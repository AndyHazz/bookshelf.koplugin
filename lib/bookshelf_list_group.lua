-- bookshelf_list_group.lua
-- How a FOLDER or a STACK renders in list mode, as opposed to a book.
--
-- ── WHY GROUPS ARE HARDCODED HERE ──────────────────────────────────────────
--
-- Every other part of the list model is the user's: how many lines, what is on
-- them, what they are set in. A group is the exception, on the maintainer's
-- ruling:
--
--     "Folders and stacks need to be presented differently to books, probably
--      something we'd hardcoded - let's start by just putting a chevron icon
--      in the cover column, the folder title, then 'x Books' on the second
--      row"
--
-- The reason it has to be an exception rather than a preference is that a
-- template written for books says nothing useful about a folder. "%authors ...
-- %book_pct of %page_count pages" against a folder is at best blank and at
-- worst a lie -- a folder has no author and no reading position. Under the
-- column model each column carried a second, group-shaped accessor to paper
-- over this; a template has no such thing, so the row substitutes its own
-- content instead.
--
-- What it does NOT substitute is the STYLE. Each hardcoded line borrows the
-- face, size, weight, case and alignment of the user's line in the same slot.
-- That is not politeness, it is a load-bearing invariant: the row-height budget
-- measures the user's lines, so a group row that set its own sizes would be a
-- different height from the book rows around it and the page would hold the
-- wrong number of items. Same styles in, same height out, by construction.
--
-- ── THE COUNT ──────────────────────────────────────────────────────────────
--
--     "the count should use the same settings that drive the numbers shown on
--      the badge in cover view mode ... just using the extra width available to
--      make it clear what the numbers are with text labels"
--
-- So this reads the same two settings the cover badge does and answers the same
-- question, in words rather than in the badge's compressed notation:
--
--     cover badge   list line
--     ×12           12 books
--     3/12          3 of 12 finished          (stack_count_badge_format)
--     3/12          3 of 12 selected          (selection, which outranks both)
--
-- Including the OFF case: stack_count_badge_mode decides whether folders,
-- groups, both or neither carry a count, and a user who turned the badge off
-- gets no count line either. That also keeps the cost honest -- a folder's
-- count needs a recursive walk, and nothing here pays for one unless the
-- setting asked for the number.

local Blitbuffer     = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom           = require("ui/geometry")
local OverlapGroup   = require("ui/widget/overlapgroup")
local Screen         = require("device").screen
local CoverProgress  = require("lib/bookshelf_cover_progress")
local BookshelfSettings = require("lib/bookshelf_settings_store")
local Repo           = require("lib/bookshelf_book_repository")
local _              = require("lib/bookshelf_i18n").gettext

local Group = {}

-- chevron-right, U+E841 in the bundled symbols face. PUA only: a non-PUA
-- codepoint has segfaulted this plugin before, and that face covers
-- U+E000..U+F8FF and nothing else (see bookshelf_cover_progress.lua's note on
-- GLYPH_DOWNLOADED).
Group.CHEVRON = "\u{e841}"

-- How much of the cover cell's height the chevron fills. Sized off the cell
-- rather than off the font so it stays proportional when the row's density
-- changes -- at list_font_scale 60 a fixed-size glyph would overflow the
-- thumbnail slot it is standing in for.
--
-- 0.38 rather than the 0.55 first tried. A chevron is a signpost, not the
-- subject of the row: at 0.55 on a two-line row it rendered about twice the
-- cap height of the folder name beside it and pulled the eye down the column
-- of arrows instead of down the column of names. Measured against a 97px row
-- on a PW5, where this puts it at roughly the height of the title's capitals.
local CHEVRON_FILL = 0.38

-- ── The count ──────────────────────────────────────────────────────────────

-- Which kinds carry a count, from the same setting the cover badge reads.
-- Default "groups", matching bookshelf_shelf_row.lua's own resolution.
local function badgeKinds()
    local mode = BookshelfSettings.read("stack_count_badge_mode")
    if not (mode == "off" or mode == "folders" or mode == "groups"
         or mode == "all") then
        mode = "groups"
    end
    return (mode == "folders" or mode == "all"),   -- folders
           (mode == "groups"  or mode == "all")    -- every other group kind
end

-- The member filepaths of a group, or nil when it has none to offer.
-- A folder's are a recursive walk (cached by the repo); every other kind
-- carries its members inline.
local function memberPaths(item)
    if item.kind == "folder" then
        if not item.path then return nil end
        return Repo.getFolderBookPaths(item.path)
    end
    if item.books then
        local out = {}
        for i = 1, #item.books do out[i] = item.books[i].filepath end
        return out
    end
    return nil
end

local function countIn(paths, predicate)
    local n = 0
    for i = 1, #paths do
        local fp = paths[i]
        if fp and predicate(fp) then n = n + 1 end
    end
    return n
end

-- countText(item, selection) -> a labelled count, or nil.
--
-- nil rather than "" when there is nothing to say, so the caller can leave the
-- line's own template in place rather than blanking it.
function Group.countText(item, selection)
    local folders_on, groups_on = badgeKinds()
    local is_folder = item.kind == "folder"
    if is_folder and not folders_on then return nil end
    if not is_folder and not groups_on then return nil end

    local paths = memberPaths(item)
    if not paths or #paths == 0 then return nil end
    local total = #paths

    -- Selection wins, exactly as it does on the badge: while picking books the
    -- user wants to see how much of each stack they have got.
    local sel_active = selection and selection.isActive and selection:isActive()
    if sel_active then
        local k = countIn(paths, function(fp) return selection:contains(fp) end)
        if k > 0 then
            return string.format(_("%d of %d selected"), k, total)
        end
    end

    local format = BookshelfSettings.read("stack_count_badge_format")
    -- Finished is an OUT-of-selection format on the badge too: while a
    -- selection is live the user is being told about the selection instead.
    if format == "finished_total" and not sel_active then
        local f = countIn(paths, function(fp)
            local _pct, status = Repo.readProgress(fp)
            return status == "finished"
        end)
        return string.format(_("%d of %d finished"), f, total)
    end

    if total == 1 then return _("1 book") end
    return string.format(_("%d books"), total)
end

-- ── The cover cell ─────────────────────────────────────────────────────────

-- chevron(width, height, glyph_h) -> a widget filling that cell with a right
-- chevron. `glyph_h` is what the glyph is sized against; the cell's own height
-- when omitted.
--
-- It is NOT a cover, and that is the point. A group's first book would give a
-- real one -- it is what the cover grid's stack tiles show -- and at thumbnail
-- size in a table that is exactly the problem: one arbitrary member's artwork,
-- too small to recognise, is indistinguishable from a book row. The chevron
-- says "this opens into something", which is the one thing artwork cannot say.
--
-- It moved to the RIGHT-HAND END of the row once the deck arrived, on the
-- maintainer's ruling: "moved the chevron the right of the books, and left
-- aligned to help title/book count". Two things fall out of that. The row
-- reads name, count, then the books it holds, then the way in -- and with the
-- cover cell gone the group's text starts at the row's left edge instead of
-- indented to line up with book thumbnails, which is the clearest signal yet
-- that a folder is not a book. There it is sized against the first LINE
-- rather than the row, the way the bulk-select tick is: a disclosure arrow
-- beside the title, not a signpost the height of the whole row.
function Group.chevron(width, height, glyph_h)
    local size = math.max(8, math.floor((glyph_h or height) * CHEVRON_FILL))
    local glyph = CoverProgress.buildGlyphWidget(
        Group.CHEVRON, size, Blitbuffer.COLOR_BLACK)
    return CenterContainer:new{
        dimen = Geom:new{ w = width, h = height },
        glyph,
    }
end

-- chevronWidth(glyph_h) -> the cell width that arrow wants at the row's right.
-- Square on its glyph size, so it reserves no more of the row than the arrow
-- actually occupies.
function Group.chevronWidth(glyph_h)
    return math.max(8, math.floor((glyph_h or 0) * CHEVRON_FILL))
end

-- ── The deck ───────────────────────────────────────────────────────────────
--
-- Up to four member covers, overlapping like a fanned hand of cards, filling
-- the space a folder row has and a book row has not.
--
--     "the folder/stack rows stick out as needing a lot of work ... use the
--      covers inside the folder, four of them like we have in the collage
--      cover, and stack them up on the right edge like a bunch of overlapping
--      cards"
--
-- WHY IT GOES ON THE RIGHT rather than in the cover cell. The cell is one
-- thumbnail wide -- a cover at the row's height is already as wide as the
-- column -- so a deck inside it would have to shrink every card to about a
-- third, and a 55px cover says nothing at all. The row's RIGHT-HAND side is
-- the space that is actually free: a group has two lines to say against a
-- book's four or five, so on the maintainer's layout there were 750 empty
-- pixels beside "Southern Reach / 4 books". The deck fills the emptiness that
-- made the row look broken, at full thumbnail size, and the chevron stays in
-- the cover cell saying "this opens into something" -- which artwork alone
-- does not say.
Group.DECK_MAX = 4

-- Which end of the fan is on top. "left" puts the first member's cover nearest
-- the text and the rest trailing off towards the row's edge, which is the
-- reading order; "right" anchors the front card on the row edge and recedes
-- back towards the text. A module constant rather than a setting until it has
-- been looked at on a real panel -- see the note on UI surface minimalism.
Group.DECK_FRONT = "left"

-- How far each card sits from the one under it, as a fraction of a card's
-- width. 0.42 was the first try and read as a row of overlapping covers rather
-- than as a stack; 0.28 buries most of each card and leaves the front one
-- clearly the subject.
local DECK_STEP = 0.28

-- A deck needs room to be a deck. Below this the cards are too small to tell
-- apart and the row keeps the chevron alone -- a one-line list has a ~60px row
-- and four 40px-wide cards in it is a smear, not an illustration.
local DECK_MIN_H = 64

-- EVERY MEMBER IN ORDER, coverless ones included and drawn as bare cards.
-- Two other rules were tried on screen first and both looked worse:
--
--   * skip the coverless and deal the next member instead. A ten-book series
--     whose members BIM has not indexed yet then shows ONE card, which reads
--     as "one book in here" -- contradicted by the count line beside it.
--   * give the coverless SpineWidget's lettered placeholder, so each card
--     names its book. Only about 70px of each buried card is visible, and the
--     placeholder centres its text in the card it thinks it has, so what
--     actually renders is a white strip with the middle of one word in it.
--
-- Which is the general lesson about this fan: past the front card there is a
-- SLIVER, and only things that survive being sliced -- artwork, or a plain
-- bordered card -- are worth putting on one.

-- A GROUP'S INLINE MEMBERS ARE LIGHT RECORDS AND HAVE NO COVER FIELDS. That is
-- deliberate upstream and it caught this out: Repo.getTags / getSeriesGroups
-- hydrate every member with light metadata and upgrade only books[1] to a full
-- record, because "the stack visual only renders books[1]'s cover" -- holding a
-- decoded cover for every member of every group is what OOM-killed KOReader on
-- a 2000-book library. A light record has no has_cover and no
-- cover_image_path, and SpineWidget requires one of them
-- (bookshelf_spine_widget.lua:794), so the deck drew the front card's artwork
-- and three placeholders for books whose covers the maintainer could see
-- perfectly well one screen deeper.
--
-- So a member that has never been asked about gets a buildBookMeta here.
-- want_cover = false, which is what keeps the upstream reasoning intact: it
-- sets has_cover without decoding anything, and SpineWidget's own lazy path
-- (scaled-cover cache, then Repo.getCoverBB) fetches the artwork at render
-- time for the three cards that are actually on screen.
local function hydrated(book)
    if type(book) ~= "table" then return nil end
    -- Already knows: a full record answers has_cover either way, and an
    -- external enrichment cover is decisive on its own.
    if book.has_cover ~= nil or book.cover_image_path then return book end
    if type(book.filepath) ~= "string" then return book end
    local ok, rec = pcall(Repo.buildBookMeta, book.filepath,
                          { want_cover = false })
    return (ok and rec) or book
end

-- Member BOOKS -- records, not paths -- for the deck, at most `limit` of them.
--
-- A stack or a series carries its members inline; a folder carries only its
-- first book, so the rest come from the cached recursive walk. Either way each
-- one goes through hydrated() before it is dealt.
function Group.deckBooks(item, limit)
    limit = limit or Group.DECK_MAX
    local out = {}
    if type(item) ~= "table" then return out end
    if item.books then
        for i = 1, #item.books do
            if #out >= limit then break end
            if item.books[i] then out[#out + 1] = hydrated(item.books[i]) end
        end
        return out
    end
    if item.kind ~= "folder" then return out end
    -- The first book is already a record; taking it from here rather than from
    -- the walk keeps the cover cell and the deck's front card agreeing about
    -- which book comes first.
    local first_fp
    if type(item.first_book) == "table" then
        out[1] = hydrated(item.first_book)
        first_fp = item.first_book.filepath
    end
    local paths = memberPaths(item)
    if not paths then return out end
    for i = 1, #paths do
        if #out >= limit then break end
        if paths[i] ~= first_fp then
            local ok, rec = pcall(Repo.buildBookMeta, paths[i],
                                  { want_cover = false })
            if ok and rec then out[#out + 1] = rec end
        end
    end
    return out
end

-- Group.deck(books, height, opts) -> widget, width  (nil when there is no deck)
--
-- opts.front  "left" (default) or "right" -- which end of the fan is on top.
--
-- EACH CARD KEEPS THE COVER GRID'S OWN CARD CHROME -- rounded corners and a
-- drop shadow -- which is what separates one card from the next. The first
-- version drew flat thumbnails in hairline frames instead, on the reasoning
-- that a shadow needs a margin a table row has not got. It does not need one
-- here: the shadow falls onto the card BEHIND, which is the whole point of a
-- fan, and SpineWidget reserves the offset inside the slot it is given
-- (_cardDimensions) so it costs the deck width rather than the row.
--
-- The paint order does the work. Cards are dealt back to front, so card i is
-- painted after card i+1 and its shadow lands on card i+1's face. That only
-- holds while the fan opens to the RIGHT, since SpineWidget's shadow is fixed
-- at bottom-right; with front = "right" the cards recede leftwards and each
-- shadow is covered by the card dealt after it. Noted rather than fixed --
-- "left" is the default and the arrangement this was designed against.
function Group.deck(books, height, opts)
    opts = opts or {}
    if type(books) ~= "table" or #books == 0 then return nil end
    if not height or height < DECK_MIN_H then return nil end

    local ListGeom = require("lib/bookshelf_list_geom")
    local SpineWidget = require("lib/bookshelf_spine_widget")
    -- The SLOT, sized so the CARD inside it comes out at the book aspect:
    -- SpineWidget takes its shadow reservation off whatever it is handed.
    local shadow = SpineWidget.SHADOW_OFFSET or Screen:scaleBySize(4)
    local card_w = ListGeom.thumbSize(height - shadow, 0) + shadow
    local step   = math.max(shadow * 2, math.floor(card_w * DECK_STEP))
    local n      = math.min(#books, Group.DECK_MAX)
    local total  = card_w + (n - 1) * step

    local group = OverlapGroup:new{
        dimen = Geom:new{ w = total, h = height },
        allow_mirroring = false,
    }
    -- MEMBER 1 IS ALWAYS THE FRONT CARD, in both arrangements: it is the book
    -- the cover cell would have shown, and a fan whose top card is the LAST
    -- member is a fan dealt backwards. `front` only decides which end of the
    -- row that card sits at.
    for i = n, 1, -1 do
        local card = SpineWidget:new{
            book             = books[i],
            width            = card_w,
            height           = height,
            -- No lettering on a coverless card: see the note above deckBooks
            -- for what that looks like on a sliver.
            bare_placeholder = true,
        }
        card.overlap_offset = {
            (opts.front == "right") and (n - i) * step or (i - 1) * step, 0 }
        group[#group + 1] = card
    end
    return group, total
end

-- ── The lines ──────────────────────────────────────────────────────────────

-- templates(item, selection, n_lines) -> array of template strings, or nil
-- when `item` is not a group.
--
-- One entry per line the row will draw, so the caller can index it directly.
-- Line 1 is the group's name (through %title, which Lines.groupRecord maps to
-- whichever field this kind of group keeps its name in). Line 2 is the count.
-- Anything below is empty -- a group has nothing else to say, and repeating the
-- name or the count to fill the space would be noise.
--
-- With only ONE line configured the count has nowhere to go and is dropped;
-- the name wins, because a row that says "12 books" without saying which
-- folder is useless.
function Group.templates(item, selection, n_lines)
    local out = {}
    for i = 1, n_lines do out[i] = "" end
    out[1] = "%title"
    if n_lines >= 2 then
        out[2] = Group.countText(item, selection) or ""
    end
    return out
end

return Group
