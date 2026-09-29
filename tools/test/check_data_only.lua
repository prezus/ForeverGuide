-- ============================================================
-- ForeverGuide / tools/test/check_data_only.lua
-- Guides/ and Data/ arrive by pull request from the maintainer's route planner and data build.
-- The game runs them with the addon's full permissions, so they must be data and nothing else:
--
--     lua5.1 tools/test/check_data_only.lua [dir ...]     (default: Guides Data tools/test/fixtures/Guides)
--
-- Two checks, both required:
--   static   with strings and comments removed, a file holds only table constructors, the
--            `local _, ns = ...` header, `ns.<Name> = ...` assignments and `ns.RegisterGuide(...)`
--            calls: no `function`, no loop or branch keyword, no other call.
--   runtime  each file runs with no globals and a bare `ns`; afterwards everything reachable from
--            `ns` is a table, string, number or boolean. Every packed string (a guide's steps,
--            a Data record) must pass the same static check and decode, in an empty
--            environment, to plain data.
-- Exits non-zero naming the first problem in each failing file.
-- ============================================================

local dirs = (#arg > 0) and arg or { "Guides", "Data", "tools/test/fixtures/Guides" }

--- Text with every string literal and comment replaced by a space, so only code remains.
local function codeOnly(src)
    local out, i, n = {}, 1, #src
    while i <= n do
        local c = src:sub(i, i)
        local long = src:match("^%[(=*)%[", i)
        if src:sub(i, i + 1) == "--" then
            local level = src:match("^%-%-%[(=*)%[", i)
            if level then
                local close = src:find("]" .. level .. "]", i, true)
                if not close then return nil, "unterminated long comment" end
                i = close + #level + 2
            else
                local nl = src:find("\n", i, true)
                i = nl or n + 1
            end
            out[#out + 1] = " "
        elseif long then
            local close = src:find("]" .. long .. "]", i + #long + 2, true)
            if not close then return nil, "unterminated long string" end
            i = close + #long + 2
            out[#out + 1] = " \1 "
        elseif c == '"' or c == "'" then
            local j = i + 1
            while j <= n do
                local d = src:sub(j, j)
                if d == "\\" then j = j + 2
                elseif d == c then break
                elseif d == "\n" then return nil, "newline in a quoted string"
                else j = j + 1 end
            end
            if j > n then return nil, "unterminated string" end
            i = j + 1
            out[#out + 1] = " \1 "
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
end

local FORBIDDEN = { ["function"] = true, ["while"] = true, ["for"] = true, ["repeat"] = true, ["until"] = true,
    ["if"] = true, ["then"] = true, ["else"] = true, ["elseif"] = true, ["do"] = true, ["end"] = true,
    ["return"] = true, ["break"] = true, ["goto"] = true }

--- The static check on a file's code: nil when it is data, else what is wrong.
local function staticProblem(src, isRecord)
    local code, err = codeOnly(src)
    if not code then return err end
    for word in code:gmatch("[%a_][%w_]*") do
        if FORBIDDEN[word] then return "keyword `" .. word .. "`" end
    end
    if code:find(":", 1, true) then return "a method call" end
    -- A name is a value only when it is `ns`, a literal or the header; otherwise it must name a
    -- field (`name =`) or follow a `.`. A bare name read as a value would reach the game's globals.
    local pos = 1
    while true do
        local s, e, word = code:find("([%a_][%w_]*)", pos)
        if not s then break end
        local before = code:sub(1, s - 1):match("(%S)%s*$")
        local after = code:sub(e + 1):match("^%s*(%S%S?)")
        local fieldName = after ~= nil and after:sub(1, 1) == "=" and after ~= "=="
        if not (word == "ns" or word == "_" or word == "local" or word == "true" or word == "false" or word == "nil"
            or before == "." or fieldName) then
            return "the name `" .. word .. "` read as a value"
        end
        pos = e + 1
    end
    -- `local` only in the header, calls only to ns.RegisterGuide.
    local withoutHeader = code:gsub("^%s*local%s+_%s*,%s*ns%s*=%s*%.%.%.", "", 1)
    if withoutHeader:find("%f[%w_]local%f[^%w_]") then return "a `local` other than the header" end
    if withoutHeader:find("...", 1, true) then return "a vararg" end
    local calls = withoutHeader:gsub("ns%.RegisterGuide%s*%(", "")
    if calls:find("(", 1, true) then return isRecord and "a parenthesis in a packed record" or "a call other than ns.RegisterGuide" end
    return nil
end

--- Nil when every value reachable from v is plain data.
local function dataProblem(v, seen, path)
    local t = type(v)
    if t == "string" or t == "number" or t == "boolean" or t == "nil" then return nil end
    if t ~= "table" then return path .. " is a " .. t end
    if seen[v] then return nil end
    seen[v] = true
    if getmetatable(v) ~= nil then return path .. " has a metatable" end
    for k, x in pairs(v) do
        local kt = type(k)
        if kt ~= "string" and kt ~= "number" then return path .. " has a " .. kt .. " key" end
        local problem = dataProblem(x, seen, path .. "." .. tostring(k))
        if problem then return problem end
    end
    return nil
end

--- A packed string decoded in an empty environment: the value, or nil and why not.
local function decode(text, where)
    local problem = staticProblem(text, true)
    if problem then return nil, where .. ": " .. problem end
    local chunk, err = loadstring("return " .. text, where)
    if not chunk then return nil, where .. ": " .. err end
    setfenv(chunk, {})
    local ok, value = pcall(chunk)
    if not ok then return nil, where .. ": " .. tostring(value) end
    if type(value) ~= "table" then return nil, where .. ": not a table" end
    local bad = dataProblem(value, {}, where)
    if bad then return nil, bad end
    return value
end

local function checkFile(path)
    local fh = io.open(path, "rb")
    if not fh then return "cannot read" end
    local src = fh:read("*a")
    fh:close()
    local problem = staticProblem(src, false)
    if problem then return problem end

    local guides = {}
    local ns = { RegisterGuide = function(g) guides[#guides + 1] = g end }
    local chunk, err = loadstring(src, path)
    if not chunk then return err end
    setfenv(chunk, {})
    local ok, runErr = pcall(chunk, "ForeverGuide", ns)
    if not ok then return tostring(runErr) end
    ns.RegisterGuide = nil
    local bad = dataProblem(ns, {}, "ns")
    if bad then return bad end

    for _, g in ipairs(guides) do
        bad = dataProblem(g, {}, "guide " .. tostring(g.id))
        if bad then return bad end
        if type(g.steps) == "string" then
            local steps, why = decode(g.steps, "guide " .. tostring(g.id) .. " steps")
            if not steps then return why end
            if g.stepCount and #steps ~= g.stepCount then return "guide " .. tostring(g.id) .. ": stepCount " .. g.stepCount .. ", decoded " .. #steps end
        end
    end
    for name, tbl in pairs(ns) do
        if type(tbl) == "table" then
            for id, record in pairs(tbl) do
                if type(record) == "string" and record:sub(1, 1) == "{" then
                    local _, why = decode(record, "ns." .. name .. "[" .. tostring(id) .. "]")
                    if why then return why end
                end
            end
        end
    end
    return nil
end

local files, failed = 0, 0
for _, dir in ipairs(dirs) do
    local list = io.popen('ls "' .. dir .. '" 2>/dev/null')
    for name in list:lines() do
        if name:match("%.lua$") then
            files = files + 1
            local problem = checkFile(dir .. "/" .. name)
            if problem then
                failed = failed + 1
                print("NOT DATA " .. dir .. "/" .. name .. ": " .. problem)
            end
        end
    end
    list:close()
end
if files == 0 then
    print("no .lua files in " .. table.concat(dirs, ", "))
    os.exit(1)
end
if failed > 0 then
    print(failed .. " of " .. files .. " file(s) are not data only")
    os.exit(1)
end
print(files .. " file(s): data only")
