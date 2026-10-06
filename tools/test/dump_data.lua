-- Everything the addon reads from its bundled data, as one canonical text:
--     lua5.1 tools/test/dump_data.lua <addon root> <out file>
-- Loads the addon in TOC order against the mock (as run_tests.lua does), lets the modules
-- initialise, then writes every quest, NPC, object and item record as DB:Get* returns it, the
-- zone tables, the scanner's id lists and every guide's steps. Two builds whose dumps are equal
-- give the addon the same data, whatever the storage format underneath.

local root, outPath = arg[1], arg[2]
assert(root and outPath, "usage: dump_data.lua <addon root> <out file>")
if not root:find("[/\\]$") then root = root .. "/" end

dofile(root .. "tools/test/mock_wow.lua")
local ns = {}
for line in io.lines(root .. "ForeverGuide.toc") do
    line = line:gsub("\r", "")
    if line ~= "" and not line:match("^#") then
        local files = {}
        if line:match("%.xml$") then
            local dir = line:match("^(.*)[/\\][^/\\]+$") or ""
            for xl in io.lines(root .. line:gsub("\\", "/")) do
                local f = xl:match('file="([^"]+)"')
                -- as the game reads the attribute: "&amp;" is "&" (TUGs' "Ashenvale&Wetlands")
                if f then
                    f = f:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&")
                    files[#files + 1] = (dir .. "/" .. f):gsub("\\", "/")
                end
            end
        else
            files[1] = line:gsub("\\", "/")
        end
        for _, f in ipairs(files) do assert(loadfile(root .. f))("ForeverGuide", ns) end
    end
end
MOCK_FIRE("ADDON_LOADED", "ForeverGuide")

--- A number exactly as stored: the shortest form that reads back to the same value.
local function num(v)
    if v == math.floor(v) and math.abs(v) < 2 ^ 53 then return string.format("%d", v) end
    for p = 1, 17 do
        local s = string.format("%." .. p .. "g", v)
        if tonumber(s) == v then return s end
    end
end

local function canon(v)
    local t = type(v)
    if t == "number" then return num(v) end
    if t == "string" then return string.format("%q", v) end
    if t ~= "table" then return tostring(v) end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        if type(a) == type(b) then return a < b end
        return type(a) == "number"
    end)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = "[" .. canon(k) .. "]=" .. canon(v[k]) end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function ids(tbl)
    local out = {}
    for id in pairs(tbl or {}) do out[#out + 1] = id end
    table.sort(out)
    return out
end

local out = assert(io.open(outPath, "w"))
local DB = ns.DB
for _, kind in ipairs({ { "quest", ns.QuestDB, "GetQuest" }, { "npc", ns.NpcDB, "GetNPC" },
                        { "object", ns.ObjectDB, "GetObject" }, { "item", ns.ItemDB, "GetItem" } }) do
    local name, tbl, getter = kind[1], kind[2], kind[3]
    for _, id in ipairs(ids(tbl)) do
        out:write(name, " ", id, " ", canon(DB[getter](DB, id)), "\n")
    end
end
for _, key in ipairs({ "areaToMap", "names", "parent", "mapNames", "mapParent" }) do
    out:write("zone ", key, " ", canon(ns.ZoneDB[key] or {}), "\n")
end
out:write("scanner new ", canon(ns.ForeverNewQuestIDRanges or {}), "\n")
out:write("scanner vanilla ", canon(ns.VanillaQuestIDs or {}), "\n")
for _, id in ipairs(ids(ns.Guide.registry)) do
    local g = ns.Guide.registry[id]
    local header = {}
    for k, v in pairs(g) do if k ~= "steps" then header[k] = v end end
    out:write("guide ", id, " ", canon(header), "\n")
    for i, step in ipairs(g.steps) do out:write("step ", id, " ", i, " ", canon(step), "\n") end
end
out:close()
