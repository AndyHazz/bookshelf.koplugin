-- tests/_test_scale_choice.lua
-- Covers are scaled by whichever scaler is cheaper for the job.
--
-- Measured on a PW5 (KOReader 2026.x) against real 597x901 covers:
-- Blitbuffer:scale is a per-pixel Lua loop, ~0.4 us per OUTPUT pixel (40 ms
-- for a 259x390 shelf cover, 6.5 ms for a 96x144 list thumb); MuPDF's costs
-- by the SOURCE (10-14 ms whatever the target). A Series shelf page spent
-- ~45 ms per stack cover in the Lua loop. Upscales stay on bb:scale (MuPDF
-- upscaling is documented to corrupt on Kindle).
package.path = "./?.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

local calls = {}
package.loaded["ffi/mupdf"] = {
    scaleBlitBuffer = function(src, w, h)
        calls[#calls + 1] = "mupdf"
        if src.mupdf_fails then error("boom") end
        return { w = w, h = h, by = "mupdf" }
    end,
}
local Scale = require("lib/bookshelf_scale")

local function bb(w, h, fails)
    return {
        mupdf_fails = fails,
        getWidth = function() return w end,
        getHeight = function() return h end,
        scale = function(_self, nw, nh) calls[#calls + 1] = "lua"; return { w = nw, h = nh, by = "lua" } end,
    }
end

t.test("a shelf-sized downscale goes to MuPDF", function()
    calls = {}
    local out = Scale.cover(bb(597, 901), 259, 390)
    eq(out.by, "mupdf"); eq(out.w, 259); eq(out.h, 390)
end)

t.test("a small thumbnail stays on the Lua loop, which is cheaper there", function()
    calls = {}
    eq(Scale.cover(bb(597, 901), 96, 144).by, "lua")
    eq(#calls, 1)
end)

t.test("an upscale in either axis never reaches MuPDF", function()
    calls = {}
    eq(Scale.cover(bb(200, 300), 259, 390).by, "lua")
    eq(Scale.cover(bb(300, 300), 259, 390).by, "lua")
    eq(table.concat(calls, " "), "lua lua")
end)

t.test("a MuPDF failure falls back to the Lua loop", function()
    calls = {}
    eq(Scale.cover(bb(597, 901, true), 259, 390).by, "lua")
    eq(table.concat(calls, " "), "mupdf lua")
end)

t.test("the cover paths scale through it", function()
    local SW = io.open("lib/bookshelf_spine_widget.lua"):read("*a")
    local fill = assert(SW:match("\nlocal function _coverFillBB%(bb, img_w, img_h%)\n(.-)\nend\n"))
    assert(not fill:find("bb:scale(", 1, true), "grid covers still scale in Lua")
    local top = assert(SW:match("\nfunction SpineWidget:_renderCoverAlignTop%(.-\nend\n"))
    assert(top:find("_scaleCover(bb, img_w, nat_h)", 1, true), "stack covers still scale in Lua")
    local W = io.open("lib/bookshelf_widget.lua"):read("*a")
    assert(W:find([[return require("lib/bookshelf_scale").cover(bb, job.w, job.h)]], 1, true), "the background cover warm-up still scales in Lua")
    local HT = io.open("lib/bookshelf_hero_tier.lua"):read("*a")
    assert(HT:find('require("lib/bookshelf_scale").cover(src_bb, w, h)', 1, true), "hero copies still scale in Lua")
    local SD = io.open("lib/bookshelf_stack_display.lua"):read("*a")
    assert(SD:find('require("lib/bookshelf_scale").cover(src, cell.w, cell.h)', 1, true), "collage cells still scale in Lua")
end)

t.done()
