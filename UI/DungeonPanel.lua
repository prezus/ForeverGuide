-- ============================================================
-- ForeverGuide / UI/DungeonPanel.lua
-- The Dungeon Quests panel under the guide window: the dungeons this
-- character can do, and for the one picked, each of its quests and where it
-- stands, with a Waypoint to the entrance. Looking never changes the guide:
-- the chapter stays on the step it was on.
-- ============================================================

local _, ns = ...
local Theme = ns.Theme
local Dungeons = ns.Dungeons

local drawer

local STATE_FOR = { done = "done", ready = "available", late = "available", gathering = "available",
                    upcoming = "future", later = "future" }

local function Create()
    if drawer then return drawer end
    local f = ns.QuestGuide.frame or ns.QuestGuide:Create()
    local d = ns.QuestGuide:NewDrawer(f, "DUNGEON QUESTS")
    drawer = d
    f.dungeons = d
    d.back = Theme.NewButton(d, "Back", 52, 20, function() Dungeons:ShowDungeon(nil) end)
    d.waypoint = Theme.NewButton(d, "Waypoint", 78, 20, function()
        local at = d.guide and Dungeons:Entrance(d.guide)
        if at then ns.Navigation:SetTarget({ map = at.map, x = at.x, y = at.y, label = Dungeons:Name(d.guide) .. " entrance", owner = "dungeon", radius = 30 }) end
    end)
    d.back:SetPoint("TOPRIGHT", d, "TOPRIGHT", -8, -7)
    d.waypoint:SetPoint("RIGHT", d.back, "LEFT", -4, 0)
    d.title:SetPoint("RIGHT", d.waypoint, "LEFT", -6, 0)
    d.note = Theme.NewText(d, { size = 10, color = Theme.C.textDim, maxLines = 2 })
    d.note:SetPoint("TOPLEFT", d, "TOPLEFT", 14, -30)
    d.note:SetPoint("TOPRIGHT", d, "TOPRIGHT", -14, -30)
    return d
end

--- The list of dungeons: level range, quests carried, and where the character stands.
local function DungeonEntries()
    local entries = {}
    for _, g in ipairs(ns.Guide:Dungeons()) do
        local st = Dungeons:Status(g)
        local what
        if st.state == "done" then what = "done"
        elseif st.state == "ready" then what = "ready"
        elseif st.state == "late" then what = "hand in by " .. st.maxLevel
        elseif st.state == "later" or st.state == "upcoming" then what = "from level " .. st.minLevel
        end
        local sub = string.format("%d-%d  ·  %d/%d quests%s", st.minLevel, st.maxLevel, st.have, st.total, what and ("  ·  " .. what) or "")
        entries[#entries + 1] = {
            guideID = g.id, icon = "kill", state = STATE_FOR[st.state] or "future",
            title = Dungeons:Name(g), subtitle = sub,
            tooltip = { "|cff8a8070Left click: its quests and where they stand.|r" },
            onClick = function() Dungeons:ShowDungeon(g) end,
        }
    end
    return entries
end

--- One row per quest of the picked dungeon; a quest in the log opens there on a click.
local function QuestEntries(g)
    local lines, st = Dungeons:QuestLines(g)
    local entries = {}
    for _, l in ipairs(lines) do
        local inLog = l.where == "in your log"
        entries[#entries + 1] = {
            questID = l.quest, icon = inLog and "turnin" or "accept",
            state = l.where == "done" and "done" or (inLog and "available" or "future"),
            title = l.name, subtitle = l.where,
            tooltip = inLog and { "|cff8a8070Left click: open in the quest log.|r" } or nil,
            onClick = inLog and function() ns.Quest:OpenInLog(l.quest) end or nil,
        }
    end
    return entries, st
end

function Dungeons:RefreshPanel()
    if not drawer or not drawer:IsShown() then return end
    local d, g = drawer, drawer.guide
    if g then
        local entries, st = QuestEntries(g)
        d.title:SetText(string.format("%s  %d-%d", self:Name(g), st.minLevel, st.maxLevel))
        local at = self:Entrance(g)
        d.note:SetText(string.format("Quests from level %d; hand them in by %d for full XP.%s", st.minLevel, st.maxLevel,
            at and string.format("  Entrance: %s %.1f, %.1f", at.zone or "", at.x, at.y) or ""))
        d.note:Show()
        d.back:Show()
        d.waypoint:SetShown(at ~= nil)
        d.top = 58
        d.list:Set(entries, "No quests for this dungeon.")
    else
        d.title:SetText("DUNGEON QUESTS")
        d.note:Hide()
        d.back:Hide()
        d.waypoint:Hide()
        d.top = 32
        d.list:Set(DungeonEntries(), "No dungeon guides for your character.")
    end
    d.scroll:ClearAllPoints()
    d.scroll:SetPoint("TOPLEFT", d, "TOPLEFT", 6, -d.top)
    d.scroll:SetPoint("BOTTOMRIGHT", d, "BOTTOMRIGHT", -6, 6)
    d.scroll:SetVerticalScroll(0)
    d:Fit()
end

--- Show one dungeon's quests in the panel (nil: back to the list of dungeons).
function Dungeons:ShowDungeon(g)
    Create().guide = g
    self:RefreshPanel()
end

--- The guide window opens and closes the panel (one panel under it at a time).
function Dungeons:SetDrawerShown(on)
    if not on and not drawer then return end
    local d = Create()
    d:SetShown(on)
    if not on then d.guide = nil end
    self:RefreshPanel()
end

--- Open the panel on a dungeon (the badge's, when none is given).
function Dungeons:ShowPanel(g)
    local d = Create()
    d.guide = g or self:Next()
    ns.QuestGuide:SetDrawer("dungeons")
    return d
end

function Dungeons:TogglePanel(g)
    if drawer and drawer:IsShown() then ns.QuestGuide:SetDrawer(nil) return end
    self:ShowPanel(g)
end

function Dungeons:OnInit()
    ns.Events:RegisterMany({ "FG_GUIDE_CHANGED", "FG_QUEST_LOG_CHANGED", "FG_STEP_CHANGED", "FG_LEVEL_CHANGED" },
        function() if drawer and drawer:IsShown() then ns.Events:Debounce("dungeonpanel", 0.1, function() Dungeons:RefreshPanel() end) end end)
end
