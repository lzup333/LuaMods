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
        例如挖掉一块铁矿, 会把连在一起的整条铁矿脉全部挖掉; 挖石头/泥土不会连锁。

  实现对照(与 C 版逐段对应):
    * C 版 Hook Player.PickTile 的 prefix/postfix:
        - prefix: 记录重入深度, 最外层调用时捕获被挖方块类型(此时尚未销毁);
        - postfix: 最外层且方块确已销毁(type==0)且是矿石/宝石时, 调用 ChainMine。
    * ChainMine: 以 (ox,oy) 为起点做 4 邻接 BFS, 只连锁与 origin 同类型的方块,
                 调用 WorldGen.KillTile(i,j,false,false,noItem) 破坏。
    * 连锁上限 256, 搜索半径 32, 仅矿石/宝石类型会触发。

  === 与 C 版的平台差异(重要) ===
  Android(已用 C 快通道实现): 用 LuaLoader 1.3.0 新增的
      field_pointer + ptr_deref + mem_read_values
  复刻 C 版 Android 原生 TileData 数组方案:
      idx  = TileLookup[y*maxTilesX+x]   (索引 0xFFFFFFFF 表示空)
      type = TileType[idx]
  与 C 版 Android 路径逐行等价, 热路径不再调用 il2cpp 运行时函数。
  桌面端: field_pointer 返回 nil, 自动回退到 C 版**桌面端**方案:
      Framing.GetTileSafely(x,y) -> Tile 对象 -> 读 Tile.type 字段
  该路径在桌面端已被 C 版验证可用; GetTileSafely 是静态方法(2 个 int 参数,
  返回对象), WorldGen.KillTile 是静态方法(5 个标量参数), Player.PickTile 是
  实例方法(4 个 int 参数) —— 全部只有标量参数, 可正常走 mod.patch.invoke。

  === 与 C 版的其它差异 ===
  * C 版 prefix 实测 false=执行原方法、true=跳过; Lua 版一致:
      prefix 返回 false  => 执行原方法(与 C 相同)。
  * C 版用运行时指针做热路径优化; Lua 版把字段/方法句柄缓存在 local
    upvalue 中。Android 快通道解析一次静态字段地址后只做
    ptr_deref/mem_read_values; 桌面端回退时每帧只做 get_field_value/invoke, 不重复 get_field。
--]]

mod.meta = { pkg_id = "lzup.lua.veinminer", version = "1.2.0" }

local patch = mod.patch

-- ============ 连锁类型表 (与 C 版一致) ============
-- 矿石 Tile ID
local ORE_TYPES = {
    6, 7, 8, 9, 22, 37, 56, 58,
    107, 108, 111,
    166, 167, 168, 169,
    204, 211, 221, 222, 223,
    408,
}
-- 宝石 Tile ID
local GEM_TYPES = { 63, 64, 65, 66, 67, 68, 178, 566 }

-- 类型查询集合(替代 C 版的线性查找, 等价)
local VEIN_SET = {}
for _, t in ipairs(ORE_TYPES) do VEIN_SET[t] = true end
for _, t in ipairs(GEM_TYPES) do VEIN_SET[t] = true end

local function is_vein_type(t)
    return t ~= nil and VEIN_SET[t] == true
end

-- ============ 常量 (与 C 版一致) ============
local MAX_CHAIN_TILES = 256
local CHAIN_RADIUS = 32
local DX = { 0, 0, -1, 1 }
local DY = { -1, 1, 0, 0 }

-- ============ 句柄 (setup 中解析并缓存) ============
local f_max_tiles_x      -- Main.maxTilesX (static int32)
local f_max_tiles_y      -- Main.maxTilesY (static int32)
local f_tile_type        -- Tile.type (uint16, 桌面端托管回退)
local m_get_tile_safely  -- Framing.GetTileSafely (static, 2 参, 桌面端托管回退)
local m_kill_tile        -- WorldGen.KillTile (static, 5 参)

-- ============ Android C 快通道 (桌面端 field_pointer 返回 nil, 保持禁用) ============
local android_fast = false -- true 时才走原生数组路径
local p_max_tiles_x        -- &Main.maxTilesX       (lightuserdata, int*)
local p_max_tiles_y        -- &Main.maxTilesY       (lightuserdata, int*)
local p_tile_lookup        -- &TileData.TileLookup  (lightuserdata, uint**)
local p_tile_type          -- &TileData.TileType    (lightuserdata, ushort**)

local NO_TILE = 0xFFFFFFFF
-- 越界保护: TileType 合法索引上限(大世界约 2000 万格, 这里给足余量)
local MAX_TILE_INDEX = 0x10000000

-- ============ 状态 (对应 C 版 g_killDepth / g_lastKilledType) ============
local kill_depth = 0
local last_killed_type = 0

-- ============ 工具 ============
-- 沿父类链查找字段
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

--- Android C 快通道读取方块类型; 快通道不可用返回 nil (由调用方回退托管路径)
--- 对应 C 版 Android GetTileType: TileType[TileLookup[y*maxX+x]]
local function get_tile_type_android(x, y)
    if not android_fast then return nil end

    local max_x = patch.mem_read_values(p_max_tiles_x, 0, 1, "int32")[1]
    local max_y = patch.mem_read_values(p_max_tiles_y, 0, 1, "int32")[1]
    if not max_x or not max_y or max_x <= 0 or max_y <= 0 then return 0 end
    if x < 0 or y < 0 or x >= max_x or y >= max_y then return 0 end

    -- 每次读取时重新解引用: 换世界后数组可能被重新分配
    local lookup = patch.ptr_deref(p_tile_lookup, 0)
    if not lookup then return 0 end
    local idx = patch.mem_read_values(lookup, (y * max_x + x) * 4, 1, "uint32")[1]
    if idx == nil or idx == NO_TILE then return 0 end          -- 0xFFFFFFFF = 空
    if idx >= MAX_TILE_INDEX then return 0 end                 -- 越界保护, 避免野偏移

    local types = patch.ptr_deref(p_tile_type, 0)
    if not types then return 0 end
    local t = patch.mem_read_values(types, idx * 2, 1, "uint16")[1]
    if t == nil then return 0 end
    return t
end

--- 读取指定坐标的方块类型; 0 表示空/越界/读取失败 (对应 C 版 GetTileType)
local function get_tile_type(x, y)
    -- Android: 优先走 C 快通道
    local fast_type = get_tile_type_android(x, y)
    if fast_type ~= nil then return fast_type end

    -- 桌面端 / 快通道不可用: Framing.GetTileSafely 托管回退
    if not m_get_tile_safely or not f_tile_type then return 0 end
    local max_x = read_static_int(f_max_tiles_x)
    local max_y = read_static_int(f_max_tiles_y)
    if max_x <= 0 or max_y <= 0 then return 0 end
    if x < 0 or y < 0 or x >= max_x or y >= max_y then return 0 end

    local tile = patch.invoke(m_get_tile_safely, x, y)
    if not tile then return 0 end   -- 空 Tile -> 空气
    local t = patch.get_field_value(f_tile_type, tile, "uint16")
    if t == nil then return 0 end
    return t
end

--- 调用 WorldGen.KillTile 破坏方块 (对应 C 版 CallKillTile)
local function call_kill_tile(i, j, fail, effect_only, no_item)
    if not m_kill_tile then return end
    patch.invoke(m_kill_tile, i, j, fail, effect_only, no_item)
end

--- 连锁逻辑 (对应 C 版 ChainMine): 4 邻接 BFS, 同类型且相连
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

            -- 限制搜索半径, 防止误挖远处方块
            if nx >= ox - CHAIN_RADIUS and nx <= ox + CHAIN_RADIUS
               and ny >= oy - CHAIN_RADIUS and ny <= oy + CHAIN_RADIUS then

                -- 已访问检查(防止死循环)
                local seen = false
                for v = 1, count do
                    if queue[v][1] == nx and queue[v][2] == ny then
                        seen = true
                        break
                    end
                end

                if not seen and get_tile_type(nx, ny) == tile_type then
                    if count >= MAX_CHAIN_TILES then return end   -- 达到连锁上限
                    count = count + 1
                    queue[count] = { nx, ny }
                    call_kill_tile(nx, ny, false, false, no_item)
                end
            end
        end
    end
end

-- ============ Hook: Player.PickTile ============
--- Prefix: 原方法执行前捕获被挖方块的类型 (对应 C 版 PickTile_Prefix)
local function picktile_prefix(instance, args, result)
    local d = kill_depth
    kill_depth = kill_depth + 1

    -- 仅在最外层调用时捕获类型(此时方块还没被销毁)
    if d == 0 and args then
        last_killed_type = get_tile_type(args[1], args[2])
    end

    -- false = 正常执行原方法
    return false
end

--- Postfix: 玩家成功挖掉矿石/宝石后, 对同类型的相连方块执行连锁
local function picktile_postfix(instance, args, result)
    if kill_depth <= 0 then return end

    if kill_depth == 1 and args then
        local i = args[1]
        local j = args[2]

        -- 目标方块已被成功挖掉(原版 PickTile 内部调用 KillTile 完成破坏)才连锁
        if get_tile_type(i, j) == 0 then
            local tile_type = last_killed_type
            -- 类型 0 表示空气/读取失败
            if tile_type ~= 0 and tile_type < 4096 and is_vein_type(tile_type) then
                chain_mine(i, j, tile_type, false)
            end
        end
    end

    kill_depth = kill_depth - 1
end

--- 安装钩子并吞掉异常
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

-- ============ 初始化 ============
function setup()
    mod.info("初始化连锁挖矿模组")

    local main_type = patch.get_type("Terraria", "Main")
    local worldgen_type = patch.get_type("Terraria", "WorldGen")
    local player_type = patch.get_type("Terraria", "Player")
    local framing_type = patch.get_type("Terraria", "Framing")
    local tile_type = patch.get_type("Terraria", "Tile")

    if not main_type or not worldgen_type or not player_type then
        mod.error("获取类型失败 (Main/WorldGen/Player)")
        return
    end

    -- 方块数据字段 / 读取方法
    f_max_tiles_x = find_field(main_type, "maxTilesX")
    f_max_tiles_y = find_field(main_type, "maxTilesY")
    if tile_type then
        f_tile_type = find_field(tile_type, "type")
    end
    if framing_type then
        m_get_tile_safely = patch.get_method(framing_type, "GetTileSafely", 2)
            or patch.get_method(framing_type, "GetTileSafely")
    end

    -- Android C 快通道: 解析 TileData.TileLookup / TileType 静态字段的真实指针。
    -- (桌面端 field_pointer 返回 nil, android_fast 保持 false, 自动走托管回退)
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

    -- 至少需要一条可用读取路径
    if not android_fast and (not f_tile_type or not m_get_tile_safely) then
        mod.error("获取 Framing.GetTileSafely / Tile.type 失败, 连锁不可用")
        return
    end

    -- WorldGen.KillTile(静态, 5 参): 连锁时直接调用原版
    m_kill_tile = patch.get_method(worldgen_type, "KillTile", 5)
        or patch.get_method(worldgen_type, "KillTile")
    if not m_kill_tile then
        mod.error("获取 WorldGen.KillTile 方法失败")
        return
    end

    -- Player.PickTile(实例, 4 参): 1.4.5.8 签名
    --   (int x, int y, int pickPower, int dealDamageAsIfBaseNumberIs = -1)
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
