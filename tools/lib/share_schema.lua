-- ============================================================
-- ForeverGuide / tools/lib/share_schema.lua
-- Turns the /fg share allowlist (Share.SCHEMA in Share.lua) into a JSON Schema
-- (draft 2020-12), so anyone can validate a share with any JSON Schema validator.
-- Used by tools/share_schema.lua (writes docs/share-format.schema.json) and by the
-- tests (the committed file must equal what this makes).
-- ============================================================

-- JSON Schema nodes are ordered lists of { key, value } pairs, so the file is stable.
local function Quote(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        return ({ ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n" })[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
end

local function Emit(v, depth)
    local pad = string.rep("  ", depth)
    if type(v) == "string" then return Quote(v) end
    if type(v) == "number" then return string.format("%d", v) end
    if type(v) == "boolean" then return tostring(v) end
    if v.array then
        local items = {}
        for i, x in ipairs(v.array) do items[i] = Emit(x, depth + 1) end
        return "[" .. table.concat(items, ", ") .. "]"
    end
    local items = {}
    for i, pair in ipairs(v) do
        items[i] = pad .. "  " .. Quote(pair[1]) .. ": " .. Emit(pair[2], depth + 1)
    end
    return "{\n" .. table.concat(items, ",\n") .. "\n" .. pad .. "}"
end

local function Node(spec)
    if spec == "int" then return { { "type", "integer" } } end
    if spec == "num" then return { { "type", "number" } } end
    if spec == "bool" then return { { "type", "boolean" } } end
    if spec.kind == "str" then return { { "type", "string" }, { "maxLength", spec.max } } end
    if spec.kind == "list" then
        return { { "type", "array" }, { "maxItems", spec.max }, { "items", Node(spec.of) } }
    end
    if spec.kind == "map" then
        return {
            { "type", "object" },
            { "maxProperties", spec.max },
            { "propertyNames", { { "pattern", "^-?[0-9]+$" } } },
            { "additionalProperties", Node(spec.of) },
        }
    end
    local props = {}
    for i, f in ipairs(spec.fields) do props[i] = { f[1], Node(f[2]) } end
    return { { "type", "object" }, { "additionalProperties", false }, { "properties", props } }
end

return function(schema)
    local root = Node(schema)
    -- the version field is fixed: a reader knows which format it holds
    for _, pair in ipairs(root[3][2]) do
        if pair[1] == "format" then pair[2] = { { "const", 2 } } end
    end
    table.insert(root, 1, { "$schema", "https://json-schema.org/draft/2020-12/schema" })
    table.insert(root, 2, { "title", "ForeverGuide /fg share, format 2" })
    table.insert(root, 3, { "description", "The decoded JSON of a ForeverGuide share string (FG2). "
        .. "Only these fields may appear; see docs/SHARE-FORMAT.md. Generated from Share.lua by tools/share_schema.lua." })
    table.insert(root, #root, { "required", { array = { "format" } } })
    return Emit(root, 0) .. "\n"
end
