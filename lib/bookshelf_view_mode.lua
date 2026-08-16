-- bookshelf_view_mode.lua
-- Which presentation the shelf grid uses: covers or list.
--
-- Deliberately a pure function of three inputs rather than state on the
-- widget, so the whole decision is testable headless and there is exactly one
-- place that answers "which mode am I in".
--
-- The model is one persisted setting plus one session override:
--   * list_when_expanded  persisted bool. Off by default, so a user who never
--                         asks for list view sees today's behaviour exactly.
--   * override            session only, set by long-pressing the pagination
--                         page label. Survives expand/collapse and chip
--                         changes; dies with the process.
--
-- The override beats the setting in BOTH directions on purpose: a user who
-- has list-on-expand turned on must still be able to get covers back while
-- expanded, or the gesture is only half a toggle.
--
-- ...with ONE escape hatch, added after the maintainer reported that the
-- setting "doesn't seem to work yet". Reproduced offscreen: flip to list with
-- the gesture and flip back, and the override is "covers" for the rest of the
-- session, so ticking the checkbox afterwards changes nothing at all and there
-- is no UI anywhere that says why. Changing the PERSISTENT preference is the
-- stronger statement of intent than a gesture the user may not remember
-- making, so it retires the override -- see clearOverride, called from the
-- checkbox in lib/bookshelf_settings.lua.

local ViewMode = {}

ViewMode.COVERS = "covers"
ViewMode.LIST   = "list"

local function valid(mode)
    return mode == ViewMode.COVERS or mode == ViewMode.LIST
end

-- ── The session override ───────────────────────────────────────────────────
--
-- Module state rather than a field on the shelf widget, which is where it
-- lived first. Two reasons, both of them bugs the widget version had:
--
--   * The help text promises the flip "lasts until you hold it again or
--     restart KOReader". A widget field lasts until the widget is destroyed,
--     which is every "Close Bookshelf" -- main.lua's show() then takes its
--     cold-create branch and builds a fresh one (main.lua:775). Same process,
--     override silently gone.
--   * Nothing outside the widget could clear it. The settings checkbox reaches
--     the live shelf through Settings._bw, which is not always populated (it
--     is set from main.lua's menu entry points, and is Library-only), so a fix
--     that poked bw._list_override would work from some menus and not others.
--
-- One process, one shelf, one answer. Dies with the process, as documented.
local _override = nil

function ViewMode.override() return _override end

-- setOverride(mode) -- a valid mode arms the override; anything else (nil
-- included) retires it, so callers can clear by passing what they read.
function ViewMode.setOverride(mode)
    _override = valid(mode) and mode or nil
end

function ViewMode.clearOverride() _override = nil end

-- effective(expanded, override, list_when_expanded) -> ViewMode.COVERS|LIST
-- An override that isn't one of the two constants is ignored rather than
-- returned: a stale or corrupted value must not reach the renderer as a mode
-- it cannot dispatch on.
function ViewMode.effective(expanded, override, list_when_expanded)
    if valid(override) then return override end
    if expanded and list_when_expanded then return ViewMode.LIST end
    return ViewMode.COVERS
end

-- flip(mode) -> the other mode. Anything unrecognised flips to LIST, so a
-- hold from an indeterminate state still does something visible.
function ViewMode.flip(mode)
    if mode == ViewMode.LIST then return ViewMode.COVERS end
    return ViewMode.LIST
end

function ViewMode.isList(mode) return mode == ViewMode.LIST end

return ViewMode
