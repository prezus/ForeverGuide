-- ============================================================
-- ForeverGuide / FieldTests.lua
-- Field checks: a short, temporary guide a tester follows in game to gather what the travel
-- planner and its walking maps need (prezus/forever-codex#724). `/fg tests` remembers the guide,
-- the travel planner and Record runs as they are, then turns the planner and recording on and
-- opens the checks for the character's faction, from the first step with nothing done (run again,
-- it starts them over); `/fg tests off` puts all three back.
--
-- Nothing new is recorded: every recorded entry already names the guide and step being followed
-- (g/s, Run.lua), so each check's stretch of the recording is its own, with the planner's ROUTE,
-- LEG and LEGDONE entries for the trips it plans. Starting also prints the height the game gives
-- for the player (UnitPosition's third value), which recordings do not carry. Every travel step
-- waits for the arrival (`arrive`), not the zone line, so each check ends where it says.
--
-- These checks are not guides for players: they are never auto-picked, and they go when the
-- data is in.
-- ============================================================

local _, ns = ...
local Tests = ns:NewModule("FieldTests")

local NOTE = "Then /fg skip."

--- The checks, by faction: places from the planner's own travel data (TravelDB) and NPC spawns.
local CHECKS = {
    Alliance = {
        id = "FIELD_CHECKS_ALLIANCE",
        name = "Field checks (Alliance)",
        faction = "Alliance",
        steps = {
            { type = "TRAVEL", arrive = true, map = 1455, x = 55.5, y = 47.74, text = "Go to Ironforge's flight master",
              note = "Follow the arrow: the travel planner chooses the way (boat, tram, flight or Hearthstone)." },
            { type = "TRAVEL", arrive = true, map = 1453, x = 70.95, y = 72.51, text = "Go to Stormwind's flight master",
              note = "From Ironforge the planner should take the Deeprun Tram." },
            { type = "TRAVEL", arrive = true, map = 1453, x = 48.2, y = 87.22, radius = 12, text = "Walk to the Wizard's Sanctum in the Mage Quarter" },
            { type = "NOTE", map = 1453, x = 48.2, y = 87.22, text = "Walk down into the Wizard's Sanctum to the mage trainers (Elsharin, Jennea Cannon). " .. NOTE,
              note = "The stairs down to their floor." },
            { type = "TRAVEL", arrive = true, map = 1429, x = 42.1, y = 65.9, text = "Walk to Goldshire",
              note = "A walk: compare the arrow's time with yours." },
            { type = "TRAVEL", arrive = true, map = 1429, x = 40.4, y = 82.4, text = "Walk to the Fargodeep Mine",
              note = "A walk across open ground." },
            { type = "TRAVEL", arrive = true, map = 1437, x = 9.49, y = 59.69, text = "Go to Menethil Harbor's flight master",
              note = "A long trip: let the planner choose." },
            { type = "TRAVEL", arrive = true, map = 1437, x = 4.74, y = 63.76, radius = 10, text = "Walk onto the pier where the boat to Theramore docks" },
            { type = "NOTE", map = 1437, x = 4.74, y = 63.76, text = "Stand where you would board, and wait for the Theramore boat to dock. " .. NOTE,
              note = "Where you board, and how long the wait was." },
            { type = "NOTE", text = "Field checks done: /fg tests off, then send the recording." },
        },
    },
    Horde = {
        id = "FIELD_CHECKS_HORDE",
        name = "Field checks (Horde)",
        faction = "Horde",
        steps = {
            { type = "TRAVEL", arrive = true, map = 1458, x = 60.6, y = 44.02, radius = 8, text = "Go to the bottom of Undercity's west lift" },
            { type = "NOTE", map = 1420, x = 60.67, y = 74.4, text = "Ride the west lift up and walk out of the throne room into the courtyard. " .. NOTE,
              note = "The throne room's way from the west lift." },
            { type = "TRAVEL", arrive = true, map = 1458, x = 71.35, y = 44.16, radius = 8, text = "Go back down to the bottom of Undercity's east lift" },
            { type = "NOTE", map = 1420, x = 62.95, y = 74.43, text = "Ride the east lift up and walk out of the throne room into the courtyard. " .. NOTE,
              note = "The throne room's way from the east lift." },
            { type = "TRAVEL", arrive = true, map = 1420, x = 60.64, y = 58.93, radius = 12, text = "Go to the zeppelin tower outside Undercity" },
            { type = "NOTE", map = 1420, x = 60.64, y = 58.93, text = "Climb to where the Orgrimmar zeppelin docks, stand where you would board, and wait for it. " .. NOTE,
              note = "Where you board, and how long the wait was." },
            { type = "TRAVEL", arrive = true, map = 1420, x = 61, y = 52, text = "Walk to Brill",
              note = "A walk: compare the arrow's time with yours." },
            { type = "NOTE", text = "Field checks done: /fg tests off, then send the recording." },
        },
    },
}

--- The checks' guide for a faction, registered the first time it is asked for.
function Tests:GuideFor(faction)
    local def = CHECKS[faction]
    if not def then return nil end
    if not ns.Guide:Get(def.id) then
        local steps = {}
        for i, s in ipairs(def.steps) do
            local copy = {}
            for k, v in pairs(s) do copy[k] = v end
            steps[i] = copy
        end
        ns.RegisterGuide({ id = def.id, name = def.name, faction = def.faction, kind = "alternate", routeLabel = "Field checks", steps = steps })
    end
    return ns.Guide:Get(def.id)
end

--- The height the game gives for the player, or nil: whether recordings could tell floors apart.
function Tests:Height()
    local x, y, z = ns.Safe(UnitPosition, "player")
    if type(x) ~= "number" or type(y) ~= "number" then return nil end
    return type(z) == "number" and z or nil
end

--- Whether the checks are running on this character.
function Tests:Active()
    return ns.char ~= nil and type(ns.char.fieldTests) == "table"
end

function Tests:Start()
    local guide = self:GuideFor(ns.Player:GetFaction())
    if not guide then ns.Error("field checks: no checks for this character's faction") return end
    if not self:Active() then
        ns.char.fieldTests = {
            guide = ns.Guide.active and ns.Guide.active.id or false,
            planner = ns.db.nav.travelPlanner == true,
            recording = ns.db.recordRuns == true,
        }
    end
    -- every /fg tests starts the checks over: nothing done, nothing skipped, step 1
    ns.Database:ResetGuide(guide.id)
    -- the guide first, so the recording's first entry already names the checks
    ns.Guide:Pick(guide.id)
    ns.Navigation:SetTravelPlanner(true)
    if ns.db.recordRuns ~= true then ns.Run:SetEnabled(true) end
    local z = self:Height()
    ns.Printf("field checks: %s, %d steps. The travel planner and recording are on; /fg tests off puts them back.", guide.name, #guide.steps)
    if z == nil then
        ns.Print("field checks: the game gives no height here.")
    else
        ns.Printf("field checks: the game gives your height as %.2f%s; put it in your report.", z, z == 0 and " (0: likely no height at all)" or "")
    end
end

function Tests:Stop()
    if not self:Active() then ns.Print("field checks are not running.") return end
    local was = ns.char.fieldTests
    ns.char.fieldTests = nil
    ns.Navigation:SetTravelPlanner(was.planner)
    if not was.recording then ns.Run:SetEnabled(false) end
    if was.guide and ns.Guide:Get(was.guide) then ns.Guide:Activate(was.guide) end
    ns.Print("field checks off: your guide, the travel planner and recording are as they were. Send the recording to finish.")
end
