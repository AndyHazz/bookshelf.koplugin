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

local ViewMode = {}

ViewMode.COVERS = "covers"
ViewMode.LIST   = "list"

local function valid(mode)
    return mode == ViewMode.COVERS or mode == ViewMode.LIST
end

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
