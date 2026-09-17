-- tests/_test_pagination_format.lua
-- What the footer counts, and why the shelf decides rather than the reader.
--
-- THE RULE. A spine page holds a variable number of books, so "page 3 of 27"
-- is a number nothing on screen can be checked against -- and the page map
-- that produces it comes from a second planning pass that does not always
-- agree with the render. A RANGE is arithmetic on the cursor and the total:
-- always true, and true from the very first paint. Every other style pages by
-- a fixed grid, where the page number is the honest summary and the one every
-- other pager on the device shows.
--
-- IT WAS A SETTING FIRST, and that was the mistake. It asked the reader to
-- decide something they have no way to judge, and the wrong half of the answer
-- looked like a bug rather than a preference: a page count that corrected
-- itself on the first turn after a restart ("page 1 of 3, then when I go to
-- next page it says 2 of 9"). The shelf knows which answer it can stand
-- behind, so the shelf picks.
--
-- The open-ended "+" belongs to both forms: an OPDS feed that has not been
-- walked to the end knows a lower bound only, and dropping the plus in either
-- would have a partly-walked catalogue claim a total it does not have.
--
-- HAIR SPACES (U+200A) sit around the range's dash; they live in the msgid so
-- translators keep or drop them deliberately.
--
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
        BookshelfSettings = { read = function(_k, dflt) return dflt end },
        _ = function(x) return x end,
        T = function(fmt, ...)
            local args = { ... }
            local i = 0
            return (fmt:gsub("%%(%d)", function(n) return tostring(args[tonumber(n)]) end))
        end,
        tostring = tostring, tonumber = tonumber, math = math, pcall = pcall,
    }
    local fn = assert(load(
        "return function(self, first, last, total, open_ended, page, pages)\n"
            .. body .. "\nend",
        "counter", "t", env))
    -- Stands in for a shelf with no page map: both map calls answer nil, so
    -- the old fields stand. The map-backed path is exercised below.
    -- `stored` now says which SHELF this is: "spines" or anything else.
    local self_ = { page = page or 1, _totalPages = function() return pages or 1 end,
                    _isSpineMode = function() return stored == "spines" end }
    return fn()(self_, first, last, total, open_ended, ovr_page, ovr_pages)
end

t.test("a spine shelf counts books, because its pages vary", function()
    eq(run("spines", 9, 16, 247, false, 3, 27),
       "9" .. HAIR .. "-" .. HAIR .. "16 of 247")
end)

t.test("every other style counts pages", function()
    eq(run("covers", 9, 16, 247, false, 3, 27), "Page 3 of 27")
    eq(run("list",   9, 16, 247, false, 3, 27), "Page 3 of 27")
end)

t.test("the open-ended plus survives in both forms", function()
    -- A partly-walked OPDS feed must not claim a total it does not have.
    eq(run("spines", 9, 16, 247, true, 3, 27),
       "9" .. HAIR .. "-" .. HAIR .. "16 of 247+")
    eq(run("covers", 9, 16, 247, true, 3, 27), "Page 3 of 27+")
end)

t.test("the reader is no longer asked to choose", function()
    -- The whole footprint, not just the row: a key left behind reads as a
    -- setting that stopped working.
    local set = io.open("lib/bookshelf_settings.lua"):read("*a")
    assert(not set:find("pagination_format", 1, true),
        "the setting row or its key is still in the menu")
    assert(not src:find("pagination_format", 1, true),
        "the counter still reads a setting")
    assert(src:find("if not self:_isSpineMode() then", 1, true),
        "the counter no longer decides by shelf style")
end)

t.test("the probe can force the widest numbers, not today's", function()
    -- Otherwise a shelf that grows from page 9 to page 100 outgrows the slot
    -- its width was measured for.
    eq(run("covers", 1, 1, 1, true, 3, 27, 999, 999), "Page 999 of 999+")
end)

t.test("the map answers both numbers when there is one", function()
    -- THE RESTART BUG. self.page and self._total_pages are maintained
    -- separately, and _total_pages starts as a capacity ESTIMATE because the
    -- first _rebuild has no shelf dims to plan a map with. Read independently
    -- they disagree: "page 1 of 3, then when I go to next page it says 2 of 9,
    -- and I still have two pages 2's" (maintainer). Both now come from the
    -- map, so they cannot be a step apart.
    local env_self = {
        page = 1,                                  -- the stale field
        _totalPages = function() return 3 end,     -- the stale estimate
        _cursor = 40,
        _isSpineMode = function() return false end,
        _spinePageIndexForCursor = function(_s, cur) return 4 end,
        _spineTotalPages = function() return 9 end,
    }
    local body = src:match(
        "\nfunction BookshelfWidget:_pageCounterText%(first, last, total, open_ended, page, pages%)\n(.-)\nend\n")
    local env = {
        BookshelfSettings = { read = function(_k, d) return d end },
        _ = function(x) return x end, pcall = pcall, math = math,
        T = function(fmt, ...) local a = { ... }
            return (fmt:gsub("%%(%d)", function(n) return tostring(a[tonumber(n)]) end)) end,
        tostring = tostring, tonumber = tonumber,
    }
    local fn = assert(load("return function(self, first, last, total, open_ended, page, pages)\n"
        .. body .. "\nend", "counter", "t", env))
    eq(fn()(env_self, 1, 1, 1, false), "Page 4 of 9",
        "the counter still reads the stale fields instead of the map")
end)

t.test("a page number past the end is clamped to the map", function()
    local env_self = {
        page = 12, _totalPages = function() return 12 end, _cursor = 1,
        _isSpineMode = function() return false end,
        _spinePageIndexForCursor = function() return nil end,
        _spineTotalPages = function() return 9 end,
    }
    local body = src:match(
        "\nfunction BookshelfWidget:_pageCounterText%(first, last, total, open_ended, page, pages%)\n(.-)\nend\n")
    local env = {
        BookshelfSettings = { read = function(_k, d) return d end },
        _ = function(x) return x end, pcall = pcall, math = math,
        T = function(fmt, ...) local a = { ... }
            return (fmt:gsub("%%(%d)", function(n) return tostring(a[tonumber(n)]) end)) end,
        tostring = tostring, tonumber = tonumber,
    }
    local fn = assert(load("return function(self, first, last, total, open_ended, page, pages)\n"
        .. body .. "\nend", "counter", "t", env))
    eq(fn()(env_self, 1, 1, 1, false), "Page 9 of 9",
        "a stale page number past the map's end was shown as-is")
end)

t.done()
