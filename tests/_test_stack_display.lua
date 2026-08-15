-- tests/_test_stack_display.lua
-- Folder/stack display modes: the library default, a chip's override of it,
-- and the one-time migration off the per-kind settings this replaced.
--
-- The default dominates everything else here: unset must mean the shipped
-- divider card. Any regression there changes every tile on every shelf of
-- every library that never opens this menu.
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["logger"] = { dbg=function() end, info=function() end,
                             warn=function() end, err=function() end }

-- Stub the KOReader surface the module touches at load time.
local stored = {}
package.loaded["lib/bookshelf_settings_store"] = {
    read   = function(k) return stored[k] end,
    save   = function(k, v) stored[k] = v end,
    delete = function(k) stored[k] = nil end,
    flush  = function() end,
}
-- The migration writes chip overrides through TabModel.
local saved_tabs
package.loaded["lib/bookshelf_tab_model"] = {
    load = function() return saved_tabs or {} end,
    save = function(t) saved_tabs = t end,
}
-- Colour stubs carry a getColor8 so the pile's border interpolation works:
-- it blends the resolved card border toward the layer body in PAINTED space.
local function color8(v)
    return { a = v, getColor8 = function(self) return self end }
end
package.loaded["ffi/blitbuffer"] = {
    COLOR_BLACK = color8(0x00), COLOR_WHITE = color8(0xFF),
    new = function() return nil end,
    gray = function(f) return color8(255 - math.floor(255 * f)) end,
    Color8 = color8,
}
-- Minimal stand-in for KOReader's Widget base class: extend/new, which is all
-- the pile uses. Deliberately NOT a bare table -- the pile being a bare table
-- with no event surface is exactly the crash this test now guards.
local WidgetStub = {}
function WidgetStub:extend(t)
    t = t or {}
    setmetatable(t, { __index = self })
    t.extend = self.extend
    t.new = self.new
    return t
end
function WidgetStub:new(o)
    o = o or {}
    setmetatable(o, { __index = self })
    if o.init then o:init() end
    return o
end
function WidgetStub:handleEvent() return false end
function WidgetStub:getSize() return self.dimen end
package.loaded["ui/widget/widget"] = WidgetStub
package.loaded["ui/geometry"] = { new = function(_s, t) return t end }
-- The pile borrows the real card's radius, shadow grey and shadow offset
-- rather than inventing its own, so a stub has to stand in for them.
package.loaded["lib/bookshelf_spine_widget"] = {
    CARD_RADIUS   = 8,
    SHADOW_OFFSET = 8,
    shadowGray    = function() return color8(0x80) end,
    -- outer, inner: the placeholder card's bands, mode-aware in the real one.
    fallbackBgs   = function() return color8(0xEB), color8(0xFF) end,
}
package.loaded["lib/bookshelf_cover_progress"] = {
    resolvedColors = function() return { border = color8(0x00) } end,
}
package.loaded["device"] = { screen = {
    scaleBySize = function(_s, n) return n * 2 end,   -- PW5-ish: 1 -> 2px
} }

local SD = require("lib/bookshelf_stack_display")

local pass, fail = 0, 0
local function eq(got, want, label)
    if got == want then pass = pass + 1
    else fail = fail + 1; print("FAIL " .. label .. ": got " .. tostring(got) .. " want " .. tostring(want)) end
end
local function ok(cond, label)
    if cond then pass = pass + 1 else fail = fail + 1; print("FAIL " .. label) end
end

local function reset() stored = {}; saved_tabs = nil end

-- ── the library default ──────────────────────────────────────────────────────
reset()
eq(SD.defaultMode(), SD.DIVIDER, "an untouched library shows the shipped divider card")
reset()
stored[SD.DEFAULT_KEY] = SD.RIBBON
eq(SD.defaultMode(), SD.RIBBON, "a stored default is honoured")
stored[SD.DEFAULT_KEY] = "hologram"
eq(SD.defaultMode(), SD.DIVIDER, "a mode this build does not offer never reaches a renderer")
stored[SD.DEFAULT_KEY] = 3
eq(SD.defaultMode(), SD.DIVIDER, "nor does a non-string one")

-- ── a chip's override of it ──────────────────────────────────────────────────
reset()
stored[SD.DEFAULT_KEY] = SD.RIBBON
eq(SD.resolve(nil), SD.RIBBON, "a chip that has chosen nothing follows the default")
eq(SD.resolve(SD.STACK), SD.STACK, "a chip that has chosen overrides the default")
eq(SD.resolve("hologram"), SD.RIBBON,
   "an override this build does not offer falls back to the default, not to a crash")
-- Divider carries an explicit value precisely so a chip can disagree with a
-- non-divider default. With divider stored as nil these two were the same.
eq(SD.resolve(SD.DIVIDER), SD.DIVIDER,
   "a chip can be an explicit divider card while the library default is not")
local values = {}
for _i, opt in ipairs(SD.OPTIONS) do
    ok(type(opt.value) == "string", "every option carries a real value, not nil-as-default")
    ok(not values[opt.value], "option value " .. tostring(opt.value) .. " appears once")
    values[opt.value] = true
end
for _i, needed in ipairs{ SD.DIVIDER, SD.RIBBON, SD.STACK, SD.COLLAGE, SD.TEXT, SD.NONE } do
    ok(values[needed], "mode '" .. needed .. "' is offered in the menu")
end

-- ── migration off the per-kind settings ──────────────────────────────────────
-- What it has to preserve is the RESULT, not the settings: a shelf that said
-- "series are piles, genres are text" must look identical afterwards.
reset()
stored.folder_display = SD.STACK
stored.series_display = SD.COLLAGE
stored.genre_display  = SD.TEXT
saved_tabs = {
    { id = "library", source = { kind = "all" } },
    { id = "series",  source = { kind = "series" } },
    { id = "genres",  source = { kind = "genres" } },
    { id = "recent",  source = { kind = "recent" } },
    { id = "cat",     source = { kind = "opds", id = "srv" } },
}
eq(SD.defaultMode(), SD.STACK, "the library default inherits the old FOLDER value")
local by_id = {}
for _i, t in ipairs(saved_tabs or {}) do by_id[t.id] = t end
eq(by_id.series.group_display, SD.COLLAGE, "the series chip keeps the series look")
eq(by_id.genres.group_display, SD.TEXT, "the genres chip keeps the genres look")
eq(by_id.library.group_display, SD.STACK, "a home chip shows folder tiles, so it takes folders")
eq(by_id.cat.group_display, SD.STACK, "an OPDS catalog shows folder tiles too")
eq(by_id.recent.group_display, nil, "a chip that shows no group tiles inherits nothing")
eq(stored.folder_display, nil, "the legacy keys are deleted, so this cannot run twice")
eq(stored.series_display, nil, "every legacy key, not just the one that seeded the default")

-- An untouched library still gets stamped, so the probe does not run forever.
reset()
eq(SD.defaultMode(), SD.DIVIDER, "nothing configured means the divider card")
eq(stored[SD.DEFAULT_KEY], SD.DIVIDER, "and the default is written rather than re-derived")

-- A chip that already has its own override is never overwritten by the
-- migration -- the newer choice is the real one.
reset()
stored.series_display = SD.COLLAGE
saved_tabs = { { id = "series", source = { kind = "series" }, group_display = SD.NONE } }
SD.defaultMode()
eq(saved_tabs[1].group_display, SD.NONE, "an existing override survives the migration")

-- ── mode predicates ──────────────────────────────────────────────────────────
reset()
for _i, mode in ipairs{ SD.RIBBON, SD.STACK, SD.COLLAGE, SD.TEXT, SD.NONE } do
    eq(SD.showsCardboard(mode), false, mode .. " does not draw the cardboard")
end
eq(SD.showsCardboard(SD.DIVIDER), true, "divider draws the cardboard")
eq(SD.isTextOnly(SD.TEXT), true, "text mode suppresses artwork")
for _i, mode in ipairs{ SD.DIVIDER, SD.RIBBON, SD.STACK, SD.COLLAGE, SD.NONE } do
    eq(SD.isTextOnly(mode), false, mode .. " still renders artwork")
end

-- ── the ribbon ───────────────────────────────────────────────────────────────
-- The band runs PAST the cover, and the only way to do that without painting
-- over the next tile is for the cover to give up the room.
ok(SD.ribbonInset(SD.RIBBON) > 0, "ribbon shortens the cover to make room for its overhang")
eq(SD.ribbonInset(SD.RIBBON), SD.ribbonOverhang() * 2, "an overhang each side, symmetric")
for _i, mode in ipairs{ SD.DIVIDER, SD.STACK, SD.COLLAGE, SD.TEXT, SD.NONE } do
    eq(SD.ribbonInset(mode), 0, mode .. " gives up no room for a band")
end
ok(SD.ribbonInset(SD.RIBBON) < 30, "and the overhang stays small enough for a tile")
-- The name IS the ribbon, so a nameless group gets no band rather than an
-- empty bar across a third of its artwork.
eq(SD.ribbonWidget(100, 200, nil), nil, "no band without a name")
eq(SD.ribbonWidget(100, 200, ""), nil, "nor for an empty one")
eq(SD.ribbonWidget(0, 200, "Dune"), nil, "nor for a zero-width cover")

-- Only stack reserves room; every other mode gets the full slot, so callers can
-- subtract the inset unconditionally.
ok(SD.pileInset(SD.STACK, 4) > 0, "stack reserves room for the layers behind")
for _i, mode in ipairs{ SD.DIVIDER, SD.COLLAGE, SD.TEXT, SD.NONE } do
    eq(SD.pileInset(mode, 4), 0, mode .. " reserves no pile room")
end
-- The inset has to leave the cover the majority of a narrow tile.
ok(SD.pileInset(SD.STACK, 4) < 60, "the pile inset stays small enough for a tile")

-- ── pile depth follows the stack size ────────────────────────────────────────
-- The pile DEPICTS the stack rather than decorating it, so a two-book series
-- must not claim to be a pile of four.
eq(SD.pileLayers(1), 0, "a single book is not a pile")
eq(SD.pileLayers(2), 1, "two books get one layer behind")
eq(SD.pileLayers(3), 2, "three books get two")
eq(SD.pileLayers(4), 3, "four books get three")
eq(SD.pileLayers(90), 3, "beyond the cap the pile stops growing")
eq(SD.pileLayers(0), 0, "an empty stack draws no layers")
eq(SD.pileLayers(-5), 0, "a nonsense count draws no layers")
-- nil means "the caller never computed it" (folder tiles only count books when
-- the badge needs it), NOT "empty" - so it takes the full pile.
eq(SD.pileLayers(nil), SD.MAX_PILE_BOOKS - 1, "an unknown count assumes a full pile")
eq(SD.pileLayers("lots"), SD.MAX_PILE_BOOKS - 1, "a non-numeric count assumes a full pile")

-- The inset must track the depth, or a shallow pile would reserve room it
-- never paints into and the cover would sit shrunken for no reason.
eq(SD.pileInset(SD.STACK, 1), 0, "a single-book stack reserves nothing")
ok(SD.pileInset(SD.STACK, 2) < SD.pileInset(SD.STACK, 4),
    "a two-book pile reserves less room than a four-book one")

-- And no pile widget at all for a stack of one.
eq(SD.pileWidget(100, 200, 1), nil, "no pile widget for a single book")
ok(SD.pileWidget(100, 200, 2) ~= nil, "a two-book stack gets a pile")
eq(SD.pileWidget(100, 200, 2).layers, 1, "with exactly one layer behind")
eq(SD.pileWidget(100, 200, 9).layers, 3, "and a big stack caps at three")

-- The pile depicts the stack, so VISIBLE EDGES must equal the book count:
-- the front cover is one book, each layer behind is another. Nothing else in
-- the pile may draw a card-like edge - an outline around the outermost shadow
-- did, and made an x4 stack look like five books.
for _i, case in ipairs{ {1,1}, {2,2}, {3,3}, {4,4}, {40,4} } do
    local books, want_edges = case[1], case[2]
    eq(1 + SD.pileLayers(books), want_edges,
        books .. " books should show " .. want_edges .. " edges (cover + layers)")
end

-- ── labels ───────────────────────────────────────────────────────────────────
for _i, opt in ipairs(SD.OPTIONS) do
    local label = SD.labelFor(opt.value)
    ok(type(label) == "string" and label ~= "", "each mode has a label")
end
eq(SD.labelFor("hologram"), SD.OPTIONS[1].label_func(),
    "an unknown value renders as the default option's label")
-- Divider leads the list, and carries a real value. nil now means "not set",
-- which for a chip means "follow the library default" -- so divider has to be
-- sayable, or a chip could never disagree with a non-divider default.
eq(SD.OPTIONS[1].value, SD.DIVIDER, "the divider card leads the list")

-- ── external labels ─────────────────────────────────────────────────────────
-- Divider carries the name in its own band, Text makes the name the card. The
-- other three show artwork with nothing naming it, so they need the name
-- printed below the tile the way a book's title is -- without this, choosing
-- one of them silently made every author and genre tile anonymous.
reset()
eq(SD.needsExternalLabel(SD.DIVIDER), false, "divider already shows the name")
eq(SD.needsExternalLabel(SD.TEXT), false, "text IS the name")
for _i, mode in ipairs{ SD.STACK, SD.COLLAGE, SD.NONE } do
    eq(SD.needsExternalLabel(mode), true, mode .. " needs the name printed below")
end

reset()
eq(SD.needsExternalLabel(SD.RIBBON), false, "ribbon carries the name in its band")

-- externalLabel takes the resolved MODE, not a kind: the tile's style is now
-- the caller's answer, not a global this module looks up per kind.
eq(SD.externalLabel(SD.DIVIDER, "Discworld"), nil,
    "a divider-mode group needs no external label")
eq(SD.externalLabel(SD.RIBBON, "Discworld"), nil,
    "nor does a ribbon-mode one")
eq(SD.externalLabel(SD.STACK, "Discworld"), "Discworld",
    "a stack-mode group hands back its name")
eq(SD.externalLabel(SD.TEXT, "Discworld"), nil,
    "a text-mode group needs no external label")
eq(SD.externalLabel(SD.NONE, ""), nil, "an empty name is never labelled")
eq(SD.externalLabel(SD.NONE, nil), nil, "a missing name is never labelled")
eq(SD.externalLabel(SD.NONE, 42), nil, "a non-string name is never labelled")

-- ── the pile widget ──────────────────────────────────────────────────────────
local pile = SD.pileWidget(100, 200, 4)
ok(pile ~= nil, "a pile is built for a normal tile")
ok(pile and pile.paintTo ~= nil and pile.getSize ~= nil,
    "and it can paint and size itself")
-- The crash this guards: the pile was first written as a bare table with a
-- metatable, carrying paintTo and getSize but none of the event surface.
-- KOReader's containers walk their children for EVENTS as well as paint, so
-- the first tap that reached a stack-mode tile called handleEvent on it and
-- took the whole app down. Anything put into a widget tree must be a Widget.
ok(pile and type(pile.handleEvent) == "function",
    "and it answers handleEvent, because containers propagate events to children")
-- Degenerate slots must not produce a widget that paints outside itself.
eq(SD.pileWidget(2, 200, 4), nil, "no pile when the tile is narrower than the inset")
eq(SD.pileWidget(100, 2, 4), nil, "no pile when the tile is shorter than the inset")

-- ── collage member selection ─────────────────────────────────────────────────
-- Membership only. Whether a cover can be had for each is collageBB's problem,
-- because answering it means a BIM read and that is the expensive part -- an
-- earlier version filtered to already-cached covers here, which made the same
-- group render differently from one visit to the next.
local picked = SD.collageCovers({
    { filepath = "/b/1.epub" }, { filepath = "/b/2.epub" },
    { filepath = "/b/3.epub" }, { filepath = "/b/4.epub" },
}, 4)
eq(#picked, 4, "the first four members are taken regardless of cache state")
eq(picked[1], "/b/1.epub", "in member order")
eq(picked[2], "/b/2.epub", "including ones with no cached cover")

local capped = SD.collageCovers({
    { filepath = "/b/1.epub" }, { filepath = "/b/2.epub" },
    { filepath = "/b/3.epub" }, { filepath = "/b/4.epub" },
    { filepath = "/b/5.epub" },
}, 4)
eq(#capped, 4, "never more than the grid can show")

eq(#SD.collageCovers(nil, 4), 0, "a nil member list is handled")
eq(#SD.collageCovers({}, 4), 0, "an empty group yields no covers")
eq(#SD.collageCovers({ "not a table", { }, { filepath = "" } }, 4), 0,
    "junk members are skipped rather than throwing")

-- ── collage placement ────────────────────────────────────────────────────────
-- The result is quarter indices in MEMBER order: result[2] == 4 means "the
-- second cover goes in quarter 4". Confusing that with a positional index is
-- what broke the two-cover diagonal -- the gap fill keyed on position, so it
-- painted filler over the cover in quarter 4 and left quarters 2 and 3
-- untouched (and an uninitialised buffer paints black).
eq(#SD.collagePlacement(2), 2, "two members use two quarters")
eq(SD.collagePlacement(2)[1], 1, "first goes top-left")
eq(SD.collagePlacement(2)[2], 4, "second goes bottom-right, diagonally")
eq(SD.collagePlacement(1)[1], 1, "a single member goes top-left")
eq(#SD.collagePlacement(3), 3, "three members use three quarters")
eq(SD.collagePlacement(3)[3], 3, "the third fills in reading order")
eq(#SD.collagePlacement(4), 4, "four members fill every quarter")
eq(SD.collagePlacement(9)[4], 4, "more members than quarters still uses four")
eq(#SD.collagePlacement(0), 1, "a nonsense count degrades to one quarter")
eq(#SD.collagePlacement(nil), 1, "a missing count degrades to one quarter")
-- Every returned index must BE a quarter, or it indexes past the grid.
for _i, count in ipairs{ 1, 2, 3, 4, 7 } do
    for _j, q in ipairs(SD.collagePlacement(count)) do
        ok(q >= 1 and q <= 4, "placement for " .. count .. " stays within the four quarters")
    end
end

-- Fewer than two covers is not a collage: the caller renders the front cover
-- the ordinary way instead of a grid with holes in it.
eq(SD.collageBB({ "/b/1.epub" }, 100, 200), nil, "one cover is not a collage")
eq(SD.collageBB({}, 100, 200), nil, "no covers is not a collage")
eq(SD.collageBB(nil, 100, 200), nil, "a nil list is not a collage")
eq(SD.collageBB({ "/b/1.epub", "/b/2.epub" }, 0, 200), nil,
    "a degenerate slot yields no collage")

print(string.format("stack display: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
