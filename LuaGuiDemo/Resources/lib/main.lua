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
-- LuaGuiDemo —— LuaLoader 内置 ImGui GUI 示范
-- 加载器会为每个定义了 mod.on_gui 的 Mod 创建一个独立窗口，每帧回调该函数。

mod.meta = { pkg_id = "lzup.lua.guidemo", version = "1.0.0" }

local enabled = true
local speed = 3.0
local clicks = 0
local name = ""

function mod.on_gui()
    mod.gui.text("LuaLoader GUI 示范")
    mod.gui.separator()

    mod.gui.text(string.format("速度 = %.1f", speed))
    speed = mod.gui.slider("speed", speed, 1.0, 10.0)

    enabled = mod.gui.checkbox("启用", enabled)

    name = mod.gui.input_text("名字", name)
    mod.gui.text("你好，" .. (name == "" and "（在此输入）" or name))

    if mod.gui.button("点我") then
        clicks = clicks + 1
        mod.info("按钮被点击 " .. clicks .. " 次")
    end

    mod.gui.same_line()
    mod.gui.text("点击次数 = " .. clicks)
end

todo_list = {}
