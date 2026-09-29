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
-- RandomCraft —— LuaLoader (Lua) 版
-- 由 KernelLoader(C) 版 Mods/TEKernelMods/RandomCraft/main.c 移植，功能对齐。
--
-- 功能:
--   1. 随机产物: Hook CraftingRequests.CreateResult 后置, 每次合成把返回的产物
--      Item 替换为另一个随机可合成物品(类型取自产物池, 数量固定为 1)。
--   2. 随机所需材料: 配方表构建完成(Recipe.SetupRecipes 后置)后, 把每个配方的
--      requiredItem 内容随机替换为 1~3 种随机材料 + 随机堆叠(1~9)。
--   3. 材料池 / 产物池在首次初始化时从 Main.recipe 收集, 整个进程只随机化一次。
--
-- 与原 C 版的实现差异(说明):
--   注: C 版同时改写 Recipe.requiredItem(Item[]) 和 requiredItemQuickLookup
--     (RequiredItemEntry[] 内联结构体数组, 每项 8 字节)。LuaLoader 1.3.0 起提供
--     mod.patch.array_set_raw, 现已在 randomize_recipe_materials 里按同样的 8 字节
--     结构写回, 使"可合成判定 / 材料消耗"也走随机材料(已用 array_set_raw 实现,
--     与 C 版桌面端 patchlib_array_set 等价)。取不到句柄或旧版无该 API 时自动跳过
--     写回, 退回仅显示层随机(与旧版行为一致), 不影响产物随机化。
--   C 版 CreateResult 后置直接改结果对象的字段(type/stack), 不改变返回值指针,
--     故 Lua 的 postfix 亦可完成(读到的 result 就是产物 Item 句柄)。

mod.meta = { pkg_id = "lzup.lua.randomcraft", version = "1.1.0" }

local patch = mod.patch

-- ============ 池上限 ============
local POOL_MAX = 2048
local LOOKUP_FAKE_ID = 1000000  -- RecipeGroup 伪物品 id 门槛
local CAP = 15                  -- Recipe.maxRequirements

-- ============ 句柄 ============
local T_MAIN, T_RECIPE, T_ITEM, T_CRAFTING
local F_main_recipe
local F_recipe_create_item
local F_recipe_required_item
local F_recipe_quick_lookup
local F_item_type
local F_item_stack

local M_set_defaults1
local M_set_defaults2

-- ============ 状态 ============
local initialized = false
local logged_sample = false
local random_initialized = false
local material_types = {}
local material_set = {}
local product_types = {}
local product_set = {}

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

local function safe_set(field, instance, value, ty)
    if not field then return false end
    return (pcall(patch.set_field_value, field, instance, value, ty))
end

-- 写入材料快速查找表第 idx 项 (RequiredItemEntry: itemIdOrRecipeGroup + stack)
-- 已用 mod.patch.array_set_raw 实现, 每项按 8 字节内联结构写回;
-- 取不到句柄/不支持该 API 时返回 false(静默回退到仅显示层随机)。
local function set_lookup_entry(quick, idx, t, stack)
    if not quick or not patch.array_set_raw then return false end
    local ok = pcall(patch.array_set_raw, quick, idx, string.pack("<ii", t, stack))
    return ok
end

-- ============ 随机数 ============
local function init_random()
    if not random_initialized then
        random_initialized = true
        math.randomseed(os.time())
    end
end

local function rand(range)
    if range <= 0 then return 0 end
    return math.random(1, range)
end

-- ============ 池构建 ============
local function pool_add(pool, set, t)
    if not t or t <= 0 then return end
    if #pool >= POOL_MAX then return end
    if set[t] then return end          -- 去重
    set[t] = true
    pool[#pool + 1] = t
end

local function build_pools()
    material_types = {}
    material_set = {}
    product_types = {}
    product_set = {}

    if not F_main_recipe then return end
    local recipes = get_obj(F_main_recipe, nil)
    if not recipes then return end

    local total = patch.array_length(recipes)
    for i = 0, total - 1 do
        local recipe = patch.array_at(recipes, i)
        if recipe then
            -- 产物池: createItem.type
            local item = F_recipe_create_item and get_obj(F_recipe_create_item, recipe)
            if item then
                pool_add(product_types, product_set, get_int(F_item_type, item, 0))
            end
            -- 材料池: requiredItemQuickLookup 中的真实物品 id
            local quick = F_recipe_quick_lookup and get_obj(F_recipe_quick_lookup, recipe)
            if quick then
                local len = patch.array_length(quick)
                for j = 0, len - 1 do
                    local t = patch.array_at(quick, j, "int32")
                    if t and t > 0 and t < LOOKUP_FAKE_ID then
                        pool_add(material_types, material_set, t)
                    end
                end
            end
        end
    end

    mod.info(string.format("pools: materials=%d products=%d",
            #material_types, #product_types))
end

-- ============ 物品初始化(等价 C 版 ApplyItemDefaults) ============
local function apply_item_defaults(item, item_type)
    if not item or item_type <= 0 then return end
    if M_set_defaults2 then
        -- Item.SetDefaults(int, ItemVariant)：变体传 nil(null)
        local ok, r = pcall(patch.invoke, M_set_defaults2, item, item_type, nil)
        if ok and r ~= false then return end
    end
    if M_set_defaults1 then
        local ok, r = pcall(patch.invoke, M_set_defaults1, item, item_type)
        if ok and r ~= false then return end
    end
    -- 都不可用时退化: 直接改 type
    safe_set(F_item_type, item, item_type, "int32")
end

-- ============ 单个配方材料随机化 ============
local function randomize_recipe_materials(recipe)
    if not recipe or #material_types <= 0 then return end

    local req = F_recipe_required_item and get_obj(F_recipe_required_item, recipe)
    local req_len = req and patch.array_length(req) or 0
    -- requiredItemQuickLookup: 可合成判定与材料消耗实际依据的快速查找表
    local quick = F_recipe_quick_lookup and get_obj(F_recipe_quick_lookup, recipe)
    local q_len = quick and patch.array_length(quick) or 0

    -- 随机 1~3 种材料; 同时写 requiredItem(显示) 与 requiredItemQuickLookup(判定/消耗)
    local n = 1 + rand(3)
    for i = 0, n - 1 do
        local t = material_types[rand(#material_types)]
        local stack = 1 + rand(9)
        if i < req_len then
            local item = patch.array_at(req, i)
            if item then
                apply_item_defaults(item, t)
                safe_set(F_item_stack, item, stack, "int32")
            end
        end
        if i < q_len then
            set_lookup_entry(quick, i, t, stack)
        end
    end

    -- 其余置空, 防止残留旧材料
    for i = n, CAP - 1 do
        if i < req_len then
            local item = patch.array_at(req, i)
            if item then
                safe_set(F_item_type, item, 0, "int32")
                safe_set(F_item_stack, item, 0, "int32")
            end
        end
        if i < q_len then
            set_lookup_entry(quick, i, 0, 0)
        end
    end

    -- 已用 mod.patch.array_set_raw 写回 requiredItemQuickLookup: 材料需求的逻辑层
    -- 随机化与 C 版一致。若运行时不支持, set_lookup_entry 静默跳过, 仅显示层生效。
end

-- ============ 全部配方随机化(只执行一次) ============
local function randomize_all_recipes()
    if initialized then return end
    initialized = true

    build_pools()
    if #material_types <= 0 then return end

    local recipes = get_obj(F_main_recipe, nil)
    if not recipes then return end
    local total = patch.array_length(recipes)

    local count = 0
    for i = 0, total - 1 do
        local recipe = patch.array_at(recipes, i)
        if recipe then
            local item = F_recipe_create_item and get_obj(F_recipe_create_item, recipe)
            if item and get_int(F_item_type, item, 0) > 0 then
                randomize_recipe_materials(recipe)
                count = count + 1
            end
        end
    end

    mod.info(string.format("randomized materials for %d recipes", count))
end

-- ============ Hook 回调 ============
-- Recipe.SetupRecipes 后置 -> 随机材料
local function on_setup_recipes(instance, args, result)
    randomize_all_recipes()
end

-- CraftingRequests.CreateResult 后置 -> 随机产物
local function on_create_result(instance, args, result)
    if not result then return end

    -- 兜底: 若 SetupRecipes Hook 未触发, 在此完成首次随机化
    randomize_all_recipes()
    if #product_types <= 0 then return end

    local t = product_types[rand(#product_types)]
    if not t or t <= 0 then return end

    apply_item_defaults(result, t)
    safe_set(F_item_stack, result, 1, "int32")

    if not logged_sample then
        logged_sample = true
        mod.info(string.format("sample craft -> random item type=%d", t))
    end
end

-- ============ 初始化 ============
function setup()
    init_random()

    T_MAIN = patch.get_type("Terraria", "Main")
    T_RECIPE = patch.get_type("Terraria", "Recipe")
    T_ITEM = patch.get_type("Terraria", "Item")
    T_CRAFTING = patch.get_type("Terraria.GameContent", "CraftingRequests")
    if not T_MAIN or not T_RECIPE or not T_ITEM then
        mod.error("获取类型失败 (Main/Recipe/Item), 模组未启用")
        return
    end

    F_main_recipe = find_field(T_MAIN, "recipe")
    F_recipe_create_item = find_field(T_RECIPE, "createItem")
    F_recipe_required_item = find_field(T_RECIPE, "requiredItem")
    F_recipe_quick_lookup = find_field(T_RECIPE, "requiredItemQuickLookup")
    F_item_type = find_field(T_ITEM, "type")
    F_item_stack = find_field(T_ITEM, "stack")

    if not F_main_recipe or not F_recipe_create_item or not F_recipe_required_item
        or not F_recipe_quick_lookup or not F_item_type or not F_item_stack then
        mod.error("获取配方字段失败, 模组未启用")
        return
    end

    M_set_defaults2 = patch.get_method(T_ITEM, "SetDefaults", 2)
    M_set_defaults1 = patch.get_method(T_ITEM, "SetDefaults", 1)
    if not M_set_defaults2 and not M_set_defaults1 then
        M_set_defaults1 = patch.get_method(T_ITEM, "SetDefaults")
    end

    -- 1) Recipe.SetupRecipes() 后置 -> 随机材料
    local setup_m = patch.get_method(T_RECIPE, "SetupRecipes", 0)
        or patch.get_method(T_RECIPE, "SetupRecipes")
    if not safe_hook(setup_m, { postfix = on_setup_recipes }, "Recipe.SetupRecipes", true) then
        mod.warn("SetupRecipes Hook 未安装(随机材料将延迟到首次合成时执行)")
    end

    -- 2) CraftingRequests.CreateResult(Recipe) 后置 -> 随机产物
    if T_CRAFTING then
        local create_m = patch.get_method(T_CRAFTING, "CreateResult", 1)
            or patch.get_method(T_CRAFTING, "CreateResult")
        if not safe_hook(create_m, { postfix = on_create_result }, "CraftingRequests.CreateResult") then
            mod.warn("CreateResult Hook 未安装(随机产物不可用)")
        end
    else
        mod.error("找不到类型 Terraria.GameContent.CraftingRequests, 随机产物不可用")
    end

    mod.info("随机合成已启用")
end

todo_list = { "setup" }
