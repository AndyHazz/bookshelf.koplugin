-- Every documented token must RESOLVE - never survive as its own literal text.
--
-- This is the class of bug that reached a render during the #348 sweep:
-- bookshelf's default status template uses %wifi_icon, bookends only had
-- %wifi, and the reader's status bar showed the characters "%wifi_icon". A
-- set-difference audit of token NAMES cannot see that - both plugins have a
-- Wi-Fi token, they just disagreed on its name.
--
-- Empty output is fine and often correct (a book with one author has no
-- %author_2). The literal surviving is never correct: to a reader it looks
-- like the plugin is broken.
--
-- Usage: cd into the plugin dir, then `lua tests/_test_no_literal_tokens.lua`.

package.loaded["device"] = {
    getPowerDevice = function() return nil end,
    isKindle = function() return false end,
    hasNaturalLight = function() return true end,
    home_dir = "/",
}
package.loaded["datetime"] = {
    secondsToClockDuration = function(_fmt, s)
        if not s or s <= 0 then return "" end
        return string.format("%dh %02dm", math.floor(s / 3600),
                             math.floor((s % 3600) / 60))
    end,
}
local _i18n = {
    gettext = function(str) return str end,
    ngettext = function(a, b, n) return n == 1 and a or b end,
}
package.loaded["bookshelf_i18n"] = _i18n
package.loaded["lib/bookshelf_i18n"] = _i18n
-- %quote reaches lib/bookshelf_quotes, which pulls in KOReader's logger.
package.loaded["logger"] = {
    dbg = function() end, info = function() end,
    warn = function() end, err = function() end,
}
_G.G_reader_settings = setmetatable({}, {
    __index = function() return function() return false end end,
})

local t = dofile("tests/_helpers.lua").runner()
local Tokens = dofile("lib/bookshelf_tokens.lua")

-- A book and device state rich enough that most tokens have something to say.
local function book()
    return {
        title = "Dune", author = "Frank Herbert",
        authors = { "Frank Herbert", "Brian Herbert", "Kevin Anderson" },
        series = "Dune #1", series_name = "Dune", series_num = "1",
        filename = "dune", lang = "en", format = "EPUB",
        page_num = 100, page_count = 500, book_pct = 0.2,
        status = "complete", rating = 4, size = 2048,
        date_added = 1710000000, last_opened = 1720000000,
        description = "Spice.", filepath = "/lib/dune.epub",
        book_read_time_seconds = 11100, book_pages_read = 120,
        days_reading_book = 6, pages_per_day = 20, speed_pph = 39,
        book_time_left_minutes = 185, avg_page_time_seconds = 42,
        book_pct_read = 44,
        highlights = 12, notes = 3, bookmarks = 2,
        hardcover_rating = 4.5,
        calibre = { mood = "cosy" },
    }
end
local function state()
    return {
        batt = 82, charging = false, charged = true,
        wifi = "on", connected = "yes",
        light = 12, fl_max = 24,
        warmth_native = 12, warmth_pct = 50, has_natural_light = true,
        mem_total = 1000, mem_available = 624,
        ram_kb = 86016, sysused_bytes = 88080384, disk_bytes = 13207024435,
        duration_format = "classic", full_width = true,
        books_read = 24, books_started = 30,
        pages_today = 34, time_today_minutes = 72,
        total_read_time_seconds = 513000,
        now = 1720000000,
    }
end

local function documentedTokens()
    local names, seen = {}, {}
    local f = assert(io.open("README.md", "r"))
    for line in f:lines() do
        for n in line:gmatch("`%%([a-z_0-9]+)`") do
            if not seen[n] then seen[n] = true; names[#names + 1] = n end
        end
    end
    f:close()
    for _i, entry in ipairs(Tokens.CATALOGUE or {}) do
        local n = tostring(entry.token or ""):match("^%%([a-z_0-9]+)$")
        if n and not seen[n] then seen[n] = true; names[#names + 1] = n end
    end
    table.sort(names)
    return names
end

local names = documentedTokens()

t.test("the token inventory is non-trivial", function()
    assert(#names > 50, "only found " .. #names .. " tokens; the parse is wrong")
end)

-- Whole FAMILIES rather than one entry per variant: enumerating chap_title_2
-- and forgetting chap_title_9 is precisely how such a list rots, and the first
-- run of this test proved it by leaking nine chapter variants I had not
-- thought to write down.
local ABSENT_PATTERNS = {
    { "^chap_",      "reader context: there is no current chapter on a shelf" },
    { "_lastdigit$", "grammar helper for the reader's chapter/page counters" },
}

-- %bar and %spacer are WIDGETS: the renderer replaces them after expansion,
-- so surviving Tokens.expand is correct for them and only for them.
local WIDGET_TOKENS = { bar = true, spacer = true }

local function leaks(list, skip)
    local out = {}
    for _i, name in ipairs(list) do
        local skipped = WIDGET_TOKENS[name] or (skip and skip[name])
        if skip and not skipped then
            for _j, rule in ipairs(ABSENT_PATTERNS) do
                if name:match(rule[1]) then skipped = rule[2]; break end
            end
        end
        if not skipped then
            local got = Tokens.expand("%" .. name, book(), state())
            if type(got) == "string" and got:find("%" .. name, 1, true) then
                out[#out + 1] = "%" .. name
            end
        end
    end
    return out
end

t.test("no documented token survives as literal text", function()
    local bad = leaks(names)
    assert(#bad == 0, #bad .. " token(s) rendered as their own name: "
           .. table.concat(bad, " "))
end)

-- ── The cross-plugin check ─────────────────────────────────────────────────
--
-- #348 is about templates being COPIED between the plugins, so the question
-- that matters is whether a line written for the reader renders here. Absences
-- that are DELIBERATE are listed with their reason, so this test records the
-- scope decisions instead of quietly tolerating gaps.
local DELIBERATELY_ABSENT = {
    session_pages = "no reading session on a shelf",
    session_time  = "no reading session on a shelf",
    invert = "no page turning on a shelf",
    plugin_content = "footer-extension API belongs to the reader",
    file_num = "wants a per-book folder listing bookshelf does not build yet",
    file_count = "ditto",
    streak = "needs consecutive-day logic over page_stat; deferred",
    book_streak = "ditto",
    book_finish_date = "derived from the reader's live pace",
    book_time_left_eta = "ditto",
    pages_today_book = "per-book today; bookshelf has the global pair",
    time_today_book = "ditto", pages_week_book = "ditto",
    time_week_book = "ditto",
    warmth_icon = "present; empty because the stub PowerD reports no warmth",
    light_icon = "present; empty under the stub PowerD",
    batt_icon = "present; empty without a real PowerD",
    quote = "reads highlights from the sidecar; no file under test",
    quote_source = "ditto",
    favourite = "reads the favourites collection; unavailable under stubs",
    sysused = "present; empty under the stubs",
}

local SIBLING_README = "../bookends.koplugin/README.md"

t.test("bookends' documented tokens resolve here too", function()
    local f = io.open(SIBLING_README, "r")
    if not f then
        print("  SKIP: no sibling checkout at " .. SIBLING_README)
        return
    end
    local sib, seen = {}, {}
    for line in f:lines() do
        for n in line:gmatch("`%%([a-z_0-9]+)`") do
            if not seen[n] then seen[n] = true; sib[#sib + 1] = n end
        end
    end
    f:close()
    assert(#sib > 60, "only found " .. #sib .. " sibling tokens; parse is wrong")
    local gaps = leaks(sib, DELIBERATELY_ABSENT)
    assert(#gaps == 0,
        #gaps .. " token(s) documented by bookends render as literal text here, "
        .. "so a copied template would show them raw: " .. table.concat(gaps, " "))
end)

t.done()
