---@meta
-- Editor-only declarations for WoW Forever 1.60.1.69977 (not loaded by ForeverGuide.toc).
-- Source: https://github.com/Gethe/wow-ui-source/tree/c6e89983189e4f626f549204a23c2d2bea93080a
-- UIParent is used by Blizzard_UIParent/UIParent.lua; frame getters are in
-- Blizzard_APIDocumentationGenerated/SimpleScriptRegionAPIDocumentation.lua.
-- These return types do not imply the values are safe to inspect in combat.
-- CreateFrame is used in Blizzard's UI Lua; Ketho's annotations provide the
-- argument order (including optional id), not Forever availability evidence.
-- C_Timer, C_Map, UnitName and UnitGUID are documented by this snapshot in
-- UITimerDocumentation.lua, MapDocumentation.lua and UnitDocumentation.lua.

---@class FGFrame
---@field GetWidth fun(self: FGFrame): number
---@field GetHeight fun(self: FGFrame): number
---@field RegisterEvent fun(self: FGFrame, event: string): boolean
---@field UnregisterEvent fun(self: FGFrame, event: string): boolean
---@field SetScript fun(self: FGFrame, scriptType: string, handler: function?)

---@type FGFrame
UIParent = nil

---@param frameType string
---@param name? string
---@param parent? table
---@param template? string
---@param id? number
---@return table  Frame methods are not typed yet; don't mistake this for a client compatibility check.
function CreateFrame(frameType, name, parent, template, id) end

---@class FGTimerAPI
---@field After fun(seconds: number, callback: function)
---@type FGTimerAPI
C_Timer = nil

---@class FGMapAPI
---@field GetMapPosFromWorldPos fun(continentID: number, worldPosition: table, overrideUiMapID?: number): number?, table?
---@type FGMapAPI
C_Map = nil

---@param unit string
---@return string? name, string? server  Results can be secret or unavailable in combat.
function UnitName(unit) end

---@param unit string
---@return string? guid  Results can be secret or unavailable in combat.
function UnitGUID(unit) end
