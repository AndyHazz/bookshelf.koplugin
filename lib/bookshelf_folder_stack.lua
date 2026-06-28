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
local FrameContainer = require("ui/widget/container/framecontainer")
local OverlapGroup   = require("ui/widget/overlapgroup")
local TextWidget     = require("ui/widget/textwidget")
local Widget         = require("ui/widget/widget")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local Size           = require("ui/size")
local Font           = require("ui/font")
local Blitbuffer     = require("ffi/blitbuffer")
local Screen         = require("device").screen
local BookshelfSettings = require("lib/bookshelf_settings_store")
local SpineWidget    = require("lib/bookshelf_spine_widget")
local FolderCard     = require("lib/bookshelf_folder_card")
local CountBadge     = require("lib/bookshelf_count_badge")
local ImageSource    = require("lib/bookshelf_image_source")

local FADED_FINISHED_FOLDER_AMOUNT = 0.5

local FadeOverlay = Widget:extend{
    width  = nil,
    height = nil,
    amount = nil,
}

function FadeOverlay:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
end

function FadeOverlay:paintTo(bb, x, y)
    bb:lightenRect(x, y, self.width, self.height,
                   self.amount or FADED_FINISHED_FOLDER_AMOUNT)
end

local function fadeFinishedFoldersEnabled()
    return BookshelfSettings.isTrue("fade_finished_folders")
end

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
    -- all_read/all_read_total: supplied even when count badges are hidden,
    -- so the faded-folder overlay can remain independent of badge display.
    all_read         = nil,
    all_read_total   = nil,
}

function FolderStack:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }

    -- Custom folder image (#70). Resolves to either an explicit user
    -- override (set via long-press) or an auto-detected cover.jpg /
    -- folder.jpg at the folder root. When present, the folder
    -- renders via a synthetic book cover while still keeping the
    -- cardboard overlay and folder-name label below it. Auto-detect short
    -- circuits to nil for empty / missing folders so the empty-
    -- folder branch below still triggers when appropriate.
    local custom_image_path
    if self.folder and self.folder.path then
        custom_image_path = ImageSource.resolveFolderImage(self.folder.path)
    end

    -- Book layer: full-slot SpineWidget. Its internal drop shadow paints
    -- the slot's right+bottom L-strip; because the folder card shares
    -- the book card's right and bottom edges, that shadow doubles as
    -- the folder's drop shadow (no separate folder-shaped shadow layer).
    local book_widget
    if custom_image_path then
        -- Synthetic book: no filepath so SpineWidget skips the
        -- ScaledCoverCache lookup (which is keyed on the BOOK file,
        -- not our image); we pre-load the bb via ImageSource's own
        -- cache and hand it in via the cover_bb override. has_cover
        -- gates the cover render path (line ~429 of spine_widget).
        -- cover_bb_disposable=false: ImageSource owns lifetime, the
        -- spine must not free the bb on widget teardown or the next
        -- paint that hits the same cache key crashes.
        local slot_w = self.width - FolderCard.SHADOW_OFFSET
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
                width               = self.width,
                height              = self.height,
                cover_fill          = true,
                is_selected         = self.is_selected,
                is_bulk_selected    = self.is_bulk_selected,
                suppress_badges     = true,
            }
        else
            -- Load failed (corrupt file, decoder error): fall back to
            -- the regular folder-card rendering rather than rendering
            -- a blank slot. Marker so the cardboard branch below
            -- still runs.
            custom_image_path = nil
        end
    end
    if not book_widget then
        if self.folder and self.folder.first_book then
            book_widget = SpineWidget:new{
                book             = self.folder.first_book,
                width            = self.width,
                height           = self.height,
                cover_fill       = true,
                is_selected      = self.is_selected,
                is_bulk_selected = self.is_bulk_selected,
                suppress_badges  = true,
            }
        else
            -- Empty folder: SpineWidget's fallback path with the folder's
            -- label as the title so the "?" placeholder reads correctly.
            book_widget = SpineWidget:new{
                book             = { title = self.folder and self.folder.label or "" },
                width            = self.width,
                height           = self.height,
                is_selected      = self.is_selected,
                is_bulk_selected = self.is_bulk_selected,
                suppress_badges  = true,
            }
        end
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
    -- title text beneath).
    local folder_widget, label_widget = FolderCard.build{
        width  = self.width,
        height = self.height,
        label  = self.folder and self.folder.label or "",
    }
    local children = {
        book_widget,           -- 0: image (or book) + drop shadow
        folder_widget,         -- 1: cardboard front
        label_widget,          -- 2: folder name on body
    }

    local book_count = tonumber(self.book_count)
        or (self.folder and tonumber(self.folder.book_count))
    local unread_count = self.folder and tonumber(self.folder.unread_count)
    local all_read_count = book_count
        or tonumber(self.all_read_total)
        or (self.folder and tonumber(self.folder.all_read_total))
    local all_read = self.all_read or (self.folder and self.folder.all_read)
    if all_read and all_read_count and all_read_count > 0 and fadeFinishedFoldersEnabled() then
        children[#children + 1] = FadeOverlay:new{
            width  = self.width - FolderCard.SHADOW_OFFSET,
            height = self.height - FolderCard.SHADOW_OFFSET,
            amount = FADED_FINISHED_FOLDER_AMOUNT,
        }
    end

    if book_count and book_count > 0 then
        local badge = CountBadge.render(
            book_count,
            self.selected_count,
            self.finished_count,
            self.finished_total)
        if badge then
            local badge_w = badge:getSize().w
            local cover_right_x = self.width - FolderCard.SHADOW_OFFSET
            local badge_x = math.max(0, math.min(self.width - badge_w,
                                                 cover_right_x - math.floor(badge_w / 2)))
            badge.overlap_offset = { badge_x, -FolderCard.SHADOW_OFFSET }
            children[#children + 1] = badge
        end
    end

    if unread_count and unread_count > 0 and not self.selected_count then
        local badge = CountBadge.render(unread_count)
        if badge then
            badge.overlap_offset = { 0, -FolderCard.SHADOW_OFFSET }
            children[#children + 1] = badge
        end
    elseif all_read and all_read_count and all_read_count > 0 and not self.selected_count then
        local card_w = self.width - FolderCard.SHADOW_OFFSET
        local card_h = self.height - FolderCard.SHADOW_OFFSET
        local glyph = SpineWidget.newStatusGlyphOverlay{
            state  = "read",
            card_w = card_w,
            card_h = card_h,
        }
        if glyph then
            children[#children + 1] = glyph
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
