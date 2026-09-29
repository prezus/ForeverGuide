-- ============================================================
-- ForeverGuide / tools/pack_data.lua
-- Pack the full data tables (data-src/tables/*.lua, published by the maintainer's data build,
-- or written by merge_recorded.py / import_rxp.py) into
-- the addon's Data/*.lua:
--
--     lua5.1 tools/pack_data.lua            write Data/
--     lua5.1 tools/pack_data.lua --check    fail when Data/ is not what the tables pack to
--
-- The Forever overlay is merged here, once, instead of by the addon at every login. Every
-- quest, NPC, object and item record is then written as one Lua table-constructor string,
-- which the addon decodes the first time it is read (DB.lua): about a fifth of the memory
-- the same records take as live tables. The format is Data/README.md, "Storage".
-- ============================================================

local root = (arg and arg[0] or ""):match("^(.*)tools[/\\]pack_data%.lua$") or "./"
if root == "" then root = "./" end
local check = arg[1] == "--check"
local TABLES = root .. "data-src/tables/"
local OUT = root .. "Data/"

-- ---- read the tables ------------------------------------------------------------------
local ns = {}
for _, file in ipairs({ "ZoneDB", "QuestDB", "NpcDB", "ObjectDB", "ItemDB", "ForeverDB", "ForeverQuestIDs", "VanillaQuestIDs" }) do
    local chunk = assert(loadfile(TABLES .. file .. ".lua"))
    chunk("ForeverGuide", ns)
end

-- ---- merge the Forever overlay --------------------------------------------------------
-- Vanilla records only gain what they lack; unknown ids become new records flagged
-- `forever = true`; vanilla quests the client does not have are flagged `removed = true`.
local function AddUnique(list, v)
    for _, x in ipairs(list) do if x == v then return end end
    list[#list + 1] = v
end

local function MergePoints(dst, src)
    if not src then return end
    for map, pts in pairs(src) do
        dst[map] = dst[map] or {}
        for _, p in ipairs(pts) do dst[map][#dst[map] + 1] = p end
    end
end

--- Walks tables in id order, so a list the merge appends to comes out the same every run.
local function sortedPairs(t)
    local keys = {}
    for k in pairs(t or {}) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        if type(a) == type(b) then return a < b end
        return type(a) == "number"
    end)
    local i = 0
    return function()
        i = i + 1
        local k = keys[i]
        if k ~= nil then return k, t[k] end
    end
end

local function applyOverlay(overlay)
    for id, q in pairs(ns.QuestDB) do
        if not ns.ForeverQuestIDs[id] then q.removed = true end
    end
    ns.ZoneDB.mapNames = ns.ZoneDB.mapNames or {}
    ns.ZoneDB.mapParent = ns.ZoneDB.mapParent or {}

    for map, m in sortedPairs(overlay.maps) do
        if m.name then ns.ZoneDB.mapNames[map] = m.name end
        if m.parent then ns.ZoneDB.mapParent[map] = m.parent end
    end

    for id, f in sortedPairs(overlay.npcs) do
        local n = ns.NpcDB[id]
        if not n then
            n = { n = f.n or ("NPC " .. id), min = f.lvl, max = f.lvl, forever = true }
            ns.NpcDB[id] = n
        elseif not n.n and f.n then
            n.n = f.n
        end
        if f.spm then n.spm = n.spm or {} MergePoints(n.spm, f.spm) end
        if f.spw then n.spw = n.spw or {} MergePoints(n.spw, f.spw) end
        for _, q in ipairs(f.starts or {}) do n.starts = n.starts or {} AddUnique(n.starts, q) end
        for _, q in ipairs(f.ends or {}) do n.ends = n.ends or {} AddUnique(n.ends, q) end
    end

    for id, f in sortedPairs(overlay.objects) do
        local o = ns.ObjectDB[id]
        if not o then
            o = { n = f.n or ("Object " .. id), forever = true }
            ns.ObjectDB[id] = o
        end
        if f.spm then o.spm = o.spm or {} MergePoints(o.spm, f.spm) end
        if f.spw then o.spw = o.spw or {} MergePoints(o.spw, f.spw) end
    end

    for id, f in sortedPairs(overlay.quests) do
        local q = ns.QuestDB[id]
        if not q then
            q = { forever = true }
            ns.QuestDB[id] = q
        end
        if f.n and (not q.n or q.n == "") then q.n = f.n end
        if f.lvl and not q.lvl then q.lvl = f.lvl end
        if f.req and not q.req then q.req = f.req end
        if f.zone and not q.zone then q.zone = f.zone end
        if f.xp and not q.xp then q.xp = f.xp end
        if f.classes and q.forever then q.classes = f.classes end
        if f.pre and q.forever and not q.pre then q.pre = f.pre end
        if f.snpc and #f.snpc > 0 and not ((q.snpc and #q.snpc > 0) or (q.sobj and #q.sobj > 0) or (q.sitem and #q.sitem > 0)) then
            q.snpc = {}
            for _, n in ipairs(f.snpc) do AddUnique(q.snpc, n) end
        end
        if f.enpc and #f.enpc > 0 and not ((q.enpc and #q.enpc > 0) or (q.eobj and #q.eobj > 0)) then
            q.enpc = {}
            for _, n in ipairs(f.enpc) do AddUnique(q.enpc, n) end
        end
        -- objective / start evidence is kept separately and only used where vanilla has nothing
        if f.obj then q.fobj = f.obj end
        if f.start then q.fstart = f.start end
        if f.fin then q.ffin = f.fin end
    end
end
applyOverlay(ns.ForeverDB or {})

-- ---- serialise --------------------------------------------------------------------------
--- A number as the shortest text that reads back to the same value.
local function num(v)
    if v == math.floor(v) and math.abs(v) < 2 ^ 53 then return string.format("%d", v) end
    for p = 1, 17 do
        local s = string.format("%." .. p .. "g", v)
        if tonumber(s) == v then return s end
    end
end

local KEYWORDS = {}
for w in ("and break do else elseif end false for function if in local nil not or repeat return then true until while"):gmatch("%a+") do
    KEYWORDS[w] = true
end

--- A value as a Lua constructor: the array part in order, then the other keys sorted.
local function ser(v)
    local t = type(v)
    if t == "number" then return num(v) end
    if t == "string" then return (string.format("%q", v):gsub("\\\n", "\\n")) end
    if t == "boolean" then return tostring(v) end
    assert(t == "table", "cannot pack a " .. t)
    -- the array part is 1..n with no hole (`#` may stop anywhere in a sparse id table)
    local parts, n = {}, 0
    while v[n + 1] ~= nil do n = n + 1 end
    for i = 1, n do parts[#parts + 1] = ser(v[i]) end
    local keys = {}
    for k in pairs(v) do
        if not (type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)) then keys[#keys + 1] = k end
    end
    table.sort(keys, function(a, b)
        if type(a) == type(b) then return a < b end
        return type(a) == "number"
    end)
    for _, k in ipairs(keys) do
        local key = (type(k) == "string" and k:match("^[%a_][%w_]*$") and not KEYWORDS[k]) and k or ("[" .. ser(k) .. "]")
        parts[#parts + 1] = key .. "=" .. ser(v[k])
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

--- A string as a long-bracket literal, at the lowest level its text does not close.
local function longString(s)
    local eq = ""
    while s:find("]" .. eq .. "]", 1, true) do eq = eq .. "=" end
    return "[" .. eq .. "[" .. s .. "]" .. eq .. "]"
end

local function sortedIds(t)
    local ids = {}
    for id in pairs(t) do ids[#ids + 1] = id end
    table.sort(ids)
    return ids
end

local HEADER = "-- AUTO-GENERATED by tools/pack_data.lua from data-src/tables - DO NOT EDIT\n"
    .. "-- Each record is a Lua table constructor in a string, decoded on first use (Data/README.md, \"Storage\").\n"
    .. "local _, ns = ...\n"

--- One Data file: the records as strings under `ns.<name>`, then any `extra` lines.
local function packRecords(name, tbl, source, extra)
    local lines = { HEADER .. "-- " .. source .. "\nns." .. name .. " = {" }
    for _, id in ipairs(sortedIds(tbl)) do
        lines[#lines + 1] = "[" .. id .. "]=" .. longString(ser(tbl[id])) .. ","
    end
    lines[#lines + 1] = "}"
    for _, line in ipairs(extra or {}) do lines[#lines + 1] = line end
    return table.concat(lines, "\n") .. "\n"
end

-- ---- indexes the addon would otherwise build by decoding every quest ----------------------
local function parentZone(areaID)
    local parent, guard = ns.ZoneDB.parent, 0
    while parent and parent[areaID] and guard < 8 do
        areaID = parent[areaID]
        guard = guard + 1
    end
    return areaID
end

local byZone, byItem = {}, {}
for _, id in ipairs(sortedIds(ns.QuestDB)) do
    local q = ns.QuestDB[id]
    if q.zone and q.zone > 0 then
        local z = parentZone(q.zone)
        byZone[z] = byZone[z] or {}
        table.insert(byZone[z], id)
    end
    for _, e in ipairs(q.item or {}) do
        local item = e[1]
        if item then
            byItem[item] = byItem[item] or {}
            AddUnique(byItem[item], id)
        end
    end
end

local counts = ns.ForeverQuestCounts or {}
local files = {
    ["QuestDB.lua"] = packRecords("QuestDB", ns.QuestDB, "quests, Forever overlay merged; ns.QuestIndex: quests by top-level zone and by objective item", {
        "ns.QuestIndex = {",
        "byZone = " .. ser(byZone) .. ",",
        "byItem = " .. ser(byItem) .. ",",
        "}",
    }),
    ["NpcDB.lua"] = packRecords("NpcDB", ns.NpcDB, "quest-relevant NPCs, Forever overlay merged"),
    ["ObjectDB.lua"] = packRecords("ObjectDB", ns.ObjectDB, "quest-relevant objects, Forever overlay merged"),
    ["ItemDB.lua"] = packRecords("ItemDB", ns.ItemDB, "quest-relevant items"),
    ["ZoneDB.lua"] = HEADER .. "-- areaID -> uiMapID, names, sub-zone parents; Forever map names and parents\n"
        .. "ns.ZoneDB = " .. ser(ns.ZoneDB) .. "\n",
    ["ForeverQuestIDs.lua"] = HEADER .. "-- quest ids the client has and Questie does not: /fg scan new walks them\n"
        .. "ns.ForeverNewQuestIDRanges = " .. ser(ns.ForeverNewQuestIDRanges or {}) .. "\n"
        .. string.format("ns.ForeverQuestCounts = { client = %d, new = %d, removed = %d }\n", counts.client or 0, counts.new or 0, counts.removed or 0),
    ["VanillaQuestIDs.lua"] = HEADER .. "-- vanilla quest ids, used by Scanner.lua as throttle canaries\n"
        .. "ns.VanillaQuestIDs = " .. ser(ns.VanillaQuestIDs or {}) .. "\n",
}

-- ---- write or check -------------------------------------------------------------------
local names = sortedIds(files)
local stale = 0
for _, name in ipairs(names) do
    local path = OUT .. name
    if check then
        local fh = io.open(path, "rb")
        local have = fh and fh:read("*a")
        if fh then fh:close() end
        if have ~= files[name] then
            stale = stale + 1
            print("stale " .. path)
        end
    else
        local fh = assert(io.open(path, "wb"))
        fh:write(files[name])
        fh:close()
        print(string.format("wrote %s (%d KB)", path, math.floor(#files[name] / 1024)))
    end
end
if check then
    if stale > 0 then
        print(stale .. " file(s) differ from data-src/tables: run lua5.1 tools/pack_data.lua")
        os.exit(1)
    end
    print("Data/ matches data-src/tables")
end
