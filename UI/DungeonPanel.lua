-- ============================================================
-- ForeverGuide / UI/DungeonPanel.lua
-- The dungeon badge's panel: the dungeon's levels, each of its quests and
-- where it stands, and buttons to point at the entrance, open the dungeon's
-- guide, or go back to the chapter.
-- ============================================================

local _, ns = ...
local Theme = ns.Theme
local Dungeons = ns.Dungeons

local panel

local function Create()
    if panel then return panel end
    local ok, p = pcall(CreateFrame, "Frame", "ForeverGuideDungeonPanel", UIParent, "BackdropTemplate")
    if not ok or not p then p = CreateFrame("Frame", "ForeverGuideDungeonPanel", UIParent) end
    panel = p
    p:SetSize(360, 220)
    p:SetFrameStrata("DIALOG")
    p:EnableMouse(true)
    p:SetMovable(true)
    p:SetClampedToScreen(true)
    p:RegisterForDrag("LeftButton")
    p:SetScript("OnDragStart", function(self) self:StartMoving() end)
    p:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    Theme.Backdrop(p, "panel", 0.75)
    p.title = Theme.NewText(p, { fancy = true, size = 15, color = Theme.C.goldLight, maxLines = 2 })
    p.title:SetPoint("TOPLEFT", p, "TOPLEFT", 14, -12)
    p.title:SetPoint("TOPRIGHT", p, "TOPRIGHT", -44, -12)
    p.body = Theme.NewText(p, { size = 11, color = Theme.C.text, maxLines = 20 })
    p.body:SetPoint("TOPLEFT", p.title, "BOTTOMLEFT", 0, -8)
    p.body:SetPoint("TOPRIGHT", p, "TOPRIGHT", -14, 0)
    p.waypoint = Theme.NewButton(p, "Waypoint", 84, 22, function()
        local at = p.guide and Dungeons:Entrance(p.guide)
        if at then ns.Navigation:SetTarget({ map = at.map, x = at.x, y = at.y, label = Dungeons:Name(p.guide) .. " entrance", owner = "dungeon", radius = 30 }) end
    end)
    p.open = Theme.NewButton(p, "Open guide", 96, 22, function()
        if p.guide then ns.Guide:Activate(p.guide.id) end
        Dungeons:RefreshPanel()
    end)
    p.back = Theme.NewButton(p, "Back to chapter", 120, 22, function()
        ns.Guide:Resume()
        Dungeons:RefreshPanel()
    end)
    p.close = Theme.NewButton(p, "x", 26, 20, function() panel:Hide() end)
    p.waypoint:SetPoint("BOTTOMLEFT", p, "BOTTOMLEFT", 12, 10)
    p.open:SetPoint("LEFT", p.waypoint, "RIGHT", 6, 0)
    p.back:SetPoint("LEFT", p.open, "RIGHT", 6, 0)
    p.close:SetPoint("TOPRIGHT", p, "TOPRIGHT", -8, -8)
    p:Hide()
    return p
end

function Dungeons:RefreshPanel()
    if not panel or not panel:IsShown() or not panel.guide then return end
    local g = panel.guide
    local lines, st = self:QuestLines(g)
    panel.title:SetText(string.format("%s  %d-%d", self:Name(g), st.minLevel, st.maxLevel))
    local out = {
        string.format("|cffdeb24aAll quests available from level %d; hand them in by level %d for full XP.|r", st.minLevel, st.maxLevel),
        " ",
    }
    for _, l in ipairs(lines) do
        local color = (l.where == "in your log" or l.where == "done") and "|cff7fd67f" or "|cffa89e8e"
        out[#out + 1] = string.format("%s  %s-  %s|r", l.name, color, l.where)
    end
    local at = self:Entrance(g)
    if at then
        out[#out + 1] = " "
        out[#out + 1] = string.format("|cffa89e8eEntrance: %s %.1f, %.1f|r", at.zone or "", at.x, at.y)
    end
    panel.body:SetText(table.concat(out, "\n"))
    local titleH = panel.title.GetStringHeight and panel.title:GetStringHeight() or 18
    local bodyH = panel.body.GetStringHeight and panel.body:GetStringHeight() or 120
    panel:SetHeight(math.max(160, 12 + titleH + 8 + bodyH + 16 + 22 + 12))
    local active = ns.Guide.active
    panel.open:SetShown(active ~= g)
    panel.back:SetShown(active == g)
end

--- Show the panel for a dungeon guide (the badge's, when none is given).
function Dungeons:ShowPanel(g)
    g = g or self:Next()
    local p = Create()
    if not g then p:Hide() return p end
    p.guide = g
    p:ClearAllPoints()
    local qg = ns.QuestGuide and ns.QuestGuide.frame
    if qg then p:SetPoint("TOPRIGHT", qg, "TOPLEFT", -12, 0) else p:SetPoint("CENTER") end
    p:Show()
    self:RefreshPanel()
    return p
end

function Dungeons:TogglePanel(g)
    if panel and panel:IsShown() then panel:Hide() return end
    self:ShowPanel(g)
end

function Dungeons:OnInit()
    ns.Events:RegisterMany({ "FG_GUIDE_CHANGED", "FG_QUEST_LOG_CHANGED", "FG_STEP_CHANGED" },
        function() if panel and panel:IsShown() then ns.Events:Debounce("dungeonpanel", 0.1, function() Dungeons:RefreshPanel() end) end end)
end
