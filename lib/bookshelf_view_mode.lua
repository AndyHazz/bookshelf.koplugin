-- bookshelf_view_mode.lua
-- Which presentation the shelf grid uses: covers or list.
--
-- Deliberately a pure function of its inputs rather than state anywhere, so
-- the whole decision is testable headless and there is exactly one place that
-- answers "which mode am I in".
--
-- ── THE MODEL: three independent persisted booleans ────────────────────────
--
--   list_when_expanded    show a list while the shelf is EXPANDED
--   list_when_collapsed   show a list while the shelf is COLLAPSED
--   list_when_in_folder   show a list while drilled INTO a folder or stack
--
-- All default off, so a user who has asked for none sees exactly today's cover
-- grid everywhere. They are independent on purpose (the maintainer's ruling:
-- "two independent toggles, both can be affected separately by long press on
-- the pagination"): a list is a density trade, and wanting it for the big
-- expanded grid says nothing about wanting it for the two rows under the hero.
--
-- ── HOW THE FOLDER ONE COMBINES, AND WHY IT IS AN OR ───────────────────────
--
-- The first two are mutually exclusive: the shelf is expanded or it is not, so
-- exactly one of them is ever consulted, and effective() is a lookup rather
-- than an arbitration. The folder one is not exclusive with either -- you are
-- inside a folder AND expanded, or inside a folder AND collapsed -- so it has
-- to combine.
--
-- It combines as an OR: it can turn a list ON, never OFF. The requested feature
-- was "option to enable list mode inside folders", i.e. covers on the main
-- shelf and a list once you are in a folder. Making it authoritative instead
-- would mean a user with list_when_expanded on and this one off would drill
-- into a folder and lose the list they had asked for everywhere else -- which
-- nobody asked for, and which reads as the drill breaking a setting.
--
-- Consequence worth knowing, and the reason inFolderKeyIsDecisive() exists:
-- inside a folder with the shelf-wide toggle already on, turning the folder one
-- OFF changes nothing on screen. The gesture has to know that, or it looks
-- broken.
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
-- The gesture now writes the persisted boolean for the context you are in. The
-- settings screen is consequently an exact mirror of what is on screen, in
-- both directions, always -- which is the property the override could not have.

local ViewMode = {}

ViewMode.COVERS = "covers"
ViewMode.LIST   = "list"

-- The three settings keys. Named here rather than spelled out at each call site
-- so the gesture, the checkboxes and the resolver cannot drift apart.
ViewMode.KEY_EXPANDED  = "list_when_expanded"
ViewMode.KEY_COLLAPSED = "list_when_collapsed"
ViewMode.KEY_IN_FOLDER = "list_when_in_folder"

-- keyFor(expanded, in_folder) -> the key the long-press writes.
--
-- Inside a folder that is the folder key, because that is the context the user
-- is looking at and the one they most likely mean. Outside, it is whichever of
-- the two shelf-state keys matches. Everything not named is left alone; that
-- independence is the whole point of having three.
function ViewMode.keyFor(expanded, in_folder)
    if in_folder then return ViewMode.KEY_IN_FOLDER end
    if expanded then return ViewMode.KEY_EXPANDED end
    return ViewMode.KEY_COLLAPSED
end

-- inFolderKeyIsDecisive(expanded, list_when_expanded, list_when_collapsed)
--     -> true when, inside a folder, the folder key is the ONLY thing keeping
--        the list on.
--
-- The gesture uses this to tell a real toggle from one the OR will absorb, so
-- it can say so instead of appearing to do nothing.
function ViewMode.inFolderKeyIsDecisive(expanded, list_when_expanded,
                                        list_when_collapsed)
    if expanded then return not list_when_expanded end
    return not list_when_collapsed
end

-- effective(expanded, list_when_expanded, list_when_collapsed,
--           in_folder, list_when_in_folder)
--     -> ViewMode.COVERS | ViewMode.LIST
--
-- Written as an if rather than `expanded and a or b`: that idiom returns b
-- whenever a is false, which is exactly the case this has to get right.
--
-- The last two arguments are optional; omitting them is the pre-folder-key
-- behaviour exactly, which is what keeps every existing caller and test honest.
function ViewMode.effective(expanded, list_when_expanded, list_when_collapsed,
                            in_folder, list_when_in_folder)
    if in_folder and list_when_in_folder then return ViewMode.LIST end
    local want
    if expanded then want = list_when_expanded else want = list_when_collapsed end
    if want then return ViewMode.LIST end
    return ViewMode.COVERS
end

function ViewMode.isList(mode) return mode == ViewMode.LIST end

return ViewMode
