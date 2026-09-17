-- tests/_test_ornament_per_shelf.lua
-- Ornament frequency is a per-shelf pin, set where it is relevant.
--
-- WHAT NEEDS PINNING. The control lived in the library settings, two menus
-- away from the only mode it affects, and applied to every shelf at once.
-- It now sits in the shelf style dialog, in the spine-only block, and a chip
-- may pin its own: a crowded shelf on one and a bare one on another
-- (maintainer). An untouched chip stores ABSENCE and shows the word its
-- default resolves to; there is no "Default" stop, because on a dial this
-- short a value the reader cannot see is a trap.
--
-- The stops also have to LOOK different from each other. pick() multiplies
-- the base odds by the level and skips the roll once the product reaches 1,
-- so two stops that both saturate are the same picture on a plain shelf.
-- That shipped: Often (2) and Lots (3) were indistinguishable.
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

t.test("no pin means the module's own default, not a library setting", function()
    -- There is deliberately nothing behind the pin: a library-wide default
    -- that every shelf can override is a trap, since changing it later moves
    -- nothing (maintainer). An untouched shelf gets FREQ_DEFAULT.
    eq(frequencyWith(nil, 2), 1)
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
    assert(block:find("tab[Orn.FREQ_SETTING]", 1, true),
        "the chip's OWN value is pushed; _chipListValue would fall back to a library setting")
    assert(not block:find("_chipListValue(Orn.FREQ_SETTING)", 1, true),
        "no library fallback: there is no library-wide frequency")
end)

-- The stop list, as the dialog declares it.
local STOPS = (function()
    -- To the closing brace at the list's own indentation: a plain "}" stops
    -- at the end of the first entry.
    local block = editor:match("local ORN_STOPS = {(.-)\n            }")
    assert(block, "the ornament stops are missing from the style dialog")
    local out = {}
    for value, word in block:gmatch("value = ([%d%.]+),%s*label = function%(%) return _%(\"([^\"]+)\"%)") do
        out[#out + 1] = { value = tonumber(value), word = word }
    end
    return out
end)()

t.test("four stops, in the maintainer's words, and no hidden Default", function()
    local words = {}
    for i, stop in ipairs(STOPS) do words[i] = stop.word end
    eq(table.concat(words, ","), "None,Rarely,Often,Always")
    assert(not editor:find('return _("Default")', 1, true),
        "a Default stop stores a value the reader cannot see")
end)

t.test("every stop looks different from the one before it", function()
    -- THE BUG. pick() does:
    --     local chance = (o.chance or M.CHANCE) * M.frequency()
    --     if chance < 1 and (h % 100) >= math.floor(chance * 100) then return nil end
    -- so once base * level reaches 1 the roll is skipped and EVERY eligible
    -- gap takes a piece. Two stops above that line are one stop wearing two
    -- names, which is what Often (2) and Lots (3) were.
    local base = tonumber(orn:match("\nM%.CHANCE%s*=%s*([%d%.]+)"))
    assert(base, "M.CHANCE moved or was renamed")
    local saturated = 0
    for i, stop in ipairs(STOPS) do
        local chance = base * stop.value
        if chance >= 1 then saturated = saturated + 1 end
        if i > 1 then
            local prev = base * STOPS[i - 1].value
            assert(chance > prev,
                stop.word .. " is not denser than " .. STOPS[i - 1].word)
        end
    end
    eq(saturated, 1,
        "only the top stop may fill every gap; " .. saturated .. " stops saturate, "
        .. "so the ones above the first are the same picture")
end)

t.test("an untouched chip shows its default's word, by nearest stop", function()
    local at = editor:match("local function ornAt%(%)\n(.-)\n            end\n")
    assert(at, "ornAt moved or was renamed")
    assert(at:find("Orn.FREQ_DEFAULT", 1, true),
        "nil must resolve to the module's default, not to the first stop")
    assert(at:find("math.abs", 1, true),
        "nearest stop, so a value from an older build cannot fall off the list")
end)

t.test("the row sits in the spine block, paired with the author tick", function()
    local author_at = editor:find('local function authorOn()', 1, true)
    local stops_at  = editor:find("local ORN_STOPS", 1, true)
    assert(author_at and stops_at and stops_at > author_at,
        "the row belongs in the spine block, not the general one")
    -- One row, two buttons: the maintainer asked for the author switch beside
    -- the ornament dial rather than on a line of its own.
    local row = editor:match("(rows%[#rows %+ 1%] = {\n                { text_func = function%(%)\n"
        .. "                      return %(authorOn.-\n            }\n)")
    assert(row, "the author and ornament buttons are no longer one row")
    assert(row:find("_(\"Ornaments\")", 1, true), "the ornament dial shares the row")
end)

t.test("the author switch is a tick, the same mark the face-out picker uses", function()
    local tick = editor:match('local TICK, BLANK = ("\\x%x%x\\x%x%x\\x%x%x ")')
    assert(tick, "the tick constant moved")
    assert(editor:find("(authorOn() and TICK or BLANK) .. _(\"Author on spine\")", 1, true),
        "Author on spine must render as a tick box, not a Yes/No label")
    assert(not editor:find("toggleRow", 1, true),
        "the Yes/No row helper is dead once nothing calls it")
end)

t.test("the live preview carries the pin, like the other spine pins", function()
    assert(editor:find("override.ornament_frequency  = draft.ornament_frequency", 1, true),
        "a pinned frequency must preview on the shelf behind the dialog")
end)

t.done()
