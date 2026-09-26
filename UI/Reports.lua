-- Feedback entry and copyable report export. Reports themselves live in ForeverGuideDB.
local _, ns = ...
local Reports = {}
ns.Reports = Reports
local Theme = ns.Theme

local function Window(name, width, height, title)
    local ok, f = pcall(CreateFrame, "Frame", name, UIParent, "BackdropTemplate")
    if not ok or not f then f = CreateFrame("Frame", name, UIParent) end
    f:SetSize(width, height)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    Theme.Backdrop(f, "panel", 0.75)
    local heading = Theme.NewText(f, { size = 15, oneLine = true })
    heading:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -14)
    heading:SetText(title)
    local close = Theme.NewButton(f, "x", 26, 22, function() f:Hide() end)
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -8)
    f:Hide()
    return f
end

local prompt, list
function Reports:Prompt()
    if not prompt then
        local f = Window("ForeverGuideReportPrompt", 420, 170, "Report a wrong step")
        local hint = Theme.NewText(f, { size = 11, color = Theme.C.textDim, maxLines = 2 })
        hint:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -42)
        hint:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -42)
        hint:SetText("What is wrong? Stand at the correct location or target the correct NPC first.")
        local input = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
        input:SetSize(376, 26)
        input:SetPoint("TOPLEFT", f, "TOPLEFT", 22, -90)
        input:SetAutoFocus(false)
        input:SetMaxLetters(500)
        input:SetScript("OnEscapePressed", function(self) self:ClearFocus() f:Hide() end)
        f.input = input
        local save = Theme.NewButton(f, "Save report", 110, 24, function()
            local text = ns.Trim(input:GetText() or "")
            if text == "" then ns.Warn("describe what is wrong before saving.") return end
            ns.Commands:Run("wrong " .. text)
            input:ClearFocus()
            f:Hide()
        end)
        save:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -14, 12)
        f.save = save
        input:SetScript("OnEnterPressed", function() save:GetScript("OnClick")() end)
        prompt = f
    end
    prompt.input:SetText("")
    prompt:Show()
    prompt.input:SetFocus()
end

-- Snapshot the selected log quest now; the player may move or abandon it later.
function Reports:MissingQuest(questID)
    local quest = ns.Quest:GetEntry(questID)
    if not quest then return end
    local map, x, y = ns.Player:GetMapPosition()
    local zone, sub = ns.Player:GetZone()
    local npc = ns.Player:GetUnitInfo("target")
    local guide = ns.Guide.active
    local r = {
        t = ns.Now(), type = "MISSING_ROUTE_QUEST", q = quest.questID,
        title = quest.title, questLevel = quest.level, ready = quest.ready, failed = quest.isFailed,
        m = map, x = x, y = y, zone = zone, sub = sub, lvl = ns.Player:GetLevel(),
        guide = guide and guide.id, step = guide and ns.Guide.current, objectives = {},
    }
    if npc and npc.npcID then r.npc, r.npcName = npc.npcID, npc.name end
    for _, obj in ipairs(quest.objectives) do
        r.objectives[#r.objectives + 1] = {
            text = obj.text, numFulfilled = obj.numFulfilled,
            numRequired = obj.numRequired, finished = obj.finished,
        }
    end
    ns.db.reports = ns.db.reports or {}
    table.insert(ns.db.reports, r)
    while #ns.db.reports > 300 do table.remove(ns.db.reports, 1) end
    ns.Printf("missing route quest reported: %s (%d). Copy it with /fg reports.", quest.title, questID)
end

local function Export(reports)
    local lines = {}
    for i, r in ipairs(reports) do
        local where = r.loc and string.format("map %s %.1f,%.1f%s", tostring(r.loc.m or "?"), r.loc.x or 0, r.loc.y or 0,
            r.loc.id and (" " .. (r.loc.kind or "target") .. " " .. tostring(r.loc.id)) or "") or "?"
        local actual = string.format("map %s %.1f,%.1f (%s%s)", tostring(r.m or "?"), r.x or 0, r.y or 0,
            r.zone or "?", r.sub and r.sub ~= "" and " / " .. r.sub or "")
        lines[#lines + 1] = string.format("%d. time %s | %s%s | quest %s | %s | expected %s | actual %s | level %s%s | %s",
            i, tostring(r.t or "?"), r.guide and (r.guide .. " step " .. tostring(r.step or "?")) or (r.mode or "unknown mode"),
            r.type and (" " .. r.type) or (r.what and " " .. r.what or ""), tostring(r.q or "?"),
            r.text or r.title or "(no description)", r.type == "MISSING_ROUTE_QUEST" and "not in route" or where, actual, tostring(r.lvl or "?"),
            r.npc and (" | target NPC " .. tostring(r.npc) .. " " .. (r.npcName or "")) or "",
            r.npcStep and ("expected NPC " .. tostring(r.npcStep)) or "")
        if r.type == "MISSING_ROUTE_QUEST" then
            lines[#lines + 1] = string.format("  Quest level %s | %s", tostring(r.questLevel or "?"),
                r.failed and "failed" or (r.ready and "ready to turn in" or "in progress"))
            for _, obj in ipairs(r.objectives or {}) do
                lines[#lines + 1] = string.format("  Objective: %s (%s/%s)%s", obj.text or "?",
                    tostring(obj.numFulfilled or 0), tostring(obj.numRequired or 0), obj.finished and " done" or "")
            end
        end
    end
    return table.concat(lines, "\n")
end
Reports.Export = Export

-- A window with a scrolling, selectable text box (the only way to copy text out of the game).
local function CopyWindow(name, title)
    local f = Window(name, 660, 400, title)
    local scroll = CreateFrame("ScrollFrame", nil, f)
    scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -44)
    scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -16, 14)
    pcall(scroll.SetClipsChildren, scroll, true)
    scroll:EnableMouseWheel(true)
    local text = CreateFrame("EditBox", nil, scroll)
    text:SetMultiLine(true)
    text:SetAutoFocus(false)
    text:SetFont(Theme.FONT, 12, "")
    text:SetTextColor(1, 1, 1)
    text:SetWidth(620)
    text:SetScript("OnEscapePressed", function() f:Hide() end)
    text:SetScript("OnTextChanged", function(self)
        local ok, height = pcall(self.GetStringHeight, self)
        self:SetHeight(math.max(330, (ok and height or 0) + 20))
    end)
    text:SetHeight(330)
    scroll:SetScrollChild(text)
    local selectAll = Theme.NewButton(f, "Select all", 86, 22, function() text:SetFocus() text:HighlightText() end)
    selectAll:SetPoint("TOPRIGHT", f, "TOPRIGHT", -42, -8)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        self:SetVerticalScroll(math.max(0, math.min(self:GetVerticalScrollRange(), self:GetVerticalScroll() - delta * 60)))
    end)
    f.text, f.scroll, f.selectAll = text, scroll, selectAll
    return f
end

function Reports:ShowList()
    if not list then
        local f = CopyWindow("ForeverGuideReports", "Reports (select text and copy)")
        local clear = Theme.NewButton(f, "Clear all", 92, 22, function()
            if not f.confirmClear then
                f.confirmClear = true
                f.clear.label:SetText("Confirm clear")
                return
            end
            ns.Commands:Run("reports clear")
            f.confirmClear = false
            f.clear.label:SetText("Clear all")
            Reports:ShowList()
        end)
        clear:SetPoint("RIGHT", f.selectAll, "LEFT", -8, 0)
        f.clear = clear
        f:SetScript("OnHide", function() f.confirmClear = false clear.label:SetText("Clear all") end)
        list = f
    end
    local reports = ns.db.reports or {}
    list.text:SetText(#reports > 0 and Export(reports) or "No reports yet. Use /fg wrong to add one.")
    list.scroll:SetVerticalScroll(0)
    list:Show()
end

--- Show text in a copy window, already selected so Ctrl+C copies it. One window per name.
local copyWindows = {}
function Reports:ShowText(name, title, text)
    local f = copyWindows[name]
    if not f then
        f = CopyWindow(name, title)
        copyWindows[name] = f
    end
    f.text:SetText(text or "")
    f.scroll:SetVerticalScroll(0)
    f:Show()
    f.text:SetFocus()
    f.text:HighlightText()
    return f
end
