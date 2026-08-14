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
-- Layers drawn BEHIND the front cover, and how far each is offset. Two back
-- layers is enough to read as "several"; a third is lost at tile size, which
-- is the same trap the removed three-cover stack fell into
-- (bookshelf_series_stack.lua's header records it).
M.PILE_LAYERS = 2

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

-- How much room the pile needs on each axis: the front cover is inset from the
-- left by this and shortened by this, so the layers behind protrude down and
-- to the left of it. Zero in every mode but stack, so callers can apply it
-- unconditionally.
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
    local SpineWidget = require("lib/bookshelf_spine_widget")
    local step  = M.pileStep()
    local inset = step * M.PILE_LAYERS
    -- The REAL card's chrome, borrowed rather than reinvented: same rounded
    -- radius, same border weight and colour, same drop-shadow grey (which is
    -- mode-aware -- night mode picks a different one, and a hardcoded grey
    -- would have inverted). A pile built from an approximation of a book card
    -- sitting next to actual book cards is a mismatch the eye finds
    -- immediately, which is what the first version looked like.
    local radius = SpineWidget.CARD_RADIUS
    local stroke = math.max(1, Screen:scaleBySize(1))
    local shadow = SpineWidget.shadowGray()
    local edge   = Blitbuffer.COLOR_BLACK
    local page   = Blitbuffer.COLOR_WHITE
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
    for depth = M.PILE_LAYERS, 1, -1 do
        local lx = x + (depth * step)
        local ly = y + (depth * step)
        -- Shadow first, offset down-right from the card exactly as a real
        -- card's is, so the pile is lit from the same direction as everything
        -- around it.
        bb:paintRoundedRect(lx + SpineWidget.SHADOW_OFFSET,
                            ly + SpineWidget.SHADOW_OFFSET,
                            lw - SpineWidget.SHADOW_OFFSET,
                            lh - SpineWidget.SHADOW_OFFSET,
                            shadow, radius)
        -- Body, then border: a blank page-white card. No cover art on the
        -- layers behind -- they are the EDGES of books under the front one,
        -- and printing artwork on them would claim they are specific books
        -- when the group's members past the first are not even hydrated.
        local cw = lw - SpineWidget.SHADOW_OFFSET
        local ch = lh - SpineWidget.SHADOW_OFFSET
        bb:paintRoundedRect(lx, ly, cw, ch, page, radius)
        bb:paintBorder(lx, ly, cw, ch, stroke, edge, radius, true)
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
    -- The grid ADAPTS to how many covers there are, rather than always being
    -- 2x2 with holes in it. A 2x2 grid holding two covers showed two white
    -- quadrants on device, which reads as broken rather than as partial -- and
    -- partial is the normal state here, since only covers already in the
    -- scaled cache are used. Two covers split the slot in half, three give one
    -- a full-height column beside two stacked, four fill the quarters.
    --
    -- Odd pixels go to the left/top cell so the cells always sum to the full
    -- slot and no seam of background shows through.
    local hw = math.ceil(width / 2)
    local hh = math.ceil(height / 2)
    local n = math.min(4, #filepaths)
    local cells
    if n == 2 then
        cells = {
            { x = 0,  y = 0, w = hw,         h = height },
            { x = hw, y = 0, w = width - hw, h = height },
        }
    elseif n == 3 then
        cells = {
            { x = 0,  y = 0,  w = hw,         h = height },
            { x = hw, y = 0,  w = width - hw, h = hh },
            { x = hw, y = hh, w = width - hw, h = height - hh },
        }
    else
        cells = {
            { x = 0,  y = 0,  w = hw,         h = hh },
            { x = hw, y = 0,  w = width - hw, h = hh },
            { x = 0,  y = hh, w = hw,         h = height - hh },
            { x = hw, y = hh, w = width - hw, h = height - hh },
        }
    end
    local drawn = 0
    for i = 1, n do
        local cell = cells[i]
        local cw, ch = cell.w, cell.h
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
