-- Minimal strict JSON decoder for the tests: reads back what Share.lua exports, so the
-- tests check the export as the server will see it. Errors on anything that is not JSON.
local json = {}

local function fail(s, i, what) error(string.format("json: %s at %d near %q", what, i, s:sub(i, i + 20)), 0) end

local function ws(s, i)
    local _, e = s:find("^[ \t\r\n]*", i)
    return e + 1
end

local ESC = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

local value

local function str(s, i)
    local out, j = {}, i + 1
    while true do
        local c = s:sub(j, j)
        if c == "" then fail(s, j, "unterminated string") end
        if c == '"' then return table.concat(out), j + 1 end
        if c == "\\" then
            local n = s:sub(j + 1, j + 1)
            if n == "u" then
                local hex = s:sub(j + 2, j + 5)
                if not hex:match("^%x%x%x%x$") then fail(s, j, "bad \\u escape") end
                local code = tonumber(hex, 16)
                if code > 127 then fail(s, j, "non-ASCII \\u escape (not produced by the exporter)") end
                out[#out + 1] = string.char(code)
                j = j + 6
            elseif ESC[n] then
                out[#out + 1] = ESC[n]
                j = j + 2
            else
                fail(s, j, "bad escape")
            end
        elseif c:byte() < 32 then
            fail(s, j, "raw control character in string")
        else
            out[#out + 1] = c
            j = j + 1
        end
    end
end

value = function(s, i)
    i = ws(s, i)
    local c = s:sub(i, i)
    if c == "{" then
        local obj = {}
        i = ws(s, i + 1)
        if s:sub(i, i) == "}" then return obj, i + 1 end
        while true do
            if s:sub(i, i) ~= '"' then fail(s, i, "expected key") end
            local k
            k, i = str(s, i)
            i = ws(s, i)
            if s:sub(i, i) ~= ":" then fail(s, i, "expected ':'") end
            if obj[k] ~= nil then fail(s, i, "duplicate key " .. k) end
            obj[k], i = value(s, i + 1)
            i = ws(s, i)
            local d = s:sub(i, i)
            if d == "}" then return obj, i + 1 end
            if d ~= "," then fail(s, i, "expected ',' or '}'") end
            i = ws(s, i + 1)
        end
    elseif c == "[" then
        local arr = {}
        i = ws(s, i + 1)
        if s:sub(i, i) == "]" then return arr, i + 1 end
        while true do
            arr[#arr + 1], i = value(s, i)
            i = ws(s, i)
            local d = s:sub(i, i)
            if d == "]" then return arr, i + 1 end
            if d ~= "," then fail(s, i, "expected ',' or ']'") end
            i = i + 1
        end
    elseif c == '"' then
        return str(s, i)
    elseif s:find("^true", i) then return true, i + 4
    elseif s:find("^false", i) then return false, i + 5
    elseif s:find("^null", i) then return nil, i + 4
    else
        local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
        if not num or num == "" or not tonumber(num) then fail(s, i, "unexpected character") end
        return tonumber(num), i + #num
    end
end

function json.decode(s)
    local v, i = value(s, 1)
    i = ws(s, i)
    if i <= #s then fail(s, i, "trailing data") end
    return v
end

return json
