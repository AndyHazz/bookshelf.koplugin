-- folder_stack.lua
-- Renders a folder-as-magazine-file: the first book inside the folder peeks
-- out the top of a manilla cardboard "magazine file" shape; the folder name
-- sits centred on the cardboard's front face. Drop-shadowed to match the
-- depth of regular spine widgets.
--
-- Visual composition (back-to-front):
--   1. Magazine drop shadow — the magazine's polygon shape filled in
--      shadow-grey at SHADOW_OFFSET down+right of the card. Visible as an
--      L-shaped halo on the right and bottom edges of the magazine, and a
--      thinner band tracing the slope on its underside.
--   2. First-book cover (rendered via SpineWidget) inset slightly inside
--      the card so the cardboard's side walls visually wrap the book.
--   3. Magazine front: a filled cardboard polygon with a sloped top edge.
--      The slope rises on the LEFT (high y on right, low y on left → the
--      slope drops as the eye moves rightward, matching the reference
--      photo's open-mouth orientation). Below the slope: cardboard fill
--      to the bottom edge.
--   4. Folder name centred horizontally and vertically on the cardboard
--      (TextBoxWidget with bgcolor = CARDBOARD so its rendering matches
--      the surrounding fill rather than knocking out a white rectangle).
--
-- All shapes paint into an OverlapGroup at slot dimen so the whole stack
-- has the same getSize() / tap zone as a regular SpineWidget — drop-in
-- replacement at the ShelfRow slot level.

local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup   = require("ui/widget/overlapgroup")
local CenterContainer= require("ui/widget/container/centercontainer")
local TopContainer   = require("ui/widget/container/topcontainer")
local TextWidget     = require("ui/widget/textwidget")
local TextBoxWidget  = require("ui/widget/textboxwidget")
local Widget         = require("ui/widget/widget")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local Size           = require("ui/size")
local Font           = require("ui/font")
local Blitbuffer     = require("ffi/blitbuffer")
local Screen         = require("device").screen
local SpineWidget    = require("spine_widget")

-- Slope geometry as fractions of slot height. Slope FALLS going
-- left-to-right (y_left < y_right): back wall on the LEFT (taller),
-- front wall lip on the RIGHT (shorter). Magazine occupies about 2/3
-- of slot height.
local SLOPE_LEFT_FRAC  = 0.53   -- y at left edge (high point of slope, back wall top)
local SLOPE_RIGHT_FRAC = 0.70   -- y at right edge (low point of slope, front wall lip)

-- Cardboard colour and a darker outline. Slightly denser than the
-- earlier values so the magazine reads as a solid object on the page
-- now that the drop shadow has been removed (see init below for the
-- composition; shadow was making the shape look 1-D rather than 3-D).
local CARDBOARD       = Blitbuffer.gray(0.30)
local CARDBOARD_EDGE  = Blitbuffer.gray(0.65)
local PAGE_BG         = Blitbuffer.COLOR_WHITE

-- Bottom-corner rounding (matches SpineWidget's CARD_RADIUS so adjacent
-- magazine and book spines on the same shelf have consistent corner
-- treatment). The TOP corners are kept angular — they're slope/wall
-- junctions, sharp by design in a real magazine file.
local CARD_RADIUS = Screen:scaleBySize(4)

-- Book inset in absolute pixels. Just enough that a thin band of
-- cardboard wraps the book on each side and the top — the book "barely
-- fits inside" the file rather than shrinking visibly inside it.
local BOOK_INSET_X = Screen:scaleBySize(3)
local BOOK_INSET_Y = Screen:scaleBySize(2)

-- Painter for the magazine polygon: cardboard filled below a sloped top
-- edge, with rounded BOTTOM corners (top corners stay angular — they're
-- slope/wall junctions, sharp by design) and an optional thin darker
-- outline. Reused for both the front fill (CARDBOARD) and the drop
-- shadow (SHADOW_GRAY) — only fill_color differs, so corner-rounding
-- and shadow shape stay in sync.
local MagazinePolygon = Widget:extend{
    width      = nil,
    height     = nil,
    y_left     = nil,
    y_right    = nil,
    fill_color = nil,    -- the polygon body colour
    edge_color = nil,    -- optional outline colour; nil = no outline
    radius     = 0,      -- bottom-corner radius (0 = sharp corners)
}

function MagazinePolygon:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
end

function MagazinePolygon:paintTo(bb, x, y)
    local w  = self.width
    local h  = self.height
    local yl = self.y_left
    local yr = self.y_right
    local fill = self.fill_color
    local y_min = math.min(yl, yr)
    local y_max = math.max(yl, yr)
    -- Per-row fill: above min(yl, yr) nothing; between min and max use
    -- the slope's x at this row to start; below max, full width.
    for dy = 0, h - 1 do
        local x_start
        if dy >= y_max then
            x_start = 0
        elseif dy < y_min then
            x_start = nil
        else
            local frac = (dy - yl) / (yr - yl)
            x_start = math.floor((w - 1) * frac + 0.5)
            if x_start < 0 then x_start = 0 end
            if x_start > w - 1 then x_start = w - 1 end
        end
        if x_start then
            bb:paintRect(x + x_start, y + dy, w - x_start, 1, fill)
        end
    end
    -- Round bottom corners by knocking out the bottom-left/-right corner
    -- squares with PAGE_BG. Same arithmetic dx² + dy² > r² test the
    -- SpineWidget's RoundedCornerCard uses for consistency.
    local r    = self.radius or 0
    local r_sq = r * r
    if r > 0 then
        for i = 0, r - 1 do
            local dy = h - r + i           -- row inside the corner square
            local i_sq = (i + 1) * (i + 1) -- y² distance from corner-arc centre
            local cutoff = 0
            while cutoff < r and (r - cutoff) * (r - cutoff) + i_sq > r_sq do
                cutoff = cutoff + 1
            end
            if cutoff > 0 then
                bb:paintRect(x, y + dy, cutoff, 1, PAGE_BG)               -- BL
                bb:paintRect(x + w - cutoff, y + dy, cutoff, 1, PAGE_BG)  -- BR
            end
        end
    end
    if self.edge_color then
        local b = Size.border.thin
        local edge = self.edge_color
        bb:paintRect(x + r, y + h - b, w - 2 * r, b, edge)            -- bottom (between rounded corners)
        bb:paintRect(x + w - b, y + y_min, b, h - y_min - r, edge)    -- right (back wall, stops at corner radius)
        bb:paintRect(x, y + yl, b, h - yl - r, edge)                  -- left (front wall, stops at corner radius)
        -- Slope edge: stair-step b×b blocks along the line.
        local steps = math.max(w, math.abs(yr - yl))
        for s = 0, steps do
            local px = math.floor(s * (w - 1) / steps + 0.5)
            local py = math.floor(yl + (yr - yl) * s / steps + 0.5)
            bb:paintRect(x + px, y + py, b, b, edge)
        end
        -- Rounded-corner outline: walk the arc itself and stamp b×b blocks.
        if r > 0 then
            for i = 0, r - 1 do
                local dy = h - r + i
                local i_sq = (i + 1) * (i + 1)
                -- Find the arc's exact x for this row (where dx² + dy² ≈ r²)
                local cutoff = 0
                while cutoff < r and (r - cutoff) * (r - cutoff) + i_sq > r_sq do
                    cutoff = cutoff + 1
                end
                bb:paintRect(x + cutoff, y + dy, b, b, edge)               -- BL arc
                bb:paintRect(x + w - cutoff - b, y + dy, b, b, edge)       -- BR arc
            end
        end
    end
end

local FolderStack = InputContainer:extend{
    folder      = nil,    -- { path, label, first_book }
    width       = nil,
    height      = nil,
    on_tap      = nil,
    on_hold     = nil,
    is_selected = false,
}

function FolderStack:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    -- No drop shadow on folders — the previous shadow read as "flat
    -- shape with shadow" rather than "3D file on the page". A darker
    -- cardboard fill plus the perimeter outline carry the solidity
    -- without extra layering. Folder fills the full slot (book covers
    -- still leave SHADOW_OFFSET space for their own shadows; the
    -- folder doesn't need that allocation).
    local card_w = self.width
    local card_h = self.height

    -- Slope endpoints in card-local coordinates.
    local y_left  = math.floor(card_h * SLOPE_LEFT_FRAC)
    local y_right = math.floor(card_h * SLOPE_RIGHT_FRAC)

    -- Book layer: SpineWidget for the first book, inset within the card
    -- by a few pixels on every side. The book's bottom extends to the
    -- card bottom and is hidden by the magazine's cardboard fill below
    -- the slope; only the top portion (above the slope) is visible.
    local book_w = card_w - BOOK_INSET_X * 2
    local book_h = card_h - BOOK_INSET_Y
    local book_widget
    if self.folder and self.folder.first_book then
        book_widget = SpineWidget:new{
            book        = self.folder.first_book,
            width       = book_w,
            height      = book_h,
            cover_fill  = true,
            is_selected = self.is_selected,
        }
    else
        -- Empty folder: SpineWidget's fallback path with the folder's
        -- label as the title so the "?" placeholder reads correctly.
        book_widget = SpineWidget:new{
            book        = { title = self.folder and self.folder.label or "" },
            width       = book_w,
            height      = book_h,
            is_selected = self.is_selected,
        }
    end
    local book_positioned = FrameContainer:new{
        bordersize    = 0,
        padding       = 0,
        padding_top   = BOOK_INSET_Y,
        padding_left  = BOOK_INSET_X,
        book_widget,
    }

    -- Magazine front: cardboard fill in front of the book, rounded
    -- bottom corners, thin darker outline.
    local magazine = MagazinePolygon:new{
        width      = card_w,
        height     = card_h,
        y_left     = y_left,
        y_right    = y_right,
        fill_color = CARDBOARD,
        edge_color = CARDBOARD_EDGE,
        radius     = CARD_RADIUS,
    }

    -- Folder label: centred both axes on the cardboard area below the
    -- slope's lowest point. TextBoxWidget bgcolor = CARDBOARD so the
    -- text renders directly onto cardboard rather than knocking out a
    -- white rectangle. Strip a trailing "/" if FileChooser appended one.
    --
    -- Vertical centring works by probing the unconstrained TextBoxWidget
    -- to learn its content height, then building the real widget with
    -- height = min(content, available). When content fits, the
    -- CenterContainer (sized to label_h_avail) genuinely centres the
    -- shorter widget; when it overflows, we cap at available height and
    -- height_overflow_show_ellipsis truncates with "…".
    local label_text = self.folder and self.folder.label or ""
    label_text = label_text:gsub("/$", "")
    local label_top     = math.max(y_left, y_right) + Size.padding.small
    local label_h_avail = card_h - label_top - Size.padding.small
    local label_w_avail = card_w - Size.padding.default * 2
    local face          = Font:getFace("infofont", 14)
    local probe = TextBoxWidget:new{
        text  = label_text,
        face  = face,
        bold  = true,
        width = label_w_avail,
    }
    local content_h = probe:getSize().h
    probe:free()
    local fits      = content_h <= label_h_avail
    local label_h   = fits and content_h or label_h_avail
    local label_widget = TextBoxWidget:new{
        text                          = label_text,
        face                          = face,
        bold                          = true,
        fgcolor                       = Blitbuffer.COLOR_BLACK,
        bgcolor                       = CARDBOARD,
        width                         = label_w_avail,
        alignment                     = "center",
        height                        = label_h,
        height_overflow_show_ellipsis = not fits,
    }
    local label_centered = CenterContainer:new{
        dimen = Geom:new{ w = card_w, h = label_h_avail },
        label_widget,
    }
    local label_positioned = FrameContainer:new{
        bordersize  = 0,
        padding     = 0,
        padding_top = label_top,
        label_centered,
    }

    self[1] = OverlapGroup:new{
        dimen = self.dimen,
        book_positioned,       -- 1: book cover, inset within card
        magazine,              -- 2: cardboard front (covers book bottom)
        label_positioned,      -- 3: folder name centred on cardboard
    }
    self.ges_events = {
        Tap  = { GestureRange:new{ ges = "tap",  range = self.dimen } },
        Hold = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
end

function FolderStack:onTap()
    if self.on_tap then self.on_tap(self.folder) end
    return true
end
function FolderStack:onHold()
    if self.on_hold then self.on_hold(self.folder) end
    return true
end

return FolderStack
