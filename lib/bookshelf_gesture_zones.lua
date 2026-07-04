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

-- tryFMZones(ev, fm) -> boolean
--   ev  raw gesture event (ev.pos, ev.ges, etc. -- event.args[1] of an
--       onGesture Event)
--   fm  FileManager.instance, or nil
-- Walks every registered FM module's touch zones (not just fm + fm.menu --
-- KOReader v2026.03 on Kobo / SimpleUI navbar setups registers the menu-open
-- zones on other FM modules, issue #79), filtered to zones whose id is either
-- a stock "filemanager_*" zone or a user-configured Gestures-plugin gesture
-- (fm.gestures.gestures[id]). fm.file_chooser is explicitly excluded: it's
-- the Menu widget for the file list painted underneath bookshelf, and its
-- row-tap/row-hold zones cover the body area, so a tap in a gap of the
-- caller's own layout could otherwise open an unintended file.
function GestureZones.tryFMZones(ev, fm)
    if not fm then return false end
    local user_gestures = (fm.gestures and fm.gestures.gestures) or {}
    local zone_lists = { fm._ordered_touch_zones }
    for _, child in ipairs(fm) do
        if child ~= fm.file_chooser
           and type(child) == "table"
           and child._ordered_touch_zones then
            zone_lists[#zone_lists + 1] = child._ordered_touch_zones
        end
    end
    for _i, zones in ipairs(zone_lists) do
        for _j, tzone in ipairs(zones) do
            local id = tzone.def and tzone.def.id
            local allowed = id and (id:find("^filemanager_")
                                    or user_gestures[id])
            if allowed
               and tzone.gs_range:match(ev)
               and tzone.handler(ev) then
                return true
            end
        end
    end
    return false
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
-- Three exclusions:
--   1. Lifecycle events targeting self_widget itself -- forwarding
--      onCloseWidget/onFlushSettings/onShow/onClose to FM can tear FM down
--      (e.g. nil'ing FileManager.instance) or otherwise misfire.
--   2. Events tagged _bookshelf_from_broadcast (main.lua's
--      _installBroadcastTag): UIManager:broadcastEvent already delivers to
--      FM via its own window-stack iteration, so forwarding here would be a
--      redundant second delivery -- harmless for idempotent lifecycle
--      broadcasts (Suspend, Resume) but corrupting for toggle broadcasts
--      (ToggleNightMode would flip state twice, net zero -- issue #19).
--   3. Gesture-translated events (onSwipe / onTapClose / onMultiSwipe / ...).
--      InputContainer:onGesture re-dispatches a matched gesture as
--      Event:new(name, ges_args, ev), so the raw gesture rides along as an
--      arg (a table with a `.ges` field). These must NOT be forwarded: the
--      caller's own gesture handlers already offer FM its passthrough via
--      tryFMZones, and re-delivering the gesture lets FM act on it a SECOND
--      time -- e.g. a swipe reaching FM's open menu fires onCloseAllMenus,
--      whose close_callback is FileManager:onClose, tearing down the whole
--      home surface and exiting KOReader (issue #225). forwardToFM is only
--      for non-gesture Dispatcher action events.
local NEVER_FORWARD = {
    onCloseWidget   = true,
    onFlushSettings = true,
    onShow          = true,
    onClose         = true,
}
-- A gesture-translated event carries the raw gesture table (with a `.ges`
-- field) as one of its args. Checked by index (not ipairs): the first arg is
-- often nil (the ges_event's own `.args`), and the gesture is the next one.
local function carriesGesture(event)
    local args = event.args
    if type(args) ~= "table" then return false end
    for i = 1, 3 do
        local a = args[i]
        if type(a) == "table" and a.ges then return true end
    end
    return false
end
function GestureZones.forwardToFM(event, self_widget)
    if NEVER_FORWARD[event.handler] then return false end
    if event._bookshelf_from_broadcast then return false end
    if carriesGesture(event) then return false end
    local fm = require("apps/filemanager/filemanager").instance
    if fm and fm ~= self_widget then
        return fm:handleEvent(event) and true or false
    end
    return false
end

return GestureZones
