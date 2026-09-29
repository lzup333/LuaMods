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
-- PocketGear —— LuaLoader(Lua) 版
-- 由 KernelLoader(C) 版 Mods/TEKernelMods/PocketGear/main.c 移植，功能对齐。
-- 原版作者: 雨鹜 https://github.com/2099123771/PocketGear
--
-- 功能: 使物品栏以及各种背包(银行/保险箱/护卫保险箱/虚空保险库)中的
--       饰品与装备效果生效(翅膀除外)。
--
-- 做法: postfix Hook Player.ResetEffects, 原版每帧重置装备效果后,
--       重新对主背包与各银行容器中的每个物品调用
--       ApplyEquipFunctional / GrantPrefixBenefits / GrantArmorBenefits。
--
-- 注: 手机端 Player.bank/bank2/bank3/bank4 的类型是 InventoryStorage (内含 Item[] item 字段),
--     PC 端是 Chest。

mod.meta = { pkg_id = "lzup.lua.pocketgear", version = "1.3.0" }

local patch = mod.patch

-- ============ 状态 ============
local ready = false

-- ============ 类型句柄 ============
local T_PLAYER, T_STORAGE

-- ============ 字段句柄 ============
local F_inventory     -- Player.inventory (Item[])
local F_bank, F_bank2, F_bank3, F_bank4  -- Player.bank.. (InventoryStorage/Chest)
local F_storage_item  -- InventoryStorage.item / Chest.item (Item[])

-- ============ 方法句柄 ============
local M_apply_equip   -- Player.ApplyEquipFunctional(int, Item)
local M_grant_prefix  -- Player.GrantPrefixBenefits(Item)
local M_grant_armor   -- Player.GrantArmorBenefits(Item)

-- ============ 工具 ============
-- 读取对象字段(引用类型)并返回对象句柄(借用)
local function get_obj_field(field, instance)
    if not field then return nil end
    return patch.get_field_value(field, instance, "object")
end

local function equip_methods_ready()
    return M_apply_equip and M_grant_prefix and M_grant_armor
end

-- 逐个物品应用装备效果
local function process_inventory(player, items, skip_last_slot)
    if not player or not items then return end
    if not equip_methods_ready() then return end

    local count = patch.array_length(items)
    if count == 0 then return end
    if skip_last_slot and count > 0 then count = count - 1 end

    for i = 0, count - 1 do
        local item = patch.array_at(items, i)
        if item then
            -- ApplyEquipFunctional 内部访问 hideVisibleAccessory[itemSlot](长度10),
            -- 背包/银行槽位索引可能越界, 需限制在 0..9
            local eq_slot = i
            if eq_slot < 0 then eq_slot = 0 end
            if eq_slot > 9 then eq_slot = 9 end

            patch.invoke(M_apply_equip, player, eq_slot, item)
            patch.invoke(M_grant_prefix, player, item)
            patch.invoke(M_grant_armor, player, item)
        end
    end
end

local function apply_pocket_effects(player)
    if not ready or not player then return end
    if not equip_methods_ready() then
        mod.error("装备方法未解析, 跳过")
        return
    end

    -- 主背包 (跳过鼠标/垃圾槽)
    process_inventory(player, get_obj_field(F_inventory, player), true)

    -- 各类银行容器
    process_inventory(player, get_obj_field(F_storage_item, get_obj_field(F_bank, player)), false)
    process_inventory(player, get_obj_field(F_storage_item, get_obj_field(F_bank2, player)), false)
    process_inventory(player, get_obj_field(F_storage_item, get_obj_field(F_bank3, player)), false)
    process_inventory(player, get_obj_field(F_storage_item, get_obj_field(F_bank4, player)), false)
end

-- ============ Hook: Player.ResetEffects (Postfix) ============
local function on_reset_effects(instance, args, result)
    apply_pocket_effects(instance)
end

-- ============ 生命周期 ============
function setup()
    mod.info("初始化口袋装备模组")

    T_PLAYER = patch.get_type("Terraria", "Player")
    -- Android: 银行容器为 InventoryStorage; 桌面端: Chest
    T_STORAGE = patch.get_type("Terraria", "InventoryStorage")
        or patch.get_type("Terraria", "Chest")
    if not T_PLAYER or not T_STORAGE then
        mod.error("获取类型失败 (Player/InventoryStorage|Chest)")
        return
    end

    -- 字段
    F_inventory = patch.get_field(T_PLAYER, "inventory")
    F_bank = patch.get_field(T_PLAYER, "bank")
    F_bank2 = patch.get_field(T_PLAYER, "bank2")
    F_bank3 = patch.get_field(T_PLAYER, "bank3")
    F_bank4 = patch.get_field(T_PLAYER, "bank4")
    F_storage_item = patch.get_field(T_STORAGE, "item")
    if not F_inventory or not F_bank or not F_bank2 or
        not F_bank3 or not F_bank4 or not F_storage_item then
        mod.error("获取背包字段失败")
        return
    end

    -- 装备方法
    M_apply_equip = patch.get_method(T_PLAYER, "ApplyEquipFunctional", 2)
        or patch.get_method(T_PLAYER, "ApplyEquipFunctional")
    M_grant_prefix = patch.get_method(T_PLAYER, "GrantPrefixBenefits", 1)
        or patch.get_method(T_PLAYER, "GrantPrefixBenefits")
    M_grant_armor = patch.get_method(T_PLAYER, "GrantArmorBenefits", 1)
        or patch.get_method(T_PLAYER, "GrantArmorBenefits")
    mod.info(string.format("equip=%s prefix=%s armor=%s",
        tostring(M_apply_equip ~= nil), tostring(M_grant_prefix ~= nil), tostring(M_grant_armor ~= nil)))

    -- ResetEffects (0 参数)
    local reset_method = patch.get_method(T_PLAYER, "ResetEffects", 0)
        or patch.get_method(T_PLAYER, "ResetEffects")
    if not reset_method then
        mod.error("获取 ResetEffects 方法失败")
        return
    end

    ready = true
    local ok, err = pcall(patch.install_hook, reset_method, { postfix = on_reset_effects })
    if not ok then
        ready = false
        mod.error(string.format("安装 ResetEffects Hook 失败：%s", tostring(err)))
        return
    end

    mod.info("成功 Hook ResetEffects, 口袋装备已启用")
end

function cleanup()
    ready = false
    M_apply_equip = nil
    M_grant_prefix = nil
    M_grant_armor = nil
    F_inventory = nil
    F_bank, F_bank2, F_bank3, F_bank4 = nil, nil, nil, nil
    F_storage_item = nil
    T_STORAGE = nil
    mod.info("清理模组")
end

todo_list = { "setup" }
