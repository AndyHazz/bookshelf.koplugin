-- bookshelf_snug_scroll.lua
-- A ScrollableContainer whose vertical scrollbar sits flush against the right
-- edge, drawn as a rail rather than a box.
--
-- The stock container reserves 3x the bar width (gap | bar | gap) and paints
-- the bar as a bordered box, so inside a framed dialog it floated in a margin
-- with a top, right and bottom edge of its own doubling the frame's. Here the
-- content butts the bar, the bar butts the frame, and the bar is one rule down
-- its LEFT side for the full height of the scroll area, with the thumb filling
-- from that rule to the edge: whatever sits above, beside and below it (a
-- title's rule, the frame's border, a button row's rule) is its other three
-- edges (maintainer: "as if the scroll bar had no top, right or bottom border
-- of its own, just a left border running top to bottom").
--
-- Used by the book detail modal's scrolling tabs and the Extract page counts
-- dialog. LTR only -- RTL falls back to the stock layout and stock bar.

local Geom                = require("ui/geometry")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")

-- A shade lighter than the rule and the frame it sits against, so the thumb
-- reads as the thumb and not as more border (maintainer).
local ok_bb, Blitbuffer = pcall(require, "ffi/blitbuffer")
local THUMB = ok_bb and Blitbuffer and Blitbuffer.COLOR_DARK_GRAY or nil

-- widen(w) -> a caller's bar width, a couple of pixels wider: the stock widths
-- read as a line beside the frame's border rather than as a bar.
local function widen(w)
    local ok_d, Device = pcall(require, "device")
    local extra = (ok_d and Device and Device.screen and Device.screen.scaleBySize)
                  and Device.screen:scaleBySize(1.5) or 2
    return (type(w) == "number" and w or 0) + extra
end

local SnugScroll = ScrollableContainer:extend{
    scroll_bar_width = widen(ScrollableContainer.scroll_bar_width),
}
SnugScroll.widen = widen

local function mirrored()
    local ok, BD = pcall(require, "ui/bidi")
    return ok and BD and BD.mirroredUILayout() or false
end

-- The rail: a left rule the bar's full height, and the thumb from it to the
-- right edge. Keeps the stock bar's touch area, so tap / hold / pan to scroll
-- behave as before.
local function railPaint(bar, bb, x, y)
    if not bar.enable then return end
    bar.touch_dimen = Geom:new{
        x = x - bar.extra_touch_on_side,
        y = y,
        w = bar.width + 2 * bar.extra_touch_on_side,
        h = bar.height,
    }
    local rule = bar.bordersize
    bb:paintRect(x, y, rule, bar.height, bar.bordercolor)
    local th = math.max(math.floor((bar.high - bar.low) * bar.height + 0.5), bar.min_thumb_size)
    local ty = y + math.floor(bar.low * bar.height + 0.5)
    if ty + th > y + bar.height then ty = y + bar.height - th end
    bb:paintRect(x + rule, ty, bar.width - rule, th, THUMB or bar.rectcolor)
end
SnugScroll._railPaint = railPaint   -- for tests

function SnugScroll:initState()
    ScrollableContainer.initState(self)
    if not self._is_scrollable or mirrored() then return end
    if self._v_scroll_bar then
        self._crop_w = self.dimen.w - self.scroll_bar_width  -- content up to the bar
        self._v_scroll_bar.paintTo = railPaint
    end
    -- The parent decided horizontal overflow against its 3x reserve, so content
    -- sized to the snug crop still triggered a spurious horizontal bar (and ate
    -- height). Re-decide it against dimen.w itself, not the narrower _crop_w:
    -- callers (section heading bars, pill-row frames) build their backgrounds
    -- to fill dimen.w exactly, with the scrollbar meant to overlay their
    -- trailing edge rather than reserve extra width beyond it -- so content
    -- flush with dimen.w is "fits", not overflow. Comparing to _crop_w here
    -- flagged that flush fill as a permanent scroll_bar_width of bogus
    -- horizontal overflow on any tab tall enough to need vertical scrolling
    -- (invisible on short tabs, since _is_scrollable is false there).
    local content_w = self[1]:getSize().w
    self._max_scroll_offset_x = math.max(0, content_w - self.dimen.w)
    if self._max_scroll_offset_x == 0 and self._h_scroll_bar then
        self._h_scroll_bar = nil
        self._crop_h = self.dimen.h
    end
end

function SnugScroll:paintTo(bb, x, y)
    if self._is_scrollable == nil then self:initState() end
    local real_w = self.dimen.w
    -- The parent paints the v-bar at dimen.w - 2*bar_width; inflating dimen.w by
    -- one bar width during paint shifts it to dimen.w - bar_width (flush right).
    if self._v_scroll_bar and not mirrored() then
        self.dimen.w = real_w + self.scroll_bar_width
    end
    ScrollableContainer.paintTo(self, bb, x, y)
    self.dimen.w = real_w
end

-- The width a caller should take off its content to leave room for the bar.
function SnugScroll:getScrollbarWidth()
    return self.scroll_bar_width
end

return SnugScroll
