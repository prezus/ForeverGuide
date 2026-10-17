-- ============================================================
-- ForeverGuide / UI/RouteDots.lua
-- The planned route drawn as dots on the world map and the minimap: the
-- legs still ahead (Navigation.route), each kind of leg in its own colour (walks
-- gold, flights green, boats blue, zeppelins peach, the tram and lifts tan) on a
-- white disc, so the tint comes out true, over a near-black rim so it reads on
-- the parchment map and the minimap alike. The current leg is drawn full; the
-- legs after it faded. With no route (the way is a plain walk) and the planner
-- on, the walk from the player to the target is drawn.
-- A walk whose way the walking maps have found follows it, corner to corner;
-- a flight follows its taxi path and a boat or zeppelin its sailing path
-- (TravelDB, #742), a crossing to the other continent its part on each; other
-- legs are straight lines from start to end. The current walk starts at the
-- player. A jump (Hearthstone, teleport, portal) draws nothing. Dots run on
-- along a leg's segments at one spacing, so a path of many short segments
-- reads as one line, not a clump at each corner.
--
-- World map: a map canvas data provider (WorldMapFrame:AddDataProvider)
-- redrawn when the map, its zoom or the route changes, and every second
-- while the map is open; dots keep their on-screen size and spacing at any
-- zoom. At most 300. They are drawn on a frame of their own over the map:
-- the canvas's own textures sit under its tiles (the detail layers are its
-- child frames), so dots on the canvas itself never showed.
-- Minimap: textures on the Minimap placed from the player's world position,
-- the minimap's view radius in yards (C_Minimap.GetViewRadius) and, when the
-- minimap rotates, the player's facing. At most 120, spaced in on-screen
-- pixels like the world map's, inside the round map only. Its driver runs only
-- while a route is shown.
-- ============================================================

local _, ns = ...
local Dots = ns:NewModule("RouteDots")

local Plain, PlainNumber, Safe = ns.Plain, ns.PlainNumber, ns.Safe
local sqrt, cos, sin = math.sqrt, math.cos, math.sin

-- Sized to read on Elwynn's greens and the parchment map alike: 4 px dots on a 1 px rim were lost there.
Dots.WORLD_MAX, Dots.WORLD_SPACING, Dots.WORLD_SIZE = 300, 11, 7  -- dots; on-screen pixels
Dots.MINI_MAX, Dots.MINI_SPACING, Dots.MINI_SIZE = 120, 10, 6      -- dots; on-screen pixels
Dots.RIM = 1.5                                                     -- the dark rim round each dot, pixels
Dots.LATER_ALPHA = 0.5                                             -- the legs after the current one
--- Each kind of leg's colour; a ride not named here is a boat's.
Dots.COLORS = {
    walk = { 1, 0.84, 0.2 },
    flight = { 0.3, 1, 0.55 },
    boat = { 0.58, 0.79, 1 },
    zeppelin = { 0.96, 0.68, 0.52 },
    tram = { 0.86, 0.79, 0.66 },
    lift = { 0.86, 0.79, 0.66 },
}
local RIM_COLOR = { 0.02, 0.03, 0.06, 1 }
local JUMPS = { hearth = true, teleport = true, portal = true }

local function On()
    return not (ns.db and ns.db.nav and ns.db.nav.routeDots == false)
end

--- A walk's way from the player on, as segments: the player to the corner ahead, then corner to corner.
local function AlongWay(segs, way, at, px, py, inst, later)
    local _, aim = ns.Navigation.Along(way, at, px, py)
    local pts, ax, ay = way.points, px, py
    for i = aim, #pts do
        segs[#segs + 1] = { ax = ax, ay = ay, bx = pts[i][1], by = pts[i][2], inst = inst, kind = "walk", later = later }
        ax, ay = pts[i][1], pts[i][2]
    end
end

--- A whole way, corner to corner.
local function WholeWay(segs, way, inst, later)
    local pts = way.points
    for i = 2, #pts do
        segs[#segs + 1] = { ax = pts[i - 1][1], ay = pts[i - 1][2], bx = pts[i][1], by = pts[i][2], inst = inst, kind = "walk", later = later }
    end
end

--- The legs still ahead as world segments { ax, ay, bx, by, inst, kind, later }, or nil without a route.
function Dots:Segments()
    local Nav, T = ns.Navigation, ns.Travel
    local r = Nav.route
    if not T or not On() then return nil end
    local px, py, pInstance = ns.Player:GetWorldPosition()
    if not r then
        -- a plain walk: from the player to the target, when both are in one world; along its way when found
        local t = Nav.target
        if not (t and px and t.worldX and Nav:PlannerOn() and t.instanceID == pInstance) then return nil end
        local walk = Nav.walk
        if walk and walk.target == t and walk.way then
            local segs = {}
            AlongWay(segs, walk.way, walk.at, px, py, pInstance, false)
            return segs
        end
        return { { ax = px, ay = py, bx = t.worldX, by = t.worldY, inst = pInstance, kind = "walk" } }
    end
    local segs = {}
    for k = r.index, #r.legs do
        local leg = r.legs[k]
        local a, b = T.World(leg.from), T.World(leg.to)
        local current = k == r.index and leg.kind == "walk" and px
        if current then a = { x = px, y = py, inst = pInstance } end
        local path = leg.kind ~= "walk" and not JUMPS[leg.kind] and T.RidePath(leg)
        if leg.kind == "walk" and leg.way and a and b and a.inst == b.inst then
            if current then AlongWay(segs, leg.way, leg.wayAt, px, py, a.inst, false)
            else WholeWay(segs, leg.way, a.inst, k > r.index) end
        elseif path then
            for _, run in ipairs(path) do
                for i = 4, #run - 1, 2 do
                    segs[#segs + 1] = { ax = run[i - 2], ay = run[i - 1], bx = run[i], by = run[i + 1], inst = run[1], kind = leg.kind, later = k > r.index }
                end
            end
        elseif a and b and a.inst == b.inst and not JUMPS[leg.kind] then
            segs[#segs + 1] = { ax = a.x, ay = a.y, bx = b.x, by = b.y, inst = a.inst, kind = leg.kind, later = k > r.index }
        end
    end
    return segs
end

-- ------------------------------------------------------------
-- A pool of dots per surface: each a bright dot over a darker, larger one
-- ------------------------------------------------------------
local function Pool(parent, layer)
    return { parent = parent, layer = layer, used = 0, list = {} }
end

local function Texture(pool, sublevel)
    local t = pool.parent:CreateTexture(nil, pool.layer, nil, sublevel)
    -- a texture the game cannot load draws nothing: a square of colour then, never no dot
    local ok, loaded = pcall(t.SetTexture, t, ns.Theme.TEX.routeDot)
    Dots.textureLoaded = ok and loaded ~= false
    if not Dots.textureLoaded then t:SetColorTexture(1, 1, 1, 1) end
    return t
end

--- The next free dot, placed at (x, y) from `relative`'s `point`.
local function Next(pool, relative, point, x, y)
    pool.used = pool.used + 1
    local d = pool.list[pool.used]
    if not d then
        d = { rim = Texture(pool, 1), core = Texture(pool, 2) }
        pool.list[pool.used] = d
    end
    for _, t in ipairs({ d.rim, d.core }) do
        t:ClearAllPoints()
        t:SetPoint("CENTER", relative, point, x, y)
    end
    return d
end

local function Finish(pool)
    for i = pool.used + 1, #pool.list do
        pool.list[i].rim:Hide()
        pool.list[i].core:Hide()
    end
    pool.used = 0
end

--- Whether segment `s` goes on from where `prev` ended, in the same leg: its dots keep their spacing across the corner.
local function Continues(prev, s)
    return prev ~= nil and prev.kind == s.kind and prev.later == s.later and prev.inst == s.inst and prev.bx == s.ax and prev.by == s.ay
end

--- Dot positions along a segment from (ax, ay) to (bx, by) in screen units, `spacing` apart, `carry` already
--- run since the last dot (nil: a dot at its start). Calls place(f) for each, f from 0 to 1 along it; returns
--- the run since the last dot at its end.
local function Along(ax, ay, bx, by, spacing, carry, place)
    local len = sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
    local t = carry and (spacing - carry) or 0
    while t <= len do
        if place(len > 0 and t / len or 0) == false then return nil end
        t = t + spacing
    end
    return len - (t - spacing)
end

Dots.Along = Along

--- A dot of `size` with its rim `rim` wider all round, in the leg's colour; a later leg's faded.
local function Paint(d, seg, size, rim)
    local c = Dots.COLORS[seg.kind] or Dots.COLORS.boat
    local a = seg.later and Dots.LATER_ALPHA or 1
    d.rim:SetVertexColor(RIM_COLOR[1], RIM_COLOR[2], RIM_COLOR[3], RIM_COLOR[4] * a)
    d.rim:SetSize(size + 2 * rim, size + 2 * rim)
    d.rim:Show()
    d.core:SetVertexColor(c[1], c[2], c[3], a)
    d.core:SetSize(size, size)
    d.core:Show()
end

-- ------------------------------------------------------------
-- World map
-- ------------------------------------------------------------
local worldPool
local provider

--- A world point on the shown map, 0-1, or nil off it.
local function OnMap(mapID, inst, x, y)
    local vec = Safe(CreateVector2D, x, y)
    if not vec then return nil end
    local _, pos = ns.Call("C_Map.GetMapPosFromWorldPos", inst, vec, mapID)
    if type(pos) ~= "table" or type(pos.GetXY) ~= "function" then return nil end
    local ok, mx, my = pcall(pos.GetXY, pos)
    mx, my = PlainNumber(mx), PlainNumber(my)
    if not ok or not mx or not my then return nil end
    return mx, my
end

function Dots:DrawWorld()
    local map = provider and provider:GetMap()
    if not map or not worldPool then return end
    local segs = map:IsShown() and self:Segments()
    local mapID = segs and map:GetMapID()
    if mapID then
        local canvas = map:GetCanvas()
        local w, h = canvas:GetWidth(), canvas:GetHeight()
        local scale = map:GetCanvasScale() or 1
        local spacing, size, rim = self.WORLD_SPACING / scale, self.WORLD_SIZE / scale, self.RIM / scale
        local prev, carry
        for _, s in ipairs(segs) do
            local ax, ay = OnMap(mapID, s.inst, s.ax, s.ay)
            local bx, by = OnMap(mapID, s.inst, s.bx, s.by)
            if ax and bx then
                if not Continues(prev, s) then carry = nil end
                carry = Along(ax * w, ay * h, bx * w, by * h, spacing, carry, function(f)
                    if worldPool.used >= self.WORLD_MAX then return false end
                    local x, y = ax + (bx - ax) * f, ay + (by - ay) * f
                    if x >= 0 and x <= 1 and y >= 0 and y <= 1 then
                        Paint(Next(worldPool, canvas, "TOPLEFT", x * w, -y * h), s, size, rim)
                    end
                end)
            else
                carry = nil
            end
            prev = s
        end
    end
    Finish(worldPool)
end

local function HookWorldMap()
    local map = rawget(_G, "WorldMapFrame")
    local base = rawget(_G, "MapCanvasDataProviderMixin")
    if provider or not map or not base or type(map.AddDataProvider) ~= "function" then return false end
    provider = CreateFromMixins(base)
    function provider:RemoveAllData() if worldPool then Finish(worldPool) end end
    function provider:RefreshAllData() Dots:DrawWorld() end
    function provider:OnMapChanged() Dots:DrawWorld() end
    function provider:OnCanvasScaleChanged() Dots:DrawWorld() end
    function provider:OnCanvasSizeChanged() Dots:DrawWorld() end
    map:AddDataProvider(provider)
    -- a layer over the map's tiles, at a pin frame level of its own when the map has its manager
    local canvas = map:GetCanvas()
    local layer = CreateFrame("Frame", nil, canvas)
    layer:SetAllPoints(canvas)
    local levels = type(map.GetPinFrameLevelsManager) == "function" and map:GetPinFrameLevelsManager()
    local level
    if levels and levels.AddFrameLevel and levels.GetValidFrameLevel then
        pcall(levels.AddFrameLevel, levels, "PIN_FRAME_LEVEL_FOREVERGUIDE_ROUTE")
        local ok, got = pcall(levels.GetValidFrameLevel, levels, "PIN_FRAME_LEVEL_FOREVERGUIDE_ROUTE")
        level = ok and got or nil
    end
    layer:SetFrameLevel(level or ((canvas:GetFrameLevel() or 1) + 100))
    Dots.worldLayer = layer
    worldPool = Pool(layer, "OVERLAY")
    return true
end

-- ------------------------------------------------------------
-- Minimap
-- ------------------------------------------------------------
local miniPool, driver

function Dots:DrawMinimap()
    local mm = rawget(_G, "Minimap")
    if not mm or not miniPool then return end
    local segs = mm:IsShown() and self:Segments()
    local px, py, pInstance = ns.Player:GetWorldPosition()
    local radius = PlainNumber(ns.Call("C_Minimap.GetViewRadius"))
    if segs and px and radius and radius > 0 then
        local half = mm:GetWidth() / 2
        local perYard = half / radius
        -- the same on-screen spacing at any zoom: closer in yards when zoomed in
        local spacing = self.MINI_SPACING / perYard
        self.miniSpacingYards = spacing
        local rotate = Plain(ns.Call("C_CVar.GetCVarBool", "rotateMinimap")) == true
            and Plain(ns.Call("C_Minimap.IsRotateMinimapIgnored")) ~= true
        local facing = rotate and ns.Player:GetFacing() or 0
        local c, s = cos(-facing), sin(-facing)
        local prev, carry
        for _, seg in ipairs(segs) do
            if seg.inst == pInstance then
                if not Continues(prev, seg) then carry = nil end
                local dx, dy = seg.bx - seg.ax, seg.by - seg.ay
                carry = Along(seg.ax, seg.ay, seg.bx, seg.by, spacing, carry, function(f)
                    if miniPool.used >= self.MINI_MAX then return false end
                    local north, west = seg.ax + dx * f - px, seg.ay + dy * f - py
                    if north * north + west * west < radius * radius * 0.9 then
                        -- north is up and west left; a rotating minimap turns with the player
                        local sx, sy = -west * perYard, north * perYard
                        Paint(Next(miniPool, mm, "CENTER", sx * c - sy * s, sx * s + sy * c), seg, self.MINI_SIZE, self.RIM)
                    end
                end)
            else
                carry = nil
            end
            prev = seg
        end
    end
    Finish(miniPool)
end

--- What decides whether dots are drawn, as lines for `/fg dots`.
function Dots:Diagnose()
    local Nav = ns.Navigation
    local lines = {}
    local function add(fmt, ...) lines[#lines + 1] = string.format(fmt, ...) end
    local t, r = Nav.target, Nav.route
    add("route dots option: %s; travel planner on: %s", tostring(On()), tostring(Nav:PlannerOn()))
    add("target: %s", t and string.format("map %s %.1f, %.1f (world %s, %s, instance %s)", tostring(t.map), t.x or -1, t.y or -1,
        t.worldX and string.format("%.0f", t.worldX) or "none", t.worldY and string.format("%.0f", t.worldY) or "none", tostring(t.instanceID)) or "none")
    add("route: %s", r and string.format("%d legs, on leg %d", #r.legs, r.index) or "none (a walk)")
    local px, py, pInstance = ns.Player:GetWorldPosition()
    add("you: world %s, %s, instance %s", px and string.format("%.0f", px) or "none", py and string.format("%.0f", py) or "none", tostring(pInstance))
    local W = ns.Walking
    if W then
        local st = W:Status()
        local walk = Nav.walk
        local current = r and r.legs[r.index]
        local way = (walk and walk.way) or (current and current.way)
        add("walking maps: %s; tiles read %d; searches waiting %d; this walk: %s", #st.maps > 0 and table.concat(st.maps, ", ") or "none",
            st.tiles, st.waiting, way and string.format("follows its way, %d yd", way.yards) or "a straight line")
    end
    local segs = self:Segments()
    add("segments to draw: %s", segs and tostring(#segs) or "none")
    local world, mini = self:Shown()
    add("dots shown: world map %d, minimap %d; world map hooked: %s; minimap driver running: %s",
        world, mini, tostring(provider ~= nil), tostring(driver ~= nil and driver:IsShown()))
    add("minimap view radius: %s; dot texture loaded: %s", tostring(PlainNumber(ns.Call("C_Minimap.GetViewRadius"))), tostring(self.textureLoaded))
    return lines
end

--- The dot pools, for the tests: world map, minimap.
function Dots.pools() return { world = worldPool, mini = miniPool } end

--- How many dots show now: world map, minimap.
function Dots:Shown()
    local function count(pool)
        local n = 0
        for _, d in ipairs(pool and pool.list or {}) do
            if d.core:IsShown() then n = n + 1 end
        end
        return n
    end
    return count(worldPool), count(miniPool)
end

--- Run the minimap's driver only while there is a way to draw: a route, or a walk to the target.
function Dots:Refresh()
    local Nav = ns.Navigation
    local shown = On() and (Nav.route ~= nil or (Nav.target ~= nil and Nav:PlannerOn()))
    if driver then driver:SetShown(shown) end
    if not shown and miniPool then Finish(miniPool) end
    if shown then self:DrawMinimap() end
    self:DrawWorld()
end

function Dots:OnEnable()
    local mm = rawget(_G, "Minimap")
    if mm then
        miniPool = Pool(mm, "OVERLAY")
        driver = CreateFrame("Frame", nil, mm)
        driver.elapsed, driver.worldElapsed = 0, 0
        driver:SetScript("OnUpdate", function(f, elapsed)
            f.elapsed, f.worldElapsed = f.elapsed + elapsed, f.worldElapsed + elapsed
            if f.elapsed >= 0.1 then
                f.elapsed = 0
                local ok, err = pcall(Dots.DrawMinimap, Dots)
                if not ok then ns.ReportOnce("routedots:minimap", err) end
            end
            -- the current walk starts at the player: move the open world map's dots now and then
            if f.worldElapsed >= 1 and provider and provider:GetMap():IsShown() then
                f.worldElapsed = 0
                local ok, err = pcall(Dots.DrawWorld, Dots)
                if not ok then ns.ReportOnce("routedots:world", err) end
            end
        end)
        driver:Hide()
    end
    if not HookWorldMap() then
        ns.Events:Register("ADDON_LOADED", function(_, name)
            if name == "Blizzard_WorldMap" then HookWorldMap() end
        end)
    end
    for _, event in ipairs({ "FG_NAV_ROUTE_CHANGED", "FG_NAV_TARGET_CHANGED", "FG_NAV_WAY_FOUND" }) do
        ns.Events:Register(event, function()
            local ok, err = pcall(Dots.Refresh, Dots)
            if not ok then ns.ReportOnce("routedots", err) end
        end)
    end
    self:Refresh()
end
