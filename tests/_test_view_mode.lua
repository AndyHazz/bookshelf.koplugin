-- tests/_test_view_mode.lua
-- Pure-Lua tests for the list/cover view-mode state machine.
-- Usage (from plugin root): lua tests/_test_view_mode.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local helpers = dofile("tests/_helpers.lua")
local t       = helpers.runner()

local ViewMode = require("lib/bookshelf_view_mode")

-- The full truth table: (expanded, override, list_when_expanded) -> effective.
-- Override beats everything in BOTH directions; that is what lets a user who
-- has the setting on still get covers while expanded.
local CASES = {
    -- expanded, override,  setting, want
    { false,     nil,       false,   "covers" },
    { false,     nil,       true,    "covers" },  -- setting only bites when expanded
    { true,      nil,       false,   "covers" },
    { true,      nil,       true,    "list"   },
    { false,     "list",    false,   "list"   },
    { false,     "covers",  true,    "covers" },
    { true,      "covers",  true,    "covers" },  -- override beats the setting
    { true,      "list",    false,   "list"   },
}

t.test("effective covers the full truth table", function()
    for i, c in ipairs(CASES) do
        local got = ViewMode.effective(c[1], c[2], c[3])
        assert(got == c[4], string.format(
            "case %d (expanded=%s override=%s setting=%s): got %s want %s",
            i, tostring(c[1]), tostring(c[2]), tostring(c[3]), got, c[4]))
    end
end)

t.test("a junk override is ignored, not propagated", function()
    -- Guards against a stale or corrupted value reaching the renderer as a
    -- mode string it cannot dispatch on.
    assert(ViewMode.effective(false, "banana", false) == "covers")
    assert(ViewMode.effective(true, "", true) == "list")
end)

t.test("flip returns the opposite mode", function()
    assert(ViewMode.flip("list") == "covers")
    assert(ViewMode.flip("covers") == "list")
end)

t.test("flip of an unknown mode yields list", function()
    -- Flipping from an unrecognised state should land somewhere useful rather
    -- than preserving the junk.
    assert(ViewMode.flip(nil) == "list")
end)

t.test("isList only accepts the list constant", function()
    assert(ViewMode.isList("list") == true)
    assert(ViewMode.isList("covers") == false)
    assert(ViewMode.isList(nil) == false)
end)

-- ── The session override, as state ─────────────────────────────────────────
-- It lives on the module rather than on the shelf widget, which is what makes
-- the two things below possible: it survives the widget being destroyed and
-- rebuilt (main.lua's cold-create path, every "Close Bookshelf"), matching the
-- help text's promise that a flip "lasts until you hold it again or restart
-- KOReader"; and the settings checkbox can retire it without needing a handle
-- on a live shelf.
t.test("the override round-trips and clears", function()
    ViewMode.clearOverride()
    assert(ViewMode.override() == nil, "the override does not start unset")
    ViewMode.setOverride(ViewMode.LIST)
    assert(ViewMode.override() == ViewMode.LIST)
    ViewMode.clearOverride()
    assert(ViewMode.override() == nil)
end)

t.test("setting a junk override retires it rather than storing it", function()
    -- setOverride(saved) is how _asCoverGrid puts the override back, and
    -- `saved` is nil whenever it was never armed. Storing junk would let a
    -- mode string the renderer cannot dispatch on reach it.
    ViewMode.setOverride(ViewMode.LIST)
    ViewMode.setOverride("banana")
    assert(ViewMode.override() == nil)
    ViewMode.setOverride(ViewMode.COVERS)
    ViewMode.setOverride(nil)
    assert(ViewMode.override() == nil)
end)

t.test("the reported defect: a gesture flip-flop deafens the setting", function()
    -- Reproduced offscreen before it was fixed. Hold the page label to get
    -- list, hold again to get covers back, and the override is "covers" for
    -- the rest of the session -- so ticking "Show as list when shelf is
    -- expanded" afterwards changed nothing, with no UI anywhere to say why.
    ViewMode.clearOverride()
    local expanded, setting = true, false
    -- ... hold once: list.
    ViewMode.setOverride(ViewMode.flip(
        ViewMode.effective(expanded, ViewMode.override(), setting)))
    assert(ViewMode.effective(expanded, ViewMode.override(), setting) == "list")
    -- ... hold again: covers.
    ViewMode.setOverride(ViewMode.flip(
        ViewMode.effective(expanded, ViewMode.override(), setting)))
    assert(ViewMode.override() == ViewMode.COVERS)
    -- Now turn the setting on. This is the state the user was stuck in.
    setting = true
    assert(ViewMode.effective(expanded, ViewMode.override(), setting) == "covers",
        "the override is supposed to beat the setting -- that part is by design")
    -- The fix: changing the persistent preference retires the override.
    ViewMode.clearOverride()
    assert(ViewMode.effective(expanded, ViewMode.override(), setting) == "list",
        "clearing the override did not let the setting through")
end)

t.done()
