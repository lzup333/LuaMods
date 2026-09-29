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
-- MultiProjectile (多倍弹幕 / 多重射击) —— LuaLoader 版
-- 由 KernelLoader(C) 版 Mods/TEKernelMods/MultiProjectile/main.c 移植，功能对齐。
--
-- 功能:
--   玩家手持武器射击(产生弹幕)时, 每一发弹幕额外复制 4 份(默认 5 倍),
--   复制弹道按小角度扇形展开(散射)。敌对/NPC 弹幕同样受影响。
--
-- 实现:
--   Hook Projectile.NewProjectile 的 float 重载(13 参)的 postfix:
--     * result 为新建弹幕的索引, 经 Main.projectile 取对象做过滤;
--     * 过滤条件: 排除钓鱼浮标(bobber)、召唤物(minion)、哨兵(sentry)、
--       钩爪(aiStyle == 7), 其余弹幕均可复制;
--     * 初速过小(原地生成)的弹幕不散射复制;
--     * 用同一方法句柄再次调用 NewProjectile 生成副本, 只把速度按对称扇形旋转;
--     * g_duplicating 等价物 = Lua upvalue duplicating, 防止副本再次触发
--       postfix 造成无限递归。
--
-- 与 C 版的语义差异:
--   * C 版读 args/result 的指针; Lua 里 args 是 1 起始数组、result 是原返回值。
--     对应关系: 速度 = args[4]/args[5], 类型 = args[6], owner = args[9]
--     (C: args[3]/args[4]/args[5]/args[8])。result 只读, postfix 返回值被忽略,
--     本 Mod 不需要改写返回值, 故 1:1 对齐。
--   * C 版 Android 用 Main.get_myPlayer 属性 getter、桌面用 Main.myPlayer 静态字段;
--     Lua 版统一为: 优先静态字段, 取不到再退化到 get_myPlayer() 方法。
--     (本 Mod 的 owner 仅用于日志, 仍按 C 版语义解析。)

mod.meta = { pkg_id = "lzup.lua.multiprojectile", version = "1.0.1" }

local patch = mod.patch
local unpack = table.unpack or unpack

-- ============ 配置 ============
local EXTRA_COPIES = 4          -- 每发额外复制 4 份 => 总共 5 倍
local SPREAD_STEP = 0.13        -- 相邻复制弹道夹角(弧度, 约 7.4°), 总扇形约 ±11°

-- ============ 句柄 ============
local T_MAIN, T_PROJECTILE
local F_main_projectile        -- Main.projectile     (静态 Projectile[])
local F_ai_style               -- Projectile.aiStyle  (int)
local F_minion                 -- Projectile.minion   (bool)
local F_sentry                 -- Projectile.sentry   (bool)
local F_bobber                 -- Projectile.bobber   (bool)
local F_my_player              -- Main.myPlayer       (静态 int 字段; 桌面)
local M_get_my_player          -- Main.get_myPlayer   (静态 int getter; Android)
local M_new_projectile         -- Projectile.NewProjectile(float 重载, 13 参)

-- ============ 状态 ============
local ready = false
local duplicating = false
local logged_once = false
local hook_new_projectile

-- ============ 工具函数 ============

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

local function read_bool(field, inst, default)
    if not field then return default end
    local v = patch.get_field_value(field, inst, "bool")
    if v == nil then return default end
    return v
end

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

-- 从 Main.projectile 取指定索引(0 起始)的弹幕对象; 失败返回 nil
local function get_projectile_at(idx)
    if not F_main_projectile or idx < 0 then return nil end
    local arr = patch.get_field_value(F_main_projectile, nil, "object")
    if not arr then return nil end
    return patch.array_at(arr, idx)
end

-- 是否为"武器弹幕"(可被复制); 过滤非武器来源
local function is_candidate(proj)
    if read_bool(F_bobber, proj, false) then return false end   -- 钓鱼浮标
    if read_bool(F_minion, proj, false) then return false end   -- 召唤物
    if read_bool(F_sentry, proj, false) then return false end   -- 哨兵
    if read_int(F_ai_style, proj, 0) == 7 then return false end -- 钩爪
    return true
end

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

-- 用原参数 + 新速度重新调用 NewProjectile(不改变其余参数)
local function invoke_copy(args, sx, sy)
    local n = #args
    local dup = {}
    for i = 1, n do dup[i] = args[i] end
    dup[4] = sx                     -- SpeedX
    dup[5] = sy                     -- SpeedY
    return patch.invoke(M_new_projectile, unpack(dup, 1, n))
end

local function duplicate(args, sx, sy)
    for j = 0, EXTRA_COPIES - 1 do
        -- 对称扇形: (j - (N-1)/2) * step, N=4 => -1.5,-0.5,+0.5,+1.5
        local angle = (j - (EXTRA_COPIES - 1) * 0.5) * SPREAD_STEP
        local c, s = math.cos(angle), math.sin(angle)
        local nsx = sx * c - sy * s
        local nsy = sx * s + sy * c
        local r = invoke_copy(args, nsx, nsy)
        if r == false then break end          -- 调用失败, 与 C 版 break 一致
    end
end

-- ============ Postfix: Projectile.NewProjectile (float 重载) ============
local function on_new_projectile(instance, args, result)
    if not ready or duplicating then return end
    if not args or result == nil then return end

    -- args[9] = int Owner (仅用于日志; 不再限制来源, NPC/敌对弹幕同样复制)

    -- result 为弹幕索引, 通过 Main.projectile 取对象做非武器过滤
    local idx = result
    if type(idx) ~= "number" or idx < 0 then return end
    local proj = get_projectile_at(idx)
    if not proj or not is_candidate(proj) then return end

    -- 速度(args[4]/args[5])
    local sx, sy = args[4], args[5]
    if type(sx) ~= "number" or type(sy) ~= "number" then return end
    if sx * sx + sy * sy <= 0.0001 then return end  -- 无初速弹幕不散射复制

    duplicating = true
    local ok, err = pcall(duplicate, args, sx, sy)
    duplicating = false
    if not ok then
        mod.error("复制弹幕失败: " .. tostring(err))
        return
    end

    if not logged_once then
        logged_once = true
        mod.info(string.format("5x 多倍弹幕已生效 (owner=%s type=%s)", tostring(args[9]), tostring(args[6])))
    end
end

-- ============ 初始化 ============
function setup()
    T_MAIN = patch.get_type("Terraria", "Main")
    T_PROJECTILE = patch.get_type("Terraria", "Projectile")
    if not T_MAIN or not T_PROJECTILE then
        mod.error("获取类型失败 (Main/Projectile)")
        return
    end

    -- 本地玩家编号(owner 解析)
    F_my_player = find_field(T_MAIN, "myPlayer")
    if not F_my_player then
        M_get_my_player = patch.get_method(T_MAIN, "get_myPlayer", 0)
    end
    if not F_my_player and not M_get_my_player then
        mod.error("获取 Main.myPlayer 失败")
        return
    end

    F_main_projectile = find_field(T_MAIN, "projectile")
    F_ai_style = find_field(T_PROJECTILE, "aiStyle")
    F_minion = find_field(T_PROJECTILE, "minion")
    F_sentry = find_field(T_PROJECTILE, "sentry")
    F_bobber = find_field(T_PROJECTILE, "bobber")
    if not F_main_projectile or not F_ai_style or not F_minion
            or not F_sentry or not F_bobber then
        mod.error("获取字段失败")
        return
    end

    -- Projectile.NewProjectile 的 float 重载(13 参; 版本差异时退化为 12 参)
    M_new_projectile = patch.get_method(T_PROJECTILE, "NewProjectile", 13)
            or patch.get_method(T_PROJECTILE, "NewProjectile", 12)
            or patch.get_method(T_PROJECTILE, "NewProjectile")
    if not M_new_projectile then
        mod.error("获取 Projectile.NewProjectile 方法失败")
        return
    end

    hook_new_projectile = safe_hook(M_new_projectile, { postfix = on_new_projectile }, "Projectile.NewProjectile")
    if not hook_new_projectile then return end

    ready = true
    mod.info("多倍弹幕(5x)已启用")
end

function cleanup()
    if hook_new_projectile then
        pcall(function() hook_new_projectile:remove() end)
        hook_new_projectile = nil
    end
    ready = false
    duplicating = false
    logged_once = false
end

todo_list = { "setup" }
