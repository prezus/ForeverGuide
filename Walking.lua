-- ============================================================
-- ForeverGuide / Walking.lua
-- The walking way between two points: the path a player walks round walls,
-- cliffs and water, and its length, over the walking maps in Nav/.
--
-- Data: Nav/NavManifest.lua and Nav/NavData<map>.lua, written by codex. A
-- map's file holds each 533-yard tile of the world map (0 Eastern Kingdoms,
-- 1 Kalimdor, 2991 Zephras Isle) as zlib then base64; a tile is decoded with
-- the game's C_EncodingUtil the first time a search reaches it, and dropped
-- again when many others have been used since. A map whose file is missing or
-- does not match the manifest is left out, and walks there stay straight lines.
--
-- A tile's surface is grouped into regions; where two touch, the edge they
-- share is a portal. Each region holds, for each two of its portals, the way
-- between them (its length, and the corners it turns at). A search is A* over
-- the portals; the way found is then pulled straight through the portals it
-- crosses, past those corners: the points drawn, and the yards walked. A walk
-- goes straight from its start to its region's portals and from a portal to
-- its goal, but not to one the pack found no straight line to from that grid
-- cell over the surface: a region wrapping round a cliff (codex #809).
--
-- Positions are world yards (X north, Y west, as Navigation:MapToWorld gives
-- them) and, when known, the height, which picks the floor where floors stack.
--
-- Searches run in a coroutine, a few milliseconds a frame and never in
-- combat (Request); FindWay runs one at once, for the tests. Each search in
-- play that ends fires FG_WALK_SEARCHED with what it found and what it cost
-- (Run.lua records it as WAY). The format and
-- the search follow codex's reference router, which nav check holds to
-- recorded walks: change them together.
-- ============================================================

local _, ns = ...
local Walking = ns:NewModule("Walking")

local floor, abs, sqrt, huge, min, max = math.floor, math.abs, math.sqrt, math.huge, math.min, math.max
local byte = string.byte

-- the pack's format versions read: 3 adds the drops' two sides to 2, decoded alike; 4 adds each region's
-- crooked portals after its stored ways (codex src/nav/pack.ts, #809)
local PACK_VERSIONS = { [2] = true, [3] = true, [4] = true }
local CROOKED_VERSION = 4
local TILE_YARDS = 1600 / 3
local GRID = 64
local CELL = TILE_YARDS / GRID
local SIDE_HERE = 4
-- a drop (codex src/nav/drops.ts, #800): a way down off a ledge too steep to climb back. Its top is a
-- portal of the region it leaves (side 9, other: its landing's portal in the tile), its landing one of
-- the region it lands in (side 10, other: its top's); a walk goes from the top to the landing, never back
local SIDE_DROP, SIDE_LANDING = 9, 10

Walking.SNAP_CELLS = 3       -- grid cells searched round a point whose own cell has no ground
Walking.HEIGHT_YARDS = 40    -- a height further than this from every floor there is ignored
Walking.ON_FLOOR_YARDS = 4   -- a floor this near the height is the point's: the search round it stops
Walking.SWIM_COST = 1.5      -- a swum yard costs this many walked ones
-- What a walked yard costs on each ground, by its class (codex src/nav/ground.ts, #745): normal, road,
-- gentle slope, steep slope, under a roof or a mountain. A region's stored ways are priced already.
Walking.GROUND_COST = { [0] = 1, 0.95, 1.3, 2.5, 1.5 }
Walking.MIN_GROUND_COST = 0.95-- the smallest: the search's heuristic scales by it, so it never overstates
-- A yard in the other faction's town costs a walker this many (codex src/nav/hubs.ts, #746): kept out of
-- where the way round is there, never closed. A region's flags say whose town it is in.
Walking.HOSTILE_TOWN_COST = 20
-- A zone whose lowest level is this many above the walker's costs this many times a yard (codex
-- src/nav/router.ts dangerFor, #747; zones' levels from the manifest's NavZoneLevels).
Walking.DANGER_LEVELS, Walking.DANGER_COST = 4, 3
Walking.DEADLY_LEVELS, Walking.DEADLY_COST = 10, 10
local TOWN_BIT = { Alliance = 32, Horde = 64 }
Walking.BUDGET_MS = 3        -- a search's time a frame
Walking.MAX_TILES = 48       -- decoded tiles kept (about 175 KB each: 8 MB); past it the least recently used go
Walking.MAX_WAYS = 200       -- ways remembered

-- ------------------------------------------------------------
-- The maps: checked against the manifest once, decoded tile by tile
-- ------------------------------------------------------------
local maps = {}      -- world map id -> { tiles = { ["x_y"] = base64 }, decoded = {}, used = {} }
local clock = 0      -- counts tile uses, for dropping the least recently used

--- Load the maps that match the manifest; a map that does not is left out, once reported.
function Walking:Load()
    maps = {}
    local manifest = rawget(ns, "NavManifest")
    if type(manifest) ~= "table" then return end
    for mapID, want in pairs(manifest) do
        if type(mapID) == "number" and type(want) == "table" then
            local data = rawget(ns, "NavMap" .. mapID)
            local count = 0
            if type(data) == "table" and type(data.tiles) == "table" then
                for _ in pairs(data.tiles) do count = count + 1 end
            end
            if type(data) ~= "table" or not PACK_VERSIONS[data.version] or data.hash ~= want.hash or count ~= want.tiles then
                ns.ReportOnce("walking-map-" .. mapID, string.format(
                    "the walking map %d is missing or not the one this release lists; walks there stay straight", mapID))
            else
                maps[mapID] = { tiles = data.tiles, decoded = {}, used = {} }
            end
        end
    end
end

--- The game's codec for the tiles (zlib, base64), or nil on a client without it.
local function Codec()
    local E = rawget(_G, "C_EncodingUtil")
    if E and type(E.DecodeBase64) == "function" and type(E.DecompressString) == "function" then return E end
    return nil
end

--- Whether walks on a world map can follow the ground: its map loaded, and the client able to read it.
function Walking:Has(mapID)
    return maps[mapID] ~= nil and Codec() ~= nil
end

-- the tile holding a world point, and a tile's corner of least X and Y
local function TileAt(wx, wy)
    return floor(32 - wy / TILE_YARDS), floor(32 - wx / TILE_YARDS)
end
local function TileName(tx, ty) return tx .. "_" .. ty end
-- a tile name's column and row, its corner and its neighbours, worked out once: searches ask them often
local tileInfo = {}
local function InfoOf(name)
    local t = tileInfo[name]
    if not t then
        local tx, ty = name:match("^(%-?%d+)_(%-?%d+)$")
        tx, ty = tonumber(tx), tonumber(ty)
        t = { tx = tx, ty = ty, x0 = (31 - ty) * TILE_YARDS, y0 = (31 - tx) * TILE_YARDS, id = (tx + 64) * 256 + (ty + 64), sides = {} }
        tileInfo[name] = t
    end
    return t
end
local function Corner(name)
    local t = InfoOf(name)
    return t.x0, t.y0
end
local function Neighbour(name, side)
    local t = InfoOf(name)
    local n = t.sides[side]
    if not n then
        n = TileName(t.tx + side % 3 - 1, t.ty + floor(side / 3) - 1)
        t.sides[side] = n
    end
    return n
end

--- A tile's bytes read back: regions, portals and the grid of which regions cover each cell.
--- Indexes are 1-based here (the format's are 0-based).
local function Decode(s)
    local o = 1
    local function u8() local v = byte(s, o); o = o + 1; return v end
    local function u16() local a, b = byte(s, o, o + 1); o = o + 2; return a + b * 256 end
    local function i16() local v = u16(); if v >= 32768 then v = v - 65536 end return v end
    local version = #s >= 5 and u8()
    if not PACK_VERSIONS[version] then return nil end
    local regionCount, portalCount = u16(), u16()
    local regions = {}
    for r = 1, regionCount do
        local flags = u8()
        local swim = flags % 2 == 1
        local ground = floor(flags / 2) % 8
        local pocket = floor(flags / 16) % 2 == 1
        local towns = floor(flags / 32) % 4 * 32
        local height = i16() / 2
        local k = u8()
        local portals = {}
        for i = 1, k do portals[i] = u16() + 1 end
        local pairs_ = k * (k - 1) / 2
        local costs = {}
        for i = 1, pairs_ do
            local c = u16()
            costs[i] = c == 65535 and huge or c / 2
        end
        -- the stored ways' corners stay in the bytes, read for the way found only (Corners)
        local cornersAt = o
        for _ = 1, pairs_ do o = o + 1 + 4 * byte(s, o) end
        local region = { swim = swim, ground = ground, pocket = pocket, towns = towns, height = height, portals = portals, costs = costs, cornersAt = cornersAt }
        -- its crooked portals (#809): the distinct lists, each the portals (1-based, among its own) no straight line
        -- over the surface joins to a grid cell, leaving the cell then arriving at it; then a box of cells, each
        -- naming its list, left in the bytes and read where a walk starts or ends (Crooked)
        if version >= CROOKED_VERSION then
            local d = u8()
            if d > 0 then
                local lists = {}
                for l = 1, d do
                    local leaving, arriving = {}, {}
                    for _ = 1, u8() do leaving[u8() + 1] = true end
                    for _ = 1, u8() do arriving[u8() + 1] = true end
                    lists[l] = { leaving = leaving, arriving = arriving }
                end
                local x0, y0, w, h = u8(), u8(), u8(), u8()
                region.crooked = { lists = lists, x0 = x0, y0 = y0, w = w, h = h, at = o }
                o = o + w * h
            end
        end
        regions[r] = region
    end
    local portals = {}
    for p = 1, portalCount do
        local ax, ay, bx, by = u16() / 2, u16() / 2, u16() / 2, u16() / 2
        local height = i16() / 2
        local region = u16() + 1
        local side = u8()
        portals[p] = { ax = ax, ay = ay, bx = bx, by = by, height = height, region = region, side = side, other = u16() + 1 }
    end
    -- the grid stays in the bytes too: a cell is read where a point is placed (Cell)
    local rawAt = o
    o = o + 2 * GRID * GRID
    local lists = {}
    for l = 1, u16() do
        local list = {}
        for j = 1, u8() do list[j] = u16() + 1 end
        lists[l] = list
    end
    -- each region's zone (#747): the tile's list, then each region's index in it
    local zones = {}
    for z = 1, u8() do zones[z] = u16() end
    for r = 1, regionCount do regions[r].zone = zones[u8() + 1] or 0 end
    return { regions = regions, portals = portals, bytes = s, rawAt = rawAt, lists = lists, single = {} }
end
Walking.Decode = Decode

--- The corners of a region's stored way between two of its portals (`pair`, as the costs number them), in
--- tile coordinates: { {x, y}, ... }. Read from the tile's bytes, for the way found.
local function Corners(tile, region, pair)
    local s, o = tile.bytes, region.cornersAt
    for _ = 1, pair - 1 do o = o + 1 + 4 * byte(s, o) end
    local list = {}
    for j = 1, byte(s, o) do
        local at = o + 1 + 4 * (j - 1)
        local a, b, c, d = byte(s, at, at + 3)
        list[j] = { (a + b * 256) / 2, (c + d * 256) / 2 }
    end
    return list
end

local NONE = {}

--- A region's crooked portals at a world point (#809): { leaving = { [n] = true }, arriving = ... }, its
--- portals (by their place among its own) no straight line over the surface joins to the point's grid cell,
--- walking from it and walking to it; nil where it has none.
local function Crooked(tile, name, region, wx, wy)
    local c = region.crooked
    if not c then return nil end
    local x0, y0 = Corner(name)
    local gx, gy = floor((wx - x0) / CELL) - c.x0, floor((wy - y0) / CELL) - c.y0
    if gx < 0 or gy < 0 or gx >= c.w or gy >= c.h then return nil end
    local v = byte(tile.bytes, c.at + gx * c.h + gy)
    return v and v > 0 and c.lists[v] or nil
end

--- The regions covering a grid cell (gx, gy from 0).
local function Cell(tile, gx, gy)
    local at = tile.rawAt + 2 * (gx * GRID + gy)
    local a, b = byte(tile.bytes, at, at + 1)
    local v = a and a + b * 256
    if not v or v == 0 then return NONE end
    local n = #tile.regions
    if v <= n then
        -- one region: the same list each time, made once
        local one = tile.single[v]
        if not one then one = { v } tile.single[v] = one end
        return one
    end
    return tile.lists[v - n] or NONE
end

--- A packed tile's bytes from its base64: the game's codec, or nil when it cannot read it.
local function Unpack(text)
    local E = Codec()
    if not E then return nil end
    local ok, bin = pcall(E.DecodeBase64, text)
    if not ok or type(bin) ~= "string" then return nil end
    local enum = rawget(_G, "Enum")
    local zlib = enum and enum.CompressionMethod and enum.CompressionMethod.Zlib or 1
    local ok2, bytes = pcall(E.DecompressString, bin, zlib)
    if not ok2 or type(bytes) ~= "string" then return nil end
    return bytes
end

--- A map's tiles for a search: each decoded the first time it is asked for; false for none.
local function Tiles(mapID)
    local m = maps[mapID]
    if not m or not Codec() then return nil end
    return function(name)
        local t = m.decoded[name]
        if t == nil then
            local text = m.tiles[name]
            local bytes = text and Unpack(text)
            t = bytes and Decode(bytes) or false
            if text and not bytes then ns.ReportOnce("walking-decode", "a walking map tile could not be read; walks stay straight there") end
            m.decoded[name] = t
        end
        clock = clock + 1
        m.used[name] = clock
        return t or nil
    end
end

--- Drop the decoded tiles used longest ago, keeping MAX_TILES.
local function Trim()
    local all = {}
    for mapID, m in pairs(maps) do
        for name in pairs(m.decoded) do all[#all + 1] = { m = m, name = name, used = m.used[name] or 0 } end
    end
    if #all <= Walking.MAX_TILES then return end
    table.sort(all, function(a, b) return a.used < b.used end)
    for i = 1, #all - Walking.MAX_TILES do
        all[i].m.decoded[all[i].name], all[i].m.used[all[i].name] = nil, nil
    end
end

-- ------------------------------------------------------------
-- Placing a point on the regions under it
-- ------------------------------------------------------------
--- A region's height near a point: its nearest portal's (a region on a slope varies), else its own. A
--- drop's ends stand at a ledge's or a landing's height, not the region's: left out.
local function HeightNear(tile, r, lx, ly)
    local region = tile.regions[r]
    local best, height = huge, region and region.height or 0
    for _, i in ipairs(region and region.portals or NONE) do
        local p = tile.portals[i]
        if p and p.side ~= SIDE_DROP and p.side ~= SIDE_LANDING then
            local dx, dy = (p.ax + p.bx) / 2 - lx, (p.ay + p.by) / 2 - ly
            local d = dx * dx + dy * dy
            if d < best then best, height = d, p.height end
        end
    end
    return height
end

--- The regions a point stands on: { { tile, region, height } }. With a height, the region nearest it,
--- searching outwards until one is within ON_FLOOR_YARDS (a point at a cliff's edge may hold only the
--- ground below, a nearer cell a roof over the point's floor); else all there.
local function Place(tiles, p)
    local tx, ty = TileAt(p.x, p.y)
    local name = TileName(tx, ty)
    local tile = tiles(name)
    if not tile then return {} end
    local x0, y0 = Corner(name)
    local cx, cy = floor((p.x - x0) / CELL), floor((p.y - y0) / CELL)
    local first, seen, best, island = nil, {}, nil, nil
    for ring = 0, Walking.SNAP_CELLS do
        local here = {}
        for dx = -ring, ring do
            for dy = -ring, ring do
                if max(abs(dx), abs(dy)) == ring then
                    local gx, gy = cx + dx, cy + dy
                    if gx >= 0 and gy >= 0 and gx < GRID and gy < GRID then
                        for _, r in ipairs(Cell(tile, gx, gy)) do
                            if not seen[r] then
                                seen[r] = true
                                here[#here + 1] = { tile = name, region = r, height = HeightNear(tile, r, p.x - x0, p.y - y0) }
                            end
                        end
                    end
                end
            end
        end
        if not first or #first == 0 then first = here end
        if p.z == nil then
            if #first > 0 then return first end
        else
            for _, r in ipairs(here) do
                local d = abs(r.height - p.z)
                if d <= Walking.HEIGHT_YARDS then
                    -- a pocket (a roof, a sealed room: a small surface on its own) is the point's floor only when nothing else is near
                    local region = tile.regions[r.region]
                    if region and not region.pocket then
                        if not best or d < abs(best.height - p.z) then best = r end
                    elseif not island or d < abs(island.height - p.z) then
                        island = r
                    end
                end
            end
            -- a joined region at the point's own height ends the search; a nearer cell's floor some yards off may be a roof over it
            if best and abs(best.height - p.z) <= Walking.ON_FLOOR_YARDS then return { best } end
        end
    end
    local chosen = best or island
    if chosen then return { chosen } end
    return first or {}
end

--- The floors at a world point, as a point with no height is placed: { { height, joined, swim, tile, region } },
--- joined when a portal joins the region to its neighbours (a roof or a ledge is not); tile and region name
--- the region, for Joins. {} off the walking maps.
function Walking:Floors(mapID, x, y)
    local tiles = Tiles(mapID)
    if not tiles then return {} end
    local out = {}
    for _, r in ipairs(Place(tiles, { x = x, y = y })) do
        local t = tiles(r.tile)
        local region = t and t.regions[r.region]
        out[#out + 1] = { height = r.height, joined = region ~= nil and not region.pocket, swim = region ~= nil and region.swim,
            tile = r.tile, region = r.region }
    end
    -- the floor is looked at as the player walks: the tiles it decodes are kept to MAX_TILES as a search's are
    Trim()
    return out
end

--- Whether a walker can step from one region to the other: the same region, or one a portal joins to it
--- (in its tile, or the copy across a tile's border). Reads only tiles already decoded, and allocates
--- nothing: it is asked as the floor is followed.
function Walking:Joins(mapID, aTile, aRegion, bTile, bRegion)
    if aTile == bTile and aRegion == bRegion then return true end
    local m = maps[mapID]
    local tile = m and m.decoded[aTile]
    local region = tile and tile.regions[aRegion]
    if not region then return false end
    for _, i in ipairs(region.portals) do
        local p = tile.portals[i]
        if p then
            if p.side == SIDE_HERE then
                if aTile == bTile and ((p.region == aRegion and p.other == bRegion) or (p.other == aRegion and p.region == bRegion)) then return true end
            elseif p.side == SIDE_DROP then
                -- down a drop, not up it
                local landing = tile.portals[p.other]
                if aTile == bTile and landing and landing.region == bRegion then return true end
            elseif p.side ~= SIDE_LANDING and Neighbour(aTile, p.side) == bTile then
                -- across a tile's border (a landing joins nothing back up)
                local there = m.decoded[bTile]
                local copy = there and there.portals[p.other]
                if copy and copy.region == bRegion then return true end
            end
        end
    end
    return false
end

-- ------------------------------------------------------------
-- The search
-- ------------------------------------------------------------
local function Push(heap, prio, key)
    local n = #heap + 1
    heap[n] = { prio, key }
    while n > 1 do
        local up = floor(n / 2)
        if heap[up][1] <= heap[n][1] then break end
        heap[up], heap[n] = heap[n], heap[up]
        n = up
    end
end

local function Pop(heap)
    local top = heap[1]
    if not top then return nil end
    local last = table.remove(heap)
    if #heap > 0 then
        heap[1] = last
        local i, n = 1, #heap
        while true do
            local l, r, m = 2 * i, 2 * i + 1, i
            if l <= n and heap[l][1] < heap[m][1] then m = l end
            if r <= n and heap[r][1] < heap[m][1] then m = r end
            if m == i then break end
            heap[i], heap[m] = heap[m], heap[i]
            i = m
        end
    end
    return top[2]
end

-- the position of the pair (a, b), a < b, among a region's k portals (1-based)
local function PairIndex(a, b, k)
    local a0, b0 = a - 1, b - 1
    return a0 * k - a0 * (a0 + 1) / 2 + (b0 - a0 - 1) + 1
end

local function Flat(p, q)
    local dx, dy = p[1] - q[1], p[2] - q[2]
    return sqrt(dx * dx + dy * dy)
end

local function Cross(o, p, q) return (p[1] - o[1]) * (q[2] - o[2]) - (p[2] - o[2]) * (q[1] - o[1]) end
local function Same(p, q) return abs(p[1] - q[1]) < 1e-6 and abs(p[2] - q[2]) < 1e-6 end

--- The shortest line from start to finish through the edges crossed in order: the corners it turns at.
local function Funnel(start, gates, finish)
    local all = { { start, start } }
    for _, g in ipairs(gates) do all[#all + 1] = g end
    all[#all + 1] = { finish, finish }
    local corners = {}
    local apex, left, right = start, start, start
    local apexAt
    local leftAt, rightAt = 1, 1
    local i = 2
    while i <= #all do
        local l, r = all[i][1], all[i][2]
        local restart = false
        if Cross(apex, right, r) >= 0 then
            if Same(apex, right) or Cross(apex, left, r) < 0 then
                right, rightAt = r, i
            else
                corners[#corners + 1] = left
                apex, apexAt = left, leftAt
                left, right, leftAt, rightAt = apex, apex, apexAt, apexAt
                i = apexAt + 1
                restart = true
            end
        end
        if not restart then
            if Cross(apex, left, l) <= 0 then
                if Same(apex, left) or Cross(apex, right, l) > 0 then
                    left, leftAt = l, i
                else
                    corners[#corners + 1] = right
                    apex, apexAt = right, rightAt
                    left, right, leftAt, rightAt = apex, apex, apexAt, apexAt
                    i = apexAt + 1
                    restart = true
                end
            end
        end
        if not restart then i = i + 1 end
    end
    local out = {}
    for _, c in ipairs(corners) do
        if not Same(c, start) and not Same(c, finish) then out[#out + 1] = c end
    end
    return out
end
Walking.Funnel = Funnel

--- The way from one point to another on one map's tiles: { points = { {x, y} }, yards, swimYards,
--- riskYards (what the other faction's towns and zones far above the walker add to its yards: the
--- travel planner weighs it against a flight), startHeight, goalHeight }, or nil and why ("off-start", "off-goal", "no-walk"). `pause`, when
--- given, is called now and then so a coroutine can yield.
local function Search(tiles, from, to, pause, faction, danger)
    local hostile = (faction == "Alliance" and TOWN_BIT.Horde) or (faction == "Horde" and TOWN_BIT.Alliance) or nil
    local ownZones = {}
    -- what a yard in a region costs the walker beyond its ground: the other faction's town, a zone far above
    -- them (not the zones the walk starts and ends in, which it must cross)
    local function TownCost(region)
        local town = hostile and floor(region.towns / hostile) % 2 == 1 and Walking.HOSTILE_TOWN_COST or 1
        local zone = (danger and not ownZones[region.zone] and danger[region.zone]) or 1
        return town * zone
    end
    local function PortalOf(tile, i) local t = tiles(tile); return t and t.portals[i] end
    local function RegionOf(tile, r) local t = tiles(tile); return t and t.regions[r] end

    -- a border portal is in both its tiles: one node, keyed by the copy whose number is lower. Keys are
    -- numbers (a tile's id times 65536 plus the portal), so a search makes no strings.
    local function KeyOf(tile, i)
        local p = PortalOf(tile, i)
        local here = InfoOf(tile).id * 65536 + i
        if not p or p.side == SIDE_HERE or p.side == SIDE_DROP or p.side == SIDE_LANDING then return here end
        local there = InfoOf(Neighbour(tile, p.side)).id * 65536 + p.other
        return here < there and here or there
    end
    -- a portal's middle, as numbers
    local function MidXY(tile, i)
        local p = PortalOf(tile, i)
        local x0, y0 = Corner(tile)
        if not p then return x0, y0, 0 end
        return x0 + (p.ax + p.bx) / 2, y0 + (p.ay + p.by) / 2, p.height
    end
    local function Segment(tile, i)
        local p = PortalOf(tile, i)
        local x0, y0 = Corner(tile)
        if not p then return { { x0, y0, 0 }, { x0, y0, 0 } } end
        return { { x0 + p.ax, y0 + p.ay, p.height }, { x0 + p.bx, y0 + p.by, p.height } }
    end
    local function RegionKey(tile, r) return InfoOf(tile).id * 65536 + r end

    local start, goal = Place(tiles, from), Place(tiles, to)
    if #start == 0 then return nil, "off-start" end
    if #goal == 0 then return nil, "off-goal" end
    for _, list in ipairs({ start, goal }) do
        for _, p in ipairs(list) do
            local region = RegionOf(p.tile, p.region)
            if region then ownZones[region.zone] = true end
        end
    end
    local goalSet = {}
    for _, g in ipairs(goal) do goalSet[RegionKey(g.tile, g.region)] = g end
    local goalPoint = { to.x, to.y, to.z or goal[1].height }
    local startPoint = { from.x, from.y, from.z or start[1].height }
    local best, refs, done, heap = {}, {}, {}, {}
    local GOAL = "goal"

    -- a step is made only when it improves on the best known: most offers are turned down
    -- via: the stored way's corners, kept by reference (its region, pair and direction) and built for the way found
    local function Offer(key, cost, from_, swim, yards, risk, origin, arrived, viaRegion, viaPair, viaBack, viaTile, ax, ay)
        local known = best[key]
        if known and cost >= known.cost then return end
        best[key] = { cost = cost, from = from_, swim = swim, yards = yards, risk = risk, origin = origin, arrived = arrived,
            viaRegion = viaRegion, viaPair = viaPair, viaBack = viaBack, viaTile = viaTile }
        local h = 0
        if key ~= GOAL then
            local dx, dy = ax - goalPoint[1], ay - goalPoint[2]
            h = sqrt(dx * dx + dy * dy) * Walking.MIN_GROUND_COST
        end
        Push(heap, cost + h, key)
    end

    for _, s in ipairs(start) do
        local region = RegionOf(s.tile, s.region)
        if region then
            local town = TownCost(region)
            local weight = (region.swim and Walking.SWIM_COST or (Walking.GROUND_COST[region.ground] or 1)) * town
            if goalSet[RegionKey(s.tile, s.region)] then
                local d = Flat(startPoint, goalPoint)
                Offer(GOAL, d * weight, nil, region.swim and d or 0, d, d * (town - 1), s, s, nil, nil, nil, nil, goalPoint[1], goalPoint[2])
            end
            -- a portal no straight line from the start's cell reaches over the surface is left by another (#809)
            local crooked = Crooked(tiles(s.tile), s.tile, region, startPoint[1], startPoint[2])
            local unleft = crooked and crooked.leaving or NONE
            for n, p in ipairs(region.portals) do
                if not unleft[n] then
                    local key = KeyOf(s.tile, p)
                    local mx, my = MidXY(s.tile, p)
                    local dx, dy = startPoint[1] - mx, startPoint[2] - my
                    local d = sqrt(dx * dx + dy * dy)
                    if not refs[key] then refs[key] = { tile = s.tile, portal = p } end
                    Offer(key, d * weight, nil, region.swim and d or 0, d, d * (town - 1), s, nil, nil, nil, nil, nil, mx, my)
                end
            end
        end
    end

    -- from a portal, on through one of the regions either side of it
    local here, key
    local function Through(tile, regionIndex, portalIndex, ax, ay)
        local region = RegionOf(tile, regionIndex)
        if not region then return end
        -- a straight stretch in the region costs its ground's multiplier; a stored way is priced already
        local town = TownCost(region)
        local weight = (region.swim and Walking.SWIM_COST or (Walking.GROUND_COST[region.ground] or 1)) * town
        local wayWeight = (region.swim and Walking.SWIM_COST or 1) * town
        local portals = region.portals
        local k, i = #portals, nil
        for n = 1, k do if portals[n] == portalIndex then i = n break end end
        local arrived = goalSet[RegionKey(tile, regionIndex)]
        -- nor is the goal walked to straight from a portal no straight line from its cell reaches (#809)
        local crooked = arrived and i and Crooked(tiles(tile), tile, region, goalPoint[1], goalPoint[2])
        if arrived and not (crooked and crooked.arriving[i]) then
            local dx, dy = ax - goalPoint[1], ay - goalPoint[2]
            local d = sqrt(dx * dx + dy * dy)
            Offer(GOAL, here.cost + d * weight, key, here.swim + (region.swim and d or 0), here.yards + d, here.risk + d * (town - 1), here.origin, arrived,
                nil, nil, nil, nil, goalPoint[1], goalPoint[2])
        end
        if not i then return end
        for j = 1, k do
            if j ~= i then
                local pair = PairIndex(min(i, j), max(i, j), k)
                local length = region.costs[pair] or huge
                if length < huge then
                    local nextPortal = portals[j]
                    local nextKey = KeyOf(tile, nextPortal)
                    local cost = here.cost + length * wayWeight
                    local known = best[nextKey]
                    if not known or cost < known.cost then
                        if not refs[nextKey] then refs[nextKey] = { tile = tile, portal = nextPortal } end
                        local mx, my = MidXY(tile, nextPortal)
                        Offer(nextKey, cost, key, here.swim + (region.swim and length or 0), here.yards + length, here.risk + length * (town - 1), here.origin, nil,
                            region, pair, i > j, tile, mx, my)
                    end
                end
            end
        end
    end

    local searched = 0
    while true do
        key = Pop(heap)
        if not key then break end
        here = best[key]
        if here and not done[key] then
            done[key] = true
            if key == GOAL then break end
            searched = searched + 1
            if pause and searched % 16 == 0 then pause() end
            local ref = refs[key]
            local p = ref and PortalOf(ref.tile, ref.portal)
            if p then
                local ax, ay = MidXY(ref.tile, ref.portal)
                -- the regions either side of the portal, each with the portal's index among its own
                Through(ref.tile, p.region, ref.portal, ax, ay)
                if p.side == SIDE_DROP then
                    -- down the drop to its landing, the run's yards on
                    local landingKey = KeyOf(ref.tile, p.other)
                    local lx, ly = MidXY(ref.tile, p.other)
                    local dx, dy = lx - ax, ly - ay
                    local run = sqrt(dx * dx + dy * dy)
                    if not refs[landingKey] then refs[landingKey] = { tile = ref.tile, portal = p.other } end
                    Offer(landingKey, here.cost + run, key, here.swim, here.yards + run, here.risk, here.origin, nil, nil, nil, nil, nil, lx, ly)
                elseif p.side == SIDE_HERE then
                    Through(ref.tile, p.other, ref.portal, ax, ay)
                elseif p.side ~= SIDE_LANDING then
                    -- across a tile's border (a landing is crossed into, never back up)
                    local there = Neighbour(ref.tile, p.side)
                    local copy = PortalOf(there, p.other)
                    if copy then Through(there, copy.region, p.other, ax, ay) end
                end
            end
        end
    end

    local finish = best[GOAL]
    if not finish or not done[GOAL] then return nil, "no-walk" end

    -- back from the goal: each portal crossed (anywhere along it) and each corner passed (exactly)
    local crossed, step = {}, finish
    while step and step.from do
        -- the corners of the stored way this step took, last first (built now, for the way found only)
        local region = step.viaRegion
        if region then
            local tile = tiles(step.viaTile)
            local stored = tile and Corners(tile, region, step.viaPair) or NONE
            local x0, y0 = Corner(step.viaTile)
            local m = #stored
            for n = 1, m do
                local c = stored[step.viaBack and n or (m - n + 1)]
                local pt = { x0 + c[1], y0 + c[2], region.height }
                crossed[#crossed + 1] = { pt, pt }
            end
        end
        local ref = refs[step.from]
        if ref then crossed[#crossed + 1] = Segment(ref.tile, ref.portal) end
        step = best[step.from]
    end
    local gates = {}
    local function Mid(g) return { (g[1][1] + g[2][1]) / 2, (g[1][2] + g[2][2]) / 2, (g[1][3] + g[2][3]) / 2 } end
    local n = #crossed
    for idx = 1, n do
        local g = crossed[n - idx + 1]
        local before = idx == 1 and startPoint or Mid(crossed[n - idx + 2])
        local after = idx == n and goalPoint or Mid(crossed[n - idx])
        local turn = (after[1] - before[1]) * (g[1][2] - before[2]) - (after[2] - before[2]) * (g[1][1] - before[1])
        gates[idx] = turn > 0 and g or { g[2], g[1] }
    end
    local points = { { startPoint[1], startPoint[2] } }
    for _, c in ipairs(Funnel(startPoint, gates, goalPoint)) do points[#points + 1] = { c[1], c[2] } end
    points[#points + 1] = { goalPoint[1], goalPoint[2] }
    local yards = 0
    for i = 2, #points do yards = yards + Flat(points[i], points[i - 1]) end
    local swim = finish.yards > 0 and finish.swim / finish.yards * yards or 0
    local risk = finish.yards > 0 and finish.risk / finish.yards * yards or 0
    return {
        points = points,
        yards = yards,
        swimYards = swim,
        riskYards = risk,
        startHeight = finish.origin and finish.origin.height or startPoint[3],
        goalHeight = finish.arrived and finish.arrived.height or goalPoint[3],
        searched = searched,
    }
end

--- The way between two world points on a map, found at once (the tests; a search in play uses Request).
--- from, to: { x, y, z? } in world yards; faction ("Alliance", "Horde") prices the other's towns, none none;
--- danger ({ [zone] = multiplier }, Walking:DangerFor) the zones far above the walker.
--- Returns the way, or nil and why ("no-map" too).
function Walking:FindWay(mapID, from, to, faction, danger)
    local tiles = Tiles(mapID)
    if not tiles then return nil, "no-map" end
    local way, why = Search(tiles, from, to, nil, faction, danger)
    Trim()
    return way, why
end

-- ------------------------------------------------------------
-- Searches in play: a few milliseconds a frame, never in combat, remembered
-- ------------------------------------------------------------
local ways, wayOrder = {}, {}     -- remembered ways (false: no walk), oldest first
local ends, endOf = {}, {}        -- how many remembered ways end at a point (EndKey), and each way's
local jobs = {}                   -- searches waiting or running, in order
local runner

local function Q(v) return floor(v / 2 + 0.5) end
local function WayKey(mapID, from, to)
    return table.concat({ mapID, Q(from.x), Q(from.y), from.z and Q(from.z) or "-", Q(to.x), Q(to.y), to.z and Q(to.z) or "-" }, ":")
end

--- A number for a way's end, its height aside: the travel planner asks after hundreds of walks a plan,
--- nearly all never searched, and a number answers those without making a key string each.
local function EndKey(mapID, x, y)
    return (mapID * 20011 + Q(x) + 10000) * 20011 + Q(y) + 10000
end

local function Remember(key, way, mapID, to)
    if ways[key] == nil then
        wayOrder[#wayOrder + 1] = key
        local e = EndKey(mapID, to.x, to.y)
        endOf[key], ends[e] = e, (ends[e] or 0) + 1
    end
    ways[key] = way or false
    while #wayOrder > Walking.MAX_WAYS do
        local old = table.remove(wayOrder, 1)
        local e = endOf[old]
        ways[old], endOf[old] = nil, nil
        if e then ends[e] = ends[e] > 1 and ends[e] - 1 or nil end
    end
end

--- Whether any remembered way ends at (x, y) on the map: when not, Known is nil for every walk there.
function Walking:EndsAt(mapID, x, y)
    return ends[EndKey(mapID, x, y)] ~= nil
end

--- The way between two points if a search has found it: the way, false for no walk, nil when not yet searched.
function Walking:Known(mapID, from, to)
    if not ends[EndKey(mapID, to.x, to.y)] then return nil end
    return ways[WayKey(mapID, from, to)]
end

local function Now()
    local f = rawget(_G, "debugprofilestop")
    return f and f() or nil
end

--- A search in play has ended: what it found and what it cost, for the recording (FG_WALK_SEARCHED:
--- { map, way, why, height = the goal had one, secs = from asked to answered, peakMs = the most
--- one frame spent on it }).
local function Searched(job, way, why)
    if not ns.Events then return end
    ns.Events:Fire("FG_WALK_SEARCHED", {
        map = job.map, way = way, why = why, height = job.to.z ~= nil,
        secs = job.asked and ns.Now() - job.asked or nil, peakMs = job.peak,
    })
end

local function Run()
    if #jobs == 0 then
        if runner then runner:SetScript("OnUpdate", nil) end
        return
    end
    if InCombatLockdown and InCombatLockdown() then return end
    local began = Now()
    while #jobs > 0 do
        local job = jobs[1]
        if not job.co then
            local tiles = Tiles(job.map)
            if not tiles then
                table.remove(jobs, 1)
                job.done = true
                Searched(job, nil, "no-map")
                pcall(job.callback, nil, "no-map")
            else
                job.co = coroutine.create(function()
                    return Search(tiles, job.from, job.to, function()
                        local now = Now()
                        if now and began and now - began > Walking.BUDGET_MS then coroutine.yield() end
                    end, job.faction, job.danger)
                end)
            end
        end
        if job.co then
            local t0 = Now()
            local ok, way, why = coroutine.resume(job.co)
            local t1 = Now()
            -- one resume is one frame's share: the longest is what the search cost a frame at worst
            if t0 and t1 then job.peak = max(job.peak or 0, t1 - t0) end
            if not ok then
                table.remove(jobs, 1)
                job.done = true
                ns.ReportOnce("walking-search", way)
                Searched(job, nil, "error")
                pcall(job.callback, nil, "error")
            elseif coroutine.status(job.co) == "dead" then
                table.remove(jobs, 1)
                job.done = true
                Remember(job.key, way, job.map, job.to)
                Trim()
                if not job.cancelled then
                    Searched(job, way, why)
                    pcall(job.callback, way, why)
                end
            else
                return     -- out of time this frame
            end
        end
        local now = Now()
        if not now or not began or now - began > Walking.BUDGET_MS then return end
    end
end

--- Find the way between two world points on a map, over frames. callback(way) or callback(nil, why)
--- runs once, unless cancelled; a way already found answers at once. Returns a handle for Cancel.
function Walking:Request(mapID, from, to, callback)
    local key = WayKey(mapID, from, to)
    local known = ways[key]
    if known ~= nil then
        callback(known or nil, known and nil or "no-walk")
        return nil
    end
    for _, job in ipairs(jobs) do
        if job.key == key and not job.cancelled then
            local first = job.callback
            job.callback = function(...) first(...) callback(...) end
            return job
        end
    end
    -- the player's faction: the other's towns cost them more (a character's faction is its own for good, so ways remembered stay right)
    local faction = ns.Player and ns.Player:GetFaction()
    local danger = ns.Player and self:DangerFor(ns.Player:GetLevel())
    local job = { key = key, map = mapID, from = from, to = to, callback = callback, asked = ns.Now(), faction = faction, danger = danger }
    jobs[#jobs + 1] = job
    if not runner then runner = CreateFrame("Frame") end
    runner:SetScript("OnUpdate", Run)
    return job
end

--- Stop a search: its callback never runs.
function Walking:Cancel(job)
    if not job or job.done then return end
    job.cancelled = true
    for i, j in ipairs(jobs) do
        if j == job and not j.co then table.remove(jobs, i) break end
    end
end

--- How many searches wait, and the tiles decoded: for /fg diagnostics.
function Walking:Status()
    local tiles, loaded = 0, {}
    for mapID, m in pairs(maps) do
        loaded[#loaded + 1] = mapID
        for _ in pairs(m.decoded) do tiles = tiles + 1 end
    end
    table.sort(loaded)
    return { maps = loaded, tiles = tiles, waiting = #jobs, ways = #wayOrder }
end

--- Forget the remembered ways (the tests).
function Walking:Forget()
    ways, wayOrder, ends, endOf = {}, {}, {}, {}
end

--- The zones dangerous for a walker of `level`, { [zone] = multiplier }: those whose lowest level is well above theirs.
function Walking:DangerFor(level)
    local levels = rawget(ns, "NavZoneLevels")
    if type(levels) ~= "table" or type(level) ~= "number" then return nil end
    local out
    for zone, lowest in pairs(levels) do
        local above = lowest - level
        local cost = (above >= self.DEADLY_LEVELS and self.DEADLY_COST) or (above >= self.DANGER_LEVELS and self.DANGER_COST) or nil
        if cost then
            out = out or {}
            out[zone] = cost
        end
    end
    return out
end

-- ------------------------------------------------------------
-- Named places a way passes (codex src/nav/places.ts, #696): cave and building mouths, tunnels,
-- gates and bridges, from Nav/NavNames.lua. Each is a line from a to b that a walk through it goes
-- along (a mouth's from outside to inside); a way passing near a, then near b, passes it that way.
-- ------------------------------------------------------------
local NAMES_VERSION = 1
local PLACE_BUCKET = 128      -- yards: the index's cells
Walking.PLACE_REACH = { cave = 12, building = 12, tunnel = 15, gate = 12, bridge = 20 }   -- yards off a and b a way may pass
Walking.PLACE_ALONG = 0.5     -- and the way between them at least this share of a to b: a way passing beside a mouth is not through it
Walking.PLACE_AHEAD_YARDS = 150   -- a place this far ahead along the way is named on the arrow
Walking.PLACE_PASSED_YARDS = 10   -- and still this far behind it
-- what the arrow says, going a to b, then b to a
local PLACE_VERBS = {
    cave = { "Enter ", "Leave " }, building = { "Enter ", "Leave " },
    tunnel = { "Go through ", "Go through " }, gate = { "Go through ", "Go through " },
    bridge = { "Cross ", "Cross " },
}
local placeIndex = {}         -- world map id -> { [cell] = { place, ... } }, or false: none

local function PlaceCell(cx, cy) return cx * 100003 + cy end

--- A map's places, by the index cells their lines' boxes (with their reach) cover; nil when there are none.
local function Places(mapID)
    local index = placeIndex[mapID]
    if index ~= nil then return index or nil end
    local names = rawget(ns, "NavNames")
    local rows = type(names) == "table" and names.version == NAMES_VERSION and names[mapID]
    index = false
    if type(rows) == "table" then
        index = {}
        for _, r in ipairs(rows) do
            local kind, ax, ay, bx, by, label = r[1], r[2], r[3], r[4], r[5], r[7]
            local reach = Walking.PLACE_REACH[kind]
            if reach and type(ax) == "number" and type(ay) == "number" and type(bx) == "number" and type(by) == "number" and type(label) == "string" then
                local place = { kind = kind, ax = ax, ay = ay, bx = bx, by = by, area = r[6], label = label }
                for cx = floor((min(ax, bx) - reach) / PLACE_BUCKET), floor((max(ax, bx) + reach) / PLACE_BUCKET) do
                    for cy = floor((min(ay, by) - reach) / PLACE_BUCKET), floor((max(ay, by) + reach) / PLACE_BUCKET) do
                        local key = PlaceCell(cx, cy)
                        local list = index[key]
                        if not list then list = {} index[key] = list end
                        list[#list + 1] = place
                    end
                end
            end
        end
    end
    placeIndex[mapID] = index
    return index or nil
end

--- How near a way passes (x, y), and how many yards along it it is nearest.
local function Nearest(pts, along, x, y)
    local best, at = huge, 0
    for i = 1, #pts - 1 do
        local p, q = pts[i], pts[i + 1]
        local dx, dy = q[1] - p[1], q[2] - p[2]
        local len2 = dx * dx + dy * dy
        local f = len2 > 0 and ((x - p[1]) * dx + (y - p[2]) * dy) / len2 or 0
        if f < 0 then f = 0 elseif f > 1 then f = 1 end
        local ex, ey = p[1] + dx * f - x, p[2] + dy * f - y
        local d = ex * ex + ey * ey
        if d < best then best, at = d, along[i] + f * sqrt(len2) end
    end
    return sqrt(best), at
end

--- The named places a way on a world map passes, in order: { at = yards along it, text = "Enter
--- Fargodeep Mine", place }. Worked out once a way (kept on it): the cells its segments cross, and
--- for each place there how near the way passes its two ends.
function Walking:PlacesOn(mapID, way)
    if way.places then return way.places end
    local out = {}
    way.places = out
    local index = Places(mapID)
    local pts = way.points
    if not index or not pts or #pts < 2 then return out end
    local along = { 0 }
    for i = 2, #pts do along[i] = along[i - 1] + Flat(pts[i], pts[i - 1]) end
    local seen = {}
    for i = 1, #pts - 1 do
        local p, q = pts[i], pts[i + 1]
        for cx = floor(min(p[1], q[1]) / PLACE_BUCKET), floor(max(p[1], q[1]) / PLACE_BUCKET) do
            for cy = floor(min(p[2], q[2]) / PLACE_BUCKET), floor(max(p[2], q[2]) / PLACE_BUCKET) do
                for _, place in ipairs(index[PlaceCell(cx, cy)] or NONE) do
                    if not seen[place] then
                        seen[place] = true
                        local reach = self.PLACE_REACH[place.kind]
                        local da, sa = Nearest(pts, along, place.ax, place.ay)
                        local db, sb = Nearest(pts, along, place.bx, place.by)
                        local length = sqrt((place.bx - place.ax) ^ 2 + (place.by - place.ay) ^ 2)
                        if da <= reach and db <= reach and abs(sb - sa) >= self.PLACE_ALONG * length then
                            local verb = PLACE_VERBS[place.kind][sa <= sb and 1 or 2]
                            out[#out + 1] = { at = (sa + sb) / 2, text = verb .. place.label, place = place }
                        end
                    end
                end
            end
        end
    end
    table.sort(out, function(x, y) return x.at < y.at end)
    return out
end

--- The next named place on a way, with `left` yards of it still to walk: its text, or nil when none is
--- within PLACE_AHEAD_YARDS ahead (or just passed).
function Walking:PlaceAhead(mapID, way, left)
    if not way or not left then return nil end
    local here = (way.yards or 0) - left
    for _, p in ipairs(self:PlacesOn(mapID, way)) do
        if p.at >= here - self.PLACE_PASSED_YARDS then
            return p.at - here <= self.PLACE_AHEAD_YARDS and p.text or nil
        end
    end
    return nil
end

--- Read the named places again (the tests; a new release's data).
function Walking:ForgetPlaces()
    placeIndex = {}
end

function Walking:OnInit()
    self:Load()
    -- a level up makes zones safer: the ways remembered are searched again
    if ns.Events then ns.Events:Register("PLAYER_LEVEL_UP", function() self:Forget() end) end
end
