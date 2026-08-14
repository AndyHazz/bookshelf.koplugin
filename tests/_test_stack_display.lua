-- tests/_test_stack_display.lua
-- Per-kind folder/stack display modes.
--
-- The default dominates everything else here: unset must mean the shipped
-- divider card, for every kind, including kinds this build has never heard of.
-- Any regression there changes every tile on every shelf of every library that
-- never opens this menu.
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["logger"] = { dbg=function() end, info=function() end,
                             warn=function() end, err=function() end }

-- Stub the KOReader surface the module touches at load time.
local stored = {}
package.loaded["lib/bookshelf_settings_store"] = {
    read = function(k) return stored[k] end,
    save = function(k, v) stored[k] = v end,
}
package.loaded["ffi/blitbuffer"] = {
    COLOR_BLACK = "black", COLOR_WHITE = "white",
    new = function() return nil end,
}
package.loaded["ui/geometry"] = { new = function(_s, t) return t end }
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

-- ── defaults ─────────────────────────────────────────────────────────────────
reset()
for _i, k in ipairs(SD.KINDS) do
    eq(SD.modeFor(k.kind), SD.DIVIDER, k.kind .. ": unset means the divider card")
end
eq(SD.modeFor("nonsense"), SD.DIVIDER, "an unknown kind falls back to the divider card")
eq(SD.modeFor(nil), SD.DIVIDER, "a nil kind falls back to the divider card")
eq(SD.showsCardboard(SD.DIVIDER), true, "divider draws the cardboard")
eq(SD.pileInset(SD.DIVIDER), 0, "divider needs no room for a pile")

-- Every kind that renders through a stack widget must have a row, or it would
-- silently follow a default nobody can change. This is the list that keeps the
-- menu and the renderers in agreement.
local kinds = {}
for _i, k in ipairs(SD.KINDS) do kinds[k.kind] = true end
for _i, needed in ipairs{ "folder", "series", "author", "genre", "tag",
                          "language", "format", "rating" } do
    ok(kinds[needed], "kind '" .. needed .. "' has a settings row")
end

-- Keys must be distinct, or two kinds would share one setting.
local seen_keys = {}
for _i, k in ipairs(SD.KINDS) do
    ok(not seen_keys[k.key], "settings key " .. k.key .. " is used by exactly one kind")
    seen_keys[k.key] = true
end

-- ── stored values ────────────────────────────────────────────────────────────
reset()
stored.series_display = SD.STACK
stored.genre_display  = SD.TEXT
stored.author_display = SD.NONE
eq(SD.modeFor("series"), SD.STACK, "series honours its own setting")
eq(SD.modeFor("genre"),  SD.TEXT,  "genre honours its own setting")
eq(SD.modeFor("author"), SD.NONE,  "author honours its own setting")
eq(SD.modeFor("folder"), SD.DIVIDER, "an untouched kind is unaffected by its neighbours")

-- A value this build does not offer must not reach a renderer.
reset()
stored.series_display = "hologram"
eq(SD.modeFor("series"), SD.DIVIDER, "an unknown stored mode falls back to the divider card")
stored.series_display = 3
eq(SD.modeFor("series"), SD.DIVIDER, "a non-string stored mode falls back too")

-- ── mode predicates ──────────────────────────────────────────────────────────
reset()
for _i, mode in ipairs{ SD.STACK, SD.COLLAGE, SD.TEXT, SD.NONE } do
    eq(SD.showsCardboard(mode), false, mode .. " does not draw the cardboard")
end
eq(SD.isTextOnly(SD.TEXT), true, "text mode suppresses artwork")
for _i, mode in ipairs{ SD.DIVIDER, SD.STACK, SD.COLLAGE, SD.NONE } do
    eq(SD.isTextOnly(mode), false, mode .. " still renders artwork")
end

-- Only stack reserves horizontal room; every other mode gets the full slot, so
-- callers can subtract the inset unconditionally.
ok(SD.pileInset(SD.STACK) > 0, "stack reserves room for the layers behind")
for _i, mode in ipairs{ SD.DIVIDER, SD.COLLAGE, SD.TEXT, SD.NONE } do
    eq(SD.pileInset(mode), 0, mode .. " reserves no pile room")
end
-- The inset has to leave the cover the majority of a narrow tile.
ok(SD.pileInset(SD.STACK) < 40, "the pile inset stays small enough for a tile")

-- ── labels ───────────────────────────────────────────────────────────────────
for _i, opt in ipairs(SD.OPTIONS) do
    local label = SD.labelFor(opt.value)
    ok(type(label) == "string" and label ~= "", "each mode has a label")
end
eq(SD.labelFor("hologram"), SD.OPTIONS[1].label_func(),
    "an unknown value renders as the default option's label")
-- The default option must be the nil one: a stored "divider" string would be a
-- second way to say the same thing and would defeat the unset-means-default
-- rule the renderers rely on.
eq(SD.OPTIONS[1].value, nil, "the first option is the unset default")

-- ── the pile widget ──────────────────────────────────────────────────────────
local pile = SD.pileWidget(100, 200)
ok(pile ~= nil, "a pile is built for a normal tile")
ok(pile and pile.paintTo ~= nil and pile.getSize ~= nil,
    "and it satisfies the widget contract")
-- Degenerate slots must not produce a widget that paints outside itself.
eq(SD.pileWidget(2, 200), nil, "no pile when the tile is narrower than the inset")
eq(SD.pileWidget(100, 2), nil, "no pile when the tile is shorter than the inset")

-- ── collage cover selection ──────────────────────────────────────────────────
-- Only covers the scaled cache already holds are used. Members 2..N of a group
-- are bare { filepath } stubs and hydrating them would be a BIM decode each,
-- which is the cost the one-cover-per-group rule exists to avoid.
local cached = {}
package.loaded["lib/bookshelf_scaled_cover_cache"] = {
    has = function(_s, fp) return cached[fp] == true end,
    get = function(_s, fp) return cached[fp] and ("bb:" .. fp) or nil end,
}
cached["/b/1.epub"] = true
cached["/b/3.epub"] = true
local picked = SD.collageCovers({
    { filepath = "/b/1.epub" }, { filepath = "/b/2.epub" },
    { filepath = "/b/3.epub" }, { filepath = "/b/4.epub" },
}, 4)
eq(#picked, 2, "only cached covers are taken")
eq(picked[1], "/b/1.epub", "in member order")
eq(picked[2], "/b/3.epub", "skipping the uncached ones")

cached["/b/2.epub"] = true
cached["/b/4.epub"] = true
cached["/b/5.epub"] = true
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

-- Fewer than two covers is not a collage: the caller renders the front cover
-- the ordinary way instead of a grid with holes in it.
eq(SD.collageBB({ "/b/1.epub" }, 100, 200), nil, "one cover is not a collage")
eq(SD.collageBB({}, 100, 200), nil, "no covers is not a collage")
eq(SD.collageBB(nil, 100, 200), nil, "a nil list is not a collage")
eq(SD.collageBB({ "/b/1.epub", "/b/2.epub" }, 0, 200), nil,
    "a degenerate slot yields no collage")

print(string.format("stack display: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
