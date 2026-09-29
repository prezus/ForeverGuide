-- lua5.1 tools/test/test_check_data_only.lua: the data-only check refuses code in any disguise.
local LUA = arg[-1] or "lua5.1"
local cases = {
    good = { ok = true, src = 'local _, ns = ...\nns.RegisterGuide({\n    id = "G", version = 2, race = { "Human" },\n    stepCount = 1,\n    steps = [==[{\n{type="NOTE",text="a ]] and ]=] b"}\n}]==],\n})\n' },
    goodData = { ok = true, src = 'local _, ns = ...\nns.QuestDB = {\n[7]=[[{n="Kobold Camp",lvl=4}]],\n}\nns.QuestIndex = {\nbyZone = {[12]={7}},\n}\n' },
    ["function"] = { src = 'local _, ns = ...\nns.X = function() end\n' },
    otherCall = { src = 'local _, ns = ...\nprint("hi")\n' },
    loop = { src = 'local _, ns = ...\nwhile true do end\n' },
    method = { src = 'local _, ns = ...\nns.RegisterGuide({ id = ("x"):rep(2), steps = "{}" })\n' },
    extraLocal = { src = 'local _, ns = ...\nlocal x = 1\n' },
    stepsCode = { src = 'local _, ns = ...\nns.RegisterGuide({ id = "G", stepCount = 1, steps = [[{{type=os.exit(1)}}]] })\n' },
    stepsFunction = { src = 'local _, ns = ...\nns.RegisterGuide({ id = "G", stepCount = 1, steps = [[{{type="NOTE",f=function() end}}]] })\n' },
    recordCode = { src = 'local _, ns = ...\nns.QuestDB = {\n[1]=[[{n=print("x")}]],\n}\n' },
    globalRead = { src = 'local _, ns = ...\nns.X = { os }\n' },
    bareS = { src = 'local _, ns = ...\nns.X = { S }\n' },
    unterminated = { src = 'local _, ns = ...\nns.X = "open\n' },
}
local failed = 0
for name, case in pairs(cases) do
    local dir = os.tmpname()
    os.remove(dir)
    os.execute('mkdir -p "' .. dir .. '"')
    local fh = assert(io.open(dir .. "/" .. name .. ".lua", "wb"))
    fh:write(case.src)
    fh:close()
    local ok = os.execute(string.format('"%s" tools/test/check_data_only.lua "%s" >/dev/null', LUA, dir)) == 0
    os.execute('rm -rf "' .. dir .. '"')
    if ok ~= (case.ok == true) then
        failed = failed + 1
        print(string.format("FAIL %s: expected %s", name, case.ok and "data" or "refused"))
    end
end
if failed > 0 then os.exit(1) end
print("check_data_only: every case as expected")
