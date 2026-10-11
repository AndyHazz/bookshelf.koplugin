-- bookshelf_view_mode.lua
-- Which presentation the shelf grid uses: covers or list.
--
-- Deliberately a pure function of its inputs rather than state anywhere, so
-- the whole decision is testable headless and there is exactly one place that
-- answers "which mode am I in".
--
-- ── THE MODEL: a chip pin, defaulting to COVERS ────────────────────────────
--
-- A chip is pinned to LIST, pinned to COVERS, or set to AUTO -- and UNSET,
-- the default, means COVERS. The maintainer reversed the original default
-- ("shelf style should not have been 'auto' by default, it should have
-- 'cover' ... to keep our existing behaviour without users opting into the
-- new auto mode"): a library that has never touched the setting looks
-- exactly as it did before list view existed. Auto is an explicit stored
-- choice now, and its policy is still fixed:
--
--     expanded, or drilled into a folder / series / author / tag  ->  LIST
--     collapsed at a chip's top level                             ->  COVERS
--
-- (That fixed policy is now Auto's DEFAULT per level and is still what search
-- results' own Auto uses; a chip's Auto is chosen per level, see AUTO BY LEVEL.)
--
-- This replaces the three independent booleans (list_when_expanded /
-- _collapsed / _in_folder) on the maintainer's ruling: "I think we can move
-- the 'show as list ...' options from the main menu into the per chip
-- settings ... as part of the show as 'list / covers / auto: list when
-- expanded or lists inside folders'". The policy Auto encodes is that quote,
-- verbatim. The old keys stay on disk, ignored -- list mode never shipped, so
-- nothing is owed to them.
--
-- Why that split earns being the ONE automatic behaviour: collapsed under the
-- hero there are two rows, where covers say more per item than text; expanded
-- and inside folders the reader is scanning MANY items, which is what a table
-- is for.

local ViewMode = {}

ViewMode.COVERS = "covers"
ViewMode.LIST   = "list"
ViewMode.AUTO   = "auto"
-- The third presentation: books edge-on, like a real bookcase. Never chosen
-- by the Auto policy -- it is a deliberate, per-chip aesthetic (the opposite
-- of the utilitarian list), so it exists only as an explicit pin.
ViewMode.SPINES = "spines"

-- effective(expanded, in_folder) -> ViewMode.COVERS | ViewMode.LIST
--
-- The Auto policy, whole: a list wherever the reader is scanning many items
-- (expanded, or drilled into anything), covers on the two rows under the
-- hero. A pinned chip never reaches this -- the caller checks the pin first.
function ViewMode.effective(expanded, in_folder)
    if expanded or in_folder then return ViewMode.LIST end
    return ViewMode.COVERS
end

-- ── AUTO BY LEVEL (5.4.3) ──────────────────────────────────────────────────
--
-- An Auto chip says which style each drill level wears: Level 1 its top level
-- (collapsed OR expanded, maintainer 2026-10-11: levels are drill depth, not
-- screen size), Level 2 everything drilled into below it (folders in folders,
-- series inside an author). Each is covers, list or spines, cycled from two
-- buttons in Shelf style as the sort levels are. Unset is today's Auto: covers
-- on top, a list inside. Expanded at the top level now follows Level 1, so an
-- untouched Auto shelf shows covers expanded where it showed a list.
--
-- A shelf of shelves has only Level 1: opening a sub-shelf switches to it
-- (its own Show as and levels), so nothing in it is ever drilled into.
ViewMode.LEVEL_KEYS     = { "view_level1", "view_level2" }
ViewMode.LEVEL_DEFAULTS = { ViewMode.COVERS, ViewMode.LIST }
ViewMode.LEVEL_CYCLE    = { ViewMode.COVERS, ViewMode.LIST, ViewMode.SPINES }

-- levelMode(value, level) -> the style stored for that level, or its default
-- for absence or anything this build does not know.
function ViewMode.levelMode(value, level)
    if value == ViewMode.COVERS or value == ViewMode.LIST or value == ViewMode.SPINES then
        return value
    end
    return ViewMode.LEVEL_DEFAULTS[level] or ViewMode.COVERS
end

-- auto(tab, drilled) -> the style an Auto chip shows: Level 2's when drilled
-- into anything, else Level 1's.
function ViewMode.auto(tab, drilled)
    tab = tab or {}
    if drilled then return ViewMode.levelMode(tab[ViewMode.LEVEL_KEYS[2]], 2) end
    return ViewMode.levelMode(tab[ViewMode.LEVEL_KEYS[1]], 1)
end

-- nextLevelMode(value, level, no_spines) -> the next style in the cycle from
-- the one that level shows now; spines left out for a catalogue.
function ViewMode.nextLevelMode(value, level, no_spines)
    local cur = ViewMode.levelMode(value, level)
    local cycle = ViewMode.LEVEL_CYCLE
    for i, m in ipairs(cycle) do
        if m == cur then
            local nxt = cycle[i % #cycle + 1]
            if no_spines and nxt == ViewMode.SPINES then nxt = cycle[(i + 1) % #cycle + 1] end
            return nxt
        end
    end
    return ViewMode.LEVEL_DEFAULTS[level]
end

function ViewMode.isList(mode) return mode == ViewMode.LIST end
function ViewMode.isSpines(mode) return mode == ViewMode.SPINES end

-- ── THE PER-CHIP OVERRIDE ──────────────────────────────────────────────────
--
-- A chip may pin itself to either mode, outranking the Auto policy.
-- Stored as tab.view_mode, persisted with the rest of the chip by
-- TabModel.save, and edited in the same picker as the chip's folder tile style
-- -- as its own SECTION of that picker, not as extra values in it.
--
-- The two were briefly one field, with "list" living among the tile styles.
-- The maintainer split them, and the reason is that they are genuinely
-- independent: a chip needs to be able to say "divider cards" without also
-- asserting a view mode, and "always a list" without throwing away the tile
-- style it would use if it ever showed tiles again. Merged, every tile style
-- silently meant "and never a list here", which also quietly reinterpreted
-- every chip in every existing library -- group_display has shipped for
-- several releases.
--
-- UNSET is the fourth state and the default: COVERS. Absence rather than a
-- sentinel, so a chip written by a later release that grows new mode values
-- degrades to the covers default here rather than to an error. AUTO is a
-- stored value like the other two -- it stopped being the absence when the
-- default flipped to covers.
-- No labels here, and no gettext require: this file is a pure function of its
-- arguments so the whole decision is testable headless, and pulling in i18n for
-- three strings would end that. The chip editor owns the wording.
ViewMode.CHIP_KEY = "view_mode"

-- chipOverride(value) -> COVERS | LIST | AUTO | nil
--
-- nil for anything this build does not recognise -- including the absence
-- that means the covers default -- so a hand-edited chip, or one written by
-- a later release, falls back to the default rather than reaching a renderer
-- as a mode it has no branch for.
function ViewMode.chipOverride(value)
    if value == ViewMode.LIST or value == ViewMode.COVERS
            or value == ViewMode.AUTO or value == ViewMode.SPINES then
        return value
    end
    return nil
end

-- chipPin(value) -> COVERS | LIST | AUTO | SPINES
--
-- chipOverride answers "is there a recognised value stored?" and returns nil
-- for absence. chipPin answers the question the CALLER usually has -- "which
-- mode is this chip in?" -- and absence is not a missing answer to that one:
-- unset IS covers, and has been since the default flipped.
--
-- Both exist because the difference matters in exactly one place: the picker
-- needs chipOverride to know whether to light the Auto radio, and chipPin to
-- know which density controls belong to the mode. It had only the first, so
-- a Covers chip -- stored as nil -- failed a `mode ~= COVERS` test and was
-- offered the list's column and row nudges, controls for a view it is
-- pinned away from.
function ViewMode.chipPin(value)
    return ViewMode.chipOverride(value) or ViewMode.COVERS
end

return ViewMode
