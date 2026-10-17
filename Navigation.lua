-- ============================================================
-- ForeverGuide / Navigation.lua
-- Distance and direction from the player to a map coordinate.
--
-- Coordinates in guides are uiMapID + x/y in 0-100 (the usual "42.3, 71.8").
--
-- Distance: map coordinate -> continent world position with
--   C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(x, y)) -> instanceID, vector2
-- player world position with UnitPosition("player") -> x, y, z, instanceID.
-- WoW's world axes: X points north, Y points west. GetPlayerFacing() is
-- 0 = north and grows counter-clockwise, so the relative angle to the
-- target is atan2(dy, dx) - facing, positive = to the left.
-- Fallback (instances, where UnitPosition is nil): map-space distance
-- scaled by C_Map.GetMapWorldSize(mapID).
--
-- Route: with the travel planner on (nav.travelPlanner) and its data loaded,
-- setting a target plans the way there (Travel.lua). A route that is more
-- than a walk is followed leg by leg: state.leg aims at the current leg's
-- end, the leg advances as the player reaches it, and while walking the way
-- is planned again every few seconds, switched only for a clearly faster one.
-- The target, its distance and arrival stay the final destination's.
--
-- Walking paths: where the walking maps cover a walk (Walking.lua), its way
-- is looked for in the background, for each walk of the route and for a walk
-- to the target with no route. Once found, the arrow aims at the way's next
-- corner, the time left follows the way's own yards, and the dots follow it
-- (FG_NAV_WAY_FOUND). A way much longer or shorter than the straight-line
-- guess the plan was made with plans again, a few times a target at most.
--
-- Optional: also sets Blizzard's own user waypoint + super-track so the
-- built-in in-world arrow points to the step (C_Map.SetUserWaypoint,
-- C_SuperTrack.SetSuperTrackedUserWaypoint — both present on 1.60.1).
-- ============================================================

local _, ns = ...
local Nav = ns:NewModule("Navigation")

local Plain, PlainNumber, PlainString, Safe = ns.Plain, ns.PlainNumber, ns.PlainString, ns.Safe
local atan2, sqrt, pi, abs, max, huge = math.atan2, math.sqrt, math.pi, math.abs, math.max, math.huge

Nav.target = nil        -- { map, x, y, label, radius, worldX, worldY, instanceID }
Nav.state = nil         -- last Update() result
Nav.route = nil         -- { legs, seconds, index }: the planned way to the target, when more than a walk
Nav.walk = nil          -- { target, way, at }: the walking way to the target when there is no route
Nav.ownsWaypoint = false

local LEG_WALK_RADIUS = 20    -- yards from a walk's end that count as there
local LEG_RIDE_RADIUS = 60    -- the same for a dock, a landing, a flight master
local REPLAN_SECONDS = 5      -- while walking, look for a better way this often
local SWITCH_SECONDS, SWITCH_SHARE = 30, 0.1   -- a new way must save this much, and this share
local WAY_REPLANS = 3         -- plans again a found walking way may cause, a target
local OFF_WAY_YARDS = 30      -- further than this from the way, it is looked for again from here
local CORNER_YARDS = 4        -- a corner this near counts as passed
local ASK_AGAIN_SECONDS = 5   -- and not more often than this

-- ------------------------------------------------------------
-- Conversions
-- ------------------------------------------------------------
--- Map coordinate (0-100) -> instanceID, worldX, worldY (yards). nil if unknown.
function Nav:MapToWorld(mapID, x, y)
    local vec = Safe(CreateVector2D, x / 100, y / 100)
    if not vec then return nil end
    local instanceID, pos = ns.Call("C_Map.GetWorldPosFromMapPos", mapID, vec)
    instanceID = PlainNumber(instanceID)
    if type(pos) ~= "table" or type(pos.GetXY) ~= "function" then return nil end
    local ok, wx, wy = pcall(pos.GetXY, pos)
    wx, wy = PlainNumber(wx), PlainNumber(wy)
    if not ok or not wx or not wy then return nil end
    return instanceID, wx, wy
end

--- Width/height of a map in yards.
function Nav:MapWorldSize(mapID)
    local w, h = ns.Call("C_Map.GetMapWorldSize", mapID)
    return PlainNumber(w), PlainNumber(h)
end

-- ------------------------------------------------------------
-- Target management
-- ------------------------------------------------------------
function Nav:SetTarget(target)
    if not target or not target.map or not target.x or not target.y then
        self:Clear()
        return
    end
    local t = {
        map = target.map,
        x = target.x,
        y = target.y,
        label = target.label,
        owner = target.owner,
        guide = target.guide,
        step = target.step,
        npcs = target.npcs,
        radius = target.radius or (ns.db and ns.db.nav.arrivalRadius) or 15,
    }
    t.instanceID, t.worldX, t.worldY = self:MapToWorld(t.map, t.x, t.y)
    -- the NPC's own floor where floors stack: a walk there ends at its height
    t.height = self:SpawnHeight(t.instanceID, t.worldX, t.worldY, t.npcs)
    -- the same place asked for again (the guide re-aims the arrow on every zone change) while a
    -- route is under way: keep following it. Planning afresh from inside a ride (the tram's own
    -- instance, a boat between zones) found no way and dropped the route, and its leg with it.
    local old = self.target
    local sameRoute = old and self.route and self:CurrentLeg() ~= nil and old.map == t.map and old.x == t.x and old.y == t.y
    if sameRoute then t.arrivedFired = old.arrivedFired end
    self.target = t
    self.state = nil
    if not sameRoute then self:SetRoute(self:PlanRoute(t)) end
    self:UpdateBlizzardWaypoint()
    ns.Events:Fire("FG_NAV_TARGET_CHANGED", t)
end

function Nav:Clear()
    if not self.target then return end
    self.target = nil
    self.state = nil
    self:SetRoute(nil)
    self:ClearBlizzardWaypoint()
    ns.Events:Fire("FG_NAV_TARGET_CHANGED", nil)
end

-- ------------------------------------------------------------
-- The planned route (Travel.lua)
-- ------------------------------------------------------------
local function PlannerOn()
    return ns.db ~= nil and ns.db.nav ~= nil and ns.db.nav.travelPlanner == true and ns.Travel ~= nil and ns.TravelDB ~= nil
end

--- Dead or a ghost: no flight, boat, Hearthstone or teleport, so no plan; the corpse run walks straight.
local function Dead()
    return Plain(Safe(rawget(_G, "UnitIsGhost"), "player")) == true or Plain(Safe(rawget(_G, "UnitIsDead"), "player")) == true
end

--- Whether the travel planner is on and has its data.
function Nav:PlannerOn() return PlannerOn() end

--- The way from where the player stands to `t`, or nil (planner off, no position, no way).
function Nav:PlanRoute(t)
    t = t or self.target
    if not t or not PlannerOn() or Dead() then return nil end
    local map, x, y = ns.Player:GetMapPosition()
    if not (map and x and y) then return nil end
    local opts = ns.Travel:Options()
    opts.walk = function(a, b) return self:WalkYards(a, b) end
    local ok, plan = pcall(ns.Travel.Plan, ns.Travel, { map = map, x = x, y = y }, { map = t.map, x = t.x, y = t.y }, opts)
    if not ok then
        ns.ReportOnce("nav:plan", plan)
        return nil
    end
    return plan
end

--- Follow `plan` when it is more than a walk; otherwise no route (the arrow points at the target).
function Nav:SetRoute(plan)
    local worth = false
    for _, leg in ipairs(plan and plan.legs or {}) do
        if leg.kind ~= "walk" then worth = true break end
    end
    local had = self.route ~= nil
    self.route = worth and { legs = plan.legs, seconds = plan.seconds, index = 1, legAt = ns.Now() } or nil
    self.replanAt = ns.Now() + REPLAN_SECONDS
    if had or self.route then ns.Events:Fire("FG_NAV_ROUTE_CHANGED", self.route) end
    self:FindWalks()
end

-- ------------------------------------------------------------
-- Walking ways (Walking.lua)
-- ------------------------------------------------------------
local function Dist(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return sqrt(dx * dx + dy * dy)
end

--- A way's yards as the planner prices them: a swum yard costs more than a walked one.
local function WayYards(way)
    return way.yards + (way.swimYards or 0) * ((ns.Walking and ns.Walking.SWIM_COST or 1.5) - 1)
end

local SPAWN_YARDS = 15   -- an NPC's spawn this near the target is the target's

--- The height of the NPC a target leads to: its spawn within SPAWN_YARDS of the target's world point
--- (TravelDB.heights, from the server's spawns), else nil.
function Nav:SpawnHeight(inst, wx, wy, npcs)
    local heights = ns.TravelDB and ns.TravelDB.heights
    if type(heights) ~= "table" or not inst or not wx or type(npcs) ~= "table" then return nil end
    local best, nearest = nil, SPAWN_YARDS
    for _, id in ipairs(npcs) do
        local h = heights[id]
        if type(h) == "table" then
            for i = 1, #h - 3, 4 do
                if h[i] == inst then
                    local d = Dist(h[i + 1], h[i + 2], wx, wy)
                    if d <= nearest then best, nearest = h[i + 3], d end
                end
            end
        end
    end
    return best
end

--- The end of a walk as the walking maps search it: with its own height when it has one (a
--- zeppelin's platform, TravelDB's z), or the target's when it is the target.
function Nav:WalkEnd(b)
    local t = self.target
    local to = { x = b.x, y = b.y, z = b.z }
    if not to.z and t and t.height and t.worldX and t.instanceID == b.inst and Dist(b.x, b.y, t.worldX, t.worldY) < 1 then to.z = t.height end
    return to
end

--- The way of a walk between two world points ({ inst, x, y }): known now, else asked for, and
--- onFound(way) runs when it arrives. nil where the walking maps cannot tell. A walk to the target
--- searches with its NPC's height; when that finds no way, once more without it.
function Nav:WalkWay(a, b, onFound)
    local W = ns.Walking
    if not W or not a or not b or a.inst ~= b.inst or not W:Has(a.inst) then return nil end
    local from, to = { x = a.x, y = a.y }, self:WalkEnd(b)
    local known = W:Known(a.inst, from, to)
    if known == false and to.z then known = W:Known(a.inst, from, { x = to.x, y = to.y }) end
    if known ~= nil then return known or nil end
    W:Request(a.inst, from, to, function(way)
        if way then
            if onFound then onFound(way) end
        elseif to.z then
            W:Request(a.inst, from, { x = to.x, y = to.y }, function(flat)
                if flat and onFound then onFound(flat) end
            end)
        end
    end)
    return nil
end

--- The yards of a walk for the planner (Travel's opts.walk): its way's when found, else nil.
function Nav:WalkYards(a, b)
    local W = ns.Walking
    if not W or not a or not b or not W:Has(a.inst) then return nil end
    -- the first walk starts where the player stood when it was asked for: from a few yards on it still serves
    local s = self.startWay
    if s and s.inst == a.inst and Dist(s.ax, s.ay, a.x, a.y) <= 10 and Dist(s.bx, s.by, b.x, b.y) <= 2 then return WayYards(s.way) end
    local to = self:WalkEnd(b)
    local known = W:Known(a.inst, { x = a.x, y = a.y }, to)
    if known == false and to.z then known = W:Known(a.inst, { x = a.x, y = a.y }, { x = to.x, y = to.y }) end
    return known and WayYards(known) or nil
end

--- A found way for a walk: kept, drawn, and, when it changes the walk's time a lot, planned again.
function Nav:WayFound(t, leg, way, a, b)
    if leg then
        leg.way, leg.wayAt = way, 1
        if a and b and leg == (self.route and self.route.legs[1]) then
            self.startWay = { inst = a.inst, ax = a.x, ay = a.y, bx = b.x, by = b.y, way = way }
        end
        local secs = WayYards(way) / self:RunSpeed()
        if t and abs(secs - leg.seconds) > max(10, 0.2 * leg.seconds) and (t.wayReplans or 0) < WAY_REPLANS then
            t.wayReplans = (t.wayReplans or 0) + 1
            local r = self.route
            ns.Events:After(0, function()
                if self.target == t and self.route == r then self:SetRoute(self:PlanRoute(t)) end
            end)
        end
    end
    ns.Events:Fire("FG_NAV_WAY_FOUND")
end

--- Look for the ways of the route's walks, or of the walk to the target when there is no route.
function Nav:FindWalks()
    local t, r = self.target, self.route
    self.walk = nil
    if not t or not PlannerOn() then return end
    if r then
        for _, leg in ipairs(r.legs) do
            if leg.kind == "walk" and not leg.way then
                local a, b = ns.Travel.World(leg.from), ns.Travel.World(leg.to)
                local way = self:WalkWay(a, b, function(found)
                    if self.route == r and self.target == t then self:WayFound(t, leg, found, a, b) end
                end)
                if way then
                    leg.way, leg.wayAt = way, 1
                    if leg == r.legs[1] then self.startWay = { inst = a.inst, ax = a.x, ay = a.y, bx = b.x, by = b.y, way = way } end
                end
            end
        end
        return
    end
    self:FindPlainWalk()
end

--- The way from where the player stands to the target, for a walk with no route.
function Nav:FindPlainWalk()
    local t = self.target
    local px, py, pInstance = ns.Player:GetWorldPosition()
    if self.route or not t or not t.worldX or not px or pInstance ~= t.instanceID or not PlannerOn() then
        self.walk = nil
        return
    end
    local walk = { target = t, askedAt = ns.Now() }
    self.walk = walk
    local way = self:WalkWay({ inst = pInstance, x = px, y = py }, { inst = t.instanceID, x = t.worldX, y = t.worldY }, function(found)
        if self.walk == walk then
            walk.way, walk.at = found, 1
            self:WayFound(t, nil, found)
        end
    end)
    if way then walk.way, walk.at = way, 1 end
end

--- How far a point is from the segment p-q.
local function SegmentDistance(px, py, p, q)
    local dx, dy = q[1] - p[1], q[2] - p[2]
    local len2 = dx * dx + dy * dy
    local f = len2 > 0 and ((px - p[1]) * dx + (py - p[2]) * dy) / len2 or 0
    if f < 0 then f = 0 elseif f > 1 then f = 1 end
    return Dist(px, py, p[1] + dx * f, p[2] + dy * f)
end

--- Where along a way the player is: the segment they are on (from `at`, the last one reached, on),
--- the index of the corner the arrow aims at, the yards left along the way, and how far off it they are.
function Nav.Along(way, at, px, py)
    local pts = way.points
    local seg, off = at or 1, huge
    for i = max(1, at or 1), #pts - 1 do
        local d = SegmentDistance(px, py, pts[i], pts[i + 1])
        if d < off then seg, off = i, d end
    end
    local aim = math.min(seg + 1, #pts)
    if aim < #pts and Dist(px, py, pts[aim][1], pts[aim][2]) <= CORNER_YARDS then aim = aim + 1 end
    local left = Dist(px, py, pts[aim][1], pts[aim][2])
    for i = aim, #pts - 1 do left = left + Dist(pts[i][1], pts[i][2], pts[i + 1][1], pts[i + 1][2]) end
    return seg, aim, left, off
end

--- The angle to a world point from the player, relative to their facing; nil without a facing.
local function AngleTo(px, py, x, y)
    local facing = ns.Player:GetFacing()
    if not facing then return nil end
    local rel = atan2(y - py, x - px) - facing
    while rel > pi do rel = rel - 2 * pi end
    while rel < -pi do rel = rel + 2 * pi end
    return rel
end

--- Follow a way from (px, py): the corner to aim at and the yards left; nil when the player has
--- left it (it is then looked for again from here, now and then).
function Nav:FollowWay(holder, wayKey, atKey, px, py, again)
    local way = holder[wayKey]
    if not way or not px then return nil end
    local seg, aim, left, off = Nav.Along(way, holder[atKey], px, py)
    if off > OFF_WAY_YARDS then
        if ns.Now() - (holder.askedAt or 0) >= ASK_AGAIN_SECONDS then
            holder.askedAt = ns.Now()
            again()
        end
        return nil
    end
    holder[atKey] = seg
    local p = way.points[aim]
    return p[1], p[2], left
end

--- Plan the way to the current target again now (an option changed).
function Nav:Replan()
    if self.target then self:SetRoute(self:PlanRoute(self.target)) end
end

--- Turn the travel planner on or off; the current target is planned again, or straight again.
function Nav:SetTravelPlanner(on)
    ns.db.nav.travelPlanner = on and true or false
    self:Replan()
end

--- The current leg, or nil when there is no route or it is done.
function Nav:CurrentLeg()
    local r = self.route
    return r and r.legs[r.index]
end

--- The player's run speed in yards a second (a mount counts), else a running character's.
function Nav:RunSpeed()
    local _, run = Safe(rawget(_G, "GetUnitSpeed"), "player")
    run = PlainNumber(run)
    return (run and run > 0) and run or ns.Travel.DEFAULT_SPEED
end

--- Seconds to the target from here: what is left of the route, else the walk; nil when unknown.
function Nav:SecondsLeft(state)
    state = state or self.state
    if not self.target or not state or not ns.Travel then return nil end
    if not self.route and not state.distance then return nil end
    local left = self:RemainingSeconds(state, self:RunSpeed())
    return left ~= math.huge and left or nil
end

local RIDE = { boat = "boat", zeppelin = "zeppelin", tram = "tram", portal = "portal", lift = "lift" }

--- "Ironforge" from the client's "Ironforge, Dun Morogh".
local function PlaceName(name)
    return name and (name:match("^([^,]+)") or name)
end

--- What the player does on this leg, in a few words: "Fly to Ironforge", "Take the boat to
--- Menethil Harbor", "Use your Hearthstone". A walk names what it walks to; the last walk, to the
--- target itself, needs no caption.
function Nav:LegCaption(leg, nextLeg)
    if not leg then return nil end
    local kind = leg.kind
    if kind == "walk" then
        if not nextLeg then return nil end
        if nextLeg.kind == "fly" then return "Walk to the flight master" end
        if RIDE[nextLeg.kind] then return "Walk to the " .. RIDE[nextLeg.kind] end
        return nil
    elseif kind == "fly" then
        return "Fly to " .. (PlaceName(leg.name) or "?")
    elseif kind == "hearth" then
        return leg.name and ("Use your Hearthstone to " .. leg.name) or "Use your Hearthstone"
    elseif kind == "teleport" then
        local spell = PlainString(ns.Call("C_Spell.GetSpellName", leg.spell))
        return "Cast " .. (spell or ("Teleport: " .. (leg.name or "?")))
    elseif kind == "lift" then
        return "Take the lift"
    elseif RIDE[kind] then
        return "Take the " .. RIDE[kind] .. (leg.name and (" to " .. leg.name) or "")
    end
    return nil
end

--- While waiting for a ride: "Boat in about 2:45" (the expected wait, counting down), else nil.
function Nav:RideWait()
    local r, leg = self.route, self:CurrentLeg()
    if not leg or not RIDE[leg.kind] or not leg.wait or leg.wait <= 0 then return nil end
    local left = leg.wait - (ns.Now() - (r.legAt or ns.Now()))
    if left <= 0 then return nil end
    local what = RIDE[leg.kind]
    return what:sub(1, 1):upper() .. what:sub(2) .. " in about " .. self:FormatTime(left)
end

local function Near(px, py, pInstance, point, radius)
    local w = point and ns.Travel.World(point)
    if not w or w.inst ~= pInstance then return false end
    local dx, dy = w.x - px, w.y - py
    return dx * dx + dy * dy <= radius * radius
end

--- Move to the furthest leg the player has reached: past a leg whose end they stand at, or onto
--- a later leg whose start they stand at (boarding a flight they were walking to, say).
function Nav:AdvanceRoute(px, py, pInstance)
    local r = self.route
    if not r or not px then return end
    local legs = r.legs
    for k = #legs, r.index, -1 do
        local leg = legs[k]
        if Near(px, py, pInstance, leg.to, leg.kind == "walk" and LEG_WALK_RADIUS or LEG_RIDE_RADIUS) then
            if r.index ~= k + 1 then
                r.index, r.legAt = k + 1, ns.Now()
                ns.Events:Fire("FG_NAV_ROUTE_CHANGED", r)
            end
            return
        end
        if k > r.index and Near(px, py, pInstance, leg.from, LEG_RIDE_RADIUS) then
            r.index, r.legAt = k, ns.Now()
            ns.Events:Fire("FG_NAV_ROUTE_CHANGED", r)
            return
        end
    end
end

--- Seconds the current route still takes from here; for no route, the walk to the target.
function Nav:RemainingSeconds(state, speed)
    local detour = ns.Travel.WALK_DETOUR
    local r = self.route
    if not r then
        if state and state.wayYards then return state.wayYards / speed end
        return state and state.distance and state.distance * detour / speed or math.huge
    end
    local total = 0
    for k = r.index, #r.legs do
        local leg = r.legs[k]
        if k == r.index and leg.kind == "walk" and state and state.leg and state.leg.distance then
            -- along its way, the yards are the walk's own; a straight line is a guess
            total = total + state.leg.distance * (state.leg.onWay and 1 or detour) / speed
        elseif k == r.index and leg.kind == "fly" and self:FlightLeft(leg) then
            -- in the air: the flight's own seconds, as much of them as is left of its path
            total = total + self:FlightLeft(leg)
        elseif k == r.index and leg.kind ~= "walk" then
            -- under way (or waiting at the dock): what is left of the leg's own seconds
            total = total + math.max(0, leg.seconds - (ns.Now() - (r.legAt or ns.Now())))
        else
            total = total + leg.seconds
        end
    end
    return total
end

--- Seconds left of a flight the player is on, from how much of its taxi path is left: steady whatever the
--- flight's pace (#742). nil off a taxi, or without the path.
function Nav:FlightLeft(leg)
    if Plain(Safe(rawget(_G, "UnitOnTaxi"), "player")) ~= true then return nil end
    local runs = ns.Travel.RidePath(leg)
    local px, py, pInstance = ns.Player:GetWorldPosition()
    if not runs or not px then return nil end
    local left, whole = ns.Travel.PathLeft(runs, pInstance, px, py)
    if not left or whole <= 0 then return nil end
    local board = ns.TravelDB and ns.TravelDB.flightBoard or 0
    return math.max(0, leg.seconds - board) * left / whole
end

--- While walking, plan again now and then, and take the new way only when it is clearly faster.
--- The switch happens a tick later: Update runs inside callers that are still reading the state.
function Nav:MaybeReplan(t, state)
    if not PlannerOn() or ns.Now() < (self.replanAt or 0) then return end
    self.replanAt = ns.Now() + REPLAN_SECONDS
    local leg = self:CurrentLeg()
    if leg and leg.kind ~= "walk" then return end
    if Plain(Safe(rawget(_G, "UnitOnTaxi"), "player")) == true then return end
    local plan = self:PlanRoute(t)
    if not plan then return end
    local remaining = self:RemainingSeconds(state, self:RunSpeed())
    if plan.seconds < remaining - math.max(SWITCH_SECONDS, SWITCH_SHARE * remaining) then
        ns.Events:After(0, function()
            if self.target == t then self:SetRoute(plan) end
        end)
    end
end

--- Turn the Blizzard map pin on/off and apply it to the current target right away.
function Nav:SetBlizzardWaypointEnabled(on)
    ns.db.nav.blizzardWaypoint = on and true or false
    if on then
        self:UpdateBlizzardWaypoint()
    else
        self:ClearBlizzardWaypoint()
    end
end

--- Remove the Blizzard pin only if it is still the one we placed (the player
--- may have set their own since).
function Nav:ClearBlizzardWaypoint()
    if not self.ownsWaypoint then return end
    self.ownsWaypoint = false
    local own = self.ownPoint
    self.ownPoint = nil
    local has = Plain(ns.Call("C_Map.HasUserWaypoint"))
    if has == false then return end
    local cur = ns.Call("C_Map.GetUserWaypoint")
    if type(cur) == "table" and own then
        local pos = cur.position
        local cx, cy = pos and PlainNumber(pos.x), pos and PlainNumber(pos.y)
        if PlainNumber(cur.uiMapID) ~= own.map or not cx or not cy or math.abs(cx - own.x) > 1e-3 or math.abs(cy - own.y) > 1e-3 then
            return   -- not ours any more
        end
    end
    ns.Call("C_Map.ClearUserWaypoint")
end

function Nav:UpdateBlizzardWaypoint()
    local t = self.target
    if not t then return end
    if not (ns.db and ns.db.nav.blizzardWaypoint) then return end
    if Plain(ns.Call("C_Map.CanSetUserWaypointOnMap", t.map)) ~= true then return end
    local UiMapPoint = rawget(_G, "UiMapPoint")
    if not UiMapPoint or type(UiMapPoint.CreateFromCoordinates) ~= "function" then return end
    local point = Safe(UiMapPoint.CreateFromCoordinates, t.map, t.x / 100, t.y / 100)
    if not point then return end
    local set = ns.Call("C_Map.SetUserWaypoint", point)
    if Plain(set) == true then
        self.ownsWaypoint = true
        self.ownPoint = { map = t.map, x = t.x / 100, y = t.y / 100 }
        ns.Call("C_SuperTrack.SetSuperTrackedUserWaypoint", true)
    end
end

-- ------------------------------------------------------------
-- Live update
-- ------------------------------------------------------------
--- Returns a state table (also stored in Nav.state):
---   distance (yards or nil), angle (relative radians, nil if unknown),
---   sameContinent (bool), method ("world"|"map"|nil), arrived (bool)
function Nav:Update(allowCached)
    local t = self.target
    if not t then
        self.state = nil
        return nil
    end
    -- the window, the arrow and the poller all tick; with allowCached they share one result per 40 ms
    if allowCached and self.state and self.stateTarget == t and ns.Now() - (self.stateAt or 0) < 0.04 then return self.state end
    local state = { distance = nil, angle = nil, sameContinent = true, method = nil, arrived = false }

    local px, py, pInstance = ns.Player:GetWorldPosition()
    if px and t.worldX then
        if pInstance and t.instanceID and pInstance ~= t.instanceID then
            state.sameContinent = false
        else
            local dx, dy = t.worldX - px, t.worldY - py
            state.distance = sqrt(dx * dx + dy * dy)
            state.method = "world"
            local facing = ns.Player:GetFacing()
            if facing then
                local bearing = atan2(dy, dx)
                local rel = bearing - facing
                while rel > pi do rel = rel - 2 * pi end
                while rel < -pi do rel = rel + 2 * pi end
                state.angle = rel
            end
        end
    end

    if not state.distance and state.sameContinent then
        -- fallback: map-space (works in instances if both are on the same map)
        local mapID, mx, my = ns.Player:GetMapPosition()
        if mapID and mx and mapID == t.map then
            local w, h = self:MapWorldSize(mapID)
            if w and h then
                local dx, dy = (t.x - mx) / 100 * w, (t.y - my) / 100 * h
                state.distance = sqrt(dx * dx + dy * dy)
                state.method = "map"
                local facing = ns.Player:GetFacing()
                if facing then
                    -- map axes: +x east, +y south. north component = -dy, west component = -dx
                    local rel = atan2(-dx, -dy) - facing
                    while rel > pi do rel = rel - 2 * pi end
                    while rel < -pi do rel = rel + 2 * pi end
                    state.angle = rel
                end
            end
        elseif mapID and mapID ~= t.map then
            state.otherMap = true
        end
    end

    state.arrived = state.distance ~= nil and state.distance <= (t.radius or 15)

    -- the route's current leg: where the arrow points while one is followed
    if self.route then
        self:AdvanceRoute(px, py, pInstance)
        local leg = self:CurrentLeg()
        if leg then
            -- a ride to another world map points at where it starts until the player is aboard
            local aim = ns.Travel.World(leg.to)
            if not aim or aim.inst ~= pInstance then aim = ns.Travel.World(leg.from) end
            local l = { index = self.route.index, kind = leg.kind }
            local cx, cy, left
            if leg.kind == "walk" and leg.way and px and aim and aim.inst == pInstance then
                cx, cy, left = self:FollowWay(leg, "way", "wayAt", px, py, function()
                    local b = ns.Travel.World(leg.to)
                    local r = self.route
                    local way = self:WalkWay({ inst = pInstance, x = px, y = py }, b, function(found)
                        if self.route == r then self:WayFound(t, leg, found) end
                    end)
                    if way then leg.way, leg.wayAt = way, 1 end
                end)
            end
            if cx then
                l.distance, l.onWay = left, true
                l.angle = AngleTo(px, py, cx, cy)
            elseif px and aim and aim.inst == pInstance then
                local dx, dy = aim.x - px, aim.y - py
                l.distance = sqrt(dx * dx + dy * dy)
                l.angle = AngleTo(px, py, aim.x, aim.y)
            end
            state.leg = l
        end
    end
    -- a walk with no route: the arrow aims along its way, and the time left is the way's
    local walk = self.walk
    if not self.route and walk and walk.target == t and walk.way and px and pInstance == t.instanceID and not state.arrived then
        local cx, cy, left = self:FollowWay(walk, "way", "at", px, py, function() self:FindPlainWalk() end)
        if cx then
            state.wayYards = left
            state.angle = AngleTo(px, py, cx, cy) or state.angle
        end
    end
    self.state, self.stateAt, self.stateTarget = state, ns.Now(), t
    if px and not state.arrived then self:MaybeReplan(t, state) end
    if state.arrived and not t.arrivedFired then
        t.arrivedFired = true
        -- deferred, not fired in-line: Update() runs synchronously inside whoever just
        -- called SetTarget (Arrow and the waypoint both refresh immediately on
        -- FG_NAV_TARGET_CHANGED). A target that is already within radius the moment it
        -- is set - standing right next to the flight point you just asked to walk to,
        -- say - used to fire FG_NAV_ARRIVED from inside that same SetTarget call, and a
        -- handler reacting to arrival (Reminders releasing the flight-point override)
        -- would reassign the navigation target while the
        -- original caller had not finished setting it up. One tick later costs nothing
        -- a player would notice and closes that reentrancy off.
        ns.Events:After(0, function()
            if self.target == t then ns.Events:Fire("FG_NAV_ARRIVED", t) end
        end)
    end
    return state
end

-- arrival must be noticed even when the window and the arrow are hidden
local poller = CreateFrame("Frame")
poller.elapsed = 0
poller:SetScript("OnUpdate", function(self, elapsed)
    self.elapsed = self.elapsed + (elapsed or 0)
    if self.elapsed < 0.25 or not Nav.target then return end
    self.elapsed = 0
    local ok, err = pcall(Nav.Update, Nav, true)
    if not ok then ns.ReportOnce("nav:poll", err) end
end)

-- ------------------------------------------------------------
-- Formatting
-- ------------------------------------------------------------
--- "85 yd", "1.5k yd": yards like the game's own waypoint, abbreviated from a thousand on.
function Nav:FormatDistance(yards)
    if not yards then return "?" end
    local n = math.floor(yards + 0.5)
    if n < 1000 then return string.format("%d yd", n) end
    local k = string.format("%.1f", n / 1000):gsub("%.0$", "")
    return k .. "k yd"
end

--- "45 s", "4:15", "1:05:00".
function Nav:FormatTime(seconds)
    if not seconds or seconds ~= seconds or seconds == math.huge then return nil end
    local s = math.floor(seconds + 0.5)
    if s < 60 then return s .. " s" end
    local h, m = math.floor(s / 3600), math.floor(s % 3600 / 60)
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s % 60) end
    return string.format("%d:%02d", m, s % 60)
end

--- "ahead", "ahead-left", "left", "behind-left", "behind", ... from a relative angle.
function Nav:DirectionWord(angle)
    if not angle then return "?" end
    local deg = angle * 180 / pi   -- positive = left
    local a = math.abs(deg)
    local side = deg > 0 and "left" or "right"
    if a < 22.5 then return "ahead" end
    if a < 67.5 then return "ahead-" .. side end
    if a < 112.5 then return side end
    if a < 157.5 then return "behind-" .. side end
    return "behind"
end

--- Clock-face direction ("12 o'clock" = straight ahead).
function Nav:ClockWord(angle)
    if not angle then return "?" end
    local deg = -angle * 180 / pi       -- clockwise positive
    local hour = math.floor((deg + 15) / 30) % 12
    if hour == 0 then hour = 12 end
    return hour .. " o'clock"
end

function Nav:Describe()
    local s = self.state or self:Update()
    if not self.target then return "no destination" end
    if not s then return "?" end
    if not s.sameContinent then return "different continent" end
    if s.otherMap then return "on another map (" .. tostring(ns.Player:GetMapName(self.target.map) or self.target.map) .. ")" end
    if not s.distance then return "position unavailable" end
    local dir = s.angle and (", " .. self:DirectionWord(s.angle)) or ""
    return self:FormatDistance(s.distance) .. dir
end

-- ------------------------------------------------------------
-- Resolve where a guide step points to
-- ------------------------------------------------------------
--- Returns mapID, x, y, label for a step (or nil). Order of preference:
---  0. an in-game edit; then, for an objective step of a quest in the log, Blizzard's own
---     world-map pin for it (current map, then the step's map) or its next waypoint
---  1. explicit step.map/x/y
---  2. step.zone name matching the player's current map + x/y
---  3. the bundled quest database (giver / turn-in / objective spawns / npc / item sources)
---  4. Blizzard's quest waypoint for step.quest
local validMap = {}   -- mapID -> true/false (does this client know the map?)
function Nav:IsValidMap(mapID)
    if not mapID then return false end
    if validMap[mapID] == nil then
        local info = ns.Call("C_Map.GetMapInfo", mapID)
        validMap[mapID] = type(info) == "table" and info.name ~= nil
    end
    return validMap[mapID]
end

function Nav:ResolveStep(step)
    if not step then return nil end
    if ns.Editor then step = ns.Editor:Effective(step) end   -- in-game corrections win
    if not step.edited then
        local loc = self:BlizzardLocationForStep(step)
        if loc then return loc.map, loc.x, loc.y, step.text or loc.name, loc end
    end
    if step.near and not step.edited then
        -- objective with many spawns: the nearest known one beats the planned spot, among the
        -- spawns around that spot. Snow Leopards roam all of Dun Morogh; a step planned in the
        -- west must not send the player to one in the east because it happens to be closer.
        local around = step.map and step.x and step.y and { map = step.map, x = step.x, y = step.y } or nil
        local loc = self:DBLocationForStep(step, around)
        if loc then return loc.map, loc.x, loc.y, step.text or loc.name, loc end
    end
    -- an NPC step whose NPC has a Forever-confirmed position: that beats the planned spot
    if step.npc and (step.type == "ACCEPT" or step.type == "TURNIN" or step.type == "TALK") and not step.edited and ns.DB and ns.DB:IsLoaded() then
        local locs = ns.DB:NPCLocations(step.npc)
        if locs[1] and locs[1].forever then
            -- the Forever point by the step's own spot: a stray point (RestedXP lists some NPCs twice)
            -- must not win just because the player happens to stand near it
            local loc = (step.x and step.y and self:ClosestTo(locs, step.map, step.x, step.y)) or ns.DB:Nearest(locs) or locs[1]
            return loc.map, loc.x, loc.y, step.text or loc.name, loc
        end
    end
    if step.x and step.y then
        local mapID = step.map
        -- guide data may carry Classic-era map IDs; if Forever does not know
        -- the ID, fall back to matching the zone by name.
        if mapID and not self:IsValidMap(mapID) then mapID = nil end
        if not mapID and step.zone then
            local curMap = ns.Player:GetMapID()
            local curName = ns.Player:GetMapName(curMap)
            if curName and curName == step.zone then mapID = curMap end
            if not mapID and ns.db and ns.db.contrib then
                for id, info in pairs(ns.db.contrib.maps) do
                    if info.name == step.zone then mapID = id break end
                end
            end
            if not mapID and ns.DB then mapID = ns.DB:MapForZoneName(step.zone) end
        end
        -- a place with no map or zone at all is on the map the player is on (Guidelime's reading)
        if not mapID and not step.map and not step.zone then mapID = ns.Player:GetMapID() end
        if mapID then return mapID, step.x, step.y, step.text end
    end
    local loc = self:DBLocationForStep(step)
    if loc then return loc.map, loc.x, loc.y, step.text or loc.name, loc end
    if step.quest then
        local mapID, x, y = ns.Quest:GetWaypoint(step.quest)
        if mapID then return mapID, x, y, step.text end
    end
    return nil
end

local OBJECTIVE_STEP = { COMPLETE = true, KILL = true, COLLECT = true }

--- Blizzard's own idea of where an objective step's quest is done, once it is in the log: the
--- world map's pin on the player's map, then on the step's map, then the client's next waypoint
--- (cross-zone routing). nil when the client has none, and the guide's data takes over.
function Nav:BlizzardLocationForStep(step)
    local questID = step.quest
    if not (questID and OBJECTIVE_STEP[step.type] and ns.Quest:IsOnQuest(questID)) then return nil end
    local maps = { ns.Player:GetMapID() }
    if step.map and step.map ~= maps[1] then maps[#maps + 1] = step.map end
    for _, mapID in ipairs(maps) do
        local x, y = ns.Quest:GetMapPin(questID, mapID)
        if x then return { map = mapID, x = x, y = y, blizzard = true } end
    end
    local mapID, x, y = ns.Quest:GetWaypoint(questID)
    if mapID then return { map = mapID, x = x, y = y, blizzard = true } end
    return nil
end

--- The location on `mapID` closest to (x, y) in map percent, or nil when none is on that map.
function Nav:ClosestTo(locs, mapID, x, y)
    local best, bestD
    for _, loc in ipairs(locs) do
        if loc.map == mapID then
            local dx, dy = loc.x - x, loc.y - y
            local d = dx * dx + dy * dy
            if not bestD or d < bestD then best, bestD = loc, d end
        end
    end
    return best
end

--- How far (map percent) a near step's spawns may be from its planned spot to count.
local NEAR_RADIUS = 15

--- Nearest database location that makes progress on a step, or nil. With `around` ({map, x, y}),
--- only locations within NEAR_RADIUS of it count.
function Nav:DBLocationForStep(step, around)
    local DB = ns.DB
    if not DB or not DB:IsLoaded() then return nil end
    local t = step.type
    local locs
    if step.npc and (t == "TALK" or t == "TRAIN" or t == "FLY" or t == "ACCEPT" or t == "TURNIN" or t == "HEARTH") then
        locs = DB:NPCLocations(step.npc)
    end
    if (not locs or #locs == 0) and step.quest then
        if t == "ACCEPT" then
            locs = DB:QuestStarts(step.quest)
        elseif t == "TURNIN" then
            locs = DB:QuestEnds(step.quest)
        elseif ns.Guide.OBJECTIVE[t] then
            locs = {}
            local game = ns.Quest:GetObjectives(step.quest)
            local objIdx = ns.Guide:StepObjectiveIndex(step)
            if objIdx then
                local o = game and game[objIdx]
                local dbo = DB:MatchObjective(step.quest, objIdx, o and o.text)
                if dbo then for _, l in ipairs(dbo.locations) do locs[#locs + 1] = l end end
            elseif game and #game > 0 then
                for idx, o in ipairs(game) do
                    if not o.finished then
                        local dbo = DB:MatchObjective(step.quest, idx, o.text)
                        if dbo then for _, l in ipairs(dbo.locations) do locs[#locs + 1] = l end end
                    end
                end
            end
            if #locs == 0 then
                if step.npc then
                    locs = DB:NPCLocations(step.npc)
                else
                    for _, dbo in ipairs(DB:QuestObjectives(step.quest)) do
                        for _, l in ipairs(dbo.locations) do locs[#locs + 1] = l end
                    end
                end
            end
        end
    end
    if (not locs or #locs == 0) and step.npc then locs = DB:NPCLocations(step.npc) end
    if (not locs or #locs == 0) and step.item and t == "BUY" then locs = DB:ItemLocations(step.item) end
    if not locs or #locs == 0 then return nil end
    if around then
        local kept = {}
        for _, l in ipairs(locs) do
            local dx, dy = (l.x or 0) - around.x, (l.y or 0) - around.y
            if l.map == around.map and dx * dx + dy * dy <= NEAR_RADIUS * NEAR_RADIUS then kept[#kept + 1] = l end
        end
        if #kept == 0 then return nil end
        locs = kept
    end
    local loc = DB:Nearest(locs)
    return loc
end

function Nav:OnInit()
    -- back from the dead: plan the way to whatever the arrow points at again. Only with no route
    -- (dead, there was none): the game also says PLAYER_ALIVE after a loading screen (the tram, a
    -- Hearthstone), where planning afresh, with no position yet, dropped the way being followed
    ns.Events:RegisterMany({ "PLAYER_UNGHOST", "PLAYER_ALIVE" }, function()
        if self.target and not self.route and not Dead() then self:Replan() end
    end)
end
