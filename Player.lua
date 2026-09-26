-- ============================================================
-- ForeverGuide / Player.lua
-- Everything about the player and what they are looking at:
-- level, faction, class, race, map, zone, coordinates, facing, target.
--
-- API used (all confirmed present on 1.60.1, see project API reference):
--   UnitLevel, UnitXP, UnitXPMax, GetXPExhaustion, UnitFactionGroup,
--   UnitClass, UnitRace, UnitGUID, UnitName, UnitExists, UnitIsDead,
--   UnitIsPlayer, UnitReaction, UnitCreatureType, UnitPosition,
--   GetPlayerFacing, GetZoneText, GetSubZoneText, IsInInstance,
--   C_Map.GetBestMapForUnit, C_Map.GetMapInfo, C_Map.GetPlayerMapPosition
-- ============================================================

local _, ns = ...
---@cast ns FGCore
local Player = ns:NewModule("Player")

local Plain, PlainNumber, PlainString, Safe = ns.Plain, ns.PlainNumber, ns.PlainString, ns.Safe

Player.cache = {
    level = 1,
    faction = nil,       -- "Alliance" / "Horde"
    class = nil,         -- localized
    classFile = nil,     -- "WARRIOR"
    classID = nil,
    race = nil,          -- localized
    raceFile = nil,      -- "Human"
    mapID = nil,
    mapName = nil,
    zone = "",
    subzone = "",
}

-- ------------------------------------------------------------
-- Identity
-- ------------------------------------------------------------
function Player:GetLevel()
    local lvl = PlainNumber(Safe(UnitLevel, "player"))
    if lvl and lvl > 0 then self.cache.level = lvl end
    return self.cache.level
end

function Player:GetXP()
    local xp = PlainNumber(Safe(UnitXP, "player")) or 0
    local max = PlainNumber(Safe(UnitXPMax, "player")) or 0
    local rested = PlainNumber(Safe(GetXPExhaustion)) or 0
    return xp, max, rested
end

function Player:GetFaction()
    if not self.cache.faction then
        local tag = PlainString(Safe(UnitFactionGroup, "player"))
        if tag == "Alliance" or tag == "Horde" then self.cache.faction = tag end
    end
    return self.cache.faction
end

function Player:GetClass()
    if not self.cache.classFile then
        local name, file, id = Safe(UnitClass, "player")
        self.cache.class = PlainString(name)
        self.cache.classFile = PlainString(file)
        self.cache.classID = PlainNumber(id)
    end
    return self.cache.class, self.cache.classFile, self.cache.classID
end

-- skill line IDs of the professions and secondary skills, so a non-English client matches too
local SKILL_IDS = {
    [164] = "Blacksmithing", [165] = "Leatherworking", [171] = "Alchemy", [182] = "Herbalism",
    [185] = "Cooking", [186] = "Mining", [197] = "Tailoring", [202] = "Engineering",
    [333] = "Enchanting", [356] = "Fishing", [393] = "Skinning", [129] = "First Aid",
}

--- The character's rank in a profession or secondary skill by its English name ("Cooking"), 0 when
--- the character does not have it, or nil when the client lists no skills (so nothing is hidden).
--- Read from the skill lines and kept until they change: WoW Forever's C_SkillInfo (one table per
--- line, as its own Skills window reads them), else the Classic globals (several values per line).
function Player:ProfessionRank(name)
    if not self.cache.skills then
        local skills = {}
        local function add(skillName, isHeader, rank, skillID)
            if isHeader == true then return end
            rank = PlainNumber(rank) or 0
            skillName = PlainString(skillName)
            if skillName then skills[skillName] = rank end
            local english = SKILL_IDS[PlainNumber(skillID) or 0]
            if english then skills[english] = rank end
        end
        local num, info = ns.API("C_SkillInfo.GetNumSkillLines"), ns.API("C_SkillInfo.GetSkillLineInfo")
        if num and info then
            for i = 1, PlainNumber(Safe(num)) or 0 do
                local line = Safe(info, i)
                if type(line) == "table" then add(line.name, Plain(line.isHeader), line.rank, line.skillID) end
            end
        else
            num, info = rawget(_G, "GetNumSkillLines"), rawget(_G, "GetSkillLineInfo")
            if type(num) ~= "function" or type(info) ~= "function" then return nil end
            for i = 1, PlainNumber(Safe(num)) or 0 do
                local skillName, isHeader, _, rank = Safe(info, i)
                add(skillName, Plain(isHeader) and true or false, rank)
            end
        end
        self.cache.skills = skills
    end
    return self.cache.skills[name] or 0
end

function Player:GetRace()
    if not self.cache.raceFile then
        local name, file = Safe(UnitRace, "player")
        self.cache.race = PlainString(name)
        self.cache.raceFile = PlainString(file)
    end
    return self.cache.race, self.cache.raceFile
end

function Player:GetName()
    return PlainString(Safe(UnitName, "player")) or "?"
end

-- ------------------------------------------------------------
-- Location
-- ------------------------------------------------------------
function Player:GetMapID()
    local mapID = PlainNumber(ns.Call("C_Map.GetBestMapForUnit", "player"))
    if mapID then self.cache.mapID = mapID end
    return self.cache.mapID
end

function Player:GetMapName(mapID)
    mapID = mapID or self:GetMapID()
    if not mapID then return nil end
    local info = ns.Call("C_Map.GetMapInfo", mapID)
    if type(info) == "table" then
        return PlainString(info.name), PlainNumber(info.mapType), PlainNumber(info.parentMapID)
    end
    return nil
end

function Player:GetZone()
    local zone = PlainString(Safe(GetZoneText)) or ""
    local sub = PlainString(Safe(GetSubZoneText)) or ""
    self.cache.zone, self.cache.subzone = zone, sub
    return zone, sub
end

--- Returns mapID, x, y with x/y in 0-100 map percent (nil when unavailable, e.g. instances).
function Player:GetMapPosition()
    local mapID = self:GetMapID()
    if not mapID then return nil end
    local pos = ns.Call("C_Map.GetPlayerMapPosition", mapID, "player")
    if type(pos) ~= "table" or type(pos.GetXY) ~= "function" then return mapID end
    local ok, x, y = pcall(pos.GetXY, pos)
    x, y = PlainNumber(x), PlainNumber(y)
    if not ok or not x or not y then return mapID end
    return mapID, x * 100, y * 100
end

--- Continent-space position in yards: x (north axis), y (west axis), instanceID.
--- Returns nil inside instances / battlegrounds where UnitPosition is restricted.
function Player:GetWorldPosition()
    local x, y, _, instanceID = Safe(UnitPosition, "player")
    x, y, instanceID = PlainNumber(x), PlainNumber(y), PlainNumber(instanceID)
    if not x or not y then return nil end
    return x, y, instanceID
end

--- Facing in radians: 0 = north, increases counter-clockwise (pi/2 = west).
function Player:GetFacing()
    return PlainNumber(Safe(GetPlayerFacing))
end

function Player:IsInInstance()
    local inInstance, instanceType = Safe(IsInInstance)
    return Plain(inInstance) == true, PlainString(instanceType)
end

function Player:RefreshLocation()
    self:GetMapID()
    self.cache.mapName = self:GetMapName()
    self:GetZone()
end

-- ------------------------------------------------------------
-- Units / target
-- ------------------------------------------------------------
--- Creature-0-1234-0-1234-<npcID>-XXXXXXXXXX  ->  npcID
function Player:NpcIDFromGUID(guid)
    guid = PlainString(guid)
    if not guid then return nil end
    local unitType, _, _, _, _, id = strsplit("-", guid)
    if unitType == "Creature" or unitType == "Vehicle" or unitType == "GameObject" or unitType == "Pet" then
        return tonumber(id), unitType
    end
    return nil, unitType
end

local REACTION = { [1] = "hostile", [2] = "hostile", [3] = "hostile", [4] = "neutral",
                   [5] = "friendly", [6] = "friendly", [7] = "friendly", [8] = "friendly" }

--- Snapshot of a unit token ("target", "npc", "mouseover", ...) or nil if it does not exist.
function Player:GetUnitInfo(unit)
    if Plain(Safe(UnitExists, unit)) ~= true then return nil end
    local guid = PlainString(Safe(UnitGUID, unit))
    local npcID, guidType = self:NpcIDFromGUID(guid)
    local reactionIdx = PlainNumber(Safe(UnitReaction, "player", unit))
    local creatureType, creatureTypeID = Safe(UnitCreatureType, unit)
    return {
        unit = unit,
        name = PlainString(Safe(UnitName, unit)) or "?",
        guid = guid,
        guidType = guidType,
        npcID = npcID,
        level = PlainNumber(Safe(UnitLevel, unit)),
        isPlayer = Plain(Safe(UnitIsPlayer, unit)) == true,
        isDead = Plain(Safe(UnitIsDead, unit)) == true,
        reaction = reactionIdx and (REACTION[reactionIdx] or "unknown") or "unknown",
        creatureType = PlainString(creatureType),
        creatureTypeID = PlainNumber(creatureTypeID),
        isQuestRelated = Plain(ns.Call("C_QuestLog.UnitIsRelatedToActiveQuest", unit)) == true,
    }
end

function Player:GetTargetInfo()
    return self:GetUnitInfo("target")
end

--- The NPC the player is currently interacting with (gossip/quest/vendor
--- window open), falling back to the target.
function Player:GetInteractionNPC()
    return self:GetUnitInfo("npc") or self:GetUnitInfo("target")
end

-- ------------------------------------------------------------
-- Events
-- ------------------------------------------------------------
function Player:OnInit()
    -- professions learned, raised or dropped: read the skill lines again when next asked
    ns.Events:RegisterMany({ "SKILL_LINES_CHANGED", "CHAT_MSG_SKILL" }, function() self.cache.skills = nil end)

    ns.Events:Register("PLAYER_LEVEL_UP", function(_, level)
        level = PlainNumber(level)
        if level then self.cache.level = level end
        ns.Events:Fire("FG_LEVEL_CHANGED", self:GetLevel())
    end)

    ns.Events:RegisterMany({ "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED", "ZONE_CHANGED_INDOORS", "PLAYER_MAP_CHANGED" },
        function(event, ...)
            local oldMap = self.cache.mapID
            self:RefreshLocation()
            ns.Events:Fire("FG_ZONE_CHANGED", self.cache.mapID, oldMap, event)
        end)

    ns.Events:Register("PLAYER_TARGET_CHANGED", function()
        ns.Events:Fire("FG_TARGET_CHANGED", self:GetTargetInfo())
    end)
end

function Player:OnEnterWorld()
    self.cache.faction, self.cache.classFile, self.cache.raceFile = nil, nil, nil
    self:GetLevel()
    self:GetFaction()
    self:GetClass()
    self:GetRace()
    self:RefreshLocation()
end

--- One-line description used by /fg and the UI header.
function Player:Describe()
    local level = self:GetLevel()
    local race = self:GetRace()
    local class = self:GetClass()
    local faction = self:GetFaction() or "?"
    return string.format("Level %d %s %s (%s)", level, race or "?", class or "?", faction)
end
