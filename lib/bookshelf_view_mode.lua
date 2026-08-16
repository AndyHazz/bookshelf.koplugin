-- bookshelf_view_mode.lua
-- Which presentation the shelf grid uses: covers or list.
--
-- Deliberately a pure function of its inputs rather than state anywhere, so
-- the whole decision is testable headless and there is exactly one place that
-- answers "which mode am I in".
--
-- ── THE MODEL: two independent persisted booleans ──────────────────────────
--
--   list_when_expanded    show a list while the shelf is EXPANDED
--   list_when_collapsed   show a list while the shelf is COLLAPSED
--
-- Both default off, so a user who has asked for neither sees exactly today's
-- cover grid in both states. They are independent on purpose (the maintainer's
-- ruling: "two independent toggles, both can be affected separately by long
-- press on the pagination"): a list is a density trade, and wanting it for the
-- big expanded grid says nothing about wanting it for the two rows under the
-- hero.
--
-- effective() is therefore a LOOKUP, not an arbitration -- pick the boolean
-- that matches the state you are in and read it.
--
-- ── WHAT THIS REPLACES: the session override ───────────────────────────────
--
-- Until this revision the long-press on the pagination page label armed a
-- session-only override that beat the setting in both directions. Two things
-- were wrong with it and neither had a fix inside that model:
--
--   * the settings screen could disagree with the screen. Flip to list with
--     the gesture and flip back, and the override was "covers" for the rest of
--     the session -- so ticking the checkbox afterwards did nothing at all,
--     with no UI anywhere to say why. That was reported as "the setting
--     doesn't seem to work yet", and the fix at the time (the checkbox retires
--     the override) only patched the one direction someone happened to hit.
--   * it was a third state to hold in your head, documented only in the help
--     text of a checkbox it silently outranked.
--
-- The gesture now writes the persisted boolean for the state you are in. The
-- settings screen is consequently an exact mirror of what is on screen, in
-- both directions, always -- which is the property the override could not have.

local ViewMode = {}

ViewMode.COVERS = "covers"
ViewMode.LIST   = "list"

-- The two settings keys. Named here rather than spelled out at each call site
-- so the gesture, the checkboxes and the resolver cannot drift apart.
ViewMode.KEY_EXPANDED  = "list_when_expanded"
ViewMode.KEY_COLLAPSED = "list_when_collapsed"

-- keyFor(expanded) -> the key that decides the mode in THIS shelf state, and
-- therefore the one the long-press writes. The other is left alone; that
-- independence is the whole point of having two.
function ViewMode.keyFor(expanded)
    if expanded then return ViewMode.KEY_EXPANDED end
    return ViewMode.KEY_COLLAPSED
end

-- effective(expanded, list_when_expanded, list_when_collapsed)
--     -> ViewMode.COVERS | ViewMode.LIST
--
-- Written as an if rather than `expanded and a or b`: that idiom returns b
-- whenever a is false, which is exactly the case this has to get right.
function ViewMode.effective(expanded, list_when_expanded, list_when_collapsed)
    local want
    if expanded then want = list_when_expanded else want = list_when_collapsed end
    if want then return ViewMode.LIST end
    return ViewMode.COVERS
end

function ViewMode.isList(mode) return mode == ViewMode.LIST end

return ViewMode
