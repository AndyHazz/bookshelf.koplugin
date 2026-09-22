-- tests/_test_no_stray_globals.lua
-- No plugin file reads or writes a global it did not mean to.
--
-- Usage (from plugin root): lua tests/_test_no_stray_globals.lua
--
-- A name Lua cannot resolve to a local becomes a global, silently: no error
-- at load, and a nil (or a stray write) at run time. It is how a local that is
-- DECLARED BELOW its user goes missing (see the upvalue-order note in
-- _test_theme_ink_coverage), and how a local of one function gets read from
-- another. The first sweep found six, all shipped:
--
--   * SpineShelf.invalidateBook cleared a global _plan_cache, not the plan's
--     cache, declared further down the file;
--   * the custom-metadata gate's invalidation did the same to _only_location;
--   * the book menu's cover tap, the chip bar's inactive fill and the raw
--     calibre series string each read a local of ANOTHER function;
--   * the wallpaper's Background class lived in _G.
--
-- ...and a refactor the same afternoon dropped a local two footers still read,
-- which no other test noticed. So: list every global each file touches, via
-- the compiler's own listing, and allow only the standard library and the
-- handful KOReader defines.

package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()

local ALLOWED = {}
for name in ([[
    assert collectgarbage debug dofile error getmetatable io ipairs load
    loadfile loadstring math next os package pairs pcall rawequal rawget
    rawlen rawset require select setmetatable string table tonumber tostring
    type unpack utf8 xpcall coroutine print
    G_reader_settings G_defaults
]]):gmatch("%S+") do ALLOWED[name] = true end

local function which(cmd)
    local p = io.popen("command -v " .. cmd .. " 2>/dev/null")
    local out = p and p:read("*l"); if p then p:close() end
    return out and out ~= "" and out or nil
end
-- The listing format (GETTABUP ... _ENV "name") is 5.2 onward; the device's
-- LuaJIT has no luac, and this is about the source, not the runtime.
local luac = which("luac5.4") or which("luac5.5") or which("luac")

if not luac then
    print("SKIP  no luac on PATH")
    t.done()
    return
end

local files = {}
do
    local p = io.popen("find lib -name '*.lua' | sort")
    for line in p:lines() do files[#files + 1] = line end
    p:close()
    files[#files + 1] = "main.lua"
end

for _i, f in ipairs(files) do
    t.test(f, function()
        local p = io.popen(luac .. " -l -l -p '" .. f .. "' 2>&1")
        local listing = p:read("*a"); p:close()
        local bad, seen = {}, {}
        local function note(name, lno)
            if name and not ALLOWED[name] and not seen[name] then
                seen[name] = true
                bad[#bad + 1] = name .. " (line " .. lno .. ")"
            end
        end
        -- Two encodings. The usual one names the global in one instruction:
        --   GETTABUP  A 0 k   ; _ENV "name"
        -- A function with more constants than fit an operand (>255 -- the
        -- rebuild is one) loads _ENV into a register and indexes it instead:
        --   GETUPVAL  R u     ; _ENV
        --   LOADK     Q k     ; "name"
        --   GETTABLE  A R Q   (or SETTABLE R Q v)
        -- The first sweep read only the first, and missed a nil total_pages
        -- in _rebuild's own perf line.
        local env_reg, name_reg = {}, {}
        for line in listing:gmatch("[^\n]+") do
            local lno, name = line:match("%[(%d+)%]%s+[GS]ETTABUP.-_ENV \"([^\"]+)\"")
            if name then note(name, lno) end
            local ln, op, a, b, c = line:match("%[(%d+)%]%s+(%u+)%s+(%-?%d+)%s*(%-?%d*)%s*(%-?%d*)")
            if op then
                a, b, c = tonumber(a), tonumber(b), tonumber(c)
                if op == "GETUPVAL" and line:find("; _ENV", 1, true) then
                    env_reg[a] = true
                elseif op == "LOADK" then
                    name_reg[a] = line:match('; "([^"]*)"')
                elseif op == "GETTABLE" and env_reg[b] and name_reg[c] then
                    note(name_reg[c], ln)
                elseif op == "SETTABLE" and env_reg[a] and name_reg[b] then
                    note(name_reg[b], ln)
                end
                -- Anything else written to a register ends what it held.
                if op ~= "GETUPVAL" and op ~= "SETTABLE" then env_reg[a] = nil end
                if op ~= "LOADK" and op ~= "SETTABLE" then name_reg[a] = nil end
                if op == "GETUPVAL" and not line:find("; _ENV", 1, true) then env_reg[a] = nil end
            end
            if line:match("^%a.-function <") then env_reg, name_reg = {}, {} end
        end
        assert(#bad == 0, "undeclared globals: " .. table.concat(bad, ", ")
            .. " -- a local declared below its user, or read out of its scope?")
    end)
end

t.done()
