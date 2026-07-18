-- tests/_test_hide_menu.lua
-- Regression guard for #288: launching a settings dialog (e.g. "Edit shelf
-- size") as a start-menu shortcut replays the menu item via
-- bookshelf_menu_shortcut.replay, which fires the callback with a duck-typed
-- shim whose show_parent is nil. Bookshelf:hideMenu (main.lua) used to fall
-- back to the instance itself as the "menu container", so the restore closure
-- called UIManager:show(shim) -- pushing a plain table with no paintTo onto the
-- window stack, which crashed on the next paint (on both Accept and Cancel).
-- hideMenu must now hide/re-show ONLY a real container, and no-op the show/hide
-- when the instance carries neither show_parent nor menu_container.

local runner = dofile("tests/_helpers.lua").runner()

-- Lightweight stubs for main.lua's load-time requires. hideMenu only touches
-- the UIManager stub (captured as an upvalue at load); the rest just let
-- main.lua's module body evaluate under a standalone interpreter.
local ui_calls = {}
local function reset_calls() ui_calls = {} end

local WC = {}
WC.__index = WC
function WC:extend(t)
    t = t or {}
    setmetatable(t, { __index = self })
    t.extend, t.new = self.extend, self.new
    return t
end
function WC:new(t) t = t or {}; setmetatable(t, { __index = self }); return t end

package.loaded["ui/widget/container/widgetcontainer"] = WC
package.loaded["lib/bookshelf_settings_store"] =
    { read = function() end, save = function() end, flush = function() end, delete = function() end }
package.loaded["ui/uimanager"] = {
    show    = function(_, w) ui_calls[#ui_calls + 1] = { "show", w } end,
    close   = function(_, w) ui_calls[#ui_calls + 1] = { "close", w } end,
    setDirty = function() end,
    nextTick = function() end,
    scheduleIn = function() end,
}
package.loaded["logger"] = setmetatable({}, { __index = function() return function() end end })
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
package.loaded["ffi/util"] = { template = function(s) return s end }

local Bookshelf = assert(dofile("main.lua"), "main.lua did not return the plugin table")
assert(type(Bookshelf.hideMenu) == "function", "Bookshelf:hideMenu missing")

-- Count UIManager calls that reference a given widget/table.
local function calls_referencing(w)
    local n = 0
    for _, c in ipairs(ui_calls) do
        if c[2] == w then n = n + 1 end
    end
    return n
end

runner.test("nil instance: restore is a safe no-op", function()
    reset_calls()
    local restore = Bookshelf:hideMenu(nil)
    assert(type(restore) == "function", "restore must be callable")
    restore()
    assert(#ui_calls == 0, "no UIManager traffic for a nil instance")
end)

runner.test("#288 shim (no show_parent/menu_container): never shown/closed", function()
    reset_calls()
    local updated = false
    local shim = {
        show_parent = nil,
        updateItems = function() updated = true end,
    }
    local restore = Bookshelf:hideMenu(shim)
    restore()
    -- The shim is a plain table, not a paintable widget: it must never reach
    -- UIManager:show/close, or the next paint crashes.
    assert(calls_referencing(shim) == 0, "shim must never be shown or closed")
    assert(updated, "restore should still refresh the instance via updateItems")
end)

runner.test("real instance: hidden on open, re-shown on restore", function()
    reset_calls()
    local widget = { paintTo = function() end } -- stands in for a paintable container
    local shown = false
    local instance = {
        show_parent = widget,
        updateItems = function() shown = true end,
    }
    local restore = Bookshelf:hideMenu(instance)
    -- hideMenu should have closed the real container immediately.
    assert(ui_calls[1] and ui_calls[1][1] == "close" and ui_calls[1][2] == widget,
        "real container should be closed on hide")
    restore()
    -- ...and re-shown it on restore.
    local saw_show = false
    for _, c in ipairs(ui_calls) do
        if c[1] == "show" and c[2] == widget then saw_show = true end
    end
    assert(saw_show, "real container should be re-shown on restore")
    assert(shown, "restore should refresh the instance via updateItems")
end)

runner.done()
