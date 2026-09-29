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
-- 随机伤害 (Random Damage) —— LuaLoader (Lua) 版
-- 由 KernelLoader(C) 版 Mods/TEKernelMods/Random Damage/main.c 移植, 功能对齐。
--
-- 功能:
--   所有武器每次攻击的伤害被随机化为 1~100 之间的任意值。
--
-- C 版实现:
--   Hook Player.GetWeaponDamage(1 参数, 参数为 Item) 的 Postfix;
--   在 Postfix 里直接把返回值 *result 覆盖为 generate_random_damage(1, 100)
--   (原返回值被丢弃), 随机数用 srand(time(NULL)) + rand()%range。
--
-- Lua 版差异 / 限制:
--   * 原 LuaLoader 的 postfix 回调返回值会被忽略; 现已用 1.3.0 新增的
--     install_hook(method, { override_result = true, postfix = ... }) 实现
--     (已用 postfix 覆盖返回值实现), 与 C 版语义一致: 先执行原方法, 再覆盖返回值。
--     已验证 Player.GetWeaponDamage 只读 sItem.damage 并调用
--     GetWeaponDamageMultiplier(纯字段读取), 无副作用, 因此保留原方法执行是安全的。
--     (若某些旧版 LuaLoader 不支持 override_result, 自动回退旧的 prefix 接管写法。)
--   * 随机数改用 Lua 内置 math.random(1, 100), 无需 srand/初始化。
--
-- Hook 失败不影响游戏运行。

mod.meta = { pkg_id = "lzup.lua.random_damage", version = "1.2.0" }

local patch = mod.patch

-- 随机伤害范围 [MIN_DAMAGE, MAX_DAMAGE]
local MIN_DAMAGE = 1
local MAX_DAMAGE = 100

local fired = false

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

-- ============ Postfix(override_result): Player.GetWeaponDamage ============
-- override_result = true 时, postfix 的返回值会覆盖原方法返回值 (LuaLoader 1.3.0+)。
-- 原方法照常执行(无副作用), 与 C 版"postfix 里改写 *result"完全等价。
local function on_get_weapon_damage(instance, args, result)
    if not fired then
        fired = true
        mod.info(string.format("随机伤害已生效 (%d~%d)", MIN_DAMAGE, MAX_DAMAGE))
    end
    return math.random(MIN_DAMAGE, MAX_DAMAGE)
end

-- ============ Prefix(回退): Player.GetWeaponDamage ============
-- 仅当 override_result 不可用时使用: 返回 true 跳过原方法, 并把第二个返回值作为返回值。
local function on_get_weapon_damage_prefix(instance, args, result)
    if not fired then
        fired = true
        mod.info(string.format("随机伤害已生效 (%d~%d, prefix 回退)", MIN_DAMAGE, MAX_DAMAGE))
    end
    return true, math.random(MIN_DAMAGE, MAX_DAMAGE)
end

-- ============ 初始化 ============
function setup()
    local player_type = patch.get_type("Terraria", "Player")
    if not player_type then
        mod.error("获取 Player 类型失败")
        return
    end

    -- GetWeaponDamage 带 1 个参数(Item)
    local method = patch.get_method(player_type, "GetWeaponDamage", 1)
            or patch.get_method(player_type, "GetWeaponDamage")

    -- 优先用 1.3.0 的 postfix 覆盖返回值; 失败则回退旧的 prefix 接管写法
    local ok = safe_hook(method,
            { override_result = true, postfix = on_get_weapon_damage },
            "Player.GetWeaponDamage(postfix)")
    if not ok then
        if not safe_hook(method, { prefix = on_get_weapon_damage_prefix },
                "Player.GetWeaponDamage(prefix 回退)") then
            return
        end
    end

    mod.info("成功 Hook GetWeaponDamage, 武器伤害将变为随机值")
end

todo_list = { "setup" }
