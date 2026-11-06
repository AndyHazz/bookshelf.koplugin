-- tests/_test_pubdate_format.lua
-- %published{format}'s formatter (lib/bookshelf_pubdate_format): a stored
-- publication date ("YYYY", "YYYY-MM" or "YYYY-MM-DD") in a strftime-style
-- layout, without os.date (a Kindle's 32-bit time_t stops at 1901, before most
-- public-domain books). A date that lacks a part the layout asks for shows the
-- book menu's short form instead, never a made-up 1 January.
-- Usage (from plugin root): lua tests/_test_pubdate_format.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

local F = dofile("lib/bookshelf_pubdate_format.lua")

t.test("a full date in any layout, before 1901 too", function()
    eq(F.format("1851-10-18", "%-d %B %Y"), "18 October 1851")
    eq(F.format("1851-10-18", "%A"), "Saturday")
    eq(F.format("2016-02-29", "%a %d/%m/%y"), "Mon 29/02/16")
    eq(F.format("1903-07-04", "%e %b %Y"), " 4 Jul 1903")
    eq(F.format("1903-07-04", "%Y-%m-%d"), "1903-07-04")
end)

t.test("a date with fewer parts than the layout falls back to the short form", function()
    eq(F.format("1851-10", "%-d %B %Y"), "Oct 1851")
    eq(F.format("1851-10", "%B %Y"), "October 1851")
    eq(F.format("1851", "%B %Y"), "1851")
    eq(F.format("1851", "%Y"), "1851")
    eq(F.format("1851", "%A"), "1851")
end)

t.test("no date is empty; %% and unknown codes pass through", function()
    eq(F.format(nil, "%Y"), "")
    eq(F.format("", "%Y"), "")
    eq(F.format("1851-10-18", "100%% %Q"), "100% %Q")
end)

t.test("short form matches the book menu", function()
    eq(F.short("2016-02-18"), "18 Feb 2016")
    eq(F.short("2016-02-05"), "05 Feb 2016")
    eq(F.short("2016-02"), "Feb 2016")
    eq(F.short("2016"), "2016")
    eq(F.short(nil), "")
end)

t.test("decades", function()
    eq(F.decade("1851-10-18"), 1850)
    eq(F.decade("1009"), 1000)
    eq(F.decade("2029"), 2020)
    eq(F.decade(nil), nil)
    eq(F.decade("soon"), nil)
    eq(F.decadeLabel(1850), "1850s")
end)

t.test("names go through the interface language", function()
    package.loaded["lib/bookshelf_localdate"] = {
        localize = function(s) return ({ October = "octubre", Saturday = "sábado", Oct = "oct" })[s] or s end,
    }
    local G = dofile("lib/bookshelf_pubdate_format.lua")
    eq(G.format("1851-10-18", "%A %-d %B %Y"), "sábado 18 octubre 1851")
    eq(G.short("1851-10"), "oct 1851")
    package.loaded["lib/bookshelf_localdate"] = nil
end)

t.done()
