-- tests/_test_spine_forget_looks.lua
-- Issue 537: a reader's spines were saved grey while their covers were in
-- colour. A saved look is only dropped one book at a time (a status change, a
-- cover re-extracted), so Clear cover cache now forgets them all and every
-- spine samples its cover again.
-- Run from the plugin root: lua tests/_test_spine_forget_looks.lua
package.path = "./?.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t = H.runner()
local F = dofile("tests/_binding_fixture.lua")

-- A facts store in memory, shaped like lib/bookshelf_book_facts_db.
local rows, cleared = {}, 0
package.loaded["lib/bookshelf_book_facts_db"] = {
    get = function(fp) return rows[fp] end,
    put = function(fp, f)
        local e = rows[fp] or {}
        for k, v in pairs(f) do if v == false then e[k] = nil else e[k] = v end end
        rows[fp] = e
    end,
    drop = function(fp) rows[fp] = nil end,
    flush = function() end,
    migrateFrom = function() return 0 end,
    clearLooks = function()
        local n = 0
        for _, e in pairs(rows) do
            if e.r then n = n + 1; e.r, e.g, e.b, e.a = nil, nil, nil, nil end
        end
        cleared = cleared + 1
        return n
    end,
}

-- The cover BIM hands back now: in colour.
local function cover()
    local bb = F.surface(40, 60)
    function bb:getPixel()
        return { getColorRGB32 = function() return { r = 40, g = 90, b = 160 } end }
    end
    return bb
end
package.loaded["lib/bookshelf_book_repository"].getCoverBB = function() return cover() end

local Shelf = require("lib/bookshelf_spine_shelf")   -- the real bookLook, unconfigured

t.test("a look saved grey keeps coming back until it is forgotten", function()
    rows["/b/grey.epub"] = { r = 90, g = 90, b = 90, a = 1.5, p = 300 }
    local look = Shelf.bookLook({ filepath = "/b/grey.epub", title = "Grey" })
    assert(look.r == 90 and look.g == 90 and look.b == 90, "the saved look was not used")
end)

t.test("forgetLooks clears the saved looks and the session's copy", function()
    local n = Shelf.forgetLooks()
    assert(cleared == 1 and n == 1, "the store was not cleared")
    assert(rows["/b/grey.epub"].p == 300, "the page count went with the look")
    local look = Shelf.bookLook({ filepath = "/b/grey.epub", title = "Grey" })
    assert(look.sampled, "the cover was not sampled again")
    assert(look.b > look.r, "the spine is still grey: r=" .. look.r .. " b=" .. look.b)
    assert(rows["/b/grey.epub"].b == look.b, "the fresh look was not saved")
end)

t.test("Clear cover cache forgets the spine colours and rebuilds the shelf", function()
    local src = F.source("lib/bookshelf_settings.lua")
    local at = src:find('text = _("Clear cover cache")', 1, true)
    assert(at, "Clear cover cache moved")
    local block = src:sub(at, (src:find("Cover cache cleared", at, true) or at + 2000))
    assert(block:find("ScaledCoverCache:clear()", 1, true), "the cover cache is no longer cleared")
    assert(block:find('require("lib/bookshelf_spine_shelf").forgetLooks()', 1, true),
        "the spine colours are not forgotten")
    assert(block:find("_rebuild()", 1, true), "the shelf is not rebuilt with the new colours")
end)

t.done()
