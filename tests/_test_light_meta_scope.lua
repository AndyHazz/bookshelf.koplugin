-- tests/_test_light_meta_scope.lua
-- The light-meta map is built from BIM's whole table, which covers every book
-- KOReader has ever opened -- not just the ones under home_dir. Every consumer
-- looks entries up by a filepath that came from the home-scoped walk, so a
-- record for a book outside home is built and then never read, and each one
-- drags in a directory listing for wherever it lives.
--
-- On a PW5, 63 of 384 rows were outside home; skipping them took the cold
-- build from 959ms to 869ms median (-9%), because those 63 were scattered
-- across many directories and the listings are the expensive half.
--
-- SOURCE-SHAPE checks on the guards. The filter sits in a module local that
-- the repository suite's fixture does not reach, and getting it wrong empties
-- the map rather than erroring -- every book would fall back to the per-book
-- path and the shelf would just be slow, which no other test would catch.
package.path = "./?.lua;./?/init.lua;" .. package.path

local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()

local src = io.open("lib/bookshelf_book_repository.lua"):read("*a")
local fn  = src:match("\nlocal function _getLightMetaCache%(home, depth%)\n(.-)\nend\n")

t.test("_getLightMetaCache is still there under that name", function()
    assert(fn, "_getLightMetaCache is gone or its signature changed")
end)

t.test("rows outside home are skipped", function()
    assert(fn:match("prefix"), "the home-prefix filter is gone -- the map is "
        .. "back to building records no consumer reads")
end)

t.test("an unset or root home disables the filter rather than emptying the map",
function()
    -- home_dir unset, "", or "/" must NOT filter everything out: a prefix of ""
    -- matches nothing useful and "/" matches everything anyway. Getting this
    -- wrong gives an empty map and a shelf that silently falls back per book.
    assert(fn:match('prefix ~= ""') and fn:match('prefix ~= "/"'),
        "empty and root home must bypass the filter")
    assert(fn:match("prefix = nil"), "the bypass must clear the prefix, not "
        .. "leave a partial one in place")
end)

t.test("the prefix ends at a path boundary", function()
    -- Without the trailing slash, home "/mnt/us/ebooks" also matches
    -- "/mnt/us/ebooks-old/..." and quietly pulls in a second library.
    assert(fn:match('gsub%("/%+%$", ""%) %.%. "/"'),
        "the prefix must be normalised to exactly one trailing slash, or a "
        .. "sibling directory with a shared name prefix is matched too")
end)

t.done()
