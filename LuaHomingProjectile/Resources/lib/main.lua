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
-- HomingProjectile (追踪弹幕) —— LuaLoader 版
-- 由内核(C)版 HomingProjectile (libHomingProjectile.android.arm64.so) 移植, 功能对齐。
--
-- 功能:
--   玩家自己的武器弹幕在飞行中自动朝最近的敌人转向前进, 保持弹幕原有速率不变,
--   每帧转向 18%。敌对弹幕、召唤物、哨兵、钓鱼浮标、钩爪(以及 aiStyle 61)不处理。
--
-- 实现:
--   Hook Terraria.Projectile.AI() 的 postfix。C 版装的是 prepost hook
--   patchlib_install_prepost_hook(method, NULL, fn), 即只挂 postfix, 时机一致:
--   原版 Update() 先调用 AI() 决定本帧速度, 再 position += velocity,
--   所以在 AI() 之后改 velocity 当帧立即生效, 也不会被 AI() 覆盖。
--
-- 与 C 版对齐的参数(取自 .so 的常量池):
--   索敌半径 900 像素(平方比较), 转向系数 0.18, 速度低于 0.5 的弹幕不处理,
--   与目标中心距离小于 0.001 时跳过, 目标最多复用 12 帧后重新扫描。
--
-- 目标判定等价于 C 版 can_target_npc():
--   active && lifeMax >= 6 && life >= 1 && chaseable && !friendly
--   && !dontTakeDamage && !immortal
--
-- 与 C 版的语义差异:
--   * C 版用 g_target[whoAmI] 缓存 NPC 索引, Lua 版同样按弹幕槽位(whoAmI)作键、
--     只缓存索引数值, 不缓存对象句柄, 因此不存在跨帧句柄悬垂问题;
--   * C 版直接读写字段指针, Lua 版统一走 mod.patch 字段 API;
--   * C 版读 Main.myPlayer 属性 getter, Lua 版优先静态字段, 取不到再退化为 getter。

mod.meta = { pkg_id = "lzup.lua.homingprojectile", version = "1.1.0" }

local patch = mod.patch

-- ============ 常量 ============
local TARGET_RANGE2 = 900.0 * 900.0   -- 索敌半径 900 像素
local TURN_RATE = 0.18                -- 每帧转向比例(0~1)
local MIN_SPEED = 0.5                 -- 低于此速率的弹幕不追踪(避免原地打转)
local EPS_LEN = 0.001                 -- 与目标中心的最小距离
local EPS_SPEED = 0.0001              -- 新速度长度的下限, 低于它就直接采用新速度
local RETARGET_TICKS = 12             -- 锁定目标最多复用的帧数
local MIN_NPC_LIFE_MAX = 6            -- 可锁定 NPC 的最低生命上限
local MAX_PROJECTILE_SLOTS = 1000     -- Main.projectile 槽位数上限
local EXCLUDED_AI_STYLES = { [7] = true, [61] = true }  -- 钩爪等非武器弹幕

-- ============ 句柄 ============
local F_main_npc, F_my_player, M_get_my_player
local F_proj_active, F_proj_friendly, F_proj_owner, F_proj_ai_style
local F_proj_bobber, F_proj_minion, F_proj_sentry, F_proj_who_am_i
local F_pos, F_vel, F_width, F_height
local F_npc_active, F_npc_life, F_npc_life_max, F_npc_chaseable
local F_npc_friendly, F_npc_dont_take_damage, F_npc_immortal

-- ============ 状态 ============
local targets, hits = {}, {}    -- [弹幕槽位] = 锁定的 NPC 索引 / 已复用帧数
local ready = false
local logged_once = false

-- ============ 工具函数 ============

-- 沿父类链查找字段(Projectile / NPC 的 position 等来自 Entity)
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

-- Main.npc 数组句柄; 现取现用, 不跨帧缓存
local function get_npc_array()
    if not F_main_npc then return nil end
    return patch.get_field_value(F_main_npc, nil, "object")
end

local function npc_at(idx)
    local arr = get_npc_array()
    if not arr or idx < 0 then return nil end
    return patch.array_at(arr, idx)
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

-- 实体中心(位置 + 尺寸的一半); 位置取不到返回 nil
local function entity_center(ent)
    local x, y = patch.get_field_vec2(F_pos, ent)
    if not x then return nil end
    return x + get_int(F_width, ent, 0) * 0.5, y + get_int(F_height, ent, 0) * 0.5
end

-- 等价于 C 版 can_target_npc(): 该 NPC 能否作为追踪目标
local function can_target(npc)
    if not npc then return false end
    if not get_bool(F_npc_active, npc, false) then return false end
    if get_int(F_npc_life_max, npc, 0) < MIN_NPC_LIFE_MAX then return false end
    if F_npc_life and get_int(F_npc_life, npc, 0) < 1 then return false end
    if F_npc_chaseable and not get_bool(F_npc_chaseable, npc, false) then return false end
    if get_bool(F_npc_friendly, npc, false) then return false end
    if get_bool(F_npc_dont_take_damage, npc, false) then return false end
    if get_bool(F_npc_immortal, npc, false) then return false end
    return true
end

-- 该 NPC 的中心是否在索敌半径内
local function in_range(npc, pcx, pcy)
    local cx, cy = entity_center(npc)
    if not cx then return false end
    local dx, dy = cx - pcx, cy - pcy
    return dx * dx + dy * dy <= TARGET_RANGE2
end

-- 全表扫描: 取距弹幕中心最近的合法目标, 返回 (索引, 对象); 无目标返回 nil
local function find_best_target(pcx, pcy)
    local arr = get_npc_array()
    if not arr then return nil end

    local count = patch.array_length(arr)
    local best_index, best_npc, best_dist2
    for i = 0, count - 1 do
        local npc = patch.array_at(arr, i)
        if can_target(npc) then
            local cx, cy = entity_center(npc)
            if cx then
                local dx, dy = cx - pcx, cy - pcy
                local dist2 = dx * dx + dy * dy
                if dist2 <= TARGET_RANGE2 and (not best_dist2 or dist2 < best_dist2) then
                    best_index, best_npc, best_dist2 = i, npc, dist2
                end
            end
        end
    end
    return best_index, best_npc
end

-- 取锁定目标: 优先复用缓存(逐帧校验有效性与距离, 最多复用 RETARGET_TICKS 帧),
-- 失效或到期限则重新全表扫描
local function acquire_target(who, pcx, pcy)
    local index = targets[who]
    if index then
        local npc = npc_at(index)
        if can_target(npc) and in_range(npc, pcx, pcy) then
            local used = hits[who] or 0
            if used < RETARGET_TICKS then
                hits[who] = used + 1
                return npc
            end
        end
        targets[who], hits[who] = nil, nil
    end

    local best_index, best_npc = find_best_target(pcx, pcy)
    if not best_index then return nil end
    targets[who], hits[who] = best_index, 0
    return best_npc
end

-- 把弹幕速度方向朝目标中心插值转向; 只改方向, 速率保持不变
local function steer(proj, pcx, pcy, npc)
    local vx, vy = patch.get_field_vec2(F_vel, proj)
    if not vx then return end
    local speed = math.sqrt(vx * vx + vy * vy)
    if speed < MIN_SPEED then return end

    local cx, cy = entity_center(npc)
    if not cx then return end
    local dx, dy = cx - pcx, cy - pcy
    local len = math.sqrt(dx * dx + dy * dy)
    if len < EPS_LEN then return end
    dx, dy = dx / len, dy / len

    -- 新速度 = v + (dir * speed - v) * 0.18, 再按原速率归一化
    local nvx = vx + (dx * speed - vx) * TURN_RATE
    local nvy = vy + (dy * speed - vy) * TURN_RATE
    local ns = math.sqrt(nvx * nvx + nvy * nvy)
    if ns > EPS_SPEED then
        patch.set_field_vec2(F_vel, proj, speed * (nvx / ns), speed * (nvy / ns))
    else
        patch.set_field_vec2(F_vel, proj, nvx, nvy)
    end
end

-- ============ Hook: Projectile.AI() postfix ============
local function on_ai(instance)
    if not ready or not instance then return end

    -- 过滤出"自己的武器弹幕"
    if not get_bool(F_proj_active, instance, false) then return end
    if not get_bool(F_proj_friendly, instance, false) then return end

    local my_player = local_player_id()
    if my_player == nil then return end
    if get_int(F_proj_owner, instance, -1) ~= my_player then return end

    if get_bool(F_proj_bobber, instance, false) then return end   -- 钓鱼浮标
    if get_bool(F_proj_minion, instance, false) then return end   -- 召唤物
    if get_bool(F_proj_sentry, instance, false) then return end   -- 哨兵
    if EXCLUDED_AI_STYLES[get_int(F_proj_ai_style, instance, 0)] then return end

    -- 缓存以弹幕槽位 whoAmI 为键
    local who = get_int(F_proj_who_am_i, instance, -1)
    if who < 0 or who >= MAX_PROJECTILE_SLOTS then return end

    -- 自身中心
    local px, py = entity_center(instance)
    if not px then return end

    local npc = acquire_target(who, px, py)
    if not npc then return end

    steer(instance, px, py, npc)

    if not logged_once then
        logged_once = true
        mod.info(string.format("追踪弹幕已生效 (whoAmI=%d target=%d)", who, targets[who]))
    end
end

-- ============ 初始化 ============
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

function setup()
    local t_main = patch.get_type("Terraria", "Main")
    local t_projectile = patch.get_type("Terraria", "Projectile")
    local t_npc = patch.get_type("Terraria", "NPC")
    if not t_main or not t_projectile or not t_npc then
        mod.error("获取类型失败 (Main/Projectile/NPC)")
        return
    end

    -- Main.myPlayer: Android 是属性 getter, 桌面是静态字段
    F_my_player = find_field(t_main, "myPlayer")
    if not F_my_player then
        M_get_my_player = patch.get_method(t_main, "get_myPlayer", 0)
            or patch.get_method(t_main, "get_myPlayer")
    end
    F_main_npc = find_field(t_main, "npc")

    F_proj_active = find_field(t_projectile, "active")
    F_proj_friendly = find_field(t_projectile, "friendly")
    F_proj_owner = find_field(t_projectile, "owner")
    F_proj_ai_style = find_field(t_projectile, "aiStyle")
    F_proj_bobber = find_field(t_projectile, "bobber")
    F_proj_minion = find_field(t_projectile, "minion")
    F_proj_sentry = find_field(t_projectile, "sentry")
    F_proj_who_am_i = find_field(t_projectile, "whoAmI")

    F_pos = find_field(t_projectile, "position")
    F_vel = find_field(t_projectile, "velocity")
    F_width = find_field(t_projectile, "width")
    F_height = find_field(t_projectile, "height")

    F_npc_active = find_field(t_npc, "active")
    F_npc_life = find_field(t_npc, "life")
    F_npc_life_max = find_field(t_npc, "lifeMax")
    F_npc_chaseable = find_field(t_npc, "chaseable")
    F_npc_friendly = find_field(t_npc, "friendly")
    F_npc_dont_take_damage = find_field(t_npc, "dontTakeDamage")
    F_npc_immortal = find_field(t_npc, "immortal")

    if not F_main_npc or not F_pos or not F_vel or not F_proj_active or
       not F_proj_friendly or not F_proj_owner or not F_proj_who_am_i or
       not F_npc_active or not F_npc_life_max then
        mod.error("获取关键字段失败")
        return
    end
    if not F_my_player and not M_get_my_player then
        mod.error("获取 Main.myPlayer 失败")
        return
    end

    local m_ai = patch.get_method(t_projectile, "AI", 0)
        or patch.get_method(t_projectile, "AI")
    if not safe_hook(m_ai, { postfix = on_ai }, "Projectile.AI") then
        return
    end

    ready = true
    mod.info(string.format("成功 Hook Projectile.AI (索敌 %.0f 像素, 转向 %.2f), 追踪弹幕已启用",
            math.sqrt(TARGET_RANGE2), TURN_RATE))
end

todo_list = { "setup" }
