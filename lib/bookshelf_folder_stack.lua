-- bookshelf_folder_stack.lua
-- Renders a folder slot: the first book inside the folder fills the slot
-- like a regular spine; a compact cardboard "folder card" (tab + body)
-- sits on top of the book's bottom portion, label centred on the body.
-- The book's top peeks above the folder body and to the right of the
-- tab as visual evidence of the folder's contents.
--
-- Composition: see folder_card.lua for the cardboard primitive. This
-- module just adds the SpineWidget for the first book and the tap/hold
-- input handling.

local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup   = require("ui/widget/overlapgroup")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local SpineWidget    = require("lib/bookshelf_spine_widget")
local BookshelfSettings = require("lib/bookshelf_settings_store")
local FolderCard     = require("lib/bookshelf_folder_card")
local CountBadge     = require("lib/bookshelf_count_badge")
local ImageSource    = require("lib/bookshelf_image_source")

local FolderStack = InputContainer:extend{
    folder      = nil,    -- { path, label, first_book }
    width       = nil,
    height      = nil,
    on_tap      = nil,
    on_hold     = nil,
    is_selected      = false,
    is_bulk_selected = false,
    -- book_count: total recursive books under this folder. nil
    -- suppresses the badge entirely. shelf_row supplies it (or not)
    -- based on the stack_count_badge_mode setting.
    book_count       = nil,
    -- selected_count: K when 0 < K < book_count → renders "K/book_count"
    -- instead of "×book_count" (Venn-diagram partial-selection state).
    selected_count   = nil,
    -- finished_count: out-of-selection format. Renders "F/N" when set
    -- and selected_count is nil. Driven by
    -- stack_count_badge_format = "finished_total".
    finished_count   = nil,
    -- finished_total: unfiltered total for the F/N denominator. Falls
    -- back to book_count when omitted. Separate field so F/N stays
    -- stack-wide even when book_count reflects a filtered count.
    finished_total   = nil,
    -- plain_if_placeholder: when this tile has no cover and falls back to the
    -- label-placeholder card, the placeholder already shows the label as its
    -- title -- so the cardboard tab and the label band below just repeat it.
    -- Set by callers whose tiles resolve on a tap (OPDS nav), where the folder
    -- affordance is redundant: drop the overlay and render the bare card. When
    -- the tile HAS a cover the overlay + label stay (the title isn't otherwise
    -- shown).
    plain_if_placeholder = false,
    -- book_paths: the folder's member filepaths, supplied by shelf_row when
    -- something needed the walk. Only the collage uses them; every other mode
    -- renders from first_book alone.
    book_paths       = nil,
    -- display_mode: how this tile draws itself, already resolved by the
    -- caller (chip override, else the library default). Supplied rather than
    -- read here because the tile has no idea which chip it belongs to, and
    -- that is now the question that decides this. nil falls back to the
    -- library default, which is what a caller that has no chip means.
    display_mode     = nil,
}

function FolderStack:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }

    -- How this tile draws itself (bookshelf_stack_display), resolved by the
    -- caller from the active chip's override or the library default. DIVIDER
    -- reproduces the shipped tile exactly.
    local StackDisplay = require("lib/bookshelf_stack_display")
    local display_mode = StackDisplay.resolve(self.display_mode)
    -- Text mode wants no artwork at all, so it takes the placeholder branch
    -- below regardless of what covers exist. Suppressing the lookups (rather
    -- than rendering and hiding) also skips the custom-image disk probe and
    -- the cover load, which is the whole point on a kind whose artwork was
    -- judged to be noise.
    local want_art = not StackDisplay.isTextOnly(display_mode)
    local show_cardboard = StackDisplay.showsCardboard(display_mode)
    -- Stack mode shrinks the cover so the layers behind it protrude past its
    -- right and bottom edges, following the drop shadow. The cover itself stays
    -- at the slot origin. Zero in every other mode, so the arithmetic below is
    -- unconditional.
    -- book_count is the folder's recursive total, but shelf_row only computes
    -- it when the count badge needs it -- nil here means "not asked", which
    -- pileLayers treats as a full pile rather than as an empty folder.
    -- Will this tile take the plain-placeholder path below? A coverless
    -- tap-resolving tile (an OPDS nav entry) renders as the bare label card
    -- and draws NO pile and NO ribbon -- so it must not reserve room for them
    -- either. Reserving it anyway shrank the card and left the reserved strip
    -- empty at the bottom: a small cover with a gap under it before the label.
    --
    -- Decided here rather than at the plain branch itself because the insets
    -- feed the whole size arithmetic, and by the time is_label_placeholder is
    -- known the card has already been built at the reduced size.
    local plain_ahead = self.plain_if_placeholder
                        and not (self.folder and self.folder.first_book)
    local pile_inset = plain_ahead and 0
                       or StackDisplay.pileInset(display_mode, self.book_count)
    -- Ribbon gives up an overhang each side so its band can run past the
    -- cover without painting outside the tile (see StackDisplay.ribbonInset).
    local ribbon_inset = plain_ahead and 0
                         or StackDisplay.ribbonInset(display_mode)
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
        local _front = self.folder and self.folder.first_book
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

    -- Custom folder image (#70). Resolves to either an explicit user
    -- override (set via long-press) or an auto-detected cover.jpg /
    -- folder.jpg at the folder root. When present, the folder
    -- renders identically to a book cover -- no cardboard overlay,
    -- no folder-name label on the card -- so a themed library can
    -- present sections as first-class artwork. Auto-detect short
    -- circuits to nil for empty / missing folders so the empty-
    -- folder branch below still triggers when appropriate.
    local custom_image_path
    if want_art and self.folder and self.folder.path then
        custom_image_path = ImageSource.resolveFolderImage(self.folder.path)
    end

    -- Built up front (not just when composing children below) so cover_floor
    -- -- the slot-local y where the cardboard body begins -- is known
    -- before the book cover renders. Always safe: label/geometry depend
    -- only on width + label text, not on what's drawn underneath.
    local folder_widget, label_widget, cover_floor = FolderCard.build{
        width  = art_w,
        height = self.height,
        label  = self.folder and self.folder.label or "",
    }

    -- Book layer: full-slot SpineWidget. Its internal drop shadow paints
    -- the slot's right+bottom L-strip; because the folder card shares
    -- the book card's right and bottom edges, that shadow doubles as
    -- the folder's drop shadow (no separate folder-shaped shadow layer).
    local book_widget
    -- Set when we render the label-only placeholder (no cover, no first_book):
    -- the card itself carries the label as its title.
    local is_label_placeholder = false
    if custom_image_path then
        -- Synthetic book: no filepath so SpineWidget skips the
        -- ScaledCoverCache lookup (which is keyed on the BOOK file,
        -- not our image); we pre-load the bb via ImageSource's own
        -- cache and hand it in via the cover_bb override. has_cover
        -- gates the cover render path (line ~429 of spine_widget).
        -- cover_bb_disposable=false: ImageSource owns lifetime, the
        -- spine must not free the bb on widget teardown or the next
        -- paint that hits the same cache key crashes.
        local slot_w = art_w - FolderCard.SHADOW_OFFSET
        local slot_h = self.height - FolderCard.SHADOW_OFFSET
        local bb = ImageSource.loadImage(custom_image_path, slot_w, slot_h)
        if bb then
            book_widget = SpineWidget:new{
                book = {
                    title     = self.folder and self.folder.label or "",
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
            -- Load failed (corrupt file, decoder error): fall back to
            -- the regular folder-card rendering rather than rendering
            -- a blank slot. Marker so the cardboard branch below
            -- still runs.
            custom_image_path = nil
        end
    end
    if not book_widget and display_mode == StackDisplay.COLLAGE
            and type(self.book_paths) == "table" then
        -- Folder members arrive as bare PATH STRINGS from getFolderBookPaths,
        -- where a stack's arrive as records -- so wrap them into the shape
        -- collageCovers reads. Same grid, same fetch, same buffer discipline.
        local members = {}
        for _i, fp in ipairs(self.book_paths) do
            if #members >= 4 then break end
            if type(fp) == "string" and fp ~= "" then
                members[#members + 1] = { filepath = fp }
            end
        end
        local paths = StackDisplay.collageCovers(members, 4)
        local bb = StackDisplay.collageBB(paths, art_w - FolderCard.SHADOW_OFFSET,
                                          art_h - FolderCard.SHADOW_OFFSET)
        if bb then
            book_widget = SpineWidget:new{
                book = { title = self.folder and self.folder.label or "",
                         has_cover = true },
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
        if want_art and self.folder and self.folder.first_book then
            -- True-aspect, unconditionally (not gated on the true_cover_aspect
            -- setting): the cardboard tab+label already masks the bottom of
            -- this slot, so an undistorted cover only ever gives up pixels
            -- that were hidden anyway. The card itself stays full slot size
            -- (height = self.height, unchanged) so its shadow/border/corners
            -- keep lining up with the folder cardboard; only the cover image
            -- inside renders at its own aspect, top-anchored (cover_align_top),
            -- floored at cover_floor so it always reaches under the cardboard.
            book_widget = SpineWidget:new{
                book             = self.folder.first_book,
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
            -- Empty folder: SpineWidget's fallback path with the folder's
            -- label as the title so the "?" placeholder reads correctly. A
            -- remote nav tile may also carry an author (Gutenberg puts it in
            -- the list entry), shown on the placeholder so the tile is
            -- identifiable before it is opened.
            is_label_placeholder = true
            book_widget = SpineWidget:new{
                -- Text style reads as a button, not a book (see flat_card).
                flat_card        = StackDisplay.isTextOnly(display_mode),
                book             = { title  = self.folder and self.folder.label or "",
                                     author = self.folder and self.folder.author or nil,
                                     -- Divider motif on the placeholder card:
                                     -- OPDS nav tiles show the feed's icon (or
                                     -- a drill chevron), facet tiles a filter
                                     -- glyph, books keep the diamond.
                                     is_opds_nav = self.folder and self.folder.is_opds_nav or nil,
                                     is_facet    = self.folder and self.folder.is_facet or nil,
                                     opds_icon   = self.folder and self.folder.opds
                                                   and self.folder.opds.icon or nil },
                width            = art_w,
                height           = art_h,
                is_selected      = self.is_selected,
                is_bulk_selected = self.is_bulk_selected,
            }
        end
    end

    -- Redundant-overlay case: a tap-resolving tile (OPDS nav) with no cover,
    -- or a kind set to Text (whose card IS the label). The placeholder card
    -- already shows the label as its title, so skip the cardboard tab and the
    -- repeated label band and present the bare card.
    if StackDisplay.isTextOnly(display_mode)
            or (self.plain_if_placeholder and is_label_placeholder) then
        local children = { book_widget }
        children.dimen = self.dimen
        self[1] = OverlapGroup:new(children)
        self.ges_events = {
            Tap  = { GestureRange:new{ ges = "tap",  range = self.dimen } },
            Hold = { GestureRange:new{ ges = "hold", range = self.dimen } },
        }
        return
    end

    -- Cardboard overlay stays on every render path (#70 follow-up).
    -- Earlier draft dropped it when a custom image was set, on the
    -- theory that the image alone would be enough to identify the
    -- folder. In practice this loses the visual cue that the slot
    -- represents a group rather than a single book, and a folder
    -- whose chosen image doesn't include the folder name becomes
    -- unidentifiable. Keep the cardboard tab + label in both
    -- branches so the artwork shows above and the user sees the
    -- folder name below; matches what BOOK rows do (cover plus
    -- title text beneath). (Built earlier, above, so cover_floor is
    -- available before the book cover renders.)
    --
    -- That reasoning is why DIVIDER is the default and why it is the only mode
    -- that draws the cardboard. The other modes are a deliberate trade the
    -- user makes per kind: stack and collage swap the cardboard for a
    -- different group cue and give up the name, none gives up both. Losing the
    -- name matters most on author and genre tiles, where the front book's
    -- cover says nothing about the group -- which is exactly why Text exists.
    local children = {}
    -- Pile first so the front cover paints over it, leaving only the left
    -- strip of each layer showing.
    if display_mode == StackDisplay.STACK then
        local pile = StackDisplay.pileWidget(art_w + pile_inset, art_h + pile_inset, self.book_count)
        if pile then
            pile.overlap_offset = { 0, card_y }
            children[#children + 1] = pile
        end
        -- The cover was built at art_w; push it right so the layers sit to
        -- its left rather than under it.
    end
    if card_y > 0 or ribbon_x > 0 then
        book_widget.overlap_offset = { ribbon_x, card_y }
    end
    children[#children + 1] = book_widget      -- image (or book) + drop shadow
    if show_cardboard then
        children[#children + 1] = folder_widget   -- cardboard front
        children[#children + 1] = label_widget    -- folder name on body
    end
    -- The band, over the cover and past both its edges. Sized from the COVER
    -- (art_w), offset back to the tile's own left edge so the overhang is
    -- symmetric, and stacked after the cover so it paints on top of it.
    if display_mode == StackDisplay.RIBBON then
        local label = self.folder and (self.folder.label or self.folder.name)
        local band, band_y = StackDisplay.ribbonWidget(art_w, art_h, label)
        if band then
            band.overlap_offset = { 0, card_y + band_y }
            children[#children + 1] = band
        end
    end
    -- Count badge: same anchor as SeriesStack so a row mixing folders
    -- and group stacks reads with a consistent visual rhythm.
    if self.book_count and self.book_count > 0 then
        local badge = CountBadge.render(self.book_count, self.selected_count, self.finished_count, self.finished_total)
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

function FolderStack:onTap()
    if self.on_tap then self.on_tap(self.folder) end
    return true
end
function FolderStack:onHold()
    if self.on_hold then self.on_hold(self.folder) end
    return true
end

return FolderStack
