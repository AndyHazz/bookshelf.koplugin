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
local Screen     = require("device").screen
local BookshelfSettings = require("lib/bookshelf_settings_store")
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

-- ─── The pile ────────────────────────────────────────────────────────────────
-- Layers drawn BEHIND the front cover, and how far each is offset. Two back
-- layers is enough to read as "several"; a third is lost at tile size, which
-- is the same trap the removed three-cover stack fell into
-- (bookshelf_series_stack.lua's header records it).
M.PILE_LAYERS = 2

-- Offset per layer. scaleBySize(3) rather than (1): at the PW5's 264 DPI a
-- scaled 1 is about 2px, which is under the width of the outline stroke and
-- the layers merge into a smudge.
function M.pileStep()
    return Screen:scaleBySize(3)
end

-- How much horizontal room the pile needs, i.e. how far the front cover has
-- to be inset so the layers behind it are visible. Zero in every mode but
-- stack, so callers can apply it unconditionally.
function M.pileInset(mode)
    if mode ~= M.STACK then return 0 end
    return M.pileStep() * M.PILE_LAYERS
end

-- SpinePile: the outlines behind the front cover.
--
-- Deliberately NOT made of book covers. The removed three-cover stack shared
-- one cover_bb between three SpineWidgets, which forced a defensive per-paint
-- safeCopy to dodge a use-after-free (the bb is ImageWidget-owned and freed
-- after paint). Outlines own no bitmap at all, so that whole class of bug
-- cannot recur here, and they cost two filled rects each instead of a scaled
-- blit.
local SpinePile = {}
SpinePile.__index = SpinePile

function SpinePile:getSize() return self.dimen end

function SpinePile:paintTo(bb, x, y)
    local step = M.pileStep()
    local edge = Blitbuffer.COLOR_BLACK
    local page = Blitbuffer.COLOR_WHITE
    -- Farthest layer first so nearer ones paint over it, and each is inset
    -- from the TOP as it recedes while staying bottom-aligned: books in a
    -- pile share a table, not a ceiling.
    for k = 0, M.PILE_LAYERS - 1 do
        local depth = M.PILE_LAYERS - k          -- 2 for the farthest, 1 for the nearest
        local lx = x + (k * step)
        local ly = y + (depth * step)
        local lh = self.height - (depth * step)
        if lh > 0 then
            -- Visible strip only: everything right of the front cover's left
            -- edge is about to be painted over anyway, so filling the whole
            -- layer would be wasted work on every paint of every tile.
            local lw = step + Screen:scaleBySize(1)
            bb:paintRectRGB32(lx, ly, lw, lh, page)
            -- Outline: left edge and top edge, so each layer reads as a
            -- separate object rather than one grey block.
            bb:paintRectRGB32(lx, ly, Screen:scaleBySize(1), lh, edge)
            bb:paintRectRGB32(lx, ly, lw, Screen:scaleBySize(1), edge)
        end
    end
end

-- pileWidget(width, height) -> a widget for the layers behind the cover, or
-- nil when there is no room for one.
function M.pileWidget(width, height)
    local inset = M.pileInset(M.STACK)
    if width <= inset or height <= inset then return nil end
    local w = setmetatable({
        width  = width,
        height = height,
        dimen  = Geom:new{ w = width, h = height },
    }, SpinePile)
    return w
end

-- ─── The collage ─────────────────────────────────────────────────────────────
-- Member covers for a 2x2 grid, from the ALREADY-SCALED cover cache only.
--
-- The honest limitation, and the reason this is not a full hydration: a group
-- record hydrates books[1] and nothing else -- members 2..N are bare
-- { filepath } stubs, and the repository comment says why ("only one cover is
-- visible per group on the shelf"). Turning four stubs into four covers means
-- four BIM decodes PER TILE PER PAGE, which is the cost the one-cover rule was
-- written to avoid and which has already caused one round of shelf-slowness
-- reports.
--
-- So this takes only what is free: covers the scaled-cover cache already
-- holds, because they were rendered somewhere else this session. A collage
-- therefore fills in as a library is browsed rather than being complete on
-- first sight, and a group whose members have never been rendered shows just
-- its front cover. Making it complete on first sight needs a background
-- hydration pass (the OPDS cover chain is the shape for it), not a change
-- here.
function M.collageCovers(books, limit)
    limit = limit or 4
    local out = {}
    if type(books) ~= "table" then return out end
    local ok, Cache = pcall(require, "lib/bookshelf_scaled_cover_cache")
    if not ok or not Cache then return out end
    for _i, b in ipairs(books) do
        if #out >= limit then break end
        local fp = type(b) == "table" and b.filepath or nil
        if type(fp) == "string" and fp ~= "" then
            local ok_has, has = pcall(function() return Cache:has(fp) end)
            if ok_has and has then out[#out + 1] = fp end
        end
    end
    return out
end

-- collageBB(filepaths, width, height) -> a single owned blitbuffer with the
-- covers tiled 2x2, or nil.
--
-- Composed ONCE, at widget construction, into one buffer the widget then owns
-- and frees (handed to SpineWidget with cover_bb_disposable = true). Not
-- composed per paint: four scale-and-blits on every repaint of every tile is
-- exactly the per-paint bitmap work that got the previous multi-cover stack
-- removed.
--
-- The cache's buffers are borrowed, never written to and never freed here --
-- they belong to ScaledCoverCache and are shared with whatever else is
-- rendering those books. Each scaled temporary IS freed, immediately after it
-- is blitted, so a page of collages does not accumulate four orphaned buffers
-- per tile.
--
-- Returns nil for fewer than two covers: a "collage" of one is just that
-- cover, and the caller renders it the ordinary way rather than drawing a
-- grid with three holes in it.
function M.collageBB(filepaths, width, height)
    if type(filepaths) ~= "table" or #filepaths < 2 then return nil end
    if not (width and height and width > 1 and height > 1) then return nil end
    local ok, Cache = pcall(require, "lib/bookshelf_scaled_cover_cache")
    if not ok or not Cache then return nil end
    local ok_new, out = pcall(function()
        return Blitbuffer.new(width, height, Screen.bb and Screen.bb:getType() or nil)
    end)
    if not ok_new or not out then return nil end
    pcall(function() out:fill(Blitbuffer.COLOR_WHITE) end)
    -- Halves, with the odd pixel given to the left/top cell so the grid
    -- always covers the full slot rather than leaving a seam.
    local qw = math.ceil(width / 2)
    local qh = math.ceil(height / 2)
    local cells = {
        { x = 0,  y = 0  },
        { x = qw, y = 0  },
        { x = 0,  y = qh },
        { x = qw, y = qh },
    }
    local drawn = 0
    for i = 1, math.min(4, #filepaths) do
        local cell = cells[i]
        local cw = (cell.x == 0) and qw or (width - qw)
        local ch = (cell.y == 0) and qh or (height - qh)
        local ok_cell = pcall(function()
            local src = Cache:get(filepaths[i])
            if not src then return end
            local scaled = src:scale(cw, ch)
            if not scaled then return end
            out:blitFrom(scaled, cell.x, cell.y, 0, 0, cw, ch)
            -- Freed straight after the blit: the pixels are already copied,
            -- and this is the only reference to the temporary.
            if scaled.free then scaled:free() end
            drawn = drawn + 1
        end)
        if not ok_cell then break end
    end
    if drawn < 2 then
        if out.free then pcall(function() out:free() end) end
        return nil
    end
    return out
end

return M
