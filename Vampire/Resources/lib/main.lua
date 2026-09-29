-- Copyright (C) 2026 lzup333
--
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU Affero General Public License as published
-- by the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU Affero General Public License for more details.
--
-- You should have received a copy of the GNU Affero General Public License
-- along with this program.  If not, see <https://www.gnu.org/licenses/>.
--
-- Vampire (吸血鬼) —— LuaLoader 版
-- 由 KernelLoader(C) 版 Mods/TEKernelMods/Vampire/main.c 移植，功能对齐。
--
-- 功能:
--   玩家本人每次命中敌对生物, 有 5% 概率通过游戏自带的 Player.Heal(20)
--   回复 20 点生命(含绿色回血特效, 自动钳制到生命上限)。
--
-- 实现:
--   Hook Terraria.NPC.StrikeNPC(int Damage, float knockBack, int hitDirection,
--   bool crit, bool fromNet, int owner) 的 postfix:
--     * result 为本次实际造成的伤害(<=0 跳过);
--     * args[6] 为攻击者玩家编号(owner), 仅当等于本地玩家 Main.myPlayer 时生效;
--     * 仅对敌对生物(NPC.friendly == false && NPC.townNPC == false &&
--       NPC.lifeMax > 5)生效;
--     * 5% 概率触发后调用 Player.Heal(20)。
--
-- 与 C 版的语义差异:
--   * C 版 postfix 直接读 result 指针; Lua postfix 的 result 即原返回值, 只读即可,
--     本 Mod 无需改写返回值, 因此 1:1 对齐。
--   * C 版 Android 用 Main.get_myPlayer 属性 getter、桌面用 Main.myPlayer 静态字段;
--     Lua 版统一为: 优先静态字段, 取不到再退化到 get_myPlayer() 方法。
--   * C 版 srand(time) 播种; Lua 用 math.randomseed(os.time()) 等价。

mod.meta = { pkg_id = "lzup.lua.vampire", version = "1.3.0" }

local patch = mod.patch

-- ============ 配置 ============
local VAMPIRE_CHANCE = 5    -- 触发概率(百分比)
local VAMPIRE_HEAL   = 20   -- 触发时回复的生命值

-- ============ 句柄(全部在 setup 中解析并缓存到 local upvalue) ============
local T_MAIN, T_PLAYER, T_NPC
local F_main_player            -- Main.player      (静态 Player[])
local F_my_player              -- Main.myPlayer    (静态 int 字段; 桌面)
local M_get_my_player          -- Main.get_myPlayer(静态 int getter; Android)
local F_npc_life_max           -- NPC.lifeMax      (int)
local F_npc_friendly           -- NPC.friendly     (bool)
local F_npc_town_npc           -- NPC.townNPC      (bool)
local M_heal                   -- Player.Heal(int)

local hook_strike              -- NPC.StrikeNPC 钩子句柄

-- ============ 工具函数 ============

-- 沿父类链查找字段
local function find_field(type_handle, name)
    local cur, guard = type_handle, 0
    while cur and guard < 16 do
        local field = patch.get_field(cur, name)
        if field then return field end
        cur = patch.get_parent(cur)
        guard = guard + 1
    end
    return nil
end

-- 安全读 bool(字段缺失/读取失败时返回 default)
local function read_bool(field, inst, default)
    if not field then return default end
    local v = patch.get_field_value(field, inst, "bool")
    if v == nil then return default end
    return v
end

-- 安全读 int32
local function read_int(field, inst, default)
    if not field then return default end
    local v = patch.get_field_value(field, inst, "int32")
    if v == nil then return default end
    return v
end

-- 本地玩家编号; 失败返回 nil
local function local_player_id()
    if F_my_player then
        return patch.get_field_value(F_my_player, nil, "int32")
    end
    if M_get_my_player then
        return patch.invoke(M_get_my_player)
    end
    return nil
end

-- 本地玩家实例; 借用句柄, 仅在当次调用内有效
local function local_player()
    if not F_main_player then return nil end
    local my = local_player_id()
    if my == nil or my < 0 then return nil end
    local arr = patch.get_field_value(F_main_player, nil, "object")
    if not arr then return nil end
    if my >= patch.array_length(arr) then return nil end
    return patch.array_at(arr, my)
end

-- 用 pcall 包裹 install_hook, 失败时记录并安全退出
local function safe_hook(method, spec, label)
    if not method then
        mod.error("安装钩子失败(" .. label .. ")：方法句柄为空")
        return nil
    end
    local ok, hook = pcall(patch.install_hook, method, spec)
    if not ok then
        mod.error("安装钩子失败(" .. label .. ")：" .. tostring(hook))
        return nil
    end
    return hook
end

-- ============ Postfix: NPC.StrikeNPC ============
-- 签名(Lua 1 起始): args[1]=Damage(int) args[2]=knockBack(float)
--   args[3]=hitDirection(int) args[4]=crit(bool) args[5]=fromNet(bool)
--   args[6]=owner(int); result=本次实际伤害(int)
local function on_strike_npc(instance, args, result)
    if not instance or not args or result == nil then return end

    local dealt = result                    -- 本次实际造成的伤害
    if type(dealt) ~= "number" or dealt <= 0 then return end

    local owner = args[6]                   -- 攻击者玩家编号
    local my = local_player_id()
    if my == nil or my < 0 or owner ~= my then return end

    -- 只对敌对生物生效(排除小动物/小虫与城镇 NPC)
    if read_bool(F_npc_friendly, instance, true) then return end
    if read_bool(F_npc_town_npc, instance, true) then return end
    if read_int(F_npc_life_max, instance, 0) <= 5 then return end

    -- 每次命中独立掷 5%
    if math.random(1, 100) > VAMPIRE_CHANCE then return end

    local p = local_player()
    if not p then return end
    if M_heal then
        pcall(patch.invoke, M_heal, p, VAMPIRE_HEAL)
    end

    mod.debug(string.format("吸血触发: Player.Heal(%d)", VAMPIRE_HEAL))
end

-- ============ 初始化 ============
function setup()
    T_MAIN = patch.get_type("Terraria", "Main")
    T_PLAYER = patch.get_type("Terraria", "Player")
    T_NPC = patch.get_type("Terraria", "NPC")
    if not T_MAIN or not T_PLAYER or not T_NPC then
        mod.error("获取类型失败 (Main/Player/NPC)")
        return
    end

    -- 本地玩家编号: 桌面为静态字段, Android 为静态属性(退化到 getter 方法)
    F_my_player = find_field(T_MAIN, "myPlayer")
    if not F_my_player then
        M_get_my_player = patch.get_method(T_MAIN, "get_myPlayer", 0)
    end
    if not F_my_player and not M_get_my_player then
        mod.error("解析 Main.myPlayer 失败")
        return
    end
    F_main_player = find_field(T_MAIN, "player")

    F_npc_life_max = find_field(T_NPC, "lifeMax")
    F_npc_friendly = find_field(T_NPC, "friendly")
    F_npc_town_npc = find_field(T_NPC, "townNPC")
    if not F_npc_life_max or not F_npc_friendly or not F_npc_town_npc then
        mod.error("获取 NPC 字段失败 (lifeMax/friendly/townNPC)")
        return
    end
    if not F_main_player then
        mod.error("获取 Main.player 字段失败")
        return
    end

    -- Player.Heal(int)
    M_heal = patch.get_method(T_PLAYER, "Heal", 1) or patch.get_method(T_PLAYER, "Heal")
    if not M_heal then
        mod.warn("获取 Player.Heal 方法失败，回血将不可用")
    end

    -- Hook: NPC.StrikeNPC(6 参)
    local strike = patch.get_method(T_NPC, "StrikeNPC", 6)
    hook_strike = safe_hook(strike, { postfix = on_strike_npc }, "NPC.StrikeNPC")
    if hook_strike then
        mod.info("吸血鬼模组已启用 (5% / +20)")
    end
end

function cleanup()
    if hook_strike then
        pcall(function() hook_strike:remove() end)
        hook_strike = nil
    end
end

-- 概率随机数播种(等价 C 版 srand(time(NULL)))
pcall(math.randomseed, os.time())

todo_list = { "setup" }
