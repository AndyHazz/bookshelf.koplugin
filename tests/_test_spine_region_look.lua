-- tests/_test_spine_region_look.lua
-- A spine-out series box prints its first cover across its spines. Each
-- spine takes its colour from the strip of that picture it stands behind
-- (SpineShelf.lookFromRegion), so the band behind its title matches the
-- picture rather than its own book's cover. The same sampling, lettering
-- clamp and Image contrast boost as a spine's own look.
-- Run from the plugin root: lua tests/_test_spine_region_look.lua
package.path = "./?.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq
local F = dofile("tests/_binding_fixture.lua")
package.loaded["lib/bookshelf_book_facts_db"] = { get = function() return nil end,
    put = function() end, drop = function() end, flush = function() end,
    migrateFrom = function() return 0 end }
package.loaded["lib/bookshelf_image_contrast"] = { spineLook = function(look) return look end }
local Shelf = require("lib/bookshelf_spine_shelf")

-- A picture whose left half is dark red and right half bright yellow.
local function picture()
    local bb = F.surface(40, 60)
    function bb:getPixel(x)
        local c = x < 20 and { r = 100, g = 20, b = 20 } or { r = 250, g = 230, b = 40 }
        return { getColorRGB32 = function() return c end }
    end
    return bb
end

t.test("a region's look is that region's colour, not the whole picture's", function()
    local left = Shelf.lookFromRegion(picture(), 0, 0, 20, 60)
    eq(left.r, 100); eq(left.g, 20); eq(left.b, 20)
    eq(left.sampled, true)
end)

t.test("a bright region is held dark enough for the spine's light lettering", function()
    local right = Shelf.lookFromRegion(picture(), 20, 0, 20, 60)
    local luma = 0.299 * right.r + 0.587 * right.g + 0.114 * right.b
    assert(luma <= 111, "a bright strip left the title unreadable: luma " .. luma)
    assert(right.r > right.b, "the clamp lost the strip's hue")
end)

t.test("in night mode the stored picture is inverted: the look is the day colour", function()
    local inv = F.surface(40, 60)
    function inv:getPixel()
        return { getColorRGB32 = function() return { r = 155, g = 235, b = 235 } end }
    end
    local look = Shelf.lookFromRegion(inv, 0, 0, 40, 60, true)
    eq(look.r, 100); eq(look.g, 20); eq(look.b, 20)
end)

t.test("an empty region gives nothing, not a crash", function()
    eq(Shelf.lookFromRegion(picture(), 0, 0, 0, 60), nil)
end)

t.done()
