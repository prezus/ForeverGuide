-- ============================================================
-- ForeverGuide / Travel.lua
-- The travel planner: the fastest way from where the player stands to a
-- target, as legs (walk, fly, boat, zeppelin, tram, portal, lift, hearth,
-- teleport), each with its seconds.
--
-- Data: ns.TravelDB (Data/TravelDB.lua, written by codex): flight nodes and
-- flights, one-way links (boats, zeppelins, the tram, portals, lifts), class
-- teleports and inns. Positions are uiMapID + x/y 0-100; the planner works in
-- world yards through Navigation:MapToWorld, cached per point.
--
-- The plan is Dijkstra over the start, the target, the flight masters the
-- character knows, the links' ends, the bind point and the teleports'
-- landings. Walking is straight-line yards x WALK_DETOUR at the run speed,
-- and only within one world map (a continent, or Zephras Isle). A flight
-- boards once (TravelDB.flightBoard) and may chain direct flights through
-- known nodes. The Hearthstone and teleports carry a margin in the cost the
-- search compares (not in the seconds shown), so a spent cooldown has to buy
-- real time.
--
-- Pure: Plan reads only its arguments and the data, so the engine decides
-- when to plan and the tests drive it directly.
-- ============================================================

local _, ns = ...
local Travel = ns:NewModule("Travel")

local sqrt, huge, floor = math.sqrt, math.huge, math.floor

Travel.WALK_DETOUR = 1.2      -- straight-line yards to walked yards; #695 fits it to recorded runs
Travel.DEFAULT_SPEED = 7      -- yards a second, a running character
Travel.HEARTH_MARGIN = 120    -- seconds added to a Hearthstone's cost, not its time
Travel.TELEPORT_MARGIN = 10   -- the same for a class teleport (a reagent, a cooldown)
Travel.LOADING_SECONDS = 5    -- a jump to another world map
Travel.MAX_POPS = 1500        -- search caps: a plan never costs a frame
Travel.BUDGET_MS = 25

local SAME_SPOT_YARDS = 5     -- a walk shorter than this is no leg

-- ------------------------------------------------------------
-- World positions of map points, cached per point table
-- ------------------------------------------------------------
local worldOf = setmetatable({}, { __mode = "k" })

--- A map point's world position: { inst, x, y }, or nil where the client cannot place it.
local function World(p)
    if not p then return nil end
    local w = worldOf[p]
    if w == nil then
        local inst, x, y = ns.Navigation:MapToWorld(p.map, p.x, p.y)
        w = inst and { inst = inst, x = x, y = y } or false
        worldOf[p] = w
    end
    return w or nil
end
Travel.World = World

--- Forget every cached position (the map conversion changed: the tests swap it).
function Travel:ForgetPositions()
    worldOf = setmetatable({}, { __mode = "k" })
end

local function Yards(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return sqrt(dx * dx + dy * dy)
end

-- ------------------------------------------------------------
-- A small binary heap of node indexes by cost
-- ------------------------------------------------------------
local function Push(heap, cost, i)
    local n = #heap + 1
    heap[n] = i
    while n > 1 do
        local parent = floor(n / 2)
        if cost[heap[parent]] <= cost[heap[n]] then break end
        heap[parent], heap[n] = heap[n], heap[parent]
        n = parent
    end
end

local function Pop(heap, cost)
    local top, n = heap[1], #heap
    heap[1] = heap[n]
    heap[n] = nil
    n = n - 1
    local i = 1
    while true do
        local l, r, m = i * 2, i * 2 + 1, i
        if l <= n and cost[heap[l]] < cost[heap[m]] then m = l end
        if r <= n and cost[heap[r]] < cost[heap[m]] then m = r end
        if m == i then break end
        heap[i], heap[m] = heap[m], heap[i]
        i = m
    end
    return top
end

-- ------------------------------------------------------------
-- The graph for one plan
-- ------------------------------------------------------------
--- Node kinds: "start", "target", "ground" (a flight master), "air" (aloft over a
--- flight node), "board" (a link's start), "land" (a link's end), "arrive" (where a
--- hearth or teleport puts the player). Walks go from any node on the ground to a
--- "target", "ground" or "board" node on the same world map.
local function Build(from, to, opts)
    local db = ns.TravelDB or {}
    local side = opts.faction == "Horde" and "H" or "A"
    local nodes, edges = {}, {}
    local function Add(node)
        nodes[#nodes + 1] = node
        edges[#nodes] = {}
        return #nodes
    end
    local function Edge(a, b, cost, seconds, leg)
        local list = edges[a]
        list[#list + 1] = { to = b, cost = cost, seconds = seconds, leg = leg }
    end

    local start = Add({ kind = "start", pos = from, w = World(from) })
    local target = Add({ kind = "target", pos = to, w = World(to) })

    -- Flights: a ground node where the master stands and an air node above it.
    local known, airOf = opts.known or {}, {}
    for id, node in pairs(db.flightNodes or {}) do
        local at = node.at and node.at[side]
        local w = at and World(at)
        if w and known[node.name] and (node.faction == nil or node.faction == side) then
            local ground = Add({ kind = "ground", pos = at, w = w, node = id, name = node.name })
            local air = Add({ kind = "air", pos = at, w = w, node = id, name = node.name })
            airOf[id] = air
            local board = db.flightBoard or 15
            Edge(ground, air, board, board, { kind = "board" })
            Edge(air, ground, 0, 0, { kind = "land" })
        end
    end
    for fromId, hops in pairs(db.flights or {}) do
        local a = airOf[fromId]
        if a then
            for toId, seconds in pairs(hops) do
                local b = airOf[toId]
                if b then Edge(a, b, seconds, seconds, { kind = "hop" }) end
            end
        end
    end

    -- Links: board at one end, arrive at the other, after the wait and the ride.
    for _, link in ipairs(db.links or {}) do
        local wa, wb = World(link.from), World(link.to)
        if wa and wb and (link.faction == nil or link.faction == side) then
            local a = Add({ kind = "board", pos = link.from, w = wa })
            local b = Add({ kind = "land", pos = link.to, w = wb })
            local seconds = (link.wait or 0) + (link.ride or 0)
            Edge(a, b, seconds, seconds, { kind = link.kind, name = link.name, wait = link.wait, ride = link.ride })
        end
    end

    -- The Hearthstone and teleports, cast where the player stands.
    local sw = nodes[start].w
    local function Jump(pos, wait, cast, margin, leg)
        local w = World(pos)
        if not w or not sw then return end
        local landing = Add({ kind = "arrive", pos = pos, w = w })
        local seconds = (wait or 0) + (cast or 0) + (w.inst ~= sw.inst and Travel.LOADING_SECONDS or 0)
        Edge(start, landing, seconds + margin, seconds, leg)
    end
    if opts.bind and opts.hearthWait then
        Jump(opts.bind, opts.hearthWait, 10, Travel.HEARTH_MARGIN, { kind = "hearth", name = opts.bindName })
    end
    for _, t in ipairs(opts.teleports or {}) do
        local spell = db.teleports and db.teleports[t.spell]
        if spell then
            local land = spell.bind and opts.bind or spell.to
            if land then
                Jump(land, t.wait, spell.cast, Travel.TELEPORT_MARGIN,
                    { kind = "teleport", spell = t.spell, name = spell.bind and opts.bindName or (spell.to and spell.to.name) })
            end
        end
    end

    -- Where a walk may lead.
    local walkTo = {}
    for i, node in ipairs(nodes) do
        if node.w and (node.kind == "target" or node.kind == "ground" or node.kind == "board") then
            walkTo[#walkTo + 1] = i
        end
    end
    return nodes, edges, start, target, walkTo
end

-- ------------------------------------------------------------
-- Plan
-- ------------------------------------------------------------
--- The fastest way from `from` to `to` (map points { map, x, y }).
--- opts: faction ("Alliance"|"Horde"), known (set of flight node names), speed
--- (yards a second), bind ({ map, x, y }) and bindName, hearthWait (seconds until
--- the Hearthstone is ready; nil when there is none), teleports ({ { spell, wait } }
--- castable now or after `wait`).
--- Returns { legs = { { kind, from, to, seconds, wait?, name?, spell? } }, seconds },
--- or nil and why: "nowhere" (start or target has no world position), "unreachable",
--- "budget" (the search ran out of its caps).
function Travel:Plan(from, to, opts)
    opts = opts or {}
    local nodes, edges, start, target, walkTo = Build(from, to, opts)
    if not nodes[start].w or not nodes[target].w then return nil, "nowhere" end
    local speed = (opts.speed and opts.speed > 0) and opts.speed or Travel.DEFAULT_SPEED

    local cost, seconds, prev, via, done = {}, {}, {}, {}, {}
    for i = 1, #nodes do cost[i] = huge end
    cost[start], seconds[start] = 0, 0
    local heap = { start }
    local clock = rawget(_G, "debugprofilestop")
    local began = clock and clock()
    local pops = 0

    local function Relax(u, v, c, s, leg)
        local nc = cost[u] + c
        if nc < cost[v] then
            cost[v], seconds[v], prev[v], via[v] = nc, seconds[u] + s, u, leg
            Push(heap, cost, v)
        end
    end

    while #heap > 0 do
        local u = Pop(heap, cost)
        if not done[u] then
            done[u] = true
            if u == target then break end
            pops = pops + 1
            if pops > Travel.MAX_POPS or (clock and clock() - began > Travel.BUDGET_MS) then return nil, "budget" end
            for _, e in ipairs(edges[u]) do
                if not done[e.to] then Relax(u, e.to, e.cost, e.seconds, e.leg) end
            end
            local nu = nodes[u]
            if nu.kind ~= "air" and nu.w then
                for _, v in ipairs(walkTo) do
                    local nv = nodes[v]
                    if v ~= u and not done[v] and nv.w.inst == nu.w.inst then
                        local s = Yards(nu.w, nv.w) * Travel.WALK_DETOUR / speed
                        Relax(u, v, s, s, { kind = "walk" })
                    end
                end
            end
        end
    end
    if cost[target] == huge then return nil, "unreachable" end

    -- Walk back from the target, then merge a flight's board, hops and landing into one leg.
    local chain, at = {}, target
    while prev[at] do
        table.insert(chain, 1, { from = prev[at], to = at, leg = via[at] })
        at = prev[at]
    end
    local legs, flight = {}, nil
    for _, step in ipairs(chain) do
        local a, b, kind = nodes[step.from], nodes[step.to], step.leg.kind
        local span = seconds[step.to] - seconds[step.from]
        if kind == "board" then
            flight = { kind = "fly", from = a.pos, seconds = span, node = a.node }
        elseif kind == "hop" and flight then
            flight.seconds = flight.seconds + span
        elseif kind == "land" and flight then
            flight.to, flight.name, flight.toNode = b.pos, b.name, b.node
            legs[#legs + 1] = flight
            flight = nil
        elseif kind == "walk" then
            if Yards(a.w, b.w) >= SAME_SPOT_YARDS then
                legs[#legs + 1] = { kind = "walk", from = a.pos, to = b.pos, seconds = span }
            end
        else
            legs[#legs + 1] = { kind = kind, from = a.pos, to = b.pos, seconds = span, wait = step.leg.wait, name = step.leg.name, spell = step.leg.spell }
        end
    end
    return { legs = legs, seconds = seconds[target] }
end

-- ------------------------------------------------------------
-- The character: where its Hearthstone is bound, which teleports it can
-- cast and when, what it knows. Plan takes these as options (Options).
-- ------------------------------------------------------------
local Plain, PlainNumber, PlainString, Safe = ns.Plain, ns.PlainNumber, ns.PlainString, ns.Safe

local HEARTHSTONE_ITEM, HEARTHSTONE_SPELL, ASTRAL_RECALL = 6948, 8690, 556
local LANDED_AFTER = 2      -- seconds after a hearth cast to read where it set the player down
local LANDING_WINDOW = 60   -- a loading screen may delay that past the timer

local function BindName()
    return PlainString(Safe(rawget(_G, "GetBindLocation")))
end

local function Here()
    local map, x, y = ns.Player:GetMapPosition()
    if map and x and y then return { map = map, x = x, y = y } end
end

--- Seconds until a cooldown that started at `start` for `duration` ends; 0 when ready.
local function Remaining(start, duration)
    start, duration = PlainNumber(start), PlainNumber(duration)
    if not start or not duration or start <= 0 or duration <= 0 then return 0 end
    local now = PlainNumber(Safe(rawget(_G, "GetTime"))) or 0
    local left = start + duration - now
    return left > 0 and left or 0
end

local function SpellKnown(spell)
    local known = Plain(ns.Call("C_SpellBook.IsSpellKnown", spell))
    if known == nil then known = Plain(Safe(rawget(_G, "IsSpellKnown"), spell)) end
    return known == true
end

local function HasReagents(reagents)
    for item, count in pairs(reagents or {}) do
        if (PlainNumber(ns.Call("C_Item.GetItemCount", item)) or 0) < count then return false end
    end
    return true
end

--- Remember where the Hearthstone is bound, under the name the client gives the place.
function Travel:RecordBind(where, npcID)
    local name = BindName()
    if not name or not where then return end
    ns.char.bind = { map = where.map, x = where.x, y = where.y, name = name, npc = npcID }
end

--- The bind point { map, x, y, name }, or nil while unknown. The client says only the place's
--- name, so the position is the innkeeper's (or where the player stood) when the player bound,
--- or where a Hearthstone last set the player down; a bind made elsewhere with the addon off
--- (the name no longer matches) forgets it.
function Travel:Bind()
    local b = ns.char and ns.char.bind
    if not b then return nil end
    local name = BindName()
    if name and b.name ~= name then
        ns.char.bind = nil
        return nil
    end
    return b
end

--- Seconds until the Hearthstone is ready (0 now), or nil without one in the bags.
function Travel:HearthWait()
    if (PlainNumber(ns.Call("C_Item.GetItemCount", HEARTHSTONE_ITEM)) or 0) == 0 then return nil end
    local start, duration = ns.Call("C_Container.GetItemCooldown", HEARTHSTONE_ITEM)
    if start == nil then start, duration = Safe(rawget(_G, "GetItemCooldown"), HEARTHSTONE_ITEM) end
    return Remaining(start, duration)
end

--- The class teleports the character knows and has the reagents for: { { spell, wait } }.
function Travel:Teleports()
    local out = {}
    for spell, t in pairs(ns.TravelDB and ns.TravelDB.teleports or {}) do
        if SpellKnown(spell) and HasReagents(t.reagents) then
            local info = ns.Call("C_Spell.GetSpellCooldown", spell)
            local wait = type(info) == "table" and Remaining(info.startTime, info.duration) or 0
            out[#out + 1] = { spell = spell, wait = wait }
        end
    end
    table.sort(out, function(a, b) return a.spell < b.spell end)
    return out
end

--- Plan's options for this character now: faction, known flight points, run speed, and the
--- Hearthstone and teleports unless the player turned them off (nav.useHearth).
function Travel:Options()
    local useHearth = not (ns.db and ns.db.nav and ns.db.nav.useHearth == false)
    local bind = useHearth and self:Bind() or nil
    local _, run = Safe(rawget(_G, "GetUnitSpeed"), "player")
    return {
        faction = ns.Player:GetFaction(),
        known = ns.Reminders and ns.Reminders.Known and ns.Reminders.Known() or {},
        speed = PlainNumber(run),
        bind = bind,
        bindName = bind and bind.name,
        hearthWait = bind and self:HearthWait() or nil,
        teleports = useHearth and self:Teleports() or {},
    }
end

function Travel:OnInit()
    -- Bound while talking to an innkeeper: the inn is where that innkeeper stands.
    ns.Events:Register("HEARTHSTONE_BOUND", function()
        local npc = ns.Player:GetInteractionNPC()
        local id = npc and npc.npcID
        local inn = id and ns.TravelDB and ns.TravelDB.inns and ns.TravelDB.inns[id]
        self:RecordBind(inn or Here(), id)
    end)
    -- A Hearthstone or Astral Recall puts the player at the bind point: learn it there if unknown.
    local function Landed()
        if not self.castAt then return end
        local age = (PlainNumber(Safe(rawget(_G, "GetTime"))) or 0) - self.castAt
        if age > LANDING_WINDOW then
            self.castAt = nil
            return
        end
        local here = Here()
        if not here then return end   -- still loading; PLAYER_ENTERING_WORLD tries again
        self.castAt = nil
        if not self:Bind() then self:RecordBind(here) end
    end
    ns.Events:Register("UNIT_SPELLCAST_SUCCEEDED", function(_, unit, _, spellID)
        spellID = PlainNumber(spellID)
        if unit ~= "player" or (spellID ~= HEARTHSTONE_SPELL and spellID ~= ASTRAL_RECALL) then return end
        self.castAt = PlainNumber(Safe(rawget(_G, "GetTime"))) or 0
        C_Timer.After(LANDED_AFTER, Landed)
    end)
    ns.Events:Register("PLAYER_ENTERING_WORLD", Landed)
end
