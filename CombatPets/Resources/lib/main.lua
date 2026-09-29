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
--[[
  CombatPets - 战斗宠物 —— LuaLoader (Lua) 版
  ---------------------------------------------------------------------------
  由 KernelLoader(C) 版 Mods/TEKernelMods/CombatPets/main.c 移植，功能对齐。

  功能:
    1. 宠物保留各自 AI 与行为不变; 附近(500px)有敌怪时, 宠物主动跑向敌怪
       (直接位移), 靠近后靠弹幕接触伤害结算;
    2. 伤害随世界进程(9 个时期)成长;
    3. 宠物召唤物品标记为召唤伤害物品(summon=true)并同步 item.damage;
    4. 多宠物共存: 跳过原版宠物 Buff 互斥清理。

  时期: 0 初始 -> 1 克眼/世吞/克脑/史王/蜂王 -> 2 骷髅王 -> 3 困难模式 ->
        4 任意机械Boss -> 5 世纪之花 -> 6 石巨人 -> 7 拜月教徒 -> 8 月总

  Hook 对照:
    * Projectile.AI       prefix+postfix : 伤害成长 / 追击接管(跳过原 AI);
    * Projectile.Damage   prefix+postfix : type 伪装成 755 绕过 projPet 禁伤;
    * Item.SetDefaults    postfix        : 标记 summon + 同步伤害;
    * Player.AddBuff_RemoveOldPetBuffsOfMatchingType prefix: 跳过互斥清理, 多宠物共存。

  === 与 C 版的差异 / 限制 ===
  * C 版有 Android(原生指针) 与桌面(托管字段) 两套读写。Lua 版:
      - position/velocity: 用 get/set_field_vec2 (两端一致);
      - 标量字段: get/set_field_value 显式类型 (两端一致);
      - Projectile.ai (float[3]):
          Android: 用 get/set_field_raw 读写 12 字节, 与 C 版 Android 的
                   patchlib_field_get_pointer + p[idx] 完全等价;
          桌面端: 读用托管数组 array_at, 写用 array_set(ai, idx, v, "float")。
  * 桌面端 Projectile.ai[0] 的临时改写已用 mod.patch.array_set 实现
    (LuaLoader 1.3.0), 无需再依赖原始指针。
  * C 版 prefix 实测 false=执行原方法、true=跳过; Lua 版一致。
--]]

mod.meta = { pkg_id = "lzup.lua.combatpets", version = "4.6.0" }

local patch = mod.patch

-- ============ 常量 (与 C 版一致) ============
local PROJ_BAT_OF_LIGHT = 755
local CHASE_RANGE_SQ = 500.0 * 500.0
local CHASE_SPEED = 8.0
local PET_KNOCKBACK = 2.0
local DAMAGE_CAP = 100
local NPC_SLOTS = 1000

-- 宠物弹幕表 (取自 Main.projPet, 除去 755/946)
local PET_PROJS = {
    492, 499, 653, 701, 703, 702, 764, 765, 319, 334, 324, 266,
    313, 314, 317, 175, 111, 112, 127, 191, 192, 193, 194, 197,
    198, 199, 200, 208, 209, 210, 211, 236, 268, 269, 353, 373,
    375, 380, 387, 388, 390, 391, 392, 393, 394, 395, 1093, 1094,
    398, 407, 423, 533, 613, 623, 625, 626, 627, 628, 758, 759,
    774, 815, 816, 817, 821, 825, 831, 833, 834, 835, 854, 858,
    859, 860, 864, 875, 951, 963, 970, 1022, 881, 882, 883, 884,
    885, 886, 887, 888, 889, 890, 891, 892, 893, 894, 895, 896,
    897, 898, 899, 900, 901, 934, 956, 957, 958, 959, 960, 994,
    998, 1003, 1004, 1018, 1056, 1090, 1027, 1046, 1050, 1095, 1096,
}

-- 宠物基础伤害表
local PET_DMG = {
    [236] = 12, [266] = 14, [268] = 15, [269] = 15, [313] = 14,
    [314] = 14, [317] = 14, [319] = 15, [324] = 15, [334] = 13,
    [373] = 14, [375] = 16, [380] = 20, [387] = 16, [395] = 18,
    [398] = 18, [407] = 20, [423] = 22, [533] = 24, [613] = 25,
    [623] = 26, [625] = 26, [626] = 26, [627] = 26, [628] = 26,
    [653] = 22, [701] = 24, [702] = 24, [703] = 24, [758] = 30,
    [759] = 30, [764] = 28, [765] = 28, [774] = 28, [815] = 32,
    [816] = 32, [817] = 32, [821] = 32, [825] = 34, [831] = 34,
    [833] = 34, [834] = 34, [835] = 34, [854] = 35, [858] = 35,
    [859] = 35, [860] = 35, [864] = 36, [875] = 38, [881] = 30,
    [882] = 30, [883] = 30, [884] = 30, [885] = 30, [886] = 30,
    [887] = 30, [888] = 30, [889] = 30, [890] = 30, [891] = 30,
    [892] = 30, [893] = 30, [894] = 30, [895] = 30, [896] = 30,
    [897] = 30, [898] = 30, [899] = 30, [900] = 30, [901] = 30,
    [934] = 38, [951] = 40, [956] = 42, [957] = 42, [958] = 42,
    [959] = 42, [960] = 42, [963] = 45, [970] = 45, [994] = 48,
    [998] = 48, [1003] = 48, [1004] = 48, [1018] = 50, [1022] = 50,
    [1027] = 52, [1046] = 55, [1050] = 55, [1056] = 52, [1090] = 52,
    [1093] = 30, [1094] = 30, [1095] = 55, [1096] = 55, [175] = 10,
    [111] = 10, [112] = 10, [127] = 10, [191] = 10, [192] = 10,
    [193] = 10, [194] = 10, [197] = 10, [198] = 10, [199] = 10,
    [200] = 10, [208] = 10, [209] = 10, [210] = 10, [211] = 10,
    [353] = 12, [492] = 18, [499] = 18,
}

-- 阶段倍率 (下标 1~9 对应 stage 0~8)
local STAGE_MULT = { 1.0, 1.2, 1.5, 2.0, 2.4, 2.8, 3.2, 3.6, 4.0 }

-- 宠物弹幕查询表(热路径免反射)
local PET_SET = {}
for _, t in ipairs(PET_PROJS) do PET_SET[t] = true end

-- ============ 句柄 ============
local f_projpet, f_npc_array, f_hardmode
-- NPC.downed* 静态字段
local f_downed1, f_downed2, f_downed3
local f_downed_slimeking, f_downed_queenbee
local f_downed_mechany, f_downed_plant, f_downed_golem
local f_downed_cultist, f_downed_moonlord

-- Projectile 字段
local f_proj_active, f_proj_type, f_proj_owner, f_proj_damage
local f_proj_friendly, f_proj_knockback, f_proj_ai
local f_proj_timeleft, f_proj_spritedir
-- Entity 字段
local f_vel, f_whoami, f_pos, f_width, f_height
-- NPC 字段
local f_npc_active, f_npc_friendly, f_npc_townnpc, f_npc_donttake
local f_npc_life, f_npc_lifemax, f_npc_chaseable, f_npc_immortal
-- Item 字段
local f_item_shoot, f_item_damage, f_item_summon

-- 本地玩家编号: 桌面端是字段 Main.myPlayer; Android 端是属性 -> get_myPlayer()
local f_myplayer
local m_get_myplayer

-- Collision.SolidTiles(int,int,int,int)
local m_solidtiles

-- ============ 状态 ============
local ready = false
local skip_ai = false
local chase_target = {}
local chase_scan_tick = {}
local ai_tick = 0

local stage_cache = 0
local stage_tick = 0

-- Damage 伪装上下文
local dmg_spoofing = false
local orig_type = 0
local ai0_modified = false

-- ============ 工具 ============
local function find_field(type_handle, name)
    local cur, guard = type_handle, 0
    while cur and guard < 16 do
        local f = patch.get_field(cur, name)
        if f then return f end
        cur = patch.get_parent(cur)
        guard = guard + 1
    end
    return nil
end

local function get_int(field, inst, default)
    if not field then return default end
    local v = patch.get_field_value(field, inst, "int32")
    if v == nil then return default end
    return v
end

local function set_int(field, inst, v)
    if field then patch.set_field_value(field, inst, v, "int32") end
end

local function get_bool(field, inst, default)
    if not field then return default end
    local v = patch.get_field_value(field, inst, "bool")
    if v == nil then return default end
    return v
end

local function set_bool(field, inst, v)
    if field then patch.set_field_value(field, inst, v, "bool") end
end

local function set_float(field, inst, v)
    if field then patch.set_field_value(field, inst, v, "float") end
end

local function read_static_bool(field)
    if not field then return false end
    return patch.get_field_value(field, nil, "bool") == true
end

--- 读取弹幕 ai[idx]; Android 用 raw(与 C 版指针内联等价), 桌面用托管数组
local function proj_ai_get(proj, idx)
    if not proj or not f_proj_ai then return nil end
    if mod.platform == "android" then
        local raw = patch.get_field_raw(f_proj_ai, proj, 12)
        if not raw or #raw < (idx + 1) * 4 then return nil end
        return (string.unpack("<f", raw, idx * 4 + 1))
    else
        local arr = patch.get_field_value(f_proj_ai, proj, "object")
        if not arr then return nil end
        return patch.array_at(arr, idx, "float")
    end
end

--- 写入弹幕 ai[idx]; 返回是否成功 (对应 C 版 ProjAiSet)
local function proj_ai_set(proj, idx, v)
    if not proj or not f_proj_ai then return false end
    if mod.platform == "android" then
        local raw = patch.get_field_raw(f_proj_ai, proj, 12)
        if not raw then return false end
        local bytes = raw:sub(1, idx * 4) .. string.pack("<f", v) .. raw:sub(idx * 4 + 5)
        patch.set_field_raw(f_proj_ai, proj, bytes)
        return true
    else
        -- 桌面端: ai 是托管 float[], 用 array_set 写回 (LuaLoader 1.3.0)
        local arr = patch.get_field_value(f_proj_ai, proj, "object")
        if not arr or not patch.array_set then return false end
        local ok, r = pcall(patch.array_set, arr, idx, v, "float")
        return ok and r ~= false
    end
end

--- 读取实体中心点
local function entity_center(ent)
    local x, y = patch.get_field_vec2(f_pos, ent)
    if x == nil then return nil end
    return x + get_int(f_width, ent, 0) * 0.5, y + get_int(f_height, ent, 0) * 0.5
end

local function entity_pos_add(ent, dx, dy)
    local x, y = patch.get_field_vec2(f_pos, ent)
    if x == nil then return end
    patch.set_field_vec2(f_pos, ent, x + dx, y + dy)
end

local function entity_vel_get(ent)
    local x, y = patch.get_field_vec2(f_vel, ent)
    if x == nil then return 0.0, 0.0 end
    return x, y
end

local function entity_vel_set(ent, x, y)
    patch.set_field_vec2(f_vel, ent, x, y)
end

--- 本地玩家编号; 失败返回 -1 (对应 C 版 LocalPlayer)
local function local_player()
    local v = get_int(f_myplayer, nil, nil)
    if v ~= nil then return v end
    if m_get_myplayer then
        local r = patch.invoke(m_get_myplayer)
        if r ~= nil then return r end
    end
    return -1
end

local function is_pet_proj(t)
    return t ~= nil and PET_SET[t] == true
end

--- 计算当前世界进程阶段 (0~8)
local function current_stage()
    if read_static_bool(f_downed_moonlord) then return 8 end
    if read_static_bool(f_downed_cultist) then return 7 end
    if read_static_bool(f_downed_golem) then return 6 end
    if read_static_bool(f_downed_plant) then return 5 end
    if read_static_bool(f_downed_mechany) then return 4 end
    if read_static_bool(f_hardmode) then return 3 end
    if read_static_bool(f_downed3) then return 2 end
    if read_static_bool(f_downed1) or read_static_bool(f_downed2)
       or read_static_bool(f_downed_slimeking) or read_static_bool(f_downed_queenbee) then
        return 1
    end
    return 0
end

local function pet_base_dmg(proj_type)
    return PET_DMG[proj_type] or 10
end

--- 宠物在当前时期的伤害 (阶段每 120 帧刷新一次缓存)
local function pet_damage_now(proj_type)
    stage_tick = stage_tick + 1
    if stage_tick >= 120 then
        stage_tick = 0
        stage_cache = current_stage()
    end
    local stage = stage_cache
    if stage > 8 then stage = 8 end
    local d = pet_base_dmg(proj_type) * STAGE_MULT[stage + 1]
    if d > DAMAGE_CAP then d = DAMAGE_CAP end
    return math.floor(d + 0.5)
end

--- 敌怪有效性 (对齐 NPC.CanBeChasedBy)
local function is_chaseable_enemy(npc)
    if not npc then return false end
    if get_bool(f_npc_active, npc, false) == false then return false end
    if get_int(f_npc_lifemax, npc, 0) <= 5 then return false end
    if get_int(f_npc_life, npc, 0) <= 0 then return false end
    if get_bool(f_npc_chaseable, npc, false) == false then return false end
    if get_bool(f_npc_friendly, npc, false) == true then return false end
    if get_bool(f_npc_donttake, npc, false) == true then return false end
    if get_bool(f_npc_immortal, npc, false) == true then return false end
    return true
end

local function npc_array()
    if not f_npc_array then return nil end
    return patch.get_field_value(f_npc_array, nil, "object")
end

--- 扫描宠物附近(500px)的最近敌怪, 返回 Main.npc 下标, 无则 -1
local function find_nearest_enemy(pet)
    local arr = npc_array()
    if not arr then return -1 end
    local px, py = entity_center(pet)
    if not px then return -1 end

    local n = patch.array_length(arr)
    local best, best_d2 = -1, CHASE_RANGE_SQ
    for i = 0, n - 1 do
        local npc = patch.array_at(arr, i)
        if npc and is_chaseable_enemy(npc) then
            local nx, ny = entity_center(npc)
            if nx then
                local dx, dy = nx - px, ny - py
                local d2 = dx * dx + dy * dy
                if d2 < best_d2 then
                    best_d2 = d2
                    best = i
                end
            end
        end
    end
    return best
end

--- 查询世界坐标所在图格是否为实心方块 (对应 C 版 TileSolidAt)
local function tile_solid_at(wx, wy)
    if not m_solidtiles then return false end
    local tx = math.floor(wx / 16.0)
    local ty = math.floor(wy / 16.0)
    -- Collision.SolidTiles(startX, endX, startY, endY): 单格 (tx,ty)
    local r = patch.invoke(m_solidtiles, tx, tx, ty, ty)
    return r == true
end

--- 宠物中心到目标中心的直线是否通畅(按图格采样, 步长 16px)
local function path_clear(x1, y1, x2, y2)
    local dx, dy = x2 - x1, y2 - y1
    local dist = math.sqrt(dx * dx + dy * dy)
    local steps = math.floor(dist / 16.0)
    for k = 1, steps do
        local t = k / (steps + 1)
        if tile_solid_at(x1 + dx * t, y1 + dy * t) then return false end
    end
    return true
end

--- 校验追击目标是否仍有效
local function chase_target_valid(pet, target)
    if target < 0 then return false end
    local arr = npc_array()
    if not arr then return false end
    local npc = patch.array_at(arr, target)
    if not npc then return false end
    if not is_chaseable_enemy(npc) then return false end

    local px, py = entity_center(pet)
    local nx, ny = entity_center(npc)
    if not px or not nx then return false end
    local dx, dy = nx - px, ny - py
    if dx * dx + dy * dy > 700.0 * 700.0 then return false end
    return path_clear(px, py, nx, ny)
end

--- 冲刺一步: 直线冲向目标, 返回是否仍在追击
local function chase_step(pet, target)
    local arr = npc_array()
    if not arr then return false end
    local npc = patch.array_at(arr, target)
    if not npc then return false end

    local px, py = entity_center(pet)
    local nx, ny = entity_center(npc)
    if not px or not nx then return false end
    local dx, dy = nx - px, ny - py
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist < 0.001 then return false end

    local pw = get_int(f_width, pet, 0)
    local nw = get_int(f_width, npc, 0)
    local stop_dist = (pw + nw) * 0.25
    if stop_dist < 8.0 then stop_dist = 8.0 end

    if dist <= stop_dist then
        entity_vel_set(pet, dx / dist * 1.5, dy / dist * 1.5)
        return true
    end

    local cvx, cvy = entity_vel_get(pet)
    local wantx = dx / dist * CHASE_SPEED
    local wanty = dy / dist * CHASE_SPEED
    local vx = cvx + (wantx - cvx) * 0.25
    local vy = cvy + (wanty - cvy) * 0.25

    if tile_solid_at(px + vx, py + vy) then
        entity_vel_set(pet, 0.0, 0.0)
        return false
    end

    entity_pos_add(pet, vx, vy)
    entity_vel_set(pet, vx, vy)
    if vx >= 0.0 then
        set_int(f_proj_spritedir, pet, 1)
    else
        set_int(f_proj_spritedir, pet, -1)
    end
    return true
end

-- ============ Hook: Projectile.AI (Prefix + Postfix) ============
local function ai_prefix(instance, args, result)
    if not ready or skip_ai or not instance then return false end

    local t = get_int(f_proj_type, instance, -1)
    if not is_pet_proj(t) then return false end
    if get_bool(f_proj_active, instance, false) == false then return false end

    local my_player = local_player()
    if my_player < 0 or get_int(f_proj_owner, instance, -1) ~= my_player then return false end

    local who = get_int(f_whoami, instance, -1)
    if who < 0 or who >= NPC_SLOTS then return false end

    -- 伤害随时期成长
    set_int(f_proj_damage, instance, pet_damage_now(t))
    set_float(f_proj_knockback, instance, PET_KNOCKBACK)
    -- 接触伤害需要 friendly
    set_bool(f_proj_friendly, instance, true)

    ai_tick = ai_tick + 1
    local tick = ai_tick
    local target = chase_target[who] or -1
    if not chase_target_valid(instance, target) then
        if tick - (chase_scan_tick[who] or 0) >= 20 then
            chase_scan_tick[who] = tick
            target = find_nearest_enemy(instance)
            chase_target[who] = target
        else
            target = -1
        end
    end

    if target >= 0 then
        -- 接管: 跳过原 AI。原 AI 的存活刷新(timeLeft=2)不会执行, 补上
        set_int(f_proj_timeleft, instance, 2)
        skip_ai = true
        return true
    end
    return false
end

local function ai_postfix(instance, args, result)
    if not skip_ai or not instance then return end
    skip_ai = false

    local who = get_int(f_whoami, instance, -1)
    if who < 0 or who >= NPC_SLOTS then return end
    local target = chase_target[who] or -1
    if target < 0 then return end
    if not chase_step(instance, target) then
        chase_target[who] = -1
    end
end

-- ============ Hook: Projectile.Damage (Prefix/Postfix) ============
-- 原版 Damage_CanDealDamage() 对 Main.projPet 弹幕一律禁伤(755 冲刺除外)。
-- Damage 执行期间把 type 伪装成 755, ai[0] 临时置 1, 绕过禁伤检查。
local function damage_prefix(instance, args, result)
    if not ready or dmg_spoofing or not instance then return false end

    local t = get_int(f_proj_type, instance, -1)
    if not is_pet_proj(t) then return false end
    if get_bool(f_proj_active, instance, false) == false then return false end

    local my_player = local_player()
    if my_player < 0 or get_int(f_proj_owner, instance, -1) ~= my_player then return false end

    orig_type = t
    set_int(f_proj_type, instance, PROJ_BAT_OF_LIGHT)

    -- 755 的放行条件是 ai[0]!=0, 宠物待机时 ai[0] 多为 0, 临时置 1
    ai0_modified = false
    local a0 = proj_ai_get(instance, 0)
    if a0 ~= nil and a0 == 0.0 then
        if proj_ai_set(instance, 0, 1.0) then
            ai0_modified = true
        end
    end
    dmg_spoofing = true
    return false
end

local function damage_postfix(instance, args, result)
    if not dmg_spoofing or not instance then return end
    dmg_spoofing = false
    set_int(f_proj_type, instance, orig_type)
    if ai0_modified then
        proj_ai_set(instance, 0, 0.0)
        ai0_modified = false
    end
end

-- ============ Hook: Player.AddBuff_RemoveOldPetBuffsOfMatchingType ============
-- 跳过它即可让多只宠物共存 (true = 跳过原方法)
local function remove_old_pet_buffs_prefix(instance, args, result)
    return ready
end

-- ============ Hook: Item.SetDefaults (Postfix) ============
local function set_defaults_postfix(instance, args, result)
    if not ready or not instance then return end
    local shoot = get_int(f_item_shoot, instance, -1)
    if not is_pet_proj(shoot) then return end
    set_bool(f_item_summon, instance, true)
    set_int(f_item_damage, instance, pet_damage_now(shoot))
end

-- ============ 钩子安装 ============
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

-- ============ 初始化 ============
function setup()
    mod.info("初始化战斗宠物模组")

    local main_type = patch.get_type("Terraria", "Main")
    local npc_type = patch.get_type("Terraria", "NPC")
    local player_type = patch.get_type("Terraria", "Player")
    local item_type = patch.get_type("Terraria", "Item")
    local projectile_type = patch.get_type("Terraria", "Projectile")
    local entity_type = patch.get_type("Terraria", "Entity")
    if not main_type or not npc_type or not player_type or not item_type
       or not projectile_type or not entity_type then
        mod.error("获取类型失败")
        return
    end

    -- 本地玩家编号
    f_myplayer = find_field(main_type, "myPlayer")
    if not f_myplayer then
        m_get_myplayer = patch.get_method(main_type, "get_myPlayer", 0)
            or patch.get_method(main_type, "get_myPlayer")
    end
    if not f_myplayer and not m_get_myplayer then
        mod.error("获取 Main.myPlayer 失败")
        return
    end

    -- 静态字段
    f_projpet = find_field(main_type, "projPet")
    f_npc_array = find_field(main_type, "npc")
    f_hardmode = find_field(main_type, "hardMode")
    f_downed1 = find_field(npc_type, "downedBoss1")
    f_downed2 = find_field(npc_type, "downedBoss2")
    f_downed3 = find_field(npc_type, "downedBoss3")
    f_downed_slimeking = find_field(npc_type, "downedSlimeKing")
    f_downed_queenbee = find_field(npc_type, "downedQueenBee")
    f_downed_mechany = find_field(npc_type, "downedMechBossAny")
    f_downed_plant = find_field(npc_type, "downedPlantBoss")
    f_downed_golem = find_field(npc_type, "downedGolemBoss")
    f_downed_cultist = find_field(npc_type, "downedAncientCultist")
    f_downed_moonlord = find_field(npc_type, "downedMoonlord")

    -- 实例字段
    f_proj_active = find_field(projectile_type, "active")
    f_npc_active = find_field(npc_type, "active")
    f_proj_type = find_field(projectile_type, "type")
    f_proj_owner = find_field(projectile_type, "owner")
    f_proj_damage = find_field(projectile_type, "damage")
    f_proj_friendly = find_field(projectile_type, "friendly")
    f_proj_knockback = find_field(projectile_type, "knockBack")
    f_proj_ai = find_field(projectile_type, "ai")
    f_vel = find_field(entity_type, "velocity")
    f_proj_timeleft = find_field(projectile_type, "timeLeft")
    f_proj_spritedir = find_field(projectile_type, "spriteDirection")
    f_whoami = find_field(entity_type, "whoAmI")
    f_pos = find_field(entity_type, "position")
    f_width = find_field(entity_type, "width")
    f_height = find_field(entity_type, "height")
    f_npc_friendly = find_field(npc_type, "friendly")
    f_npc_townnpc = find_field(npc_type, "townNPC")
    f_npc_donttake = find_field(npc_type, "dontTakeDamage")
    f_npc_life = find_field(npc_type, "life")
    f_npc_lifemax = find_field(npc_type, "lifeMax")
    f_npc_chaseable = find_field(npc_type, "chaseable")
    f_npc_immortal = find_field(npc_type, "immortal")
    f_item_shoot = find_field(item_type, "shoot")
    f_item_damage = find_field(item_type, "damage")
    f_item_summon = find_field(item_type, "summon")

    if not f_proj_active or not f_proj_type or not f_proj_owner or not f_proj_damage
       or not f_proj_friendly or not f_proj_knockback or not f_proj_ai
       or not f_vel or not f_proj_timeleft or not f_proj_spritedir or not f_whoami
       or not f_pos or not f_width or not f_height
       or not f_npc_active or not f_npc_friendly or not f_npc_donttake
       or not f_npc_life or not f_npc_lifemax or not f_npc_chaseable or not f_npc_immortal
       or not f_item_shoot or not f_item_damage or not f_item_summon then
        mod.error("获取关键字段失败")
        return
    end

    if not f_npc_array or not f_hardmode then
        mod.error("获取 Main.npc / Main.hardMode 失败")
        return
    end

    -- 追击状态初始化
    for i = 0, NPC_SLOTS - 1 do
        chase_target[i] = -1
        chase_scan_tick[i] = 0
    end

    -- Hook Projectile.AI
    local ai_method = patch.get_method(projectile_type, "AI", 0)
        or patch.get_method(projectile_type, "AI")
    if safe_hook(ai_method, { prefix = ai_prefix, postfix = ai_postfix }, "Projectile.AI") then
        -- ok
    else
        mod.error("Projectile.AI Hook 失败, 战斗宠物不可用")
        return
    end

    -- Hook Projectile.Damage (绕过 projPet 禁伤)
    local dmg_method = patch.get_method(projectile_type, "Damage")
        or patch.get_method(projectile_type, "Damage", 0)
    if not safe_hook(dmg_method, { prefix = damage_prefix, postfix = damage_postfix }, "Projectile.Damage") then
        mod.warn("Projectile.Damage Hook 失败, 宠物接触伤害可能不结算")
    end

    -- Collision.SolidTiles(4 参)
    local collision_type = patch.get_type("Terraria", "Collision")
    if collision_type then
        m_solidtiles = patch.get_method(collision_type, "SolidTiles", 4)
            or patch.get_method(collision_type, "SolidTiles")
    end
    if not m_solidtiles then
        mod.warn("获取 Collision.SolidTiles 失败(穿墙保护不可用)")
    end

    -- 多宠物共存: 跳过宠物 Buff 互斥清理
    local remove_pet = patch.get_method(player_type, "AddBuff_RemoveOldPetBuffsOfMatchingType")
        or patch.get_method(player_type, "AddBuff_RemoveOldPetBuffsOfMatchingType", 1)
    if not safe_hook(remove_pet, { prefix = remove_old_pet_buffs_prefix }, "Player.RemoveOldPetBuffs") then
        mod.warn("多宠物共存 Hook 失败")
    end

    -- 宠物召唤物品: 标记 summon + 同步伤害
    local setdef = patch.get_method(item_type, "SetDefaults", 2)
        or patch.get_method(item_type, "SetDefaults", 1)
        or patch.get_method(item_type, "SetDefaults")
    if not safe_hook(setdef, { postfix = set_defaults_postfix }, "Item.SetDefaults") then
        mod.warn("Item.SetDefaults Hook 失败")
    end

    ready = true
    mod.info("战斗宠物初始化完成")
end

todo_list = { "setup" }
