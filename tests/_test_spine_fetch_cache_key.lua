-- tests/_test_spine_fetch_cache_key.lua
-- Spine mode's 30-second list cache is keyed on WHICH group is drilled into.
--
-- Usage (from plugin root): lua tests/_test_spine_fetch_cache_key.lua
--
-- Maintainer report: with a book in the top panel and a spine shelf, tapping
-- the hero's "relationships" tag showed one book; tapping "time travel" next
-- updated the breadcrumb but kept showing that one book, and only going back
-- to the full shelf first gave time travel's three. The key took the payload's
-- path / name / query, and a genre or tag payload carries its name in
-- series_name, so every genre drill keyed "genre:" and shared one entry.

package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local src = io.open("lib/bookshelf_widget.lua"):read("*a")
local body = src:match("\nfunction BookshelfWidget:_spineCachedFetch%(n%)\n(.-)\nend\n")
assert(body, "_spineCachedFetch moved")
local fetch = assert(load("return function(self, n)\n" .. body .. "\nend", "spineCachedFetch", "t",
    { os = os, tostring = tostring, type = type }))()

local function widget()
    local w = { chip = "all", _drilldown_path = {}, fetches = 0 }
    function w:_fetchChipItems()
        self.fetches = self.fetches + 1
        local tip = self._drilldown_path[#self._drilldown_path]
        return { tip and tip.label or "top" }
    end
    return w
end
local function drill(w, kind, name)
    w._drilldown_path = { { kind = kind, label = name, payload = { series_name = name, books = {} } } }
end

t.test("a second genre is fetched, not served from the first", function()
    local w = widget()
    drill(w, "genre", "relationships")
    eq(fetch(w)[1], "relationships")
    drill(w, "genre", "time travel")
    eq(fetch(w)[1], "time travel", "the second genre showed the first one's books")
    eq(w.fetches, 2)
end)

t.test("the same drill within the TTL is still served from the cache", function()
    local w = widget()
    drill(w, "tag", "Favourites")
    fetch(w); fetch(w)
    eq(w.fetches, 1, "the cache no longer caches")
end)

t.test("series, authors and tags are told apart the same way", function()
    for _i, kind in ipairs({ "series", "author", "tag", "format", "language", "rating" }) do
        local w = widget()
        drill(w, kind, "A"); fetch(w)
        drill(w, kind, "B")
        eq(fetch(w)[1], "B", kind .. " drills shared a cache entry")
    end
end)

t.done()
