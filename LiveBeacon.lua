--------------------------------------------------------------------------------
-- LiveBeacon.lua - the player's position, drawn for the ForeverGuide Companion
--
-- An addon cannot send anything out of the game while it runs, and the game writes saved variables
-- only on /reload, logout or exit. So, when the player opts in ("Share live position with the
-- Companion", off by default), this draws the position as a strip of 11 colored cells, 3x3 physical
-- pixels each, in the window's top-left corner, redrawn every 0.1 s. The Companion captures that
-- strip and nothing else, and streams it to codex, where admins watch the player move on the map.
-- The contract (frame, cells, checksum) is forever-codex's docs/LIVE-BEACON.md; the encoder is
-- checked against its test vectors (tools/test/fixtures/live-beacon-vectors.json).
--
-- Passive: it reads the position the addon already reads (Player.lua) and draws; nothing else.
--------------------------------------------------------------------------------
local _, ns = ...
local LiveBeacon = ns:NewModule("LiveBeacon")

local MAGIC = 0xFB
local CELLS, CELL_PX = 11, 3
local EVERY = 0.1                 -- seconds between frames
LiveBeacon.FLAG = { mounted = 1, taxi = 2, dead = 4, noPosition = 8, paused = 16 }

-- ---- the frame: pure functions, the contract ------------------------------------------------
-- Lua 5.1 has no bit operators, and WoW's `bit` is not in the headless tests: bytes are XORed by arithmetic.
local function xor8(a, b)
    local r, p = 0, 1
    for _ = 1, 8 do
        local x, y = a % 2, b % 2
        if x ~= y then r = r + p end
        a, b, p = (a - x) / 2, (b - y) / 2, p * 2
    end
    return r
end

--- CRC-8, polynomial 0x07, initial 0.
function LiveBeacon.Crc8(bytes)
    local crc = 0
    for _, byte in ipairs(bytes) do
        crc = xor8(crc, byte)
        for _ = 1, 8 do
            if crc >= 0x80 then crc = xor8((crc * 2) % 256, 0x07) else crc = (crc * 2) % 256 end
        end
    end
    return crc
end

local function coordinate(percent)
    local v = math.floor(percent * 655.35 + 0.5)
    if v < 0 then return 0 elseif v > 0xFFFF then return 0xFFFF end
    return v
end

--- A frame's 13 bytes, the checksum last. frame = { seq, map, x, y, facing, classId, flags }.
function LiveBeacon.Bytes(frame)
    local x, y = coordinate(frame.x), coordinate(frame.y)
    local body = {
        MAGIC,
        math.floor(frame.seq / 256) % 256, frame.seq % 256,
        math.floor(frame.map / 256) % 256, frame.map % 256,
        math.floor(x / 256), x % 256,
        math.floor(y / 256), y % 256,
        frame.facing, frame.classId, frame.flags,
    }
    body[13] = LiveBeacon.Crc8(body)
    return body
end

--- The strip's colors for a frame, 0-255 a channel: black, 9 data cells, white.
function LiveBeacon.Cells(frame)
    local bytes, nibbles = LiveBeacon.Bytes(frame), {}
    for _, b in ipairs(bytes) do
        nibbles[#nibbles + 1] = math.floor(b / 16)
        nibbles[#nibbles + 1] = b % 16
    end
    nibbles[27] = 0                       -- 26 nibbles of frame, one of padding
    local cells = { { 0, 0, 0 } }
    for i = 0, 8 do
        cells[#cells + 1] = { nibbles[i * 3 + 1] * 16 + 8, nibbles[i * 3 + 2] * 16 + 8, nibbles[i * 3 + 3] * 16 + 8 }
    end
    cells[#cells + 1] = { 255, 255, 255 }
    return cells
end

-- ---- reading the player ---------------------------------------------------------------------
local seq = 0

--- The frame for where the player is now.
function LiveBeacon:Frame()
    local P, Plain = ns.Player, ns.Plain
    local map, x, y = P:GetMapPosition()
    local facing = P:GetFacing()
    local classId = tonumber(Plain(select(3, ns.Safe(UnitClass, "player")))) or 0
    local F, flags = LiveBeacon.FLAG, 0
    if Plain(ns.Safe(rawget(_G, "IsMounted"))) == true then flags = flags + F.mounted end
    if Plain(ns.Safe(rawget(_G, "UnitOnTaxi"), "player")) == true then flags = flags + F.taxi end
    if Plain(ns.Safe(rawget(_G, "UnitIsDeadOrGhost"), "player")) == true then flags = flags + F.dead end
    if not x or not y then flags, x, y = flags + F.noPosition, 0, 0 end
    seq = (seq + 1) % 65536
    return {
        seq = seq, map = map or 0, x = x, y = y,
        facing = facing and (math.floor(facing / (2 * math.pi) * 256 + 0.5) % 256) or 0,
        classId = classId, flags = flags,
    }
end

-- ---- drawing ----------------------------------------------------------------------------------
local strip, textures

--- One UI unit to one physical pixel: the strip is the same size at any UI scale or resolution.
local function PixelScale()
    local _, height = ns.Safe(rawget(_G, "GetPhysicalScreenSize"))
    height = tonumber(ns.Plain(height))
    return (height and height > 0) and (768 / height) or 1
end

local function Draw()
    local cells = LiveBeacon.Cells(LiveBeacon:Frame())
    for i, c in ipairs(cells) do textures[i]:SetColorTexture(c[1] / 255, c[2] / 255, c[3] / 255, 1) end
end

local function Build()
    strip = CreateFrame("Frame", nil, UIParent)
    if strip.SetIgnoreParentScale then strip:SetIgnoreParentScale(true) end
    strip:SetScale(PixelScale())
    strip:SetFrameStrata("TOOLTIP")
    strip:SetSize(CELLS * CELL_PX, CELL_PX)
    strip:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
    textures = {}
    for i = 1, CELLS do
        local t = strip:CreateTexture(nil, "OVERLAY")
        t:SetSize(CELL_PX, CELL_PX)
        t:SetPoint("TOPLEFT", strip, "TOPLEFT", (i - 1) * CELL_PX, 0)
        textures[i] = t
    end
    local wait = 0
    strip:SetScript("OnUpdate", function(_, elapsed)
        wait = wait - elapsed
        if wait > 0 then return end
        wait = EVERY
        local ok, err = pcall(Draw)
        if not ok then ns.ReportOnce("livebeacon", err) end
    end)
end

function LiveBeacon:Enabled() return ns.db and ns.db.liveBeacon == true end

--- Draw the strip, or stop drawing it, as the setting says.
function LiveBeacon:Apply()
    if self:Enabled() then
        if not strip then Build() end
        strip:SetScale(PixelScale())
        strip:Show()
    elseif strip then
        strip:Hide()
    end
end

--- Entering the world: draw the strip when the setting is on.
function LiveBeacon:OnEnable() self:Apply() end

--- The setting switched on or off (Options, /fg live).
function LiveBeacon:SetEnabled(on)
    ns.db.liveBeacon = on and true or false
    self:Apply()
end

--- The cells as last drawn, for tests and /fg live: their colors, 0-255.
function LiveBeacon:Shown()
    if not (strip and strip:IsShown()) then return nil end
    local out = {}
    for i, t in ipairs(textures) do
        local c = t.colorTexture
        out[i] = c and { math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5), math.floor(c[3] * 255 + 0.5) } or nil
    end
    return out
end
