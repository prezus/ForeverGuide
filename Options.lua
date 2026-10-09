-- ============================================================
-- ForeverGuide / Options.lua
-- Options panel (Esc -> Options -> AddOns -> ForeverGuide, or /fg options).
-- Checkboxes plus a couple of sliders (numeric settings like arrow size) on
-- a canvas category; everything here also has a slash command, the panel
-- just makes it discoverable.
-- ============================================================

local _, ns = ...
local Options = ns:NewModule("Options")

local panel, category, keyCategory
local widgets = {}

local function Bool(v) return v and true or false end

-- ---- the settings this panel edits: get/set pairs ---------------------------------
local ITEMS = {
    { key = "window", label = "Show the guide window",
      get = function() return Bool(ns.db.ui.shown) end,
      set = function(v) if v then ns.UI:Show() else ns.UI:Hide() end end },
    { key = "arrow", label = "Show the compact chevron arrow above your head (the everyday indicator)",
      get = function() return Bool(ns.db.ui.arrow and ns.db.ui.arrow.enabled ~= false) end,
      set = function(v) ns.Arrow:SetEnabled(v) end },
    { key = "arrowsize", type = "slider", label = "Arrow size", min = 0.5, max = 2.5, step = 0.1,
      get = function() return ns.Arrow and ns.Arrow:GetScale() or (ns.db.ui.arrow and ns.db.ui.arrow.scale) or 1 end,
      set = function(v) if ns.QuestGuideConfig then ns.QuestGuideConfig.SetNumber("arrowsize", v) elseif ns.Arrow then ns.Arrow:SetScale(v) end end },
    { key = "minimap", label = "Show the minimap button",
      get = function() return Bool(ns.db.minimap == nil or ns.db.minimap.shown ~= false) end,
      set = function(v) ns.Minimap:SetShown(v) end },
    { key = "lock", label = "Lock the window and the arrow (no dragging)",
      get = function() return Bool(ns.db.ui.locked) end,
      set = function(v) ns.db.ui.locked = v ns.Events:Fire("FG_LOCK_CHANGED", v) end },
    { key = "hideall", label = "Hide everything (window + arrow) - the guide keeps running",
      get = function() return Bool(ns.db.ui.hiddenAll) end,
      set = function(v) ns.UI:SetAllHidden(v) end,
      refresh = { "window", "arrow" } },
    { key = "combat", label = "Hide the window and arrow while in combat",
      get = function() return Bool(ns.db.ui.hideInCombat) end,
      set = function(v) ns.db.ui.hideInCombat = v end },
    { key = "bliz", label = "Also use Blizzard's own map pin / super-track arrow",
      get = function() return Bool(ns.db.nav.blizzardWaypoint) end,
      set = function(v) ns.Navigation:SetBlizzardWaypointEnabled(v) end },
    { header = "XP buff reminders" },
    { key = "xpfood", label = "Show an icon while the +5% XP food buff (Well Fed XP Boost) is missing",
      get = function() return Bool(ns.XPBuffs.Cfg().food.enabled) end,
      set = function(v) ns.XPBuffs.Cfg().food.enabled = v ns.XPBuffs:Refresh() end },
    { key = "xpbag", label = "Show an icon while the sleeping bag's Well-Rested is below 3 stacks (+3% XP)",
      get = function() return Bool(ns.XPBuffs.Cfg().bag.enabled) end,
      set = function(v) ns.XPBuffs.Cfg().bag.enabled = v ns.XPBuffs:Refresh() end },
    { header = "Quests" },
    { key = "acceptAll", label = "Auto-accept every quest an NPC offers",
      get = function() return ns.AutoQuest.Cfg().accept == "on" end,
      set = function(v) ns.AutoQuest:Set("accept", v and "on" or "guide") end,
      refresh = { "acceptGuide" } },
    { key = "acceptGuide", label = "Auto-accept only quests of the active guide",
      get = function() return ns.AutoQuest.Cfg().accept == "guide" end,
      set = function(v) ns.AutoQuest:Set("accept", v and "guide" or "off") end,
      refresh = { "acceptAll" } },
    { key = "turnin", label = "Auto-turn-in finished quests (a reward choice is left to you)",
      get = function() return Bool(ns.AutoQuest.Cfg().turnin) end,
      set = function(v) ns.AutoQuest:Set("turnin", v and "on" or "off") end },
    { key = "share", label = "Share quests you accept with your group",
      get = function() return Bool(ns.AutoQuest.Cfg().share) end,
      set = function(v) ns.AutoQuest:Set("share", v and "on" or "off") end },
    { key = "shared", label = "Auto-accept quests your group shares, and join its escorts",
      get = function() return Bool(ns.AutoQuest.Cfg().shared) end,
      set = function(v) ns.AutoQuest:Set("shared", v and "on" or "off") end },
    { key = "announce", label = "Announce auto-accepted / turned-in quests in chat",
      get = function() return Bool(ns.AutoQuest.Cfg().announce) end,
      set = function(v) ns.AutoQuest.Cfg().announce = v end },
    { key = "autopick", label = "Pick a fitting guide automatically when none is active",
      get = function() return Bool(ns.char.autoPickGuide) end,
      set = function(v) ns.char.autoPickGuide = v end },
    { header = "Data collection (all off until you opt in)" },
    { key = "contribute", label = "Contribute data: quest givers, turn-ins, objective spots, addon errors (no names or times); /fg share",
      get = function() return Bool(ns.db.contribute) end,
      set = function(v) ns.Recorder:SetEnabled(v) end },
    { key = "runs", label = "Record runs: Start, Pause, Stop and Send on the guide window; a timed log of your play (no names or clock time)",
      get = function() return Bool(ns.db.recordRuns) end,
      set = function(v) ns.Run:SetEnabled(v) end },
    { key = "scanner", label = "Scanner: collect quest IDs; allow /fg scan to query the server",
      get = function() return Bool(ns.db.scanEnabled) end,
      set = function(v) ns.Scanner:SetEnabled(v) end },
}

-- ---- widgets --------------------------------------------------------------------------
local function MakeCheck(parent, item, y)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, y)
    local label = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    label:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    label:SetText(item.label)
    cb.label = label
    cb:SetScript("OnClick", function(self)
        local ok, err = pcall(item.set, self:GetChecked() and true or false)
        if not ok then ns.ReportOnce("options:" .. item.key, err) end
        Options:Refresh()
    end)
    return cb
end

--- A plain base "Slider" widget (not a named FrameXML template - those are unconfirmed on
--- Forever's client, see docs/history/PHASE1_NOTES.md) with hand-drawn track/thumb textures, so it
--- needs nothing beyond the core widget API every WoW client has always shipped.
local function MakeSlider(parent, item, y)
    local label = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    label:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, y)
    label:SetText(item.label)

    local slider = CreateFrame("Slider", nil, parent)
    slider:SetOrientation("HORIZONTAL")
    slider:SetSize(200, 16)
    slider:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, y - 20)
    pcall(slider.SetHitRectInsets, slider, 0, 0, -6, -6)
    slider:SetMinMaxValues(item.min, item.max)
    slider:SetValueStep(item.step or 0.1)
    pcall(slider.SetObeyStepOnDrag, slider, true)

    local track = slider:CreateTexture(nil, "BACKGROUND")
    track:SetColorTexture(0, 0, 0, 0.6)
    track:SetPoint("LEFT", slider, "LEFT", 0, 0)
    track:SetPoint("RIGHT", slider, "RIGHT", 0, 0)
    track:SetHeight(4)

    local thumb = slider:CreateTexture(nil, "OVERLAY")
    thumb:SetColorTexture(0.9, 0.75, 0.2, 1)
    thumb:SetSize(10, 18)
    slider:SetThumbTexture(thumb)

    local valueText = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    valueText:SetPoint("LEFT", slider, "RIGHT", 10, 0)

    slider:SetScript("OnValueChanged", function(self, value)
        value = tonumber(string.format("%.1f", value)) or value
        valueText:SetText(string.format("%.1f", value))
        if self.suppress then return end
        local ok, err = pcall(item.set, value)
        if not ok then ns.ReportOnce("options:" .. item.key, err) end
    end)

    return slider, valueText
end

local function MakeButton(parent, text, x, y, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(150, 22)
    b:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    b:SetText(text)
    b:SetScript("OnClick", function()
        local ok, err = pcall(onClick)
        if not ok then ns.ReportOnce("options:button", err) end
    end)
    return b
end

--- A game key binding: the key it has, and a button to ForeverGuide > Key Bindings, where the game's
--- own binding rows set it (any key, mouse button, wheel or gamepad button, two keys, right-click to
--- clear). Without that page the note points at the game's Key Bindings instead.
local function MakeKeybind(parent, item, y)
    local label = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    label:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, y - 4)
    local note = parent:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    note:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, y - 24)
    note:SetWidth(540)
    note:SetJustifyH("LEFT")
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(150, 22)
    b:SetPoint("TOPLEFT", parent, "TOPLEFT", 336, y)
    b:SetText("Key bindings...")
    b:SetScript("OnClick", function()
        local ok, err = pcall(Options.OpenKeyBindings, Options)
        if not ok then ns.ReportOnce("options:" .. item.key, err) end
    end)
    b.label, b.note = label, note
    return b
end

function Options:Refresh()
    for _, w in pairs(widgets) do
        local item = w.item
        local ok, v = pcall(item.get)
        if w.kind == "keybind" then
            w.widget.label:SetText(item.label .. ": " .. ((ok and v) or "not bound"))
            w.widget:SetShown(keyCategory ~= nil)
            w.widget.note:SetText(keyCategory and "" or "Set it in Esc -> Options -> Key Bindings -> AddOns -> ForeverGuide.")
        elseif w.kind == "slider" then
            v = (ok and tonumber(v)) or item.min
            w.widget.suppress = true
            w.widget:SetValue(v)
            w.widget.suppress = false
            if w.valueText then w.valueText:SetText(string.format("%.1f", v)) end
        else
            w.widget:SetChecked(ok and v and true or false)
        end
    end
end

--- The settings canvas is only so tall and does not clip what we draw on it, so the checkboxes
--- go on a scrolling child: the list can grow without spilling over the game (Ilya, 2026-09-21).
local function MakeScroller(parent, topOffset)
    local ok, scroll = pcall(CreateFrame, "ScrollFrame", nil, parent)
    if not ok or not scroll then return parent, nil end
    scroll:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, topOffset)
    scroll:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -24, 8)
    pcall(scroll.SetClipsChildren, scroll, true)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(560, 10)
    pcall(scroll.SetScrollChild, scroll, content)
    pcall(scroll.EnableMouseWheel, scroll, true)
    -- the client's own range can lag the child's height, so take whichever is larger
    local function range(self)
        local child = self.GetScrollChild and self:GetScrollChild()
        local byChild = child and math.max(0, (child:GetHeight() or 0) - (self:GetHeight() or 0)) or 0
        local byApi = self.GetVerticalScrollRange and self:GetVerticalScrollRange() or 0
        return math.max(byApi or 0, byChild)
    end
    -- a scroll bar in the gap on the right: a plain Slider with drawn track and thumb, as MakeSlider
    local bar = CreateFrame("Slider", nil, parent)
    bar:SetOrientation("VERTICAL")
    bar:SetWidth(12)
    bar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -6, topOffset - 4)
    bar:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -6, 12)
    pcall(bar.SetHitRectInsets, bar, -4, -4, 0, 0)
    bar:SetValueStep(1)
    pcall(bar.SetObeyStepOnDrag, bar, true)
    local track = bar:CreateTexture(nil, "BACKGROUND")
    track:SetColorTexture(0, 0, 0, 0.6)
    track:SetPoint("TOP", bar, "TOP", 0, 0)
    track:SetPoint("BOTTOM", bar, "BOTTOM", 0, 0)
    track:SetWidth(4)
    local thumb = bar:CreateTexture(nil, "OVERLAY")
    thumb:SetColorTexture(0.9, 0.75, 0.2, 1)
    thumb:SetSize(10, 30)
    bar:SetThumbTexture(thumb)
    bar:SetScript("OnValueChanged", function(_, value)
        if bar.suppress then return end
        scroll:SetVerticalScroll(math.max(0, math.min(range(scroll), value or 0)))
    end)
    --- the bar follows the list: its range, where the list is, and hidden when nothing scrolls
    function scroll.UpdateBar()
        local r = range(scroll)
        bar.suppress = true
        bar:SetMinMaxValues(0, r)
        bar:SetValue(scroll.GetVerticalScroll and scroll:GetVerticalScroll() or 0)
        bar.suppress = false
        bar:SetShown(r > 0)
    end
    scroll.bar = bar
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local at = (self.GetVerticalScroll and self:GetVerticalScroll() or 0) - (delta or 0) * 60
        self:SetVerticalScroll(math.max(0, math.min(range(self), at)))
        self.UpdateBar()
    end)
    scroll:SetScript("OnSizeChanged", function(self, w)
        if w and w > 0 then content:SetWidth(w) end
        self.UpdateBar()
    end)
    return content, scroll
end

--- ForeverGuide > Key Bindings: a vertical list of the game's own binding rows (Blizzard_Keybindings.lua's
--- CreateKeybindingEntryInitializer, the row Controls uses for the Interact Key), one per entry of
--- Bindings.xml. The settings panel takes the key, mouse button, wheel or gamepad button, settles a key
--- another action had, and saves when it closes. Left out on a client without those calls.
local function RegisterKeyBindings(S, parent)
    local entry, index = rawget(_G, "CreateKeybindingEntryInitializer"), rawget(_G, "C_KeyBindings")
    index = index and index.GetBindingIndex
    if not (S.RegisterVerticalLayoutSubcategory and entry and index) then return end
    local sub, layout = S.RegisterVerticalLayoutSubcategory(parent, "Key Bindings")
    if not (sub and layout) then return end
    for _, action in ipairs(ns.BINDINGS) do
        local i = index(action)
        if i then
            local row = entry(i, true)
            row:AddSearchTags(GetBindingName(action))
            layout:AddInitializer(row)
        end
    end
    keyCategory = sub
end

--- Open ForeverGuide > Key Bindings (the Key bindings... button is hidden on a client without it).
function Options:OpenKeyBindings()
    self:Create()
    local S = rawget(_G, "Settings")
    if keyCategory and S and S.OpenToCategory then S.OpenToCategory(keyCategory:GetID()) end
end

function Options:Create()
    if panel then return panel end
    panel = CreateFrame("Frame", "ForeverGuideOptionsPanel")
    panel.name = "ForeverGuide"
    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("ForeverGuide")
    local sub = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    sub:SetWidth(600)
    sub:SetJustifyH("LEFT")
    sub:SetText("Free leveling guide engine for WoW Forever. Everything here is also available as /fg commands (/fg help).")
    local more = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    more:SetPoint("TOPLEFT", sub, "BOTTOMLEFT", 0, -2)
    more:SetText("Scroll for the rest of the settings. Data collection is off until you opt in.")

    local body, scroll = MakeScroller(panel, -80)
    panel.body, panel.scroll = body, scroll
    local y = body == panel and -80 or -4
    -- the Quest Guide / waypoint toggles live with their settings module
    local items = {}
    for _, it in ipairs(ITEMS) do items[#items + 1] = it end
    if ns.QuestGuideConfig then for _, it in ipairs(ns.QuestGuideConfig.OptionItems()) do items[#items + 1] = it end end
    for _, item in ipairs(items) do
        if item.header then
            local h = body:CreateFontString(nil, "ARTWORK", "GameFontNormal")
            h:SetPoint("TOPLEFT", 16, y - 6)
            h:SetText(item.header)
            y = y - 26
        elseif item.type == "keybind" then
            local b = MakeKeybind(body, item, y)
            widgets[item.key] = { widget = b, item = item, kind = "keybind" }
            y = y - 44
        elseif item.type == "slider" then
            local slider, valueText = MakeSlider(body, item, y)
            widgets[item.key] = { widget = slider, item = item, kind = "slider", valueText = valueText }
            y = y - 46
        else
            local cb = MakeCheck(body, item, y)
            widgets[item.key] = { widget = cb, item = item, kind = "check" }
            y = y - 26
        end
    end
    y = y - 10
    MakeButton(body, "Reset positions", 16, y, function() ns.UI:ResetPosition() ns.Arrow:ResetPosition() end)
    MakeButton(body, "Pick a guide", 176, y, function() ns.UI:TogglePicker() end)
    MakeButton(body, "Show reports", 336, y, function() ns.Commands:Run("reports") end)
    y = y - 34
    MakeButton(body, "Report wrong step", 16, y, function() ns.Commands:Run("wrong") end)
    y = y - 34
    local hint = body:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 16, y)
    hint:SetWidth(560)
    hint:SetJustifyH("LEFT")
    hint:SetText("Data collection switches stop future capture when off; /fg share clear erases collected facts, /fg share copies them.\nSomething wrong? Stand where it should be, then use Report wrong step or /fg wrong. /fg reports opens a copyable list for review.\nLook: /fg qg scale|opacity|width|rows|wpsize|arrowsize <value>   (e.g. /fg qg opacity 0.8, or /fg arrow size 1.5)\nKey bindings: ForeverGuide > Key Bindings in this list, or Esc -> Options -> Key Bindings -> AddOns -> ForeverGuide.")

    -- the scrolling child is exactly as tall as what we put on it
    if body ~= panel then
        body:SetHeight(math.abs(y) + 70)
        panel.contentHeight = body:GetHeight()
    end

    panel:SetScript("OnShow", function()
        Options:Refresh()
        if panel.scroll and panel.scroll.SetVerticalScroll then pcall(panel.scroll.SetVerticalScroll, panel.scroll, 0) end
        if panel.scroll and panel.scroll.UpdateBar then panel.scroll.UpdateBar() end
    end)

    -- register with whichever settings API this client has
    local S = rawget(_G, "Settings")
    if S and S.RegisterCanvasLayoutCategory and S.RegisterAddOnCategory then
        local ok, cat = pcall(S.RegisterCanvasLayoutCategory, panel, panel.name)
        if ok and cat then
            category = cat
            local subOk, err = pcall(RegisterKeyBindings, S, cat)
            if not subOk then ns.ReportOnce("options:keybindings", err) end
            pcall(S.RegisterAddOnCategory, cat)
        end
    elseif rawget(_G, "InterfaceOptions_AddCategory") then
        pcall(InterfaceOptions_AddCategory, panel)
    end
    return panel
end

function Options:Open()
    self:Create()
    local S = rawget(_G, "Settings")
    if category and S and S.OpenToCategory then
        pcall(S.OpenToCategory, category:GetID())
    elseif rawget(_G, "InterfaceOptionsFrame_OpenToCategory") then
        pcall(InterfaceOptionsFrame_OpenToCategory, panel)
        pcall(InterfaceOptionsFrame_OpenToCategory, panel)
    else
        ns.Print("options panel could not be opened on this client; use /fg commands.")
    end
end

function Options:OnEnable()
    self:Create()
end

--- The widget for one option's key (mainly for tests to drive - e.g. dragging the arrow-size
--- slider the way a player would - without duplicating the ITEMS table).
function Options:GetWidget(key)
    return widgets[key] and widgets[key].widget
end
