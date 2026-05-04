-- tests/_test_tokens.lua
-- Pure-Lua test runner. No KOReader dependencies.
-- Usage: cd into the plugin dir, then `lua tests/_test_tokens.lua`.

package.loaded["device"] = {
    getPowerDevice = function() return nil end,
    isKindle = function() return false end,
    hasNaturalLight = function() return false end,
    home_dir = "/",
}
package.loaded["datetime"] = {
    secondsToClockDuration = function(s)
        if not s or s <= 0 then return "" end
        local h = math.floor(s / 3600)
        local m = math.floor((s % 3600) / 60)
        return string.format("%dh %02dm", h, m)
    end,
}
package.loaded["bookshelf_i18n"] = {
    gettext = function(t) return t end,
    ngettext = function(s, p, n) return n == 1 and s or p end,
}
_G.G_reader_settings = setmetatable({}, {
    readSetting = function() return nil end,
    isTrue = function() return false end,
    __index = function() return function() return false end end,
})

local Tokens = dofile("tokens.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end
local function eq(a, e, msg)
    if a ~= e then error((msg or "") .. " expected=" .. tostring(e) .. " got=" .. tostring(a), 2) end
end

-- ============================================================================
test("smoke: Tokens module loads", function()
    assert(type(Tokens) == "table", "Tokens is not a table")
    assert(type(Tokens.expand) == "function", "Tokens.expand missing")
end)

local function bookFixture()
    return {
        title = "Dune",
        author = "Frank Herbert",
        authors = { "Frank Herbert" },
        series = "Dune #1",
        series_name = "Dune",
        series_num = "1",
        filename = "dune",
        lang = "en",
        format = "EPUB",
    }
end

test("metadata: %title", function()
    eq(Tokens.expand("%title", bookFixture()), "Dune")
end)
test("metadata: %author", function()
    eq(Tokens.expand("%author", bookFixture()), "Frank Herbert")
end)
test("metadata: %series", function()
    eq(Tokens.expand("%series", bookFixture()), "Dune #1")
end)
test("metadata: literal text passes through", function()
    eq(Tokens.expand("Reading %title by %author.", bookFixture()),
       "Reading Dune by Frank Herbert.")
end)
test("metadata: missing token resolves to empty", function()
    local b = bookFixture(); b.series = nil
    eq(Tokens.expand("%series", b), "")
end)

test("position: %page_num / %page_count", function()
    local b = bookFixture(); b.page_num = 142; b.page_count = 688
    eq(Tokens.expand("%page_num / %page_count", b), "142 / 688")
end)
test("position: %book_pct rounds to integer percent", function()
    local b = bookFixture(); b.book_pct = 0.213
    eq(Tokens.expand("%book_pct", b), "21%")
end)
test("position: %book_pct_left", function()
    local b = bookFixture(); b.book_pct = 0.213
    eq(Tokens.expand("%book_pct_left", b), "79%")
end)
test("position: %pages_left = page_count - page_num", function()
    local b = bookFixture(); b.page_num = 142; b.page_count = 688
    eq(Tokens.expand("%pages_left", b), "546")
end)

local function clockState()
    return { now = os.time({ year=2026, month=5, day=3, hour=14, min=35, sec=0 }) }
end

test("time: %time_24h", function()
    eq(Tokens.expand("%time_24h", bookFixture(), clockState()), "14:35")
end)
test("time: %time_12h", function()
    eq(Tokens.expand("%time_12h", bookFixture(), clockState()), "2:35 PM")
end)
test("date: %weekday", function()
    eq(Tokens.expand("%weekday", bookFixture(), clockState()), "Sunday")
end)
test("datetime: custom strftime", function()
    eq(Tokens.expand("%datetime{%d %B}", bookFixture(), clockState()), "03 May")
end)

test("stats: %book_time_left formats minutes → 'Nh MMm'", function()
    local b = bookFixture(); b.book_time_left_minutes = 131
    eq(Tokens.expand("%book_time_left", b), "2h 11m")
end)
test("stats: missing → empty", function()
    eq(Tokens.expand("%book_time_left", bookFixture()), "")
end)
test("annotations: %highlights pluralisation", function()
    local b = bookFixture(); b.highlights = 3
    eq(Tokens.expand("%highlights", b), "3")
end)
test("device: %batt with state", function()
    eq(Tokens.expand("%batt", bookFixture(), { batt = 73 }), "73%")
end)
test("device: %wifi off → wifi-off Nerd Font glyph", function()
    eq(Tokens.expand("%wifi", bookFixture(), { wifi = "off" }), "\xee\xb2\xa9")
end)
test("device: %wifi on → wifi Nerd Font glyph", function()
    eq(Tokens.expand("%wifi", bookFixture(), { wifi = "on" }), "\xee\xb2\xa8")
end)

test("if: token-truthy", function()
    local b = bookFixture()
    eq(Tokens.expand("[if:series]Series: %series_name[/if]", b), "Series: Dune")
end)
test("if: token-falsy → empty", function()
    local b = bookFixture(); b.series = nil; b.series_name = nil
    eq(Tokens.expand("[if:series]Series: %series_name[/if]", b), "")
end)
test("if/else: book_pct numeric compare", function()
    local b = bookFixture(); b.book_pct = 0.7
    eq(Tokens.expand("[if:book_pct>50]Almost done[else]%book_pct[/if]", b), "Almost done")
end)
test("if: not operator", function()
    local b = bookFixture(); b.series = nil
    eq(Tokens.expand("[if:not series]Standalone[/if]", b), "Standalone")
end)
test("if: nested", function()
    local b = bookFixture(); b.book_pct = 0.95
    eq(Tokens.expand("[if:book_pct>50][if:book_pct>90]Final![else]Halfway+[/if][/if]", b), "Final!")
end)
test("if: equality with quoted string", function()
    eq(Tokens.expand([=[[if:author="Frank Herbert"]✓[/if]]=], bookFixture()), "✓")
end)

test("inline: [b]bold[/b] tags survive expansion", function()
    eq(Tokens.expand("[b]%title[/b]", bookFixture()), "[b]Dune[/b]")
end)
test("inline: nested [b][i] preserved", function()
    eq(Tokens.expand("[b][i]%title[/i][/b]", bookFixture()), "[b][i]Dune[/i][/b]")
end)

test("width: {N} cap is preserved as marker for renderer", function()
    -- The token engine resolves the value but leaves {N} intact, so the
    -- renderer can measure pixels and truncate. We test that the token
    -- expansion happens AND the width-cap suffix is preserved.
    local b = bookFixture(); b.title = "An extremely long book title that goes on"
    eq(Tokens.expand("%title{200}", b), "An extremely long book title that goes on{200}")
end)

test("autoHide: line of all empty tokens is hidden", function()
    local b = bookFixture(); b.book_time_left_minutes = nil
    eq(Tokens.isEmpty(Tokens.expand("%book_time_left", b)), true)
end)
test("autoHide: line with literal text is not empty", function()
    eq(Tokens.isEmpty(Tokens.expand("Reading %title", bookFixture())), false)
end)

test("if: or before and (left-to-right operator scan)", function()
    local b = bookFixture(); b.series = nil; b.book_pct = 0.95
    -- 'series' is empty (false), but 'book_pct>50' is true; left-to-right
    -- evaluation: false or true = true; (true) and (true [book_pct>0]) = true
    eq(Tokens.expand("[if:series or book_pct>50]yes[/if]", b), "yes")
end)

test("if: unknown comparison operator → false (defensive default)", function()
    -- '==' is not a supported operator. The atom should evaluate to false,
    -- not silently flip to true via 'not nil'.
    eq(Tokens.expand("[if:not author==\"Frank\"]matched[/if]", bookFixture()), "matched")
end)

test("isEmpty: only [b][i][u] tags strip, not arbitrary single-letter tags", function()
    -- A future hypothetical [c]color[/c] tag should NOT be stripped by isEmpty.
    eq(Tokens.isEmpty("[c]hi[/c]"), false)
end)

test("bar: %bar expands to empty (deferred to renderer)", function()
    eq(Tokens.expand("%bar", bookFixture()), "")
end)

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
