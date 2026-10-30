-- tests/_test_module_picker_page.lua
-- The module picker as a page of the shelf editor (Home > Modules). A page
-- fills its height with rows of cards (LibraryModal), counted at the 64dp of
-- a list row; a module card holds a live preview, its title and a summary,
-- several times that. On a PW5 the page gave each card 106px where it needs
-- about 350, so every preview was cut short and every title ran into the
-- card below (maintainer). The picker now sizes its own area, as the Theme
-- library does: two rows of cards at their own height, given up to SQUEEZE
-- of it to fit a page, one row only when even that does not fit.
-- Run from the plugin root: lua tests/_test_module_picker_page.lua
package.path = "./?.lua;" .. package.path
local t  = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq
local src = io.open("lib/bookshelf_module_picker.lua"):read("*a")

local body = src:match("\nfunction ModulePicker%._areaFor%(room, unit, gap, units%)\n(.-)\nend\n")
assert(body, "could not find ModulePicker._areaFor - renamed?")
local MP = { AREA_ROWS = tonumber(src:match("\nModulePicker%.AREA_ROWS%s*=%s*(%d+)")),
             SQUEEZE = tonumber(src:match("\nModulePicker%.SQUEEZE%s*=%s*([%d.]+)")) }
assert(MP.AREA_ROWS and MP.SQUEEZE, "AREA_ROWS or SQUEEZE moved")
local env = setmetatable({ ModulePicker = MP }, { __index = _G })
local chunk = (loadstring or load)("local room, unit, gap, units = ...\n" .. body, "areaFor", "t", env)
if setfenv then setfenv(chunk, env) end
local function areaFor(room, units) return chunk(room, 120, 19, units or MP.AREA_ROWS) end

-- PW5 numbers: a 64dp row is 120px, the modal's margin 19px.
local natural = 6 * 120 + 5 * 19       -- the area the picker had as a window
local card = math.floor((natural - 19) / 2)

t.test("as a window, with room to spare: two rows at their own height", function()
    local h, rows = areaFor(1400)
    eq(h, natural); eq(rows, 2)
    h, rows = areaFor(nil)
    eq(h, natural); eq(rows, 2)
end)

t.test("on the editor's page (a little short): two rows, squeezed to fit", function()
    for _, room in ipairs({ 640, 585 }) do   -- the rig's page; the PW5's, chips in two rows
        local h, rows = areaFor(room)
        eq(rows, 2)
        assert(h <= room, string.format("room %d: area %d overflows", room, h))
        local each = (h - 19) / 2
        assert(each >= card * (1 - MP.SQUEEZE), string.format("room %d: cards %d, own %d", room, each, card))
        assert(each > 2 * 120, string.format("room %d: cards of %d, list rows again", room, each))
    end
end)

t.test("far too short for two: one row, no taller than the room", function()
    local h, rows = areaFor(400)
    eq(rows, 1)
    assert(h <= 400 and h > 300, "one row of " .. h)
end)

t.test("landscape keeps the window's one-row-shorter area", function()
    local h = areaFor(nil, MP.AREA_ROWS - 1)
    eq(h, 5 * 120 + 4 * 19)
end)

t.test("the picker sizes its own area and pages by the rows it fits", function()
    assert(src:find("area_height = function(_cw, room)", 1, true), "no area_height: the page's 64dp rows again")
    assert(src:find("cells_per_page = function() return cols() * rows end", 1, true),
        "the page count does not follow the rows that fit")
end)

t.done()
