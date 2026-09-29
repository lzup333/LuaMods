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
-- 光源穿透 (LightPenetration) —— LuaLoader (Lua) 版
-- 由 KernelLoader(C) 版 Mods/TEKernelMods/LightPenetration/main.c 移植, 功能对齐。
--
-- 功能:
--   降低光照衰减系数, 让光源照得更远。仅彩色照明模式(新光照引擎 LightingEngine)生效。
--   穿透强度由 PENETRATION_FACTOR 控制(0~1), 当前 0.3:
--     衰减降到原来的 30%, 光照范围约扩大 3 倍。
--
-- C 版实现:
--   Hook LightingEngine.UpdateLightDecay 的 Postfix;
--   该方法每帧把衰减写入 _workingLightMap (LightMap):
--     LightDecayThroughAir / LightDecayThroughSolid;
--   LightMap 传播是乘法 light *= decay, Postfix 把衰减改为
--     new = 1 - (1 - old) * PENETRATION_FACTOR
--   _workingLightMap 每帧可能被换新, 所以每帧重新取。
--
-- Lua 版差异 / 限制:
--   * 属性->访问器桥接: 已用 LuaLoader 1.3.0 的 patch.property_get_method /
--     patch.property_set_method 从属性句柄取 getter/setter 调用(与 C 版同款能力)。
--     若属性桥接取不到, 回退编译期访问器方法名:
--       get_/set_LightDecayThroughAir、get_/set_LightDecayThroughSolid;
--     再取不到回退自动属性的后备字段 <X>k__BackingField(已做判空与告警)。
--   * postfix 仅改字段/属性, 不改原方法返回值, 与 C 版语义一致。
--
-- Hook 失败不影响游戏运行。

mod.meta = { pkg_id = "lzup.lua.lightpenetration", version = "1.2.0" }

local patch = mod.patch

-- ============ 穿透强度 (0.0 ~ 1.0, 衰减系数缩放倍数) ============
local PENETRATION_FACTOR = 0.3

-- ============ 句柄 ============
local F_working_light_map            -- LightingEngine._workingLightMap (object)
local acc_air                        -- LightMap.LightDecayThroughAir 访问器
local acc_solid                      -- LightMap.LightDecayThroughSolid 访问器

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

-- ============ 解析一个 float 自动属性的读写通道 ============
-- 优先用 LuaLoader 1.3.0 的属性桥接取 getter/setter; 取不到再逐级回退。
-- 返回 { kind = "method", get = m_get, set = m_set } 或
--      { kind = "field", field = f } 或 nil
local function resolve_float_accessor(type_handle, prop_name)
    -- 1) 属性 -> 访问器桥接 (LuaLoader 1.3.0)
    local prop = patch.get_property(type_handle, prop_name)
    if prop then
        local getter = patch.property_get_method(prop)
        local setter = patch.property_set_method(prop)
        if getter and setter then
            return { kind = "method", get = getter, set = setter, bridge = true }
        end
    end
    -- 2) 回退: 编译期生成的访问器方法名
    local getter = patch.get_method(type_handle, "get_" .. prop_name, 0)
    local setter = patch.get_method(type_handle, "set_" .. prop_name, 1)
    if getter and setter then
        return { kind = "method", get = getter, set = setter }
    end
    -- 3) 回退: 自动属性的后备字段
    local backing = patch.get_field(type_handle, "<" .. prop_name .. ">k__BackingField")
    if backing then
        return { kind = "field", field = backing }
    end
    return nil
end

local function read_accessor(acc, instance)
    if not acc then return nil end
    if acc.kind == "method" then
        return patch.invoke(acc.get, instance)
    end
    return patch.get_field_value(acc.field, instance, "float")
end

local function write_accessor(acc, instance, value)
    if not acc then return end
    if acc.kind == "method" then
        patch.invoke(acc.set, instance, value)
    else
        patch.set_field_value(acc.field, instance, value, "float")
    end
end

-- ============ Postfix: LightingEngine.UpdateLightDecay ============
-- LightMap 传播是乘法(light *= decay), decay 越接近 1 衰减越弱。
-- 把"每格损失 (1 - decay)"缩小为原来的 PENETRATION_FACTOR 倍:
--   new = 1 - (1 - old) * PENETRATION_FACTOR
-- 例如原 decay=0.91, factor=0.3 => new=0.973, 光照传播距离约扩大 3 倍。
-- _workingLightMap 每帧可能被换新, 所以必须每帧重新取。
local function on_update_light_decay(instance)
    if not instance then return end
    if not F_working_light_map then return end

    local light_map = patch.get_field_value(F_working_light_map, instance, "object")
    if not light_map then return end

    if not fired then
        fired = true
        mod.info("光源穿透已生效 (factor=%.2f)", PENETRATION_FACTOR)
    end

    if acc_air then
        local old = read_accessor(acc_air, light_map)
        if type(old) == "number" then
            write_accessor(acc_air, light_map, 1.0 - (1.0 - old) * PENETRATION_FACTOR)
        end
    end
    if acc_solid then
        local old = read_accessor(acc_solid, light_map)
        if type(old) == "number" then
            write_accessor(acc_solid, light_map, 1.0 - (1.0 - old) * PENETRATION_FACTOR)
        end
    end
end

-- ============ 初始化 ============
function setup()
    local engine_type = patch.get_type("Terraria.Graphics.Light", "LightingEngine")
    if not engine_type then
        mod.error("获取类型失败 (Terraria.Graphics.Light.LightingEngine)")
        return
    end

    F_working_light_map = patch.get_field(engine_type, "_workingLightMap")
    if not F_working_light_map then
        mod.error("获取 _workingLightMap 字段失败")
        return
    end

    local lm_type = patch.get_type("Terraria.Graphics.Light", "LightMap")
    if lm_type then
        -- 存在性自检: 属性句柄存在则 resolve_float_accessor 可经属性桥接取到访问器
        local prop_air = patch.get_property(lm_type, "LightDecayThroughAir")
        local prop_solid = patch.get_property(lm_type, "LightDecayThroughSolid")
        acc_air = resolve_float_accessor(lm_type, "LightDecayThroughAir")
        acc_solid = resolve_float_accessor(lm_type, "LightDecayThroughSolid")
        if not prop_air and not prop_solid then
            mod.warn("LightMap 未找到 LightDecayThroughAir/Solid 属性")
        end
    end

    if not acc_air or not acc_solid then
        mod.error(string.format("获取 LightMap 衰减访问器失败: air=%s solid=%s",
                  tostring(acc_air ~= nil), tostring(acc_solid ~= nil)))
        return
    end

    local method = patch.get_method(engine_type, "UpdateLightDecay", 0)
            or patch.get_method(engine_type, "UpdateLightDecay")
    if not safe_hook(method, { postfix = on_update_light_decay }, "UpdateLightDecay") then
        return
    end

    mod.info("成功 Hook UpdateLightDecay, 光源穿透已启用")
end

todo_list = { "setup" }
