-- ============================================================
-- ForeverGuide / tools/share_schema.lua
-- Prints the JSON Schema of the /fg share format, made from the allowlist in Share.lua:
--     lua5.1 tools/share_schema.lua > docs/share-format.schema.json
-- Run it after changing the allowlist; the tests fail until the file matches.
-- ============================================================
local root = arg and arg[0] and arg[0]:match("^(.*)tools[/\\]share_schema%.lua$") or "./"
if root == "" then root = "./" end

-- Share.lua only needs a module table and the Plain helpers to define its allowlist
local ns = {}
function ns.NewModule(self, name) local m = {} self[name] = m return m end
ns.PlainNumber = function(v) return v end
ns.PlainString = function(v) return v end
ns.PlainBool = function(v) return v end
assert(loadfile(root .. "Share.lua"))("ForeverGuide", ns)

local generate = dofile(root .. "tools/lib/share_schema.lua")
io.write(generate(ns.Share.SCHEMA))
