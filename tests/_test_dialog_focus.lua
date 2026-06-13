-- Pure-Lua suite for lib/bookshelf_focus (the safe-reinit helper for
-- non-touch keyboard navigation). Run by tests/run.sh under standalone `lua`.
--
-- Background (issue #133): KOReader's ButtonDialog:reinit() does free()+init().
-- free() (WidgetContainer:free) does NOT clear self.layout, and init() sets
--   self.layout = self.layout or self.buttontable.layout
-- so on the SECOND init the stale (already-freed) layout wins the `or` and the
-- freshly-built buttontable.layout is discarded. On non-touch devices the
-- FocusManager then drives dead widgets: the cursor lands on nothing, and the
-- user is locked out of the dialog (no controls to move/accept). Touch devices
-- are unaffected because they never consult self.layout.
--
-- The helper nils dialog.layout before reinit (so init() adopts the fresh
-- buttontable layout) and then refocuses (so the cursor highlight reappears on
-- the new button at the preserved self.selected position).

package.path = "./?.lua;./?/init.lua;" .. package.path

local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()

local Focus = require("lib/bookshelf_focus")

-- A minimal stand-in that reproduces upstream ButtonDialog's reinit semantics
-- faithfully: each init() builds a brand-new buttontable with its own layout,
-- and the `self.layout or ...` short-circuit keeps any pre-existing layout.
-- free() deliberately leaves self.layout untouched, like WidgetContainer:free.
local function newFakeDialog()
    local d = {
        selected = { x = 1, y = 2 },  -- a non-default cursor we expect preserved
        refocus_calls = 0,
        refocus_args = {},
    }
    function d:init()
        -- a fresh buttontable each init, with a fresh (distinct) layout table
        self.buttontable = { layout = { {"Book"}, {"Bookshelf"}, {"Cancel", "Accept"} } }
        self.layout = self.layout or self.buttontable.layout
        self.buttontable.layout = nil
    end
    function d:free() end  -- WidgetContainer:free does not nil self.layout
    function d:reinit()
        self:free()
        self:init()
    end
    function d:refocusWidget(nextTick)
        self.refocus_calls = self.refocus_calls + 1
        self.refocus_args[#self.refocus_args + 1] = nextTick
    end
    d:init()
    return d
end

t.test("naked reinit leaves a stale layout (reproduces the #133 bug)", function()
    local d = newFakeDialog()
    local first_layout = d.layout
    d:reinit()
    -- The bug: after reinit the dialog still points at the first (freed) layout.
    assert(d.layout == first_layout, "expected the stale layout to win the `or`")
    assert(d.layout ~= d.buttontable.layout or d.buttontable.layout == nil,
        "stale layout should not match the freshly built buttontable layout")
end)

t.test("Focus.reinit adopts the freshly built layout", function()
    local d = newFakeDialog()
    local first_layout = d.layout
    Focus.reinit(d)
    assert(d.layout ~= first_layout, "expected a fresh layout after Focus.reinit")
end)

t.test("Focus.reinit re-applies focus on the next tick", function()
    local d = newFakeDialog()
    Focus.reinit(d)
    assert(d.refocus_calls == 1, "expected refocusWidget called exactly once")
    assert(d.refocus_args[1] == true, "expected refocusWidget(nextTick=true)")
end)

t.test("Focus.reinit preserves the cursor position", function()
    local d = newFakeDialog()
    Focus.reinit(d)
    helpers.eq(d.selected, { x = 1, y = 2 }, "cursor should survive reinit")
end)

t.test("Focus.reinit tolerates a dialog without refocusWidget", function()
    local d = newFakeDialog()
    d.refocusWidget = nil
    Focus.reinit(d)  -- must not error
    assert(d.layout ~= nil)
end)

t.done()
