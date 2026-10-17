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
-- crosses, past those corners: the points drawn, and the yards walked.
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

local PACK_VERSION = 1
local TILE_YARDS = 1600 / 3
local GRID = 64
local CELL = TILE_YARDS / GRID
local SIDE_HERE = 4

Walking.SNAP_CELLS = 3       -- grid cells searched round a point whose own cell has no ground
Walking.HEIGHT_YARDS = 40    -- a height further than this from every floor there is ignored
Walking.ON_FLOOR_YARDS = 4   -- a floor this near the height is the point's: the search round it stops
Walking.SWIM_COST = 1.5      -- a swum yard costs this many walked ones
Walking.BUDGET_MS = 3        -- a search's time a frame
Walking.MAX_TILES = 96       -- decoded tiles kept; past it the least recently used go
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
            if type(data) ~= "table" or data.version ~= PACK_VERSION or data.hash ~= want.hash or count ~= want.tiles then
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
local function Corner(name)
    local tx, ty = name:match("^(%-?%d+)_(%-?%d+)$")
    tx, ty = tonumber(tx), tonumber(ty)
    return (31 - ty) * TILE_YARDS, (31 - tx) * TILE_YARDS
end
local function Neighbour(name, side)
    local tx, ty = name:match("^(%-?%d+)_(%-?%d+)$")
    return TileName(tonumber(tx) + side % 3 - 1, tonumber(ty) + floor(side / 3) - 1)
end

--- A tile's bytes read back: regions, portals and the grid of which regions cover each cell.
--- Indexes are 1-based here (the format's are 0-based).
local function Decode(s)
    local o = 1
    local function u8() local v = byte(s, o); o = o + 1; return v end
    local function u16() local a, b = byte(s, o, o + 1); o = o + 2; return a + b * 256 end
    local function i16() local v = u16(); if v >= 32768 then v = v - 65536 end return v end
    if #s < 5 or u8() ~= PACK_VERSION then return nil end
    local regionCount, portalCount = u16(), u16()
    local regions = {}
    for r = 1, regionCount do
        local swim = u8() % 2 == 1
        local height = i16() / 2
        local k = u8()
        local portals = {}
        for i = 1, k do portals[i] = u16() + 1 end
        local pairs_ = k * (k - 1) / 2
        local costs, corners = {}, {}
        for i = 1, pairs_ do
            local c = u16()
            costs[i] = c == 65535 and huge or c / 2
        end
        for i = 1, pairs_ do
            local list = {}
            for j = 1, u8() do
                local cx = u16() / 2
                list[j] = { cx, u16() / 2 }
            end
            corners[i] = list
        end
        regions[r] = { swim = swim, height = height, portals = portals, costs = costs, corners = corners }
    end
    local portals = {}
    for p = 1, portalCount do
        local ax, ay, bx, by = u16() / 2, u16() / 2, u16() / 2, u16() / 2
        local height = i16() / 2
        local region = u16() + 1
        local side = u8()
        portals[p] = { ax = ax, ay = ay, bx = bx, by = by, height = height, region = region, side = side, other = u16() + 1 }
    end
    local raw = {}
    for c = 1, GRID * GRID do raw[c] = u16() end
    local lists = {}
    for l = 1, u16() do
        local list = {}
        for j = 1, u8() do list[j] = u16() + 1 end
        lists[l] = list
    end
    return { regions = regions, portals = portals, raw = raw, lists = lists }
end
Walking.Decode = Decode

local NONE = {}
--- The regions covering a grid cell (gx, gy from 0).
local function Cell(tile, gx, gy)
    local v = tile.raw[gx * GRID + gy + 1]
    if not v or v == 0 then return NONE end
    local n = #tile.regions
    if v <= n then return { v } end
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
--- A region's height near a point: its nearest portal's (a region on a slope varies), else its own.
local function HeightNear(tile, r, lx, ly)
    local region = tile.regions[r]
    local best, height = huge, region and region.height or 0
    for _, i in ipairs(region and region.portals or NONE) do
        local p = tile.portals[i]
        if p then
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
                    -- a region no portal joins to anything is a roof, a ledge or a pocket: the point's floor only when nothing else is near
                    local region = tile.regions[r.region]
                    if region and #region.portals > 0 then
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

--- The floors at a world point, as a point with no height is placed: { { height, joined, swim } }, joined
--- when a portal joins the region to its neighbours (a roof or a ledge is not); {} off the walking maps.
function Walking:Floors(mapID, x, y)
    local tiles = Tiles(mapID)
    if not tiles then return {} end
    local out = {}
    for _, r in ipairs(Place(tiles, { x = x, y = y })) do
        local t = tiles(r.tile)
        local region = t and t.regions[r.region]
        out[#out + 1] = { height = r.height, joined = region ~= nil and #region.portals > 0, swim = region ~= nil and region.swim }
    end
    return out
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
--- startHeight, goalHeight }, or nil and why ("off-start", "off-goal", "no-walk"). `pause`, when
--- given, is called now and then so a coroutine can yield.
local function Search(tiles, from, to, pause)
    local function PortalOf(tile, i) local t = tiles(tile); return t and t.portals[i] end
    local function RegionOf(tile, r) local t = tiles(tile); return t and t.regions[r] end

    -- a border portal is in both its tiles: one node, named by the copy that sorts first
    local function KeyOf(tile, i)
        local p = PortalOf(tile, i)
        local here = tile .. "#" .. i
        if not p or p.side == SIDE_HERE then return here end
        local there = Neighbour(tile, p.side) .. "#" .. p.other
        return here < there and here or there
    end
    local function Middle(tile, i)
        local p = PortalOf(tile, i)
        local x0, y0 = Corner(tile)
        if not p then return { x0, y0, 0 } end
        return { x0 + (p.ax + p.bx) / 2, y0 + (p.ay + p.by) / 2, p.height }
    end
    local function Segment(tile, i)
        local p = PortalOf(tile, i)
        local x0, y0 = Corner(tile)
        if not p then return { { x0, y0, 0 }, { x0, y0, 0 } } end
        return { { x0 + p.ax, y0 + p.ay, p.height }, { x0 + p.bx, y0 + p.by, p.height } }
    end
    -- the regions either side of a portal, each with the portal's index among its own
    local function Sides(tile, i)
        local p = PortalOf(tile, i)
        if not p then return NONE end
        local mine = { tile = tile, region = p.region, index = i }
        if p.side == SIDE_HERE then return { mine, { tile = tile, region = p.other, index = i } } end
        local there = Neighbour(tile, p.side)
        local copy = PortalOf(there, p.other)
        if not copy then return { mine } end
        return { mine, { tile = there, region = copy.region, index = p.other } }
    end

    local start, goal = Place(tiles, from), Place(tiles, to)
    if #start == 0 then return nil, "off-start" end
    if #goal == 0 then return nil, "off-goal" end
    local goalSet = {}
    for _, g in ipairs(goal) do goalSet[g.tile .. "@" .. g.region] = g end
    local goalPoint = { to.x, to.y, to.z or goal[1].height }
    local startPoint = { from.x, from.y, from.z or start[1].height }
    local best, refs, done, heap = {}, {}, {}, {}
    local GOAL = "goal"

    local function Offer(key, step, at)
        local known = best[key]
        if known and step.cost >= known.cost then return end
        best[key] = step
        Push(heap, step.cost + (key == GOAL and 0 or Flat(at, goalPoint)), key)
    end

    for _, s in ipairs(start) do
        local region = RegionOf(s.tile, s.region)
        if region then
            local weight = region.swim and Walking.SWIM_COST or 1
            if goalSet[s.tile .. "@" .. s.region] then
                local d = Flat(startPoint, goalPoint)
                Offer(GOAL, { cost = d * weight, via = NONE, swim = region.swim and d or 0, yards = d, origin = s, arrived = s }, goalPoint)
            end
            for _, p in ipairs(region.portals) do
                local key = KeyOf(s.tile, p)
                local at = Middle(s.tile, p)
                local d = Flat(startPoint, at)
                refs[key] = refs[key] or { tile = s.tile, portal = p }
                Offer(key, { cost = d * weight, via = NONE, swim = region.swim and d or 0, yards = d, origin = s }, at)
            end
        end
    end

    local searched = 0
    while true do
        local key = Pop(heap)
        if not key then break end
        local here = best[key]
        if here and not done[key] then
            done[key] = true
            if key == GOAL then break end
            searched = searched + 1
            if pause and searched % 16 == 0 then pause() end
            local ref = refs[key]
            if ref then
                local at = Middle(ref.tile, ref.portal)
                for _, side in ipairs(Sides(ref.tile, ref.portal)) do
                    local region = RegionOf(side.tile, side.region)
                    if region then
                        local weight = region.swim and Walking.SWIM_COST or 1
                        local arrived = goalSet[side.tile .. "@" .. side.region]
                        if arrived then
                            local d = Flat(at, goalPoint)
                            Offer(GOAL, { cost = here.cost + d * weight, from = key, via = NONE, swim = here.swim + (region.swim and d or 0),
                                yards = here.yards + d, origin = here.origin, arrived = arrived }, goalPoint)
                        end
                        local k, i = #region.portals, nil
                        for n, p in ipairs(region.portals) do if p == side.index then i = n break end end
                        if i then
                            local x0, y0 = Corner(side.tile)
                            for j = 1, k do
                                if j ~= i then
                                    local a, b = min(i, j), max(i, j)
                                    local pair = PairIndex(a, b, k)
                                    local length = region.costs[pair] or huge
                                    if length < huge then
                                        local stored = region.corners[pair] or NONE
                                        local via = {}
                                        if i < j then
                                            for n = 1, #stored do via[n] = { x0 + stored[n][1], y0 + stored[n][2], region.height } end
                                        else
                                            for n = #stored, 1, -1 do via[#via + 1] = { x0 + stored[n][1], y0 + stored[n][2], region.height } end
                                        end
                                        local nextPortal = region.portals[j]
                                        local nextKey = KeyOf(side.tile, nextPortal)
                                        refs[nextKey] = refs[nextKey] or { tile = side.tile, portal = nextPortal }
                                        Offer(nextKey, { cost = here.cost + length * weight, from = key, via = via, swim = here.swim + (region.swim and length or 0),
                                            yards = here.yards + length, origin = here.origin }, Middle(side.tile, nextPortal))
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    local finish = best[GOAL]
    if not finish or not done[GOAL] then return nil, "no-walk" end

    -- back from the goal: each portal crossed (anywhere along it) and each corner passed (exactly)
    local crossed, step = {}, finish
    while step and step.from do
        for n = #step.via, 1, -1 do crossed[#crossed + 1] = { step.via[n], step.via[n] } end
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
    return {
        points = points,
        yards = yards,
        swimYards = swim,
        startHeight = finish.origin and finish.origin.height or startPoint[3],
        goalHeight = finish.arrived and finish.arrived.height or goalPoint[3],
        searched = searched,
    }
end

--- The way between two world points on a map, found at once (the tests; a search in play uses Request).
--- from, to: { x, y, z? } in world yards. Returns the way, or nil and why ("no-map" too).
function Walking:FindWay(mapID, from, to)
    local tiles = Tiles(mapID)
    if not tiles then return nil, "no-map" end
    local way, why = Search(tiles, from, to)
    Trim()
    return way, why
end

-- ------------------------------------------------------------
-- Searches in play: a few milliseconds a frame, never in combat, remembered
-- ------------------------------------------------------------
local ways, wayOrder = {}, {}     -- remembered ways (false: no walk), oldest first
local jobs = {}                   -- searches waiting or running, in order
local runner

local function Q(v) return floor(v / 2 + 0.5) end
local function WayKey(mapID, from, to)
    return table.concat({ mapID, Q(from.x), Q(from.y), from.z and Q(from.z) or "-", Q(to.x), Q(to.y), to.z and Q(to.z) or "-" }, ":")
end

local function Remember(key, way)
    if ways[key] == nil then wayOrder[#wayOrder + 1] = key end
    ways[key] = way or false
    while #wayOrder > Walking.MAX_WAYS do ways[table.remove(wayOrder, 1)] = nil end
end

--- The way between two points if a search has found it: the way, false for no walk, nil when not yet searched.
function Walking:Known(mapID, from, to)
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
                    end)
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
                Remember(job.key, way)
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
    local job = { key = key, map = mapID, from = from, to = to, callback = callback, asked = ns.Now() }
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
    ways, wayOrder = {}, {}
end

function Walking:OnInit()
    self:Load()
end
