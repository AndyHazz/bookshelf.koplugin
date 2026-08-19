-- tests/_test_view_mode.lua
-- Pure-Lua tests for the list/cover view-mode model.
-- Usage (from plugin root): lua tests/_test_view_mode.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local helpers = dofile("tests/_helpers.lua")
local t       = helpers.runner()
local eq      = helpers.eq

local ViewMode = require("lib/bookshelf_view_mode")

-- ── The model: two independent persisted booleans ──────────────────────────
--
-- One per shelf state. Each decides its own state and says nothing about the
-- other, so the truth table is a lookup with no arbitration in it. This
-- replaced a persisted setting plus a session override that outranked it in
-- both directions -- see the module header for why that went.

-- (expanded, list_when_expanded, list_when_collapsed) -> effective

-- ── The Auto policy ────────────────────────────────────────────────────────
--
-- Three global toggles used to decide this; they are gone, replaced by one
-- fixed policy under the per-chip pin: "show as 'list / covers / auto: list
-- when expanded or lists inside folders'". These pin the policy IS that
-- sentence, and that nothing configurable is left inside it.

t.test("auto is covers collapsed, a list expanded", function()
    eq(ViewMode.effective(false, false), ViewMode.COVERS)
    eq(ViewMode.effective(true, false), ViewMode.LIST)
end)

t.test("auto is a list inside anything drilled into, whatever the shelf state",
function()
    eq(ViewMode.effective(false, true), ViewMode.LIST)
    eq(ViewMode.effective(true, true), ViewMode.LIST)
end)

t.test("the resolver reads no settings at all", function()
    -- The policy is fixed on purpose. A settings read inside effective() is
    -- the old model growing back; the only configuration left is the chip pin,
    -- which the CALLER consults first.
    local src = io.open("lib/bookshelf_view_mode.lua"):read("*a")
    src = src:gsub("%-%-[^\n]*", "")
    assert(not src:match("Settings"), "the resolver must stay settings-free")
    assert(not src:match("require"), "the resolver must stay dependency-free")
end)

t.test("the chip override accepts the two modes and nothing else", function()
    eq(ViewMode.chipOverride(ViewMode.LIST), ViewMode.LIST)
    eq(ViewMode.chipOverride(ViewMode.COVERS), ViewMode.COVERS)
    eq(ViewMode.chipOverride(nil), nil)
    eq(ViewMode.chipOverride("grid-of-the-future"), nil,
        "a value from a later release must degrade to Auto, not to a crash")
    eq(ViewMode.chipOverride(true), nil)
end)

t.test("the global keys are gone from the module", function()
    eq(ViewMode.KEY_EXPANDED, nil)
    eq(ViewMode.KEY_COLLAPSED, nil)
    eq(ViewMode.KEY_IN_FOLDER, nil)
    eq(ViewMode.keyFor, nil)
end)

t.test("isList answers the mode, not truthiness", function()
    assert(ViewMode.isList(ViewMode.LIST))
    assert(not ViewMode.isList(ViewMode.COVERS))
    assert(not ViewMode.isList(nil))
end)

t.done()
