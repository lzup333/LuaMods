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
-- LuaLoader 示范 Mod：生命锁定（HealthLock）
-- 每帧在原版逻辑执行完后，把玩家当前生命补满。

mod.meta = { pkg_id = "lzup.lua.healthlock", version = "1.0.0" }

local stat_life
local stat_life_max
local fired = false

function lock_life(instance)
    if not fired then
        fired = true
        mod.info("生命锁定已生效")
    end
    -- 显式指定 int32，不依赖内核的字段类型查询（Android 上更稳）
    local max = mod.patch.get_field_value(stat_life_max, instance, "int32")
    mod.patch.set_field_value(stat_life, instance, max, "int32")
end

function setup()
    local player = mod.patch.get_type("Terraria", "Player")
    if not player then return end

    stat_life = mod.patch.get_field(player, "statLife")
    stat_life_max = mod.patch.get_field(player, "statLifeMax2")

    -- postfix：等 ResetEffects（每帧）执行完再锁满，否则会被原版覆盖
    mod.patch.install_hook(mod.patch.get_method(player, "ResetEffects", 0), { postfix = lock_life })
end

todo_list = { "setup" }
