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
-- AutoFisher —— LuaLoader (Lua) 版
-- 由 KernelLoader(C) 版 Mods/TEKernelMods/AutoFisher/main.c 移植，功能对齐。
--
-- 功能:
--   1. 自动收杆: 鱼上钩(浮标 ai[0]==0 && ai[1]<0 && localAI[1]!=0)后自动收线。
--   2. 自动甩杆: 手持鱼竿且场上没有浮标时自动抛竿(进入钓鱼状态后生效)。
--   3. 循环钓鱼: 两者结合实现全自动挂机钓鱼。
--   4. 选择性收线: 检测到上钩后, 先把"未上钩且空闲"的浮标临时标记 bobber=false,
--      再模拟按下使用键, 让原版 ItemCheck 只回收真正上钩的那枚; 收线结束后在
--      Postfix 里恢复这些浮标(兼容愿者上钩等多倍鱼钩)。
--
-- 实现要点:
--   - Hook Player.ItemCheck 的 prefix + postfix。prefix 返回 false 表示继续执行
--     原方法(LuaLoader 语义: true=跳过, false=执行原方法)。
--   - prefix 直接改写 Player.controlUseItem = true, 让原版 ItemCheck 自然完成
--     抛竿/收线+交鱼, 鱼饵消耗与 NPC 生成全走原版逻辑。
--   - 浮标 ai/localAI 在手机端(PE/IL2CPP)是内联结构体 Float_FixedArray_3,
--     桌面端是托管 float[]。这里按平台分别读取:
--       手机端: get_field_raw + string.unpack("<f", ...)
--       桌面端: 读对象数组 + array_at(..., "float")
--
-- 与原 C 版的实现差异:
--   - C 版把未上钩浮标的裸指针存进数组跨 prefix/postfix 使用; Lua 版按句柄
--     生命周期规则对句柄调用 retain 后再暂存, Postfix 用完后清空。

mod.meta = { pkg_id = "lzup.lua.autofisher", version = "1.1.0" }

local patch = mod.patch

-- ============ 常量 ============
local MAX_HIDDEN_BOBBERS = 64
local AI_STYLE_BOBBER = 61
local CAST_COOLDOWN_FRAMES = 15

-- ============ 句柄 ============
local T_MAIN, T_PLAYER, T_ITEM, T_PROJECTILE, T_ENTITY

local F_who_am_i
local F_inventory
local F_fishing_pole
local F_control_use_item
local F_item_animation
local F_projectile
local F_active
local F_owner
local F_ai_style
local F_bobber
local F_ai
local F_local_ai

local F_my_player              -- Main.myPlayer (桌面端为静态字段)
local M_get_my_player          -- Main.get_myPlayer() (手机端为属性)
local M_get_selected_item      -- Player.get_selectedItem()
local F_selected_item          -- 兜底: Player.selectedItem 若为字段

-- ============ 状态 ============
local ready = false
local fishing = false
local cast_cooldown = 0
local selective_reel = false
local hidden = {}              -- 本帧被临时隐藏的浮标(retain 过的句柄)

-- ============ 工具 ============
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

local function get_obj(field, instance)
    if not field then return nil end
    return patch.get_field_value(field, instance, "object")
end

local function get_int(field, instance, default)
    if not field then return default end
    local v = patch.get_field_value(field, instance, "int32")
    if v == nil then return default end
    return v
end

local function get_bool(field, instance, default)
    if not field then return default end
    local v = patch.get_field_value(field, instance, "bool")
    if v == nil then return default end
    return v
end

local function safe_set(field, instance, value, ty)
    if not field then return false end
    return (pcall(patch.set_field_value, field, instance, value, ty))
end

-- ============ 字段读取(跨平台) ============
--- 本地玩家编号; 失败返回 nil
local function local_player_index()
    if F_my_player then
        return patch.get_field_value(F_my_player, nil, "int32")
    end
    if M_get_my_player then
        local v = patch.invoke(M_get_my_player)
        if type(v) == "number" then return v end
    end
    return nil
end

--- 手持物品栏位索引; 失败返回 nil
local function selected_item_index(player)
    if M_get_selected_item then
        local v = patch.invoke(M_get_selected_item, player)
        if type(v) == "number" then return v end
        return nil
    end
    if F_selected_item then
        return patch.get_field_value(F_selected_item, player, "int32")
    end
    return nil
end

--- 读取弹幕 ai/localAI 第 idx 个 float
local function proj_ai_float(proj, field, idx)
    if not proj or not field then return nil end
    if mod.platform == "android" then
        -- 内联结构体: 直接取原始字节, 12 字节够放 3 个 float
        local raw = patch.get_field_raw(field, proj, 12)
        if not raw or #raw < idx * 4 + 4 then return nil end
        return (string.unpack("<f", raw, idx * 4 + 1))
    end
    -- 托管 float[]
    local arr = patch.get_field_value(field, proj, "object")
    if not arr then return nil end
    return patch.array_at(arr, idx, "float")
end

--- 浮标是否已上钩(与 C 版 IsBobberBiting 一致)
local function is_bobber_biting(proj)
    if not proj or not F_ai or not F_local_ai then return false end
    local ai0 = proj_ai_float(proj, F_ai, 0)
    local ai1 = proj_ai_float(proj, F_ai, 1)
    local lai1 = proj_ai_float(proj, F_local_ai, 1)
    return ai0 ~= nil and ai0 == 0.0
        and ai1 ~= nil and ai1 < 0.0
        and lai1 ~= nil and lai1 ~= 0.0
end

local function main_projectile_array()
    if not F_projectile then return nil end
    return patch.get_field_value(F_projectile, nil, "object")
end

--- 扫描本地玩家的浮标, 返回 (数量, 是否有鱼上钩)
local function scan_local_bobbers(my)
    local count, bite = 0, false
    if not F_ai_style then return count, bite end

    local arr = main_projectile_array()
    if not arr then return count, bite end

    local n = patch.array_length(arr)
    for i = 0, n - 1 do
        local proj = patch.array_at(arr, i)
        if proj and get_int(F_ai_style, proj, -1) == AI_STYLE_BOBBER then
            local owner_ok = (not F_owner) or get_int(F_owner, proj, -999) == my
            local active_ok = (not F_active) or get_bool(F_active, proj, false)
            if owner_ok and active_ok then
                count = count + 1
                if is_bobber_biting(proj) then
                    bite = true
                end
            end
        end
    end
    return count, bite
end

--- 把"未上钩且等待中(ai[0]==0)"的浮标临时标记 bobber=false
local function hide_non_biting_bobbers(my)
    hidden = {}
    if not F_bobber or not F_ai_style or not F_ai then return end

    local arr = main_projectile_array()
    if not arr then return end

    local n = patch.array_length(arr)
    for i = 0, n - 1 do
        local proj = patch.array_at(arr, i)
        if proj and get_int(F_ai_style, proj, -1) == AI_STYLE_BOBBER then
            local owner_ok = (not F_owner) or get_int(F_owner, proj, -999) == my
            local active_ok = (not F_active) or get_bool(F_active, proj, false)
            if owner_ok and active_ok then
                local ai0 = proj_ai_float(proj, F_ai, 0)
                -- 只处理等待中的浮标(已在回收的 ai[0]!=0 不动)
                if ai0 ~= nil and ai0 == 0.0 and not is_bobber_biting(proj) then
                    if safe_set(F_bobber, proj, false, "bool") then
                        if #hidden < MAX_HIDDEN_BOBBERS then
                            -- retain 成 GC 托管句柄, 可安全跨到 postfix 使用
                            hidden[#hidden + 1] = patch.retain(proj)
                        else
                            safe_set(F_bobber, proj, true, "bool")
                        end
                    end
                end
            end
        end
    end
end

--- 恢复本帧被临时隐藏的浮标
local function restore_hidden_bobbers()
    if #hidden == 0 then
        hidden = {}
        return
    end
    for i = 1, #hidden do
        local proj = hidden[i]
        if proj then
            -- 防止弹幕槽位被复用: 仍应是浮标(aiStyle==61)
            if (not F_ai_style) or get_int(F_ai_style, proj, -1) == AI_STYLE_BOBBER then
                safe_set(F_bobber, proj, true, "bool")
            end
        end
    end
    hidden = {}
end

-- ============ Hook 回调 ============
local function item_check_prefix(instance, args, result)
    if not ready or not instance then return false end

    -- 每次进入 ItemCheck 先清空上一帧的临时隐藏记录(Postfix 已恢复, 这里兜底)
    hidden = {}

    local my = local_player_index()
    if not my or my < 0 then return false end
    if get_int(F_who_am_i, instance, -1) ~= my then return false end

    local sel = selected_item_index(instance)
    if not sel or sel < 0 then return false end
    local inv = get_obj(F_inventory, instance)
    if not inv then return false end
    if sel >= patch.array_length(inv) then return false end

    local item = patch.array_at(inv, sel)
    if not item then return false end
    if get_int(F_fishing_pole, item, 0) <= 0 then
        -- 手上没有鱼竿: 结束自动钓鱼会话
        fishing = false
        return false
    end

    local count, bite = scan_local_bobbers(my)
    if count > 0 then
        fishing = true
        -- 鱼已上钩: 模拟按下使用键, 原版会自动收线并交鱼
        if bite and get_int(F_item_animation, instance, 0) <= 0 then
            if selective_reel then hide_non_biting_bobbers(my) end
            safe_set(F_control_use_item, instance, true, "bool")
        end
        return false
    end

    -- 没有浮标: 只有进入钓鱼状态后才自动抛竿
    if not fishing then return false end
    if cast_cooldown > 0 then
        cast_cooldown = cast_cooldown - 1
        return false
    end
    cast_cooldown = CAST_COOLDOWN_FRAMES
    if get_int(F_item_animation, instance, 0) > 0 then return false end

    safe_set(F_control_use_item, instance, true, "bool")
    return false
end

local function item_check_postfix(instance, args, result)
    restore_hidden_bobbers()
end

-- ============ 初始化 ============
function setup()
    T_MAIN = patch.get_type("Terraria", "Main")
    T_PLAYER = patch.get_type("Terraria", "Player")
    T_ITEM = patch.get_type("Terraria", "Item")
    T_PROJECTILE = patch.get_type("Terraria", "Projectile")
    T_ENTITY = patch.get_type("Terraria", "Entity")
    if not T_MAIN or not T_PLAYER or not T_ITEM or not T_PROJECTILE or not T_ENTITY then
        mod.error("获取类型失败 (Main/Player/Item/Projectile/Entity), 模组未启用")
        return
    end

    -- 属性/字段解析
    F_my_player = patch.get_field(T_MAIN, "myPlayer")
    if not F_my_player then
        M_get_my_player = patch.get_method(T_MAIN, "get_myPlayer", 0)
    end
    M_get_selected_item = patch.get_method(T_PLAYER, "get_selectedItem", 0)
    if not M_get_selected_item then
        F_selected_item = patch.get_field(T_PLAYER, "selectedItem")
    end

    -- 字段
    F_who_am_i = find_field(T_ENTITY, "whoAmI") or find_field(T_PLAYER, "whoAmI")
    F_inventory = find_field(T_PLAYER, "inventory")
    F_fishing_pole = find_field(T_ITEM, "fishingPole")
    F_control_use_item = find_field(T_PLAYER, "controlUseItem")
    F_item_animation = find_field(T_PLAYER, "itemAnimation")
    F_projectile = find_field(T_MAIN, "projectile")
    F_active = find_field(T_PROJECTILE, "active")
    F_owner = find_field(T_PROJECTILE, "owner")
    F_ai_style = find_field(T_PROJECTILE, "aiStyle")
    F_bobber = find_field(T_PROJECTILE, "bobber")
    F_ai = find_field(T_PROJECTILE, "ai")
    F_local_ai = find_field(T_PROJECTILE, "localAI")

    -- 选择性收线依赖 bobber 字段; 解析失败则退化为原版全局收线
    selective_reel = (F_bobber ~= nil)

    if not F_inventory or not F_fishing_pole or not F_control_use_item
        or not F_item_animation or not F_projectile or not F_ai_style then
        mod.error("获取关键字段失败, 模组未启用")
        return
    end

    -- Hook Player.ItemCheck() (每帧调用, 0 参数)
    local item_check = patch.get_method(T_PLAYER, "ItemCheck", 0)
        or patch.get_method(T_PLAYER, "ItemCheck")
    if not item_check then
        mod.error("获取 Player.ItemCheck 方法失败, 模组未启用")
        return
    end

    local ok, err = pcall(patch.install_hook, item_check, {
        prefix = item_check_prefix,
        postfix = item_check_postfix,
    })
    if not ok then
        mod.error("安装 ItemCheck Hook 失败：" .. tostring(err))
        return
    end

    ready = true
    mod.info(string.format("成功 Hook Player.ItemCheck, 自动钓鱼已启用 (选择性收线=%s)",
            selective_reel and "开" or "关"))
end

todo_list = { "setup" }
