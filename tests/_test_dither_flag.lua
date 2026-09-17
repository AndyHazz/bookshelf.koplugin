-- tests/_test_dither_flag.lua
-- Who gets the dither hint on a cover refresh.
--
-- ── WHY THE GATE IS BACK ────────────────────────────────────────────────────
--
-- Issue 289 taught the shelf to flag its refreshes `dithered` so covers pick
-- up the panel's dither waveform, gated on Screen:isColorEnabled(). v5.0.8
-- removed that gate on the reasoning that what decides whether the hint does
-- anything is the DEVICE's dithering support, not the panel being colour --
-- UIManager drops it when Screen.hw_dithering is false, which is every Kindle:
--
--     if not Screen.hw_dithering then
--         refresh.dither = nil
--     end
--
-- True as far as it goes, and it is why none of this was reproducible on the
-- PW5. What it missed is the cost on the devices where the hint IS honoured.
-- A dithered refresh on a Kobo is not the same refresh with a better waveform;
-- it is promoted, and the flag is viral -- UIManager tags the whole queue once
-- a dithered widget is in it. Two greyscale Kobos reported the result:
--
--   * Libra 2 (issue 408): an extra refresh when restarting KOReader and when
--     exiting a book, new in v5.0.8. Disabling HW dithering in KOReader's own
--     developer options stops it.
--   * Clara BW (same reporter): every touch on a cover refreshes it. A Clara
--     Colour beside it does not.
--
-- The Boox Go 6 report that motivated dropping the gate was never confirmed
-- fixed by it -- that reporter also ended up disabling HW dithering.
--
-- So: colour panels, where the washed-out symptom is real and the row's own
-- label describes it, keep the hint. Greyscale panels do not get it by
-- default, which is where v5.0.7 and earlier were.
--
-- Usage (from plugin root): lua tests/_test_dither_flag.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = dofile("tests/_helpers.lua")
local t = H.runner()

local src = assert(io.open("lib/bookshelf_widget.lua")):read("*a")
local body = src:match("\n(function BookshelfWidget:_refreshDitherFlag%(.-\nend)\n")
assert(body, "_refreshDitherFlag moved or was renamed")

local function run(is_colour, setting)
    local env = {
        BookshelfWidget = {},
        Screen = { isColorEnabled = function() return is_colour end },
        BookshelfSettings = { nilOrTrue = function() return setting end },
    }
    local code = body .. "\nEXPORT = BookshelfWidget._refreshDitherFlag"
    local f
    if _G.setfenv then
        f = assert(_G.loadstring(code, "dither")); _G.setfenv(f, env)
    else
        f = assert(load(code, "dither", "t", env))
    end
    f()
    local self_ = {}
    env.EXPORT(self_)
    return self_.dithered
end

t.test("a colour panel gets the hint", function()
    assert(run(true, true), "the #289 fix regressed")
end)

t.test("a greyscale panel does not, whatever the setting says", function()
    -- The v5.0.8 regression. On a device that honours the hint this promotes
    -- refreshes the shelf did not ask to promote, and the flag spreads through
    -- the queue from there.
    assert(run(false, true) == nil,
        "a B&W panel was handed the dither hint; on a Kobo that is an extra "
        .. "refresh on restart, on exiting a book, and on touching a cover")
    assert(run(false, false) == nil, "still nil with the tweak off")
end)

t.test("the opt-out still works on colour", function()
    assert(not run(true, false), "the setting no longer turns it off")
end)

t.test("the flag is nil rather than false when off", function()
    -- UIManager reads it as a hint, and `false` is not the same as absent in
    -- update_dither's folding; the original was careful about this.
    local v = run(true, false)
    assert(v == nil, "expected nil, got " .. tostring(v))
end)

t.done()
