-- lib/bookshelf_stack_display.lua
-- How a GROUP tile draws itself: filesystem folders and every kind of
-- metadata stack (series, author, genre, collection, language, format,
-- rating).
--
-- SET PER CHIP, with one library-wide default. This started as one setting
-- per KIND ("folders look like folders, series look like a pile"), which read
-- well in the settings menu and answered the wrong question in practice:
--
--   * A chip IS a kind, so the per-kind rows were a second, parallel way of
--     saying what a chip shows - and the two could not be reconciled when a
--     library had two chips on the same kind wanting different tiles.
--   * An OPDS catalog's subcatalogs render as folder tiles, so they were
--     bound to the same row as the filesystem's folders. Wanting a catalog to
--     look different from your Documents folder was simply not expressible,
--     which is the bug that prompted this.
--   * The style is a property of the shelf you are looking at, so the place
--     to change it is the chip you are looking at - not a submenu three
--     levels into Settings that never mentions chips.
--
-- So: `group_display_default` is the library-wide style, and any chip may
-- override it (tab.group_display, persisted with the rest of the chip by
-- TabModel.save). Views that are not a chip - search results, which mix
-- folders, authors, series and genres in one list - take the default, because
-- there is no single chip whose opinion would apply.
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
--   ribbon   a band across the lower third of the cover, name reversed out
--            of it, running slightly PAST both edges so it reads as a strap
--            around a bundle of books rather than a caption printed on one.
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

-- Mode values, stored as raw strings and never as option indices, so
-- reordering the list below cannot silently change what a library looks like.
--
-- DIVIDER carries an explicit value rather than being nil-as-default. nil now
-- means "not set" -- which for a CHIP means "follow the library default" -- so
-- a library whose default is Ribbon must still be able to say "this one chip
-- is a divider card". With divider stored as nil those two were the same
-- value and the chip could not disagree with the default.
M.DIVIDER = "divider"
M.RIBBON  = "ribbon"
M.STACK   = "stack"
M.COLLAGE = "collage"
M.TEXT    = "text"
M.NONE    = "none"

M.OPTIONS = {
    { value = M.DIVIDER, label_func = function() return _("Divider card") end },
    { value = M.RIBBON,  label_func = function() return _("Ribbon") end },
    { value = M.STACK,   label_func = function() return _("Book stack") end },
    { value = M.COLLAGE, label_func = function() return _("Collage") end },
    { value = M.TEXT,    label_func = function() return _("Text") end },
    { value = M.NONE,    label_func = function() return _("None") end },
}

-- The library-wide style. Unset = divider, the shipped design.
M.DEFAULT_KEY = "group_display_default"

-- "Follow the library default" as something a chip can actually be SET to,
-- rather than only be by never having been touched.
--
-- Stored as a value rather than by clearing the key, because clearing depends
-- on how a draft is merged on save and reads as an accident in a settings
-- file; a named sentinel says what was meant. It is deliberately not a member
-- of OPTIONS, so validated() rejects it and resolve() falls through to the
-- default - which means every existing reader already handles it correctly
-- with no change.
M.FOLLOW_DEFAULT = "default"

local function validated(value)
    if type(value) ~= "string" then return nil end
    for _i, opt in ipairs(M.OPTIONS) do
        if opt.value == value then return value end
    end
    return nil
end

-- defaultMode() -> the library-wide style, never nil.
--
-- No migration off the per-kind keys this replaced, deliberately: that model
-- never shipped, so the only settings files carrying folder_display and
-- friends are the ones it was built on. Those keys are simply never read
-- again. Migration code is a permanent cost paid to preserve state that only
-- ever existed on a dev machine.
function M.defaultMode()
    return validated(BookshelfSettings.read(M.DEFAULT_KEY)) or M.DIVIDER
end

-- resolve(override) -> the style a tile should draw itself in, never nil.
-- `override` is a chip's stored group_display (nil = follow the default). A
-- value this build does not offer is treated as unset rather than reaching a
-- renderer that has no branch for it.
function M.resolve(override)
    return validated(override) or M.defaultMode()
end

-- pinned(override) -> the style this chip was explicitly SET to, or nil when
-- it is following the library default. resolve() answers "what do I draw";
-- this answers "did anyone choose", which is what a picker needs to tick the
-- right row and a summary needs to say "Default setting" rather than naming a
-- style the chip does not actually hold.
function M.pinned(override)
    return validated(override)
end

-- The chip editor's option list: the same styles, with "follow the library
-- default" in front. The library default's OWN picker uses M.OPTIONS and must
-- not offer this - a default that could be set to "the default" is circular.
M.CHIP_OPTIONS = {
    { value = M.FOLLOW_DEFAULT,
      label_func = function() return _("Default setting") end },
}
for _i = 1, #M.OPTIONS do
    M.CHIP_OPTIONS[#M.CHIP_OPTIONS + 1] = M.OPTIONS[_i]
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
-- Divider carries the name in its own band, Ribbon reverses it out of one and
-- Text makes the name the card's title, so all three already say what the
-- group is. Stack, collage and none show artwork with nothing naming it --
-- and on an author or genre tile the front book's cover is not a name.
-- Without this, choosing one of those three silently made the group
-- anonymous.
--
-- Still subject to the reader's own "Show text below covers" setting: this
-- says the name is NEEDED, not that it is shown regardless of preference.
function M.needsExternalLabel(mode)
    return mode == M.STACK or mode == M.COLLAGE or mode == M.NONE
end

-- externalLabel(mode, name) -> the name to print below the tile, or nil.
-- One call for shelf_row's seven group branches, so the rule lives here rather
-- than being re-derived at each of them.
function M.externalLabel(mode, name)
    if type(name) ~= "string" or name == "" then return nil end
    if not M.needsExternalLabel(mode) then return nil end
    return name
end

-- Night mode is NOT a plain inversion of intent: KOReader inverts the whole
-- framebuffer at refresh, so a colour that must LOOK the same in both modes is
-- painted pre-inverted. Declared here, above its first use, because a `local`
-- declared below a function that reads it silently rebinds to a nil global.
local function _nightMode()
    local ok, night = pcall(function()
        return G_reader_settings and G_reader_settings:isTrue("night_mode")
    end)
    return ok and night or false
end

-- ─── The ribbon ──────────────────────────────────────────────────────────────
-- A band across the lower third of the cover with the group's name reversed
-- out of it, running slightly past both edges of the cover.
--
-- The overhang is the whole idea. A band that stops at the cover's edges is a
-- caption printed ON the book; one that runs past them is a strap wrapped
-- AROUND a bundle of them, which is the group cue this mode trades the
-- cardboard for. It is small (a few pixels a side) because the slot has to
-- contain it -- the tile cannot paint outside its own dimen without smearing
-- into its neighbour.

-- How tall the band is at minimum, as a fraction of the cover. A floor, not a
-- ceiling: a two-line name grows the band, and the band grows UPWARD because
-- its bottom edge is pinned (see ribbonWidget).
local RIBBON_MIN_HEIGHT = 0.18
-- Clear space left BELOW the band, as a fraction of the cover. The band is a
-- strap around the books, not a footer welded to the bottom edge -- it needs
-- cover showing beneath it to read as one. Floored at a few real pixels so it
-- survives a small tile.
local RIBBON_BOTTOM_GAP = 0.07
-- How far the band runs past each edge of the cover.
function M.ribbonOverhang()
    return Screen:scaleBySize(4)
end

-- ribbonInset(mode) -> how much NARROWER the cover is in this mode, total.
--
-- The band has to overhang the cover while staying inside the tile: a widget
-- that paints past its own dimen is not clipped, it just draws over whatever
-- the neighbouring slot has already put there, and the shelf's repaint rects
-- would not cover the overflow either. So the cover gives up the space
-- instead -- an overhang each side, exactly as the pile shortens the cover to
-- make room for its layers. Zero in every other mode, so callers apply it
-- unconditionally.
function M.ribbonInset(mode)
    if mode ~= M.RIBBON then return 0 end
    return M.ribbonOverhang() * 2
end

-- ribbonColors() -> fill, text
-- The user's Folder overlay colours drive this, so one setting covers the
-- cardboard band and this one. Unset is BLACK with white text (rather than
-- the cardboard's manilla): a ribbon is a printed strap, and the whole point
-- of the mode is the hard contrast band across the artwork.
--
-- constantInNight mirrors folder_card: night mode inverts the framebuffer at
-- refresh, so a colour that must LOOK the same in both modes is painted
-- pre-inverted. A colour the user chose explicitly is honoured as-is, because
-- day and night are independently customisable.
function M.ribbonColors()
    local fill, text
    local ok_cp, CoverProgress = pcall(require, "lib/bookshelf_cover_progress")
    if ok_cp and CoverProgress and CoverProgress.resolvedColors then
        local ok_c, c = pcall(CoverProgress.resolvedColors)
        if ok_c and type(c) == "table" then
            fill, text = c.folder_bg, c.folder_fg
        end
    end
    local is_night = _nightMode()
    local function constantInNight(color)
        if is_night then return color:invert() end
        return color
    end
    return fill or constantInNight(Blitbuffer.COLOR_BLACK),
           text or constantInNight(Blitbuffer.COLOR_WHITE)
end

-- alpha=true trips appearance.koplugin's _renderText escape hatch (it gates on
-- `not self.alpha`), so the band's own colours survive themes that otherwise
-- repaint text in their palette. Same reason bookshelf_folder_card pins it on
-- the cardboard label.
local RibbonTextBox

-- One rendered line's height for a face/width, memoised: the clamp below needs
-- it per render and probing costs a full layout pass. Mirrors the same memo in
-- bookshelf_folder_card.
local _line_h_memo = {}
local function _lineHeight(face, bold, width)
    local key = tostring(face) .. "\1" .. tostring(bold) .. "\1" .. tostring(width)
    local h = _line_h_memo[key]
    if h then return h end
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local probe = TextBoxWidget:new{ text = "Mg", face = face, bold = bold,
                                     width = width }
    h = probe:getSize().h
    probe:free()
    _line_h_memo[key] = h
    return h
end

-- ribbonWidget(cover_w, cover_h, label) -> widget, y_offset
--
-- The widget is sized to the FULL band (cover width plus both overhangs) and
-- the caller offsets it by -overhang on x, so the band is centred on the
-- cover and protrudes evenly. y_offset is where the band's top sits relative
-- to the cover's top, so a caller that has already offset the cover downward
-- (true aspect bottom-anchors the card) adds the two together.
--
-- Returns nil for an empty label: a band with nothing in it says nothing and
-- just hides a third of the artwork.
function M.ribbonWidget(cover_w, cover_h, label)
    if type(label) ~= "string" or label == "" then return nil end
    if not (cover_w and cover_h and cover_w > 0 and cover_h > 0) then return nil end
    local TextBoxWidget   = require("ui/widget/textboxwidget")
    local FrameContainer  = require("ui/widget/container/framecontainer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    -- The plugin's OWN font wrapper, not KOReader's ui/font. They differ in
    -- the third argument: this one takes an options table and returns
    -- (face, bold); KOReader's takes a faceindex and concatenates it into a
    -- cache key, so handing it { bold = true } is a crash, not a bad font.
    -- Same call the cardboard label makes (bookshelf_folder_card).
    local BFont           = require("lib/bookshelf_fonts")
    local Size            = require("ui/size")
    if not RibbonTextBox then RibbonTextBox = TextBoxWidget:extend{ alpha = true } end

    local text = label:gsub("/$", "")
    local over    = M.ribbonOverhang()
    local band_w  = cover_w + over * 2
    local pad     = Size.padding.small
    local avail_w = band_w - pad * 2
    if avail_w <= 0 then return nil end

    -- Same font and the same user scale the cardboard label uses, so the two
    -- modes read as the same family rather than as two different designs.
    local scale = BookshelfSettings.read("stack_label_font_scale", 100) or 100
    local face_size = math.max(8, math.floor(15 * scale / 100))
    local face, bold = BFont:getFace("infofont", face_size, { bold = true })
    local fill, fg = M.ribbonColors()

    -- Text clamped by the SAME rule the cardboard label uses: at most two
    -- lines, ellipsis when it overflows. Derived from the real rendered line
    -- height rather than from a fraction of the cover, so the two modes cut a
    -- long folder name at the same place and a font-scale change moves both.
    local line_h = _lineHeight(face, bold, avail_w)
    local max_h  = 2 * line_h
    local probe = TextBoxWidget:new{
        text = text, face = face, bold = bold, width = avail_w,
    }
    local content_h = probe:getSize().h
    probe:free()
    local fits  = content_h <= max_h
    local txt_h = fits and content_h or max_h
    local txt = RibbonTextBox:new{
        text      = text,
        face      = face,
        bold      = bold,
        width     = avail_w,
        height    = txt_h,
        alignment = "center",
        fgcolor   = fg,
        -- TextBoxWidget FILLS its own background before drawing glyphs, and
        -- that default is white: without this it paints a white rectangle
        -- over the band and then draws white text onto it, which is exactly
        -- as invisible as it sounds.
        bgcolor   = fill,
        height_overflow_show_ellipsis = not fits,
    }

    local band_h = math.max(txt_h + pad * 2,
                            math.floor(cover_h * RIBBON_MIN_HEIGHT))
    local band = FrameContainer:new{
        width          = band_w,
        height         = band_h,
        background     = fill,
        bordersize     = 0,
        padding        = 0,
        margin         = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = band_w, h = band_h },
            txt,
        },
    }

    -- BOTTOM-ANCHORED, and the band grows UPWARD from that line. Anchoring the
    -- TOP instead put every band at the same y and let each grow downward by
    -- however many lines its name needed, so a row of folders had bands ending
    -- at four different heights -- the one thing that makes a row of straps
    -- read as an accident rather than a design. Pinned at the bottom they
    -- share a line and only their thickness varies, which is what a real band
    -- around a bundle does.
    --
    -- Not flush with the bottom edge: a strap has cover showing beneath it.
    -- Measured from the cover's own bottom, above the drop shadow, so the gap
    -- is to the artwork rather than to the shadow's outer edge.
    local shadow = 0
    local ok_sw, SpineWidget = pcall(require, "lib/bookshelf_spine_widget")
    if ok_sw and SpineWidget and SpineWidget.SHADOW_OFFSET then
        shadow = SpineWidget.SHADOW_OFFSET
    end
    local gap = math.max(Screen:scaleBySize(3),
                         math.floor(cover_h * RIBBON_BOTTOM_GAP))
    local y = cover_h - shadow - gap - band_h
    if y < 0 then y = 0 end
    return band, y
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
-- ─── Palette extraction for the collage gap wash ─────────────────────────────
--
-- Covers are decoded to RGB32 by RenderImage whatever the screen is, so the
-- colour is there to be read even on a greyscale device - it is only lost at
-- paint time, when an 8bpp destination converts. So this samples in colour
-- everywhere and lets the destination decide: real colour on a colour screen,
-- and on e-ink the LUMINANCE of the colour picked, which is still a better
-- answer than the mean was.
--
-- 16x16 per cover, up from the 8x8 the mean used. A feature has to survive
-- sampling to be findable: a ring occupying five percent of a cover lands
-- roughly a dozen samples at this density, which is enough to rank.
local SAMPLE_STEPS = 16
-- 3 bits per channel. Fine enough to keep gold apart from orange, coarse
-- enough that the dozen samples off one ring land in the SAME bucket instead
-- of scattering into a dozen singletons that each lose to the background.
local BUCKET_BITS  = 3

-- Saturation floor in the score below. Not zero: a black-and-white cover has
-- nothing saturated at all, and with a bare `count * sat` every bucket would
-- score zero and the pick would be arbitrary. With a floor, such a cover falls
-- back to ranking by area, which is the old behaviour and the right one there.
local SAT_FLOOR = 0.02
-- How far apart two stops must be in RGB before both are worth having. Below
-- this the wash has no visible travel and reads as the flat fill it replaced.
local MIN_STOP_DISTANCE = 60

-- bucketKey(r, g, b) -> integer bucket, and the quantised centre.
local function bucketKey(r, g, b)
    local shift = 8 - BUCKET_BITS
    local qr, qg, qb = r >= 0 and math.floor(r / 2 ^ shift) or 0,
                       math.floor(g / 2 ^ shift),
                       math.floor(b / 2 ^ shift)
    return (qr * 64) + (qg * 8) + qb
end

local function saturationOf(r, g, b)
    local mx = math.max(r, g, b)
    local mn = math.min(r, g, b)
    if mx <= 0 then return 0 end
    return (mx - mn) / mx
end

local function luminanceOf(c)
    return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
end

-- sampleCover(hist, bb) - fold one cover's pixels into a shared histogram.
--
-- Shared across every cover in the collage on purpose: the wash stands for the
-- GROUP, so the palette is drawn from all of its books at once rather than one
-- tone each. Two covers that share a strong colour reinforce it, which is
-- usually the thing that makes a series look like a series.
local function sampleCover(hist, bb)
    pcall(function()
        local w, h = bb:getWidth(), bb:getHeight()
        if not (w and h and w > 0 and h > 0) then return end
        for sy = 0, SAMPLE_STEPS - 1 do
            for sx = 0, SAMPLE_STEPS - 1 do
                local px = math.floor((sx + 0.5) * w / SAMPLE_STEPS)
                local py = math.floor((sy + 0.5) * h / SAMPLE_STEPS)
                local p = bb:getPixel(px, py)
                local c = p and p.getColorRGB32 and p:getColorRGB32() or nil
                if c then
                    local k = bucketKey(c.r, c.g, c.b)
                    local b = hist[k]
                    if b then
                        b.n = b.n + 1
                        b.r = b.r + c.r; b.g = b.g + c.g; b.b = b.b + c.b
                    else
                        hist[k] = { n = 1, r = c.r, g = c.g, b = c.b }
                    end
                end
            end
        end
    end)
end

-- pickPalette(hist, max_stops) -> up to max_stops {r,g,b} stops, dark to light.
--
-- SCORED BY count * (saturation + floor), which is the whole point of this
-- over an average. A gold ring on a black cover is a few percent of the pixels
-- and loses every popularity contest going, but it is the only thing on the
-- cover anyone would describe - so area alone picks black, and area weighted
-- by saturation picks gold. The mean picked neither: it returned a dark
-- nothing that matched no part of the image.
--
-- Ordered by luminance rather than by score, so the wash runs dark to light
-- like a shadow rather than jumping about by rank.
--
-- Pure: takes a plain histogram, returns plain tables. The blitbuffer work is
-- sampleCover's, and keeping them apart is what makes this testable.
function M.pickPalette(hist, max_stops)
    if type(hist) ~= "table" then return {} end
    max_stops = max_stops or 3
    local ranked = {}
    for _k, b in pairs(hist) do
        if b.n and b.n > 0 then
            local r, g, bl = b.r / b.n, b.g / b.n, b.b / b.n
            ranked[#ranked + 1] = {
                r = r, g = g, b = bl,
                score = b.n * (saturationOf(r, g, bl) + SAT_FLOOR),
            }
        end
    end
    table.sort(ranked, function(x, y)
        if x.score == y.score then return luminanceOf(x) < luminanceOf(y) end
        return x.score > y.score
    end)
    local picked = {}
    for _i, cand in ipairs(ranked) do
        if #picked >= max_stops then break end
        local far_enough = true
        for _j, got in ipairs(picked) do
            local dr, dg, db = cand.r - got.r, cand.g - got.g, cand.b - got.b
            if math.sqrt(dr * dr + dg * dg + db * db) < MIN_STOP_DISTANCE then
                far_enough = false
                break
            end
        end
        if far_enough then
            picked[#picked + 1] = { r = cand.r, g = cand.g, b = cand.b }
        end
    end
    table.sort(picked, function(x, y) return luminanceOf(x) < luminanceOf(y) end)
    return picked
end

-- gradientColorAt(stops, t) -> {r,g,b} at position t (0..1) along the ombre.
--
-- The gap fill in a collage used to be ONE colour: the mean of every cover
-- that resolved. Averaging is what made it read as a hole - a flat panel next
-- to photographic covers looks like missing artwork, and the more covers it
-- averaged the muddier and more uniform that panel got.
--
-- Pure, and separated from any blitting, because the arithmetic is the part
-- worth testing: the endpoints have to land exactly on the first and last
-- stop, or the wash starts mid-colour and meets the covers as a shade nobody
-- picked.
function M.gradientColorAt(stops, t)
    if type(stops) ~= "table" or #stops == 0 then return nil end
    if #stops == 1 then return stops[1] end
    if type(t) ~= "number" then t = 0 end
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    -- Position along the whole run, in stop-intervals. t = 1 lands exactly on
    -- the last stop rather than one interval past it.
    local span = (#stops - 1) * t
    local i    = math.floor(span)
    if i >= #stops - 1 then return stops[#stops] end
    local frac = span - i
    local a, b = stops[i + 1], stops[i + 2]
    return {
        r = a.r + (b.r - a.r) * frac,
        g = a.g + (b.g - a.g) * frac,
        b = a.b + (b.b - a.b) * frac,
    }
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
    local drawn = 0
    -- One histogram across every cover: the wash stands for the GROUP, so its
    -- palette comes from all of its books at once (see sampleCover).
    local hist = {}
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
                    sampleCover(hist, scaled)
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
    -- Fill the gaps with a wash through the covers' own tones (see
    -- gradientToneAt). Only ever 1 or 2 quarters: four covers leave no gap,
    -- and fewer than two drawn returned nil above.
    local fill          -- flat fallback, when there is nothing to sample
    local wash = M.pickPalette(hist, 3)
    if #wash == 0 then
        wash = nil
        local ok_sw, SpineWidget = pcall(require, "lib/bookshelf_spine_widget")
        if ok_sw and SpineWidget and SpineWidget.fallbackBgs then
            fill = SpineWidget.fallbackBgs()
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
    elseif wash then
        -- COLOUR-SAFE PAINTING, which paintRect is not: it takes a C fast path
        -- that collapses whatever colour it is given to value:getColor8().a,
        -- so it can only ever fill grey. setPixel is the one write that keeps
        -- a colour, and per-pixel over two quarters would be tens of thousands
        -- of FFI calls.
        --
        -- So the wash is built once as a ONE-PIXEL-WIDE RGB32 strip - height
        -- setPixel calls, a couple of hundred - then widened with scale() and
        -- blitted in. Both of those keep colour (measured), and both are C.
        --
        -- The strip spans the whole tile, not each cell: the two gaps of a
        -- diagonal collage sit in opposite corners, and a wash restarted per
        -- cell would meet the covers at a different colour on each side. One
        -- run down the tile keeps it a single surface.
        --
        -- Into an 8bpp destination the blit converts to grey, which is right:
        -- the tone of the colour chosen, on a screen that cannot show the
        -- colour. Nothing here needs to know which kind of screen it is on.
        pcall(function()
            local strip = Blitbuffer.new(1, height, Blitbuffer.TYPE_BBRGB32)
            for y = 0, height - 1 do
                local t = (height > 1) and (y / (height - 1)) or 0
                local c = M.gradientColorAt(wash, t)
                if c then
                    strip:setPixel(0, y, Blitbuffer.ColorRGB32(
                        math.floor(c.r + 0.5), math.floor(c.g + 0.5),
                        math.floor(c.b + 0.5), 0xFF))
                end
            end
            for q = 1, 4 do
                if not filled[q] then
                    local cell = quarters[q]
                    local band = strip:scale(cell.w, height)
                    if band then
                        out:blitFrom(band, cell.x, cell.y, 0, cell.y,
                                     cell.w, cell.h)
                        if band.free then band:free() end
                    end
                end
            end
            if strip.free then strip:free() end
        end)
    end
    paintDividers()
    return out
end

return M
