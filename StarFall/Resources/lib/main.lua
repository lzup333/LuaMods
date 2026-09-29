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
-- StarFall —— LuaLoader 版（星坠 / 坠落之星雨）
-- 由 KernelLoader(C) 版 Mods/TEKernelMods/StarFall/main.c 移植，功能对齐。
--
-- 功能：夜晚原版每生成一颗坠落之星(ProjectileID.FallingStar = 12)时，
--       额外复制 299 份（共 300 倍），复制体速度在扇形张角内均匀展开。
--
-- 实现：Hook Projectile.NewProjectile 的 float 重载（13 参）Postfix。
--       当 Type == 12 且 Owner == 本地玩家时，读取原始参数，把速度按扇形
--       角度旋转后用同一方法句柄再调用 299 次。
--       - 只处理本地玩家的坠落之星；
--       - 其余弹幕一律不动；
--       - duplicating 做重入保护，避免副本再次触发 Postfix 递归。
--
-- 注意：本 Mod 与「多倍弹幕 (MultiProjectile)」同时启用会相乘，可能触顶
--       1000 弹幕上限，不建议同时启用。
--
-- 与 C 版的差异：
--   C 版 postfix 通过 patchlib_method_invoke_args 重入调用；Lua 版用
--   mod.patch.invoke 复刻。NewProjectile 的 13 参重载无结构体参数/返回值，
--   故 invoke 的结构体限制不影响本 Mod，可 1:1 复刻。

mod.meta = { pkg_id = "lzup.lua.starfall", version = "2.1.0" }

local patch = mod.patch
local unpack_fn = table.unpack or unpack

-- ============ 配置 ============
local FALLING_STAR_TYPE = 12    -- ProjectileID.FallingStar
local EXTRA_COPIES      = 299   -- 每颗额外复制 299 份 => 共 300 倍
local FAN_SPREAD        = 1.2   -- 复制体速度扇形总张角（弧度，约 ±34°）
local PROJ_ARGS         = 13    -- float 重载 NewProjectile 参数个数

-- ============ 状态 ============
local ready = false
local duplicating = false       -- 正在复制副本（重入保护）
local logged_once = false       -- 复制日志只打一次

-- ============ 句柄 ============
local M_new_projectile          -- Projectile.NewProjectile（float 重载，13 参）
local F_my_player               -- Main.myPlayer（桌面/字段）
local M_get_my_player           -- Main.get_myPlayer（Android/属性 getter）

-- ============ 本地玩家解析 ============
--- 读取本地玩家编号；失败返回 -1
local function local_player_index()
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

-- ============ Hook: Projectile.NewProjectile (Postfix) ============
-- Lua 的 args 表为 1 起始，对应 C 的 0 起始 args：
--   args[1]=source   args[2]=X       args[3]=Y
--   args[4]=SpeedX   args[5]=SpeedY  args[6]=Type
--   args[7]=Damage   args[8]=KnockBack args[9]=Owner
--   args[10..13]=ai0..ai3
local function on_new_projectile(instance, args, result)
    if not ready or duplicating then return end
    if not args then return end

    -- Type：只处理坠落之星
    local proj_type = args[6]
    if proj_type ~= FALLING_STAR_TYPE then return end

    -- Owner：仅本地玩家的坠落之星
    local owner = args[9]
    local my_player = local_player_index()
    if my_player < 0 or owner ~= my_player then return end

    -- SpeedX / SpeedY：无初速不散射复制
    local sx = args[4]
    local sy = args[5]
    if type(sx) ~= "number" or type(sy) ~= "number" then return end
    if sx * sx + sy * sy <= 0.0001 then return end

    -- 复制除速度外的全部参数（source 等对象句柄在本回调内仍然有效）
    local base = {}
    for k = 1, PROJ_ARGS do base[k] = args[k] end

    duplicating = true
    local ok, err = pcall(function()
        for j = 0, EXTRA_COPIES - 1 do
            -- 对称扇形：复制体速度在 ±FAN_SPREAD/2 范围内均匀展开
            local angle = (j - (EXTRA_COPIES - 1) * 0.5) / (EXTRA_COPIES - 1) * FAN_SPREAD
            local c = math.cos(angle)
            local s = math.sin(angle)
            local nsx = sx * c - sy * s
            local nsy = sx * s + sy * c

            -- 复制参数表，只替换速度
            local call = {}
            for k = 1, PROJ_ARGS do call[k] = base[k] end
            call[4] = nsx
            call[5] = nsy

            patch.invoke(M_new_projectile, unpack_fn(call, 1, PROJ_ARGS))
        end
    end)
    duplicating = false

    if not ok then
        mod.warn("复制坠落之星失败：" .. tostring(err))
        return
    end

    if not logged_once then
        logged_once = true
        mod.info(string.format("300x 星坠已生效 (owner=%d)", owner))
    end
end

-- ============ 小工具 ============
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

-- ============ 生命周期 ============
function setup()
    local main_type = patch.get_type("Terraria", "Main")
    local projectile_type = patch.get_type("Terraria", "Projectile")
    if not main_type or not projectile_type then
        mod.error("获取类型失败 (Main/Projectile)，模组未启用")
        return
    end

    -- 本地玩家解析：优先静态字段 Main.myPlayer，其次属性 getter Main.get_myPlayer
    F_my_player = patch.get_field(main_type, "myPlayer")
    if not F_my_player then
        M_get_my_player = patch.get_method(main_type, "get_myPlayer", 0)
    end
    if not F_my_player and not M_get_my_player then
        mod.error("解析 Main.myPlayer 失败，模组未启用")
        return
    end

    -- NewProjectile 的 float 重载（13 参）；C 版失败时退回按方法名取
    M_new_projectile = patch.get_method(projectile_type, "NewProjectile", PROJ_ARGS)
            or patch.get_method(projectile_type, "NewProjectile")
    if not safe_hook(M_new_projectile, { postfix = on_new_projectile }, "Projectile.NewProjectile") then
        mod.error("无法 Hook Projectile.NewProjectile，星坠未启用")
        return
    end

    ready = true
    mod.info("星坠已启用 (300x)")
end

todo_list = { "setup" }
