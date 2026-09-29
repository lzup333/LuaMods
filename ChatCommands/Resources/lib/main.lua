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
-- ChatCommands —— LuaLoader(Lua) 版
-- 由 KernelLoader(C) 版 Mods/TEKernelMods/ChatCommands/main.c 移植，功能对齐。
--
-- 功能(在游戏聊天框输入指令):
--   1. /get <物品ID> [数量]     生成对应物品并给予玩家(默认 1 个, 上限 9999, /give 同义)
--   2. /god [on|off]            开关无敌模式(置 creativeGodMode, 免疫一切伤害)
--   3. /time <时:分>            设置游戏内时间(如 /time 12:30, 24 小时制)
--   4. /heal                    恢复全部生命与法力
--   5. /buff <buffID> [秒数]    给自己添加 buff(默认 300 秒)
--   6. /setSpawnRate [间隔|reset]  设置 NPC.defaultSpawnRate (默认 600)
--   7. /setMaxSpawns [上限|reset]  设置 NPC.defaultMaxSpawns (默认 5)
--
-- 聊天拦截: postfix Hook ChatCommandProcessor.ProcessIncomingMessage /
--           ChatHelper.SendChatMessageFromClient, 通过 ChatMessage.Text 读取文本。
-- 无敌: postfix Hook Player.ResetEffects, 原版重置后每帧重新置 creativeGodMode=true。

mod.meta = { pkg_id = "lzup.lua.chatcommands", version = "1.2.0" }

local patch = mod.patch

-- ============ 可调参数(与 C 版一致) ============
local kBaseSpawnRate = 600
local kBaseMaxSpawns = 5

-- ============ 状态 ============
local god_mode = false

-- ============ 类型句柄 ============
local T_MAIN, T_PLAYER, T_ITEM, T_NPC

-- ============ 字段句柄 ============
local F_stat_life, F_stat_life_max, F_stat_mana, F_stat_mana_max
local F_creative_god
local F_main_player, F_my_player
local F_day_time, F_time
local F_default_spawn_rate, F_default_max_spawns
local F_pos, F_width, F_height  -- Player 位置/尺寸(继承自 Entity, Android 给物品用)

-- ============ 方法句柄 ============
local M_get_my_player   -- Main.get_myPlayer (Android)
local M_new_text        -- Main.NewText
local M_new_item        -- Item.NewItem (Android, 9 参)
local M_quick_spawn     -- Player.QuickSpawnItem (桌面端, 3 参)
local M_add_buff        -- Player.AddBuff (3 参)
local M_get_text        -- ChatMessage.get_Text
local F_msg_text        -- ChatMessage 的 <Text>k__BackingField (回退)

-- ============ 小工具 ============
local function find_field(type_handle, name)
    local cur, guard = type_handle, 0
    while cur and guard < 16 do
        local f = patch.get_field(cur, name)
        if f then return f end
        cur = patch.get_parent(cur)
        guard = guard + 1
    end
    return nil
end

local function trim_left(s)
    if not s then return "" end
    return (s:match("^[ \t\r\n]*(.*)$")) or ""
end

local function starts(s, prefix)
    if not s then return false end
    return s:sub(1, #prefix) == prefix
end

-- 大小写不敏感前缀判断(等价 C 版 IStartsWith)
local function istarts(s, prefix)
    if not s then return false end
    local n = #prefix
    if #s < n then return false end
    return s:sub(1, n):lower() == prefix:lower()
end

-- 类 strtol: 返回 (数值, 结束位置); 无数字时返回 nil
local function strtol(s, i)
    i = i or 1
    while i <= #s do
        local c = s:sub(i, i)
        if c == " " or c == "\t" or c == "\r" or c == "\n" then i = i + 1 else break end
    end
    local start = i
    local c = s:sub(i, i)
    if c == "+" or c == "-" then i = i + 1 end
    local digits = i
    while i <= #s do
        local d = s:sub(i, i)
        if d >= "0" and d <= "9" then i = i + 1 else break end
    end
    if i == digits then return nil, start end
    return tonumber(s:sub(start, i - 1)), i
end

-- ============ 聊天输出 ============
local function show_chat(text)
    if not text then return end
    if not M_new_text then return end
    local s = patch.string_create(text)
    if not s then return end
    if mod.platform == "android" then
        patch.invoke(M_new_text, s, 255, 255, 255, false)
    else
        patch.invoke(M_new_text, s, 255, 255, 255)
    end
end

-- ============ 玩家 / 物品 ============
local function my_player_index()
    if F_my_player then
        local v = patch.get_field_value(F_my_player, nil, "int32")
        if v ~= nil then return v end
    end
    if M_get_my_player then
        local v = patch.invoke(M_get_my_player)
        if v ~= nil then return v end
    end
    return -1
end

local function local_player()
    if not F_main_player then return nil end
    local idx = my_player_index()
    if idx == nil or idx < 0 then return nil end
    local arr = patch.get_field_value(F_main_player, nil, "object")
    if not arr then return nil end
    local n = patch.array_length(arr)
    if idx >= n then return nil end
    return patch.array_at(arr, idx)
end

local function give_item(player, id, stack)
    if not player then return false end
    if mod.platform == "android" then
        if not M_new_item then return false end
        local px, py = patch.get_field_vec2(F_pos, player)
        if not px then return false end
        local w = patch.get_field_value(F_width, player, "int32") or 0
        local h = patch.get_field_value(F_height, player, "int32") or 0
        -- NewItem(X, Y, Width, Height, Type, Stack, noBroadcast, pfix, ownership)
        patch.invoke(M_new_item, math.floor(px), math.floor(py), math.floor(w), math.floor(h),
            id, stack, false, 0, 0)
        return true
    end
    -- 桌面端: Player.QuickSpawnItem(source, item, stack), source 不使用, 传 nil 安全
    if not M_quick_spawn then return false end
    patch.invoke(M_quick_spawn, player, nil, id, stack)
    return true
end

-- ============ 指令处理 ============
local function handle_command(raw)
    if not raw then return end

    -- ---- /get、/give ----
    if starts(raw, "/get") or starts(raw, "/give") then
        local prefix = starts(raw, "/give") and "/give" or "/get"
        local rest = trim_left(raw:sub(#prefix + 1))
        if rest == "" then
            show_chat("[指令助手] 用法: /get 或 /give <物品ID> [数量]")
            return
        end
        local id, e = strtol(rest, 1)
        if not id or id <= 0 or id >= 100000 then
            show_chat("[指令助手] 无效的物品ID")
            return
        end
        local stack = 1
        if e <= #rest then
            local st = strtol(rest, e)
            if st then
                if st < 1 then st = 1 end
                if st > 9999 then st = 9999 end
                stack = st
            end
        end
        local p = local_player()
        if not p then return end
        if not give_item(p, math.floor(id), math.floor(stack)) then
            show_chat("[指令助手] 发放物品失败(方法解析问题)")
            return
        end
        show_chat(string.format("[指令助手] 已给予物品 %d x %d", id, stack))
        return
    end

    -- ---- /god ----
    if starts(raw, "/god") then
        local rest = trim_left(raw:sub(5))
        if rest == "on" or rest == "1" or rest == "true" then
            god_mode = true
        elseif rest == "off" or rest == "0" or rest == "false" then
            god_mode = false
        else
            god_mode = not god_mode
        end
        show_chat(god_mode and "[指令助手] 无敌模式已开启" or "[指令助手] 无敌模式已关闭")
        return
    end

    -- ---- /time ----
    if starts(raw, "/time") then
        local rest = trim_left(raw:sub(6))
        if rest == "" then
            show_chat("[指令助手] 用法: /time <时:分>, 例如 /time 12:30")
            return
        end
        local hs, ms = rest:match("^(%d+):(%d+)")
        if not hs then
            show_chat("[指令助手] 无效的时间, 用法: /time 12:30")
            return
        end
        local hour, minute = tonumber(hs), tonumber(ms)
        if hour > 23 or minute > 59 then
            show_chat("[指令助手] 无效的时间(时 0-23, 分 0-59)")
            return
        end
        -- 泰拉瑞亚时间: dayLength=54000 = 白天/夜晚各 12 小时; 1 分钟=75 单位
        -- 白天从 4:30(270 分钟)起, 夜晚从 16:30(990 分钟)起
        local min_of_day = hour * 60 + minute
        local is_day, t
        if min_of_day >= 270 and min_of_day < 990 then
            is_day = true
            t = (min_of_day - 270) * 75.0
        else
            is_day = false
            local night_min
            if min_of_day >= 990 then
                night_min = min_of_day - 990
            else
                night_min = min_of_day + 1440 - 990
            end
            t = night_min * 75.0
        end
        if not F_day_time or not F_time then
            show_chat("[指令助手] 时间字段解析失败")
            return
        end
        patch.set_field_value(F_day_time, nil, is_day, "bool")
        patch.set_field_value(F_time, nil, t, "double")
        show_chat(string.format("[指令助手] 时间已设置为 %02d:%02d", hour, minute))
        return
    end

    -- ---- /heal ----
    if starts(raw, "/heal") then
        local p = local_player()
        if not p then return end
        if not F_stat_life or not F_stat_life_max or not F_stat_mana or not F_stat_mana_max then
            show_chat("[指令助手] 生命/法力字段解析失败")
            return
        end
        local life_max = patch.get_field_value(F_stat_life_max, p, "int32") or 0
        patch.set_field_value(F_stat_life, p, life_max, "int32")
        local mana_max = patch.get_field_value(F_stat_mana_max, p, "int32") or 0
        patch.set_field_value(F_stat_mana, p, mana_max, "int32")
        show_chat("[指令助手] 已恢复全部生命与法力")
        return
    end

    -- ---- /buff ----
    if starts(raw, "/buff") then
        local rest = trim_left(raw:sub(6))
        if rest == "" then
            show_chat("[指令助手] 用法: /buff <buffID> [秒数]")
            return
        end
        local id, e = strtol(rest, 1)
        if not id or id < 0 or id >= 100000 then
            show_chat("[指令助手] 无效的buffID")
            return
        end
        local seconds = 300
        if e <= #rest then
            local s = strtol(rest, e)
            if s and s >= 1 and s <= 36000 then seconds = s end
        end
        local p = local_player()
        if not p then return end
        if not M_add_buff then
            show_chat("[指令助手] Player.AddBuff 解析失败")
            return
        end
        -- AddBuff(type, time, fromNetPvP=false), 时间单位为帧(60帧=1秒)
        patch.invoke(M_add_buff, p, math.floor(id), math.floor(seconds * 60), false)
        show_chat(string.format("[指令助手] 已添加buff %d (%d 秒)", id, seconds))
        return
    end

    -- ---- /setSpawnRate ----
    if istarts(raw, "/setSpawnRate") then
        local rest = trim_left(raw:sub(14))
        if not F_default_spawn_rate then
            show_chat("[指令助手] NPC.defaultSpawnRate 字段解析失败")
            return
        end
        if rest == "" then
            local cur = patch.get_field_value(F_default_spawn_rate, nil, "int32")
            if cur == nil then
                show_chat("[指令助手] 读取 defaultSpawnRate 失败")
            else
                show_chat(string.format(
                    "[指令助手] 刷怪间隔 defaultSpawnRate = %d (默认 %d, 越小刷怪越快)", cur, kBaseSpawnRate))
            end
            return
        end
        if istarts(rest, "reset") then
            patch.set_field_value(F_default_spawn_rate, nil, kBaseSpawnRate, "int32")
            show_chat("[指令助手] 刷怪间隔已恢复默认 (600)")
            return
        end
        local v = strtol(rest, 1)
        if not v then
            show_chat("[指令助手] 用法: /setSpawnRate <间隔> (默认 600, 越小刷怪越快), 或 reset")
            return
        end
        if v < 1 then v = 1 end
        if v > 1000000 then v = 1000000 end
        patch.set_field_value(F_default_spawn_rate, nil, math.floor(v), "int32")
        show_chat(string.format("[指令助手] 刷怪间隔已设为 %d (默认 %d, 越小刷怪越快)", v, kBaseSpawnRate))
        return
    end

    -- ---- /setMaxSpawns ----
    if istarts(raw, "/setMaxSpawns") then
        local rest = trim_left(raw:sub(14))
        if not F_default_max_spawns then
            show_chat("[指令助手] NPC.defaultMaxSpawns 字段解析失败")
            return
        end
        if rest == "" then
            local cur = patch.get_field_value(F_default_max_spawns, nil, "int32")
            if cur == nil then
                show_chat("[指令助手] 读取 defaultMaxSpawns 失败")
            else
                show_chat(string.format(
                    "[指令助手] 刷怪上限 defaultMaxSpawns = %d (默认 %d, 实际最多为其 3 倍)", cur, kBaseMaxSpawns))
            end
            return
        end
        if istarts(rest, "reset") then
            patch.set_field_value(F_default_max_spawns, nil, kBaseMaxSpawns, "int32")
            show_chat("[指令助手] 刷怪上限已恢复默认 (5)")
            return
        end
        local v = strtol(rest, 1)
        if not v then
            show_chat("[指令助手] 用法: /setMaxSpawns <上限> (默认 5), 或 reset")
            return
        end
        if v < 1 then v = 1 end
        if v > 100 then v = 100 end
        patch.set_field_value(F_default_max_spawns, nil, math.floor(v), "int32")
        show_chat(string.format("[指令助手] 刷怪上限已设为 %d (默认 %d, 实际最多为其 3 倍)", v, kBaseMaxSpawns))
        return
    end
end

-- ============ 聊天文本读取 ============
local function is_mod_command(t)
    if not t then return false end
    return starts(t, "/get") or starts(t, "/give") or starts(t, "/god") or
        starts(t, "/time") or starts(t, "/heal") or starts(t, "/buff") or
        istarts(t, "/setSpawnRate") or istarts(t, "/setMaxSpawns")
end

local function read_message_text(message)
    if not message then return nil end
    if M_get_text then
        local s = patch.invoke(M_get_text, message)
        if s then
            local v = patch.string_value(s)
            if v then return v end
        end
    end
    if F_msg_text then
        return patch.get_field_value(F_msg_text, message, "string")
    end
    return nil
end

-- ============ Hook: 聊天 ============
local function on_process_incoming(instance, args, result)
    if not args then return end
    local message = args[1]
    local client_id = args[2]
    local my = my_player_index()
    if my < 0 or client_id ~= my then return end
    local text = read_message_text(message)
    if text and is_mod_command(text) then handle_command(text) end
end

local function on_send_from_client(instance, args, result)
    if not args then return end
    local text = read_message_text(args[1])
    if text and is_mod_command(text) then handle_command(text) end
end

-- ============ Hook: 每帧维持无敌 ============
local function on_reset_effects(instance, args, result)
    if not god_mode or not instance then return end
    if not F_creative_god then return end
    patch.set_field_value(F_creative_god, instance, true, "bool")
end

-- ============ 生命周期 ============
local function safe_hook(method, spec, label)
    if not method then
        mod.error(string.format("安装钩子失败(%s)：方法为空", label))
        return false
    end
    local ok, err = pcall(patch.install_hook, method, spec)
    if not ok then
        mod.error(string.format("安装钩子失败(%s)：%s", label, tostring(err)))
        return false
    end
    return true
end

function setup()
    mod.info("初始化聊天指令模组")

    T_MAIN = patch.get_type("Terraria", "Main")
    T_PLAYER = patch.get_type("Terraria", "Player")
    T_ITEM = patch.get_type("Terraria", "Item")
    T_NPC = patch.get_type("Terraria", "NPC")
    if not T_MAIN or not T_PLAYER or not T_ITEM or not T_NPC then
        mod.error("获取类型失败 (Main/Player/Item/NPC)")
        return
    end

    -- 字段
    F_stat_life = patch.get_field(T_PLAYER, "statLife")
    F_stat_life_max = patch.get_field(T_PLAYER, "statLifeMax")
    F_stat_mana = patch.get_field(T_PLAYER, "statMana")
    F_stat_mana_max = patch.get_field(T_PLAYER, "statManaMax")
    F_creative_god = patch.get_field(T_PLAYER, "creativeGodMode")
    F_main_player = patch.get_field(T_MAIN, "player")
    F_my_player = patch.get_field(T_MAIN, "myPlayer")
    F_day_time = patch.get_field(T_MAIN, "dayTime")
    F_time = patch.get_field(T_MAIN, "time")
    F_default_spawn_rate = patch.get_field(T_NPC, "defaultSpawnRate")
    F_default_max_spawns = patch.get_field(T_NPC, "defaultMaxSpawns")
    F_pos = find_field(T_PLAYER, "position")
    F_width = find_field(T_PLAYER, "width")
    F_height = find_field(T_PLAYER, "height")

    -- 方法(平台相关)
    if mod.platform == "android" then
        M_new_text = patch.get_method(T_MAIN, "NewText", 5) or patch.get_method(T_MAIN, "NewText")
        M_new_item = patch.get_method(T_ITEM, "NewItem", 9) or patch.get_method(T_ITEM, "NewItem")
    else
        M_new_text = patch.get_method(T_MAIN, "NewText", 4) or patch.get_method(T_MAIN, "NewText")
        -- QuickSpawnItem 有 (IEntitySource,int,int) 与 (IEntitySource,Item,GetItemSettings) 两个 3 参重载,
        -- 已用 LuaLoader 1.3.0 get_method_by_names("source","item","stack") 精确选 (source,int,int);
        -- 取不到再回退按参数个数 3(与 C 版回退一致)。
        M_quick_spawn = patch.get_method_by_names(T_PLAYER, "QuickSpawnItem", { "source", "item", "stack" })
                or patch.get_method(T_PLAYER, "QuickSpawnItem", 3)
                or patch.get_method(T_PLAYER, "QuickSpawnItem")
    end

    -- Main.myPlayer: 已用 LuaLoader 1.3.0 属性桥接 property_get_method 取 getter;
    -- 取不到回退方法名 get_myPlayer(桌面端另有静态字段 F_my_player 作最终回退)。
    local my_player_prop = patch.get_property(T_MAIN, "myPlayer")
    if my_player_prop then
        M_get_my_player = patch.property_get_method(my_player_prop)
    end
    if not M_get_my_player then
        M_get_my_player = patch.get_method(T_MAIN, "get_myPlayer", 0)
    end
    M_add_buff = patch.get_method(T_PLAYER, "AddBuff", 3) or patch.get_method(T_PLAYER, "AddBuff")

    -- 聊天消息文本 getter
    local msg_type = patch.get_type("Terraria.Chat", "ChatMessage")
    if msg_type then
        M_get_text = patch.get_method(msg_type, "get_Text", 0)
        F_msg_text = patch.get_field(msg_type, "<Text>k__BackingField")
    end

    -- Hook 聊天(postfix)
    local chat_type = patch.get_type("Terraria.Chat", "ChatCommandProcessor")
    local chat_method = chat_type and patch.get_method(chat_type, "ProcessIncomingMessage", 2)
    if not safe_hook(chat_method, { postfix = on_process_incoming }, "ProcessIncomingMessage") then
        mod.warn("ProcessIncomingMessage Hook 未安装(单机指令可能不可用)")
    end

    local helper_type = patch.get_type("Terraria.Chat", "ChatHelper")
    local send_method = helper_type and patch.get_method(helper_type, "SendChatMessageFromClient", 1)
    if not safe_hook(send_method, { postfix = on_send_from_client }, "SendChatMessageFromClient") then
        mod.warn("SendChatMessageFromClient Hook 未安装(多人指令可能不可用)")
    end

    -- Hook ResetEffects(postfix): 每帧维持无敌
    local reset_method = patch.get_method(T_PLAYER, "ResetEffects", 0) or patch.get_method(T_PLAYER, "ResetEffects")
    if not safe_hook(reset_method, { postfix = on_reset_effects }, "Player.ResetEffects") then
        mod.warn("ResetEffects Hook 未安装(无敌模式不可用)")
    end

    mod.info("初始化完成: /get /god /time /heal /buff /setSpawnRate /setMaxSpawns 可用")
end

function cleanup()
    god_mode = false
    mod.info("清理模组")
end

todo_list = { "setup" }
