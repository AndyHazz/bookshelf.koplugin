-- tests/_test_token_register.lua
-- Pure-Lua test runner. No KOReader dependencies.
-- Tokens.register: tokens from a user patch or plugin (PR 515).

package.loaded["device"] = {
    getPowerDevice = function() return nil end,
    isKindle = function() return false end,
    hasNaturalLight = function() return false end,
    home_dir = "/",
}
-- Signature matches KOReader's real datetime: (format, seconds, withoutSeconds).
-- Durations route through Semantics.duration now (#348), which passes the
-- reader's duration_format first; a single-argument stub silently received the
-- format string where it expected seconds.
package.loaded["datetime"] = {
    secondsToClockDuration = function(_fmt, s)
        if not s or s <= 0 then return "" end
        local h = math.floor(s / 3600)
        local m = math.floor((s % 3600) / 60)
        return string.format("%dh %02dm", h, m)
    end,
}
-- Stub both require keys: lib code requires the canonical "lib/bookshelf_i18n"
-- (e.g. bookshelf_tokens for its catalogue descriptions), some callers the
-- bare "bookshelf_i18n". gettext is identity so the catalogue holds source.
local _i18n_stub = {
    gettext = function(t) return t end,
    ngettext = function(s, p, n) return n == 1 and s or p end,
}
package.loaded["bookshelf_i18n"] = _i18n_stub
package.loaded["lib/bookshelf_i18n"] = _i18n_stub
_G.G_reader_settings = setmetatable({}, {
    readSetting = function() return nil end,
    isTrue = function() return false end,
    __index = function() return function() return false end end,
})
package.loaded["logger"] = { warn = function() end, dbg = function() end, info = function() end }

local Tokens = dofile("lib/bookshelf_tokens.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1; print("PASS  " .. name)
    else fail = fail + 1; print("FAIL  " .. name .. "\n  " .. tostring(err)) end
end
local function eq(a, b, msg)
    if a ~= b then error((msg or "") .. "\n  got:  " .. tostring(a) .. "\n  want: " .. tostring(b), 2) end
end

local book = { title = "Dune", chapters = 12 }

test("a registered token expands in a template", function()
    assert(Tokens.register("ao3", { chapters = function(b) return b.chapters end }))
    eq(Tokens.expand("%title (%chapters ch)", book), "Dune (12 ch)")
end)

test("a registered token works in a condition", function()
    eq(Tokens.expand("[if:chapters>10]long[else]short[/if]", book), "long")
    eq(Tokens.expand("[if:chapters]x[/if]", { title = "A" }), "")
end)

test("a built-in name is refused and keeps its meaning", function()
    local ok, why = Tokens.register("bad", { title = function() return "X" end })
    assert(not ok and why:find("built%-in"), tostring(why))
    eq(Tokens.expand("%title", book), "Dune")
end)

test("another id cannot take a registered name", function()
    local ok = Tokens.register("other", { chapters = function() return "0" end })
    assert(not ok)
    eq(Tokens.expand("%chapters", book), "12")
end)

test("an expander that errors renders empty", function()
    assert(Tokens.register("boom", { boom = function() error("nope") end }))
    eq(Tokens.expand("[%boom]", book), "[]")
end)

test("a described token is listed under its id, and leaves with it", function()
    assert(Tokens.register("ao3", {
        chapters = { expand = function(b) return b.chapters end, description = "Chapters" },
    }))
    local found
    for _i, t in ipairs(Tokens.CATALOGUE) do
        if t.token == "%chapters" then found = t end
    end
    assert(found and found.category == "ao3", "not listed under its id")
    assert(Tokens.register("ao3", nil))
    for _i, t in ipairs(Tokens.CATALOGUE) do assert(t.token ~= "%chapters", "still listed") end
    eq(Tokens.expand("%chapters", book), "%chapters", "still expands after removal")
end)

test("a longer registered name does not swallow a shorter one", function()
    assert(Tokens.register("x", { ao3 = function() return "A" end,
                                  ao3_status = function() return "WIP" end }))
    eq(Tokens.expand("%ao3 %ao3_status", book), "A WIP")
end)

print(string.format("PASS %d  FAIL %d", pass, fail))
os.exit(fail == 0 and 0 or 1)
