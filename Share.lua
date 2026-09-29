-- ============================================================
-- ForeverGuide / Share.lua
-- /fg share: turns what the player chose to collect (Recorder.lua, Harvest.lua, /fg wrong
-- reports) into one string to paste into the ForeverGuide feedback form. No script, no
-- file hunting, nothing sent by the addon.
--
-- Only fields on the allowlist below leave the game: a filtered copy is made by walking the
-- allowlist, so anything else in the store (or planted in it) is never read, and the string,
-- the JSON view and the readable summary are all made from that copy. The allowlist is
-- documented in docs/SHARE-FORMAT.md and published as docs/share-format.schema.json (JSON
-- Schema); the tests keep all three in step.
--
-- The string: "FG2:<part>/<parts>:<base64 of the zlib-compressed JSON>", split into parts
-- of at most PART_MAX characters: standard formats, so anyone can decode it without our
-- code. A client without C_EncodingUtil gives "FG2J:..." with the JSON itself.
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
        { "race", Str(20) }, { "class", Str(20) }, { "faction", Str(20) },
        { "loc", Obj { { "m", "int" }, { "x", "num" }, { "y", "num" }, { "id", "int" }, { "kind", Str(20) } } },
        { "objectives", List(Obj {
            { "text", Str(160) }, { "numFulfilled", "int" }, { "numRequired", "int" }, { "finished", "bool" },
        }, 20) },
    }, 300) },
    -- one segment of a recorded run (Run.lua); a segment share carries it instead of the facts
    { "run", Obj {
        { "id", Str(16) }, { "seg", "int" }, { "done", "bool" },
        { "entries", List(Obj {
            { "e", Str(10) }, { "t", "num" }, { "lvl", "int" }, { "m", "int" }, { "x", "num" }, { "y", "num" },
            { "g", Str(80) }, { "s", "int" },
            { "q", "int" }, { "xp", "int" }, { "money", "int" },
            { "obj", "int" }, { "f", "int" }, { "r", "int" }, { "done", "bool" },
            { "l", "int" }, { "rested", "int" },
            { "npc", "int" }, { "mobLevel", "int" }, { "elite", "bool" }, { "secs", "num" },
            { "mounted", "bool" }, { "taxi", "bool" }, { "cost", "int" },
            { "action", Str(10) },
        }, 2500) },
    } },
}

Share.SCHEMA = SCHEMA   -- tools/share_schema.lua turns it into docs/share-format.schema.json

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

-- ---- filtering: the allowlisted copy ---------------------------------------------------
local function Finite(n) return n == n and n ~= math.huge and n ~= -math.huge end

local function IntKey(k)
    k = PlainNumber(k)
    return k and Finite(k) and k == math.floor(k) and k or nil
end

-- The part of value that spec allows, as a fresh table; nil when nothing allowed is there.
-- The JSON and the readable summary are both made from this copy, never from the store.
local function Filter(value, spec)
    if spec == "int" then
        local n = PlainNumber(value)
        return n and Finite(n) and n == math.floor(n) and n or nil
    elseif spec == "num" then
        local n = PlainNumber(value)
        return n and Finite(n) and n or nil
    elseif spec == "bool" then
        return PlainBool(value)
    elseif spec.kind == "str" then
        local str = PlainString(value)
        return str and ns.Utf8Sub(str, spec.max) or nil
    end
    if type(value) ~= "table" then return nil end
    local out, n = {}, 0
    if spec.kind == "list" then
        for i = 1, math.min(#value, spec.max) do
            local v = Filter(value[i], spec.of)
            if v ~= nil then n = n + 1 out[n] = v end
        end
    elseif spec.kind == "map" then
        local ids = {}
        for k in pairs(value) do
            local id = IntKey(k)
            if id then ids[#ids + 1] = id end
        end
        table.sort(ids)
        for _, id in ipairs(ids) do
            if n >= spec.max then break end
            local v = Filter(value[id], spec.of)
            if v ~= nil then n = n + 1 out[id] = v end
        end
    else -- obj
        for _, f in ipairs(spec.fields) do
            local v = Filter(value[f[1]], f[2])
            if v ~= nil then n = n + 1 out[f[1]] = v end
        end
    end
    return n > 0 and out or nil
end

-- ---- JSON --------------------------------------------------------------------------
local ESCAPES = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
local function Quote(str)
    return '"' .. str:gsub('[%c"\\]', function(c) return ESCAPES[c] or string.format("\\u%04x", c:byte()) end) .. '"'
end

local function SortedIds(t)
    local ids = {}
    for id in pairs(t) do ids[#ids + 1] = id end
    table.sort(ids)
    return ids
end

-- JSON text of an already filtered value. indent: nil = compact.
local function Encode(value, spec, indent, depth)
    if spec == "int" then return string.format("%d", value) end
    if spec == "num" then return string.format("%.14g", value) end
    if spec == "bool" then return tostring(value) end
    if spec.kind == "str" then return Quote(value) end
    local items, keys = {}, {}
    if spec.kind == "list" then
        for i, v in ipairs(value) do items[i] = Encode(v, spec.of, indent, depth + 1) end
    elseif spec.kind == "map" then
        for _, id in ipairs(SortedIds(value)) do
            items[#items + 1] = Encode(value[id], spec.of, indent, depth + 1)
            keys[#items] = string.format("%d", id)
        end
    else -- obj
        for _, f in ipairs(spec.fields) do
            if value[f[1]] ~= nil then
                items[#items + 1] = Encode(value[f[1]], f[2], indent, depth + 1)
                keys[#items] = f[1]
            end
        end
    end
    local open, close = spec.kind == "list" and "[" or "{", spec.kind == "list" and "]" or "}"
    local pad, endpad, colon = "", "", ":"
    if indent then
        pad = "\n" .. string.rep(indent, depth + 1)
        endpad = "\n" .. string.rep(indent, depth)
        colon = ": "
    end
    for i, v in ipairs(items) do
        items[i] = pad .. (keys[i] and (Quote(keys[i]) .. colon) or "") .. v
    end
    return open .. table.concat(items, ",") .. endpad .. close
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

--- The allowlisted copy of what would be shared.
function Share:Doc()
    return Filter(Build(), SCHEMA) or {}
end

--- The allowlisted copy of a run segment's share (Run.lua): the profile, the maps its entries
--- stand on, and the segment. The contributed facts and reports stay out of it.
function Share:RunDoc(segment)
    local doc = Build()
    local maps = {}
    for _, e in ipairs(segment.entries or {}) do
        local m = PlainNumber(e.m)
        if m and not maps[m] then maps[m] = ns.Recorder:MapInfo(m) end
    end
    return Filter({ format = doc.format, addon = doc.addon, build = doc.build, profile = doc.profile, maps = maps,
        run = segment }, SCHEMA) or {}
end

--- The share as JSON (pretty = indented, for the JSON view).
function Share:Json(pretty, doc)
    return Encode(doc or self:Doc(), SCHEMA, pretty and "  " or nil, 0)
end

--- The share strings to paste, one per part.
function Share:Strings(doc)
    local json = self:Json(false, doc)
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

-- ---- the readable summary -----------------------------------------------------------
local function Num(n) return string.format("%.14g", n) end

-- "Scourge Rogue, Horde": a race token, a class token read as a word, and a faction.
local function Who(race, class, faction)
    local word = class and (class:sub(1, 1) .. class:sub(2):lower())
    return string.format("%s %s, %s", race or "?", word or "?", faction or "?")
end

local function MapName(doc, mapID)
    local m = doc.maps and doc.maps[mapID]
    return m and m.name and (m.name .. " (" .. mapID .. ")") or ("map " .. mapID)
end

local function NpcName(doc, npcID)
    local n = doc.npcs and doc.npcs[npcID]
    return (n and n.name or "creature") .. " (" .. npcID .. ")"
end

-- "Elwynn Forest (1429) 48.5, 41.5; 49, 40 (+3 more)" for { [mapID] = { {x, y}, ... } }
local function Spots(doc, cells)
    local out = {}
    for _, mapID in ipairs(SortedIds(cells)) do
        local list, shown = cells[mapID], {}
        for i = 1, math.min(#list, 3) do shown[i] = Num(list[i][1]) .. ", " .. Num(list[i][2]) end
        out[#out + 1] = MapName(doc, mapID) .. " " .. table.concat(shown, "; ")
            .. (#list > 3 and string.format(" (+%d more)", #list - 3) or "")
    end
    return table.concat(out, " | ")
end

local function Count(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

--- What the share holds, in words: built from the allowlisted copy, so it shows exactly the
--- string's content and nothing else.
function Share:Summary(doc)
    doc = doc or self:Doc()
    local L = {}
    local function add(fmt, ...) L[#L + 1] = select("#", ...) > 0 and string.format(fmt, ...) or fmt end
    local function names(ids)
        local out = {}
        for i, id in ipairs(ids) do out[i] = NpcName(doc, id) end
        return table.concat(out, ", ")
    end
    add("WHAT THIS SHARE CONTAINS")
    add("Everything below is in the share string, and nothing else is.")
    add("Never included: other players, your character name, realm or account, GUIDs, chat, or the date and time of day.")
    add("To check it yourself: the string is base64 of zlib-compressed JSON. docs/SHARE-FORMAT.md in the")
    add("ForeverGuide repository shows how to decode it with common tools and validate it against its schema.")
    add("")
    local p = doc.profile or {}
    add("About you: %s. ForeverGuide %s, game build %s.", Who(p.race, p.class, p.faction), doc.addon or "?", doc.build or "?")
    local function section(title, n, what)
        add("")
        add("%s (%d) - %s", title, n, what)
    end
    local quests = doc.quests or {}
    section("QUESTS", Count(quests), "who gives and takes each quest, and where its objectives moved")
    for _, id in ipairs(SortedIds(quests)) do
        local q = quests[id]
        add("[%d] %s%s", id, q.name or "(no title)", q.level and (" (level " .. q.level .. ")") or "")
        if q.givers then add("  Given by: %s", names(q.givers)) end
        if q.enders then add("  Turned in to: %s", names(q.enders)) end
        if q.startItem then add("  Started from item %d", q.startItem) end
        if q.offeredAt then
            local lo, hi = q.offeredAt[1], q.offeredAt[2] or q.offeredAt[1]
            add("  Offered to you at level %s", lo == hi and lo or (lo .. "-" .. hi))
        end
        if q.shared then add("  Shared with you by a group member (who is not recorded)") end
        for _, idx in ipairs(SortedIds(q.objectives or {})) do
            local o = q.objectives[idx]
            add("  Objective %d: %s", idx, o.text or "(no text)")
            if o.cells then add("    Where it moved: %s", Spots(doc, o.cells)) end
            if o.targets then
                local votes = {}
                for _, npcID in ipairs(SortedIds(o.targets)) do
                    votes[#votes + 1] = NpcName(doc, npcID) .. " x" .. o.targets[npcID]
                end
                add("    Targeted when it moved: %s", table.concat(votes, ", "))
            end
        end
    end
    local npcs = doc.npcs or {}
    section("NPCS", Count(npcs), "creatures you talked to or targeted, and where you met them")
    for _, id in ipairs(SortedIds(npcs)) do
        local n = npcs[id]
        add("%s%s%s", NpcName(doc, id), n.level and (", level " .. n.level) or "", n.cells and (": " .. Spots(doc, n.cells)) or "")
    end
    if doc.order then
        local steps = {}
        for i, v in ipairs(doc.order) do steps[i] = (v < 0 and "turned in " or "accepted ") .. math.abs(v) end
        section("ORDER THIS SESSION", #steps, "the order you took and handed in quests, without times")
        add(table.concat(steps, ", "))
    end
    if doc.maps then
        section("MAPS", Count(doc.maps), "the maps you were on")
        for _, id in ipairs(SortedIds(doc.maps)) do
            local m = doc.maps[id]
            add("%s%s", MapName(doc, id), m.parent and (", inside " .. MapName(doc, m.parent)) or "")
        end
    end
    if doc.starts then
        section("QUEST STARTS", Count(doc.starts), "quest markers your world map showed")
        for _, id in ipairs(SortedIds(doc.starts)) do
            local st = doc.starts[id]
            add("[%d] %s %s, %s%s", id, st.map and MapName(doc, st.map) or "?", st.x and Num(st.x) or "?",
                st.y and Num(st.y) or "?", st.line and (" (quest line " .. st.line .. ")") or "")
        end
    end
    if doc.titles then
        section("QUEST TITLES", Count(doc.titles), "names of quests the addon's database does not know yet")
        for _, id in ipairs(SortedIds(doc.titles)) do add("[%d] %s", id, doc.titles[id]) end
    end
    if doc.errors then
        section("ADDON ERRORS", #doc.errors, "ForeverGuide errors, so they can be fixed")
        for _, e in ipairs(doc.errors) do
            add("%s: %s (guide %s, step %s, map %s)", e.key or "?", e.message or "?", e.guide or "-",
                tostring(e.step or "-"), tostring(e.map or "-"))
        end
    end
    if doc.run then
        local entries, kinds, order = doc.run.entries or {}, {}, {}
        for _, e in ipairs(entries) do
            local k = e.e or "?"
            if not kinds[k] then kinds[k] = 0 order[#order + 1] = k end
            kinds[k] = kinds[k] + 1
        end
        section("RUN SEGMENT", #entries, "a timed log of what you did while the run recorded")
        add("Run %s, segment %d%s.", doc.run.id or "?", doc.run.seg or 0, doc.run.done and " (the last one)" or "")
        add("Times count seconds of recording since the run started, never the clock: this segment covers %s to %s s.",
            entries[1] and Num(entries[1].t or 0) or "0", entries[#entries] and Num(entries[#entries].t or 0) or "0")
        local counts = {}
        for i, k in ipairs(order) do counts[i] = k .. " x" .. kinds[k] end
        add("Entries: %s", table.concat(counts, ", "))
        add("Each entry has your level, map position and guide step; JSON shows every one.")
    end
    if doc.reports then
        section("YOUR REPORTS", #doc.reports, "what you reported with /fg wrong")
        for i, r in ipairs(doc.reports) do
            add("%d. %s", i, r.text and ('"' .. r.text .. '"') or (r.title or r.type or "report"))
            local parts = {}
            if r.guide then parts[#parts + 1] = "guide " .. r.guide .. " step " .. tostring(r.step or "?") end
            if r.type then parts[#parts + 1] = r.type end
            if r.q then parts[#parts + 1] = "quest " .. r.q end
            if r.m then parts[#parts + 1] = "at " .. MapName(doc, r.m) .. " " .. Num(r.x or 0) .. ", " .. Num(r.y or 0) end
            if r.lvl then parts[#parts + 1] = "level " .. r.lvl end
            if r.race then parts[#parts + 1] = "as " .. Who(r.race, r.class, r.faction) end
            if r.npc then parts[#parts + 1] = "target " .. (r.npcName or "creature") .. " (" .. r.npc .. ")" end
            add("   %s", table.concat(parts, ", "))
        end
    end
    return table.concat(L, "\n")
end

-- ---- the window ---------------------------------------------------------------------
local WINDOW = "ForeverGuideShare"
local VIEWS = {   -- button order, right to left from "Select all"
    { key = "json", label = "JSON", width = 60 },
    { key = "readable", label = "Readable", width = 80 },
    { key = "string", label = "Share string", width = 96 },
}

local function Render(win)
    local text, title
    if win.view == "readable" then
        text, title = win.summary, "Share data: what it holds"
    elseif win.view == "json" then
        text, title = win.json, "Share data: JSON"
    else
        text = win.parts[win.part]
        title = #win.parts == 1 and "Share data" or string.format("Share data (part %d/%d)", win.part, #win.parts)
    end
    ns.Reports:ShowText(WINDOW, "Share data", text)
    win.heading:SetText(title)
    for key, button in pairs(win.views) do
        button.label:SetText((key == win.view and "> " or "") .. button.plainLabel)
    end
    if #win.parts > 1 and win.view == "string" then win.nextPart:Show() else win.nextPart:Hide() end
end

local function Open(doc)
    local win = ns.Reports:ShowText(WINDOW, "Share data", "")
    if not win.views then
        local Theme = ns.Theme
        win.views = {}
        local anchor = win.selectAll
        for _, v in ipairs(VIEWS) do
            local button = Theme.NewButton(win, v.label, v.width, 22, function()
                win.view = v.key
                Render(win)
            end)
            button.plainLabel = v.label
            button:SetPoint("RIGHT", anchor, "LEFT", -6, 0)
            win.views[v.key], anchor = button, button
        end
        win.nextPart = Theme.NewButton(win, "Next part", 80, 22, function()
            win.part = win.part % #win.parts + 1
            Render(win)
        end)
        win.nextPart:SetPoint("RIGHT", anchor, "LEFT", -6, 0)
    end
    win.parts, win.part, win.view = Share:Strings(doc), 1, "string"
    win.summary, win.json = Share:Summary(doc), Share:Json(true, doc)
    Render(win)
    return win
end

--- Open the share window with a fresh string.
function Share:Show()
    local win = Open(self:Doc())
    local quests, npcs = ns.Recorder:Counts()
    ns.Printf("share: %d quests, %d NPCs, %d reports in %d part%s. Copy each part (Ctrl+C) into the feedback form; "
        .. "Readable shows what it holds.", quests, npcs, #(ns.db.reports or {}), #win.parts, #win.parts == 1 and "" or "s")
end

--- Open the share window with one segment of a recorded run (Run.lua).
function Share:ShowRun(segment)
    local win = Open(self:RunDoc(segment))
    ns.Printf("run segment %d: %d entries in %d part%s. Copy each part (Ctrl+C) into the feedback form%s; "
        .. "Readable shows what it holds.", segment.seg or 0, #(segment.entries or {}), #win.parts, #win.parts == 1 and "" or "s",
        segment.done and " - this is the run's last segment" or "")
end
