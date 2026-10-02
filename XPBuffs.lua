-- ============================================================
-- ForeverGuide / XPBuffs.lua
-- Two XP buffs a levelling character forgets, each with its own icon on screen
-- while it is missing:
--
--   * food: Well Fed, +5% XP. On Forever the food's own Well Fed buff carries the bonus: 13 of
--           the client's 30 Well Fed spells show "Experience gained from kills increased by 5%"
--           (from 1243969), and the 106 XP foods all give one of them. The other 17 (holiday
--           treats, Prowler Steak...) say nothing about XP and do not count.
--   * bag:  Well-Rested (spell 429959) from the Cozy Sleeping Bag (item 211527), +1% XP per
--           stack up to 3; the icon stays up below 3 stacks and shows the count (1/3).
--
-- Display only: plain frames, no secure buttons, so they show and hide in combat too.
-- Both hide at max level or with XP turned off. The two sit side by side in one holder:
-- shift-drag either icon (or drag while the window is unlocked) and both move together.
-- `/fg remind food|bag on|off` turns one off.
-- ============================================================

local _, ns = ...
local Theme = ns.Theme
local XB = ns:NewModule("XPBuffs")

local SIZE = 36
local GAP = 8                -- between the two icons
local RECHECK = 30           -- seconds between fallback checks (UNIT_AURA can be secret)
local MAX_LEVEL = 60

-- The client's own tables (build 1.60.1.70094): the spells that count, stacks for the full bonus,
-- the icon, wording. Food: Well Fed XP Boost itself, then the Well Fed spells whose text carries
-- its XP line, by stat (Stamina, Intellect, Strength, Agility, Attack Power, Spell Damage,
-- Fishing, Spirit, Healing, Crit, Westfall Stew's speed, Goldthorn Tea's Herbalism, Armor).
XB.BUFFS = {
    food = { spellIDs = { 1243969, 1248406, 1248421, 1248422, 1248420, 1249519, 1249520, 1249521,
                          1249926, 1249927, 1249523, 1248688, 1249907, 1319310 },
             icon = 19705, needed = 1, slot = 0, name = "Well Fed",
             bonus = "+5% experience", hint = "Eat a food whose Well Fed buff gives experience (most cooked food does)." },
    bag  = { spellIDs = { 429959 }, needed = 3, slot = 1, name = "Well-Rested",
             bonus = "+1% experience per stack, up to 3", hint = "Rest near your Cozy Sleeping Bag." },
}
XB.ORDER = { "food", "bag" }

local function cfg()
    ns.db.xpbuffs = ns.db.xpbuffs or {}
    local c = ns.db.xpbuffs
    for _, key in ipairs(XB.ORDER) do
        c[key] = c[key] or {}
        if c[key].enabled == nil then c[key].enabled = true end
        c[key].point = nil       -- each icon had its own position before they moved together
    end
    return c
end
XB.Cfg = cfg

local function auraStacks(aura)
    if aura == nil then return 0 end
    if ns.IsSecret(aura) or type(aura) ~= "table" then return nil end
    local n = ns.PlainNumber(aura.applications)
    if n == nil and ns.IsSecret(aura.applications) then return nil end
    return math.max(n or 1, 1)              -- 0 applications = an aura that does not stack
end

--- Stacks of a buff on the player (the most of any of its spells): 0 when it is gone, nil when
--- the client will not say (secret) and no readable spell has it.
function XB:Stacks(buff)
    local best, unreadable = 0, false
    for _, id in ipairs(buff.spellIDs) do
        local n = auraStacks(ns.Call("C_UnitAuras.GetPlayerAuraBySpellID", id))
        if n == nil then unreadable = true elseif n > best then best = n end
    end
    if best == 0 and unreadable then return nil end
    return best
end

--- Below max level with XP on.
function XB:Leveling()
    local maxLevel = ns.PlainNumber(ns.Safe(rawget(_G, "GetMaxPlayerLevel"))) or MAX_LEVEL
    if ns.Player:GetLevel() >= maxLevel then return false end
    return ns.PlainBool(ns.Safe(rawget(_G, "IsXPUserDisabled"))) ~= true
end

--- Should the indicator show? true/false with stacks and needed, or nil when the aura is unreadable.
function XB:Missing(key)
    local buff = self.BUFFS[key]
    if not buff or cfg()[key].enabled == false or not self:Leveling() then return false end
    local stacks = self:Stacks(buff)
    if stacks == nil then return nil end
    return stacks < buff.needed, stacks, buff.needed
end

-- ---- the icons --------------------------------------------------------------------------

local function place(h)
    local p = cfg().point
    h:ClearAllPoints()
    if p then
        h:SetPoint(p.point or "CENTER", UIParent, p.point or "CENTER", p.x or 0, p.y or 0)
    else
        h:SetPoint("CENTER", UIParent, "CENTER", 0, 220)
    end
end

--- The frame both icons sit in; it is what moves.
function XB:Holder()
    if self.holder then return self.holder end
    local h = CreateFrame("Frame", "ForeverGuideXPBuffs", UIParent)
    h:SetSize(SIZE * 2 + GAP, SIZE)
    h:SetFrameStrata("MEDIUM")
    h:SetMovable(true)
    h:SetClampedToScreen(true)
    place(h)
    self.holder = h
    return h
end

local function tooltip(f)
    local tt = rawget(_G, "GameTooltip")
    if not tt then return end
    local buff, stacks = XB.BUFFS[f.key], f.stacks or 0
    tt:SetOwner(f, "ANCHOR_BOTTOM")
    tt:AddLine(buff.needed > 1 and string.format("%s %d/%d", buff.name, stacks, buff.needed) or ("Missing: " .. buff.name), 1, 0.82, 0)
    tt:AddLine(buff.bonus, 1, 1, 1, true)
    tt:AddLine(buff.hint, 1, 1, 1, true)
    tt:AddLine("Shift-drag to move both icons.  /fg remind " .. f.key .. " off hides this one.", 0.66, 0.61, 0.52, true)
    tt:Show()
end

local function newIndicator(key)
    local buff = XB.BUFFS[key]
    local h = XB:Holder()
    local f = CreateFrame("Frame", "ForeverGuideXPBuff_" .. key, h)
    f.key = key
    f:SetSize(SIZE, SIZE)
    f:SetPoint("LEFT", h, "LEFT", buff.slot * (SIZE + GAP), 0)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    Theme.Backdrop(f, "plain", 0.8)
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetPoint("TOPLEFT", f, "TOPLEFT", 2, -2)
    f.icon:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
    local tex = ns.Call("C_Spell.GetSpellTexture", buff.icon or buff.spellIDs[1])
    pcall(f.icon.SetTexture, f.icon, ns.Plain(tex) or "Interface\\Icons\\INV_Misc_QuestionMark")
    pcall(f.icon.SetTexCoord, f.icon, 0.08, 0.92, 0.08, 0.92)
    f.count = Theme.NewText(f, { size = 12, justify = "RIGHT", color = Theme.C.warn, oneLine = true, outline = "OUTLINE" })
    f.count:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 2)
    -- either icon drags the holder, so the two move together
    f:SetScript("OnDragStart", function()
        if IsShiftKeyDown() or not ns.db.ui.locked then h:StartMoving() end
    end)
    f:SetScript("OnDragStop", function()
        h:StopMovingOrSizing()
        local point, _, _, x, y = h:GetPoint(1)
        cfg().point = { point = point or "CENTER", x = x or 0, y = y or 0 }
    end)
    f:SetScript("OnEnter", tooltip)
    f:SetScript("OnLeave", function() local tt = rawget(_G, "GameTooltip") if tt then tt:Hide() end end)
    f:Hide()
    return f
end

--- Show the icons whose buff is missing; an unreadable aura leaves its icon as it was.
function XB:Refresh()
    self.frames = self.frames or {}
    for _, key in ipairs(self.ORDER) do
        local show, stacks, needed = self:Missing(key)
        if show ~= nil then
            local f = self.frames[key]
            if show and not f then
                f = newIndicator(key)
                self.frames[key] = f
            end
            if f then
                f.stacks = stacks
                f.count:SetText(show and needed > 1 and string.format("%d/%d", stacks, needed) or "")
                f:SetShown(show)
            end
        end
    end
end

--- Put the icons back where they start (/fg remind buffs reset).
function XB:ResetPositions()
    cfg().point = nil
    if self.holder then place(self.holder) end
end

-- ---- events -----------------------------------------------------------------------------

local function soon() ns.Events:Debounce("xpbuffs", 0.5, function() XB:Refresh() end) end

function XB:OnInit()
    ns.Events:Register("UNIT_AURA", function(_, unit)
        local u = ns.PlainString(unit)
        if u == nil or u == "player" then soon() end
    end)
    ns.Events:Register("FG_LEVEL_CHANGED", soon)
end

function XB:OnEnterWorld()
    soon()
    if not self.ticker then
        self.ticker = true
        local function beat()
            XB:Refresh()
            ns.Events:After(RECHECK, beat)
        end
        ns.Events:After(RECHECK, beat)
    end
end
