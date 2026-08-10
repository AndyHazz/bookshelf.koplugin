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
-- scaleBySize stubbed to identity so twoColMinWidth() is exactly 300 here and
-- the width band can be asserted with real numbers rather than a DPI-derived one.
package.loaded["device"] = {
    screen = { scaleBySize = function(_self, n) return n end },
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
    assert(Kit.shape(400, 100) == "wide", "ratio 4.0 => wide")
    assert(Kit.shape(300, 280) == "square", "ratio ~1.07 => square")
    assert(Kit.shape(120, 400) == "tall", "ratio 0.3 => tall")
end)

-- With no height there is no aspect to band, so the choice is made on width
-- alone against the same two-column threshold the hero/full-screen grid uses
-- to size a flex cell. This is what stops a narrow start-menu card from
-- claiming the two-column layout (and what lets a widened panel take it).
t.test("shape falls back to a width band when avail_h is absent", function()
    assert(Kit.twoColMinWidth() == 300, "identity-stubbed threshold, got "
        .. tostring(Kit.twoColMinWidth()))
    assert(Kit.shape(400, nil) == "wide", "wide enough for two columns => wide")
    assert(Kit.shape(300, nil) == "wide", "exactly at the threshold => wide")
    assert(Kit.shape(299, nil) == "square", "just under the threshold => square")
    assert(Kit.shape(120, nil) == "square", "narrow => square")
    assert(Kit.shape(400, 0) == "wide", "zero avail_h treated as absent")
    assert(Kit.shape(nil, nil) == "square", "nil width must not error")
end)

t.test("colour roles re-exported from the modules module", function()
    assert(Kit.COLOR_PRIMARY == "P" and Kit.COLOR_MUTED == "M" and Kit.CARD_BG == "BG",
        "colour roles not re-exported")
end)

-- ── fmtDuration (shared, gettext-wrapped) ───────────────────────────────────
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
package.loaded["ffi/util"] = {
    template = function(str, ...)
        local args = { ... }
        return (str:gsub("%%(%d)", function(n) return tostring(args[tonumber(n)]) end))
    end,
}

t.test("fmtDuration bands: minutes / whole hours / mixed", function()
    assert(Kit.fmtDuration(45 * 60) == "45m", Kit.fmtDuration(45 * 60))
    assert(Kit.fmtDuration(3600) == "1h", Kit.fmtDuration(3600))
    assert(Kit.fmtDuration(3660) == "1h 01m", "minutes zero-padded: "
        .. Kit.fmtDuration(3660))
    assert(Kit.fmtDuration(2 * 3600) == "2h", "whole hours drop the 00m: "
        .. Kit.fmtDuration(2 * 3600))
end)

t.test("fmtDuration clamps garbage to 0m", function()
    assert(Kit.fmtDuration(0) == "0m")
    assert(Kit.fmtDuration(-90) == "0m", "negative clamps")
    assert(Kit.fmtDuration(nil) == "0m", "nil clamps")
    assert(Kit.fmtDuration("bogus") == "0m", "non-number clamps")
end)

-- ── radioRow / settingsReopen (settings-dialog helpers) ─────────────────────
t.test("radioRow text: checkmark when active, aligned spaces otherwise", function()
    local on  = Kit.radioRow{ label = "12-hour", active = true,  on_pick = function() end }
    local off = Kit.radioRow{ label = "12-hour", active = false, on_pick = function() end }
    assert(on.text  == "\xE2\x9C\x93 12-hour", on.text)
    assert(off.text == "  12-hour", off.text)
    local num = Kit.radioRow{ label = 24, active = false, on_pick = function() end }
    assert(num.text == "  24", "numeric labels are tostring'd: " .. num.text)
end)

t.test("radioRow: tapping the active row is a no-op unless toggle", function()
    local picked = 0
    local pick = function() picked = picked + 1 end
    Kit.radioRow{ label = "x", active = true, on_pick = pick }.callback()
    assert(picked == 0, "active radio must not re-fire")
    Kit.radioRow{ label = "x", active = false, on_pick = pick }.callback()
    assert(picked == 1, "inactive radio fires")
    Kit.radioRow{ label = "x", active = true, toggle = true, on_pick = pick }.callback()
    assert(picked == 2, "active TOGGLE row still fires")
end)

t.test("settingsReopen closes, reloads the menu, reopens", function()
    local closed, reloaded, reopened_ctx
    package.loaded["ui/uimanager"] = {
        close = function(_self, w) closed = w end,
    }
    local dialog = { i_am = "dialog" }
    local ctx = { menu = { _reload = function(self) reloaded = true end } }
    Kit.settingsReopen(ctx, dialog, function(c) reopened_ctx = c end)
    assert(closed == dialog, "dialog closed")
    assert(reloaded, "menu reloaded beneath")
    assert(reopened_ctx == ctx, "settings reopened with the same ctx")
end)

t.test("settingsReopen tolerates missing ctx/menu/reopen", function()
    package.loaded["ui/uimanager"] = { close = function() end }
    Kit.settingsReopen(nil, {}, nil)               -- no ctx, no reopen
    Kit.settingsReopen({ menu = {} }, {}, nil)      -- menu without _reload
end)

-- ── hitRegion (per-region tap contract) ─────────────────────────────────────
local REGIONS = {
    { id = "book1", x = 0,   y = 0,  w = 90, h = 135 },
    { id = "book2", x = 100, y = 0,  w = 90, h = 135 },
    { id = "row",   x = 0,   y = 0,  w = 300, h = 200 },  -- overlaps both
}

t.test("hitRegion: inside / outside / gaps", function()
    assert(Kit.hitRegion(REGIONS, 10, 10) == "book1")
    assert(Kit.hitRegion(REGIONS, 150, 100) == "book2")
    assert(Kit.hitRegion(REGIONS, 95, 10) == "row",
        "the gap between covers falls through to the overlapping row region")
    assert(Kit.hitRegion(REGIONS, 400, 400) == nil, "outside everything")
end)

t.test("hitRegion: first declared match wins (most-specific first)", function()
    -- book1 and row both contain (10,10); book1 is declared first.
    assert(Kit.hitRegion(REGIONS, 10, 10) == "book1")
end)

t.test("hitRegion: edges are half-open (x, x+w)", function()
    assert(Kit.hitRegion(REGIONS, 0, 0) == "book1", "top-left corner inside")
    assert(Kit.hitRegion({ REGIONS[1] }, 90, 0) == nil, "right edge exclusive")
    assert(Kit.hitRegion({ REGIONS[1] }, 0, 135) == nil, "bottom edge exclusive")
end)

t.test("hitRegion: second return is the region table", function()
    local id, r = Kit.hitRegion(REGIONS, 150, 10)
    assert(id == "book2" and r == REGIONS[2])
end)

t.test("hitRegion fails closed on malformed input", function()
    assert(Kit.hitRegion(nil, 10, 10) == nil)
    assert(Kit.hitRegion(REGIONS, nil, 10) == nil)
    assert(Kit.hitRegion(REGIONS, 10, nil) == nil)
    assert(Kit.hitRegion({ { id = "bad", x = "0", y = 0, w = 9, h = 9 } }, 1, 1) == nil,
        "a malformed region is skipped, not an error")
    assert(Kit.hitRegion({ "not a table", REGIONS[1] }, 10, 10) == "book1",
        "junk entries are skipped; later valid regions still match")
end)

t.done()
