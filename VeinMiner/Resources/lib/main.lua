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
--[[
VeinMiner - 连锁挖矿 —— LuaLoader (Lua) 版
---------------------------------------------------------------------------
由 KernelLoader(C) 版 Mods/TEKernelMods/VeinMiner/main.c 移植，功能对齐。

功能: 破坏矿石/宝石方块时, 自动连锁破坏与其同类型、且相连的所有矿石/宝石。

连锁类型由 config.json 的 values.chain_types 提供(逗号分隔的方块ID字符串)。
该文件由 TEFManager 生成并写入私有目录; 包内 Resources/config.json 提供初始值。

实现要点:
* Hook Player.PickTile 的 prefix/postfix:
- prefix: 记录重入深度, 最外层调用时捕获被挖方块类型(此时尚未销毁);
- postfix: 最外层且方块确已销毁(type==0)且是连锁类型时, 调用 ChainMine。
* ChainMine: 以 (ox,oy) 为起点做 4 邻接 BFS, 只连锁与 origin 同类型的方块。

平台差异:
Android: 用 field_pointer + ptr_deref + mem_read_values 走 TileData 原生数组。
桌面端: field_pointer 返回 nil, 回退 Framing.GetTileSafely -> Tile.type。
--]]

mod.meta = { pkg_id = "lzup.lua.veinminer", version = "1.3.0" }

local dkjson = require("dkjson")
local patch = mod.patch

-- ============ 常量 ============
local MAX_CHAIN_TILES = 256
local CHAIN_RADIUS = 32
local DX = { 0, 0, -1, 1 }
local DY = { -1, 1, 0, 0 }

-- ============ 连锁类型集合(由 config.json 填充) ============
local VEIN_SET = {}

local function is_vein_type(t)
    return t ~= nil and VEIN_SET[t] == true
end

local function parse_id_list(s)
    if type(s) ~= "string" then return nil end
    local list = {}
    for n in s:gmatch("%d+") do list[#list + 1] = tonumber(n) end
    if #list == 0 then return nil end
    return list
end

local function rebuild_vein_set(ids)
    VEIN_SET = {}
    if not ids then return end
    for _, t in ipairs(ids) do VEIN_SET[t] = true end
end

-- ============ 句柄 (setup 中解析并缓存) ============
local f_max_tiles_x                         -- Main.maxTilesX
local f_max_tiles_y                         -- Main.maxTilesY
local f_tile_type                           -- Tile.type (桌面端托管回退)
local m_get_tile_safely                     -- Framing.GetTileSafely (桌面端托管回退)
local m_kill_tile                           -- WorldGen.KillTile

-- ============ Android C 快通道 ============
local android_fast = false
local p_max_tiles_x
local p_max_tiles_y
local p_tile_lookup
local p_tile_type

local NO_TILE = 0xFFFFFFFF
local MAX_TILE_INDEX = 0x10000000

-- ============ 状态 ============
local kill_depth = 0
local last_killed_type = 0

-- ============ 工具 ============
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

local function read_static_int(field)
    if not field then return 0 end
    local v = patch.get_field_value(field, nil, "int32")
    if v == nil then return 0 end
    return v
end

local function get_tile_type_android(x, y)
    if not android_fast then return nil end

    local max_x = patch.mem_read_values(p_max_tiles_x, 0, 1, "int32")[1]
    local max_y = patch.mem_read_values(p_max_tiles_y, 0, 1, "int32")[1]
    if not max_x or not max_y or max_x <= 0 or max_y <= 0 then return 0 end
    if x < 0 or y < 0 or x >= max_x or y >= max_y then return 0 end

    local lookup = patch.ptr_deref(p_tile_lookup, 0)
    if not lookup then return 0 end
    local idx = patch.mem_read_values(lookup, (y * max_x + x) * 4, 1, "uint32")[1]
    if idx == nil or idx == NO_TILE then return 0 end
    if idx >= MAX_TILE_INDEX then return 0 end

    local types = patch.ptr_deref(p_tile_type, 0)
    if not types then return 0 end
    local t = patch.mem_read_values(types, idx * 2, 1, "uint16")[1]
    if t == nil then return 0 end
    return t
end

local function get_tile_type(x, y)
    local fast_type = get_tile_type_android(x, y)
    if fast_type ~= nil then return fast_type end

    if not m_get_tile_safely or not f_tile_type then return 0 end
    local max_x = read_static_int(f_max_tiles_x)
    local max_y = read_static_int(f_max_tiles_y)
    if max_x <= 0 or max_y <= 0 then return 0 end
    if x < 0 or y < 0 or x >= max_x or y >= max_y then return 0 end

    local tile = patch.invoke(m_get_tile_safely, x, y)
    if not tile then return 0 end
    local t = patch.get_field_value(f_tile_type, tile, "uint16")
    if t == nil then return 0 end
    return t
end

local function call_kill_tile(i, j, fail, effect_only, no_item)
    if not m_kill_tile then return end
    patch.invoke(m_kill_tile, i, j, fail, effect_only, no_item)
end

local function chain_mine(ox, oy, tile_type, no_item)
    if not m_kill_tile then return end

    local queue = { { ox, oy } }
    local count = 1
    local visited = 0

    while visited < count do
        local cur = queue[visited + 1]
        visited = visited + 1

        for dir = 1, 4 do
            local nx = cur[1] + DX[dir]
            local ny = cur[2] + DY[dir]

            if nx >= ox - CHAIN_RADIUS and nx <= ox + CHAIN_RADIUS
                and ny >= oy - CHAIN_RADIUS and ny <= oy + CHAIN_RADIUS then
                local seen = false
                for v = 1, count do
                    if queue[v][1] == nx and queue[v][2] == ny then
                        seen = true
                        break
                    end
                end

                if not seen and get_tile_type(nx, ny) == tile_type then
                    if count >= MAX_CHAIN_TILES then return end
                    count = count + 1
                    queue[count] = { nx, ny }
                    call_kill_tile(nx, ny, false, false, no_item)
                end
            end
        end
    end
end

-- ============ Hook: Player.PickTile ============
local function picktile_prefix(instance, args, result)
    local d = kill_depth
    kill_depth = kill_depth + 1

    if d == 0 and args then
        last_killed_type = get_tile_type(args[1], args[2])
    end

    return false
end

local function picktile_postfix(instance, args, result)
    if kill_depth <= 0 then return end

    if kill_depth == 1 and args then
        local i = args[1]
        local j = args[2]

        if get_tile_type(i, j) == 0 then
            local tile_type = last_killed_type
            if tile_type ~= 0 and tile_type < 4096 and is_vein_type(tile_type) then
                chain_mine(i, j, tile_type, false)
            end
        end
    end

    kill_depth = kill_depth - 1
end

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

-- ============ 加载配置 ============
local function load_config()
    local text, err = mod.read_file("config.json")
    if not text then
        mod.error("读取 config.json 失败: " .. tostring(err))
        return
    end

    local raw, _, decode_err = dkjson.decode(text)
    if decode_err or type(raw) ~= "table" then
        mod.error("config.json 解析失败: " .. tostring(decode_err))
        return
    end

    local values = raw.values
    if type(values) ~= "table" then
        mod.error("config.json 缺少 values")
        return
    end

    local ids = parse_id_list(values.chain_types)
    if not ids then
        mod.error("config.json 的 chain_types 为空或格式错误")
        return
    end

    rebuild_vein_set(ids)

    local count = 0
    for _ in pairs(VEIN_SET) do count = count + 1 end
    mod.info("连锁类型已加载, 共 " .. count .. " 种方块")
end

-- ============ 初始化 ============
function setup()
    mod.info("初始化连锁挖矿模组")

    load_config()

    local main_type = patch.get_type("Terraria", "Main")
    local worldgen_type = patch.get_type("Terraria", "WorldGen")
    local player_type = patch.get_type("Terraria", "Player")
    local framing_type = patch.get_type("Terraria", "Framing")
    local tile_type = patch.get_type("Terraria", "Tile")

    if not main_type or not worldgen_type or not player_type then
        mod.error("获取类型失败 (Main/WorldGen/Player)")
        return
    end

    f_max_tiles_x = find_field(main_type, "maxTilesX")
    f_max_tiles_y = find_field(main_type, "maxTilesY")
    if tile_type then
        f_tile_type = find_field(tile_type, "type")
    end
    if framing_type then
        m_get_tile_safely = patch.get_method(framing_type, "GetTileSafely", 2)
            or patch.get_method(framing_type, "GetTileSafely")
    end

    if mod.platform == "android" then
        local tiledata_type = patch.get_type("Terraria", "TileData")
        if tiledata_type then
            local f_lookup = find_field(tiledata_type, "TileLookup")
            local f_type_arr = find_field(tiledata_type, "TileType")
            if f_lookup then p_tile_lookup = patch.field_pointer(f_lookup, nil) end
            if f_type_arr then p_tile_type = patch.field_pointer(f_type_arr, nil) end
            if f_max_tiles_x then p_max_tiles_x = patch.field_pointer(f_max_tiles_x, nil) end
            if f_max_tiles_y then p_max_tiles_y = patch.field_pointer(f_max_tiles_y, nil) end

            android_fast = p_tile_lookup ~= nil and p_tile_type ~= nil
                and p_max_tiles_x ~= nil and p_max_tiles_y ~= nil
        end
        if android_fast then
            mod.info("VeinMiner: 使用 Android TileData C 快通道 (TileLookup/TileType)")
        else
            mod.warn("VeinMiner: Android C 快通道不可用, 回退 Framing.GetTileSafely")
        end
    end

    if not android_fast and (not f_tile_type or not m_get_tile_safely) then
        mod.error("获取 Framing.GetTileSafely / Tile.type 失败, 连锁不可用")
        return
    end

    m_kill_tile = patch.get_method(worldgen_type, "KillTile", 5)
        or patch.get_method(worldgen_type, "KillTile")
    if not m_kill_tile then
        mod.error("获取 WorldGen.KillTile 方法失败")
        return
    end

    local picktile = patch.get_method(player_type, "PickTile", 4)
        or patch.get_method(player_type, "PickTile")
    if not picktile then
        mod.error("获取 Player.PickTile 方法失败")
        return
    end

    safe_hook(picktile, { prefix = picktile_prefix, postfix = picktile_postfix }, "Player.PickTile")
    mod.info("成功 Hook Player.PickTile, 连锁挖矿已启用")
end

todo_list = { "setup" }
