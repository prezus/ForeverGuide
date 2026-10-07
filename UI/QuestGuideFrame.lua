-- ============================================================
-- ForeverGuide / UI/QuestGuideFrame.lua
-- The Quest Guide window: plain panel,
-- header, the step list, two buttons. Reads the guide engine / tracker,
-- never changes them. UI.lua (the coordinator) shows / hides it.
--
--   ┌──────────────────────────────┐
--   │ (◎) QUEST GUIDE       6 / 14 │
--   │ Elwynn Forest 1-11 · Lv 7    │
--   │ ───────────────────────────  │
--   │ (5) ✓ Renegade Quistian  312 │
--   │ (6) ◆ Hilary's Necklace   85 │  <- active: outline, glow, bar
--   │       Find Hilary's Necklace │
--   │ (7) ! A Little More Trouble  │
--   │ ...                          │
--   │ [ ◎ Guide ]     [ Guides → ] │
--   │ [Unknown Quests][Dungeon Qs] │  <- each opens its panel below
--   └──────────────────────────────┘
-- ============================================================

local _, ns = ...
local Theme = ns.Theme
local QG = ns:NewModule("QuestGuide")

local FOOTER = 70       -- two button rows
local BAR_ROOM = 14     -- right of the list: the scroll bar
local LIST_INSET = 6 + BAR_ROOM
local DRAWER_ROWS_HEIGHT = 180

local function inCombat()
    return ns.Plain(ns.Safe(rawget(_G, "InCombatLockdown"))) == true
end
local frame
local info      -- the Details popup (created on first use)

local ICON_FOR = { ACCEPT = "accept", TURNIN = "turnin", KILL = "kill", COLLECT = "collect", COMPLETE = "collect",
                   GRIND = "kill", TRAVEL = "travel", FLY = "travel", HEARTH = "travel", TALK = "accept", NOTE = "travel",
                   BUY = "collect", TRAIN = "accept" }

-- ---- building ----------------------------------------------------------------------
--- A panel that opens under the window (one at a time): a title and a scrolling list.
function QG:NewDrawer(f, title)
    local okD, d = pcall(CreateFrame, "Frame", nil, f, "BackdropTemplate")
    if not okD or not d then d = CreateFrame("Frame", nil, f) end
    d:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 0, -8)
    d:SetPoint("TOPRIGHT", f, "BOTTOMRIGHT", 0, -8)
    Theme.Backdrop(d, "panel", ns.db.ui.opacity or 0.75)
    d.title = Theme.NewText(d, { fancy = true, size = 13, color = Theme.C.goldLight, oneLine = true })
    d.title:SetPoint("TOPLEFT", d, "TOPLEFT", 14, -10)
    d.title:SetText(title)
    local scroll = CreateFrame("ScrollFrame", nil, d)
    scroll:SetPoint("TOPLEFT", d, "TOPLEFT", 6, -32)
    scroll:SetPoint("BOTTOMRIGHT", d, "BOTTOMRIGHT", -6, 6)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        self:SetVerticalScroll(math.max(0, math.min(self:GetVerticalScrollRange(), self:GetVerticalScroll() - delta * 40)))
    end)
    d.list = ns.QuestList.Create(scroll)
    d.list:SetSize(f:GetWidth() - 12, 40)
    d.list:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
    scroll:SetScrollChild(d.list)
    d.scroll = scroll
    d.top = 32
    d.Fit = function(self) self:SetHeight(self.top + math.min(self.list.height, DRAWER_ROWS_HEIGHT) + 6) end
    d:Hide()
    f.drawers = f.drawers or {}
    f.drawers[#f.drawers + 1] = d
    return d
end

function QG:Create()
    if frame then return frame end
    local cfg = ns.db.ui
    cfg.width = math.max(cfg.width or 300, 240)
    local ok, f = pcall(CreateFrame, "Frame", "ForeverGuideFrame", UIParent, "BackdropTemplate")
    if not ok or not f then f = CreateFrame("Frame", "ForeverGuideFrame", UIParent) end
    frame = f
    f:SetSize(cfg.width, 200)
    f:SetPoint(cfg.point or "TOPRIGHT", UIParent, cfg.point or "TOPRIGHT", cfg.x or -40, cfg.y or -200)
    f:SetFrameStrata("HIGH")            -- above the objective tracker, below dialogs
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    -- not in combat: the secure buttons over the window cannot follow it until combat ends
    f:SetScript("OnDragStart", function(self) if not ns.db.ui.locked and not inCombat() then self:StartMoving() end end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint(1)
        ns.db.ui.point, ns.db.ui.x, ns.db.ui.y = point or "TOPRIGHT", x or 0, y or 0
    end)
    Theme.Backdrop(f, "panel", cfg.opacity or 0.75)
    f:SetResizable(true)
    pcall(f.SetResizeBounds, f, 240, 150, 520, 800)
    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(20, 20)
    grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1)
    grip:SetFrameLevel(f:GetFrameLevel() + 3)
    local handle = grip:CreateTexture(nil, "ARTWORK")
    handle:SetAllPoints()
    handle:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetScript("OnMouseDown", function()
        if not ns.db.ui.locked and not inCombat() then f.resizing = true f:StartSizing("BOTTOMRIGHT") end
    end)
    grip:SetScript("OnMouseUp", function()
        if not f.resizing and inCombat() then return end     -- the grip did not start a resize
        f.resizing = false
        f:StopMovingOrSizing()
        ns.db.ui.width = math.floor(math.max(240, math.min(520, f:GetWidth())) + 0.5)
        ns.db.ui.height = math.floor(math.max(150, math.min(800, f:GetHeight())) + 0.5)
        local rowHeight = ns.db.ui.showSubtitles ~= false and ns.QuestRow.HEIGHT_TWO + 3 or ns.QuestRow.HEIGHT_ONE + 3
        ns.db.ui.maxRows = math.max(3, math.min(15,
            math.floor((ns.db.ui.height - ns.QuestGuideHeader.HEIGHT - FOOTER - 6) / rowHeight)))
        QG.scrolledTo = nil          -- keep the current step in view in the new size
        QG:Apply()
        QG:Refresh()
    end)
    grip:SetShown(not cfg.locked)
    f.resizeGrip = grip

    f.header = ns.QuestGuideHeader.Create(f)
    local scroll = CreateFrame("ScrollFrame", nil, f)
    scroll:SetPoint("TOPLEFT", f.header, "BOTTOMLEFT", 6, -2)
    scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -BAR_ROOM, FOOTER + 4)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local viewport = f:GetHeight() - ns.QuestGuideHeader.HEIGHT - 2 - 4 - FOOTER
        local range = math.max(self:GetVerticalScrollRange(), f.list.height - viewport, 0)
        self:SetVerticalScroll(math.max(0, math.min(range, self:GetVerticalScroll() - delta * 40)))
        QG:Scrolled()
    end)
    f.scroll = scroll
    f.list = ns.QuestList.Create(scroll)
    f.list:SetSize(cfg.width - LIST_INSET, 40)
    self:CreateScrollBar(f)
    f.list:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
    scroll:SetScrollChild(f.list)

    -- quests in the log that no guide covers, under the window while its button is on
    f.extra = self:NewDrawer(f, "UNKNOWN QUESTS")

    f.footerLine = f:CreateTexture(nil, "ARTWORK")
    f.footerLine:SetHeight(1)
    pcall(f.footerLine.SetTexture, f.footerLine, Theme.TEX.separator)
    f.footerLine:SetVertexColor(0.3, 0.3, 0.3, 1)
    f:SetScript("OnSizeChanged", function(self, width, height)
        if not self.resizing then return end
        self.list:SetWidth(width - LIST_INSET)
        for _, d in ipairs(self.drawers) do d.list:SetWidth(width - 12) end
        self.footerLine:ClearAllPoints()
        self.footerLine:SetPoint("TOPLEFT", self, "TOPLEFT", 12, -(height - FOOTER))
        self.footerLine:SetPoint("TOPRIGHT", self, "TOPRIGHT", -12, -(height - FOOTER))
    end)

    f.guideBtn = Theme.NewButton(f, "Details", 104, 24, function() QG:ToggleInfo() end, "compass")
    f.guidesBtn = Theme.NewButton(f, "Guides", 104, 24, function() ns.UI:TogglePicker() end, "current")
    f.guideBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 12, 39)
    f.guidesBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 39)
    -- the panels under the window
    f.unknownBtn = Theme.NewButton(f, "Unknown Quests", 104, 24, function() QG:ToggleDrawer("unknown") end)
    f.dungeonsBtn = Theme.NewButton(f, "Dungeon Quests", 104, 24, function() QG:ToggleDrawer("dungeons") end)
    f.unknownBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 12, 9)
    f.unknownBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOM", -3, 9)
    f.dungeonsBtn:SetPoint("BOTTOMLEFT", f, "BOTTOM", 3, 9)
    f.dungeonsBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 9)

    -- the skull button: a secure button whose click runs "/targetexact <mob>" for the current kill
    -- step (the one way an addon may change the target). It sits between Guide and Guides but is
    -- not the window's child: see PlaceSecureButtons.
    if ns.MobMarker and ns.MobMarker.TargetButton then
        local tb = ns.MobMarker:TargetButton()
        if tb then
            tb:SetSize(30, 24)
            local normal = tb:CreateTexture(nil, "BACKGROUND")
            normal:SetAllPoints()
            pcall(normal.SetTexture, normal, Theme.TEX.button)
            normal:SetVertexColor(0.18, 0.18, 0.18, 1)
            local hl = tb:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints()
            pcall(hl.SetTexture, hl, Theme.TEX.buttonHl)
            hl:SetVertexColor(0.35, 0.35, 0.35, 1)
            pcall(hl.SetBlendMode, hl, "ADD")
            pcall(hl.SetAlpha, hl, 0.35)
            local skull = tb:CreateTexture(nil, "ARTWORK")
            skull:SetSize(20, 20)
            skull:SetPoint("CENTER")
            pcall(skull.SetTexture, skull, Theme.TEX.skullBtn)
            tb:SetScript("OnEnter", function(self)
                local tt = rawget(_G, "GameTooltip")
                if not tt then return end
                tt:SetOwner(self, "ANCHOR_TOP")
                tt:AddLine("Target the nearest quest mob", 1, 0.88, 0.55)
                local key = ns.MobMarker:TargetKey()
                tt:AddLine(key and ("Key: " .. key) or "Bind a key: Key Bindings > AddOns > ForeverGuide", 0.85, 0.82, 0.75, true)
                tt:AddLine("Press again if the first one is taken.", 0.66, 0.61, 0.52, true)
                tt:Show()
            end)
            tb:SetScript("OnLeave", function() local tt = rawget(_G, "GameTooltip") if tt then tt:Hide() end end)
            f.targetBtn = tb
        end
    end
    f.itemBtn = self:CreateItemButton(f)

    f.elapsed = 0
    f:SetScript("OnUpdate", function(self, elapsed)
        QG:FollowWindow()
        self.elapsed = self.elapsed + (elapsed or 0)
        if self.elapsed < math.max(0.25, ns.db.nav.updateInterval or 0.1) then return end
        self.elapsed = 0
        local okU, err = pcall(function() self.list:UpdateDistances(false) end)
        if not okU then ns.ReportOnce("qg:distances", err) end
    end)

    f:SetScript("OnShow", function() QG.scrolledTo = nil QG:ApplyTracker() QG:PlaceSecureButtons() end)
    f:SetScript("OnHide", function() QG:ApplyTracker() QG:PlaceSecureButtons() end)
    self.frame = f
    self:Apply()
    if not cfg.shown then f:Hide() end
    return f
end

-- ---- Blizzard's own objective tracker: out of the way while the Quest Guide shows ----
local trackerHooked = false
function QG:ApplyTracker()
    local tracker = rawget(_G, "ObjectiveTrackerFrame") or rawget(_G, "QuestWatchFrame")
    if not tracker then return end
    -- the tracker lives in an Edit-Mode managed container that keeps re-showing it, so
    -- it is faded out and made click-through rather than hidden
    -- while the guide is away (hidden, or stepped aside in a dungeon) Blizzard's tracker is the
    -- only thing left to read the dungeon quests from, so it goes back to normal
    local away = (ns.UI and ns.UI.AllHidden and ns.UI:AllHidden()) or ns.db.ui.hiddenAll
    local want = ns.db.ui.hideTracker ~= false and frame and frame:IsShown() and not away
    if want then
        pcall(tracker.SetAlpha, tracker, 0)
        pcall(tracker.EnableMouse, tracker, false)
        if not trackerHooked and tracker.HookScript then
            trackerHooked = true
            pcall(tracker.HookScript, tracker, "OnShow", function(self)
                if QG.trackerHidden then pcall(self.SetAlpha, self, 0) end
            end)
        end
        QG.trackerHidden = true
    elseif QG.trackerHidden then
        QG.trackerHidden = false
        pcall(tracker.SetAlpha, tracker, 1)
        pcall(tracker.EnableMouse, tracker, true)
    end
end

--- Push scale / opacity / width from the settings to the frame.
function QG:Apply()
    if not frame then return end
    local cfg = ns.db.ui
    pcall(frame.SetScale, frame, cfg.scale or 1)
    frame:SetWidth(math.max(cfg.width or 300, 240))
    frame.list:SetWidth(frame:GetWidth() - LIST_INSET)
    for _, d in ipairs(frame.drawers) do
        d.list:SetWidth(frame:GetWidth() - 12)
        if d.SetBackdropColor then pcall(d.SetBackdropColor, d, 0, 0, 0, cfg.opacity or 0.75) end
    end
    if frame.SetBackdropColor then pcall(frame.SetBackdropColor, frame, 0, 0, 0, cfg.opacity or 0.75) end
    self:Layout()
end

-- ---- the scroll bar ---------------------------------------------------------------------------
-- A thin track right of the list: the thumb shows which part of the guide is on screen and how
-- much of it, a gold mark where the current step is. Drag the thumb or click the track to move.
-- Drawn by hand: the scroll bar templates are not the same on every client.
local BAR_W = 5

local function viewportHeight(f)
    return f:GetHeight() - ns.QuestGuideHeader.HEIGHT - 2 - 4 - FOOTER
end

function QG:CreateScrollBar(f)
    local bar = CreateFrame("Button", nil, f)
    bar:SetWidth(BAR_W + 6)
    bar:SetPoint("TOPRIGHT", f.scroll, "TOPRIGHT", BAR_ROOM - 2, 0)
    bar:SetPoint("BOTTOMRIGHT", f.scroll, "BOTTOMRIGHT", BAR_ROOM - 2, 0)
    bar:SetFrameLevel(f:GetFrameLevel() + 4)
    bar.track = bar:CreateTexture(nil, "BACKGROUND")
    bar.track:SetWidth(BAR_W)
    bar.track:SetPoint("TOP", bar, "TOP", 0, 0)
    bar.track:SetPoint("BOTTOM", bar, "BOTTOM", 0, 0)
    pcall(bar.track.SetTexture, bar.track, Theme.TEX.white)
    bar.track:SetVertexColor(1, 1, 1, 0.08)
    bar.thumb = bar:CreateTexture(nil, "ARTWORK")
    bar.thumb:SetWidth(BAR_W)
    pcall(bar.thumb.SetTexture, bar.thumb, Theme.TEX.white)
    bar.thumb:SetVertexColor(0.75, 0.80, 0.87, 0.55)
    bar.mark = bar:CreateTexture(nil, "OVERLAY")
    bar.mark:SetSize(BAR_W + 4, 2)
    pcall(bar.mark.SetTexture, bar.mark, Theme.TEX.white)
    bar.mark:SetVertexColor(1.0, 0.82, 0.30, 1)
    bar.thumbHeight, bar.thumbOffset, bar.trackHeight, bar.markOffset = 0, 0, 0, 0
    -- click the track: that part of the guide; hold and drag: follow the mouse
    local function fractionAtCursor()
        local _, cy = GetCursorPosition()
        local scale = bar.GetEffectiveScale and bar:GetEffectiveScale() or 1
        local top = bar:GetTop() or 0
        local free = bar.trackHeight - bar.thumbHeight
        if free <= 0 then return 0 end
        return ((top - cy / scale) - bar.thumbHeight / 2) / free
    end
    bar:RegisterForClicks("LeftButtonDown")
    bar:SetScript("OnMouseDown", function(b) b.dragging = true QG:ScrollToFraction(fractionAtCursor()) end)
    bar:SetScript("OnMouseUp", function(b) b.dragging = false end)
    bar:SetScript("OnUpdate", function(b)
        if b.dragging then QG:ScrollToFraction(fractionAtCursor()) end
    end)
    bar:SetScript("OnMouseWheel", function(_, delta) f.scroll:GetScript("OnMouseWheel")(f.scroll, delta) end)
    bar:Hide()
    f.scrollBar = bar
end

--- Put the thumb and the current-step mark where the list is.
function QG:UpdateScrollBar()
    local f = frame
    local bar = f and f.scrollBar
    if not bar then return end
    local viewport = viewportHeight(f)
    local total = f.list.height or 0
    if viewport <= 0 or total <= viewport + 1 then bar:Hide() return end
    local track = viewport
    local thumbH = math.max(16, math.floor(track * viewport / total))
    local range = total - viewport
    local at = math.max(0, math.min(range, f.scroll:GetVerticalScroll()))
    local offset = (track - thumbH) * at / range
    bar.trackHeight, bar.thumbHeight, bar.thumbOffset = track, thumbH, offset
    bar.thumb:SetHeight(thumbH)
    bar.thumb:ClearAllPoints()
    bar.thumb:SetPoint("TOP", bar, "TOP", 0, -offset)
    -- the current step's place in the whole list
    local markAt
    for i, e in ipairs(f.list.entries) do
        if e.state == "active" then markAt = f.list.tops[i] + f.list.heights[i] / 2 break end
    end
    if markAt then
        bar.markOffset = math.floor(track * markAt / total)
        bar.mark:ClearAllPoints()
        bar.mark:SetPoint("TOP", bar, "TOP", 0, -bar.markOffset)
        bar.mark:Show()
    else
        bar.markOffset = 0
        bar.mark:Hide()
    end
    bar:Show()
end

--- Scroll so the view starts `fraction` (0 = top, 1 = bottom) of the way down the list.
function QG:ScrollToFraction(fraction)
    local f = frame
    if not f then return end
    local range = math.max(0, (f.list.height or 0) - viewportHeight(f))
    f.scroll:SetVerticalScroll(math.floor(range * math.max(0, math.min(1, fraction or 0)) + 0.5))
    self:Scrolled()
end

--- After any scroll: the rows on screen, their distances, the item button and the bar.
function QG:Scrolled()
    local f = frame
    self:SetView(f.scroll:GetVerticalScroll())
    f.list:UpdateDistances(false)
    self:PlaceItemButton()
    self:UpdateScrollBar()
end

--- The rows the window shows at once (the list itself holds the whole guide and scrolls).
local function rowsHeight()
    local rowH = (ns.db.ui.showSubtitles ~= false and ns.QuestRow.HEIGHT_TWO or ns.QuestRow.HEIGHT_ONE) + 3
    return math.max(3, ns.db.ui.maxRows or 7) * rowH + 6
end

--- Tell the list which part of it is on screen: only those rows work out a distance.
function QG:SetView(at)
    local f = frame
    local viewport = f:GetHeight() - ns.QuestGuideHeader.HEIGHT - 2 - 4 - FOOTER
    f.list:SetView(at, at + viewport)
end

function QG:Layout()
    if not frame then return end
    local f = frame
    local natural = ns.QuestGuideHeader.HEIGHT + 2 + math.min(f.list.height or 40, rowsHeight()) + 4 + FOOTER
    local height = math.max(150, math.min(800, ns.db.ui.height or natural))
    -- in combat the height is held: the skull button sits on the bottom edge and cannot follow it
    if inCombat() and f:GetHeight() > 0 then
        if height ~= f:GetHeight() then self.layoutPending = true end
        height = f:GetHeight()
    else
        self.layoutPending = nil
    end
    f:SetHeight(height)
    f.footerLine:ClearAllPoints()
    f.footerLine:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -(height - FOOTER))
    f.footerLine:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -(height - FOOTER))
    if f.scroll then
        local viewport = height - ns.QuestGuideHeader.HEIGHT - 2 - 4 - FOOTER
        local at = f.scroll:GetVerticalScroll()
        local tops, activeI = f.list.tops, nil
        for i, entry in ipairs(f.list.entries) do
            if entry.state == "active" then activeI = i break end
        end
        -- scroll to the current step only when it changes: a refresh must not pull the list back
        -- while the player reads further down
        local e = activeI and f.list.entries[activeI]
        local key = e and (e.index or e.questID)
        if key and key ~= self.scrolledTo then
            at = tops[math.max(1, activeI - 2)]        -- two steps of context above it
            local bottom = tops[activeI] + f.list.heights[activeI]
            -- too little room for the context: the current step itself, its top first
            if bottom > at + viewport then at = math.min(tops[activeI], bottom - viewport) end
            self.scrolledTo = key
        end
        at = math.max(0, math.min(at, math.max(0, f.list.height - viewport)))
        f.scroll:SetVerticalScroll(at)
        self:SetView(at)
        f.list:UpdateDistances(false)
        self:UpdateScrollBar()
    end
    self:PlaceItemButton()
end

-- ---- the secure buttons over the window ------------------------------------------------------
-- A secure button makes every frame it is parented under or anchored to protected, and in combat
-- the client blocks moving, sizing, showing and hiding a protected frame (ADDON_ACTION_BLOCKED).
-- So the item and skull buttons are children of UIParent, never of the window or its rows: they are
-- placed over the window by screen position out of combat and left where they are during a fight,
-- made invisible when the window goes away.

--- Put the secure buttons over the window, or hide them with it (out of combat; deferred otherwise).
function QG:PlaceSecureButtons()
    local f = frame
    if not f then return end
    local tb, ib = f.targetBtn, f.itemBtn
    if inCombat() then
        local alpha = f:IsShown() and 1 or 0
        if tb then pcall(tb.SetAlpha, tb, alpha) end
        if ib then pcall(ib.SetAlpha, ib, alpha) end
        self.securePending = true
        return
    end
    self.securePending = nil
    local left, right, top, bottom = f:GetLeft(), f:GetRight(), f:GetTop(), f:GetBottom()
    local shown = f:IsShown() and left ~= nil and top ~= nil
    local at = self.placedAt or {}
    at[1], at[2], at[3], at[4], at[5], at[6] = left, right, top, bottom, f:GetScale(), f:GetFrameStrata()
    self.placedAt = at
    local function over(b, level, point, x, y)
        pcall(b.SetAlpha, b, 1)
        if not shown or not x then b:Hide() return end
        b:SetScale(f:GetScale())            -- both are UIParent's children: same scale, same units
        b:SetFrameStrata(f:GetFrameStrata() or "HIGH")
        b:SetFrameLevel(f:GetFrameLevel() + level)
        b:ClearAllPoints()
        b:SetPoint(point, UIParent, "BOTTOMLEFT", x, y)
        b:Show()
    end
    if tb then over(tb, 5, "BOTTOM", (left + right) / 2, bottom + 39) end
    if ib then over(ib, 6, "TOPRIGHT", ib.fromTop and right - 14, ib.fromTop and top - ib.fromTop) end
end

--- Every frame: re-place the buttons once the window has moved, resized, rescaled or changed layer.
function QG:FollowWindow()
    local f = frame
    if not f or inCombat() then return end
    local at = self.placedAt
    if self.securePending or not at or at[1] ~= f:GetLeft() or at[2] ~= f:GetRight() or at[3] ~= f:GetTop()
        or at[4] ~= f:GetBottom() or at[5] ~= f:GetScale() or at[6] ~= f:GetFrameStrata() then
        self:PlaceSecureButtons()
    end
end

-- ---- the quest item button ------------------------------------------------------------------
-- A secure button that uses the current step's quest item (the one way an addon may use an item:
-- the PLAYER clicks it). Secure attributes are locked in combat, so it is set up out of combat only
-- and left as it is during a fight. It sits over the step's row but is not its child: rows are
-- re-laid out in combat, which they could not be with a secure frame on them.
local ITEM_SIZE = 22

function QG:CreateItemButton(f)
    local ok, b = pcall(CreateFrame, "Button", "ForeverGuideItemButton", UIParent, "SecureActionButtonTemplate")
    if not ok or not b then return nil end
    pcall(b.SetAttribute, b, "type", "item")
    pcall(b.RegisterForClicks, b, "AnyDown", "AnyUp")
    b:SetSize(ITEM_SIZE, ITEM_SIZE)
    b:SetFrameLevel(f:GetFrameLevel() + 6)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    pcall(hl.SetTexture, hl, Theme.TEX.buttonHl)
    pcall(hl.SetBlendMode, hl, "ADD")
    pcall(hl.SetAlpha, hl, 0.4)
    b.count = Theme.NewText(b, { size = 9, justify = "RIGHT", color = Theme.C.text, oneLine = true, outline = "OUTLINE" })
    b.count:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 1, -1)
    local okC, cd = pcall(CreateFrame, "Cooldown", nil, b, "CooldownFrameTemplate")
    if okC and cd then cd:SetAllPoints() b.cooldown = cd end
    b:SetScript("OnEnter", function(self)
        local tt = rawget(_G, "GameTooltip")
        if not tt or not self.itemID then return end
        tt:SetOwner(self, "ANCHOR_LEFT")
        if not pcall(tt.SetItemByID, tt, self.itemID) then tt:AddLine("Quest item", 1, 0.88, 0.55) end
        local key = ns.MobMarker and ns.MobMarker:TargetKey()
        if key and ns.MobMarker.Cfg().useItem ~= false then
            tt:AddLine("Click to use.  " .. key .. " targets the quest mob and uses it too.", 0.66, 0.61, 0.52, true)
        else
            tt:AddLine("Click to use.", 0.66, 0.61, 0.52, true)
        end
        tt:Show()
    end)
    b:SetScript("OnLeave", function() local tt = rawget(_G, "GameTooltip") if tt then tt:Hide() end end)
    b:SetScript("OnUpdate", function(self, elapsed)
        self.elapsed = (self.elapsed or 0) + (elapsed or 0)
        if self.elapsed < 0.25 then return end
        self.elapsed = 0
        QG:UpdateItemButtonState()
    end)
    b:Hide()
    return b
end

--- Count and cooldown: plain textures, fine to change in combat.
function QG:UpdateItemButtonState()
    local b = frame and frame.itemBtn
    if not b or not b.itemID then return end
    local n = ns.PlainNumber(ns.Call("C_Item.GetItemCount", b.itemID)) or 0
    b.count:SetText(n > 1 and tostring(n) or "")
    pcall(b.icon.SetDesaturated, b.icon, n == 0)
    if b.cooldown then
        local start, duration, enable = ns.Call("C_Container.GetItemCooldown", b.itemID)
        if start == nil then start, duration, enable = ns.Safe(rawget(_G, "GetItemCooldown"), b.itemID) end
        start, duration = ns.PlainNumber(start), ns.PlainNumber(duration)
        if start and duration and duration > 0 and ns.Plain(enable) ~= 0 then
            pcall(b.cooldown.SetCooldown, b.cooldown, start, duration)
        else
            pcall(b.cooldown.Clear, b.cooldown)
        end
    end
end

--- Put the button on the row of the step that has an item (out of combat; deferred otherwise).
function QG:PlaceItemButton()
    local f = frame
    local b = f and f.itemBtn
    if not b then return self:PlaceSecureButtons() end
    if inCombat() then self.securePending = true return end
    local idx, itemID
    for i, e in ipairs(f.list.entries or {}) do
        if e.useItem then idx, itemID = i, e.useItem break end
    end
    local rowH = idx and f.list.heights[idx]
    local viewport = f:GetHeight() - ns.QuestGuideHeader.HEIGHT - 2 - 4 - FOOTER
    local y = idx and (f.list.tops[idx] - (f.scroll and f.scroll:GetVerticalScroll() or 0))
    if not idx or y < 0 or y + rowH > viewport + 1 then
        b.itemID, b.fromTop = nil, nil
        self:PlaceSecureButtons()
        return
    end
    if b.itemID ~= itemID then
        pcall(b.SetAttribute, b, "item", "item:" .. itemID)
        local icon = ns.Call("C_Item.GetItemIconByID", itemID)
        if icon == nil then icon = ns.Safe(rawget(_G, "GetItemIcon"), itemID) end
        pcall(b.icon.SetTexture, b.icon, ns.Plain(icon) or "Interface\\Icons\\INV_Misc_QuestionMark")
        b.itemID = itemID
    end
    b.fromTop = ns.QuestGuideHeader.HEIGHT + 2 + y + (rowH - ITEM_SIZE) / 2
    self:PlaceSecureButtons()
    self:UpdateItemButtonState()
end

-- ---- entries ---------------------------------------------------------------------------
local function questTitle(step)
    if step.questName and step.questName ~= "" then return step.questName end
    if step.quest and ns.DB and ns.DB:IsLoaded() then
        local q = ns.DB:GetQuest(step.quest)
        if q and q.n then return q.n end
    end
    return nil
end

--- What the row says under the quest name.
local function subtitle(G, step, idx)
    local t = step.type
    local DB = ns.DB
    if t == "ACCEPT" then
        local who = step.npcName or (step.npc and DB and DB:NPCName(step.npc))
        return who and ("Accept from " .. who) or "Accept the quest"
    elseif t == "TURNIN" then
        local who = step.npcName or (step.npc and DB and DB:NPCName(step.npc))
        return who and ("Turn in to " .. who) or "Turn in"
    elseif t == "KILL" or t == "COLLECT" or t == "COMPLETE" then
        local verb = t == "KILL" and "Kill" or (t == "COLLECT" and "Collect" or "Complete")
        local target = step.target
        if not target and step.quest and DB and DB:IsLoaded() then
            local objs = DB:QuestObjectives(step.quest)
            local o = objs[G:StepObjectiveIndex(step) or 1]
            target = o and o.name
        end
        local text = target and string.format("%s%s %s", verb, step.count and (" " .. step.count) or "", target) or (step.note or verb)
        local prog = G:GetStepProgress(step)
        if prog and prog:find("^%d+ / %d+") then text = text .. "  (" .. prog .. ")" end
        return text
    elseif t == "GRIND" then
        return step.note or ("Grind to level " .. tostring(step.level))
    elseif t == "TRAVEL" or t == "FLY" then
        return step.note or ("Go to " .. tostring(step.zone or ""))
    elseif t == "NOTE" then
        return nil
    end
    return G:GetStepText(step)
end

--- Who a step is for, when not everyone: "[Warrior]" in the class colour, "[Blacksmithing]".
--- The step is hidden from everyone else, so the tag says why this one is on the list.
local function forTag(step)
    local tags = {}
    local names, colors = rawget(_G, "LOCALIZED_CLASS_NAMES_MALE"), rawget(_G, "RAID_CLASS_COLORS")
    for _, cls in ipairs(type(step.class) == "table" and step.class or {}) do
        local name = (names and names[cls]) or (cls:sub(1, 1) .. cls:sub(2):lower())
        local color = colors and colors[cls] and colors[cls].colorStr
        tags[#tags + 1] = color and ("|c" .. color .. "[" .. name .. "]|r") or ("[" .. name .. "]")
    end
    if step.profession then tags[#tags + 1] = "|cffc0a060[" .. step.profession .. "]|r" end
    return #tags > 0 and table.concat(tags, " ") or nil
end

local function rowTitle(G, step)
    local t = step.type
    if step.quest then return questTitle(step) or G:GetStepText(step) end
    if t == "NOTE" then return step.text or "Note" end
    if t == "GRIND" then return "Grind to level " .. tostring(step.level) end
    if t == "TRAVEL" or t == "FLY" then return (step.zone and ("Travel to " .. step.zone)) or "Travel" end
    return G:GetStepText(step)
end

function QG:BuildGuideEntries()
    local G = ns.Guide
    local g = G.active
    local p = G.progress
    local cur, total = G:GetStepCount()     -- position of the current step in the player's order
    local curIdx = G.current
    local seq = G:Order()
    local cfg = ns.db.ui
    local showDone = cfg.showCompleted ~= false
    local entries = {}
    -- quests skipped by hand: all their steps read as skipped, not done
    local skippedQuest = {}
    for idx in pairs(p and p.skipped or {}) do
        local s = g.steps[idx]
        if s and s.quest and p.done[idx] then skippedQuest[s.quest] = true end
    end
    local function isSkipped(idx, s)
        if not (p and p.done[idx]) then return false end
        return (p.skipped and p.skipped[idx]) or (s.quest and skippedQuest[s.quest]) or false
    end
    -- the whole guide, in the player's order: the window scrolls, it does not cut the list
    local upcoming = 0
    for pos = 1, total do
        local idx = seq[pos]
        local s = g.steps[idx]
        local skipped = s and isSkipped(idx, s)
        local done = s and pos ~= cur and (pos < cur or G:IsStepDone(s, idx))
        if s and G:StepApplies(s) and (pos == cur or skipped or not done or showDone) then
            local state
            if skipped then state = "skipped"
            elseif done then state = "done"
            elseif idx == curIdx then state = "active"
            elseif s.optional then state = "optional"
            else
                upcoming = upcoming + 1
                state = upcoming <= 2 and "available" or "future"
            end
            if idx == curIdx and G.IsStepBlocked and G:IsStepBlocked(s) and G.note then state = "blocked" end
            local sub = subtitle(G, s, idx)
            local gate = G.LevelGate and G:LevelGate(s)
            local deferred = s.quest and G.progress and G.progress.deferred and G.progress.deferred[s.quest]
            if state ~= "done" and state ~= "skipped" and (gate or (deferred and not ns.Quest:IsOnQuest(s.quest))) then
                state = "blocked"
                local q = ns.DB and ns.DB:GetQuest(s.quest)
                sub = string.format("Needs level %d - skipped until then", gate or (q and q.req) or 0)
            end
            local title = (forTag(s) and ((rowTitle(G, s) or "") .. " " .. forTag(s))) or rowTitle(G, s)
            if state == "skipped" then
                title = "|cffd99a4dSkipped:|r " .. (title or "")
                sub = "Right-click > Do now brings it back"
            end
            local e = {
                number = pos, index = idx, step = s, icon = ICON_FOR[s.type] or "accept", state = state,
                title = title, subtitle = sub, questID = s.quest,
                useItem = idx == curIdx and G:StepUseItem(s) or nil,
                onClick = function() G:SetStep(idx) end,
                onRightClick = function(_, row) QG:ShowStepMenu(row, idx) end,
            }
            local tip = {}
            local eff = ns.Editor and ns.Editor:Effective(s) or s
            if eff.note and eff.note ~= "" then tip[#tip + 1] = eff.note .. (eff.hasEdit and "  (edited)" or "") end
            if s.quest and ns.Quest then
                local grey = ns.Quest:GreyWarning(s.quest)
                if grey then tip[#tip + 1] = "|cffff8040" .. grey .. "|r" end
            end
            if G:IsMoved(idx) then tip[#tip + 1] = "|cff8a8070Moved by you (/fg order reset puts it back).|r" end
            tip[#tip + 1] = state == "skipped" and "|cff8a8070You skipped this. Right click: Do now brings it back.|r"
                or "|cff8a8070Left click: jump here.  Right click: do it now, later, or skip it.|r"
            e.tooltip = tip
            entries[#entries + 1] = e
        end
    end
    return entries, cur, total
end

function QG:BuildTrackerEntries()
    local T = ns.Tracker
    local entries = {}
    for i, c in ipairs(T.candidates) do
        entries[#entries + 1] = {
            number = i, icon = c.kind == "turnin" and "turnin" or (c.kind == "kill" and "kill" or "collect"), state = i == 1 and "active" or (i <= 3 and "available" or "future"),
            title = ns.Quest:TitleWithLevel(c.questID, c.title), subtitle = c.what, loc = c.loc, questID = c.questID,
            useItem = i == 1 and c.kind ~= "turnin" and ns.Quest:UsableItem(c.questID) or nil,
            tooltip = { c.loc and ns.DB:DescribeLocation(c.loc) or "", c.grey and ("|cffff8040" .. c.grey .. "|r") or nil,
                        "|cff8a8070Right click: do it first, last, or in nearest order.|r" },
            onRightClick = function(_, row) QG:ShowMenu(row, QG:QuestMenuItems(c.questID)) end,
        }
    end
    return entries
end

-- ---- the panels under the window: one open at a time ------------------------------------------
--- Open the panel named `which` ("unknown" or "dungeons"), or close them all with nil.
function QG:SetDrawer(which)
    if not frame then return end
    self.drawer = which
    frame.extra:SetShown(which == "unknown")
    if which == "unknown" then self:RefreshExtra() end
    if ns.Dungeons.SetDrawerShown then ns.Dungeons:SetDrawerShown(which == "dungeons") end
    for name, btn in pairs({ unknown = frame.unknownBtn, dungeons = frame.dungeonsBtn }) do
        local on = which == name
        pcall(btn.normal.SetVertexColor, btn.normal, on and 0.34 or 0.18, on and 0.28 or 0.18, on and 0.14 or 0.18, 1)
    end
end

function QG:ToggleDrawer(which)
    self:SetDrawer(self.drawer ~= which and which or nil)
end

-- ---- the right-click menu on a row -----------------------------------------------------------
local menu
local MENU_W = 116

function QG:RowMenu()
    if menu then return menu end
    local ok, m = pcall(CreateFrame, "Frame", "ForeverGuideRowMenu", UIParent, "BackdropTemplate")
    if not ok or not m then m = CreateFrame("Frame", "ForeverGuideRowMenu", UIParent) end
    menu = m
    m:SetFrameStrata("DIALOG")
    m:EnableMouse(true)
    m:SetClampedToScreen(true)
    m:SetWidth(MENU_W)
    Theme.Backdrop(m, "panel", 0.92)
    m.buttons = {}
    m:Hide()
    -- Escape closes it, like the game's own menus
    local special = rawget(_G, "UISpecialFrames")
    if type(special) == "table" then table.insert(special, "ForeverGuideRowMenu") end
    return m
end

--- A small menu beside `row`: items = { { label, fn, tooltip }, ... }. Right-clicking the same row
--- again closes it; hovering a choice says what it does.
function QG:ShowMenu(row, items)
    local m = self:RowMenu()
    if m:IsShown() and m.row == row then m:Hide() return end
    if #items == 0 then m:Hide() return end
    for i, item in ipairs(items) do
        local b = m.buttons[i]
        if not b then
            local btn
            btn = Theme.NewButton(m, "", MENU_W - 12, 22, function()
                local it = btn.item
                m:Hide()
                if it then it[2]() end
            end)
            btn:SetPoint("TOPLEFT", m, "TOPLEFT", 6, -6 - (i - 1) * 26)
            btn:SetScript("OnEnter", function(self)
                Theme.Color(self.label, Theme.C.goldLight)
                local tt = rawget(_G, "GameTooltip")
                if tt and self.item and self.item[3] then
                    tt:SetOwner(self, "ANCHOR_LEFT")
                    tt:AddLine(self.item[1], 1, 0.88, 0.55)
                    tt:AddLine(self.item[3], 0.85, 0.82, 0.75, true)
                    tt:Show()
                end
            end)
            btn:SetScript("OnLeave", function(self)
                Theme.Color(self.label, Theme.C.gold)
                local tt = rawget(_G, "GameTooltip")
                if tt then tt:Hide() end
            end)
            m.buttons[i] = btn
            b = btn
        end
        b.item = item
        b.label:SetText(item[1])
        b:Show()
    end
    for i = #items + 1, #m.buttons do m.buttons[i].item = nil m.buttons[i]:Hide() end
    m:SetHeight(12 + #items * 26 - 4)
    m:ClearAllPoints()
    if row and info and info:IsShown() then
        -- the Details popup already sits left of the window: go left of it, level with the row
        m:SetPoint("RIGHT", info, "LEFT", -4, 0)
        m:SetPoint("TOP", row, "TOP", 0, 0)
    elseif row then
        m:SetPoint("TOPRIGHT", row, "TOPLEFT", -4, 0)
    else
        m:SetPoint("CENTER")
    end
    m.row = row
    m:Show()
end

--- What can be done with a guide step: now, later, skip - or bring back a skipped one.
function QG:StepMenuItems(idx)
    local G = ns.Guide
    local p = G.progress
    local s = G.active and G.active.steps[idx]
    if not s or not p then return {} end
    local items = {}
    local quest = s.type == "ACCEPT" and s.quest
    if G:IsOpen(idx) then
        if idx ~= G.current then
            items[#items + 1] = { "Do now", function() G:DoNow(idx) end,
                "Becomes the current step; the one you're on comes next." }
        end
        items[#items + 1] = { "Later", function() G:Later(idx) end,
            "Comes back after the next 5 steps" .. (s.quest and ", with its quest" or "") .. ". Not marked done." }
        items[#items + 1] = { "Skip", function() G:MarkDone(idx, "skip") end, (quest and "Skips the whole quest." or "Marked done.") .. " It stays in the list to undo." }
    elseif p.done[idx] and G:StepApplies(s) and not G:IsStepDone(s, idx, true) then
        -- marked done or skipped by hand, not by the game: it can come back
        items[#items + 1] = { "Do now", function() G:DoNow(idx) end,
            "Brings it back as the current step" .. (quest and ", with its quest." or ".") }
    end
    return items
end

function QG:ShowStepMenu(row, idx)
    self:ShowMenu(row, self:StepMenuItems(idx))
end

--- Auto mode: pin a quest first or last, or back to distance order.
function QG:QuestMenuItems(questID)
    local T = ns.Tracker
    local items = {
        { "Do first", function() T:Pin(questID, "first") end,
          "Always at the top, with the arrow on it." },
        { "Do last", function() T:Pin(questID, "last") end,
          "Always at the bottom." },
    }
    if (T:Prio()[questID] or 0) ~= 0 then
        items[#items + 1] = { "Nearest order", function() T:Pin(questID, nil) end, "Sorted by distance again." }
    end
    return items
end

-- ---- refresh -------------------------------------------------------------------------------
function QG:RefreshExtra()
    local f = frame
    local covered = ns.Guide:CoveredQuests()
    local entries = {}
    for quest in ns.Quest:Iterate() do
        if not covered[quest.questID] then
            local objective = quest.objectives[1]
            entries[#entries + 1] = {
                questID = quest.questID, title = ns.Quest:TitleWithLevel(quest.questID, quest.title),
                subtitle = quest.ready and "Ready to turn in" or (objective and objective.text or "In progress"),
                icon = quest.ready and "turnin" or "collect", state = quest.ready and "available" or "future",
                tooltip = { "|cff8a8070Left click: open in the quest log.  Right click: report missing route quest.|r" },
                onClick = function() ns.Quest:OpenInLog(quest.questID) end,
                onRightClick = function() ns.Reports:MissingQuest(quest.questID) end,
            }
        end
    end
    f.unknownBtn.label:SetText(#entries > 0 and string.format("Unknown Quests (%d)", #entries) or "Unknown Quests")
    if not f.extra:IsShown() then return end
    f.extra.list:Set(entries, "Every quest in your log is in a guide.")
    f.extra:Fit()
end

--- The next chapter as a player reads it: its name, never its id ("TUGS_ALLIANCE_..."); the id
--- only when that guide is not loaded.
local function nextChapterName(g)
    local nextGuide = g.next and ns.Guide:Get(g.next)
    return nextGuide and (nextGuide.name or nextGuide.id) or g.next
end

function QG:Refresh()
    if not frame then return end
    local f = frame
    self:ApplyTracker()
    self:RefreshExtra()
    local G, T = ns.Guide, ns.Tracker
    local g = G.active
    local level = ns.Player:GetLevel()
    local zone = ns.Player:GetMapName() or ns.Player:GetZone() or ""

    if T and T:IsActive() and (not g or ns.char.mode == "auto") then
        local entries = self:BuildTrackerEntries()
        f.header:Set(string.format("%d", #T.candidates), string.format("Auto mode  ·  quest log  ·  Lv %d  %s", level, zone))
        f.list:Set(entries, #ns.Quest.order == 0 and "Pick up some quests - auto mode tracks your quest log." or "No known locations for your quests yet.")
        self:Layout()
        return
    end
    if not g then
        f.header:Set("", string.format("Lv %d  ·  %s", level, zone))
        f.list:Set({}, "No guide active.\nClick Guides to pick a route (or /fg guides).")
        self:Layout()
        return
    end
    local entries, cur, total = self:BuildGuideEntries()
    local sub = string.format("%s  ·  Lv %d", g.name or g.id, level)
    -- "Lv 18 -> 19 in 1h 0m" while the pace is known
    local pace = ns.Pace and ns.Pace:Tag()
    if pace then sub = sub .. "  ·  " .. pace end
    f.header:Set(string.format("%d / %d", math.min(cur, total), total), sub)
    if cur > total then
        f.list:Set({}, "Guide complete!" .. (g.next and ("\nNext chapter: " .. nextChapterName(g)) or ""))
    else
        f.list:Set(entries)
    end
    self:Layout()
end

-- ---- the "Details" info popup --------------------------------------------------------------
function QG:CreateInfo()
    if info then return info end
    local ok, p = pcall(CreateFrame, "Frame", "ForeverGuideInfo", UIParent, "BackdropTemplate")
    if not ok or not p then p = CreateFrame("Frame", "ForeverGuideInfo", UIParent) end
    info = p
    p:SetSize(360, 200)
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
    p.body = Theme.NewText(p, { size = 11, color = Theme.C.text, maxLines = 12 })
    p.body:SetPoint("TOPLEFT", p.title, "BOTTOMLEFT", 0, -8)
    p.body:SetPoint("TOPRIGHT", p, "TOPRIGHT", -14, 0)
    p.back = Theme.NewButton(p, "Back", 66, 22, function() ns.Guide:Back() QG:RefreshInfo() end)
    p.skip = Theme.NewButton(p, "Skip", 66, 22, function() ns.Guide:Skip() QG:RefreshInfo() end)
    p.auto = Theme.NewButton(p, "Auto", 66, 22, function() ns.Tracker:SetMode(ns.char.mode == "auto" and "guide" or "auto") QG:RefreshInfo() end)
    p.resync = Theme.NewButton(p, "Resync", 66, 22, function() ns.Commands:Run("resync") QG:RefreshInfo() end)
    p.close = Theme.NewButton(p, "x", 26, 20, function() info:Hide() end)
    p.back:SetPoint("BOTTOMLEFT", p, "BOTTOMLEFT", 12, 10)
    p.skip:SetPoint("LEFT", p.back, "RIGHT", 6, 0)
    p.auto:SetPoint("LEFT", p.skip, "RIGHT", 6, 0)
    p.resync:SetPoint("LEFT", p.auto, "RIGHT", 6, 0)
    p.close:SetPoint("TOPRIGHT", p, "TOPRIGHT", -8, -8)
    p:Hide()
    return p
end

function QG:RefreshInfo()
    if not info or not info:IsShown() then return end
    local G = ns.Guide
    local g = G.active
    local lines = {}
    if g then
        info.title:SetText(g.name or g.id)
        local cur, total = G:GetStepCount()
        lines[#lines + 1] = string.format("|cffdeb24aStep %d of %d|r", math.min(cur, total), total)
        local step = G:GetCurrentStep()
        if step then
            lines[#lines + 1] = G:GetStepText(step)
            local prog = G:GetStepProgress(step)
            if prog and prog ~= "" then lines[#lines + 1] = "|cffa89e8e" .. prog .. "|r" end
            local _, _, _, _, loc = ns.Navigation:ResolveStep(step)
            if loc then lines[#lines + 1] = "|cffa89e8e" .. ns.DB:DescribeLocation(loc) .. "|r" end
            local eff = ns.Editor and ns.Editor:Effective(step) or step
            if eff.note and eff.note ~= "" then lines[#lines + 1] = "|cffff8040" .. eff.note .. "|r" end
        else
            lines[#lines + 1] = "Guide complete!" .. (g.next and ("  Next: " .. nextChapterName(g)) or "")
        end
        if G.note then lines[#lines + 1] = "|cffff8040" .. G.note .. "|r" end
        local moved = G.progress and G.progress.order and #G.progress.order or 0
        if moved > 0 then
            lines[#lines + 1] = string.format("|cff8a8070%d step%s moved by you - /fg order reset puts them back.|r", moved, moved == 1 and "" or "s")
        end
        if g.notes then lines[#lines + 1] = " " lines[#lines + 1] = "|cff8a8070" .. g.notes .. "|r" end
        info.auto:SetText(ns.char.mode == "auto" and "Guide" or "Auto")
        info.auto.label:SetText(ns.char.mode == "auto" and "Guide" or "Auto")
    else
        info.title:SetText("No guide active")
        lines[#lines + 1] = "Pick a route with the Guides button, or /fg guides. Auto mode tracks your quest log without a guide."
    end
    info.body:SetText(table.concat(lines, "\n"))
    local titleH = info.title.GetStringHeight and info.title:GetStringHeight() or 18
    local bodyH = info.body.GetStringHeight and info.body:GetStringHeight() or 60
    info:SetHeight(math.max(140, 12 + titleH + 8 + bodyH + 16 + 22 + 12))
    info.back:SetShown(g ~= nil) info.skip:SetShown(g ~= nil) info.resync:SetShown(g ~= nil)
end

function QG:ToggleInfo()
    local p = self:CreateInfo()
    if menu then menu:Hide() end        -- both open left of the window
    if p:IsShown() then p:Hide() return end
    p:ClearAllPoints()
    if frame then p:SetPoint("TOPRIGHT", frame, "TOPLEFT", -12, 0) else p:SetPoint("CENTER") end
    p:Show()
    self:RefreshInfo()
end

function QG:OnInit()
    ns.Events:Register("PLAYER_REGEN_ENABLED", function()
        if QG.layoutPending then QG:Layout() elseif QG.securePending then QG:PlaceItemButton() end
    end)
    ns.Events:Register("FG_LOCK_CHANGED", function(_, locked)
        if frame and frame.resizeGrip then frame.resizeGrip:SetShown(not locked) end
    end)
    ns.Events:RegisterMany({ "FG_STEP_CHANGED", "FG_STEP_UPDATED", "FG_GUIDE_CHANGED", "FG_MODE_CHANGED", "FG_QUEST_LOG_CHANGED" },
        function() if info and info:IsShown() then ns.Events:Debounce("qginfo", 0.1, function() QG:RefreshInfo() end) end end)
end
