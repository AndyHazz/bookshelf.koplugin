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

local function reset() stored = {} end

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

-- NO migration off the per-kind keys this replaced, deliberately: that model
-- never shipped, so the only settings files carrying folder_display and
-- friends are the ones it was built on. A stale key is simply never read.
reset()
stored.folder_display = SD.STACK
stored.series_display = SD.COLLAGE
eq(SD.defaultMode(), SD.DIVIDER, "a stale per-kind key does not seed the default")
eq(SD.resolve(nil), SD.DIVIDER, "nor does it reach a tile")
eq(stored.folder_display, SD.STACK, "and nothing rewrites the user's settings behind them")

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

-- ── "follow the library default" as an explicit choice ─────────────────────
-- A chip could always BE unset, but the picker had no row for it, so once a
-- style was chosen there was no way back except changing the library default.
-- The sentinel has to stay invisible to every existing reader: resolve() must
-- treat it exactly like an untouched chip.
eq(SD.resolve(SD.FOLLOW_DEFAULT), SD.defaultMode(),
   "the follow-default sentinel resolves to the library default")
eq(SD.resolve(nil), SD.resolve(SD.FOLLOW_DEFAULT),
   "and is indistinguishable from never having been set")
eq(SD.pinned(SD.FOLLOW_DEFAULT), nil, "it is not a pinned style")
eq(SD.pinned(nil), nil, "and neither is an untouched chip")
eq(SD.pinned(SD.STACK), SD.STACK, "a chosen style reads back as pinned")
eq(SD.pinned("nonsense"), nil, "a style this build does not offer is not pinned")
-- The library default's own picker must not offer "the default", which would
-- be circular; only the chip editor's list carries it.
eq(SD.CHIP_OPTIONS[1].value, SD.FOLLOW_DEFAULT, "the chip list leads with it")

-- ── TILE STYLES ONLY ───────────────────────────────────────────────────────
-- This field carries no view-mode vocabulary. A chip's list-or-covers pin was
-- briefly a sentinel in here and the maintainer split it back out into its own
-- field: a chip has to be able to say "divider cards" without also asserting a
-- mode. Pinned so a future merge has to argue with a test rather than with a
-- comment.
eq(#SD.CHIP_OPTIONS, #SD.OPTIONS + 1,
   "CHIP_OPTIONS is the styles plus one sentinel; something else crept in")
assert(SD.LIST == nil, "a view-mode value is back in the tile-style module")
assert(SD.isList == nil, "a view-mode predicate is back in the tile-style module")
for _i, opt in ipairs(SD.CHIP_OPTIONS) do
    assert(opt.value ~= "list" and opt.value ~= "covers",
        "a view mode is being offered as a tile style: " .. tostring(opt.value))
end

-- chipLabelFor: what a chip's ROW says its TILES are. Distinct from labelFor,
-- which falls back to the first tile style -- right for the library default,
-- wrong for a chip, where "not set" and "set to Divider card" are different
-- states.
eq(SD.chipLabelFor(SD.STACK), SD.labelFor(SD.STACK))
eq(SD.chipLabelFor(nil), "Default")
eq(SD.chipLabelFor(SD.FOLLOW_DEFAULT), "Default")
eq(SD.chipLabelFor("nonsense"), "Default",
   "a value this build does not know reads as unset, not as Divider card")
local in_global = false
for _i, o in ipairs(SD.OPTIONS) do
    if o.value == SD.FOLLOW_DEFAULT then in_global = true end
end
eq(in_global, false, "the library-wide list does not offer it")

-- ── the collage gap wash: palette ──────────────────────────────────────────
-- Gaps used to be one flat colour: the mean of every cover that resolved. A
-- flat panel beside photographic covers reads as missing artwork, and the more
-- covers it averaged the muddier it got.
--
-- The scoring is count * (saturation + floor), and the case that forces it is
-- a gold ring on a black cover: the ring is a few percent of the pixels and
-- loses every popularity contest, but it is the only thing anyone would
-- describe. Area alone picks black; area weighted by saturation picks gold.
local function hist(entries)
    -- entries: { {n=, r=, g=, b=}, ... } already averaged per bucket
    local h = {}
    for i, e in ipairs(entries) do
        h[i] = { n = e.n, r = e.r * e.n, g = e.g * e.n, b = e.b * e.n }
    end
    return h
end

do
    -- 90% neutral dark, plus mid and light greys that OUTNUMBER the gold, so
    -- ranking has to do real work: there are five candidates for three slots,
    -- and by area alone the gold is fifth and never picked.
    local p = SD.pickPalette(hist{
        { n = 900, r = 12,  g = 12,  b = 12  },   -- the background
        { n = 300, r = 60,  g = 60,  b = 60  },   -- shadow
        { n = 200, r = 110, g = 110, b = 110 },   -- midtone
        { n = 150, r = 170, g = 170, b = 170 },   -- highlight
        { n = 50,  r = 212, g = 168, b = 40  },   -- the ring: outnumbered 18:1
    }, 3)
    eq(#p, 3, "three stops from five candidates")
    local has_gold = false
    for _i, c in ipairs(p) do
        if c.r > 150 and c.g > 120 and c.b < 100 then has_gold = true end
    end
    eq(has_gold, true, "the ring's gold beats four larger greys on saturation")
    -- And the wash runs dark to light, not by rank.
    local lum = function(c) return 0.299*c.r + 0.587*c.g + 0.114*c.b end
    local ordered = true
    for i = 2, #p do if lum(p[i]) < lum(p[i-1]) then ordered = false end end
    eq(ordered, true, "stops are ordered dark to light")
end

do
    -- A black-and-white cover has nothing saturated. Without the saturation
    -- FLOOR every bucket scores zero, ranking collapses to the tiebreak, and a
    -- single stray near-black pixel outranks the 600 that make up the actual
    -- dark - then swallows it as "too close" and shifts the whole wash.
    local p = SD.pickPalette(hist{
        { n = 600, r = 20,  g = 20,  b = 20  },   -- the real dark
        { n = 300, r = 200, g = 200, b = 200 },   -- the real light
        { n = 1,   r = 2,   g = 2,   b = 2   },   -- one stray pixel
    }, 3)
    ok(#p >= 2, "a monochrome cover still yields a usable wash")
    eq(math.floor(p[1].r), 20, "area decides when nothing is saturated, so the dark is the real one")
end

do
    -- Stops too close together make a wash with no visible travel - that is
    -- just the flat fill again, with extra steps.
    local p = SD.pickPalette(hist{
        { n = 500, r = 100, g = 100, b = 100 },
        { n = 400, r = 104, g = 102, b = 101 },   -- indistinguishable
    }, 3)
    eq(#p, 1, "near-identical colours collapse to one stop")
end

eq(#SD.pickPalette({}, 3), 0, "no samples, no stops")
eq(#SD.pickPalette(nil, 3), 0, "no histogram, no stops")

-- ── the collage gap wash: interpolation ────────────────────────────────────
-- If the endpoints do not land exactly on the first and last stop, the wash
-- starts mid-colour and meets the covers as a shade nobody picked.
local A = { r = 40,  g = 60,  b = 80  }
local B = { r = 200, g = 160, b = 120 }
local C = { r = 120, g = 110, b = 100 }
eq(SD.gradientColorAt({ A }, 0).r, 40, "one stop: flat at the start")
eq(SD.gradientColorAt({ A }, 1).r, 40, "one stop: flat at the end")
eq(SD.gradientColorAt({ A, B }, 0).r,   40,  "two stops: t=0 IS the first stop")
eq(SD.gradientColorAt({ A, B }, 1).r,   200, "two stops: t=1 IS the last stop")
eq(SD.gradientColorAt({ A, B }, 1).b,   120, "and on every channel")
eq(SD.gradientColorAt({ A, B }, 0.5).r, 120, "two stops: halfway is halfway")
eq(SD.gradientColorAt({ A, B }, 0.5).g, 110, "on the green channel too")
-- Three covers put a stop in the middle, so t=0.5 must land ON it.
eq(SD.gradientColorAt({ A, C, B }, 0.5).r, 120, "three stops: the middle stop is reached")
eq(SD.gradientColorAt({ A, C, B }, 1).r,   200, "three stops: t=1 IS the last stop")
eq(SD.gradientColorAt({ A, B }, -0.5).r, 40,  "below the run clamps to the first stop")
eq(SD.gradientColorAt({ A, B }, 1.5).r,  200, "above the run clamps to the last stop")
eq(SD.gradientColorAt({}, 0.5),  nil, "no stops, no colour")
eq(SD.gradientColorAt(nil, 0.5), nil, "no list, no colour")

print(string.format("stack display: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
