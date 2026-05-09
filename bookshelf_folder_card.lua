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

-- CardboardTextBox: TextBoxWidget subclass whose paintTo composites a CARDBOARD
-- background into the target bb using only standard blitbuffer primitives.
--
-- TextBoxWidget._bb is always initialised white before glyphs are rendered
-- into it; on KOReader builds where bgcolor is silently ignored, blitting
-- that _bb covers any parent-painted CARDBOARD with a white rectangle.
--
-- Algorithm (invert → saturating-add → invert):
--   1. Fill target area with CARDBOARD; invert → inverted-CARDBOARD.
--   2. Invert _bb: white-bg→black, black-text→white.
--   3. addblitFrom: black-bg + inv-CARDBOARD = inv-CARDBOARD (unchanged);
--                   white-text + inv-CARDBOARD = saturates to 0xFF.
--   4. Restore _bb (invert back).
--   5. Invert target: inv-CARDBOARD→CARDBOARD (bg), 0xFF→0x00 (black text).
--
-- No Lua pixel loops; works on both greyscale and colour targets.
local CardboardTextBox = TextBoxWidget:extend{}
function CardboardTextBox:paintTo(bb, x, y)
    if not self._bb then
        TextBoxWidget.paintTo(self, bb, x, y)
        return
    end
    local w = self._bb:getWidth()
    local h = self._bb:getHeight()
    -- addblitFrom on this KOReader build takes an explicit intensity
    -- parameter (0.0–1.0); omitting it leaves intensity=nil and crashes
    -- at `intensity * 0xFF`. Pass 1.0 for full-strength saturating add.
    bb:paintRectRGB32(x, y, w, h, CARDBOARD)
    bb:invertRect(x, y, w, h)
    self._bb:invertRect(0, 0, w, h)
    bb:addblitFrom(self._bb, x, y, 0, 0, w, h, 1.0)
    self._bb:invertRect(0, 0, w, h)
    bb:invertRect(x, y, w, h)
end

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

    if self.edge_color then
        local b    = CARD_BORDER
        local edge = self.edge_color
        bb:paintRect(x, y + tr, b, h - r - tr, edge)            -- left wall
        bb:paintRect(x + tr, y, tw - 2 * tr, b, edge)           -- tab top
        bb:paintRect(x + tw - b, y + tr, b, th - tr, edge)      -- tab right wall
        bb:paintRect(x + tw, y + th, w - tw, b, edge)           -- body top right of tab
        bb:paintRect(x + w - b, y + th, b, h - th - r, edge)    -- body right wall
        bb:paintRect(x + r, y + h - b, w - 2 * r, b, edge)      -- body bottom
        if tr > 0 then
            for i = 0, tr - 1 do
                local dy   = tr - 1 - i
                local i_sq = (i + 1) * (i + 1)
                local cutoff = 0
                while cutoff < tr and (tr - cutoff) * (tr - cutoff) + i_sq > tr_sq do
                    cutoff = cutoff + 1
                end
                bb:paintRect(x + cutoff, y + dy, b, b, edge)
                bb:paintRect(x + tw - cutoff - b, y + dy, b, b, edge)
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
                bb:paintRect(x + cutoff, y + dy, b, b, edge)
                bb:paintRect(x + w - cutoff - b, y + dy, b, b, edge)
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

    local card_w        = slot_w - SHADOW_OFFSET
    local face          = Font:getFace("infofont", 16)
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
        fill_color = CARDBOARD,
        edge_color = CARDBOARD_EDGE,
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

    local label_widget = CardboardTextBox:new{
        text                          = label_text,
        face                          = face,
        bold                          = true,
        fgcolor                       = Blitbuffer.COLOR_BLACK,
        bgcolor                       = CARDBOARD,
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
