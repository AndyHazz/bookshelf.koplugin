-- tests/_test_ornament_per_shelf.lua
-- Ornament frequency is a per-shelf pin, set where it is relevant.
--
-- WHAT NEEDS PINNING. The control lived in the library settings, two menus
-- away from the only mode it affects, and applied to every shelf at once.
-- It now sits in the shelf style dialog, in the spine-only block, and a chip
-- may pin its own: a crowded shelf on one and a bare one on another
-- (maintainer). Default is a stop of its own and stores ABSENCE, so an
-- untouched chip follows the library setting for ever after, which is the
-- same nil-means-default rule every other pin in that dialog uses.
--
-- The module reads the value at PLAN time, so the widget has to push it
-- before it builds anything, next to the other build-time flags.
--
-- Usage (from plugin root): lua tests/_test_ornament_per_shelf.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq
local orn    = io.open("lib/bookshelf_ornaments.lua"):read("*a")
local widget = io.open("lib/bookshelf_widget.lua"):read("*a")
local editor = io.open("lib/bookshelf_chip_editor.lua"):read("*a")

local body = orn:match("\nfunction M%.frequency%(%)\n(.-)\nend\n")
assert(body, "M.frequency moved or was renamed")

local function frequencyWith(pinned, stored)
    local env = {
        M = { _chip_frequency = pinned, FREQ_DEFAULT = 1, FREQ_SETTING = "ornament_frequency" },
        pcall = pcall, type = type,
        require = function() return { read = function() return stored end } end,
    }
    local fn = assert(load("return function()\n" .. body .. "\nend", "frequency", "t", env))
    return fn()()
end

t.test("a shelf's own pin wins over the library setting", function()
    eq(frequencyWith(3, 1), 3)
    eq(frequencyWith(0, 2), 0, "a pinned None must not fall through to the library value")
end)

t.test("no pin falls back to the library setting", function()
    eq(frequencyWith(nil, 2), 2)
end)

t.test("a pin is clamped the same as the library value", function()
    eq(frequencyWith(9, 1), 4)
end)

t.test("setChipFrequency takes a number and treats anything else as unpinned", function()
    local setter = orn:match("\nfunction M%.setChipFrequency%(v%)\n(.-)\nend\n")
    assert(setter, "M.setChipFrequency missing")
    assert(setter:find('type(v) == "number"', 1, true), "only a number is a pin")
    assert(setter:find("v >= 0", 1, true), "a negative is not a frequency")
end)

t.test("the shelf is told before it builds anything, with the chip resolver", function()
    local block = widget:match("\n    do\n        local on = self:groundIsPainted%(%)\n(.-)\n    end\n")
    assert(block, "the early build-time block moved")
    assert(block:find("setChipFrequency", 1, true), "the frequency must be pushed in that block")
    assert(block:find("self:_chipListValue(Orn.FREQ_SETTING)", 1, true),
        "the chip's pin resolves against the library setting through _chipListValue")
end)

t.test("the style dialog offers it, in the spine block, with a Default stop", function()
    -- To the closing brace at the list's own indentation: a plain "}" stops
    -- at the end of the first entry.
    local stops = editor:match("local ORN_STOPS = {(.-)\n            }")
    assert(stops, "the ornament stops are missing from the style dialog")
    assert(stops:find("value = nil", 1, true), "Default must store absence")
    for _, word in ipairs({ "Default", "None", "Rare", "Occasional", "Often", "Lots" }) do
        assert(stops:find('_("' .. word .. '")', 1, true), "missing stop: " .. word)
    end
    -- Spine-only: it sits with the other spine pins, after the author toggle.
    local author_at = editor:find('toggleRow(_("Author on spine")', 1, true)
    local stops_at  = editor:find("local ORN_STOPS", 1, true)
    assert(author_at and stops_at and stops_at > author_at,
        "the row belongs in the spine block, not the general one")
end)

t.test("the live preview carries the pin, like the other spine pins", function()
    assert(editor:find("override.ornament_frequency  = draft.ornament_frequency", 1, true),
        "a pinned frequency must preview on the shelf behind the dialog")
end)

t.done()
