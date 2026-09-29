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
-- RandomLoot / OneHitLoot —— LuaLoader 版（一击必爆）
-- 由 KernelLoader(C) 版 Mods/TEKernelMods/RandomLoot/main.c 移植，功能对齐。
--
-- 功能：怪物受击（NPC.checkDead）时，额外掉落一件随机物品。
--       - 每次受击必定额外掉落一件随机物品；
--       - 物品 ID 完全随机（1~6144），所有物品都有可能出现；
--       - 跳过城镇 NPC（friendly / townNPC）。
--
-- 实现：Hook NPC.checkDead() 的 Postfix，用 Player.QuickSpawnItem 生成随机物品。
--
-- 与 C 版的差异：
--   已用 LuaLoader 1.3.0 get_method_by_names("source","item","stack") 按参数名精确选择
--   QuickSpawnItem(source,int,int)，与 C 版首选逻辑一致；取不到再按参数个数 3 回退。
--   C 版 source 传 NULL；Lua 版传 nil，即空对象句柄。

mod.meta = { pkg_id = "lzup.lua.randomloot", version = "1.1.0" }

local patch = mod.patch

-- ============ 配置 ============
local MIN_ITEM_ID = 1
local MAX_ITEM_ID = 6144

-- ============ 状态 ============
local ready = false

-- ============ 句柄 ============
local T_NPC, T_MAIN, T_PLAYER
local F_friendly            -- NPC.friendly  (bool)
local F_town_npc            -- NPC.townNPC   (bool)
local F_main_player         -- Main.player   (Player[] 静态字段)
local F_my_player           -- Main.myPlayer (桌面静态字段)
local M_get_my_player       -- Main.get_myPlayer (Android 属性 getter)
local M_quick_spawn_item    -- Player.QuickSpawnItem

-- ============ 小工具 ============
-- 沿父类链查找字段（NPC 的部分字段可能来自父类）
local function find_field(t, name)
    local cur, guard = t, 0
    while cur and guard < 16 do
        local f = patch.get_field(cur, name)
        if f then return f end
        cur = patch.get_parent(cur)
        guard = guard + 1
    end
    return nil
end

local function safe_hook(method, spec, label)
    if not method then
        mod.error("安装钩子失败(" .. label .. ")：方法句柄为空")
        return false
    end
    local ok, err = pcall(patch.install_hook, method, spec)
    if not ok then
        mod.error("安装钩子失败(" .. label .. ")：" .. tostring(err))
        return false
    end
    return true
end

-- ============ 本地玩家解析 ============
--- 读取本地玩家编号；失败返回 -1
local function get_my_player()
    if F_my_player then
        local v = patch.get_field_value(F_my_player, nil, "int32")
        if v ~= nil then return v end
    end
    if M_get_my_player then
        local v = patch.invoke(M_get_my_player)
        if v ~= nil then return v end
    end
    return -1
end

--- 取本地玩家对象；失败返回 nil（借用句柄，仅当次回调内有效）
local function get_player_obj()
    local my = get_my_player()
    if my == nil or my < 0 then return nil end
    if not F_main_player then return nil end
    local arr = patch.get_field_value(F_main_player, nil, "object")
    if not arr then return nil end
    return patch.array_at(arr, my)
end

local function read_bool(field, obj)
    if not field or not obj then return false end
    local v = patch.get_field_value(field, obj, "bool")
    return v == true
end

-- ============ Hook: NPC.checkDead (Postfix) ============
local function on_check_dead(instance)
    if not ready or not instance then return end
    if not M_quick_spawn_item then return end

    -- 跳过城镇 NPC
    if read_bool(F_friendly, instance) then return end
    if read_bool(F_town_npc, instance) then return end

    local player = get_player_obj()
    if not player then return end

    local item_id = math.random(MIN_ITEM_ID, MAX_ITEM_ID)
    local stack = 1

    -- QuickSpawnItem(IEntitySource source, int item, int stack)
    -- source 传 nil 表示空引用（对应 C 版的 NULL）
    local ok, err = pcall(patch.invoke, M_quick_spawn_item, player, nil, item_id, stack)
    if not ok then
        mod.warn("QuickSpawnItem 调用失败：" .. tostring(err))
    end
end

-- ============ 生命周期 ============
function setup()
    T_NPC = patch.get_type("Terraria", "NPC")
    T_MAIN = patch.get_type("Terraria", "Main")
    T_PLAYER = patch.get_type("Terraria", "Player")
    if not T_NPC or not T_MAIN or not T_PLAYER then
        mod.error("获取类型失败 (NPC/Main/Player)，模组未启用")
        return
    end

    F_friendly = find_field(T_NPC, "friendly")
    F_town_npc = find_field(T_NPC, "townNPC")
    F_main_player = patch.get_field(T_MAIN, "player")
    if not F_friendly or not F_town_npc or not F_main_player then
        mod.error("获取 NPC.friendly / NPC.townNPC / Main.player 字段失败，模组未启用")
        return
    end

    -- 本地玩家解析：优先静态字段，其次属性 getter
    F_my_player = patch.get_field(T_MAIN, "myPlayer")
    if not F_my_player then
        M_get_my_player = patch.get_method(T_MAIN, "get_myPlayer", 0)
    end

    -- QuickSpawnItem 有 (IEntitySource,int,int) 与 (IEntitySource,Item,GetItemSettings) 两个 3 参重载,
    -- 已用 LuaLoader 1.3.0 get_method_by_names("source","item","stack") 精确选 (source,int,int);
    -- 取不到再回退按参数个数 3(与 C 版回退一致)。
    M_quick_spawn_item = patch.get_method_by_names(T_PLAYER, "QuickSpawnItem", { "source", "item", "stack" })
            or patch.get_method(T_PLAYER, "QuickSpawnItem", 3)
            or patch.get_method(T_PLAYER, "QuickSpawnItem")
    if not M_quick_spawn_item then
        mod.error("获取 Player.QuickSpawnItem 方法失败，模组未启用")
        return
    end

    -- checkDead 无参；C 版先按参数个数(0)取，失败再按方法名取
    local check_dead = patch.get_method(T_NPC, "checkDead", 0)
            or patch.get_method(T_NPC, "checkDead")
    if not safe_hook(check_dead, { postfix = on_check_dead }, "NPC.checkDead") then
        mod.error("无法 Hook NPC.checkDead，一击必爆未启用")
        return
    end

    -- 物品 ID 随机化种子（每个 Mod 有独立 Lua 状态机，不影响其它 Mod）
    pcall(math.randomseed, os.time())

    ready = true
    mod.info(string.format("一击必爆已启用 (item %d~%d)", MIN_ITEM_ID, MAX_ITEM_ID))
end

todo_list = { "setup" }
