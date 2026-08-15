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

t.done()
