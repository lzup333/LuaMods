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
-- LuaLoader 示范 Mod：追踪弹幕 (Homing Projectile)
--
-- 思路:
--   Hook Terraria.Projectile.AI() 的 postfix。
--   原版 Update() 里会先调用 AI() 决定本帧速度, 随后 position += velocity,
--   所以在 AI() 执行完之后修改 velocity, 本帧就会立刻生效, 也不会被 AI 覆盖。
--
--   对每个"玩家的武器弹幕":
--     1. 先读自身速度, 速度太小(静止)的弹幕不处理;
--     2. 遍历 Main.npc 选择锁定目标, 优先级:
--          Boss > 精英怪(rarity >= elite_min_rarity) > 距离更近 > 总血量(lifeMax)更多;
--     3. 把自己的速度方向朝"目标中心 - 自身中心"方向做一个插值转向(保持原速率),
--        并可选地同步 rotation / netUpdate。
--
-- 依赖 LuaLoader 在字段访问上的扩展:
--   mod.patch.get_field_vec2(field, instance) -> x, y   (读写 Vector2)
--   mod.patch.set_field_vec2(field, instance, x, y)
--   mod.patch.array_length / array_at                    (遍历对象数组)

mod.meta = { pkg_id = "lzup.lua.homingprojectile", version = "1.0.0" }

local patch = mod.patch

-- ============ 配置 ============
local cfg = {
    enabled = true,      -- 总开关
    range = 5000.0,      -- 索敌半径(像素), 给足够大即可覆盖全屏
    turn_rate = 0.18,    -- 每帧转向比例(0~1), 越大越"粘人"
    max_speed = 24.0,    -- 追踪时速度上限(像素/帧)
    min_speed = 1.0,     -- 低于此速度的弹幕不追踪(避免原地打转)
    stop_distance = 24.0,-- 距目标过近时停止转向(避免绕圈)
    rotate = false,      -- 是否让贴图朝向速度方向(会因贴图基准轴不同而偏转, 默认关闭)
    sync = false,        -- 联机时是否置 netUpdate(单机可关, 减少网络流量)
    elite_min_rarity = 1,-- rarity >= 此值视为"精英怪"(原版稀有生物标记)
    retarget_interval = 4,-- 每多少帧重新扫描一次目标(缓存期间只做有效性校验)
}

-- ============ 句柄 ============
local T_PROJECTILE, T_NPC, T_MAIN
local F_pos, F_vel, F_width, F_height
local F_active, F_friendly, F_hostile, F_minion, F_sentry, F_bobber
local F_ai_style, F_rotation, F_net_update
local F_npc_pos, F_npc_width, F_npc_height, F_npc_active
local F_npc_boss, F_npc_rarity, F_npc_life_max
local F_npc_chaseable, F_npc_dont_take_damage, F_npc_immortal, F_npc_friendly
local F_main_npc

local npc_array            -- Main.npc (懒加载并缓存)
local target_cache = {}    -- [弹幕] = { npc = 目标, ttl = 剩余帧数 }

local fired = false

-- 沿父类链查找字段(Projectile 的 position/velocity/width/height 来自 Entity)
local function find_field(type_handle, name)
    local cur = type_handle
    local guard = 0
    while cur and guard < 16 do
        local field = patch.get_field(cur, name)
        if field then return field end
        cur = patch.get_parent(cur)
        guard = guard + 1
    end
    return nil
end

-- 安全读取(字段可能因版本差异缺失, 缺失时返回默认值, 避免每帧报错)
local function get_bool(field, inst, default)
    if not field then return default end
    local value = patch.get_field_value(field, inst, "bool")
    if value == nil then return default end
    return value
end

local function get_int(field, inst, default)
    if not field then return default end
    local value = patch.get_field_value(field, inst, "int32")
    if value == nil then return default end
    return value
end

-- 判断是否为"玩家的武器弹幕"
local function is_player_projectile(p)
    if not get_bool(F_active, p, false) then return false end
    if get_bool(F_hostile, p, false) then return false end
    if not get_bool(F_friendly, p, false) then return false end
    if get_bool(F_minion, p, false) then return false end
    if get_bool(F_sentry, p, false) then return false end
    if get_bool(F_bobber, p, false) then return false end
    return true
end

-- 取 Main.npc 数组句柄(静态数组对象只需取一次)
local function get_npc_array()
    if npc_array then return npc_array end
    if not F_main_npc then return nil end
    npc_array = patch.get_field_value(F_main_npc, nil, "object")
    return npc_array
end

-- 目标是否可被锁定。等价于原版 NPC.CanBeChasedBy(), 但只用字段判定,
-- 避免在 Hook 里额外 invoke 方法(更稳、更快):
--   active && chaseable && lifeMax > 5 && !dontTakeDamage && !immortal && !friendly
local function is_targetable(npc)
    if not npc then return false end
    if not get_bool(F_npc_active, npc, false) then return false end
    if not get_bool(F_npc_chaseable, npc, true) then return false end
    if get_int(F_npc_life_max, npc, 0) <= 5 then return false end
    if get_bool(F_npc_dont_take_damage, npc, false) then return false end
    if get_bool(F_npc_immortal, npc, false) then return false end
    if get_bool(F_npc_friendly, npc, false) then return false end
    return true
end

-- 按优先级选择锁定目标: Boss > 精英怪 > 更近 > 血量更多
local function find_best_target(px, py)
    local arr = get_npc_array()
    if not arr then return nil end

    local count = patch.array_length(arr)
    local range2 = cfg.range * cfg.range
    local best, best_boss, best_elite, best_d2, best_hp

    for i = 0, count - 1 do
        local npc = patch.array_at(arr, i)
        if is_targetable(npc) then
            local nx, ny = patch.get_field_vec2(F_npc_pos, npc)
            if nx then
                local nw = get_int(F_npc_width, npc, 0)
                local nh = get_int(F_npc_height, npc, 0)
                local cx, cy = nx + nw * 0.5, ny + nh * 0.5
                local dx, dy = cx - px, cy - py
                local d2 = dx * dx + dy * dy
                if d2 <= range2 then
                    local is_boss = get_bool(F_npc_boss, npc, false)
                    local is_elite = get_int(F_npc_rarity, npc, 0) >= cfg.elite_min_rarity
                    local hp = get_int(F_npc_life_max, npc, 0)

                    local better
                    if not best then
                        better = true
                    elseif is_boss ~= best_boss then
                        better = is_boss
                    elseif is_elite ~= best_elite then
                        better = is_elite
                    elseif d2 ~= best_d2 then
                        better = d2 < best_d2
                    else
                        better = hp > best_hp
                    end

                    if better then
                        best, best_boss, best_elite, best_d2, best_hp = npc, is_boss, is_elite, d2, hp
                    end
                end
            end
        end
    end
    return best
end

-- 取锁定目标: 优先用缓存(逐帧校验有效性), 到期或失效则重新扫描
local function acquire_target(p)
    local entry = target_cache[p]
    if entry then
        entry.ttl = entry.ttl - 1
        if entry.ttl > 0 and is_targetable(entry.npc) then
            return entry.npc
        end
        target_cache[p] = nil
    end
    return nil
end

-- 把一枚弹幕的速度方向转向锁定目标
local function steer(p)
    local vx, vy = patch.get_field_vec2(F_vel, p)
    if not vx then return end
    local speed = math.sqrt(vx * vx + vy * vy)
    if speed < cfg.min_speed then return end

    -- 自身中心
    local px, py = patch.get_field_vec2(F_pos, p)
    if not px then return end
    local pw = get_int(F_width, p, 0)
    local ph = get_int(F_height, p, 0)
    px, py = px + pw * 0.5, py + ph * 0.5

    -- 锁定目标(带缓存, 避免每帧全表扫描)
    local npc = acquire_target(p)
    if not npc then
        npc = find_best_target(px, py)
        if not npc then return end
        -- 加一点抖动, 让各弹幕的重新扫描错开, 避免同一帧集中全表扫描
        target_cache[p] = { npc = npc, ttl = cfg.retarget_interval + math.random(0, cfg.retarget_interval) }
    end

    -- 目标中心
    local tx, ty = patch.get_field_vec2(F_npc_pos, npc)
    if not tx then return end
    local nw = get_int(F_npc_width, npc, 0)
    local nh = get_int(F_npc_height, npc, 0)
    tx, ty = tx + nw * 0.5, ty + nh * 0.5

    local dx, dy = tx - px, ty - py
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist < cfg.stop_distance then return end
    dx, dy = dx / dist, dy / dist

    -- 单位速度方向朝目标方向插值, 再归一化
    local ux, uy = vx / speed, vy / speed
    local nx = ux + (dx - ux) * cfg.turn_rate
    local ny = uy + (dy - uy) * cfg.turn_rate
    local nl = math.sqrt(nx * nx + ny * ny)
    if nl < 1e-6 then
        nx, ny = dx, dy
    else
        nx, ny = nx / nl, ny / nl
    end

    local ns = speed
    if ns > cfg.max_speed then ns = cfg.max_speed end
    patch.set_field_vec2(F_vel, p, nx * ns, ny * ns)

    if cfg.rotate and F_rotation then
        patch.set_field_value(F_rotation, p, math.atan(ny, nx), "float")
    end
    if cfg.sync and F_net_update then
        patch.set_field_value(F_net_update, p, true, "bool")
    end
end

-- ============ Hook: Projectile.AI() postfix ============
local function on_ai(instance, args, result)
    if not cfg.enabled or not instance then return end
    if not is_player_projectile(instance) then return end

    -- 排除钩爪(aiStyle 7)等非武器弹幕
    if get_int(F_ai_style, instance, -1) == 7 then return end

    if not fired then
        fired = true
        mod.info("追踪弹幕已生效")
    end

    steer(instance)
end

-- ============ 初始化 ============
function setup()
    T_PROJECTILE = patch.get_type("Terraria", "Projectile")
    T_NPC = patch.get_type("Terraria", "NPC")
    T_MAIN = patch.get_type("Terraria", "Main")
    if not T_PROJECTILE or not T_NPC or not T_MAIN then
        mod.error("获取类型失败 (Projectile/NPC/Main)")
        return
    end

    F_pos = find_field(T_PROJECTILE, "position")
    F_vel = find_field(T_PROJECTILE, "velocity")
    F_width = find_field(T_PROJECTILE, "width")
    F_height = find_field(T_PROJECTILE, "height")

    F_active = find_field(T_PROJECTILE, "active")
    F_friendly = find_field(T_PROJECTILE, "friendly")
    F_hostile = find_field(T_PROJECTILE, "hostile")
    F_minion = find_field(T_PROJECTILE, "minion")
    F_sentry = find_field(T_PROJECTILE, "sentry")
    F_bobber = find_field(T_PROJECTILE, "bobber")
    F_ai_style = find_field(T_PROJECTILE, "aiStyle")
    F_rotation = find_field(T_PROJECTILE, "rotation")
    F_net_update = find_field(T_PROJECTILE, "netUpdate")

    F_npc_pos = find_field(T_NPC, "position")
    F_npc_width = find_field(T_NPC, "width")
    F_npc_height = find_field(T_NPC, "height")
    F_npc_active = find_field(T_NPC, "active")
    F_npc_boss = find_field(T_NPC, "boss")
    F_npc_rarity = find_field(T_NPC, "rarity")
    F_npc_life_max = find_field(T_NPC, "lifeMax")
    F_npc_chaseable = find_field(T_NPC, "chaseable")
    F_npc_dont_take_damage = find_field(T_NPC, "dontTakeDamage")
    F_npc_immortal = find_field(T_NPC, "immortal")
    F_npc_friendly = find_field(T_NPC, "friendly")
    F_main_npc = find_field(T_MAIN, "npc")

    if not F_vel or not F_pos or not F_active or not F_friendly or
       not F_npc_pos or not F_npc_active or not F_main_npc then
        mod.error("获取关键字段失败")
        return
    end

    -- AI() 无参
    local m_ai = patch.get_method(T_PROJECTILE, "AI", 0)
    if not m_ai then
        mod.error("获取 Projectile.AI 方法失败")
        return
    end

    patch.install_hook(m_ai, { postfix = on_ai })
    mod.info(string.format("成功 Hook Projectile.AI (射程 %.0f, 转向 %.2f, 精英阈值 %d)",
            cfg.range, cfg.turn_rate, cfg.elite_min_rarity))
end

todo_list = { "setup" }
