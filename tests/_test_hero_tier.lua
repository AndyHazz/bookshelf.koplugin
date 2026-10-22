-- tests/_test_hero_tier.lua
-- The hero tier: hero-height cover copies stashed at shelf-decode time so a
-- book's FIRST preview skips its BIM decode. Ownership rules are the point:
-- the tier owns what it stashes (eviction really frees), and take() hands
-- ownership out exactly once.
--
-- Run from the plugin root: lua tests/_test_hero_tier.lua

package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["logger"] = { dbg = function() end, info = function() end,
                             warn = function() end, err = function() end }

local t = dofile("tests/_helpers.lua").runner()

-- A stub bb that behaves like a Blitbuffer for everything the tier touches.
local function bb(w, h)
    local o
    o = {
        _w = w, _h = h, freed = false,
        stride = w,   -- 1 byte/px, like grayscale covers on device
        getWidth  = function() return o._w end,
        getHeight = function() return o._h end,
        scale = function(_, sw, sh)
            o.scaled_to = { w = sw, h = sh }
            return bb(sw, sh)
        end,
        free = function() o.freed = true end,
    }
    return o
end

local function fresh()
    local HT = dofile("lib/bookshelf_hero_tier.lua")
    return HT
end

t.test("noteSource is a no-op until a hero build registers target_h", function()
    local HT = fresh()
    HT:noteSource("/b/a.epub", bb(400, 600))
    assert(HT:take("/b/a.epub") == nil, "stored without a target height")
end)

t.test("noteSource stashes an aspect-true copy at hero height", function()
    local HT = fresh()
    HT.target_h = 600
    local src = bb(500, 750)
    HT:noteSource("/b/a.epub", src)
    assert(not src.freed, "the tier must never free the caller's source")
    local got = HT:take("/b/a.epub")
    assert(got, "expected a stashed copy")
    assert(got:getHeight() == 600, "height should be the hero height")
    assert(got:getWidth() == 400, "width should follow the source aspect")
end)

t.test("take transfers ownership exactly once", function()
    local HT = fresh()
    HT.target_h = 600
    HT:noteSource("/b/a.epub", bb(400, 600))
    local first = HT:take("/b/a.epub")
    assert(first, "first take should hit")
    assert(not first.freed, "a transferred bb must not be freed by the tier")
    assert(HT:take("/b/a.epub") == nil, "second take must miss")
end)

t.test("a short source is stashed at its own height", function()
    -- The hero's own path would upscale the same source pixels to the
    -- same box, so serving the short copy is quality-identical and still
    -- saves the decode (real case: small embedded covers).
    local HT = fresh()
    HT.target_h = 628
    HT:noteSource("/b/short.epub", bb(220, 350))
    local got = HT:take("/b/short.epub")
    assert(got, "short copies must serve")
    assert(got:getHeight() == 350, "stashed at source height, not stretched")
end)

-- A full tier skips a new cover WITHOUT scaling it. It used to scale every
-- decoded cover and evict the oldest, and on a face-out shelf (a page of 30+
-- covers against a budget of a few) that was a hero-size bb:scale per cover
-- per page turn, almost all thrown away: ~10-40% of the turn (rig, 1500
-- books, Genres face-out). What is already stashed stays until taken.
t.test("a full tier skips new covers without scaling them", function()
    local HT = fresh()
    HT.target_h = 1000
    HT:setBudget(2 * 400 * 1000 + 100)  -- room for two 400x1000 copies
    HT:noteSource("/b/1.epub", bb(400, 1000))
    HT:noteSource("/b/2.epub", bb(400, 1000))
    local third = bb(400, 1000)
    HT:noteSource("/b/3.epub", third)
    assert(third.scaled_to == nil, "a cover that can't fit must not be scaled")
    assert(HT:take("/b/3.epub") == nil, "nothing stashed for the third")
    assert(HT:take("/b/1.epub") and HT:take("/b/2.epub"), "the stashed two stay")
end)

t.test("taking one makes room for the next", function()
    local HT = fresh()
    HT.target_h = 1000
    HT:setBudget(400 * 1000 + 100)
    HT:noteSource("/b/1.epub", bb(400, 1000))
    assert(HT:take("/b/1.epub"))
    HT:noteSource("/b/2.epub", bb(400, 1000))
    assert(HT:take("/b/2.epub"), "room freed by take is used")
end)

t.test("the size check counts the source's bytes per pixel", function()
    local HT = fresh()
    HT.target_h = 1000
    HT:setBudget(400 * 1000 + 100)          -- one 8-bit copy, not one 32-bit
    local rgb = bb(400, 1000)
    rgb.stride = 1600                       -- 4 bytes per pixel
    HT:noteSource("/b/c.epub", rgb)
    assert(rgb.scaled_to == nil, "a 32-bit copy is 4x the bytes and doesn't fit")
end)

t.test("switching shelves empties the tier for the new shelf's covers", function()
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    local f = w:match("\nfunction BookshelfWidget:_setActiveChip%(.-\nend\n")
    assert(f, "_setActiveChip not found")
    assert(f:find("bookshelf_hero_tier", 1, true) and f:find(":clear()", 1, true),
        "_setActiveChip does not clear the hero tier")
end)

t.test("drop frees the stashed copy (stale-cover funnel)", function()
    local HT = fresh()
    HT.target_h = 600
    HT:noteSource("/b/a.epub", bb(400, 600))
    HT:drop("/b/a.epub")
    assert(HT:take("/b/a.epub") == nil, "dropped entry must be gone")
end)

t.test("a duplicate noteSource is skipped", function()
    local HT = fresh()
    HT.target_h = 600
    local a = bb(400, 600)
    HT:noteSource("/b/a.epub", a)
    local b2 = bb(999, 600)
    HT:noteSource("/b/a.epub", b2)
    local got = HT:take("/b/a.epub")
    assert(got and got:getWidth() == 400, "the first stash must stand")
end)

t.done()
