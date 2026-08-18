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

    -- An OPDS subcatalogue has no members to walk -- they are on someone
    -- else's server -- but the feed sometimes DECLARES how many it holds.
    -- Where it does, that is the count; where it does not, the row says
    -- nothing rather than guessing, which is why an OPDS listing can still
    -- come out with a bare title and why the deck below matters there.
    if item.is_opds_nav then
        local n = tonumber(item.nav_item_count)
        if not n or n < 1 then return nil end
        if n == 1 then return _("1 book") end
        return string.format(_("%d books"), n)
    end

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

-- How many configured lines a row needs before a group with no covers gets the
-- fallback tile: "probably drop the card if only 1 or 2 lines for folders".
--
-- The tile exists to fill a TALL row that has nothing in it. A one- or
-- two-line listing is a compact table, its rows do not look empty, and a
-- cardboard card printed with a name the row's own first line already carries
-- is just clutter at that density. Stated in LINES rather than pixels because
-- that is the thing the reader chose; the pixel floor in Group.tile is a crash
-- guard underneath it, not a second opinion about taste.
Group.TILE_MIN_LINES = 3

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
    -- A REMOTE SUBCATALOG NEVER GETS ARTWORK, in either view: "the list view
    -- in opds needs to follow the same rules as the cover view and show
    -- folders as text style covers only".
    --
    -- The cover grid has always forced these to StackDisplay.TEXT, and the
    -- reasoning at that call site is about where the picture comes FROM: a
    -- remote category has no artwork of its own, so an image mode ends up
    -- borrowing a cover from whatever child happened to be cached inside it --
    -- usually the wrong picture for the category, and reading as a bug rather
    -- than a choice. The repo attaches exactly such a borrowed cover as
    -- cover_image_path.
    --
    -- This dealt one when the nav entry had a picture, which broke the rule in
    -- the one view that had not been carrying it. Nav entries fall through to
    -- Group.tile now, which forces TEXT.
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

    local SpineWidget = require("lib/bookshelf_spine_widget")
    -- The SLOT, sized so the CARD inside it comes out at the book aspect:
    -- SpineWidget takes its shadow reservation off whatever it is handed.
    local shadow = SpineWidget.SHADOW_OFFSET or Screen:scaleBySize(4)
    local card_w, card_h = Group.slotWidth(height)
    local step   = math.max(shadow * 2, math.floor(card_w * DECK_STEP))
    local n      = math.min(#books, Group.DECK_MAX)
    local total  = card_w + (n - 1) * step

    -- opts.max_w: the row's art budget. What it bounds is the FAN's total, not
    -- one card -- the row pays for the whole spread, and a deck sized only by
    -- the row height grew past the row's own width in a multi-column list
    -- (ListGeom.ART_MAX_SHARE has the crash that caused).
    --
    -- Solved rather than looped: `step` is card_w * DECK_STEP except at its
    -- shadow floor, so total = card_w * (1 + (n-1)*DECK_STEP) and one division
    -- lands it. The floor case can still overshoot, and then cards come off
    -- the back of the fan -- fewer books shown is a better answer than a fan
    -- wider than the row it sits in.
    if opts.max_w and opts.max_w >= 1 and total > opts.max_w then
        local span = 1 + (n - 1) * DECK_STEP
        card_w, card_h = Group.slotWidth(height,
            math.max(1, math.floor(opts.max_w / span)))
        step  = math.max(shadow * 2, math.floor(card_w * DECK_STEP))
        total = card_w + (n - 1) * step
        while n > 1 and total > opts.max_w do
            n = n - 1
            total = card_w + (n - 1) * step
        end
        -- Below the height a deck is legible at, this is not a deck. nil sends
        -- the caller to the tile fallback, which has its own width guard.
        if card_h < DECK_MIN_H then return nil end
    end

    local group = OverlapGroup:new{
        dimen = Geom:new{ w = total, h = card_h },
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
            height           = card_h,
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

-- Group.tile(item, width, height, opts) -> the cover grid's own tile for this
-- group, or nil.
--
-- THE FALLBACK WHEN THERE IS NO DECK, on the maintainer's ruling: "render the
-- cover/card that we would have shown in folder view, on the right ... that
-- cover/card is what keeps everything aligned and looking good in other tabs
-- like series."
--
-- An OPDS subcatalogue is the case that needs it. Its members are on someone
-- else's server, so there is nothing to fan and nothing to count, and a
-- Project Gutenberg feed came out as three words in a 253px row. The slot on
-- the right is what every other group row has an object in; filling it with
-- the tile the cover grid would have drawn keeps the column of objects
-- unbroken, and costs no new design -- it is a widget that already exists and
-- already answers to the reader's folder-style setting.
--
-- WHICH TILE is the same choice bookshelf_shelf_row.lua makes, deliberately
-- read from there rather than invented here: a folder or a nav entry is a
-- FolderStack, everything else (series, author, genre, tag) is a SeriesStack.
-- An OPDS nav tile is forced to TEXT whatever the folder style says, for the
-- reason given at that call site -- a remote category has no artwork of its
-- own, so every image mode ends up borrowing a cover from whatever happened
-- to be cached inside it, which is usually the wrong picture and reads as a
-- bug rather than a choice.
--
-- opts.on_tap / on_hold are the ROW's handlers. Both tile widgets return true
-- from onTap unconditionally, so a tile with no handler would be a dead patch
-- of a row that is otherwise tappable everywhere.
-- The smallest slot a tile can be built in.
--
-- NOT a taste judgement -- a hard floor. FolderCard.build (which both tile
-- widgets end at) solves its label width as
-- `slot_w - SHADOW_OFFSET - 2 * Size.padding.large` and hands the result
-- straight to TextBoxWidget. Below that it goes NEGATIVE, and TextBoxWidget
-- raises "width must be strictly positive" from inside makeLine -- which is a
-- crash of the whole reader, not a bad-looking row.
--
-- Found by crashing a Paperwhite: a one-line preset pinned to a catalogue chip
-- gave a 69px row, so a 44px slot, against a requirement of about 92 --
-- `label_w_avail` came out at -6. The same arithmetic was reachable without
-- any preset at all, from a compact layout and a coverless folder.
--
-- Derived from FolderCard's own primitives rather than restated as a number,
-- so it cannot drift from the widget it is protecting. Four paddings, not the
-- two the card spends: two is the floor where the label has exactly no room,
-- and a card with no room for a single glyph is not worth the slot.
local function minTileWidth()
    local Size = require("ui/size")
    local FolderCard = require("lib/bookshelf_folder_card")
    return (FolderCard.SHADOW_OFFSET or 0) + 4 * Size.padding.large
end

-- Build a tile, or nil if it will not build.
--
-- The floor above is the size assumption I could FIND. These widgets were
-- written for grid tiles -- a slot as wide as a cover and as tall as a card --
-- and a list row hands them shapes they have never been given before, so there
-- may be others. A decorative tile is not worth taking the reader's library
-- down for, and the failure it guards against is precisely a crash rather than
-- a bad-looking row: an empty slot is what the row had before any of this.
--
-- Logged, not swallowed. A tile that stops building is a real regression and
-- has to be findable in crash.log rather than showing up as a slot that is
-- quietly always empty.
local function built(widget, spec)
    local ok, tile = pcall(widget.new, widget, spec)
    if ok and tile then return tile end
    require("logger").warn(
        "[bookshelf] list group tile failed to build at "
        .. tostring(spec.width) .. "x" .. tostring(spec.height) .. ": "
        .. tostring(tile))
    return nil
end

function Group.tile(item, width, height, opts)
    opts = opts or {}
    if type(item) ~= "table" then return nil end
    if not (width and height and width > 1 and height > 1) then return nil end
    -- Too small to hold a card: no tile, and no crash.
    --
    -- The WIDTH bound is the crash guard and applies always -- FolderCard.build
    -- runs on every FolderStack path, text-only included, and solves a label
    -- width that goes negative below it.
    --
    -- The HEIGHT bound is a judgement, and only about the tile that sits in a
    -- slot beside the text: a row that short does not look empty, so it does
    -- not need filling. A row-FILLING tile is the row itself and has to render
    -- at whatever height the reader's layout gives it -- refusing there would
    -- leave the row with nothing in it at all.
    if width < minTileWidth() then return nil end
    if not opts.fill_row and height < DECK_MIN_H then return nil end
    local StackDisplay = require("lib/bookshelf_stack_display")
    local is_nav = item.kind == "opds_nav"
    if is_nav or item.kind == "folder" then
        local FolderStack = require("lib/bookshelf_folder_stack")
        -- No first_book stand-in for a nav entry, unlike the cover grid's
        -- version of this call. That exists so an image mode can render the
        -- feed's own picture, and a nav tile is pinned to TEXT below --
        -- FolderStack asks `want_art = not isTextOnly(display_mode)` and never
        -- looks at it. Setting it anyway would be mutating a shared record to
        -- feed a branch that cannot run.
        -- The record the CARD is built from, which is the item unless there is
        -- a subtitle to put on it. A shallow copy, never a mutation: the item
        -- belongs to the page and a later reader of `author` would find the
        -- count sitting in it.
        local folder = item
        if opts.subtitle and opts.subtitle ~= "" then
            folder = {}
            for k, v in pairs(item) do folder[k] = v end
            -- The placeholder card draws `author` under the title, which is
            -- the only subtitle slot it has. A catalogue entry's own author is
            -- a group name some feeds set; a declared count is the more useful
            -- of the two when both exist, and most feeds set neither.
            folder.author = opts.subtitle
        end
        return built(FolderStack, {
            display_mode = is_nav and StackDisplay.TEXT
                                  or StackDisplay.resolve(opts.group_display),
            folder      = folder,
            width       = width,
            height      = height,
            on_tap      = opts.on_tap,
            on_hold     = opts.on_hold,
            -- The pressed / focused state, which is what the cover grid
            -- thickens a tile's border for. Passing it is the whole of
            -- "exactly the same behaviour as the cover view".
            is_selected = opts.selected or nil,
            -- A coverless nav tile resolves on a tap, so the folder tab and
            -- the repeated label are redundant over the placeholder.
            plain_if_placeholder = is_nav or nil,
        })
    end
    if not item.books then return nil end
    local SeriesStack = require("lib/bookshelf_series_stack")
    return built(SeriesStack, {
        display_mode = StackDisplay.resolve(opts.group_display),
        series  = item,
        width   = width,
        height  = height,
        on_tap  = opts.on_tap,
        on_hold = opts.on_hold,
        -- No badge: the row says "N books" in words on its own second line,
        -- and a count in two places on one row is one too many.
        show_count_badge = false,
    })
end

-- Group.fillsRow(item) -> true when this group's whole ROW is its tile.
--
-- "for opds folders, how about we just make the text cover fill the row? ...
-- losing the chevron and just making the full row like a button with a border
-- that gets thicker on tap, exactly the same behaviour as the cover view".
--
-- ONLY a remote subcatalog, and that is not an arbitrary line. Everything else
-- a group row shows -- member covers to fan, a count in words, the reader's
-- own line templates -- a catalogue entry has none of: no artwork of its own
-- (see deckBooks), no members to count unless the feed happens to declare a
-- number, and no fields for a book template to expand. Its name IS the row, so
-- the row may as well be the thing you press.
--
-- The tile it becomes is already a button. FolderStack's text-only branch
-- renders a SpineWidget placeholder with `flat_card` set -- "Text style reads
-- as a button, not a book" -- and drives its border off is_selected, which is
-- what the cover grid thickens when a tap lands. Handing that widget the whole
-- row is all "exactly the same behaviour as the cover view" takes.
function Group.fillsRow(item)
    return type(item) == "table" and item.kind == "opds_nav"
end

-- The slot a tile or a deck occupies, so the two agree and a row with either
-- one puts its object in the same place.
-- Group.slotWidth(height, max_w) -> the slot a card occupies, shadow included.
--
-- max_w caps it, and the card SHRINKS rather than distorting -- see
-- ListGeom.ART_MAX_SHARE. Returns the matching height as a second value, which
-- a capped caller needs: a card kept at the row's full height inside a capped
-- width is a sliver, not a book.
function Group.slotWidth(height, max_w)
    local ListGeom = require("lib/bookshelf_list_geom")
    local SpineWidget = require("lib/bookshelf_spine_widget")
    local shadow = SpineWidget.SHADOW_OFFSET or Screen:scaleBySize(4)
    local w, h = ListGeom.thumbSize(height - shadow, 0,
                                    max_w and (max_w - shadow) or nil)
    return w + shadow, h + shadow
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
