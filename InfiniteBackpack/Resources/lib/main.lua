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
-- InfiniteBackpack —— LuaLoader(Lua) 版
-- 由 KernelLoader(C) 版 Mods/TEKernelMods/InfiniteBackpack/main.c 移植，功能对齐。
--
-- 功能(游戏聊天框输入指令):
--   /store  (别名 /存)    把背包里全部非快捷栏物品(第 10~49 格)存入无限背包
--   /take <槽位>[-<槽位>] [数量] (别名 /取)  按槽位取出物品
--   /backpack (别名 /bp)  查看无限背包内容(每行 8 个分多行显示)
--
-- 原版机制:
--   Player.inventory (Item[]): 0~9=快捷栏, 10~49=主背包, 50~57=饰品/时装/染料;
--   存入: 读 Item.type/Item.stack 合并进存储表, 然后把该格 type=0/stack=0 清空;
--   取出: 桌面端 Player.QuickSpawnItem(source,int,int); Android 端 Item.NewItem(9参);
--   反馈消息用原版聊天标签显示物品图标: 数量>1 用 [i/s数量:ID], 否则 [i:ID]。
--
-- 存档: 私有目录 backpack.txt, 每行 "物品ID 数量"; 每次存/取后立即写回。

mod.meta = { pkg_id = "lzup.lua.backpack", version = "1.1.0" }

local patch = mod.patch

-- ============ 可调参数(与 C 版一致) ============
local INVENTORY_FIRST = 10
local INVENTORY_LAST = 49
local MAX_ENTRY_STACK = 9999
local MAX_STORAGE_ENTRIES = 4096
local CHAT_LIST_LIMIT = 8
local SAVE_FILE = "backpack.txt"

-- ============ 状态 ============
-- store: 数组 { {type=int, stack=int}, ... }  (1 起始)
local store = {}
local dirty = false
local fired = false

-- ============ 类型句柄 ============
local T_MAIN, T_PLAYER, T_ITEM

-- ============ 字段句柄 ============
local F_main_player      -- Main.player (Player[], 静态)
local F_my_player        -- Main.myPlayer (static int, 桌面端)
local F_inventory        -- Player.inventory (Item[])
local F_item_type        -- Item.type (int)
local F_item_stack       -- Item.stack (int)
local F_pos, F_width, F_height  -- Player 位置/尺寸(继承自 Entity)

-- ============ 方法句柄 ============
local M_get_my_player    -- Main.get_myPlayer (Android 属性 getter)
local M_new_text         -- Main.NewText
local M_new_item         -- Item.NewItem (Android, 9 参)
local M_quick_spawn      -- Player.QuickSpawnItem (桌面端, 3 参)
local M_get_text         -- ChatMessage.get_Text (属性 getter)
local F_msg_text         -- ChatMessage 的 <Text>k__BackingField (回退)

-- ============ 小工具 ============
-- 沿父类链查找字段(Player 的 position/width/height 来自 Entity)
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

-- 是否以 prefix 开头(C 版 strncmp 语义, 此处比较完整前缀)
local function starts(s, prefix)
    if not s then return false end
    return s:sub(1, #prefix) == prefix
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

-- 原版物品标签: 数量>1 用 [i/s数量:物品ID] 显示图标+数字, 否则 [i:物品ID]
local function format_item_tag(id, count)
    if count > 1 then
        return string.format("[i/s%d:%d]", count, id)
    end
    return string.format("[i:%d]", id)
end

-- ============ 存储表操作 ============
local function store_find(t)
    for i = 1, #store do
        if store[i].type == t then return store[i] end
    end
    return nil
end

local function store_append(t, stack)
    if #store >= MAX_STORAGE_ENTRIES then return nil end
    local e = { type = t, stack = stack }
    store[#store + 1] = e
    return e
end

-- 存入数量: 同类先填满未满格(每格最多 9999), 超出开新格; 返回 false=满
local function store_deposit(t, stack)
    if stack > MAX_ENTRY_STACK then stack = MAX_ENTRY_STACK end
    while stack > 0 do
        local e = nil
        for i = 1, #store do
            if store[i].type == t and store[i].stack < MAX_ENTRY_STACK then
                e = store[i]
                break
            end
        end
        if e then
            local add = MAX_ENTRY_STACK - e.stack
            if add > stack then add = stack end
            e.stack = e.stack + add
            stack = stack - add
        else
            local add = stack
            if add > MAX_ENTRY_STACK then add = MAX_ENTRY_STACK end
            if not store_append(t, add) then return false end
            stack = stack - add
        end
    end
    return true
end

-- 从存储表移除一段槽位 [first, last) (0 起始, 保持其余条目顺序不变)
local function store_remove_range(first, last)
    if first < 0 then first = 0 end
    if last > #store then last = #store end
    if first >= last then return end
    -- 0 起始 [first,last) 对应 Lua 索引 [first+1, last]
    for i = last, first + 1, -1 do
        table.remove(store, i)
    end
end

-- ============ 存档读写 ============
local function save_store()
    local lines = {}
    for i = 1, #store do
        lines[i] = string.format("%d %d", store[i].type, store[i].stack)
    end
    local ok, err = mod.write_file(SAVE_FILE, table.concat(lines, "\n") .. "\n")
    if not ok then
        mod.warn(string.format("存档写入失败: %s", tostring(err)))
        return
    end
    dirty = false
end

local function load_store()
    if not mod.file_exists(SAVE_FILE) then return end
    local data = mod.read_file(SAVE_FILE)
    if not data then return end
    local count = 0
    for line in data:gmatch("[^\n]+") do
        local ts, ss = line:match("^%s*(%-?%d+)%s+(%-?%d+)")
        local t, s = tonumber(ts), tonumber(ss)
        if t and s and t > 0 and t < 100000 and s > 0 then
            if s > MAX_ENTRY_STACK then s = MAX_ENTRY_STACK end
            store_append(t, s)
            count = count + 1
        end
    end
    if count > 0 then
        mod.info(string.format("存档加载: %d 种物品", #store))
    end
end

-- ============ 日志/聊天 ============
local function show_chat(text)
    if not text then return end
    if not M_new_text then return end
    local s = patch.string_create(text)
    if not s then return end
    if mod.platform == "android" then
        -- 1.4.5.8: NewText(string, byte R, byte G, byte B, bool onlyCurrentPlayer)
        patch.invoke(M_new_text, s, 255, 255, 255, false)
    else
        -- 桌面端: NewText(string, byte R, byte G, byte B)
        patch.invoke(M_new_text, s, 255, 255, 255)
    end
end

-- ============ 玩家 / 物品栏 ============
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

-- 本地玩家句柄(借用, 只在当次调用内有效)
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

local function get_inventory(player)
    if not player or not F_inventory then return nil end
    return patch.get_field_value(F_inventory, player, "object")
end

-- 把物品发给玩家
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
    -- 桌面端: Player.QuickSpawnItem(source, item, stack), 内部不使用 source, 传 nil 安全
    if not M_quick_spawn then return false end
    patch.invoke(M_quick_spawn, player, nil, id, stack)
    return true
end

-- ============ 指令处理 ============
local function cmd_store()
    local p = local_player()
    if not p then return end
    local inv = get_inventory(p)
    if not inv then show_chat("[无限背包] 背包数组获取失败"); return end
    local len = patch.array_length(inv)
    if len < INVENTORY_FIRST then show_chat("[无限背包] 背包数组过小"); return end

    local last = INVENTORY_LAST
    if len - 1 < last then last = len - 1 end

    local total = 0
    local kinds = 0
    local list = "[无限背包] 已存入:"
    local listed = {}

    for i = INVENTORY_FIRST, last do
        local item = patch.array_at(inv, i)
        if item then
            local t = patch.get_field_value(F_item_type, item, "int32") or 0
            local s = patch.get_field_value(F_item_stack, item, "int32") or 0
            if t > 0 and t < 100000 and s > 0 then
                if not store_deposit(t, s) then
                    show_chat("[无限背包] 存储已满(4096 格), 未完全存入")
                    break
                end
                patch.set_field_value(F_item_type, item, 0, "int32")
                patch.set_field_value(F_item_stack, item, 0, "int32")
                total = total + s
                local seen = false
                for _, lt in ipairs(listed) do
                    if lt == t then seen = true; break end
                end
                if not seen then
                    listed[#listed + 1] = t
                    local e = store_find(t)
                    if kinds < 20 and e then
                        list = list .. " " .. format_item_tag(t, e.stack)
                    end
                    kinds = kinds + 1
                end
                dirty = true
            end
        end
    end
    if total == 0 then
        show_chat("[无限背包] 背包(快捷栏以外)没有可存入的物品")
        return
    end
    if kinds > 20 then
        list = list .. string.format(" …等 %d 种", kinds)
    end
    list = list .. string.format(" 共 %d 件 (存前 %d 种, 现共 %d 种)", total, kinds, #store)
    show_chat(list)
    save_store()
end

local function cmd_take(rest)
    if not rest or rest == "" then
        show_chat("[无限背包] 用法: /take <槽位>[-<槽位>] [数量]")
        show_chat("[无限背包] 单槽缺省数量=1, 范围(如 1-5)整格全部取出")
        return
    end

    local a, e = strtol(rest, 1)
    if not a or a < 1 or a > #store then
        show_chat(string.format("[无限背包] 无效的槽位 (1 ~ %d), 先用 /backpack 查看", #store))
        return
    end

    local b = nil
    if rest:sub(e, e) == "-" then
        local bv, e2 = strtol(rest, e + 1)
        if not bv or bv < a or bv > #store then
            show_chat("[无限背包] 无效的范围终点")
            return
        end
        b = bv
        e = e2
    end

    local p = local_player()
    if not p then
        show_chat("[无限背包] 玩家实例获取失败")
        return
    end

    -- ---- 范围模式: 整格全部取出 ----
    if b then
        -- 先拷贝快照, 再统一移除, 最后发放(顺序稳定)
        local snapshot = {}
        for i = a, b do
            snapshot[#snapshot + 1] = { type = store[i].type, stack = store[i].stack }
        end
        store_remove_range(a - 1, b)
        for i = 1, #snapshot do
            if not give_item(p, snapshot[i].type, math.floor(snapshot[i].stack)) then
                show_chat("[无限背包] 发放物品失败(方法解析问题)")
                return
            end
        end
        show_chat(string.format("[无限背包] 已取出槽位 %d-%d", a, b))
        local line = ""
        local shown = 0
        for i = 1, #snapshot do
            local tag = format_item_tag(snapshot[i].type, snapshot[i].stack)
            if #line + #tag + 8 >= 1024 then
                show_chat(line)
                line = ""
                shown = 0
            end
            if shown > 0 then line = line .. " |" end
            line = line .. " " .. tag
            shown = shown + 1
        end
        if #line > 0 then show_chat(line) end
        save_store()
        return
    end

    -- ---- 单槽模式 ----
    local want = 1
    if e <= #rest then
        local v = strtol(rest, e)
        if v and v > 0 then
            want = v > MAX_ENTRY_STACK and MAX_ENTRY_STACK or v
        end
    end
    local entry = store[a]
    local id = entry.type
    local give = want
    if give > entry.stack then give = entry.stack end

    if not give_item(p, id, math.floor(give)) then
        show_chat("[无限背包] 发放物品失败(方法解析问题)")
        return
    end
    entry.stack = entry.stack - give
    local left = entry.stack
    if left <= 0 then
        store_remove_range(a - 1, a)
    end
    show_chat(string.format("[无限背包] 已取出槽位%d的 %s (剩余 %d)",
        a, format_item_tag(id, give), left))
    save_store()
end

-- 把 [first,last) (0 起始) 范围内的槽位列表发到聊天框: 每行 8 个, | 分隔
local function show_entry_lines(first, last)
    local base = first
    while base < last do
        local line = ""
        local shown = 0
        local i = base
        while i < last and shown < CHAT_LIST_LIMIT do
            local entry = store[i + 1]
            local tag = format_item_tag(entry.type, entry.stack)
            if shown > 0 then line = line .. " |" end
            line = line .. string.format(" %d %s", i + 1, tag)
            i = i + 1
            shown = shown + 1
        end
        show_chat(line)
        base = base + CHAT_LIST_LIMIT
    end
end

local function cmd_list()
    if #store == 0 then show_chat("[无限背包] 是空的"); return end
    show_chat("[无限背包]")
    local total = 0
    for i = 1, #store do total = total + store[i].stack end
    show_entry_lines(0, #store)
    show_chat(string.format("[无限背包] 共 %d 格 / %d 件", #store, total))
end

local function is_mod_command(t)
    if not t or t:sub(1, 1) ~= "/" then return false end
    return starts(t, "/store") or starts(t, "/存") or
        starts(t, "/take") or starts(t, "/取") or
        starts(t, "/backpack") or starts(t, "/bp")
end

local function handle_command(raw)
    if not raw then return end
    if starts(raw, "/store") or starts(raw, "/存") then
        cmd_store()
    elseif starts(raw, "/take") or starts(raw, "/取") then
        local prefix = starts(raw, "/take") and "/take" or "/取"
        local rest = trim_left(raw:sub(#prefix + 1))
        cmd_take(rest)
    elseif starts(raw, "/backpack") or starts(raw, "/bp") then
        cmd_list()
    end
end

-- ============ Hook: 读取聊天文本 ============
local function read_message_text(message)
    if not message then return nil end
    if M_get_text then
        local s = patch.invoke(M_get_text, message)
        if s then
            local v = patch.string_value(s)
            if v then return v end
        end
    end
    -- 回退: 读自动属性背后的字段(伪类型 "string")
    if F_msg_text then
        return patch.get_field_value(F_msg_text, message, "string")
    end
    return nil
end

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
    mod.info("初始化无限背包模组")

    T_MAIN = patch.get_type("Terraria", "Main")
    T_PLAYER = patch.get_type("Terraria", "Player")
    T_ITEM = patch.get_type("Terraria", "Item")
    if not T_MAIN or not T_PLAYER or not T_ITEM then
        mod.error("获取类型失败 (Main/Player/Item)")
        return
    end

    -- 字段
    F_main_player = patch.get_field(T_MAIN, "player")
    F_my_player = patch.get_field(T_MAIN, "myPlayer")
    F_inventory = patch.get_field(T_PLAYER, "inventory")
    F_item_type = patch.get_field(T_ITEM, "type")
    F_item_stack = patch.get_field(T_ITEM, "stack")
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
    -- 取不到回退方法名 get_myPlayer(静态字段 F_my_player 仍是最终回退)。
    local my_player_prop = patch.get_property(T_MAIN, "myPlayer")
    if my_player_prop then
        M_get_my_player = patch.property_get_method(my_player_prop)
    end
    if not M_get_my_player then
        M_get_my_player = patch.get_method(T_MAIN, "get_myPlayer", 0)
    end
    if not M_get_my_player and not F_my_player then
        mod.warn("Main.myPlayer 字段与 get_myPlayer 均不可用")
    end

    -- 聊天消息文本 getter
    local msg_type = patch.get_type("Terraria.Chat", "ChatMessage")
    if msg_type then
        M_get_text = patch.get_method(msg_type, "get_Text", 0)
        F_msg_text = patch.get_field(msg_type, "<Text>k__BackingField")
    end

    if not F_main_player or not F_inventory or not F_item_type or not F_item_stack then
        mod.error("获取字段失败: player/inventory/type/stack")
        return
    end

    -- 加载存档
    load_store()

    -- Hook 聊天(postfix)
    local chat_type = patch.get_type("Terraria.Chat", "ChatCommandProcessor")
    local chat_method = chat_type and patch.get_method(chat_type, "ProcessIncomingMessage", 2)
    if not safe_hook(chat_method, { postfix = on_process_incoming }, "ProcessIncomingMessage") then
        mod.warn("ProcessIncomingMessage Hook 未安装(单机指令可能不可用)")
    end

    local helper_type = patch.get_type("Terraria.Chat", "ChatHelper")
    local send_method = helper_type and patch.get_method(helper_type, "SendChatMessageFromClient", 1)
    if not safe_hook(send_method, { postfix = on_send_from_client }, "SendChatMessageFromClient") then
        mod.warn("SendChatMessageFromClient Hook 未安装(多人客户端指令可能不可用)")
    end

    mod.info(string.format("初始化完成: 存储=%d 种, /store /take /backpack 可用", #store))
end

function cleanup()
    if dirty then save_store() end
    mod.info("清理模组")
end

todo_list = { "setup" }
