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
-- or, where the walking maps have found the way (opts.walk), its own yards;
-- and only within one world map (a continent, or Zephras Isle). A flight
-- boards once (TravelDB.flightBoard) and may chain direct flights through
-- known nodes. The Hearthstone and teleports carry a margin in the cost the
-- search compares (not in the seconds shown), so a spent cooldown has to buy
-- real time. A boat or zeppelin waits half its loop, or, once the player has
-- been seen riding it, until its next departure after they reach the dock
-- (opts.departures, #697).
--
-- Pure: Plan reads only its arguments and the data, so the engine decides
-- when to plan and the tests drive it directly.
-- ============================================================

local _, ns = ...
local Travel = ns:NewModule("Travel")

local sqrt, huge, floor, max = math.sqrt, math.huge, math.floor, math.max

Travel.WALK_DETOUR = 1.2      -- straight-line yards to walked yards; #695 fits it to recorded runs
Travel.DEFAULT_SPEED = 7      -- yards a second, a running character
Travel.HEARTH_MARGIN = 120    -- seconds added to a Hearthstone's cost, not its time
Travel.TELEPORT_MARGIN = 10   -- the same for a class teleport (a reagent, a cooldown)
-- Each boarding (a flight, a boat, a zeppelin, the tram, a lift, a portal) costs this many seconds more than
-- it takes, not in the time shown: a way of fewer changes wins unless another saves real time. A flight on
-- through further flight points is one ride (the taxi carries the player), so its hops add none: from
-- Sentinel Hill to Thelsamar, one flight on through Stormwind and Ironforge, not a flight, the tram and another.
Travel.CHANGE_SECONDS = 45
Travel.LOADING_SECONDS = 5    -- a jump to another world map
Travel.MAX_POPS = 1500        -- search caps: a plan never costs a frame
Travel.BUDGET_MS = 25

local SAME_SPOT_YARDS = 5     -- a walk shorter than this is no leg
local WALK_LEG = { kind = "walk" }   -- every walk the search tries is this one (read only)

local graph   -- the flights and links, kept between plans (Static)

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
        -- a point's own height (a lift's landing, a zeppelin's platform) goes with it, for the walk that ends there
        w = inst and { inst = inst, x = x, y = y, z = type(p.z) == "number" and p.z or nil } or false
        worldOf[p] = w
    end
    return w or nil
end
Travel.World = World

--- Forget every cached position (the map conversion changed: the tests swap it).
function Travel:ForgetPositions()
    worldOf = setmetatable({}, { __mode = "k" })
    graph = nil
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
---
--- The flights and links are the same from plan to plan, so they are built once and kept (a plan
--- every few seconds made hundreds of KB of garbage); a plan adds its start, target and landings
--- past them and drops them at the next. Kept until the data, the side, the flight points known or
--- the change cost differ: graph = { db, side, sig, change, links, size, walks, nodes, edges, walkTo }.

--- What the flight points known add up to, for the side: their count and their ids' sum.
local function KnownSig(db, side, known)
    local n, sum = 0, 0
    for id, node in pairs(db.flightNodes or {}) do
        if known[node.name] and (node.faction == nil or node.faction == side) and node.at and node.at[side] then
            n, sum = n + 1, sum + id
        end
    end
    return n * 1000003 + sum
end

local function Static(db, side, known)
    local sig = KnownSig(db, side, known)
    local g = graph
    if g and g.db == db and g.side == side and g.sig == sig and g.change == Travel.CHANGE_SECONDS and g.links == #(db.links or {}) then
        return g
    end
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

    -- Flights: a ground node where the master stands and an air node above it.
    local airOf = {}
    for id, node in pairs(db.flightNodes or {}) do
        local at = node.at and node.at[side]
        local w = at and World(at)
        if w and known[node.name] and (node.faction == nil or node.faction == side) then
            local ground = Add({ kind = "ground", pos = at, w = w, node = id, name = node.name })
            local air = Add({ kind = "air", pos = at, w = w, node = id, name = node.name })
            airOf[id] = air
            local board = db.flightBoard or 15
            Edge(ground, air, board + Travel.CHANGE_SECONDS, board, { kind = "board" })
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
            Edge(a, b, seconds + Travel.CHANGE_SECONDS, seconds, { kind = link.kind, name = link.name, wait = link.wait, ride = link.ride, path = link.path,
                transport = link.transport, loop = link.loop, leaves = link.leaves })
        end
    end

    -- Where a walk may lead; the plan's target joins them.
    local walkTo = {}
    for i, node in ipairs(nodes) do
        if node.w and (node.kind == "ground" or node.kind == "board") then walkTo[#walkTo + 1] = i end
    end
    graph = { db = db, side = side, sig = sig, change = Travel.CHANGE_SECONDS, links = #(db.links or {}),
        size = #nodes, walks = #walkTo, nodes = nodes, edges = edges, walkTo = walkTo }
    return graph
end

local function Build(from, to, opts)
    local db = ns.TravelDB or {}
    local side = opts.faction == "Horde" and "H" or "A"
    local g = Static(db, side, opts.known or {})
    local nodes, edges, walkTo = g.nodes, g.edges, g.walkTo
    -- the last plan's own nodes go
    for i = #nodes, g.size + 1, -1 do nodes[i], edges[i] = nil, nil end
    for i = #walkTo, g.walks + 1, -1 do walkTo[i] = nil end
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
    if nodes[target].w then walkTo[#walkTo + 1] = target end

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
    return nodes, edges, start, target, walkTo
end

-- ------------------------------------------------------------
-- Plan
-- ------------------------------------------------------------
-- The search's own tables, refilled each plan rather than made anew
local work = { cost = {}, seconds = {}, prev = {}, via = {}, done = {}, heap = {}, used = 0 }

--- The fastest way from `from` to `to` (map points { map, x, y }).
--- opts: faction ("Alliance"|"Horde"), known (set of flight node names), speed
--- (yards a second), bind ({ map, x, y }) and bindName, hearthWait (seconds until
--- the Hearthstone is ready; nil when there is none), teleports ({ { spell, wait } }
--- castable now or after `wait`), walk (function(a, b) -> the yards a walk between two world
--- points takes when the walking maps know its way, else nil; and the yards it is priced at, when
--- more: the other faction's towns and zones far above the player on the way), now (server time) and
--- departures ({ [transport] = when its loop began, server time }: Travel:Departures) for the boats
--- and zeppelins seen under way, whose wait is then until their next departure.
--- Returns { legs = { { kind, from, to, seconds, wait?, departs?, name?, spell? } }, seconds },
--- or nil and why: "nowhere" (start or target has no world position), "unreachable",
--- "budget" (the search ran out of its caps).
function Travel:Plan(from, to, opts)
    opts = opts or {}
    local nodes, edges, start, target, walkTo = Build(from, to, opts)
    if not nodes[start].w or not nodes[target].w then return nil, "nowhere" end
    local speed = (opts.speed and opts.speed > 0) and opts.speed or Travel.DEFAULT_SPEED
    local now, departures = opts.now, opts.departures

    local cost, seconds, prev, via, done, heap = work.cost, work.seconds, work.prev, work.via, work.done, work.heap
    for i = 1, max(#nodes, work.used) do cost[i], seconds[i], prev[i], via[i], done[i] = huge, nil, nil, nil, nil end
    for i = #heap, 1, -1 do heap[i] = nil end
    work.used = #nodes
    cost[start], seconds[start] = 0, 0
    heap[1] = start
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
                if not done[e.to] then
                    local leg = e.leg
                    local loopBegan = now and leg.loop and departures and departures[leg.transport]
                    if loopBegan then
                        -- timed: wait at the dock for its next departure (a later arrival never leaves sooner)
                        local reach = now + seconds[u]
                        local s = Travel.NextDeparture(loopBegan, leg.leaves, leg.loop, reach) - reach + (leg.ride or 0)
                        Relax(u, e.to, s + Travel.CHANGE_SECONDS, s, leg)
                    else
                        Relax(u, e.to, e.cost, e.seconds, leg)
                    end
                end
            end
            local nu = nodes[u]
            if nu.kind ~= "air" and nu.w then
                for _, v in ipairs(walkTo) do
                    local nv = nodes[v]
                    if v ~= u and not done[v] and nv.w.inst == nu.w.inst then
                        -- a found way's yards; priced with what its towns and dangerous zones add (#747)
                        local walked, priced
                        if opts.walk then walked, priced = opts.walk(nu.w, nv.w) end
                        local s = (walked or Yards(nu.w, nv.w) * Travel.WALK_DETOUR) / speed
                        Relax(u, v, priced and priced / speed or s, s, WALK_LEG)
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
            flight = { kind = "fly", from = a.pos, seconds = span, node = a.node, hops = { a.node } }
        elseif kind == "hop" and flight then
            flight.seconds = flight.seconds + span
            flight.hops[#flight.hops + 1] = b.node
        elseif kind == "land" and flight then
            flight.to, flight.name, flight.toNode = b.pos, b.name, b.node
            legs[#legs + 1] = flight
            flight = nil
        elseif kind == "walk" then
            if Yards(a.w, b.w) >= SAME_SPOT_YARDS then
                legs[#legs + 1] = { kind = "walk", from = a.pos, to = b.pos, seconds = span }
            end
        else
            local leg, wait, departs = step.leg, step.leg.wait, nil
            local loopBegan = now and leg.loop and departures and departures[leg.transport]
            if loopBegan then
                local reach = now + seconds[step.from]
                departs = Travel.NextDeparture(loopBegan, leg.leaves, leg.loop, reach)
                wait = departs - reach
            end
            legs[#legs + 1] = { kind = kind, from = a.pos, to = b.pos, seconds = span, wait = wait, departs = departs, name = leg.name, spell = leg.spell, path = leg.path }
        end
    end
    return { legs = legs, seconds = seconds[target] }
end

-- ------------------------------------------------------------
-- A ride's path: a flight's taxi path, a boat's or zeppelin's sailing path (TravelDB, #742), as runs
-- { map, x1, y1, x2, y2, ... } in world yards, one a world map
-- ------------------------------------------------------------
--- A ride leg's path: its link's own, or a flight's hops' taxi paths end to end; nil when TravelDB has none.
function Travel.RidePath(leg)
    if not leg then return nil end
    if leg.path then return leg.path end
    local fp = leg.kind == "fly" and leg.hops and ns.TravelDB and ns.TravelDB.flightPaths
    if not fp then return nil end
    local out = {}
    for i = 1, #leg.hops - 1 do
        local runs = fp[leg.hops[i]] and fp[leg.hops[i]][leg.hops[i + 1]]
        if not runs then return nil end
        for _, run in ipairs(runs) do out[#out + 1] = run end
    end
    return #out > 0 and out or nil
end

--- How much of a path is left from (x, y) on world map `inst`: the yards from the nearest point of the
--- path on that map to its end, the whole path's yards, and how far (x, y) is from that nearest point;
--- nil when the path does not cross that map.
function Travel.PathLeft(runs, inst, x, y)
    local total, lengths = 0, {}
    for r, run in ipairs(runs) do
        local len = 0
        for i = 4, #run - 1, 2 do len = len + math.sqrt((run[i] - run[i - 2]) ^ 2 + (run[i + 1] - run[i - 1]) ^ 2) end
        lengths[r], total = len, total + len
    end
    local best, left = math.huge, nil
    local after = total
    for r, run in ipairs(runs) do
        after = after - lengths[r]
        if run[1] == inst then
            local tail = lengths[r]
            for i = 4, #run - 1, 2 do
                local ax, ay, bx, by = run[i - 2], run[i - 1], run[i], run[i + 1]
                local seg = math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
                local f = seg > 0 and math.max(0, math.min(1, ((x - ax) * (bx - ax) + (y - ay) * (by - ay)) / (seg * seg))) or 0
                local d = math.sqrt((ax + (bx - ax) * f - x) ^ 2 + (ay + (by - ay) * f - y) ^ 2)
                if d < best then best, left = d, tail - seg * f + after end
                tail = tail - seg
            end
        end
    end
    if not left then return nil end
    return left, total, best
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

-- ------------------------------------------------------------
-- Departures (#697): a boat or zeppelin leaves each of its docks once a loop (TravelDB's `loop`), at
-- its own moment in the loop (`leaves`). The player seen riding one fixes when its loop began, which
-- times its departures from every dock for hours; until then a wait is half a loop.
-- ------------------------------------------------------------
local SEE_EVERY = 2               -- seconds between looks for a ride under way
local OFF_PATH_YARDS = 40         -- this near a ride's path is on it
local PACE_SLACK = 0.35           -- moving along the path within this share of the ride's own pace
local DEPARTURES_HOLD = 6 * 3600  -- seconds a timetable is kept: a server restart starts the loops anew

local function ServerTime()
    return PlainNumber(Safe(rawget(_G, "GetServerTime")))
end

--- This realm's timetables, saved for every character: { [transport] = { began, at } }.
local function RealmTimetables()
    ns.db.departures = ns.db.departures or {}
    local realm = PlainString(Safe(rawget(_G, "GetRealmName"))) or "?"
    local t = ns.db.departures[realm]
    if not t then
        t = {}
        ns.db.departures[realm] = t
    end
    return t
end

--- The first departure at or after `t` from a dock a transport leaves `leaves` seconds into each loop of
--- `loop` seconds, its loop having begun at `began` (all server time).
function Travel.NextDeparture(began, leaves, loop, t)
    local first = began + leaves
    return first + math.ceil((t - first) / loop) * loop
end

--- The transports timed on this realm and seen recently enough: { [transport] = when its loop began }.
function Travel:Departures(now)
    local out = {}
    if not now or not ns.db then return out end
    for transport, seen in pairs(RealmTimetables()) do
        if now - seen.at <= DEPARTURES_HOLD then out[transport] = seen.began end
    end
    return out
end

local looked = {}   -- the last look: { [link] = { left, at } } for each ride path the player was on
local lookedAt      -- when it was taken

--- Look for a ride under way at world point (x, y) on map `inst` at server time `now`. The player is on a
--- boat or zeppelin when two looks in a row find them on one of its links' paths, gone along it at the
--- ride's own pace (a mount on the shore goes faster, a walker slower, and the way back goes against it);
--- how far along they are says when it left the dock, and so when its loop began.
function Travel:SeeRide(inst, x, y, now)
    if not now or (lookedAt and now - lookedAt < SEE_EVERY) then return end
    local before = looked
    looked, lookedAt = {}, now
    if not inst or not x or Plain(Safe(rawget(_G, "UnitOnTaxi"), "player")) == true then return end
    for _, link in ipairs(ns.TravelDB and ns.TravelDB.links or {}) do
        if link.transport and link.loop and link.leaves and link.path and (link.ride or 0) > 0 then
            local left, whole, off = Travel.PathLeft(link.path, inst, x, y)
            if left and whole > 0 and off <= OFF_PATH_YARDS and left > 0 and left < whole then
                looked[link] = { left = left, at = now }
                local last = before[link]
                if last and now > last.at then
                    local pace, own = (last.left - left) / (now - last.at), whole / link.ride
                    if math.abs(pace - own) <= own * PACE_SLACK then
                        local left_dock = now - (whole - left) / whole * link.ride
                        RealmTimetables()[link.transport] = { began = left_dock - link.leaves, at = now }
                    end
                end
            end
        end
    end
end

local lastSpeed   -- the last run speed the game gave (session state, never saved)

--- The player's run speed in yards a second, a mount counted: the game's, else the last it gave (it gives
--- none, or a secret value, in combat), else a running character's before any.
function Travel.RunSpeed()
    local _, run = Safe(rawget(_G, "GetUnitSpeed"), "player")
    run = PlainNumber(run)
    if run and run > 0 and run < math.huge then lastSpeed = run end
    return lastSpeed or Travel.DEFAULT_SPEED
end

--- Forget the last run speed (the tests).
function Travel.ForgetSpeed() lastSpeed = nil end

--- Plan's options for this character now: faction, known flight points, run speed, and the
--- Hearthstone and teleports unless the player turned them off (nav.useHearth).
function Travel:Options()
    local now = ServerTime()
    local useHearth = not (ns.db and ns.db.nav and ns.db.nav.useHearth == false)
    local bind = useHearth and self:Bind() or nil
    return {
        faction = ns.Player:GetFaction(),
        known = ns.Reminders and ns.Reminders.Known and ns.Reminders.Known() or {},
        speed = self.RunSpeed(),
        bind = bind,
        bindName = bind and bind.name,
        hearthWait = bind and self:HearthWait() or nil,
        teleports = useHearth and self:Teleports() or {},
        now = now,
        departures = self:Departures(now),
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
