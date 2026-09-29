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
  ChaosGen - 混沌生成 —— LuaLoader (Lua) 版
  ---------------------------------------------------------------------------
  由 KernelLoader(C) 版 Mods/TEKernelMods/ChaosGen/main.c 移植，功能对齐。

  功能: 每次新建世界、世界生成完成后, 自动把全世界所有"实心方块"随机化为
        任意"安全"图格(0 ~ TileID.Count-1 中非 frameImportant 的类型)。
        全图随机化, 不保留任何区域。

  实现对照:
    * C 版 Hook WorldGen.Reset 的 postfix -> 置"新世界生成中"标记;
    * C 版 Hook Player.ResetEffects 的 postfix 作为每帧 tick:
        等待 WorldGen.generatingWorld 变 false -> 首次构建安全候选表 + 播种 ->
        每帧分帧随机化一段 -> 完成后标记 done;
    * 安全候选表: 遍历 Main.tileFrameImportant(bool[]), 只保留非 important 的图格 ID;
    * 随机性: xorshift32 + 时间种子, 与 C 版算法一致;
    * 只随机化实心方块: Tile.sTileHeader 的 bit5(0x20 == active) 为 1 才处理。

  === 与 C 版的平台差异(重要) ===
  Android(已用 C 快通道实现): 用 LuaLoader 1.3.0 新增的
      field_pointer + ptr_deref + mem_read_values + mem_read + mem_write
  解析并直接操作 TileData 原生数组 (TileLookup/TileType/TileSHeader/FrameX/FrameY),
  与 C 版 Android 一致按行带(48 行/帧)高速随机化:
      idx = TileLookup[y*maxTilesX+x]; 若 TileSHeader[idx] 的 active 位为 1,
      则 TileType[idx] = 随机安全类型, FrameX/FrameY[idx] = 0。
  每行先用 mem_read_values 批量读取 TileLookup, 再逐格读写。
  桌面端: field_pointer 返回 nil, 自动回退到 C 版**桌面端**方案(已被 C 版验证):
      Framing.GetTileSafely(x,y) -> Tile 对象 -> 读/写 Tile.type / Tile.sTileHeader
      / Tile.frameX / Tile.frameY, 采用"线性游标 + 每帧 4000 格"分帧。
  若某平台取不到任何可用路径, 则跳过随机化。

  === 与 C 版的其它差异 ===
  * C 版桌面端不检查 generatingWorld; 本 Lua 版对全平台都检查该字段(与 C 版
    Android 语义一致), 确保不会在后台生成过程中随机化。
--]]

mod.meta = { pkg_id = "lzup.lua.chaosgen", version = "1.2.0" }

local patch = mod.patch

-- ============ 常量 (与 C 版一致) ============
local TILE_TYPE_COUNT = 754          -- [0, TileID.Count)
local ACTIVE_MASK = 0x20             -- Tile.sTileHeader 实心标志
local TILES_PER_FRAME = 4000         -- 桌面端每帧处理格数上限(防卡顿)
local ANDROID_ROWS_PER_FRAME = 48    -- Android 快通道每帧处理行数(与 C 版一致)

local NO_TILE = 0xFFFFFFFF
-- 越界保护: TileType 合法索引上限(大世界约 2000 万格, 这里给足余量)
local MAX_TILE_INDEX = 0x10000000

-- ============ 句柄 (setup 中解析) ============
local f_max_tiles_x          -- Main.maxTilesX (static int32)
local f_max_tiles_y          -- Main.maxTilesY (static int32)
local f_generating_world     -- WorldGen.generatingWorld (static bool)
local f_tile_frame_important -- Main.tileFrameImportant (static bool[])
local f_tile_type            -- Tile.type (uint16, 桌面端托管回退)
local f_tile_sheader         -- Tile.sTileHeader (uint16, 桌面端托管回退)
local f_tile_framex          -- Tile.frameX (int16, 桌面端托管回退)
local f_tile_framey          -- Tile.frameY (int16, 桌面端托管回退)
local m_get_tile_safely      -- Framing.GetTileSafely (static, 2 参, 桌面端托管回退)

-- ============ Android C 快通道 (桌面端 field_pointer 返回 nil, 保持禁用) ============
local android_fast = false -- true 时才走原生数组路径
local p_max_tiles_x        -- &Main.maxTilesX         (int*)
local p_max_tiles_y        -- &Main.maxTilesY         (int*)
local p_tile_lookup        -- &TileData.TileLookup    (uint**)
local p_tile_type          -- &TileData.TileType      (ushort**)
local p_tile_sheader       -- &TileData.TileSHeader   (int16**)
local p_tile_framex        -- &TileData.TileFrameX    (int16**)
local p_tile_framey        -- &TileData.TileFrameY    (int16**)

-- ============ 状态 (对应 C 版全局状态) ============
local in_world_gen = false
local done = false
local work_started = false
local progress = 0
local work_total = 0
local work_pos = 0
local android_rows = 0   -- Android 快通道: 世界总行数
local android_row = 0    -- Android 快通道: 已处理行游标
local total_changed = 0
local safe_types = {}
local safe_count = 0

-- ============ 随机数 (xorshift32, 与 C 版算法一致) ============
local rng = 0x13579BDF

local function seed_rng()
    math.randomseed(os.time())
    local t = os.time() & 0xFFFFFFFF
    local r = math.random(0, 0xFFFFFF)
    rng = (t ~ 0x9E3779B9 ~ r) & 0xFFFFFFFF
end

local function rand()
    local x = rng
    x = x ~ ((x << 13) & 0xFFFFFFFF)
    x = x & 0xFFFFFFFF
    x = x ~ (x >> 17)
    x = x & 0xFFFFFFFF
    x = x ~ ((x << 5) & 0xFFFFFFFF)
    x = x & 0xFFFFFFFF
    rng = x
    return x
end

local function random_tile_type()
    if safe_count > 0 then
        return safe_types[(rand() % safe_count) + 1]
    end
    return rand() % TILE_TYPE_COUNT
end

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

local function read_static_bool(field)
    if not field then return false end
    return patch.get_field_value(field, nil, "bool") == true
end

--- 构建安全随机候选表: 排除 Main.tileFrameImportant 图格
--- 返回候选数, 0 表示失败 (对应 C 版 BuildSafeTypes)
local function build_safe_types()
    safe_count = 0
    if not f_tile_frame_important then return 0 end

    local arr = patch.get_field_value(f_tile_frame_important, nil, "object")
    if not arr then return 0 end

    local n = patch.array_length(arr)
    local limit = TILE_TYPE_COUNT
    if n < limit then limit = n end

    for i = 0, limit - 1 do
        local important = patch.array_at(arr, i, "bool")
        if important == false then
            safe_count = safe_count + 1
            safe_types[safe_count] = i
        end
    end
    return safe_count
end

--- 用 Framing.GetTileSafely 取 Tile 对象; 越界/失败返回 nil
local function get_tile_object(x, y)
    if not m_get_tile_safely then return nil end
    local max_x = read_static_int(f_max_tiles_x)
    local max_y = read_static_int(f_max_tiles_y)
    if max_x <= 0 or max_y <= 0 then return nil end
    if x < 0 or y < 0 or x >= max_x or y >= max_y then return nil end
    return patch.invoke(m_get_tile_safely, x, y)
end

--- 随机化单个坐标的方块 (只处理实心方块) (对应 C 版 DesktopRandomizeTile)
local function randomize_tile(x, y)
    if not f_tile_type or not f_tile_sheader then return end
    local tile = get_tile_object(x, y)
    if not tile then return end

    local sh = patch.get_field_value(f_tile_sheader, tile, "uint16")
    if sh == nil or (sh & ACTIVE_MASK) == 0 then return end

    local rnd_type = random_tile_type()
    patch.set_field_value(f_tile_type, tile, rnd_type, "uint16")
    if f_tile_framex then
        patch.set_field_value(f_tile_framex, tile, 0, "int16")
    end
    if f_tile_framey then
        patch.set_field_value(f_tile_framey, tile, 0, "int16")
    end
    total_changed = total_changed + 1
end

-- ============ Android C 快通道 ============
--- 从原生静态字段读取世界尺寸; 未就绪返回 nil
local function android_world_size()
    local max_x = patch.mem_read_values(p_max_tiles_x, 0, 1, "int32")[1]
    local max_y = patch.mem_read_values(p_max_tiles_y, 0, 1, "int32")[1]
    if not max_x or not max_y or max_x <= 0 or max_y <= 0 then return nil end
    return max_x, max_y
end

--- 随机化行带 [y_from, y_to); 对应 C 版 Android Pass_RandomizeBand
local function android_randomize_band(y_from, y_to)
    if not android_fast then return end
    local max_x, max_y = android_world_size()
    if not max_x then return end
    if y_from < 0 then y_from = 0 end
    if y_to > max_y then y_to = max_y end

    -- 每次执行时重新解引用: 换世界后数组可能被重新分配
    local lookup  = patch.ptr_deref(p_tile_lookup, 0)
    local types   = patch.ptr_deref(p_tile_type, 0)
    local sheader = patch.ptr_deref(p_tile_sheader, 0)
    local framex  = p_tile_framex and patch.ptr_deref(p_tile_framex, 0) or nil
    local framey  = p_tile_framey and patch.ptr_deref(p_tile_framey, 0) or nil
    if not lookup or not types or not sheader then return end

    local ZERO16 = string.pack("<h", 0)   -- FrameX/FrameY 清零用
    for y = y_from, y_to - 1 do
        -- 批量读取整行 TileLookup (连续 uint32), 减少 C 边界调用
        local row = patch.mem_read_values(lookup, y * max_x * 4, max_x, "uint32")
        for x = 0, max_x - 1 do
            local idx = row[x + 1]
            if idx ~= nil and idx ~= NO_TILE and idx < MAX_TILE_INDEX then
                -- 只随机化实心方块: 空气/墙/液体所在格保持原样
                local sh = string.unpack("<h", patch.mem_read(sheader, idx * 2, 2))
                if (sh & ACTIVE_MASK) ~= 0 then
                    local rnd_type = random_tile_type()
                    patch.mem_write(types, idx * 2, string.pack("<H", rnd_type))
                    if framex then patch.mem_write(framex, idx * 2, ZERO16) end
                    if framey then patch.mem_write(framey, idx * 2, ZERO16) end
                    total_changed = total_changed + 1
                end
            end
        end
    end
end

-- ============ Hook: WorldGen.Reset -> 新世界开始生成 ============
local function reset_postfix(instance, args, result)
    in_world_gen = true
    done = false
    work_started = false
    progress = 0
    work_pos = 0
    android_row = 0
    android_rows = 0
    total_changed = 0
end

-- ============ Hook: Player.ResetEffects(每帧) -> 分帧随机化 ============
local function reseteffects_postfix(instance, args, result)
    if not in_world_gen or done then return end
    -- generatingWorld 仍为 true 说明后台还在生成, 等待
    if read_static_bool(f_generating_world) then return end

    -- 首次调用: 初始化随机源与安全候选表
    if not work_started then
        progress = 0
        work_pos = 0
        android_row = 0

        if android_fast then
            -- Android 快通道: 从原生字段取世界尺寸
            local max_x, max_y = android_world_size()
            if not max_x then return end   -- 尺寸尚未就绪, 下一帧重试
            android_rows = max_y
            work_total = max_x * max_y
            mod.info(string.format("android full-map randomize rows=%d tiles=%d",
                    android_rows, work_total))
        else
            -- 桌面端: 托管方案, 线性游标
            local max_x = read_static_int(f_max_tiles_x)
            local max_y = read_static_int(f_max_tiles_y)
            if max_x < 1 then max_x = 4200 end
            if max_y < 1 then max_y = 1200 end
            work_total = max_x * max_y
            mod.info(string.format("desktop full-map randomize tiles=%d", work_total))

            if not f_tile_type or not f_tile_sheader or not m_get_tile_safely then
                mod.error("tile fields not ready, skip randomization")
                done = true
                in_world_gen = false
                return
            end
        end

        work_started = true
        seed_rng()
        if build_safe_types() <= 0 then
            mod.error("tileFrameImportant unavailable, skip randomization")
            done = true
            in_world_gen = false
            return
        end
        mod.info(string.format("== chaos generation start (safe types=%d) ==", safe_count))
    end

    -- 每帧处理一段
    if android_fast then
        -- Android: 行带式 (48 行/帧), 与 C 版一致
        local from = android_row
        local to = from + ANDROID_ROWS_PER_FRAME
        if to > android_rows then to = android_rows end
        android_randomize_band(from, to)
        android_row = to
        progress = to

        if android_row >= android_rows then
            done = true
            in_world_gen = false
            mod.info(string.format("== chaos generation done (changed=%d) ==", total_changed))
        end
        return
    end

    -- 桌面端: 线性游标 + 每帧格数上限
    local max_x = read_static_int(f_max_tiles_x)
    if max_x < 1 then max_x = 4200 end

    local budget = TILES_PER_FRAME
    local processed = 0
    while processed < budget and work_pos < work_total do
        local idx = work_pos
        work_pos = work_pos + 1
        randomize_tile(idx % max_x, math.floor(idx / max_x))
        processed = processed + 1
    end
    progress = math.floor(work_pos / max_x)

    if work_pos >= work_total then
        done = true
        in_world_gen = false
        mod.info(string.format("== chaos generation done (changed=%d) ==", total_changed))
    end
end

-- ============ 钩子安装 ============
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
    mod.info("初始化混沌生成模组")

    local main_type = patch.get_type("Terraria", "Main")
    local worldgen_type = patch.get_type("Terraria", "WorldGen")
    local player_type = patch.get_type("Terraria", "Player")
    local framing_type = patch.get_type("Terraria", "Framing")
    local tile_type = patch.get_type("Terraria", "Tile")

    if not main_type or not worldgen_type or not player_type then
        mod.error("获取类型失败 (Main/WorldGen/Player)")
        return
    end

    -- 方块数据字段 (桌面端托管方案)
    f_max_tiles_x = find_field(main_type, "maxTilesX")
    f_max_tiles_y = find_field(main_type, "maxTilesY")
    f_generating_world = find_field(worldgen_type, "generatingWorld")
    f_tile_frame_important = find_field(main_type, "tileFrameImportant")
    if tile_type then
        f_tile_type = find_field(tile_type, "type")
        f_tile_sheader = find_field(tile_type, "sTileHeader")
        f_tile_framex = find_field(tile_type, "frameX")
        f_tile_framey = find_field(tile_type, "frameY")
    end
    if framing_type then
        m_get_tile_safely = patch.get_method(framing_type, "GetTileSafely", 2)
            or patch.get_method(framing_type, "GetTileSafely")
    end

    -- Android C 快通道: 解析 TileData 原生数组静态字段的真实指针。
    -- (桌面端 field_pointer 返回 nil, android_fast 保持 false, 自动走托管回退)
    if mod.platform == "android" then
        local tiledata_type = patch.get_type("Terraria", "TileData")
        if tiledata_type then
            local f_lookup = find_field(tiledata_type, "TileLookup")
            local f_type_arr = find_field(tiledata_type, "TileType")
            local f_sh = find_field(tiledata_type, "TileSHeader")
            local f_fx = find_field(tiledata_type, "TileFrameX")
            local f_fy = find_field(tiledata_type, "TileFrameY")
            if f_lookup then p_tile_lookup = patch.field_pointer(f_lookup, nil) end
            if f_type_arr then p_tile_type = patch.field_pointer(f_type_arr, nil) end
            if f_sh then p_tile_sheader = patch.field_pointer(f_sh, nil) end
            if f_fx then p_tile_framex = patch.field_pointer(f_fx, nil) end
            if f_fy then p_tile_framey = patch.field_pointer(f_fy, nil) end
            if f_max_tiles_x then p_max_tiles_x = patch.field_pointer(f_max_tiles_x, nil) end
            if f_max_tiles_y then p_max_tiles_y = patch.field_pointer(f_max_tiles_y, nil) end

            android_fast = p_tile_lookup ~= nil and p_tile_type ~= nil
                and p_tile_sheader ~= nil
                and p_max_tiles_x ~= nil and p_max_tiles_y ~= nil
        end
        if android_fast then
            mod.info("ChaosGen: 使用 Android TileData C 快通道")
        else
            mod.warn("ChaosGen: Android C 快通道不可用, 回退 Framing.GetTileSafely")
        end
    end

    if android_fast then
        -- 快通道只需 tileFrameImportant 构建安全类型表
        if not f_tile_frame_important then
            mod.error("获取 tileFrameImportant 失败")
            return
        end
    elseif not f_tile_type or not f_tile_sheader or not f_tile_frame_important
            or not m_get_tile_safely then
        mod.error("获取桌面端方块字段失败")
        return
    end

    -- WorldGen.Reset (静态, 0 参)
    local reset_method = patch.get_method(worldgen_type, "Reset", 0)
        or patch.get_method(worldgen_type, "Reset")
    if not reset_method then
        mod.error("获取 WorldGen.Reset 方法失败")
        return
    end

    -- Player.ResetEffects (实例, 0 参) 用作每帧 tick
    local reset_effects = patch.get_method(player_type, "ResetEffects", 0)
        or patch.get_method(player_type, "ResetEffects")
    if not reset_effects then
        mod.error("获取 ResetEffects 方法失败")
        return
    end

    local ok1 = safe_hook(reset_method, { postfix = reset_postfix }, "WorldGen.Reset")
    local ok2 = safe_hook(reset_effects, { postfix = reseteffects_postfix }, "Player.ResetEffects")
    if ok1 and ok2 then
        mod.info("成功 Hook Reset / ResetEffects, 混沌生成已启用")
    end
end

todo_list = { "setup" }
