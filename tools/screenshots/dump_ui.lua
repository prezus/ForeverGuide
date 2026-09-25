-- ============================================================
-- ForeverGuide / tools/screenshots/dump_ui.lua
-- Opens addon windows headless (tools/test/mock_wow.lua) and writes each
-- one's frame tree - anchors, sizes, textures, colours, text - as JSON for
-- tools/screenshots/render.py to paint:
--
--   luajit tools/screenshots/dump_ui.lua <out dir>     # writes <out dir>/<scene>.json
--
-- A scene is a function that opens a window with example content and returns
-- the frame to capture. The example text is what a player would really see.
-- ============================================================

local root = arg and arg[0] and arg[0]:match("^(.*)tools[/\\]screenshots[/\\]dump_ui%.lua$") or "./"
if root == "" then root = "./" end
local outDir = arg[1] or (root .. "build/screenshots")

dofile(root .. "tools/test/mock_wow.lua")

local ns = {}
local order = {}
for line in io.lines(root .. "ForeverGuide.toc") do
    line = line:gsub("\r", "")
    if line ~= "" and not line:match("^#") then
        if line:match("%.xml$") then
            local dir = line:match("^(.*)[/\\][^/\\]+$") or ""
            for xl in io.lines(root .. line:gsub("\\", "/")) do
                local f = xl:match('file="([^"]+)"')
                if f then order[#order + 1] = (dir .. "/" .. f):gsub("\\", "/") end
            end
        else
            order[#order + 1] = line:gsub("\\", "/")
        end
    end
end
for _, f in ipairs(order) do assert(loadfile(root .. f))("ForeverGuide", ns) end
MOCK_FIRE("ADDON_LOADED", "ForeverGuide")
MOCK_FIRE("PLAYER_ENTERING_WORLD", true, false)
MOCK_ADVANCE(1)

-- ---- JSON ------------------------------------------------------------------
local function encode(v)
    local t = type(v)
    if t == "nil" then return "null"
    elseif t == "boolean" then return tostring(v)
    elseif t == "number" then return (v == math.floor(v) and string.format("%d", v)) or string.format("%.4f", v)
    elseif t == "string" then return '"' .. v:gsub('[%c"\\]', function(c) return string.format("\\u%04x", c:byte()) end) .. '"'
    end
    if #v > 0 or next(v) == nil then
        local parts = {}
        for _, x in ipairs(v) do parts[#parts + 1] = encode(x) end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = encode(k) .. ":" .. encode(v[k]) end
    return "{" .. table.concat(parts, ",") .. "}"
end

-- ---- the frame tree ------------------------------------------------------------
--- Every shown region under `frame`, parents before children, with anchors naming regions by id.
--- An anchor to anything outside the tree (UIParent) is written as the canvas (`null`).
local function dump(frame)
    local ids, list = {}, {}
    local function walk(r)
        if not r.shown then return end
        ids[r] = #list + 1
        list[#list + 1] = r
        for _, c in ipairs(r.children or {}) do walk(c) end
    end
    walk(frame)
    local out = {}
    for i, r in ipairs(list) do
        local points = {}
        for _, p in ipairs(r.points) do
            -- SetPoint(point [, relativeTo [, relativePoint]] [, x, y])
            local point, a, b, c, d = p[1], p[2], p[3], p[4], p[5]
            local rel, relPoint, x, y
            if type(a) == "number" then x, y = a, b
            elseif type(b) == "number" then rel, x, y = a, b, c
            else rel, relPoint, x, y = a, b, c, d end
            if rel == nil and r.parent and ids[r.parent] then rel = r.parent end
            points[#points + 1] = { point = point, rel = rel and ids[rel] or nil, relPoint = relPoint or point, x = x or 0, y = y or 0 }
        end
        -- a scroll frame places its scroll child at its own top-left
        if #points == 0 and r.parent and r.parent.scrollChild == r and ids[r.parent] then
            points[1] = { point = "TOPLEFT", rel = ids[r.parent], relPoint = "TOPLEFT", x = 0, y = 0 }
        end
        local all = r.allPoints
        if all == true then all = r.parent end
        out[i] = {
            id = i, kind = r.kind, parent = r.parent and ids[r.parent] or nil, template = r.template, layer = r.layer,
            w = r.w, h = r.h, points = points, allPoints = all and (ids[all] or 0) or nil,
            texture = type(r.texture) == "string" and r.texture or nil, colorTexture = r.colorTexture, vertex = r.vertex,
            alpha = r.alpha, texCoord = r.texCoord,
            backdrop = r.backdrop and { edgeSize = r.backdrop.edgeSize, bg = r.backdropColor, border = r.backdropBorder } or nil,
            text = (r.kind == "FontString" or r.kind == "EditBox") and r.text or nil,
            font = r.font and r.font.size or nil, textColor = r.textColor, justifyH = r.justifyH, justifyV = r.justifyV,
            multiLine = r.multiLine, shadow = r.shadowOffset ~= nil,
        }
    end
    return out
end

-- ---- scenes ------------------------------------------------------------------------
local now = 1790000000
ns.Now = function() return now end

--- Reports as a Dwarf shaman at Archaic Rune would save them.
local function seedReports()
    ns.db.reports = {
        { t = now - 600, guide = "GEN_ALLIANCE_DWARF_01_DUN_MOROGH", step = 24, type = "TURNIN", q = 98581,
          text = "Teo Hammerstorm is inside Anvilmar, not at the door", loc = { m = 1426, x = 28.8, y = 66.2 },
          m = 1426, x = 28.5, y = 67.0, zone = "Dun Morogh", sub = "Anvilmar", lvl = 3, npc = 257446, npcName = "Teo Hammerstorm", npcStep = 257446 },
        { t = now - 120, guide = "GEN_ALLIANCE_DWARF_01_DUN_MOROGH", step = 31, type = "KILL", q = 179,
          text = "the wolves are further up the hill", loc = { m = 1426, x = 26.3, y = 79.2 },
          m = 1426, x = 24.9, y = 76.8, zone = "Dun Morogh", sub = "Coldridge Valley", lvl = 4 },
    }
end

local scenes = {
    ["report-prompt"] = function()
        ns.Reports:Prompt()
        local f = _G.ForeverGuideReportPrompt
        f.input:SetText("Teo Hammerstorm is inside Anvilmar, not at the door")
        return f
    end,
    ["reports-list"] = function()
        seedReports()
        ns.Reports:ShowList()
        return _G.ForeverGuideReports
    end,
}

os.execute('mkdir -p "' .. outDir .. '"')
local names = {}
for name in pairs(scenes) do names[#names + 1] = name end
table.sort(names)
for _, name in ipairs(names) do
    local frame = scenes[name]()
    local path = outDir .. "/" .. name .. ".json"
    local fh = assert(io.open(path, "w"))
    fh:write(encode({ scene = name, canvas = { w = 1280, h = 720 }, regions = dump(frame) }), "\n")
    fh:close()
    frame:Hide()
    print("wrote " .. path)
end
