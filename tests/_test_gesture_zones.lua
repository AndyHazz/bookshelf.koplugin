-- tests/_test_gesture_zones.lua
-- Pure-Lua tests for lib/bookshelf_gesture_zones (the shared FM-zone-walk +
-- event-forward helpers used by BookshelfWidget and the book-detail popup to
-- keep FileManager-level gestures working while they're the topmost widget).
-- See docs/superpowers/specs/2026-07-02-book-detail-gesture-passthrough-design.md.

package.path = "./?.lua;./?/init.lua;" .. package.path

local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()
local eq = helpers.eq

-- Minimal fake GestureRange: `range` is a plain {x,y,w,h} table (matching how
-- KOReader's own registerTouchZones builds real ranges -- see
-- frontend/ui/widget/container/inputcontainer.lua's registerTouchZones,
-- which sets range = Geom:new{...} directly, not a function). `matches` is
-- the set of ev tables this fake range should report a match for.
local function fakeRange(rect, matches)
    return {
        range = rect,
        match = function(_self, ev)
            for _, m in ipairs(matches or {}) do
                if m == ev then return true end
            end
            return false
        end,
    }
end

-- Minimal fake touch zone: {def={id=...}, gs_range=fakeRange(...), handler=fn}
local function fakeZone(id, rect, matches, handler)
    return {
        def = { id = id },
        gs_range = fakeRange(rect, matches),
        handler = handler or function() return true end,
    }
end

local Zones = dofile("lib/bookshelf_gesture_zones.lua")

print("--- tryFMZones ---")

t.test("no fm returns false", function()
    assert(Zones.tryFMZones({}, nil) == false)
end)

t.test("matches a filemanager_* zone and fires its handler", function()
    local ev = { pos = { x = 5, y = 5 } }
    local fired = false
    local fm = {
        _ordered_touch_zones = {
            fakeZone("filemanager_tap", { x = 0, y = 0, w = 10, h = 10 }, { ev },
                function() fired = true; return true end),
        },
    }
    assert(Zones.tryFMZones(ev, fm) == true)
    assert(fired, "expected the matching zone's handler to fire")
end)

t.test("a zone with a non-filemanager, non-configured id is skipped", function()
    local ev = { pos = { x = 5, y = 5 } }
    local fired = false
    local fm = {
        _ordered_touch_zones = {
            fakeZone("some_other_plugin_zone", { x = 0, y = 0, w = 10, h = 10 }, { ev },
                function() fired = true; return true end),
        },
    }
    assert(Zones.tryFMZones(ev, fm) == false)
    assert(not fired, "third-party zone must not fire")
end)

t.test("a user-configured Gestures-plugin id fires even without the filemanager_ prefix", function()
    local ev = { pos = { x = 5, y = 5 } }
    local fired = false
    local fm = {
        gestures = { gestures = { my_brightness_swipe = true } },
        _ordered_touch_zones = {
            fakeZone("my_brightness_swipe", { x = 0, y = 0, w = 10, h = 10 }, { ev },
                function() fired = true; return true end),
        },
    }
    assert(Zones.tryFMZones(ev, fm) == true)
    assert(fired)
end)

t.test("fm.file_chooser's zones are excluded even if they would otherwise match", function()
    local ev = { pos = { x = 5, y = 5 } }
    local fired = false
    local file_chooser = {
        _ordered_touch_zones = {
            fakeZone("filemanager_tap", { x = 0, y = 0, w = 10, h = 10 }, { ev },
                function() fired = true; return true end),
        },
    }
    local fm = { file_chooser = file_chooser, _ordered_touch_zones = {} }
    fm[1] = file_chooser  -- ipairs(fm) walk, same shape FileManager:registerModule uses
    assert(Zones.tryFMZones(ev, fm) == false)
    assert(not fired, "file_chooser zones must never fire from this walk")
end)

t.test("zones registered on OTHER FM child modules (not just fm itself) are walked", function()
    local ev = { pos = { x = 5, y = 5 } }
    local fired = false
    local other_module = {
        _ordered_touch_zones = {
            fakeZone("filemanager_ext_tap", { x = 0, y = 0, w = 10, h = 10 }, { ev },
                function() fired = true; return true end),
        },
    }
    local fm = { _ordered_touch_zones = {} }
    fm[1] = other_module
    assert(Zones.tryFMZones(ev, fm) == true)
    assert(fired)
end)

t.test("a handler returning false does not count as consumed", function()
    local ev = { pos = { x = 5, y = 5 } }
    local fm = {
        _ordered_touch_zones = {
            fakeZone("filemanager_tap", { x = 0, y = 0, w = 10, h = 10 }, { ev },
                function() return false end),
        },
    }
    assert(Zones.tryFMZones(ev, fm) == false)
end)

print("--- forwardToFM ---")

t.test("NEVER_FORWARD events are not forwarded, and return false", function()
    local forwarded = false
    package.loaded["apps/filemanager/filemanager"] = {
        instance = { handleEvent = function() forwarded = true; return true end },
    }
    local consumed = Zones.forwardToFM({ handler = "onCloseWidget" }, {})
    assert(not forwarded, "onCloseWidget must never be forwarded to FM")
    assert(consumed == false)
end)

t.test("broadcast-tagged events are not forwarded, and return false", function()
    local forwarded = false
    package.loaded["apps/filemanager/filemanager"] = {
        instance = { handleEvent = function() forwarded = true; return true end },
    }
    local consumed = Zones.forwardToFM({ handler = "onToggleNightMode", _bookshelf_from_broadcast = true }, {})
    assert(not forwarded)
    assert(consumed == false)
end)

t.test("a normal event is forwarded to fm:handleEvent, and its result is returned", function()
    local forwarded_event
    local fm = { handleEvent = function(_self, ev) forwarded_event = ev; return true end }
    package.loaded["apps/filemanager/filemanager"] = { instance = fm }
    local ev = { handler = "onIncreaseFlIntensity" }
    local consumed = Zones.forwardToFM(ev, {})
    assert(forwarded_event == ev)
    assert(consumed == true,
        "forwardToFM must return fm:handleEvent's result -- UIManager:sendEvent " ..
        "only skips its active_widgets fallback walk on a truthy return, so " ..
        "swallowing this would risk double-handling an event FM already consumed")
end)

t.test("fm:handleEvent returning false is passed through as false", function()
    local fm = { handleEvent = function() return false end }
    package.loaded["apps/filemanager/filemanager"] = { instance = fm }
    local consumed = Zones.forwardToFM({ handler = "onIncreaseFlIntensity" }, {})
    assert(consumed == false)
end)

t.test("does not forward to itself, and returns false", function()
    local forwarded = false
    local fm = { handleEvent = function() forwarded = true; return true end }
    package.loaded["apps/filemanager/filemanager"] = { instance = fm }
    local consumed = Zones.forwardToFM({ handler = "onIncreaseFlIntensity" }, fm)
    assert(not forwarded, "must not forward an event back to fm itself")
    assert(consumed == false)
end)

t.test("no fm instance does not crash, and returns false", function()
    package.loaded["apps/filemanager/filemanager"] = { instance = nil }
    local consumed = Zones.forwardToFM({ handler = "onIncreaseFlIntensity" }, {})
    assert(consumed == false)
end)

-- Gesture-translated events (onSwipe etc.) ARE forwarded to FM -- that's how
-- FM's own gesture handlers get the brightness/warmth edge swipes while
-- bookshelf is on top (#231). An earlier "drop all gesture events" guard
-- killed those.
t.test("a gesture-carrying event is still forwarded to FM (#231)", function()
    local forwarded = false
    package.loaded["apps/filemanager/filemanager"] = {
        instance = { handleEvent = function() forwarded = true; return true end },
    }
    -- Mirrors Event:new("Swipe", gsseq.args, ev): args[1] nil, args[2] the ges.
    local ev = { handler = "onSwipe", args = { nil, { ges = "swipe", pos = {} } } }
    local consumed = Zones.forwardToFM(ev, {})
    assert(forwarded, "a gesture event must reach FileManager (brightness edge swipes)")
    assert(consumed == true)
end)

-- Regression for #225: a forwarded event that drives FM to onClose (a swipe
-- reaching an open FM menu -> onCloseAllMenus -> close_callback = onClose ->
-- quit KOReader) must NOT be able to tear FM down. forwardToFM neutralises
-- FileManager:onClose for the synchronous dispatch, then restores it.
t.test("a forwarded event cannot tear FileManager down (#225)", function()
    local real_closed, restored_ok = false, false
    local fm
    fm = {
        onClose = function() real_closed = true end,  -- the "real" teardown
        handleEvent = function(self)
            -- Simulate the menu-close chain calling the (now neutralised) onClose.
            self.onClose()
            return true
        end,
    }
    package.loaded["apps/filemanager/filemanager"] = { instance = fm }
    local ev = { handler = "onSwipe", args = { nil, { ges = "swipe", pos = {} } } }
    Zones.forwardToFM(ev, {})
    assert(not real_closed, "FM:onClose must be neutralised during the forward")
    -- And restored afterwards (a later real close still works).
    fm.onClose()
    assert(real_closed, "FM:onClose must be restored after the forward")
end)

-- Regression for #243: the explicit "Exit KOReader" / "Restart" Dispatcher
-- actions arrive as onExit / onRestart and run FileManager:onClose to quit
-- (DeviceListener:onExit -> FileManagerMenu:exitOrRestart -> self.ui:onClose).
-- The #225 guard must NOT neutralise onClose for these, or the intentional
-- Exit is silently swallowed while bookshelf is the top widget.
for _, handler in ipairs({ "onExit", "onRestart" }) do
    t.test("an explicit " .. handler .. " reaches FM with onClose intact (#243)", function()
        local closed = false
        local fm
        fm = {
            onClose = function() closed = true end,
            handleEvent = function(self) self.onClose(); return true end,
        }
        package.loaded["apps/filemanager/filemanager"] = { instance = fm }
        Zones.forwardToFM({ handler = handler }, {})
        assert(closed, handler .. " must reach FM's real onClose (Exit/Restart must work)")
    end)
end

-- Defense-in-depth: the #243 teardown bypass must NEVER apply to a
-- gesture-carrying event (#225's trigger). Even an onExit that somehow rode in
-- with a raw gesture arg stays guarded -- onClose is neutralised like any other
-- gesture forward, so it can't reopen #225.
t.test("a gesture-carrying onExit stays guarded, no teardown (#225/#243)", function()
    local real_closed = false
    local fm
    fm = {
        onClose = function() real_closed = true end,
        handleEvent = function(self) self.onClose(); return true end,
    }
    package.loaded["apps/filemanager/filemanager"] = { instance = fm }
    local ev = { handler = "onExit", args = { nil, { ges = "swipe", pos = {} } } }
    Zones.forwardToFM(ev, {})
    assert(not real_closed, "a gesture-carrying onExit must stay guarded (no teardown)")
end)

print("--- tryReaderZones ---")

t.test("nil rui returns false", function()
    assert(Zones.tryReaderZones({}, nil) == false)
end)

t.test("matches a readermenu_* zone and fires its handler", function()
    local ev = { pos = { x = 5, y = 5 } }
    local fired = false
    local rui = {
        _ordered_touch_zones = {
            fakeZone("readermenu_tap", { x = 0, y = 0, w = 10, h = 10 }, { ev },
                function() fired = true; return true end),
        },
    }
    assert(Zones.tryReaderZones(ev, rui) == true)
    assert(fired, "expected the readermenu zone's handler to fire")
end)

t.test("page-turn zones never fire through the reader forward", function()
    local ev = { pos = { x = 5, y = 5 } }
    local fired = false
    local rui = {
        _ordered_touch_zones = {
            fakeZone("tap_forward", { x = 0, y = 0, w = 10, h = 10 }, { ev },
                function() fired = true; return true end),
            fakeZone("readerhighlight_tap", { x = 0, y = 0, w = 10, h = 10 }, { ev },
                function() fired = true; return true end),
            fakeZone("readerfooter_tap", { x = 0, y = 0, w = 10, h = 10 }, { ev },
                function() fired = true; return true end),
        },
    }
    assert(Zones.tryReaderZones(ev, rui) == false)
    assert(not fired, "reader page-turn/highlight/footer zones must not fire")
end)

t.test("a user-configured Gestures-plugin id fires on the reader host", function()
    local ev = { pos = { x = 5, y = 5 } }
    local fired = false
    local rui = {
        gestures = { gestures = { my_corner_tap = true } },
        _ordered_touch_zones = {
            fakeZone("my_corner_tap", { x = 0, y = 0, w = 10, h = 10 }, { ev },
                function() fired = true; return true end),
        },
    }
    assert(Zones.tryReaderZones(ev, rui) == true)
    assert(fired)
end)

t.test("reader child modules' zones are walked too", function()
    local ev = { pos = { x = 5, y = 5 } }
    local fired = false
    local rui = {
        _ordered_touch_zones = {},
        [1] = {
            _ordered_touch_zones = {
                fakeZone("readermenu_swipe", { x = 0, y = 0, w = 10, h = 10 }, { ev },
                    function() fired = true; return true end),
            },
        },
    }
    assert(Zones.tryReaderZones(ev, rui) == true)
    assert(fired)
end)

print("--- forwardToReader ---")

t.test("forwards a plain event to the reader host", function()
    local handled = nil
    local rui = { handleEvent = function(_self, e) handled = e.handler; return true end }
    local event = { handler = "onIncreaseFlIntensity", args = {} }
    assert(Zones.forwardToReader(event, {}, rui) == true)
    assert(handled == "onIncreaseFlIntensity")
end)

t.test("never forwards lifecycle events to the reader", function()
    local called = false
    local rui = { handleEvent = function() called = true; return true end }
    assert(Zones.forwardToReader({ handler = "onClose", args = {} }, {}, rui) == false)
    assert(not called)
end)

t.test("neutralises reader onClose during a gesture-carrying forward", function()
    local rui
    rui = {
        onClose = function() error("real onClose must not run") end,
        handleEvent = function(_self, _e)
            rui.onClose() -- incidental teardown attempt during dispatch
            return true
        end,
    }
    local event = { handler = "onSwipe", args = { { ges = "swipe" } } }
    assert(Zones.forwardToReader(event, {}, rui) == true)
    assert(type(rui.onClose) == "function")
    local ok = pcall(rui.onClose)
    assert(ok == false, "original onClose must be restored after dispatch")
end)

t.test("onExit reaches the reader with onClose intact", function()
    local saw_real_onclose = false
    local rui
    rui = {
        onClose = function() saw_real_onclose = true; return true end,
        handleEvent = function(_self, _e) rui.onClose(); return true end,
    }
    assert(Zones.forwardToReader({ handler = "onExit", args = {} }, {}, rui) == true)
    assert(saw_real_onclose, "intentional exit must run the real onClose")
end)

t.done()
