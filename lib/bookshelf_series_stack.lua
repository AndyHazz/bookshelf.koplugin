-- bookshelf_series_stack.lua
-- Renders a series/author/genre/tag slot: a single representative book
-- cover with a compact folder card below carrying the group's name, and
-- a count badge ("×N") on the cover's top-right edge to convey "this
-- represents N books".
--
-- The previous design rendered three diagonally-offset book covers
-- (Layer1/2/3) to imply "stack" plus a black series-name band. The
-- back layers were never visually distinguishable from the front
-- (small offsets, identical artwork in single-book series), and they
-- forced a defensive `safeCopy(bb)` of the cover bb to avoid a
-- use-after-free when three SpineWidgets shared one bb. Dropping
-- them removes both the per-paint copy and that whole class of bug.
--
-- The folder card matches FolderStack exactly via folder_card.lua.
-- The count badge is the only thing that distinguishes this widget
-- visually from FolderStack.

local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup   = require("ui/widget/overlapgroup")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local SpineWidget    = require("lib/bookshelf_spine_widget")
local FolderCard     = require("lib/bookshelf_folder_card")
local CountBadge     = require("lib/bookshelf_count_badge")
local ImageSource    = require("lib/bookshelf_image_source")

local SeriesStack = InputContainer:extend{
    series      = nil,    -- { series_name, books[] }
    width       = nil,
    height      = nil,
    on_tap      = nil,
    on_hold     = nil,
    is_selected      = false,
    is_bulk_selected = false,
    -- selected_count: nil (default) renders "×N"; an integer K renders
    -- "K/N" to surface the Venn-diagram partial state (set by shelf_row
    -- only when 0 < K < N and selection mode is active).
    selected_count   = nil,
    -- finished_count: out-of-selection-mode badge override. Renders
    -- "F/N" when set and selected_count is nil. Set by shelf_row only
    -- when stack_count_badge_format = "finished_total".
    finished_count   = nil,
    -- finished_total: unfiltered stack size (the N in F/N). Defaults
    -- to #books when omitted. Provided so F/N stays stack-wide even
    -- when the chip is filtered (visible #books is filtered count).
    finished_total   = nil,
    -- show_count_badge: false suppresses the badge entirely (the
    -- stack_count_badge_mode setting routes this from shelf_row).
    -- Default true preserves legacy behaviour for any direct callers.
    show_count_badge = true,
}

function SeriesStack:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    local books = self.series and self.series.books
    local front = books and books[1]
    local stack_name = self.series and self.series.series_name or ""
    local stack_kind = self.series and self.series.kind
        -- Legacy series groups (built before kinds were carried on the
        -- shape) reach here with .books but no .kind. Default them to
        -- "series" so ImageSource has something to look up under.
        or (self.series and self.series.books and "series" or nil)

    -- Custom stack image (#70 extension). Same precedence rules as
    -- FolderStack: explicit user override → image-library auto-
    -- discovery → no image. When found, the stack renders identically
    -- to a book cover (synthetic book carrying our pre-loaded bb), no
    -- cardboard overlay. The cover_bb is owned by ImageSource's
    -- cache; pass cover_bb_disposable=false so SpineWidget doesn't
    -- free it on teardown.
    local custom_image_path
    if stack_kind and stack_name ~= "" then
        custom_image_path = ImageSource.resolveStackImage(stack_kind, stack_name)
    end

    -- Built up front so cover_floor -- the slot-local y where the cardboard
    -- body begins -- is known before the representative cover renders.
    local folder_widget, label_widget, cover_floor = FolderCard.build{
        width  = self.width,
        height = self.height,
        label  = stack_name,
    }

    -- Book layer: full-slot SpineWidget for the representative cover.
    local book_widget
    if custom_image_path then
        local slot_w = self.width - FolderCard.SHADOW_OFFSET
        local slot_h = self.height - FolderCard.SHADOW_OFFSET
        local bb = ImageSource.loadImage(custom_image_path, slot_w, slot_h)
        if bb then
            book_widget = SpineWidget:new{
                book = {
                    title     = stack_name,
                    has_cover = true,
                },
                cover_bb            = bb,
                cover_bb_disposable = false,
                width               = self.width,
                height              = self.height,
                cover_fill          = true,
                is_selected         = self.is_selected,
                is_bulk_selected    = self.is_bulk_selected,
            }
        else
            custom_image_path = nil
        end
    end
    if not book_widget then
        if front then
            -- True-aspect, unconditionally (mirrors FolderStack): the
            -- cardboard tab+label already masks the bottom of this slot, so
            -- an undistorted cover only ever gives up pixels that were
            -- hidden anyway. The card itself stays full slot size (height =
            -- self.height, unchanged) so its shadow/border/corners keep
            -- lining up with the folder cardboard; only the cover image
            -- inside renders at its own aspect, top-anchored
            -- (cover_align_top), floored at cover_floor so it always reaches
            -- under the cardboard.
            book_widget = SpineWidget:new{
                book             = front,
                width            = self.width,
                height           = self.height,
                cover_align_top  = true,
                min_cover_h      = cover_floor,
                is_selected      = self.is_selected,
                is_bulk_selected = self.is_bulk_selected,
            }
        else
            -- Empty group: SpineWidget's fallback path with the group name
            -- as the title (analogous to FolderStack's empty-folder path).
            book_widget = SpineWidget:new{
                book             = { title = stack_name },
                width            = self.width,
                height           = self.height,
                is_selected      = self.is_selected,
                is_bulk_selected = self.is_bulk_selected,
            }
        end
    end

    -- Count badge: white pill with "×N" on the cover's top-right corner,
    -- lifted by SHADOW_OFFSET so it sits proud of the cover top rather
    -- than flush against it. Positioned via overlap_offset (relative to
    -- the slot's top-left). The cover's right edge in slot coords is
    -- (slot_w - SHADOW_OFFSET); we centre the badge on that x so half
    -- hangs off the cover.
    -- Cardboard overlay stays on every render path (#70 follow-up,
    -- mirrors FolderStack). The label is the only thing distinguishing
    -- "this is an author named X" from "this is a single book whose
    -- cover happens to be a portrait of X", so the cardboard + name
    -- stays under both image and non-image branches. (Built earlier,
    -- above, so cover_floor is available before the cover renders.)
    local children = {
        book_widget,
        folder_widget,
        label_widget,
    }
    -- show_count_badge: caller-controlled (shelf_row reads
    -- stack_count_badge_mode and decides per-kind). nil/true keeps
    -- legacy behaviour (always show); false suppresses.
    local show_badge = (self.show_count_badge ~= false)
    if show_badge and books and #books > 0 then
        local badge = CountBadge.render(#books, self.selected_count, self.finished_count, self.finished_total)
        if badge then
            local badge_w = badge:getSize().w
            local cover_right_x = self.width - FolderCard.SHADOW_OFFSET
            local badge_x = math.max(0, math.min(self.width - badge_w,
                                                 cover_right_x - math.floor(badge_w / 2)))
            badge.overlap_offset = { badge_x, -FolderCard.SHADOW_OFFSET }
            children[#children + 1] = badge
        end
    end

    children.dimen = self.dimen
    self[1] = OverlapGroup:new(children)
    self.ges_events = {
        Tap  = { GestureRange:new{ ges = "tap",  range = self.dimen } },
        Hold = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
end

function SeriesStack:onTap()  if self.on_tap  then self.on_tap(self.series)  end; return true end
function SeriesStack:onHold() if self.on_hold then self.on_hold(self.series) end; return true end

return SeriesStack
