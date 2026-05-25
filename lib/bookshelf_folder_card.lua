-- bookshelf_folder_card.lua
-- The shared "cardboard folder card" primitive used by FolderStack and
-- SeriesStack. Renders an L-shaped cardboard silhouette (small index tab
-- on the top-left, full-width body below) sized to fit up to two lines
-- of label text, bottom-aligned within a slot-sized dimen so it overlays
-- the bottom portion of a book SpineWidget while the book peeks above.
--
-- API:
--   FolderCard.build{ width, height, label } → folder_widget, label_widget
--
-- Both returned widgets are FrameContainers sized to the slot dimen.
-- Caller composes them into its own OverlapGroup at z-order:
--   OverlapGroup{ dimen, book_widget, folder_widget, label_widget, badge? }
--
-- Why a build helper rather than a wrapping widget: callers want to
-- splat these into an existing OverlapGroup alongside other slot-sized
-- widgets (book, count badge), and a nested OverlapGroup-in-a-widget
-- adds layers without buying anything.

local FrameContainer = require("ui/widget/container/framecontainer")
local TextBoxWidget  = require("ui/widget/textboxwidget")
local Widget         = require("ui/widget/widget")
local Geom           = require("ui/geometry")
local Size           = require("ui/size")
local Font           = require("ui/font")
local Blitbuffer     = require("ffi/blitbuffer")
local Screen         = require("device").screen

-- CardboardTextBox: TextBoxWidget subclass that pins alpha=true so its
-- explicit bgcolor=CARDBOARD and fgcolor=COLOR_BLACK survive third-party
-- monkey-patching. appearance.koplugin's _renderText patches gate on
-- `not self.alpha` — alpha=true trips that escape hatch and preserves our
-- colours when a theme is applied. alpha is a no-op for TextBoxWidget
-- itself on this KOReader build: _renderBB derives bbtype from
-- Screen.isColorEnabled only, and paintTo uses plain blitFrom.
local CardboardTextBox = TextBoxWidget:extend{
    alpha = true,
}

local FolderCard = {}

-- Tab width as a fraction of card width. Tab height is derived per-render
-- from the actual rendered label line height (half a line tall) so the
-- tab scales with the chosen font size.
local TAB_WIDTH_FRAC = 0.40

-- Cardboard fill colour. Real manilla on colour panels; mid-grey on B&W
-- e-ink (predictable dithering, matches book spine border weight).
local CARDBOARD
if Screen.isColorEnabled and Screen:isColorEnabled() then
    CARDBOARD = Blitbuffer.colorFromString("#e7c9a9")
else
    CARDBOARD = Blitbuffer.gray(0.20)
end
local CARDBOARD_EDGE = Blitbuffer.COLOR_BLACK

-- Drop-shadow allocation — must match SpineWidget's SHADOW_OFFSET so the
-- book card behind the folder casts its drop shadow into the same L-strip
-- where the folder's would be. Callers rely on this to skip a separate
-- folder shadow layer.
local SHADOW_OFFSET = Screen:scaleBySize(4)
local CARD_BORDER   = Screen:scaleBySize(1)
local CARD_RADIUS   = Screen:scaleBySize(4)

-- FolderPolygon: paints the L-shaped cardboard silhouette (tab top-left
-- + body below). Body bottom corners and tab top corners are rounded;
-- the concave inside corner where tab meets body stays sharp.
local FolderPolygon = Widget:extend{
    width      = nil,
    height     = nil,
    tab_w      = nil,    -- tab width (left edge to tab's right wall)
    tab_h      = nil,    -- tab height (top edge to body's top edge)
    fill_color = nil,
    edge_color = nil,
    radius     = 0,      -- body bottom-corner radius
    tab_radius = 0,      -- tab top-corner radius
}

function FolderPolygon:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
end

function FolderPolygon:paintTo(bb, x, y)
    local w     = self.width
    local h     = self.height
    local tw    = self.tab_w
    local th    = self.tab_h
    local fill  = self.fill_color
    local edge  = self.edge_color
    local r     = self.radius or 0
    local r_sq  = r * r
    local tr    = self.tab_radius or 0
    if tr > th then tr = th end
    if tr * 2 > tw then tr = math.floor(tw / 2) end
    local tr_sq = tr * tr

    -- Use paintRectRGB32 unconditionally for the fill. paintRect strips
    -- ColorRGB→Color8 via getColor8() before fill (blitbuffer.lua:1677),
    -- so a manilla ColorRGB32 lands on the framebuffer as the equivalent
    -- grayscale value — the body renders silver instead of tan.
    -- paintRectRGB32 calls color:getColorRGB32() first, which all Color
    -- types implement (Color8 returns the grayscale value as r=g=b), so
    -- this works for both the cardboard fill and grayscale shadows.
    --
    -- Note: can't sniff `fill.r` to dispatch — Color8 is an FFI struct,
    -- and accessing a missing field on a C struct hard-errors instead of
    -- returning nil. Cheaper to just always go through the RGB path.
    local function fillRect(rx, ry, rw, rh)
        bb:paintRectRGB32(rx, ry, rw, rh, fill)
    end
    -- Same story for the edge — when the user picks a ColorRGB32 edge
    -- through the Folder overlay foreground setting, the plain paintRect
    -- would flatten it to luminance. Route every edge stroke through
    -- paintRectRGB32 (Color8 still works because it implements
    -- getColorRGB32 as r=g=b).
    local function edgeRect(rx, ry, rw, rh)
        bb:paintRectRGB32(rx, ry, rw, rh, edge)
    end

    -- Tab fill: small rectangle in the top-left, with rounded top corners
    -- when tab_radius > 0. Bulk fillRect for the part below the corner
    -- band, then row-by-row clipping in the band itself. Same (i+1)² arc
    -- convention as the body bottom corners.
    if tw > 0 and th > 0 then
        if th > tr then
            fillRect(x, y + tr, tw, th - tr)
        end
        if tr > 0 then
            for dy = 0, tr - 1 do
                local i      = tr - 1 - dy
                local i_sq   = (i + 1) * (i + 1)
                local cutoff = 0
                while cutoff < tr and (tr - cutoff) * (tr - cutoff) + i_sq > tr_sq do
                    cutoff = cutoff + 1
                end
                local row_left  = cutoff
                local row_right = tw - cutoff
                if row_right > row_left then
                    fillRect(x + row_left, y + dy, row_right - row_left, 1)
                end
            end
        end
    end

    -- Body rectangle above the bottom corner-clip band: one bulk fillRect.
    local body_top         = th
    local body_full_bottom = h - 1 - (r > 0 and r or 0)
    if body_full_bottom >= body_top then
        fillRect(x, y + body_top, w, body_full_bottom - body_top + 1)
    end
    -- Bottom rounded-corner band: row-by-row with extent clipping. Don't
    -- paint outside the rounded area (no PAGE_BG knockout) — preserves
    -- whatever's underneath. The corner arc is centred at (r, h-r) with
    -- radius r; the (i+1)² bias makes cutoff≈0 at i=0 and cutoff≈r at
    -- i=r-1 — avoids the inverted-corner bug where the bottom edge would
    -- detach from the cardboard.
    if r > 0 then
        for dy = math.max(body_top, h - r), h - 1 do
            local i      = dy - (h - r)
            local i_sq   = (i + 1) * (i + 1)
            local cutoff = 0
            while cutoff < r and (r - cutoff) * (r - cutoff) + i_sq > r_sq do
                cutoff = cutoff + 1
            end
            local row_left  = cutoff
            local row_right = w - cutoff
            if row_right > row_left then
                fillRect(x + row_left, y + dy, row_right - row_left, 1)
            end
        end
    end

    if edge then
        local b = CARD_BORDER
        edgeRect(x, y + tr, b, h - r - tr)            -- left wall
        edgeRect(x + tr, y, tw - 2 * tr, b)           -- tab top
        edgeRect(x + tw - b, y + tr, b, th - tr)      -- tab right wall
        edgeRect(x + tw, y + th, w - tw, b)           -- body top right of tab
        edgeRect(x + w - b, y + th, b, h - th - r)    -- body right wall
        edgeRect(x + r, y + h - b, w - 2 * r, b)      -- body bottom
        if tr > 0 then
            for i = 0, tr - 1 do
                local dy   = tr - 1 - i
                local i_sq = (i + 1) * (i + 1)
                local cutoff = 0
                while cutoff < tr and (tr - cutoff) * (tr - cutoff) + i_sq > tr_sq do
                    cutoff = cutoff + 1
                end
                edgeRect(x + cutoff, y + dy, b, b)
                edgeRect(x + tw - cutoff - b, y + dy, b, b)
            end
        end
        if r > 0 then
            for i = 0, r - 1 do
                local dy   = h - r + i
                local i_sq = (i + 1) * (i + 1)
                local cutoff = 0
                while cutoff < r and (r - cutoff) * (r - cutoff) + i_sq > r_sq do
                    cutoff = cutoff + 1
                end
                edgeRect(x + cutoff, y + dy, b, b)
                edgeRect(x + w - cutoff - b, y + dy, b, b)
            end
        end
    end
end

-- Build the folder card composition for a slot of (width, height) carrying
-- `label`. Returns two FrameContainer widgets sized to the slot dimen
-- (folder_positioned, label_positioned) ready for splatting into a parent
-- OverlapGroup at the appropriate z-order.
function FolderCard.build(opts)
    local slot_w = opts.width
    local slot_h = opts.height
    local label_text = (opts.label or ""):gsub("/$", "")

    -- Pull the user's Folder overlay colours, falling back to the
    -- device-aware module defaults when either is unset. CARDBOARD itself
    -- already resolves to manilla on colour panels / dark grey on B&W, so
    -- leaving it as the fallback preserves the per-device look exactly
    -- for users who haven't picked anything. The require happens lazily
    -- because bookshelf_cover_progress requires bookshelf_settings_store
    -- and bookshelf_colour, and pulling those at module load creates a
    -- cycle with bookshelf_widget's require ordering.
    local CoverProgress = require("lib/bookshelf_cover_progress")
    local indicator_colours = CoverProgress.resolvedColours()
    local fill_color = indicator_colours.folder_bg or CARDBOARD
    local edge_color = indicator_colours.folder_fg or CARDBOARD_EDGE
    local label_fg   = indicator_colours.folder_fg or Blitbuffer.COLOR_BLACK

    local card_w        = slot_w - SHADOW_OFFSET
    -- Stack & folder label scale (issue #60): users with long Genre /
    -- Tag / Series names that get cut off can dial the cardboard-card
    -- font down to fit more text. Same store as the other text-size
    -- settings; baseline 16pt matches the pre-#60 hardcoded size, so
    -- 100% is a no-op. Lazy-require: bookshelf_settings_store sits
    -- deep enough in the dependency tree that pulling it at module
    -- load reintroduces the require cycle bookshelf_widget already
    -- guards against (see CoverProgress lazy-require below).
    local BookshelfSettings = require("lib/bookshelf_settings_store")
    local label_scale = BookshelfSettings.read("stack_label_font_scale", 100) or 100
    local face_size   = math.max(8, math.floor(16 * label_scale / 100))
    local face        = Font:getFace("infofont", face_size)
    local label_pad     = Size.padding.large
    local label_w_avail = card_w - label_pad * 2

    -- Probe a single ascii line to derive actual rendered line height.
    -- Tab height is half this; body fits up to 2 lines.
    local line_probe = TextBoxWidget:new{
        text  = "Mg",
        face  = face,
        bold  = true,
        width = label_w_avail,
    }
    local line_h = line_probe:getSize().h
    line_probe:free()

    local body_inner_max = 2 * line_h
    local probe = TextBoxWidget:new{
        text  = label_text,
        face  = face,
        bold  = true,
        width = label_w_avail,
    }
    local content_h = probe:getSize().h
    probe:free()
    local fits    = content_h <= body_inner_max
    local label_h = fits and content_h or body_inner_max

    local tab_h = math.max(1, math.floor(line_h / 2))
    local tab_w = math.floor(card_w * TAB_WIDTH_FRAC)

    local card_h   = tab_h + label_pad + label_h + label_pad
    local v_offset = slot_h - card_h - SHADOW_OFFSET
    if v_offset < 0 then v_offset = 0 end

    local folder = FolderPolygon:new{
        width      = card_w,
        height     = card_h,
        tab_w      = tab_w,
        tab_h      = tab_h,
        fill_color = fill_color,
        edge_color = edge_color,
        radius     = CARD_RADIUS,
        tab_radius = CARD_RADIUS,
    }
    local folder_positioned = FrameContainer:new{
        bordersize   = 0,
        padding      = 0,
        padding_top  = v_offset,
        padding_left = 0,
        folder,
    }

    -- CardboardTextBox.alpha=true trips appearance.koplugin's _renderText
    -- escape hatch (it gates on `not self.alpha`), so the user's chosen
    -- fgcolor / bgcolor survive themes that otherwise repaint text in
    -- their own palette. Passing user colours through here doesn't change
    -- that contract — the alpha flag still governs the appearance gate.
    local label_widget = CardboardTextBox:new{
        text                          = label_text,
        face                          = face,
        bold                          = true,
        fgcolor                       = label_fg,
        bgcolor                       = fill_color,
        width                         = label_w_avail,
        alignment                     = "left",
        height                        = label_h,
        height_overflow_show_ellipsis = not fits,
    }
    local label_positioned = FrameContainer:new{
        bordersize   = 0,
        padding      = 0,
        padding_top  = v_offset + tab_h + label_pad,
        padding_left = label_pad,
        label_widget,
    }

    return folder_positioned, label_positioned
end

-- Exposed for callers that need to align other elements (e.g., a count
-- badge) with the slot's shadow allocation.
FolderCard.SHADOW_OFFSET = SHADOW_OFFSET

return FolderCard
