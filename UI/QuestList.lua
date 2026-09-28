-- ============================================================
-- ForeverGuide / UI/QuestList.lua
-- The vertical list of rows, stacked top-down. The list is as tall as all
-- its entries, but only the entries in view (SetView) are bound to a row
-- frame from a small pool: WoW never frees a frame, and a guide is a few
-- hundred steps. Distances refreshed on a throttle, rows only re-set when
-- the entries or the part in view change.
-- ============================================================

local _, ns = ...
local Theme = ns.Theme
local Row = ns.QuestRow
local List = {}
ns.QuestList = List

local GAP = 3
local MARGIN = 60       -- rows this far outside the view are bound too, so a scroll shows no gap

function List.Create(parent)
    local l = CreateFrame("Frame", nil, parent)
    l.rows = {}          -- the pool; rows[k] shows entries[l.first + k - 1]
    l.entries = {}
    l.tops, l.heights = {}, {}
    l.height = 0
    l.Set = List.Set
    l.Layout = List.Layout
    l.SetView = List.SetView
    l.RowFor = List.RowFor
    l.UpdateDistances = List.UpdateDistances
    l.empty = Theme.NewText(l, { size = 11, color = Theme.C.textDim, justify = "CENTER", maxLines = 3 })
    l.empty:SetPoint("TOPLEFT", l, "TOPLEFT", 14, -10)
    l.empty:SetPoint("TOPRIGHT", l, "TOPRIGHT", -14, -10)
    l.empty:Hide()
    return l
end

local function row(l, k)
    local r = l.rows[k]
    if not r then
        r = Row.Create(l, k)
        l.rows[k] = r
    end
    return r
end

--- The entries within the view (all of them while the owner has set none).
local function range(l)
    local n = #l.entries
    if n == 0 then return 1, 0 end
    if not l.viewTop then return 1, n end
    local from, to = l.viewTop - MARGIN, l.viewBottom + MARGIN
    local first, last = nil, 0
    for i = 1, n do
        local top = l.tops[i]
        if top > to then break end
        if top + l.heights[i] >= from then
            first = first or i
            last = i
        end
    end
    if not first then return 1, 0 end
    return first, last
end

--- Give the entries in view their rows; the rest of the pool is hidden.
local function bind(l, force)
    local first, last = range(l)
    if not force and first == l.first and last == l.last then return end
    l.first, l.last = first, last
    local showSub = ns.db.ui.showSubtitles ~= false
    local k = 0
    for i = first, last do
        k = k + 1
        local r = row(l, k)
        r:Set(l.entries[i], showSub)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", l, "TOPLEFT", 2, -l.tops[i])
        r:SetPoint("TOPRIGHT", l, "TOPRIGHT", -2, -l.tops[i])
        r.top = l.tops[i]
        r:Show()
    end
    for j = k + 1, #l.rows do l.rows[j]:Hide() l.rows[j].entry = nil end
end

--- The row showing entry i, or nil while it is out of view.
function List.RowFor(l, i)
    if not l.first or i < l.first or i > l.last then return nil end
    return l.rows[i - l.first + 1]
end

--- entries: list of row entries (see QuestRow.Set). emptyText shown when there are none.
function List.Set(l, entries, emptyText)
    l.entries = entries or {}
    if #l.entries == 0 then
        l.empty:SetText(emptyText or "")
        l.empty:Show()
    else
        l.empty:Hide()
    end
    l:Layout()
    bind(l, true)
    l:UpdateDistances(true)
end

--- Where each entry sits (tops / heights), from the entries alone, and the list's height.
function List.Layout(l)
    local showSub = ns.db.ui.showSubtitles ~= false
    local y = 4
    l.tops, l.heights = {}, {}
    for i, e in ipairs(l.entries) do
        local h = Row.HeightFor(e, showSub)
        l.tops[i], l.heights[i] = y, h
        y = y + h + GAP
    end
    if #l.entries == 0 then y = y + 40 end
    l.height = y + 2
    l:SetHeight(l.height)
end

--- The owner says which part of the list is on screen (list coordinates, top down).
function List.SetView(l, top, bottom)
    l.viewTop, l.viewBottom = top, bottom
    bind(l, false)
end

--- Distances: the active row shows the navigation distance, the others their own. Only the rows
--- in view work one out: each one resolves a location.
function List.UpdateDistances(l, force)
    if not l.first then return end
    if ns.db.ui.showDistances == false then
        for i = l.first, l.last do l:RowFor(i):SetDistance("") end
        return
    end
    local Nav, DB = ns.Navigation, ns.DB
    for i = l.first, l.last do
        local e, r = l.entries[i], l:RowFor(i)
        local text
        if e.state == "active" and Nav.target and Nav.state and Nav.state.distance then
            text = Nav:FormatDistance(Nav.state.distance)
        elseif e.distanceText then
            text = e.distanceText
        elseif e.step and DB and DB:IsLoaded() then
            if e._loc == nil or force then
                local map, x, y, _, loc = Nav:ResolveStep(e.step)
                e._loc = (map and { map = map, x = x, y = y }) or loc or false
            end
            local d = e._loc and DB:DistanceTo(e._loc)
            text = d and Nav:FormatDistance(d) or ""
        elseif e.loc then
            local d = DB and DB:DistanceTo(e.loc)
            text = d and Nav:FormatDistance(d) or ""
        end
        r:SetDistance(text or "")
    end
end
