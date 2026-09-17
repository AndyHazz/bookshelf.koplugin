-- tests/_test_pagination_format.lua
-- What the footer counter counts: books, or pages.
--
-- WHAT NEEDS PINNING. The counter reads as a RANGE of books in every mode --
-- "9-16 of 247". That was a deliberate unification: spine pages hold a
-- variable number of books, so "Page 3 of 27" is a fiction there, and a page
-- number also lies whenever the cursor is misaligned, while a range is always
-- true. Pages survived internally -- the jump dialog and skip-ten still steer
-- by them -- and only the display changed.
--
-- Some readers want the page number back, so it is a setting. The range stays
-- the default, since the reasoning above has not changed.
--
-- The open-ended form matters in both: an OPDS feed that has not been walked
-- to the end knows a lower bound only, and the "+" is what says so. Dropping
-- it in one format and not the other would make a partly-walked catalogue
-- claim a total it does not have.
--
-- Usage (from plugin root): lua tests/_test_pagination_format.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq
local src = io.open("lib/bookshelf_widget.lua"):read("*a")

local body = src:match(
    "\nfunction BookshelfWidget:_pageCounterText%(first, last, total, open_ended, page, pages%)\n(.-)\nend\n")
assert(body, "_pageCounterText moved or was renamed")

local HAIR = "\xe2\x80\x8a"

local function run(stored, first, last, total, open_ended, page, pages, ovr_page, ovr_pages)
    local env = {
        BookshelfWidget = {},
        BookshelfSettings = { read = function(_k, dflt) return stored == nil and dflt or stored end },
        _ = function(x) return x end,
        T = function(fmt, ...)
            local args = { ... }
            local i = 0
            return (fmt:gsub("%%(%d)", function(n) return tostring(args[tonumber(n)]) end))
        end,
        tostring = tostring, tonumber = tonumber, math = math,
    }
    local fn = assert(load(
        "return function(self, first, last, total, open_ended, page, pages)\n" .. body .. "\nend",
        "counter", "t", env))
    local self_ = { page = page or 1, _totalPages = function() return pages or 1 end }
    return fn()(self_, first, last, total, open_ended, ovr_page, ovr_pages)
end

t.test("an untouched library counts pages", function()
    -- The range was the default first, because a page number is a fiction on
    -- a spine shelf whose pages hold a variable number of books. It lost:
    -- readers read "1-16 of 247" as a book count rather than as a position,
    -- and a page number is what every other pager on the device shows
    -- (maintainer). The range is one tap away and loses nothing.
    eq(run(nil, 9, 16, 247, false, 3, 27), "Page 3 of 27")
end)

t.test("the books format keeps its open-ended plus", function()
    eq(run("books", 9, 16, 247, true), "9" .. HAIR .. "-" .. HAIR .. "16 of 247+")
end)

t.test("the pages format reads as a page number", function()
    eq(run("pages", 9, 16, 247, false, 3, 27), "Page 3 of 27")
end)

t.test("the pages format keeps the open-ended plus too", function()
    -- A partly-walked OPDS feed must not claim a total it does not have.
    eq(run("pages", 9, 16, 247, true, 3, 27), "Page 3 of 27+")
end)

t.test("an unknown value falls back to books rather than showing nothing", function()
    eq(run("furlongs", 9, 16, 247, false), "9" .. HAIR .. "-" .. HAIR .. "16 of 247")
end)

t.test("the probe can force the widest numbers, not today's", function()
    -- Otherwise a shelf that grows from page 9 to page 100 outgrows the slot
    -- its width was measured for.
    eq(run("pages", 1, 1, 1, true, 3, 27, 999, 999), "Page 999 of 999+")
end)

t.test("the footer and its width probe use the same builder", function()
    -- The probe measures the widest text the slot must hold. Two builders
    -- would size the slot for one format and paint the other into it.
    local uses = select(2, src:gsub("_pageCounterText%(", ""))
    assert(uses >= 3, "expected the definition plus both call sites, found " .. uses)
    local probe = src:match("local probe = FooterSlots.probeNumber%(counter_total%)(.-)slots = FooterSlots.widths")
    assert(probe, "the probe block moved")
    assert(probe:find("_pageCounterText", 1, true),
        "the probe still builds its own text, so the slot can be sized for the wrong format")
end)

t.done()
