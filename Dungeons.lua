-- ============================================================
-- ForeverGuide / Dungeons.lua
-- Dungeon guides ("kind": "dungeon") are opened when a group forms, not
-- followed like a chapter. This module answers what the Dungeon Quests
-- panel shows: for each dungeon guide, how many of its quests the
-- character already has, and whether it is time to go.
--
-- A dungeon guide's ACCEPT steps before its "Find a group" note are the
-- quests to bring; the ones after it are given inside the dungeon.
-- ============================================================

local _, ns = ...
local Dungeons = ns:NewModule("Dungeons")

--- Levels short of a dungeon's first level at which it starts to show as upcoming.
local UPCOMING_LEVELS = 2

--- The dungeon's name without the level range guide names carry ("The Deadmines 15-22").
function Dungeons:Name(g)
    return ((g.name or g.id):gsub("%s+%d+%-%d+$", ""))
end

--- The quests of a dungeon guide this character may take, in guide order:
--- `bring` (given outside, to have before the run) and `inside` (given in the dungeon).
function Dungeons:Quests(g)
    local G = ns.Guide
    local bring, inside, seen = {}, {}, {}
    local afterGroup = false
    for _, step in ipairs(g.steps or {}) do
        if step.type == "NOTE" and (step.text or ""):find("^Find a group") then
            afterGroup = true
        elseif step.type == "ACCEPT" and step.quest and not seen[step.quest] and G:StepApplies(step) then
            seen[step.quest] = true
            local list = afterGroup and inside or bring
            list[#list + 1] = step
        end
    end
    return bring, inside
end

--- Where the character stands with a dungeon: counts and a state.
--- state: "later" (not yet near its levels), "upcoming" (a level or two short),
--- "gathering" (at its levels, quests still to pick up), "ready" (every quest to bring
--- is in the log), "late" (at the last level its quests pay full XP), "done" (all handed in).
function Dungeons:Status(g)
    local Q = ns.Quest
    local bring, inside = self:Quests(g)
    local level = ns.Player:GetLevel() or 1
    local minL, maxL = g.minLevel or 1, g.maxLevel or 60
    local have, finished = 0, 0
    for _, s in ipairs(bring) do
        if Q:IsOnQuest(s.quest) or Q:IsCompleted(s.quest) then have = have + 1 end
    end
    for _, list in ipairs({ bring, inside }) do
        for _, s in ipairs(list) do if Q:IsCompleted(s.quest) then finished = finished + 1 end end
    end
    local all = #bring + #inside
    local state
    if all > 0 and finished == all then
        state = "done"
    elseif level < minL - UPCOMING_LEVELS then
        state = "later"
    elseif level < minL then
        state = "upcoming"
    elseif level >= maxL and have > 0 then
        state = "late"
    elseif have == #bring then
        state = "ready"
    else
        state = "gathering"
    end
    return { state = state, have = have, total = #bring, bring = bring, inside = inside, minLevel = minL, maxLevel = maxL }
end

--- One line per quest for the panel: where it stands for this character.
function Dungeons:QuestLines(g)
    local Q = ns.Quest
    local st = self:Status(g)
    local level = ns.Player:GetLevel() or 1
    local lines = {}
    local function describe(step, given)
        local name = step.questName or Q:GetTitle(step.quest) or ("quest " .. step.quest)
        local where
        if Q:IsCompleted(step.quest) then
            where = "done"
        elseif Q:IsOnQuest(step.quest) then
            where = "in your log"
        else
            local q = ns.DB and ns.DB:GetQuest(step.quest)
            if q and q.req and level < q.req then
                where = "needs level " .. q.req
            elseif given then
                where = "given inside"
            else
                where = "pick up from " .. (step.npcName or "its giver") .. (step.zone and (", " .. step.zone) or "")
            end
        end
        lines[#lines + 1] = { quest = step.quest, name = name, where = where }
    end
    for _, s in ipairs(st.bring) do describe(s, false) end
    for _, s in ipairs(st.inside) do describe(s, true) end
    return lines, st
end

--- The entrance: the "Find a group" note's place, else the guide's own map.
function Dungeons:Entrance(g)
    for _, step in ipairs(g.steps or {}) do
        if step.type == "NOTE" and (step.text or ""):find("^Find a group") and step.map and step.x and step.y then
            return { map = step.map, x = step.x, y = step.y, zone = step.zone }
        end
    end
    return nil
end
