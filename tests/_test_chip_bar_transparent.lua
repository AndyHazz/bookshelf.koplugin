-- tests/_test_chip_bar_transparent.lua
-- "Transparent shelf menu" leaves out the bar behind the chips.
--
-- Usage (from plugin root): lua tests/_test_chip_bar_transparent.lua
--
-- Shelf menu background is a colour, and "none" is not one its pickers can
-- offer, so transparency is its own row. It reuses the path Panel shading's
-- Transparent already takes for this strip (no solid ground), without touching
-- the panels. The start menu is painted from the same chrome_bg and is left
-- alone: this is a key the chip bar reads, not a change to the colour.

package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()

local w  = io.open("lib/bookshelf_widget.lua"):read("*a")
local st = io.open("lib/bookshelf_settings.lua"):read("*a")
local sm = io.open("lib/bookshelf_start_menu.lua"):read("*a")

t.test("the chip bar drops its ground when the row is on", function()
    local expr = w:match("solid_ground%s*=%s*(.-),\n%s+active%s*=")
    assert(expr, "the chip bar's solid_ground moved")
    assert(expr:find("self:wallpaperScrimStrength() > 0", 1, true),
        "Transparent panel shading no longer clears it")
    assert(expr:find('not BookshelfSettings.isTrue("chip_bar_transparent")', 1, true),
        "the new row does nothing")
end)

t.test("the row toggles the key the bar reads", function()
    assert(st:find('text = _("Transparent shelf menu")', 1, true))
    assert(st:find('BookshelfSettings.save("chip_bar_transparent",', 1, true))
end)

t.test("Reset to default colors turns it off again", function()
    local keys = st:match("local keys = (%b{})")
    assert(keys and keys:find('"chip_bar_transparent"', 1, true))
end)

t.test("the start menu does not read it, so it stays solid", function()
    assert(not sm:find("chip_bar_transparent", 1, true))
end)

t.done()
