-- tests/_test_dither_flag.lua
-- Who gets the dither hint on a cover refresh.
--
-- ── WHAT WENT WRONG ─────────────────────────────────────────────────────────
--
-- Issue 289 taught the shelf to flag its refreshes `dithered` so covers pick up
-- the panel's dither waveform, and gated it on Screen:isColorEnabled(). The
-- reasoning was that it had "no effect on B&W panels". That is not what decides
-- it -- UIManager does:
--
--     if not Screen.hw_dithering then
--         refresh.dither = nil
--     end
--
-- The gate is the DEVICE's dithering support, not whether the panel is colour.
-- Kindles report canHWDither = no, so the flag is a no-op there however it is
-- set, which is why this was invisible to us. Kobo sets canHWDither = yes, and
-- Android (Boox) can too -- greyscale devices where the hint does real work,
-- and where a photographic cover on sixteen grey levels needs it most.
--
-- Reported from an Onyx Boox Go 6: "the book covers are very grainy. If I
-- toggle the night mode, it would fix itself but when I click anything else, it
-- would go back" -- a night-mode toggle forces a full refresh with a different
-- waveform, so it looks right for exactly one frame.
--
-- KOReader's own cover browser never gated on colour; it gates on having covers
-- (covermenu.lua: self.show_parent.dithered = self._has_cover_images).
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

t.test("a greyscale panel gets the hint too", function()
    -- The bug. UIManager drops it on devices that cannot dither, so this is
    -- free on a Kindle and load-bearing on a Kobo or a Boox.
    assert(run(false, true),
        "a B&W panel got no dither hint, so its covers keep the grainy "
        .. "partial-refresh waveform until something forces a full refresh")
end)

t.test("a colour panel still gets it", function()
    assert(run(true, true), "the colour path regressed")
end)

t.test("the opt-out still works", function()
    -- Colour panels keep the #289 comparison toggle.
    assert(not run(true, false), "the setting no longer turns it off")
end)

t.test("the flag is nil rather than false when off", function()
    -- UIManager reads it as a hint, and `false` is not the same as absent in
    -- update_dither's folding; the original was careful about this.
    local v = run(true, false)
    assert(v == nil, "expected nil, got " .. tostring(v))
end)

t.done()
