-- lib/bookshelf_gesture_zones.lua
--
-- Shared FM-zone-walk + event-forwarding helpers for widgets that sit on top
-- of FileManager in the window stack (BookshelfWidget, and the book-detail
-- popup ReviewsModal). KOReader's UIManager:sendEvent only ever delivers an
-- event to the TOPMOST widget in the window stack (frontend/ui/uimanager.lua
-- sendEvent: an event the top widget doesn't consume is simply dropped, it
-- does not cascade to widgets underneath) -- so anything sitting on top of FM
-- has to explicitly forward what it doesn't want to keep, or FM-level
-- gestures (brightness edge-swipes, the KOReader menu, corner taps) and
-- Dispatcher-emitted actions (IncreaseFlIntensity, ToggleNightMode) stop
-- working while that widget is shown.
--
-- Extracted from BookshelfWidget:handleEvent (originally the only caller);
-- see issues #79 (menu-open zones registered on FM modules other than
-- fm.menu) and #84 (don't steal the screensaver wake gesture) for the bug
-- history behind the zone-walk's exact shape.

local GestureZones = {}

-- Shared zone walk: the host's own _ordered_touch_zones plus every child
-- module's (issue #79: menu-open zones can be registered on modules other
-- than host.menu). `allowed(id)` is the per-host id filter; exclude_child
-- skips one specific child (FM's file_chooser - its row-tap/row-hold zones
-- cover the body area, so a tap in a gap of the caller's own layout could
-- otherwise open an unintended file).
local function _tryHostZones(ev, host, allowed, exclude_child)
    if not host then return false end
    local zone_lists = { host._ordered_touch_zones }
    for _i, child in ipairs(host) do
        if child ~= exclude_child
           and type(child) == "table"
           and child._ordered_touch_zones then
            zone_lists[#zone_lists + 1] = child._ordered_touch_zones
        end
    end
    for _i, zones in ipairs(zone_lists) do
        for _j, tzone in ipairs(zones) do
            local id = tzone.def and tzone.def.id
            if id and allowed(id)
               and tzone.gs_range:match(ev)
               and tzone.handler(ev) then
                return true
            end
        end
    end
    return false
end

-- tryFMZones(ev, fm) -> boolean
--   ev  raw gesture event (ev.pos, ev.ges, etc. -- event.args[1] of an
--       onGesture Event)
--   fm  FileManager.instance, or nil
-- Allowlist: stock "filemanager_*" zones or a user-configured
-- Gestures-plugin gesture (fm.gestures.gestures[id]).
function GestureZones.tryFMZones(ev, fm)
    if not fm then return false end
    local user_gestures = (fm.gestures and fm.gestures.gestures) or {}
    return _tryHostZones(ev, fm, function(id)
        return id:find("^filemanager_") or user_gestures[id]
    end, fm.file_chooser)
end

-- tryReaderZones(ev, rui) -> boolean
-- Hot parking: while the shelf sits above a live ReaderUI (no FileManager
-- exists - KOReader kills FM when a book opens), the reader hosts the
-- system menu and the user's Gestures-plugin zones. Allowlist: the stock
-- readermenu_* zones (top-strip tap/swipe/pan, readermenu.lua) plus
-- user-configured gestures. Everything else - tap_forward/tap_backward
-- page turns, readerhighlight_*, readerfooter_* - is excluded by
-- construction: a stray forward would turn pages invisibly under the
-- shelf.
function GestureZones.tryReaderZones(ev, rui)
    if not rui then return false end
    local user_gestures = (rui.gestures and rui.gestures.gestures) or {}
    return _tryHostZones(ev, rui, function(id)
        return id:find("^readermenu_") or user_gestures[id]
    end, nil)
end

-- forwardToFM(event, self_widget) -> boolean
-- Forward a non-gesture event (Dispatcher actions like IncreaseFlIntensity,
-- ToggleNightMode bound to a gesture) to FM's registered modules, since
-- UIManager:sendEvent only delivers to the topmost widget (self_widget).
-- Returns whether FM consumed it (fm:handleEvent's own return value) --
-- callers should return this value onward rather than hardcoding false:
-- UIManager:sendEvent only skips its own active_widgets/window-stack fallback
-- walk when the top widget's handleEvent returns truthy, so swallowing a
-- true here would make sendEvent re-walk the stack for an event FM already
-- handled -- the same double-handling risk the broadcast-tag exclusion
-- below exists to avoid on the other delivery path.
-- Two exclusions:
--   1. Lifecycle events targeting self_widget itself -- forwarding
--      onCloseWidget/onFlushSettings/onShow/onClose to FM can tear FM down
--      (e.g. nil'ing FileManager.instance) or otherwise misfire.
--   2. Events tagged _bookshelf_from_broadcast (main.lua's
--      _installBroadcastTag): UIManager:broadcastEvent already delivers to
--      FM via its own window-stack iteration, so forwarding here would be a
--      redundant second delivery -- harmless for idempotent lifecycle
--      broadcasts (Suspend, Resume) but corrupting for toggle broadcasts
--      (ToggleNightMode would flip state twice, net zero -- issue #19).
--
-- FM-teardown guard: a forwarded event must never be able to quit KOReader.
-- Some events, delivered to FM, drive it to FileManager:onClose -- e.g. a
-- swipe that reaches an open FM menu fires onCloseAllMenus, whose
-- close_callback is FileManager:onClose, which empties the window stack and
-- exits the app (issue #225). We MUST still forward gesture-translated events
-- (onSwipe etc.), because that is how FM's own gesture handlers get the
-- brightness/warmth edge swipes and other actions while bookshelf is on top
-- (issue #231 -- an over-broad "drop all gesture events" guard here silently
-- killed those). So instead of dropping the event, we neutralise
-- FileManager:onClose for the duration of the synchronous dispatch and
-- restore it after: FM still handles the gesture, it just can't tear itself
-- (and KOReader) down as a side effect.
local NEVER_FORWARD = {
    onCloseWidget   = true,
    onFlushSettings = true,
    onShow          = true,
    onClose         = true,
}
-- Explicit teardown actions: the "Exit KOReader" / "Restart" Dispatcher
-- gestures arrive as onExit / onRestart, and both run FileManager:onClose to
-- quit. These MUST reach FM with onClose intact -- neutralising it below (to
-- block INCIDENTAL teardown, e.g. a swipe that closes an FM menu, #225) also
-- swallowed the intentional Exit while bookshelf was the top widget, so the
-- gesture did nothing (issue #243). The neutralise guard stays for everything
-- else (onSwipe etc.), which is where the accidental teardown comes from.
local ALLOW_TEARDOWN = {
    onExit    = true,
    onRestart = true,
}
-- A gesture-translated event carries the raw gesture (a table with a `.ges`
-- field) among its args -- onSwipe/onTapClose/onMultiSwipe were exactly #225's
-- accidental-teardown trigger (a swipe re-reaching FM's open menu). The
-- "Exit KOReader"/"Restart" Dispatcher actions are plain events with no such
-- arg, so this never fires for them; it's belt-and-braces so the teardown
-- bypass below can NEVER apply to a gesture-carrying event (i.e. can't reopen
-- #225 even if some future path mislabelled one as onExit).
local function carriesGesture(event)
    local args = event.args
    if type(args) ~= "table" then return false end
    for i = 1, 3 do
        local a = args[i]
        if type(a) == "table" and a.ges then return true end
    end
    return false
end
local function _forwardToHost(host, event, self_widget)
    if NEVER_FORWARD[event.handler] then return false end
    if event._bookshelf_from_broadcast then return false end
    if not (host and host ~= self_widget) then return false end
    if ALLOW_TEARDOWN[event.handler] and not carriesGesture(event) then
        -- Intentional exit/restart (a plain Dispatcher action, never a
        -- gesture-translated event -- so not #225's swipe-into-menu teardown):
        -- forward as-is so the host's onClose actually runs.
        local ok, consumed = pcall(host.handleEvent, host, event)
        return (ok and consumed) and true or false
    end
    -- Neutralise host teardown for this synchronous forward (see above, #225).
    -- rawget/restore so a pre-existing instance override is preserved and a
    -- nil restores the normal class method; pcall so an error still restores.
    local saved_onClose = rawget(host, "onClose")
    host.onClose = function() return true end
    local ok, consumed = pcall(host.handleEvent, host, event)
    host.onClose = saved_onClose
    return (ok and consumed) and true or false
end

function GestureZones.forwardToFM(event, self_widget)
    local fm = require("apps/filemanager/filemanager").instance
    return _forwardToHost(fm, event, self_widget)
end

-- forwardToReader(event, self_widget, rui) -> boolean
-- Hot parking: non-gesture Dispatcher actions (brightness, night mode, and
-- Bookshelf's own ToggleBookshelf) must reach the reader host while a
-- reader is parked beneath the shelf - UIManager:sendEvent only delivers
-- to the topmost widget. Same guards as the FM path: lifecycle events
-- never forwarded, broadcast-tagged events skipped (already delivered),
-- host onClose neutralised against incidental teardown (the #225
-- analogue - here it would close the parked BOOK), except for the
-- intentional onExit/onRestart teardown actions (#243 analogue).
function GestureZones.forwardToReader(event, self_widget, rui)
    return _forwardToHost(rui, event, self_widget)
end

return GestureZones
