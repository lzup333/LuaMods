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
-- VoluntaryHook (愿者上钩 / 多倍鱼钩) —— LuaLoader 版
-- 由 KernelLoader(C) 版 Mods/TEKernelMods/VoluntaryHook/main.c 移植，功能对齐。
--
-- 功能:
--   抛出鱼钩后, 鱼钩数量固定为 5 倍: 每抛出一枚浮标, 立即额外复制 4 枚。
--   鱼线与鱼钩成对出现, 收线/上钩判定/交鱼完全走原版逻辑。
--
-- 实现:
--   Hook Projectile.NewProjectile 的 float 重载(13 参)的 postfix:
--     * result 为新建弹幕的索引, 经 Main.projectile 取对象, 仅处理 bobber(钓鱼浮标);
--     * 仅处理本地玩家(Main.myPlayer)抛出的浮标(args[9] == owner);
--     * 用同一方法句柄再次调用 NewProjectile 生成 4 个副本, 只把速度向量
--       按对称扇形旋转(不改变起点/类型/伤害/ai), 让落点错开;
--     * g_duplicating 等价物 = Lua upvalue duplicating, 防止副本再次触发 postfix
--       造成无限递归。
--
-- 与 C 版的语义差异:
--   * C 版 patchlib_method_invoke_args 直接传参数指针数组; Lua 版把 args 表的
--     每个值原样复制, 替换速度分量后用 patch.invoke 重新调用同一方法。
--     args 在 Lua 里是 1 起始数组(对应 C 的 0 起始): 速度 = args[4]/args[5],
--     类型 = args[6], owner = args[9]。
--   * C 版 Android 用 Main.get_myPlayer 属性 getter、桌面用 Main.myPlayer 静态字段;
--     Lua 版统一为: 优先静态字段, 取不到再退化到 get_myPlayer() 方法。
--   * postfix 返回值被 LuaLoader 忽略, 本 Mod 不需要改写返回值, 故 1:1 对齐。

mod.meta = { pkg_id = "lzup.lua.voluntaryhook", version = "1.1.0" }

local patch = mod.patch
local unpack = table.unpack or unpack

-- ============ 配置 ============
local EXTRA_COPIES = 4          -- 每次额外复制 4 枚 => 固定 5 倍
local SPREAD_STEP = 0.10        -- 相邻复制鱼钩的速度夹角(弧度, 约 5.7°)

-- ============ 句柄 ============
local T_MAIN, T_PROJECTILE
local F_main_projectile        -- Main.projectile  (静态 Projectile[])
local F_bobber                 -- Projectile.bobber(bool)
local F_my_player              -- Main.myPlayer    (静态 int 字段; 桌面)
local M_get_my_player          -- Main.get_myPlayer(静态 int getter; Android)
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

-- 生成 4 个副本(重入由调用方用 duplicating 保护)
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

    -- result 为弹幕索引, 通过 Main.projectile 取对象过滤: 仅处理钓鱼浮标
    local idx = result
    if type(idx) ~= "number" or idx < 0 then return end
    local proj = get_projectile_at(idx)
    if not proj then return end
    if not read_bool(F_bobber, proj, false) then return end

    -- 仅本地玩家抛出的浮标
    local my = local_player_id()
    if my == nil or my < 0 then return end
    local owner = args[9]                      -- C args[8] = int Owner
    if owner ~= my then return end

    -- 读取原始速度(C args[3]/args[4])
    local sx, sy = args[4], args[5]
    if type(sx) ~= "number" or type(sy) ~= "number" then return end

    duplicating = true
    local ok, err = pcall(duplicate, args, sx, sy)
    duplicating = false
    if not ok then
        mod.error("复制鱼钩失败: " .. tostring(err))
        return
    end

    if not logged_once then
        logged_once = true
        mod.info(string.format("5x 多倍鱼钩已生效 (owner=%d type=%d)", owner, args[6]))
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

    -- 本地玩家编号
    F_my_player = find_field(T_MAIN, "myPlayer")
    if not F_my_player then
        M_get_my_player = patch.get_method(T_MAIN, "get_myPlayer", 0)
    end
    if not F_my_player and not M_get_my_player then
        mod.error("解析 Main.myPlayer 失败")
        return
    end

    F_main_projectile = find_field(T_MAIN, "projectile")
    F_bobber = find_field(T_PROJECTILE, "bobber")
    if not F_main_projectile or not F_bobber then
        mod.error("获取字段失败 (Main.projectile / Projectile.bobber)")
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
    mod.info("愿者上钩(5x 多倍鱼钩)已启用")
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
