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
-- AlwaysDrown —— 永远溺水（LuaLoader 版）
-- 效果：不戴鱼缸，也一直有鱼缸的溺水效果。
--
-- 原理（保留原版完整逻辑，所以氧气条/气泡/扣血/死亡全走原版）：
--   原版 Player.CheckDrowning() 里有一句硬编码：
--       Item effectiveArmor = GetEffectiveArmor(0);      // 取头甲槽
--       if (effectiveArmor.type == 250 || 4275)           // FishBowl / GoldGoldfishBowl
--           flag = true;                                  // 强制进入溺水
--   我们 Hook Player.CheckDrowning：
--     * prefix  ：临时把玩家头甲槽那一格 Item 的 type 改成 250（并保证 stack>0 非空气）；
--     * 返回 false，让原版 CheckDrowning 继续跑 —— 它自己就会看到“鱼缸” => flag=true；
--     * postfix ：把 type / stack 改回原值。
--   这样原版溺水逻辑一字未改，氧气条与死亡判定都是原生的。

mod.meta = { pkg_id = "lzup.lua.alwaysdrown", version = "1.0.0" }

local patch = mod.patch

-- ============ 配置 ============
-- 只骗原版“头甲是鱼缸”，不改实际装备。想改成“背包里有鱼缸才生效”，
-- 可在此加一个背包扫描开关（见文件末尾注释）。
local FAKE_HEAD_TYPE = 250      -- 250 = FishBowl, 4275 = GoldGoldfishBowl
local ENABLE = true             -- 总开关

-- ============ 句柄 ============
local T_PLAYER, T_MAIN
local F_armor          -- Player.armor      (Item[])
local F_item_type      -- Item.type         (int32)
local F_item_stack     -- Item.stack        (int32)
local F_whoami         -- Player.whoAmI     (int32)
local F_my_player      -- Main.myPlayer     (静态 int32, 桌面)
local M_my_player      -- Main.get_myPlayer (静态 int32 getter, Android)

-- ============ 状态 ============
local ready = false
local swapped = false          -- 当前是否处于“已把 type 改成鱼缸”的窗口
local saved_type, saved_stack  -- 头甲槽 Item 原始 type / stack

-- ============ 工具 ============
local function get_obj(field, instance)
    if not field then return nil end
    return patch.get_field_value(field, instance, "object")
end

local function local_player_id()
    if F_my_player then
        return patch.get_field_value(F_my_player, nil, "int32")
    end
    if M_my_player then
        return patch.invoke(M_my_player)
    end
    return nil
end

local function is_local(player)
    if not F_whoami then return true end
    local me = patch.get_field_value(F_whoami, player, "int32")
    local my = local_player_id()
    if me == nil or my == nil then return true end
    return me == my
end

-- 取当前头甲槽 Item 句柄（借用）
local function head_item(player)
    local arr = get_obj(F_armor, player)
    if not arr then return nil end
    return patch.array_at(arr, 0)
end

-- 还原头甲槽 Item
local function restore_head(player)
    if not swapped then return end
    swapped = false
    local head = head_item(player)
    if not head then return end
    if saved_type ~= nil then
        patch.set_field_value(F_item_type, head, saved_type, "int32")
    end
    if saved_stack ~= nil then
        patch.set_field_value(F_item_stack, head, saved_stack, "int32")
    end
end

-- ============ Hook: Player.CheckDrowning (Prefix + Postfix) ============
local function prefix_check_drowning(instance, args, result)
    if not ENABLE then return false end
    if not ready or not instance then return false end
    if not is_local(instance) then return false end

    -- 上一帧 postfix 万一没跑到，先补救，别把头甲永久改成鱼缸
    if swapped then restore_head(instance) end

    local head = head_item(instance)
    if not head then return false end

    saved_type = patch.get_field_value(F_item_type, head, "int32")
    saved_stack = patch.get_field_value(F_item_stack, head, "int32")
    if saved_type == nil then return false end

    -- 骗原版：头甲是鱼缸；同时保证非空气（IsAir = type<=0 或 stack<=0）
    patch.set_field_value(F_item_type, head, FAKE_HEAD_TYPE, "int32")
    if (saved_stack or 0) <= 0 then
        patch.set_field_value(F_item_stack, head, 1, "int32")
    end
    swapped = true

    return false   -- 继续执行原版 CheckDrowning：它会看到鱼缸 => 强制溺水
end

local function postfix_check_drowning(instance, args, result)
    if not swapped or not instance then return end
    restore_head(instance)
end

-- ============ 生命周期 ============
function setup()
    T_PLAYER = patch.get_type("Terraria", "Player")
    T_MAIN = patch.get_type("Terraria", "Main")
    if not T_PLAYER then
        mod.error("找不到类型 Terraria.Player，模组未启用")
        return
    end

    F_armor = patch.get_field(T_PLAYER, "armor")
    F_whoami = patch.get_field(T_PLAYER, "whoAmI")
    if T_MAIN then
        F_my_player = patch.get_field(T_MAIN, "myPlayer")
        if not F_my_player then
            M_my_player = patch.get_method(T_MAIN, "get_myPlayer", 0)
        end
    end

    local item_type = patch.get_type("Terraria", "Item")
    if item_type then
        F_item_type = patch.get_field(item_type, "type")
        F_item_stack = patch.get_field(item_type, "stack")
    end

    if not F_armor or not F_item_type then
        mod.error("获取字段失败 (Player.armor / Item.type)，模组未启用")
        return
    end

    local check_drowning = patch.get_method(T_PLAYER, "CheckDrowning", 0)
            or patch.get_method(T_PLAYER, "CheckDrowning", 1)
            or patch.get_method(T_PLAYER, "CheckDrowning")
    if not check_drowning then
        mod.error("找不到 Player.CheckDrowning，模组未启用")
        return
    end

    local ok, err = pcall(patch.install_hook, check_drowning,
            { prefix = prefix_check_drowning, postfix = postfix_check_drowning })
    if not ok then
        mod.error("安装 CheckDrowning Hook 失败：" .. tostring(err))
        return
    end

    ready = true
    mod.info("AlwaysDrown 已启用（原版鱼缸溺水效果）")
end

function cleanup()
    ready = false
    swapped = false
    saved_type, saved_stack = nil, nil
end

todo_list = { "setup" }

-- 备注：若想改成“背包/银行里有鱼缸才生效”，在 setup 里解析 Player.inventory
-- 与 bank..bank4（参考 PocketGear），在 prefix 里先扫描到鱼缸再 swap，否则直接
-- return false 走原版即可。
