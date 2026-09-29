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
-- 完全夜视 (NightVision) —— LuaLoader (Lua) 版
-- 由 KernelLoader(C) 版 Mods/TEKernelMods/NightVision/main.c 移植, 功能对齐。
--
-- 功能:
--   全图完全明亮 (Full Bright): 无论地表黑夜、洞穴多深, 画面与白天无异。
--   原版夜视(夜视头盔/药水)只把光照衰减乘 1.03, 效果微弱;
--   本 Mod 直接把光照引擎的"衰减系数"置为不衰减, 且不占用饰品栏与 Buff 栏。
--
-- 游戏有两套光照引擎, 两条路都处理:
--   1. 传统光照 LegacyLighting (Retro/快速/普通模式):
--      Postfix DoColors, 把 _negLight / _negLight2 / _negLight3 三个衰减系数写 0。
--   2. 新光照引擎 LightingEngine (彩色/白色高级光照模式):
--      Postfix UpdateLightDecay, 把 _workingLightMap 的
--      LightDecayThroughAir / LightDecayThroughSolid 写 1.0
--      (LightMap 传播是乘法 light *= decay, 1.0 才是"不衰减"; 写 0 会全黑)。
--   3. 同时 Postfix Player.ResetEffects:
--      nightVision 置 true 兜底, 并在玩家所在格注入白色光源 Lighting.AddLight(1,1,1),
--      这样夜晚没有任何光源时也能从玩家扩散至全屏。
--
-- Lua 版差异 / 限制:
--   * 属性->访问器桥接: 已用 LuaLoader 1.3.0 的 patch.property_set_method 从属性句柄取
--     setter 调用(与 C 版同款能力)。若属性桥接取不到, 回退编译期访问器方法名
--       set_LightDecayThroughAir / set_LightDecayThroughSolid;
--     再取不到回退自动属性的后备字段 <X>k__BackingField(已做判空与告警)。
--   * postfix 仅改字段/属性, 不改原方法返回值, 与 C 版语义一致。
--   * 某条路径失败为非致命, 与 C 版一致。
--
-- Hook 一览:
--   - Terraria.Player.ResetEffects                                  nightVision=true + 种光
--   - Terraria.Graphics.Light.LegacyLighting.DoColors               _negLight*=0
--   - Terraria.Graphics.Light.LightingEngine.UpdateLightDecay       Decay 属性=1.0

mod.meta = { pkg_id = "lzup.lua.nightvision", version = "2.2.0" }

local patch = mod.patch

-- ============ 句柄 ============
local F_night_vision                 -- Player.nightVision (bool)
local F_position                     -- Entity.position (Vector2)
local F_neg_light                    -- LegacyLighting._negLight  (float)
local F_neg_light2                   -- LegacyLighting._negLight2 (float)
local F_neg_light3                   -- LegacyLighting._negLight3 (float)
local F_working_light_map            -- LightingEngine._workingLightMap (object)
local M_addlight                     -- Lighting.AddLight(int,int,float,float,float)
local acc_air                        -- LightMap.LightDecayThroughAir 访问器 (写)
local acc_solid                      -- LightMap.LightDecayThroughSolid 访问器 (写)

local installed = 0
local fired = false

-- ============ 沿父类链查找字段 ============
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

-- ============ 安全安装 Hook ============
local function safe_hook(method, spec, label)
    if not method then
        mod.warn("安装钩子失败(" .. label .. ")：方法句柄为空(非致命)")
        return false
    end
    local ok, err = pcall(patch.install_hook, method, spec)
    if not ok then
        mod.warn("安装钩子失败(" .. label .. ")：" .. tostring(err) .. "(非致命)")
        return false
    end
    installed = installed + 1
    return true
end

-- ============ 解析 float 自动属性的写通道 ============
-- 优先用 LuaLoader 1.3.0 的属性桥接取 setter; 取不到再逐级回退。
-- 返回 { kind = "method", set = m_set } 或 { kind = "field", field = f } 或 nil
local function resolve_float_setter(type_handle, prop_name)
    -- 1) 属性 -> setter 桥接 (LuaLoader 1.3.0)
    local prop = patch.get_property(type_handle, prop_name)
    if prop then
        local setter = patch.property_set_method(prop)
        if setter then
            return { kind = "method", set = setter, bridge = true }
        end
    end
    -- 2) 回退: 编译期生成的 set_ 访问器方法名
    local setter = patch.get_method(type_handle, "set_" .. prop_name, 1)
    if setter then
        return { kind = "method", set = setter }
    end
    -- 3) 回退: 自动属性的后备字段
    local backing = patch.get_field(type_handle, "<" .. prop_name .. ">k__BackingField")
    if backing then
        return { kind = "field", field = backing }
    end
    return nil
end

local function write_accessor(acc, instance, value)
    if not acc then return end
    if acc.kind == "method" then
        patch.invoke(acc.set, instance, value)
    else
        patch.set_field_value(acc.field, instance, value, "float")
    end
end

-- ============ 工具: 截断取整(C 的 (int) 强转, 向零取整) ============
local function trunc(v)
    if v >= 0 then return math.floor(v) end
    return math.ceil(v)
end

-- ============ Postfix 1: Player.ResetEffects ============
-- 1. nightVision 置 true 兜底;
-- 2. 在玩家所在格注入一个白色光源(Lighting.AddLight 1,1,1):
--    "衰减=1(不衰减)"只保证已有光不消失, 夜晚没有任何光源时依然全黑;
--    以玩家为中心种光 + 光不衰减 => 从玩家扩散至全屏 => 彻底明亮。
local function on_reset_effects(instance)
    if not instance then return end

    if F_night_vision then
        patch.set_field_value(F_night_vision, instance, true, "bool")
    end

    if not fired then
        fired = true
        mod.info("完全夜视已生效")
    end

    if not M_addlight or not F_position then return end
    local px, py = patch.get_field_vec2(F_position, instance)
    if type(px) ~= "number" then return end
    local tx = trunc(px / 16.0)
    local ty = trunc(py / 16.0)
    patch.invoke(M_addlight, tx, ty, 1.0, 1.0, 1.0)
end

-- ============ Postfix 2: LegacyLighting.DoColors ============
-- DoColors 结束后衰减系数已经定稿(夜视/盲眼等修正均已计入),
-- 此处统一覆盖为 0 => 光照不再随距离衰减 => 全图完全明亮。
local function on_do_colors(instance)
    if not instance then return end
    if F_neg_light then patch.set_field_value(F_neg_light, instance, 0.0, "float") end
    if F_neg_light2 then patch.set_field_value(F_neg_light2, instance, 0.0, "float") end
    if F_neg_light3 then patch.set_field_value(F_neg_light3, instance, 0.0, "float") end
end

-- ============ Postfix 3: LightingEngine.UpdateLightDecay ============
-- 把工作光照图的衰减系数改为 1.0 (乘法传播下 1.0 = 不衰减)。
-- _workingLightMap 每帧可能被换新, 所以必须每帧重新取。
local function on_update_light_decay(instance)
    if not instance then return end
    if not F_working_light_map then return end

    local light_map = patch.get_field_value(F_working_light_map, instance, "object")
    if not light_map then return end

    write_accessor(acc_air, light_map, 1.0)
    write_accessor(acc_solid, light_map, 1.0)
end

-- ============ 初始化 ============
function setup()
    local player_type = patch.get_type("Terraria", "Player")
    local legacy_type = patch.get_type("Terraria.Graphics.Light", "LegacyLighting")
    local engine_type = patch.get_type("Terraria.Graphics.Light", "LightingEngine")

    if not player_type then
        mod.error("获取类型失败 (Terraria.Player)")
        return
    end
    if not legacy_type and not engine_type then
        mod.error("获取光照引擎类型失败 (LegacyLighting/LightingEngine 均为空)")
        return
    end

    -- 2. Player.nightVision + ResetEffects + 种光
    F_night_vision = patch.get_field(player_type, "nightVision")

    local entity_type = patch.get_type("Terraria", "Entity")
    if entity_type then
        F_position = patch.get_field(entity_type, "position")
    end

    local lighting_type = patch.get_type("Terraria", "Lighting")
    if lighting_type then
        -- AddLight 有多个重载, 取 5 参数版本 (int,int,float,float,float)
        M_addlight = patch.get_method(lighting_type, "AddLight", 5)
    end

    if F_night_vision then
        local m = patch.get_method(player_type, "ResetEffects", 0)
                or patch.get_method(player_type, "ResetEffects")
        safe_hook(m, { postfix = on_reset_effects }, "Player.ResetEffects")
    else
        mod.warn("获取 nightVision 字段失败(非致命)")
    end

    -- 3. 传统光照: LegacyLighting.DoColors + _negLight*
    if legacy_type then
        F_neg_light = patch.get_field(legacy_type, "_negLight")
        F_neg_light2 = patch.get_field(legacy_type, "_negLight2")
        F_neg_light3 = patch.get_field(legacy_type, "_negLight3")
        local m = patch.get_method(legacy_type, "DoColors", 0)
                or patch.get_method(legacy_type, "DoColors")
        if m and F_neg_light and F_neg_light2 and F_neg_light3 then
            safe_hook(m, { postfix = on_do_colors }, "LegacyLighting.DoColors")
        else
            mod.warn(string.format("LegacyLighting 解析失败: method=%s f1=%s f2=%s f3=%s",
                     tostring(m ~= nil), tostring(F_neg_light ~= nil),
                     tostring(F_neg_light2 ~= nil), tostring(F_neg_light3 ~= nil)))
        end
    end

    -- 4. 新光照引擎: LightingEngine.UpdateLightDecay + _workingLightMap
    if engine_type then
        F_working_light_map = patch.get_field(engine_type, "_workingLightMap")

        local lm_type = patch.get_type("Terraria.Graphics.Light", "LightMap")
        if lm_type then
            -- 存在性自检: 属性句柄存在则 resolve_float_setter 可经属性桥接取到 setter
            local prop_air = patch.get_property(lm_type, "LightDecayThroughAir")
            local prop_solid = patch.get_property(lm_type, "LightDecayThroughSolid")
            acc_air = resolve_float_setter(lm_type, "LightDecayThroughAir")
            acc_solid = resolve_float_setter(lm_type, "LightDecayThroughSolid")
            if not prop_air and not prop_solid then
                mod.warn("LightMap 未找到 LightDecayThroughAir/Solid 属性")
            end
        end

        local m = patch.get_method(engine_type, "UpdateLightDecay", 0)
                or patch.get_method(engine_type, "UpdateLightDecay")
        if m and F_working_light_map and acc_air and acc_solid then
            safe_hook(m, { postfix = on_update_light_decay }, "LightingEngine.UpdateLightDecay")
        else
            mod.warn(string.format("LightingEngine 解析失败: method=%s map=%s setAir=%s setSolid=%s",
                     tostring(m ~= nil), tostring(F_working_light_map ~= nil),
                     tostring(acc_air ~= nil), tostring(acc_solid ~= nil)))
        end
    end

    if installed > 0 then
        mod.info(string.format("成功安装 %d 个 Hook, 完全夜视已启用", installed))
    else
        mod.error("所有 Hook 均安装失败")
    end
end

todo_list = { "setup" }
