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
-- Back —— LuaLoader 版（死亡回溯）：聊天框输入 /back 回到上次死亡点。

mod.meta = { pkg_id = "lzup.lua.back", version = "1.0.0" }

-- 拿到类型
local mainType   = mod.patch.get_type("Terraria", "Main")
local playerType = mod.patch.get_type("Terraria", "Player")
local entityType = mod.patch.get_type("Terraria", "Entity")
local messageType = mod.patch.get_type("Terraria.Chat", "ChatMessage")
local chatType   = mod.patch.get_type("Terraria.Chat", "ChatCommandProcessor")
if not mainType or not playerType or not entityType or not messageType or not chatType then return end

-- 拿到字段
local mainPlayerField    = mod.patch.get_field(mainType, "player")
local lastDeathField     = mod.patch.get_field(playerType, "lastDeathPostion")
local positionField      = mod.patch.get_field(entityType, "position")
local messageTextField   = mod.patch.get_field(messageType, "<Text>k__BackingField")

-- 拿本地玩家索引：安卓走属性 getter，其他走 get_myPlayer 方法
local getMyPlayerMethod
if mod.platform == "android" then
    local myPlayerProperty = mod.patch.get_property(mainType, "myPlayer")
    getMyPlayerMethod = myPlayerProperty and mod.patch.property_get_method(myPlayerProperty)
else
    getMyPlayerMethod = mod.patch.get_method(mainType, "get_myPlayer", 0)
end

-- 拿到方法
local newTextField       = mod.patch.get_method(mainType, "NewText")
local getTextField       = mod.patch.get_method(messageType, "get_Text")
local processMessageMethod = mod.patch.get_method(chatType, "ProcessIncomingMessage", 2)

-- postfix 回调：args[1] 是 ChatMessage 对象
function onMessage(instance, args)
    local message = args[1]

    -- 读出聊天文本
    local managedString = mod.patch.invoke(getTextField, message)
    local text = mod.patch.string_value(managedString)
    if text ~= "/back" then return end

    -- 拿本地玩家
    local playerIndex = mod.patch.invoke(getMyPlayerMethod)
    local playerArray = mod.patch.get_field_value(mainPlayerField, nil, "object")
    local player = mod.patch.array_at(playerArray, playerIndex)

    -- 读死亡点
    local deathX, deathY = mod.patch.get_field_vec2(lastDeathField, player)

    -- 还没死过：lastDeathPostion 默认是 (0,0)
    if deathX == 0 and deathY == 0 then
        local warningString = mod.patch.string_create("[回退] 还没有死亡记录")
        mod.patch.invoke(newTextField, warningString, 255, 255, 255)
        return
    end

    -- 写回坐标
    mod.patch.set_field_vec2(positionField, player, deathX, deathY)

    -- 聊天栏提示
    local outputString = mod.patch.string_create("[回退] 已传送")
    mod.patch.invoke(newTextField, outputString, 255, 255, 255)
end

function setup()
    mod.info("Back mod was enabled!")

    if not processMessageMethod then return end
    mod.patch.install_hook(processMessageMethod, { postfix = onMessage })
end

todo_list = { "setup" }