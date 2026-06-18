-- Pure-logic tests for lib/bookshelf_module_kit (sc rounding + shape bands).
-- Widget helpers (fitText/valueCard/face) need KOReader widgets and are
-- exercised on-device, not here.
package.path = "./?.lua;./?/init.lua;" .. package.path

-- Stub the kit's two load-time deps so it can be dofile'd standalone.
package.loaded["lib/bookshelf_fonts"] = {
    getFace = function(_self, _name, size) return { size = size } end,
}
package.loaded["lib/bookshelf_start_menu_modules"] = {
    COLOR_PRIMARY = "P", COLOR_MUTED = "M", CARD_BG = "BG",
}

local Kit = dofile("lib/bookshelf_module_kit.lua")
local t = dofile("tests/_helpers.lua").runner()

t.test("sc scales, rounds, and floors at 1", function()
    local sc = Kit.sc(150)
    assert(sc(10) == 15, "150% of 10 => 15, got " .. sc(10))
    assert(sc(0) == 1, "floors at 1, got " .. sc(0))
    local sc100 = Kit.sc(nil) -- nil scale_pct => 100%
    assert(sc100(14) == 14, "nil => 100%, got " .. sc100(14))
end)

t.test("shape returns aspect bands", function()
    assert(Kit.shape(400, nil) == "wide", "no avail_h => wide")
    assert(Kit.shape(400, 100) == "wide", "ratio 4.0 => wide")
    assert(Kit.shape(300, 280) == "square", "ratio ~1.07 => square")
    assert(Kit.shape(120, 400) == "tall", "ratio 0.3 => tall")
end)

t.test("colour roles re-exported from the modules module", function()
    assert(Kit.COLOR_PRIMARY == "P" and Kit.COLOR_MUTED == "M" and Kit.CARD_BG == "BG",
        "colour roles not re-exported")
end)

t.done()
