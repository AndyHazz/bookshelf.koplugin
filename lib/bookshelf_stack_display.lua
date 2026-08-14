-- lib/bookshelf_stack_display.lua
-- How a GROUP tile draws itself: filesystem folders and every kind of
-- metadata stack (series, author, genre, collection, language, format,
-- rating). One setting per kind, so a library can say "folders look like
-- folders, series look like a pile, authors are just the cover".
--
-- Two widgets render groups -- bookshelf_folder_stack (folders, OPDS nav
-- tiles) and bookshelf_series_stack (everything else) -- and they had
-- identical image ladders and identical cardboard overlays. Rather than
-- teach both the same five modes twice, both ask this module what to draw
-- and get back the same answers.
--
-- WHAT A MODE ACTUALLY CHANGES is only the "this is a group, not a book"
-- affordance. The cover underneath is chosen the same way in every mode
-- (custom image, else the group's first book, else a placeholder card);
-- the mode decides what is drawn OVER or AROUND it:
--
--   divider  the cardboard tab + name band. The shipped design, and the
--            default everywhere, so an untouched library is unchanged.
--   stack    the cover inset to the right, with spine outlines peeking out
--            behind it on the left. The pile IS the group cue, so no
--            cardboard.
--   collage  up to four member covers in a 2x2 grid.
--   text     no artwork at all: the placeholder card, group name as its
--            title. Chosen when the artwork is noise (a genre's "first
--            book cover" says nothing about the genre).
--   none     just the cover, with nothing over it. For kinds where the
--            first book's cover is a good enough emblem and the chrome is
--            clutter.
--
-- NO ROTATION. The "book stack" was described as a slightly rotated cover.
-- KOReader's blitbuffer rotates in 90-degree multiples only
-- (frontend/ui/widget/imagewidget.lua), and the cover-opening effect that
-- looks like a tilt is not one -- it is a banded trapezoid rescale blitted
-- straight to the framebuffer (BookshelfWidget.flexCoverOpen). An arbitrary
-- angle would have to be synthesised the same way, band by band, and at
-- tile size on e-ink that stair-steps. The pile here is built from offset
-- outlines instead, which needs no rotation and no per-paint bitmap work.
local Blitbuffer = require("ffi/blitbuffer")
local Geom       = require("ui/geometry")
local Widget     = require("ui/widget/widget")
local Screen     = require("device").screen
local BookshelfSettings = require("lib/bookshelf_settings_store")
local logger     = (function()
    local ok, l = pcall(require, "logger")
    if ok and l then return l end
    return { dbg = function() end }
end)()
local _          = require("lib/bookshelf_i18n").gettext

local M = {}

-- Mode values. nil is "divider", the shipped design: an unset library keeps
-- exactly the tiles it had, and no migration is needed for any existing
-- install. Stored as raw strings, never option indices, so reordering the
-- list below cannot silently change what a library looks like.
M.DIVIDER = "divider"
M.STACK   = "stack"
M.COLLAGE = "collage"
M.TEXT    = "text"
M.NONE    = "none"

M.OPTIONS = {
    { value = nil,       label_func = function() return _("Divider card") end },
    { value = M.STACK,   label_func = function() return _("Book stack") end },
    { value = M.COLLAGE, label_func = function() return _("Collage") end },
    { value = M.TEXT,    label_func = function() return _("Text") end },
    { value = M.NONE,    label_func = function() return _("None") end },
}

-- Every group kind that reaches a tile, with the settings key it reads and
-- the menu row that sets it.
--
-- "folder" covers filesystem folders AND OPDS nav tiles: both render through
-- FolderStack, and a catalog's subcatalogs are folders in every sense that
-- matters to this setting.
--
-- format and rating have no dispatch branch of their own in shelf_row (they
-- fall into the `item.books` catch-all alongside series) but they ARE
-- distinct kinds on the record, so they get their own row rather than
-- silently following whatever series is set to.
M.KINDS = {
    { kind = "folder",   key = "folder_display",   label_func = function() return _("Folders") end },
    { kind = "series",   key = "series_display",   label_func = function() return _("Series") end },
    { kind = "author",   key = "author_display",   label_func = function() return _("Authors") end },
    { kind = "genre",    key = "genre_display",    label_func = function() return _("Genres") end },
    { kind = "tag",      key = "tag_display",      label_func = function() return _("Collections") end },
    { kind = "language", key = "language_display", label_func = function() return _("Languages") end },
    { kind = "format",   key = "format_display",   label_func = function() return _("Formats") end },
    { kind = "rating",   key = "rating_display",   label_func = function() return _("Ratings") end },
}

local KEY_BY_KIND = {}
for _i, k in ipairs(M.KINDS) do KEY_BY_KIND[k.kind] = k.key end

local function validated(value)
    for _i, opt in ipairs(M.OPTIONS) do
        if opt.value == value then return value end
    end
    return nil
end

-- settingKey(kind) -> the settings key for a group kind, or nil if the kind
-- has no row (which means "use the default").
function M.settingKey(kind)
    return KEY_BY_KIND[kind]
end

-- modeFor(kind) -> one of the M.* mode constants, never nil.
--
-- An unknown kind, or a stored value this build does not offer, resolves to
-- DIVIDER rather than to something surprising: a tile that renders as it
-- always did is the safe answer when we do not understand the question.
function M.modeFor(kind)
    local key = KEY_BY_KIND[kind]
    if not key then return M.DIVIDER end
    local v = validated(BookshelfSettings.read(key))
    return v or M.DIVIDER
end

-- labelFor(value) -> the option label for a stored value, defaulting to the
-- first option's label. Used by the settings menu for its "Kind: Value" rows.
function M.labelFor(value)
    for _i, opt in ipairs(M.OPTIONS) do
        if opt.value == value then return opt.label_func() end
    end
    return M.OPTIONS[1].label_func()
end

-- Does this mode draw the cardboard tab + name band? Only divider does. The
-- other modes each carry their own group cue (a pile, a grid, the name as the
-- card's own title) or deliberately carry none.
function M.showsCardboard(mode)
    return mode == M.DIVIDER
end

-- Does this mode suppress artwork entirely and render the name as a card?
function M.isTextOnly(mode)
    return mode == M.TEXT
end

-- Does this mode need the group's name printed BELOW the tile, the way a
-- book's title is?
--
-- Divider carries the name in its own band and Text makes the name the card's
-- title, so both already say what the group is. Stack, collage and none show
-- artwork with nothing naming it -- and on an author or genre tile the front
-- book's cover is not a name. Without this, choosing one of those three
-- silently made the group anonymous.
--
-- Still subject to the reader's own "Show text below covers" setting: this
-- says the name is NEEDED, not that it is shown regardless of preference.
function M.needsExternalLabel(mode)
    return mode == M.STACK or mode == M.COLLAGE or mode == M.NONE
end

-- externalLabel(kind, name) -> the name to print below the tile, or nil.
-- One call for shelf_row's seven group branches, so the rule lives here rather
-- than being re-derived at each of them.
function M.externalLabel(kind, name)
    if type(name) ~= "string" or name == "" then return nil end
    if not M.needsExternalLabel(M.modeFor(kind)) then return nil end
    return name
end

-- ─── The pile ────────────────────────────────────────────────────────────────
-- How many books the pile can depict, front cover included. Beyond this the
-- layers stop being distinguishable at tile size, which is the trap the
-- removed three-cover stack fell into (bookshelf_series_stack.lua's header
-- records it) -- so a 90-book series and a 4-book one look the same, and the
-- count badge is what tells them apart.
M.MAX_PILE_BOOKS = 4

-- pileLayers(book_count) -> layers to draw BEHIND the front cover.
--
-- The pile depicts the stack rather than decorating it: two books get one
-- layer behind, three get two, four or more get three. A stack of ONE gets
-- none -- it is not a pile, and drawing one would state something false about
-- the shelf.
--
-- An unknown count (nil) takes the maximum. Folder tiles only compute their
-- recursive book count when the count badge needs it, so nil here means "not
-- asked", not "empty", and a folder deep enough to be worth a stack tile is
-- far more likely to hold several books than one.
function M.pileLayers(book_count)
    if type(book_count) ~= "number" then return M.MAX_PILE_BOOKS - 1 end
    local n = math.floor(book_count)
    if n < 1 then return 0 end
    if n > M.MAX_PILE_BOOKS then n = M.MAX_PILE_BOOKS end
    return n - 1
end

-- Offset per layer. The first attempt used scaleBySize(3) and offset the
-- layers only horizontally, bottom-aligned with the cover: on device that read
-- as a double border down the left edge of the cover, not as a pile at all,
-- because a full-height strip flush with the cover's own frame is
-- indistinguishable from part of the frame. Bigger step, and offset on BOTH
-- axes so each layer protrudes at the left AND the bottom -- the staircase of
-- corners is what says "separate objects".
function M.pileStep()
    return Screen:scaleBySize(5)
end

-- How much room the pile needs on each axis: the front cover is shortened by
-- this and the layers protrude past its right and bottom edges. Zero in every
-- mode but stack, and zero for a single-book stack, so callers can apply it
-- unconditionally.
function M.pileInset(mode, book_count)
    if mode ~= M.STACK then return 0 end
    return M.pileStep() * M.pileLayers(book_count)
end

-- Fading per layer, nearest first, deepest last: each book lower in the pile
-- casts a fainter shadow and carries a fainter border, so the pile recedes
-- instead of being three identical outlines stacked up.
--
-- COLOURS COME FROM THE RESOLVERS, NOT FROM ARITHMETIC ON gray(). This module
-- got night mode wrong twice by reasoning about the framebuffer inversion
-- instead of asking. The truth is that night mode is NOT a plain inversion of
-- intent: the card border is #000000 in day and #FAFAFA in night
-- (bookshelf_cover_progress's DEFAULT_BORDER / NIGHT_DEFAULT_BORDER), i.e.
-- painted opposite so that it DISPLAYS dark in both -- a dark border on light,
-- and a dark border on dark. Deriving the pile's border from gray(1.0) painted
-- it black in both modes, which night mode then inverted to white, and the
-- pile glowed.
--
-- So each layer's border is an interpolation between two colours the codebase
-- already resolves per mode: the real card border, and the layer's own body.
-- Fade 1.0 is the full border colour, 0 is invisible against the body. Both
-- endpoints are mode-correct, so the interpolation is too, and no inversion
-- reasoning is needed anywhere here.
local FADE_BY_DEPTH        = { 0.58, 0.34, 0.20 }   -- shadow, depth 1..3
local BORDER_FADE_BY_DEPTH = { 0.80, 0.60, 0.44 }   -- border, depth 1..3

-- The shadow keeps its own bases, mirrored from spine_widget's
-- SHADOW_GRAY_DAY / SHADOW_GRAY_NIGHT, because a shadow is deliberately
-- hard-coded to paint DARK ON SCREEN in both modes and those two numbers are
-- how that is expressed.
local SHADOW_BASE_DAY   = 0.5
local SHADOW_BASE_NIGHT = 0.15

local function _nightMode()
    local ok, night = pcall(function()
        return G_reader_settings and G_reader_settings:isTrue("night_mode")
    end)
    return ok and night or false
end

local function fadeAt(depth)
    return FADE_BY_DEPTH[depth] or FADE_BY_DEPTH[#FADE_BY_DEPTH]
end

local function borderFadeAt(depth)
    return BORDER_FADE_BY_DEPTH[depth] or BORDER_FADE_BY_DEPTH[#BORDER_FADE_BY_DEPTH]
end

-- The body colour of a blank layer: the placeholder card's own face, which is
-- white in day and a light grey in night (so that, inverted, it lands as a
-- dark card distinct from the black page rather than vanishing into it).
local function pileBody()
    local ok, SpineWidget = pcall(require, "lib/bookshelf_spine_widget")
    if ok and SpineWidget and SpineWidget.fallbackBgs then
        local _outer, inner = SpineWidget.fallbackBgs()
        if inner then return inner end
    end
    return Blitbuffer.COLOR_WHITE
end

-- The card border colour the rest of the shelf uses, honouring the user's
-- Border color setting and the day/night split.
local function cardBorder()
    local ok, CoverProgress = pcall(require, "lib/bookshelf_cover_progress")
    if ok and CoverProgress and CoverProgress.resolvedColors then
        local ok_c, c = pcall(CoverProgress.resolvedColors)
        if ok_c and c and c.border then return c.border end
    end
    return Blitbuffer.COLOR_BLACK
end

-- Interpolate two colours in PAINTED space: t = 1 gives `a`, t = 0 gives `b`.
-- Painted space is the only space both endpoints are expressed in; converting
-- to "displayed" would mean re-deriving the inversion, which is the thing this
-- module keeps getting wrong.
local function blend8(a, b, t)
    local ok, out = pcall(function()
        local av = a:getColor8().a
        local bv = b:getColor8().a
        return Blitbuffer.Color8(math.floor(bv + (av - bv) * t + 0.5))
    end)
    if ok and out then return out end
    return a
end

local function pileShadow(depth)
    local base = _nightMode() and SHADOW_BASE_NIGHT or SHADOW_BASE_DAY
    return Blitbuffer.gray(base * fadeAt(depth))
end

local function pileBorder(depth, body)
    return blend8(cardBorder(), body or pileBody(), borderFadeAt(depth))
end

-- SpinePile: the outlines behind the front cover.
--
-- Deliberately NOT made of book covers. The removed three-cover stack shared
-- one cover_bb between three SpineWidgets, which forced a defensive per-paint
-- safeCopy to dodge a use-after-free (the bb is ImageWidget-owned and freed
-- after paint). Outlines own no bitmap at all, so that whole class of bug
-- cannot recur here, and they cost two filled rects each instead of a scaled
-- blit.
-- A real Widget, not a bare table with a metatable. The first version was the
-- latter: it had paintTo and getSize, which is everything PAINTING needs, and
-- KOReader's containers also walk their children to propagate EVENTS. The
-- first tap that reached a stack-mode tile hit widgetcontainer's
-- `child:handleEvent(...)` on something that had no such method and took the
-- whole app down. Widget:extend supplies the event surface; ShadowRect in
-- spine_widget is the same pattern for the same reason.
local SpinePile = Widget:extend{
    width  = nil,
    height = nil,
    -- Layers behind the front cover, from pileLayers(book_count). Per widget,
    -- not a constant: the pile depicts how many books the stack holds.
    layers = 1,
}

function SpinePile:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
end

function SpinePile:paintTo(bb, x, y)
    local SpineWidget = require("lib/bookshelf_spine_widget")
    local step  = M.pileStep()
    local inset = step * self.layers
    -- The REAL card's chrome, borrowed rather than reinvented: same rounded
    -- radius, same border weight and colour, same drop-shadow grey (which is
    -- mode-aware -- night mode picks a different one, and a hardcoded grey
    -- would have inverted). A pile built from an approximation of a book card
    -- sitting next to actual book cards is a mismatch the eye finds
    -- immediately, which is what the first version looked like.
    local radius = SpineWidget.CARD_RADIUS
    local stroke = math.max(1, Screen:scaleBySize(1))
    local page   = pileBody()
    -- DOWN AND RIGHT, following the drop shadow. Every card on the shelf casts
    -- its shadow onto the right+bottom L-strip (SpineWidget's own shadow, which
    -- FolderCard reuses as the folder's), which places the light at the top
    -- left. A pile receding to the bottom-LEFT -- the first attempt -- lit
    -- itself from the opposite direction to everything around it, and read as
    -- wrong even when the geometry was doing exactly what it was told.
    --
    -- Receding this way also puts the front cover's own shadow directly against
    -- the layer beneath it, so the front book appears to cast onto the pile.
    local lw = self.width  - inset
    local lh = self.height - inset
    if lw <= 0 or lh <= 0 then return end
    -- Farthest first so nearer layers paint over it. Each layer is a whole
    -- card -- shadow, body, border -- exactly as a book renders one, drawn at
    -- full size and then largely covered by the layer in front of it and by
    -- the front cover. Painting only the protruding strips would be cheaper,
    -- but a strip cannot carry a rounded corner or a shadow that falls the
    -- right way, and those are the two things that make it read as a book
    -- rather than as a line.
    for depth = self.layers, 1, -1 do
        local lx = x + (depth * step)
        local ly = y + (depth * step)
        -- Shadow first, offset down-right from the card exactly as a real
        -- card's is, so the pile is lit from the same direction as everything
        -- around it.
        local sx, sy = lx + SpineWidget.SHADOW_OFFSET, ly + SpineWidget.SHADOW_OFFSET
        local sw, sh = lw - SpineWidget.SHADOW_OFFSET, lh - SpineWidget.SHADOW_OFFSET
        bb:paintRoundedRect(sx, sy, sw, sh, pileShadow(depth), radius)
        -- NO outline on the outermost shadow. It was added to terminate the
        -- pile's far edge, and it did -- but it reads as one more card edge,
        -- so an x4 stack showed FIVE: the front cover, three layer borders,
        -- and this. The pile depicts the stack, so its edge count has to be
        -- exactly the book count, and an edge that cannot be counted as a
        -- book is one the pile cannot carry.
        -- Body, then border: a blank page-white card. No cover art on the
        -- layers behind -- they are the EDGES of books under the front one,
        -- and printing artwork on them would claim they are specific books
        -- when the group's members past the first are not even hydrated.
        local cw = lw - SpineWidget.SHADOW_OFFSET
        local ch = lh - SpineWidget.SHADOW_OFFSET
        bb:paintRoundedRect(lx, ly, cw, ch, page, radius)
        bb:paintBorder(lx, ly, cw, ch, stroke, pileBorder(depth, page), radius, true)
    end
end

-- pileWidget(width, height, book_count) -> the layers behind the cover, or nil
-- when there are none to draw or no room to draw them.
function M.pileWidget(width, height, book_count)
    local layers = M.pileLayers(book_count)
    if layers < 1 then return nil end
    local inset = M.pileStep() * layers
    if width <= inset or height <= inset then return nil end
    return SpinePile:new{ width = width, height = height, layers = layers }
end

-- ─── The collage ─────────────────────────────────────────────────────────────
-- Member covers for a 2x2 grid.
--
-- This DOES pay to fetch. A group hydrates books[1] and nothing else -- members
-- 2..N are bare { filepath } stubs -- so an earlier version used only covers the
-- scaled cache already held, and laid out 2 or 3 of them across the slot. Both
-- halves of that were wrong on device: a two-cover collage stretched each cover
-- across half a tile, and the grid changing shape with the cache made the same
-- group look different from one visit to the next. A collage is a 2x2 grid; if
-- it cannot be filled, the empty cells are filled, not the layout redrawn.
--
-- The cost is real and deliberate: up to three extra BIM cover reads per
-- collage tile. It is bounded to the tiles actually on screen and to kinds the
-- user has explicitly set to Collage, and every fetched buffer is freed the
-- instant it has been blitted -- see the OOM note in the repository
-- (getSeriesGroups): 2000 live cover buffers at ~60 KB is 120 MB and a killed
-- KOReader. NEVER hold more than one at a time here.

-- collageCovers(books, limit) -> the first `limit` member filepaths.
-- Membership only; whether a cover can be had for each is collageBB's problem,
-- because answering it is the expensive part.
function M.collageCovers(books, limit)
    limit = limit or 4
    local out = {}
    if type(books) ~= "table" then return out end
    for _i, b in ipairs(books) do
        if #out >= limit then break end
        local fp = type(b) == "table" and b.filepath or nil
        if type(fp) == "string" and fp ~= "" then out[#out + 1] = fp end
    end
    return out
end

-- Average grey of a buffer, sampled on a coarse grid rather than read in full:
-- a cover is tens of thousands of pixels and the answer only has to be close
-- enough to sit beside the real covers without jarring.
local SAMPLE_STEPS = 8
local function averageGrey(bb)
    local ok, avg = pcall(function()
        local w, h = bb:getWidth(), bb:getHeight()
        if not (w and h and w > 0 and h > 0) then return nil end
        local total, n = 0, 0
        for sy = 0, SAMPLE_STEPS - 1 do
            for sx = 0, SAMPLE_STEPS - 1 do
                local px = math.floor((sx + 0.5) * w / SAMPLE_STEPS)
                local py = math.floor((sy + 0.5) * h / SAMPLE_STEPS)
                local c = bb:getPixel(px, py)
                if c then
                    local g = c.getColor8 and c:getColor8() or nil
                    if g and g.a then total = total + g.a; n = n + 1 end
                end
            end
        end
        if n == 0 then return nil end
        return total / n
    end)
    if not ok then return nil end
    return avg
end

-- collagePlacement(member_count) -> which QUARTERS to use, in member order.
--
-- Two covers go diagonally (top-left, bottom-right) rather than side by side
-- along the top, which left the bottom half as filler and read as a half-empty
-- grid. Everything else fills quarters in reading order.
--
-- The distinction this returns is worth naming, because getting it wrong is
-- what broke the diagonal: the RESULT is a list of quarter indices in
-- placement order, so result[2] = 4 means "the second cover goes in quarter
-- 4". Anything tracking what has been painted must key on the QUARTER, not on
-- the position in this list.
local ORDER_BY_COUNT = {
    [1] = { 1 },
    [2] = { 1, 4 },
    [3] = { 1, 2, 3 },
    [4] = { 1, 2, 3, 4 },
}
function M.collagePlacement(member_count)
    if type(member_count) ~= "number" or member_count < 1 then
        return ORDER_BY_COUNT[1]
    end
    return ORDER_BY_COUNT[math.min(4, math.floor(member_count))] or ORDER_BY_COUNT[4]
end

-- collageBB(filepaths, width, height) -> one owned blitbuffer, or nil.
--
-- Composed ONCE at widget construction into a buffer the widget then owns and
-- frees (SpineWidget with cover_bb_disposable = true), never per paint.
--
-- Cells with no cover are filled with the average tone of the covers that DID
-- resolve, so a partial collage reads as one object rather than as a grid with
-- holes; with nothing to average from, it falls back to the placeholder card's
-- own outer grey rather than a third invented tone.
function M.collageBB(filepaths, width, height)
    if type(filepaths) ~= "table" or #filepaths < 2 then return nil end
    if not (width and height and width > 1 and height > 1) then return nil end
    local Blitbuffer_ = Blitbuffer
    local ok_new, out = pcall(function()
        return Blitbuffer_.new(width, height, Screen.bb and Screen.bb:getType() or nil)
    end)
    if not ok_new or not out then return nil end
    -- Blitbuffer.new does NOT zero its allocation: anything not painted below
    -- is uninitialised memory, which showed as solid black cells. Every path
    -- out of here must have painted every pixel, and the cheapest guarantee of
    -- that is to start from a known colour.
    pcall(function() out:fill(Blitbuffer.COLOR_WHITE) end)

    local hw = math.ceil(width / 2)
    local hh = math.ceil(height / 2)
    -- Always the four quarters. Odd pixels go to the left/top cells so the
    -- cells sum to the whole slot and no seam shows.
    local quarters = {
        { x = 0,  y = 0,  w = hw,         h = hh },
        { x = hw, y = 0,  w = width - hw, h = hh },
        { x = 0,  y = hh, w = hw,         h = height - hh },
        { x = hw, y = hh, w = width - hw, h = height - hh },
    }
    -- WHICH quarters get used, by how many members there are. Two covers go
    -- diagonally -- top-left and bottom-right -- rather than side by side
    -- along the top, which left the whole bottom half as filler and read as a
    -- half-empty grid rather than a composition.
    --
    -- Keyed on the member count, known before any cover is fetched, not on how
    -- many covers actually resolve: deciding placement afterwards would mean
    -- holding every fetched cover in memory at once to re-place them, and full
    -- BIM cover buffers are exactly what must not accumulate here.
    local order = M.collagePlacement(#filepaths)
    local cells = {}
    for i, q in ipairs(order) do cells[i] = quarters[q] end

    local ok_cache, Cache = pcall(require, "lib/bookshelf_scaled_cover_cache")
    local ok_repo,  Repo  = pcall(require, "lib/bookshelf_book_repository")
    local drawn, grey_total, grey_n = 0, 0, 0
    local filled = {}
    local sources = {}
    for i = 1, 4 do
        local fp = filepaths[i]
        local cell = cells[i]
        if fp then
            pcall(function()
                -- Cache first: free, and already scaled.
                local src, owned
                if ok_cache and Cache then src = Cache:get(fp) end
                local from = src and "cache" or nil
                -- Then the FULL record, not just the embedded cover. A book's
                -- cover is not always in BIM: a custom cover applied through
                -- the cover picker, or one fetched by Hardcover, is a file on
                -- disk that buildBookMeta attaches as cover_image_path, and
                -- BIM knows nothing about either. Asking getCoverBB alone made
                -- such a book look coverless while the shelf was visibly
                -- rendering its cover two tiles away.
                --
                -- buildBookMeta is the one place that resolves all of this in
                -- the right precedence, so it is asked rather than the ladder
                -- being reimplemented here -- reimplementing it is what caused
                -- the divergence.
                -- want_cover = false: we only need to know whether this book
                -- has a cover FILE (a custom cover, or one Hardcover fetched),
                -- and asking for the cover as well decodes a BIM buffer we
                -- then have to own. The first version did exactly that and
                -- leaked one per member whenever the file branch won, which on
                -- a shelf of collages rebuilding repeatedly is tens of MB --
                -- the repository's OOM note is about precisely this buffer.
                if not src and ok_repo and Repo and Repo.buildBookMeta then
                    local ok_rec, rec = pcall(Repo.buildBookMeta, fp,
                                              { want_cover = false })
                    if ok_rec and type(rec) == "table"
                            and type(rec.cover_image_path) == "string"
                            and rec.cover_image_path ~= "" then
                        local ok_img, ImageSource = pcall(require, "lib/bookshelf_image_source")
                        if ok_img and ImageSource and ImageSource.loadImage then
                            src = ImageSource.loadImage(rec.cover_image_path, cell.w, cell.h)
                            -- ImageSource's cache owns this one; freeing it
                            -- would crash the next paint that hits the same key.
                            owned = false
                            from = src and "file" or nil
                        end
                    end
                end
                -- Only now the embedded cover, which DOES allocate a buffer we
                -- own -- and which is freed the moment it has been blitted.
                if not src and ok_repo and Repo and Repo.getCoverBB then
                    src = Repo.getCoverBB(fp)
                    owned = src ~= nil
                    from = src and "bim" or "none"
                end
                sources[i] = from or "none"
                if not src then return end
                local scaled = src:scale(cell.w, cell.h)
                if scaled then
                    out:blitFrom(scaled, cell.x, cell.y, 0, 0, cell.w, cell.h)
                    local g = averageGrey(scaled)
                    if g then grey_total = grey_total + g; grey_n = grey_n + 1 end
                    if scaled.free then scaled:free() end
                    drawn = drawn + 1
                    filled[order[i]] = true
                end
                -- Freed the moment it has been used, never accumulated: the
                -- repository's OOM note is about exactly this buffer.
                if owned and src.free then src:free() end
            end)
        end
    end

    logger.dbg(string.format(
        "[bookshelf perf] collage: members=%d drawn=%d sources=%s|%s|%s|%s",
        #filepaths, drawn, tostring(sources[1]), tostring(sources[2]),
        tostring(sources[3]), tostring(sources[4])))
    if drawn < 2 then
        if out.free then pcall(function() out:free() end) end
        return nil
    end
    -- Fill the gaps.
    local fill
    if grey_n > 0 then
        fill = Blitbuffer.gray((grey_total / grey_n) / 255)
    else
        local ok_sw, SpineWidget = pcall(require, "lib/bookshelf_spine_widget")
        if ok_sw and SpineWidget and SpineWidget.fallbackBgs then
            local outer = SpineWidget.fallbackBgs()
            fill = outer
        end
    end
    -- Divider cross between the cells, in the same colour the card's own
    -- border uses (so it is mode-correct, and follows the user's Border color
    -- setting). Without it two dark covers meeting at a quarter line read as
    -- one smeared image; the cross is what makes a collage read as four
    -- separate books.
    --
    -- Drawn AFTER the cells and the gap fill so nothing paints over it, and
    -- only the internal cross -- the outer frame is the card's own border,
    -- added when this buffer is rendered as a cover.
    local function paintDividers()
        local stroke = math.max(1, Screen:scaleBySize(1))
        local edge = cardBorder()
        pcall(function()
            out:paintRect(hw - math.floor(stroke / 2), 0, stroke, height, edge)
            out:paintRect(0, hh - math.floor(stroke / 2), width, stroke, edge)
        end)
    end

    if fill then
        -- Over QUARTERS, not over `cells`. `filled` is keyed by quarter (it is
        -- set as filled[order[i]]), while `cells` is placement-ordered and only
        -- as long as the member count -- so walking `cells` here compared a
        -- quarter index against a placement index and indexed a list that was
        -- often shorter than 4. On a two-cover diagonal that filled the
        -- bottom-right quarter ON TOP of the cover already drawn there, and
        -- left the other two quarters untouched.
        for q = 1, 4 do
            if not filled[q] then
                local cell = quarters[q]
                pcall(function()
                    out:paintRect(cell.x, cell.y, cell.w, cell.h, fill)
                end)
            end
        end
    end
    paintDividers()
    return out
end

return M
