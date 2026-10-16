-- ============================================================
-- ForeverGuide / UI/RouteDots.lua
-- The planned route drawn as dots on the world map and the minimap: the
-- legs still ahead (Navigation.route), walks in gold and rides in blue.
-- Straight lines from each leg's start to its end; the current walk starts
-- at the player. A leg between two world maps (a boat to the other
-- continent) or a jump (Hearthstone, teleport, portal) draws nothing.
--
-- World map: a map canvas data provider (WorldMapFrame:AddDataProvider)
-- redrawn when the map, its zoom or the route changes, and every second
-- while the map is open; dots keep their on-screen size and spacing at any
-- zoom. At most 300.
-- Minimap: textures on the Minimap placed from the player's world position,
-- the minimap's view radius in yards (C_Minimap.GetViewRadius) and, when the
-- minimap rotates, the player's facing. At most 40, one every 40 yards,
-- inside the round map only. Its driver runs only while a route is shown.
-- ============================================================

local _, ns = ...
local Dots = ns:NewModule("RouteDots")

local Plain, PlainNumber, Safe = ns.Plain, ns.PlainNumber, ns.Safe
local sqrt, cos, sin, floor = math.sqrt, math.cos, math.sin, math.floor

Dots.WORLD_MAX, Dots.WORLD_SPACING, Dots.WORLD_SIZE = 300, 14, 7   -- dots; on-screen pixels
Dots.MINI_MAX, Dots.MINI_SPACING, Dots.MINI_SIZE = 40, 40, 5       -- dots; yards; pixels
local WALK_COLOR, RIDE_COLOR = { 1, 0.85, 0.4 }, { 0.55, 0.85, 1 }
local JUMPS = { hearth = true, teleport = true, portal = true }

local function On()
    return not (ns.db and ns.db.nav and ns.db.nav.routeDots == false)
end

--- The legs still ahead as world segments { ax, ay, bx, by, inst, kind }, or nil without a route.
function Dots:Segments()
    local Nav, T = ns.Navigation, ns.Travel
    local r = Nav.route
    if not r or not T or not On() then return nil end
    local px, py, pInstance = ns.Player:GetWorldPosition()
    local segs = {}
    for k = r.index, #r.legs do
        local leg = r.legs[k]
        local a, b = T.World(leg.from), T.World(leg.to)
        if k == r.index and leg.kind == "walk" and px then a = { x = px, y = py, inst = pInstance } end
        if a and b and a.inst == b.inst and not JUMPS[leg.kind] then
            segs[#segs + 1] = { ax = a.x, ay = a.y, bx = b.x, by = b.y, inst = a.inst, kind = leg.kind }
        end
    end
    return segs
end

-- ------------------------------------------------------------
-- A pool of dot textures per surface
-- ------------------------------------------------------------
local function Pool(parent, layer)
    return { parent = parent, layer = layer, used = 0, list = {} }
end

local function Next(pool)
    pool.used = pool.used + 1
    local t = pool.list[pool.used]
    if not t then
        t = pool.parent:CreateTexture(nil, pool.layer)
        pcall(t.SetTexture, t, ns.Theme.TEX.dot)
        pool.list[pool.used] = t
    end
    return t
end

local function Finish(pool)
    for i = pool.used + 1, #pool.list do pool.list[i]:Hide() end
    pool.used = 0
end

local function Paint(t, kind, size)
    local c = kind == "walk" and WALK_COLOR or RIDE_COLOR
    t:SetVertexColor(c[1], c[2], c[3], 0.9)
    t:SetSize(size, size)
    t:Show()
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
        local spacing, size = self.WORLD_SPACING / scale, self.WORLD_SIZE / scale
        for _, s in ipairs(segs) do
            local ax, ay = OnMap(mapID, s.inst, s.ax, s.ay)
            local bx, by = OnMap(mapID, s.inst, s.bx, s.by)
            if ax and bx then
                local dx, dy = (bx - ax) * w, (by - ay) * h
                local n = floor(sqrt(dx * dx + dy * dy) / spacing)
                for i = 0, n do
                    if worldPool.used >= self.WORLD_MAX then break end
                    local f = n > 0 and i / n or 0
                    local x, y = ax + (bx - ax) * f, ay + (by - ay) * f
                    if x >= 0 and x <= 1 and y >= 0 and y <= 1 then
                        local t = Next(worldPool)
                        t:ClearAllPoints()
                        t:SetPoint("CENTER", canvas, "TOPLEFT", x * w, -y * h)
                        Paint(t, s.kind, size)
                    end
                end
            end
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
    worldPool = Pool(map:GetCanvas(), "OVERLAY")
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
        local rotate = Plain(ns.Call("C_CVar.GetCVarBool", "rotateMinimap")) == true
            and Plain(ns.Call("C_Minimap.IsRotateMinimapIgnored")) ~= true
        local facing = rotate and ns.Player:GetFacing() or 0
        local c, s = cos(-facing), sin(-facing)
        for _, seg in ipairs(segs) do
            if seg.inst == pInstance then
                local dx, dy = seg.bx - seg.ax, seg.by - seg.ay
                local n = floor(sqrt(dx * dx + dy * dy) / self.MINI_SPACING)
                for i = 0, n do
                    if miniPool.used >= self.MINI_MAX then break end
                    local f = n > 0 and i / n or 0
                    local north, west = seg.ax + dx * f - px, seg.ay + dy * f - py
                    if north * north + west * west < radius * radius * 0.9 then
                        -- north is up and west left; a rotating minimap turns with the player
                        local sx, sy = -west * perYard, north * perYard
                        local t = Next(miniPool)
                        t:ClearAllPoints()
                        t:SetPoint("CENTER", mm, "CENTER", sx * c - sy * s, sx * s + sy * c)
                        Paint(t, seg.kind, self.MINI_SIZE)
                    end
                end
            end
        end
    end
    Finish(miniPool)
end

--- How many dots show now: world map, minimap.
function Dots:Shown()
    local function count(pool)
        local n = 0
        for _, t in ipairs(pool and pool.list or {}) do
            if t:IsShown() then n = n + 1 end
        end
        return n
    end
    return count(worldPool), count(miniPool)
end

--- Run the minimap's driver only while a route is followed.
function Dots:Refresh()
    local shown = ns.Navigation.route ~= nil and On()
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
    ns.Events:Register("FG_NAV_ROUTE_CHANGED", function()
        local ok, err = pcall(Dots.Refresh, Dots)
        if not ok then ns.ReportOnce("routedots", err) end
    end)
    self:Refresh()
end
