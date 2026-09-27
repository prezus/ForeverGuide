-- ============================================================
-- ForeverGuide / Share.lua
-- /fg share: turns what the player chose to collect (Recorder.lua, Harvest.lua, /fg wrong
-- reports) into one string to paste into the ForeverGuide feedback form. No script, no
-- file hunting, nothing sent by the addon.
--
-- Only fields on the allowlist below leave the game: the JSON is written by walking the
-- allowlist, so anything else in the store (or planted in it) is never read. The allowlist
-- is documented field by field in docs/SHARE-FORMAT.md; the tests keep the two in step.
--
-- The string: "FG2:<part>/<parts>:<base64 of the zlib-compressed JSON>", split into parts
-- of at most PART_MAX characters. A client without C_EncodingUtil gives "FG2J:..." with
-- the JSON itself. Preview shows the readable JSON the string holds.
-- ============================================================

local _, ns = ...
local Share = ns:NewModule("Share")

local PlainNumber, PlainString, PlainBool = ns.PlainNumber, ns.PlainString, ns.PlainBool

local FORMAT = 2
Share.PART_MAX = 50000    -- the feedback form takes 60,000 characters

-- ---- the allowlist ----------------------------------------------------------------
-- A spec is "int" | "num" | "bool" | Str(max) | List(spec, max) | Map(spec, max) | Obj{ {key, spec}, ... }.
-- Map keys are integer ids (JSON object keys); Obj fields are written in the listed order.
local function Str(max) return { kind = "str", max = max } end
local function List(spec, max) return { kind = "list", of = spec, max = max } end
local function Map(spec, max) return { kind = "map", of = spec, max = max } end
local function Obj(fields) return { kind = "obj", fields = fields } end

local CELL = List("num", 2)
local IDS = List("int", 50)
local SCHEMA = Obj {
    { "format", "int" },
    { "addon", Str(20) },
    { "build", Str(30) },
    { "profile", Obj { { "race", Str(20) }, { "class", Str(20) }, { "faction", Str(20) } } },
    { "quests", Map(Obj {
        { "name", Str(120) },
        { "level", "int" },
        { "givers", IDS },
        { "enders", IDS },
        { "startItem", "int" },
        { "offeredAt", List("int", 2) },
        { "shared", "bool" },
        { "objectives", Map(Obj {
            { "text", Str(160) },
            { "cells", Map(List(CELL, 24), 20) },
            { "targets", Map("int", 20) },
        }, 20) },
    }, 2000) },
    { "npcs", Map(Obj {
        { "name", Str(80) },
        { "level", "int" },
        { "cells", Map(List(CELL, 12), 20) },
    }, 2000) },
    { "order", List("int", 1000) },
    { "maps", Map(Obj { { "name", Str(80) }, { "parent", "int" }, { "bounds", List("num", 5) } }, 500) },
    { "starts", Map(Obj { { "map", "int" }, { "x", "num" }, { "y", "num" }, { "line", "int" } }, 3000) },
    { "titles", Map(Str(120), 3000) },
    { "errors", List(Obj {
        { "key", Str(120) }, { "message", Str(300) }, { "guide", Str(80) }, { "step", "int" }, { "map", "int" },
    }, 50) },
    { "reports", List(Obj {
        { "type", Str(40) }, { "mode", Str(20) }, { "what", Str(40) },
        { "guide", Str(80) }, { "step", "int" }, { "q", "int" },
        { "text", Str(200) }, { "title", Str(120) }, { "questLevel", "int" }, { "ready", "bool" }, { "failed", "bool" },
        { "m", "int" }, { "x", "num" }, { "y", "num" }, { "zone", Str(80) }, { "sub", Str(80) }, { "lvl", "int" },
        { "npc", "int" }, { "npcName", Str(80) }, { "npcStep", "int" },
        { "loc", Obj { { "m", "int" }, { "x", "num" }, { "y", "num" }, { "id", "int" }, { "kind", Str(20) } } },
        { "objectives", List(Obj {
            { "text", Str(160) }, { "numFulfilled", "int" }, { "numRequired", "int" }, { "finished", "bool" },
        }, 20) },
    }, 300) },
}

--- Every allowlisted field as a path ("quests.*.givers[]"), in schema order.
function Share:Paths()
    local out = {}
    local function walk(spec, path)
        if type(spec) == "table" and spec.kind == "obj" then
            for _, f in ipairs(spec.fields) do walk(f[2], path == "" and f[1] or (path .. "." .. f[1])) end
        elseif type(spec) == "table" and spec.kind == "map" then
            walk(spec.of, path .. ".*")
        elseif type(spec) == "table" and spec.kind == "list" then
            walk(spec.of, path .. "[]")
        else
            out[#out + 1] = path
        end
    end
    walk(SCHEMA, "")
    return out
end

-- ---- JSON, written by walking the allowlist -----------------------------------------
local ESCAPES = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
local function Quote(s)
    return '"' .. s:gsub('[%c"\\]', function(c) return ESCAPES[c] or string.format("\\u%04x", c:byte()) end) .. '"'
end

local function Finite(n) return n == n and n ~= math.huge and n ~= -math.huge end

local function IntKey(k)
    k = PlainNumber(k)
    return k and Finite(k) and k == math.floor(k) and k or nil
end

-- JSON text for value under spec, or nil when nothing allowed is there. indent: nil = compact.
local function Write(value, spec, indent, depth)
    if spec == "int" then
        local n = PlainNumber(value)
        return n and Finite(n) and n == math.floor(n) and string.format("%d", n) or nil
    elseif spec == "num" then
        local n = PlainNumber(value)
        return n and Finite(n) and string.format("%.14g", n) or nil
    elseif spec == "bool" then
        local b = PlainBool(value)
        return b ~= nil and tostring(b) or nil
    elseif spec.kind == "str" then
        local s = PlainString(value)
        return s and Quote(s:sub(1, spec.max)) or nil
    end
    if type(value) ~= "table" then return nil end
    local items, keys = {}, {}
    if spec.kind == "list" then
        for i = 1, math.min(#value, spec.max) do
            local v = Write(value[i], spec.of, indent, depth + 1)
            if v then items[#items + 1] = v end
        end
    elseif spec.kind == "map" then
        local ids = {}
        for k in pairs(value) do
            local id = IntKey(k)
            if id then ids[#ids + 1] = id end
        end
        table.sort(ids)
        for _, id in ipairs(ids) do
            if #items >= spec.max then break end
            local v = Write(value[id], spec.of, indent, depth + 1)
            if v then items[#items + 1] = v keys[#items] = string.format("%d", id) end
        end
    else -- obj
        for _, f in ipairs(spec.fields) do
            local v = Write(value[f[1]], f[2], indent, depth + 1)
            if v then items[#items + 1] = v keys[#items] = f[1] end
        end
    end
    if #items == 0 then return nil end
    local open, close = spec.kind == "list" and "[" or "{", spec.kind == "list" and "]" or "}"
    local sep, pad, endpad, colon = ",", "", "", ":"
    if indent then
        pad = "\n" .. string.rep(indent, depth + 1)
        endpad = "\n" .. string.rep(indent, depth)
        sep, colon = ",", ": "
    end
    for i, v in ipairs(items) do
        items[i] = pad .. (keys[i] and (Quote(keys[i]) .. colon) or "") .. v
    end
    return open .. table.concat(items, sep) .. endpad .. close
end

-- ---- what is shared -----------------------------------------------------------------
local function Build()
    local UnitRace, UnitClass, UnitFactionGroup = rawget(_G, "UnitRace"), rawget(_G, "UnitClass"), rawget(_G, "UnitFactionGroup")
    local version, build = ns.Safe(rawget(_G, "GetBuildInfo"))
    local c = ns.db.contrib
    -- quest-line starts and titles Harvest found: only for quests the bundled database lacks
    local starts, titles = {}, {}
    local lines = ns.db.harvest and ns.db.harvest.lines
    for id, l in pairs(type(lines) == "table" and lines or {}) do
        if type(l) == "table" then starts[id] = { map = l.map, x = l.x, y = l.y, line = l.line } end
    end
    local known = ns.db.scan and ns.db.scan.quests
    for id, title in pairs(type(known) == "table" and known or {}) do
        local q = ns.DB and ns.DB:GetQuest(id)
        if not (q and q.n) then titles[id] = title end
    end
    return {
        format = FORMAT,
        addon = ns.version,
        build = PlainString(version) and PlainString(build) and (PlainString(version) .. "." .. PlainString(build)) or nil,
        profile = {
            race = select(2, ns.Safe(UnitRace, "player")),
            class = select(2, ns.Safe(UnitClass, "player")),
            faction = ns.Safe(UnitFactionGroup, "player"),
        },
        quests = c.quests, npcs = c.npcs, order = c.order, maps = c.maps, errors = c.errors,
        starts = starts, titles = titles, reports = ns.db.reports,
    }
end

--- The share as JSON (pretty = readable, for the preview).
function Share:Json(pretty)
    return Write(Build(), SCHEMA, pretty and "  " or nil, 0) or "{}"
end

--- The share strings to paste, one per part.
function Share:Strings()
    local json = self:Json()
    local tag, payload = "FG2J", json
    local E = rawget(_G, "C_EncodingUtil")
    if E and type(E.CompressString) == "function" and type(E.EncodeBase64) == "function" then
        local enum = rawget(_G, "Enum")
        local zlib = enum and enum.CompressionMethod and enum.CompressionMethod.Zlib or 1
        local ok, packed = pcall(E.CompressString, json, zlib)
        local ok2, text = false, nil
        if ok and type(packed) == "string" then ok2, text = pcall(E.EncodeBase64, packed) end
        if ok2 and type(text) == "string" then tag, payload = "FG2", text end
    end
    -- every part carries "TAG:i/n:"; size the slices so the whole part fits PART_MAX
    local parts, size = {}, self.PART_MAX - 20
    local n = math.max(1, math.ceil(#payload / size))
    for i = 1, n do
        parts[i] = string.format("%s:%d/%d:%s", tag, i, n, payload:sub((i - 1) * size + 1, i * size))
    end
    return parts
end

-- ---- the window ---------------------------------------------------------------------
local WINDOW = "ForeverGuideShare"

local function Title(win)
    if win.showPreview then return "Share data: preview" end
    return #win.parts == 1 and "Share data" or string.format("Share data (part %d/%d)", win.part, #win.parts)
end

local function Render(win)
    local text = win.showPreview and win.preview.json or win.parts[win.part]
    ns.Reports:ShowText(WINDOW, "Share data", text)
    win.heading:SetText(Title(win))
    win.preview.label:SetText(win.showPreview and "Share string" or "Preview")
    if #win.parts > 1 and not win.showPreview then win.nextPart:Show() else win.nextPart:Hide() end
end

--- Open the share window with a fresh string.
function Share:Show()
    local win = ns.Reports:ShowText(WINDOW, "Share data", "")
    if not win.preview then
        local Theme = ns.Theme
        win.preview = Theme.NewButton(win, "Preview", 96, 22, function()
            win.showPreview = not win.showPreview
            Render(win)
        end)
        win.preview:SetPoint("RIGHT", win.selectAll, "LEFT", -8, 0)
        win.nextPart = Theme.NewButton(win, "Next part", 86, 22, function()
            win.part = win.part % #win.parts + 1
            Render(win)
        end)
        win.nextPart:SetPoint("RIGHT", win.preview, "LEFT", -8, 0)
    end
    win.parts, win.part, win.showPreview = self:Strings(), 1, false
    win.preview.json = self:Json(true)
    Render(win)
    local quests, npcs = ns.Recorder:Counts()
    ns.Printf("share: %d quests, %d NPCs, %d reports in %d part%s. Copy each part (Ctrl+C) into the feedback form.",
        quests, npcs, #(ns.db.reports or {}), #win.parts, #win.parts == 1 and "" or "s")
end
