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
-- FreeCraft —— LuaLoader (Lua) 版
-- 由 KernelLoader(C) 版 Mods/TEKernelMods/FreeCraft/main.c 移植，功能对齐。
--
-- 功能:
--   1. 无需工作站/环境: 清除所有配方的 requiredTile / needWater / needHoney /
--      needLava / needTorchGodsFavor / needSnowBiome / needGraveyardBiome /
--      needMechdusa 前置, 并拦截 Recipe.PlayerMeetsEnvironmentConditions 恒通过。
--   2. 无需对应材料: 拦截 Recipe.CollectedEnoughItemsToCraft 恒通过。
--   3. 合成不消耗材料: 跳过 Recipe.GetIngredientsForOneCraft(原版据此收集本次
--      要消耗的材料列表, 列表为空 -> 不扣材料 -> 免费发放产物)。
--   4. 手机端合成界面的工作站过滤: 跳过 Recipe.SetCraftingFilter
--      (过滤器保持为空 -> get_TileFilter 返回 -1 -> 显示全部配方)。
--
-- 与原 C 版的实现差异(说明):
--   注: C 版把 Recipe.requiredItemQuickLookup(RequiredItemEntry[] 内联结构体数组,
--     每项 8 字节)直接按内存清零, 让配方材料检查恒通过。LuaLoader 1.3.0 起提供
--     mod.patch.array_set_raw, 现已在 make_free 里逐项写回 8 字节零值清空材料表
--     (已用 mod.patch.array_set_raw 实现, 与 C 版桌面端 patchlib_array_set 等价);
--     同时保留 CollectedEnoughItemsToCraft 前缀拦截作为兜底, 保证在取不到句柄或
--     旧版 LuaLoader 无 array_set_raw 时仍等价于"无需材料"。
--   postfix 在 LuaLoader 中无法修改返回值, 故 C 版用 postfix 强改返回值的两个
--   检查(C 的桌面端做法)在 Lua 中统一改为 prefix 返回 (true, true) 接管返回值。

mod.meta = { pkg_id = "lzup.lua.freecraft", version = "1.1.0" }

local patch = mod.patch

-- ============ 句柄 ============
local T_MAIN, T_RECIPE, T_ITEM
local F_main_recipe           -- Main.recipe (Recipe[], 静态)
local F_recipe_create_item    -- Recipe.createItem (Item)
local F_item_type             -- Item.type (int32)
local F_required_tile         -- Recipe.requiredTile (int32)
local F_need_water            -- Recipe.needWater (bool)
local F_need_honey            -- Recipe.needHoney (bool)
local F_need_lava             -- Recipe.needLava (bool)
local F_need_torch            -- Recipe.needTorchGodsFavor (bool)
local F_need_snow             -- Recipe.needSnowBiome (bool)
local F_need_grave            -- Recipe.needGraveyardBiome (bool)
local F_need_mech             -- Recipe.needMechdusa (bool)
local F_quick_lookup          -- Recipe.requiredItemQuickLookup (RequiredItemEntry[])

local verified = false

-- Recipe.requiredItemQuickLookup: RequiredItemEntry[] {int itemIdOrRecipeGroup; int stack;}
-- 内联结构体数组, 每项 8 字节; 长度 = Recipe.maxRequirements(15), 与 C 版一致。
local QUICK_ENTRY_SIZE = 8
local QUICK_MAX_LEN = 15
local QUICK_ZERO = string.rep("\0", QUICK_ENTRY_SIZE)

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

local function safe_hook(m, spec, label, optional)
    if not m then
        if optional then
            mod.warn("未找到钩子方法(" .. label .. ")，跳过")
        else
            mod.error("安装钩子失败(" .. label .. ")：方法为空")
        end
        return false
    end
    local ok, err = pcall(patch.install_hook, m, spec)
    if not ok then
        mod.error("安装钩子失败(" .. label .. ")：" .. tostring(err))
        return false
    end
    return true
end

-- 读取引用类型字段(返回对象句柄)
local function get_obj(field, instance)
    if not field then return nil end
    return patch.get_field_value(field, instance, "object")
end

local function safe_set(field, instance, value, ty)
    if not field then return false end
    return (pcall(patch.set_field_value, field, instance, value, ty))
end

-- ============ 配方数据修改(无需工作站/环境) ============
local function clear_env(recipe)
    safe_set(F_required_tile, recipe, -1, "int32")
    safe_set(F_need_water, recipe, false, "bool")
    safe_set(F_need_honey, recipe, false, "bool")
    safe_set(F_need_lava, recipe, false, "bool")
    safe_set(F_need_torch, recipe, false, "bool")
    safe_set(F_need_snow, recipe, false, "bool")
    safe_set(F_need_grave, recipe, false, "bool")
    safe_set(F_need_mech, recipe, false, "bool")
end

-- 配方是否已是"零前置"(以 requiredTile == -1 判定, 降低每帧开销)
local function is_free(recipe)
    if not F_required_tile then return true end
    local tile = patch.get_field_value(F_required_tile, recipe, "int32")
    return tile == -1
end

-- 逐项清空材料快速查找表(已用 mod.patch.array_set_raw 实现)
-- 返回是否实际写入; 取不到句柄/旧版无 array_set_raw 时返回 false,
-- 由 CollectedEnoughItemsToCraft 前缀拦截兜底。
local function clear_quick_lookup(recipe)
    if not F_quick_lookup or not patch.array_set_raw then return false end
    local arr = get_obj(F_quick_lookup, recipe)
    if not arr then return false end
    local len = patch.array_length(arr)
    if not len or len <= 0 or len > QUICK_MAX_LEN then return false end
    return (pcall(function()
        for i = 0, len - 1 do
            patch.array_set_raw(arr, i, QUICK_ZERO)
        end
    end))
end

local function make_free(recipe)
    if not recipe then return end
    if is_free(recipe) then return end
    clear_env(recipe)
    -- 清空 requiredItemQuickLookup 材料表(已用 array_set_raw 实现)
    clear_quick_lookup(recipe)
end

-- 遍历 Main.recipe, 把所有"产物非空"的有效配方改成零前置
local function patch_all_recipes()
    if not F_main_recipe then return 0 end
    local recipes = get_obj(F_main_recipe, nil)
    if not recipes then return 0 end

    local total = patch.array_length(recipes)
    local count = 0
    for i = 0, total - 1 do
        local recipe = patch.array_at(recipes, i)
        if recipe then
            local valid = true
            if F_recipe_create_item and F_item_type then
                local item = get_obj(F_recipe_create_item, recipe)
                if not item then
                    valid = false
                else
                    local t = patch.get_field_value(F_item_type, item, "int32")
                    if not t or t <= 0 then valid = false end
                end
            end
            if valid then
                make_free(recipe)
                count = count + 1
            end
        end
    end
    return count
end

-- 一次性采样验证日志(对齐 C 版 PatchRecipes 末尾)
local function verify_once()
    if verified then return end
    verified = true
    if not F_main_recipe or not F_required_tile then return end
    local recipes = get_obj(F_main_recipe, nil)
    if not recipes or patch.array_length(recipes) == 0 then return end
    local r0 = patch.array_at(recipes, 0)
    if not r0 then return end
    local tile = patch.get_field_value(F_required_tile, r0, "int32")
    mod.info(string.format("verify: recipe[0] requiredTile=%s", tostring(tile)))
end

-- ============ Hook 回调 ============
-- 配方表刷新后: 重建配方后清空各配方的前置(与 C 版 postfix 对应, 仅清标量字段)
local function on_find_recipes(instance, args, result)
    patch_all_recipes()
    verify_once()
end

-- 强制返回 true(布尔型检查方法): 跳过原方法并令返回值为 true
local function force_true_prefix(instance, args, result)
    return true, true
end

-- 跳过原方法(void 返回)
local function skip_prefix(instance, args, result)
    return true
end

-- ============ 初始化 ============
function setup()
    T_MAIN = patch.get_type("Terraria", "Main")
    T_RECIPE = patch.get_type("Terraria", "Recipe")
    T_ITEM = patch.get_type("Terraria", "Item")
    if not T_MAIN or not T_RECIPE or not T_ITEM then
        mod.error("获取类型失败 (Main/Recipe/Item), 模组未启用")
        return
    end

    F_main_recipe = find_field(T_MAIN, "recipe")
    F_recipe_create_item = find_field(T_RECIPE, "createItem")
    F_item_type = find_field(T_ITEM, "type")
    F_required_tile = find_field(T_RECIPE, "requiredTile")
    F_need_water = find_field(T_RECIPE, "needWater")
    F_need_honey = find_field(T_RECIPE, "needHoney")
    F_need_lava = find_field(T_RECIPE, "needLava")
    F_need_torch = find_field(T_RECIPE, "needTorchGodsFavor")
    F_need_snow = find_field(T_RECIPE, "needSnowBiome")
    F_need_grave = find_field(T_RECIPE, "needGraveyardBiome")
    F_need_mech = find_field(T_RECIPE, "needMechdusa")
    F_quick_lookup = find_field(T_RECIPE, "requiredItemQuickLookup")

    if not F_main_recipe or not F_required_tile then
        mod.error("获取配方关键字段失败 (Main.recipe / Recipe.requiredTile), 模组未启用")
        return
    end
    if not F_quick_lookup then
        mod.warn("未找到 Recipe.requiredItemQuickLookup, 已改由检查方法前缀拦截")
    elseif not patch.array_set_raw then
        mod.warn("LuaLoader 无 array_set_raw, 材料表清零跳过, 已由检查方法前缀拦截兜底")
    end

    -- 1) 配方表刷新后置: Android/PE 的 FindRecipes / GetThroughDelayedFindRecipes
    local find_m = patch.get_method(T_RECIPE, "FindRecipes", 1)
        or patch.get_method(T_RECIPE, "FindRecipes")
    safe_hook(find_m, { postfix = on_find_recipes }, "Recipe.FindRecipes", true)

    local delayed_m = patch.get_method(T_RECIPE, "GetThroughDelayedFindRecipes", 0)
        or patch.get_method(T_RECIPE, "GetThroughDelayedFindRecipes")
    safe_hook(delayed_m, { postfix = on_find_recipes }, "Recipe.GetThroughDelayedFindRecipes", true)

    -- 2) 环境/工作站检查: 强制通过
    local env_m = patch.get_method(T_RECIPE, "PlayerMeetsEnvironmentConditions", 2)
        or patch.get_method(T_RECIPE, "PlayerMeetsEnvironmentConditions")
    safe_hook(env_m, { prefix = force_true_prefix }, "Recipe.PlayerMeetsEnvironmentConditions")

    -- 3) 材料检查: 强制通过(替代 C 版清零材料表的做法)
    local enough_m = patch.get_method(T_RECIPE, "CollectedEnoughItemsToCraft", 1)
        or patch.get_method(T_RECIPE, "CollectedEnoughItemsToCraft")
    safe_hook(enough_m, { prefix = force_true_prefix }, "Recipe.CollectedEnoughItemsToCraft")

    -- 4) 合成不消耗材料: 跳过 GetIngredientsForOneCraft
    local ing_m = patch.get_method(T_RECIPE, "GetIngredientsForOneCraft", 2)
        or patch.get_method(T_RECIPE, "GetIngredientsForOneCraft")
    safe_hook(ing_m, { prefix = skip_prefix }, "Recipe.GetIngredientsForOneCraft")

    -- 5) 合成界面工作站过滤: 跳过 SetCraftingFilter(仅手机端有)
    local filter_m = patch.get_method(T_RECIPE, "SetCraftingFilter", 3)
        or patch.get_method(T_RECIPE, "SetCraftingFilter")
    safe_hook(filter_m, { prefix = skip_prefix }, "Recipe.SetCraftingFilter", true)

    -- 启动时先清一次
    patch_all_recipes()

    mod.info("自由合成已启用")
end

todo_list = { "setup" }
