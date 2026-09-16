-- tests/_test_chip_editor_preview_debounce.lua
-- The chip editor's live preview defers the shelf rebuild and coalesces
-- rapid taps, so the picker answers the next tap at once.
--
-- WHAT NEEDS PINNING. Every visual pick in the shelf-style dialog (face-out
-- reasons, rows, thickness, tiles) ran applyLivePreview, which set the
-- TabModel override and then called opts.on_change synchronously: a full
-- _rebuild of the shelf underneath, several hundred milliseconds on a
-- Kindle in spine mode, before the picker could close and reopen. Taps in
-- that window were dropped (maintainer: "sometimes you may want to tick a
-- few options at once, but there's a lag after tapping one where tapping
-- another does nothing"). Lua has one thread, so the rebuild cannot move off
-- it; it can be moved AFTER the tap. The override is still set at once, the
-- rebuild is scheduled 0.4 s after the LAST change, and Save, Cancel and the
-- X close drop a pending one before doing their own work.
--
-- Usage (from plugin root): lua tests/_test_chip_editor_preview_debounce.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq
local src = io.open("lib/bookshelf_chip_editor.lua"):read("*a")

-- The preview helpers are closures inside Editor:editTab; pull the block from
-- the debounce constant to the end of applyLivePreview (the 4-space `end`).
local block = src:match("\n(    local PREVIEW_DEBOUNCE_S = .-\n    end)\n%s*%-%- Lazy%-loaded widget constructors")
assert(block, "preview block not found (PREVIEW_DEBOUNCE_S .. applyLivePreview)")
block = block:gsub("%-%-[^\n]*", "")

local function harness()
    local e = { calls = {}, scheduled = {}, overrides = 0, on_change_calls = 0 }
    e.UIManager = {
        unschedule = function(_, fn) e.calls[#e.calls + 1] = "unschedule"; e.last_unscheduled = fn end,
        scheduleIn = function(_, s, fn) e.calls[#e.calls + 1] = "scheduleIn:" .. tostring(s); e.scheduled[#e.scheduled + 1] = fn end,
    }
    e.TabModel = {
        load = function() return { { id = "t1", label = "Old", sort_priority = { { key = "title" } } } } end,
        setOverride = function(_id, _o) e.overrides = e.overrides + 1 end,
    }
    e.ViewMode = { CHIP_KEY = "view_mode" }
    e.opts = { on_change = function() e.on_change_calls = e.on_change_calls + 1 end }
    e.draft = { label = "New" }
    e.tab_id = "t1"
    e.pairs, e.ipairs, e.type = pairs, ipairs, type
    local chunk = block .. "\nreturn { apply = applyLivePreview, cancel = cancelPreview, fire = firePreview }"
    local fn, err = load(chunk, "preview", "t", e)
    assert(fn, err)
    e.api = fn()
    return e
end

t.test("a visual pick sets the override at once but does not rebuild the shelf synchronously", function()
    local e = harness()
    e.api.apply(false)
    eq(e.overrides, 1)
    eq(e.on_change_calls, 0, "the shelf rebuild must not run inside the tap")
    eq(table.concat(e.calls, ","), "unschedule,scheduleIn:0.4")
end)

t.test("three quick picks coalesce into one pending rebuild, same timer each time", function()
    local e = harness()
    e.api.apply(false); e.api.apply(false); e.api.apply(false)
    eq(e.overrides, 3, "each pick previews immediately")
    eq(#e.scheduled, 3)
    assert(e.scheduled[1] == e.scheduled[2] and e.scheduled[2] == e.scheduled[3], "one function object, so unschedule finds it")
    eq(e.last_unscheduled, e.scheduled[3], "the pending one is dropped before re-arming")
    e.scheduled[3]()
    eq(e.on_change_calls, 1, "one rebuild for three picks")
end)

t.test("a data change is still held for Save: no override, no timer", function()
    local e = harness()
    e.api.apply(true)
    eq(e.overrides, 0); eq(#e.calls, 0); eq(e.on_change_calls, 0)
    eq(e.data_dirty, true)
end)

t.test("cancelPreview drops the pending rebuild", function()
    local e = harness()
    e.api.apply(false)
    e.api.cancel()
    eq(e.calls[#e.calls], "unschedule")
    eq(e.last_unscheduled, e.api.fire)
end)

t.test("Save, Cancel and the X close all drop a pending preview before clearing the override", function()
    local n = select(2, src:gsub("cancelPreview%(%)\n%s*TabModel%.clearOverride%(%)", ""))
    assert(n >= 3, "expected cancelPreview() directly before each of the three clearOverride() calls, found " .. n)
end)

t.done()
