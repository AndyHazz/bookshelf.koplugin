-- tests/_test_list_group.lua
-- How a folder or a stack presents in list mode: the hardcoded lines, and the
-- count that has to agree with the cover badge.
--
-- Usage (from plugin root): lua tests/_test_list_group.lua
--
-- The count is the part worth pinning. It reads the SAME two settings the cover
-- badge does, so the two surfaces can never disagree about whether there is a
-- number or what it counts -- and getting that wrong is invisible until someone
-- puts the two views side by side.

package.path = "./?.lua;./?/init.lua;" .. package.path

package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }

-- Widget-shaped dependencies, stubbed: this suite is about the numbers and the
-- strings. The chevron itself is a CoverProgress.buildGlyphWidget call, which
-- needs a real framebuffer to say anything interesting about.
package.loaded["ffi/blitbuffer"] = {
    COLOR_BLACK = "black", COLOR_WHITE = "white", COLOR_DARK_GRAY = "grey",
}
package.loaded["ui/widget/container/centercontainer"] = {
    new = function(_self, t) return t end,
}
package.loaded["ui/widget/container/framecontainer"] = {
    new = function(_self, t) return t end,
}
package.loaded["ui/widget/overlapgroup"] = {
    new = function(_self, t) return t end,
}
package.loaded["device"] = { screen = {
    scaleBySize = function(_self, px) return math.ceil(px * 2) end,
} }
package.loaded["ui/geometry"] = { new = function(_self, t) return t end }
package.loaded["lib/bookshelf_cover_progress"] = {
    buildGlyphWidget = function(glyph, size) return { glyph = glyph, size = size } end,
}
-- The deck's two collaborators. ListGeom is the real module -- thumbSize is
-- arithmetic and stubbing it would be stubbing the thing under test -- while a
-- card is only ever inspected for the book it was handed.
package.loaded["lib/bookshelf_spine_widget"] = {
    new = function(_self, t) return t end,
    -- The deck sizes its slot so the CARD inside comes out at the book aspect,
    -- and SpineWidget takes this off whatever it is handed.
    SHADOW_OFFSET = 8,
}

local STORE = {}
package.loaded["lib/bookshelf_settings_store"] = {
    read   = function(k, default)
        local v = STORE[k]
        if v == nil then return default end
        return v
    end,
    save   = function(k, v) STORE[k] = v end,
    isTrue = function(k) return STORE[k] == true end,
    flush  = function() end,
}

-- The repository, stubbed: a folder's count is a recursive walk, every other
-- group carries its members inline.
local FOLDER_PATHS, PROGRESS = {}, {}
local walks = 0
local built = {}
package.loaded["lib/bookshelf_book_repository"] = {
    getFolderBookPaths = function(path)
        walks = walks + 1
        return FOLDER_PATHS[path]
    end,
    readProgress = function(fp)
        local p = PROGRESS[fp]
        if not p then return nil, nil end
        return p.pct, p.status
    end,
    buildBookMeta = function(fp, opts)
        built[#built + 1] = { fp = fp, want_cover = opts and opts.want_cover }
        return { filepath = fp }
    end,
}

local helpers = dofile("tests/_helpers.lua")
local t       = helpers.runner()
local eq      = helpers.eq

local Group = require("lib/bookshelf_list_group")

local function reset()
    for k in pairs(STORE) do STORE[k] = nil end
    for k in pairs(FOLDER_PATHS) do FOLDER_PATHS[k] = nil end
    for k in pairs(PROGRESS) do PROGRESS[k] = nil end
    walks = 0
end

local function folder(path, n)
    local paths = {}
    for i = 1, n do paths[i] = path .. "/b" .. i .. ".epub" end
    FOLDER_PATHS[path] = paths
    return { kind = "folder", path = path, label = "Sci-fi" }
end

local function stack(n)
    local books = {}
    for i = 1, n do books[i] = { filepath = "/s/b" .. i .. ".epub" } end
    return { kind = "author", name = "Le Guin", books = books }
end

-- A selection set with the same surface the real one exposes.
local function selectionOf(...)
    local set = {}
    for _i, fp in ipairs({ ... }) do set[fp] = true end
    return {
        isActive = function() return true end,
        contains = function(_self, fp) return set[fp] == true end,
    }
end

-- ── The count, against the badge settings ──────────────────────────────────

t.test("the default badge mode counts groups but not folders", function()
    reset()
    -- stack_count_badge_mode unset == "groups", which is what the cover badge
    -- resolves an absent value to (bookshelf_shelf_row.lua:318-322).
    eq(Group.countText(stack(4), nil), "4 books")
    assert(Group.countText(folder("/f", 9), nil) == nil,
        "a folder must carry no count under the default mode")
end)

t.test("each badge mode gates exactly the kinds it names", function()
    reset()
    local cases = {
        off     = { folder = false, group = false },
        folders = { folder = true,  group = false },
        groups  = { folder = false, group = true  },
        all     = { folder = true,  group = true  },
    }
    for mode, want in pairs(cases) do
        STORE["stack_count_badge_mode"] = mode
        assert((Group.countText(folder("/f", 3), nil) ~= nil) == want.folder,
            mode .. ": folder count wrong")
        assert((Group.countText(stack(3), nil) ~= nil) == want.group,
            mode .. ": group count wrong")
    end
end)

t.test("a count switched off costs no folder walk", function()
    reset()
    STORE["stack_count_badge_mode"] = "off"
    Group.countText(folder("/f", 200), nil)
    eq(walks, 0, "the recursive walk must not run for a count nobody asked for")
end)

t.test("one book is not '1 books'", function()
    reset()
    STORE["stack_count_badge_mode"] = "all"
    eq(Group.countText(folder("/f", 1), nil), "1 book")
end)

t.test("an empty group has nothing to say", function()
    reset()
    STORE["stack_count_badge_mode"] = "all"
    assert(Group.countText({ kind = "folder", path = "/nope" }, nil) == nil)
    assert(Group.countText({ kind = "author", books = {} }, nil) == nil)
end)

t.test("finished_total counts finished members, labelled", function()
    reset()
    STORE["stack_count_badge_mode"]   = "all"
    STORE["stack_count_badge_format"] = "finished_total"
    local f = folder("/f", 4)
    PROGRESS["/f/b1.epub"] = { status = "finished" }
    PROGRESS["/f/b3.epub"] = { status = "finished" }
    PROGRESS["/f/b2.epub"] = { status = "reading" }
    eq(Group.countText(f, nil), "2 of 4 finished")
end)

t.test("a live selection outranks both formats", function()
    reset()
    STORE["stack_count_badge_mode"]   = "all"
    STORE["stack_count_badge_format"] = "finished_total"
    local f = folder("/f", 4)
    PROGRESS["/f/b1.epub"] = { status = "finished" }
    eq(Group.countText(f, selectionOf("/f/b2.epub", "/f/b3.epub")),
       "2 of 4 selected")
    -- Nothing of THIS group selected, but a selection is live: falls back to
    -- the plain total, NOT to the finished format.
    --
    -- That looks like an oversight and is not. The badge gates finished on
    -- `sel_active_global` -- whether ANY selection is running, not whether this
    -- stack is part of it (bookshelf_shelf_row.lua:341-344) -- so while picking
    -- books every stack shows a total or a K/N and none of them show F/N. This
    -- reproduces that, quirk included, because a list row and a cover tile
    -- disagreeing about the same stack is worse than either rule alone.
    eq(Group.countText(f, selectionOf("/elsewhere.epub")), "4 books")
end)

-- ── The lines ──────────────────────────────────────────────────────────────

t.test("line 1 is the name, line 2 the count, the rest empty", function()
    reset()
    STORE["stack_count_badge_mode"] = "all"
    local out = Group.templates(folder("/f", 7), nil, 4)
    eq(#out, 4, "one entry per line the row will draw")
    eq(out[1], "%title")
    eq(out[2], "7 books")
    eq(out[3], "")
    eq(out[4], "")
end)

t.test("with one line configured the name wins and the count is dropped",
function()
    reset()
    STORE["stack_count_badge_mode"] = "all"
    local out = Group.templates(folder("/f", 7), nil, 1)
    eq(#out, 1)
    eq(out[1], "%title", "a row saying '7 books' without saying which folder"
        .. " would be useless")
end)

t.test("a suppressed count leaves line 2 empty, not stale", function()
    reset()
    STORE["stack_count_badge_mode"] = "off"
    local out = Group.templates(folder("/f", 7), nil, 2)
    eq(out[2], "",
        "the user's book template must not survive onto a group row")
end)

-- ── The deck of member covers ──────────────────────────────────────────────

local ListGeom = require("lib/bookshelf_list_geom")

local function stackOf(n)
    local books = {}
    for i = 1, n do books[i] = { filepath = "/s/" .. i } end
    return { kind = "series", books = books }
end

t.test("a light member is hydrated; a full one is not", function()
    reset()
    built = {}
    -- Repo.getSeriesGroups gives every member LIGHT metadata and upgrades only
    -- books[1] to a full record, because holding a decoded cover per member
    -- OOM-killed KOReader on a 2000-book library. A light record answers
    -- neither has_cover nor cover_image_path, and SpineWidget needs one of
    -- them, so an unhydrated member is drawn as a placeholder -- which is
    -- exactly the bug this exists to stop: three blank cards for books whose
    -- covers are visible one screen deeper.
    local item = { kind = "series", books = {
        { filepath = "/s/1", has_cover = true },          -- full already
        { filepath = "/s/2" },                            -- light
        { filepath = "/s/3", cover_image_path = "/x.jpg" },  -- external cover
        { filepath = "/s/4" },                            -- light
    } }
    local out = Group.deckBooks(item)
    eq(#out, 4)
    -- Only the two light ones cost a lookup, and neither asks for cover data:
    -- has_cover is all that is wanted here, and SpineWidget fetches the
    -- artwork lazily for the cards actually on screen.
    eq(#built, 2)
    eq(built[1].fp, "/s/2")
    eq(built[2].fp, "/s/4")
    for _i, b in ipairs(built) do
        eq(b.want_cover, false, "the deck must not ask for cover data")
    end
end)

t.test("a stack's deck is its first four members, in order", function()
    reset()
    built = {}
    local out = Group.deckBooks(stackOf(9))
    eq(#out, Group.DECK_MAX)
    eq(out[1].filepath, "/s/1")
    eq(out[4].filepath, "/s/4")
end)

t.test("a folder's deck leads with first_book and never repeats it", function()
    reset()
    built = {}
    FOLDER_PATHS["/f"] = { "/f/a", "/f/b", "/f/c", "/f/d", "/f/e" }
    local out = Group.deckBooks{
        kind = "folder", path = "/f", first_book = { filepath = "/f/c" } }
    eq(#out, 4)
    eq(out[1].filepath, "/f/c")
    -- /f/c is already the front card, so the walk skips it rather than
    -- dealing the same cover twice into one fan.
    eq(out[2].filepath, "/f/a")
    eq(out[3].filepath, "/f/b")
    eq(out[4].filepath, "/f/d")
end)

t.test("a group with no members has no deck", function()
    reset()
    eq(Group.deck(Group.deckBooks{ kind = "folder", path = "/nope" }, 200), nil)
    eq(Group.deck({}, 200), nil)
end)

t.test("a short row keeps the chevron alone", function()
    reset()
    -- A one-line list row is about 60px on a Paperwhite, and four cards fanned
    -- across it are 40px wide each: a smear rather than an illustration.
    assert(Group.deck(stackOf(4).books, 40) == nil,
        "a row too short for a readable card must not get a deck")
    assert(Group.deck(stackOf(4).books, 200) ~= nil)
end)

-- The fan's geometry, asserted as RELATIONSHIPS rather than as the pixel
-- figures a particular step and shadow reservation happen to produce. Pinning
-- the numbers would only restate DECK_STEP back at itself, and it broke the
-- moment the overlap was tightened -- which is the change working, not a
-- regression.
local function fanOf(n, height, front)
    local deck, w = Group.deck(stackOf(n).books, height or 200,
                               { front = front or "left" })
    local offsets = {}
    for i = 1, #deck do offsets[i] = deck[i].overlap_offset[1] end
    return deck, w, offsets
end

t.test("the fan's width follows the members, not the maximum", function()
    reset()
    local _d4, w4 = fanOf(4)
    local _d2, w2 = fanOf(2)
    local _d1, w1 = fanOf(1)
    local step = w2 - w1
    assert(step > 0, "a second card must widen the fan")
    -- Four cards cost three steps, two cost one: linear in the members, so a
    -- two-book stack cannot reserve room it never fills.
    eq(w4, w1 + 3 * step)
    -- THE CARDS OVERLAP, and by more than half -- "more overlap on the covers
    -- would be better". A step at or above the card width would be a row of
    -- separate covers with a gap.
    assert(step < w1 / 2, string.format(
        "step %d against a %dpx card is not a stack, it is a row", step, w1))
end)

t.test("member 1 is the front card in both arrangements", function()
    reset()
    -- OverlapGroup draws in array order, so the card on top is the final
    -- entry, and it must be the FIRST member either way -- that is the book
    -- the cover cell would have shown. `front` only moves which end of the fan
    -- it sits at. A fan whose top card is the last member is dealt backwards.
    local _d1, w1 = fanOf(1)
    local _d2, w2 = fanOf(2)
    local step = w2 - w1

    local deck, _w, offs = fanOf(3, 200, "left")
    eq(#deck, 3)
    eq(offs[#offs], 0)          -- member 1, painted last, leftmost
    eq(offs[1], 2 * step)       -- member 3, painted first, rightmost

    local _f, _fw, foffs = fanOf(3, 200, "right")
    eq(foffs[#foffs], 2 * step) -- member 1, painted last, rightmost
    eq(foffs[1], 0)             -- member 3, painted first, leftmost
end)

t.test("the chevron is sized against what it is given", function()
    reset()
    -- At the row's right it is sized off the first LINE, not the row, so the
    -- arrow tracks the type beside it instead of being a signpost the height
    -- of a four-line item.
    local small = Group.chevronWidth(40)
    local big   = Group.chevronWidth(200)
    assert(big > small, "a taller reference must give a bigger arrow")
    -- Never zero, whatever it is handed: a nil reference is a missing line,
    -- not a request for an invisible affordance.
    assert(Group.chevronWidth(nil) >= 8)
    assert(Group.chevronWidth(0) >= 8)
end)

t.test("an OPDS subcatalogue counts what the feed declares, or says nothing",
function()
    reset()
    STORE["stack_count_badge_mode"] = "all"
    -- No members to walk: they are on someone else's server. The feed may
    -- declare a total, and where it does not, the row says nothing rather
    -- than guessing at one.
    local nav = { kind = "opds_nav", is_opds_nav = true, title = "Popular" }
    assert(Group.countText(nav, nil) == nil,
        "a feed that declares nothing must not be given a count")
    nav.nav_item_count = 42
    eq(Group.countText(nav, nil), "42 books")
    nav.nav_item_count = 1
    eq(Group.countText(nav, nil), "1 book")
    nav.nav_item_count = 0
    assert(Group.countText(nav, nil) == nil, "zero is nothing to say")
    -- And it never walks: a nav entry has no path to walk.
    eq(walks, 0)
end)

t.test("an OPDS subcatalogue deals its own tile image as the one card",
function()
    reset()
    -- Some catalogues put artwork on the nav entry itself. One card is not a
    -- fan, but it is the difference between a row with a picture on it and a
    -- row with a title and 250px of nothing.
    eq(#Group.deckBooks{ kind = "opds_nav", title = "Popular" }, 0)
    local with_url = { kind = "opds_nav", title = "Popular",
                       opds = { thumbnail_url = "http://x/t.jpg" } }
    local out = Group.deckBooks(with_url)
    eq(#out, 1)
    eq(out[1], with_url, "the nav record IS the card")
    -- A cover already fetched to disk counts the same way.
    eq(#Group.deckBooks{ kind = "opds_nav", cover_image_path = "/c/x.jpg" }, 1)
end)

t.done()

