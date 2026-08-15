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
local BookshelfSettings = require("lib/bookshelf_settings_store")
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
    -- display_mode: how this tile draws itself, already resolved by the
    -- caller (chip override, else the library default). Supplied rather than
    -- read here because the tile has no idea which chip it belongs to, and
    -- that is now the question that decides this. nil falls back to the
    -- library default, which is what a caller with no chip means.
    display_mode     = nil,
}

function SeriesStack:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    local books = self.series and self.series.books
    local front = books and books[1]
    local stack_name = self.series and self.series.series_name or ""
    -- How this tile draws itself (bookshelf_stack_display), resolved by the
    -- caller from the active chip's override or the library default. DIVIDER
    -- reproduces the shipped tile exactly.
    local StackDisplay = require("lib/bookshelf_stack_display")
    -- Still needed below: ImageSource looks a custom stack image up by kind.
    local stack_kind = self.series and self.series.kind
        -- Legacy series groups (built before kinds were carried on the
        -- shape) reach here with .books but no .kind. Default them to
        -- "series" so ImageSource has something to look up under.
        or (self.series and self.series.books and "series" or nil)
    local display_mode = StackDisplay.resolve(self.display_mode)
    -- Text mode wants no artwork, so the lookups below are skipped entirely
    -- rather than rendered and hidden: on a genre or format tile the front
    -- book's cover is noise, and this also skips its custom-image disk probe.
    local want_art = not StackDisplay.isTextOnly(display_mode)
    local show_cardboard = StackDisplay.showsCardboard(display_mode)
    -- The pile depicts the stack: #books drives how many layers it draws, so a
    -- two-book series reads as two books rather than as a generic pile.
    local pile_books = books and #books or nil
    local pile_inset = StackDisplay.pileInset(display_mode, pile_books)
    -- Ribbon gives up an overhang each side so its band can run past the
    -- cover without painting outside the tile (see StackDisplay.ribbonInset).
    local ribbon_inset = StackDisplay.ribbonInset(display_mode)
    local ribbon_x     = ribbon_inset > 0 and math.floor(ribbon_inset / 2) or 0
    local art_w = self.width - pile_inset - ribbon_inset
    -- Shortened on both axes: the layers show past the cover's right and
    -- bottom edges, which is what makes them read as separate objects rather
    -- than as part of the cover's own frame.
    local art_h = self.height - pile_inset
    -- True-aspect covers: the SLOT is reserved at COVER_ASPECT_CAP, but a
    -- cover must render at its OWN aspect inside it. The cardboard modes get
    -- that from cover_align_top + cover_floor (the tab masks the leftover);
    -- the bare modes have no cardboard, so they size the CARD itself, exactly
    -- as shelf_row does for a book. Without this the card kept the capped
    -- height and the cover stretched to fill it -- tall and narrow on device.
    local card_y = 0
    if BookshelfSettings.isTrue("true_cover_aspect") and not show_cardboard then
        local _front = front
        if _front then
            art_h = SpineWidget.trueAspectBoxHeight(art_w, _front, art_h)
        end
    end
    -- BOTTOM-ANCHOR the card + pile within the slot. A true-aspect cover is
    -- shorter than its slot, and left at the top it floats -- covers jumping
    -- up and down row to row instead of sitting on one shelf line, which is
    -- the whole point of the true-aspect layout (shelf_row does the same for
    -- books with a leading span).
    --
    -- The offset puts the PILE's bottom on the slot bottom, which is where a
    -- non-stacked cover's drop shadow ends -- so a stack and a plain cover
    -- share a baseline rather than the stack hanging below it.
    card_y = self.height - art_h - pile_inset
    if card_y < 0 then card_y = 0 end

    -- Custom stack image (#70 extension). Same precedence rules as
    -- FolderStack: explicit user override → image-library auto-
    -- discovery → no image. When found, the stack renders identically
    -- to a book cover (synthetic book carrying our pre-loaded bb), no
    -- cardboard overlay. The cover_bb is owned by ImageSource's
    -- cache; pass cover_bb_disposable=false so SpineWidget doesn't
    -- free it on teardown.
    local custom_image_path
    if want_art and stack_kind and stack_name ~= "" then
        custom_image_path = ImageSource.resolveStackImage(stack_kind, stack_name)
    end

    -- Built up front so cover_floor -- the slot-local y where the cardboard
    -- body begins -- is known before the representative cover renders.
    local folder_widget, label_widget, cover_floor = FolderCard.build{
        width  = art_w,
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
                width               = art_w,
                height              = art_h,
                cover_fill          = true,
                is_selected         = self.is_selected,
                is_bulk_selected    = self.is_bulk_selected,
            }
        else
            custom_image_path = nil
        end
    end
    if not book_widget and display_mode == StackDisplay.COLLAGE and books then
        local paths = StackDisplay.collageCovers(books, 4)
        local bb = StackDisplay.collageBB(paths, art_w - FolderCard.SHADOW_OFFSET,
                                          self.height - FolderCard.SHADOW_OFFSET)
        if bb then
            -- disposable = true: unlike the ImageSource path, this buffer was
            -- composed for this widget alone and nothing else references it.
            book_widget = SpineWidget:new{
                book = { title = stack_name, has_cover = true },
                cover_bb            = bb,
                cover_bb_disposable = true,
                width               = art_w,
                height              = art_h,
                cover_fill          = true,
                is_selected         = self.is_selected,
                is_bulk_selected    = self.is_bulk_selected,
            }
        end
    end
    if not book_widget then
        if want_art and front then
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
                width            = art_w,
                height           = art_h,
                -- ONLY under the cardboard. cover_align_top top-anchors a
                -- shorter-than-box cover and background-fills the remainder,
                -- and that remainder is invisible only because the cardboard
                -- sits over it (see TopAlignedCoverBox in spine_widget, and
                -- folder_card's cover_floor). In the modes that draw no
                -- cardboard, the fill is exposed as a white bar across the
                -- bottom of the cover, inside its border -- which is what a
                -- squarer cover looked like on device. Without these the
                -- cover renders as an ordinary book cover, which is what a
                -- bare tile should look like anyway.
                cover_align_top  = show_cardboard or nil,
                min_cover_h      = show_cardboard and cover_floor or nil,
                is_selected      = self.is_selected,
                is_bulk_selected = self.is_bulk_selected,
            }
        else
            -- Empty group: SpineWidget's fallback path with the group name
            -- as the title (analogous to FolderStack's empty-folder path).
            book_widget = SpineWidget:new{
                book             = { title = stack_name },
                -- Text style reads as a button, not a book (see flat_card).
                flat_card        = StackDisplay.isTextOnly(display_mode),
                width            = art_w,
                height           = art_h,
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
    --
    -- That reasoning is why DIVIDER is the default and the only mode drawing
    -- the cardboard. The other modes are a trade the user makes per kind:
    -- stack and collage swap the cardboard for a different group cue, none
    -- drops both. On an author or genre tile the name is doing the work the
    -- artwork cannot, which is what Text mode is for.
    local children = {}
    if display_mode == StackDisplay.STACK then
        local pile = StackDisplay.pileWidget(art_w + pile_inset, art_h + pile_inset, pile_books)
        if pile then
            pile.overlap_offset = { 0, card_y }
            children[#children + 1] = pile
        end
    end
    if card_y > 0 or ribbon_x > 0 then
        book_widget.overlap_offset = { ribbon_x, card_y }
    end
    children[#children + 1] = book_widget
    if show_cardboard then
        children[#children + 1] = folder_widget
        children[#children + 1] = label_widget
    end
    -- The band, over the cover and past both its edges. Sized from the COVER
    -- (art_w), offset back to the tile's own left edge so the overhang is
    -- symmetric, and stacked after the cover so it paints on top of it.
    if display_mode == StackDisplay.RIBBON then
        local band, band_y = StackDisplay.ribbonWidget(art_w, art_h, stack_name)
        if band then
            band.overlap_offset = { 0, card_y + band_y }
            children[#children + 1] = band
        end
    end
    -- show_count_badge: caller-controlled (shelf_row reads
    -- stack_count_badge_mode and decides per-kind). nil/true keeps
    -- legacy behaviour (always show); false suppresses.
    local show_badge = (self.show_count_badge ~= false)
    if show_badge and books and #books > 0 then
        local badge = CountBadge.render(#books, self.selected_count, self.finished_count, self.finished_total)
        if badge then
            local badge_w = badge:getSize().w
            -- Anchored to the FRONT COVER's right edge, not the slot's.
            -- They are the same in every mode but stack, where the cover is
            -- narrower than the slot to make room for the pile -- so a
            -- slot-anchored badge drifted off the cover and sat over the
            -- layers behind it, cutting through the very effect it was
            -- floating above. Still clamped to the slot so it cannot overflow.
            local cover_right_x = ribbon_x + art_w - FolderCard.SHADOW_OFFSET
            -- How far the badge hangs PAST the cover's right edge. Normally
            -- half its width, which is the shipped look. Over a pile that is
            -- too far: the layers behind are one step apart, so a half-badge
            -- overhang covers two of them and the pile reads as one thick edge
            -- instead of separate books. Clamped to a single step, so the
            -- badge sits over the first layer and no further.
            local overhang = math.ceil(badge_w / 2)
            if pile_inset > 0 then
                overhang = math.min(overhang, StackDisplay.pileStep())
            end
            local badge_x = math.max(0, math.min(self.width - badge_w,
                                                 cover_right_x + overhang - badge_w))
            -- Anchored to the CARD's top, not the slot's. With true aspect the
            -- card is shorter than its slot and bottom-anchored, so a
            -- slot-anchored badge floated above the cover by however much
            -- shorter the cover was -- and by a different amount per tile.
            badge.overlap_offset = { badge_x, card_y - FolderCard.SHADOW_OFFSET }
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
