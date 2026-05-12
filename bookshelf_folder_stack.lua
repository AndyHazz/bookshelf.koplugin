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
local SpineWidget    = require("bookshelf_spine_widget")
local FolderCard     = require("bookshelf_folder_card")

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
    return G_reader_settings
       and type(G_reader_settings.isTrue) == "function"
       and G_reader_settings:isTrue("bookshelf_fade_finished_folders")
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

    -- Book layer: full-slot SpineWidget. Its internal drop shadow paints
    -- the slot's right+bottom L-strip; because the folder card shares
    -- the book card's right and bottom edges, that shadow doubles as
    -- the folder's drop shadow (no separate folder-shaped shadow layer).
    local book_widget
    if self.folder and self.folder.first_book then
        book_widget = SpineWidget:new{
            book            = self.folder.first_book,
            width           = self.width,
            height          = self.height,
            cover_fill      = true,
            is_selected     = self.is_selected,
            suppress_badges = true,
        }
    else
        -- Empty folder: SpineWidget's fallback path with the folder's
        -- label as the title so the "?" placeholder reads correctly.
        book_widget = SpineWidget:new{
            book            = { title = self.folder and self.folder.label or "" },
            width           = self.width,
            height          = self.height,
            is_selected     = self.is_selected,
            suppress_badges = true,
        }
    end

    local folder_widget, label_widget = FolderCard.build{
        width  = self.width,
        height = self.height,
        label  = self.folder and self.folder.label or "",
    }

    local children = {
        dimen = self.dimen,
        book_widget,           -- 0: book card + book's own drop shadow
        folder_widget,         -- 1: cardboard front (covers book bottom)
        label_widget,          -- 2: folder name on body
    }
    local book_count = self.folder and tonumber(self.folder.book_count)
    local unread_count = self.folder and tonumber(self.folder.unread_count)
    local all_read = self.folder and self.folder.all_read
    if all_read and book_count and book_count > 0 and fadeFinishedFoldersEnabled() then
        children[#children + 1] = FadeOverlay:new{
            width  = self.width - FolderCard.SHADOW_OFFSET,
            height = self.height - FolderCard.SHADOW_OFFSET,
            amount = FADED_FINISHED_FOLDER_AMOUNT,
        }
    end

    local function makeBadge(text, size)
        return FrameContainer:new{
            bordersize     = Size.border.thin,
            background     = Blitbuffer.COLOR_WHITE,
            radius         = Screen:scaleBySize(3),
            padding_left   = Size.padding.default,
            padding_right  = Size.padding.default,
            padding_top    = Size.padding.small,
            padding_bottom = Size.padding.small,
            TextWidget:new{
                text = text,
                face = Font:getFace("smallinfofont", size or 12),
                bold = true,
            }
        }
    end

    if book_count and book_count > 0 then
        local badge = makeBadge("\xc3\x97" .. tostring(book_count), 12)
        local badge_w = badge:getSize().w
        local cover_right_x = self.width - FolderCard.SHADOW_OFFSET
        local badge_x = math.max(0, math.min(self.width - badge_w,
                                             cover_right_x - math.floor(badge_w / 2)))
        badge.overlap_offset = { badge_x, -FolderCard.SHADOW_OFFSET }
        children[#children + 1] = badge
    end

    if unread_count and unread_count > 0 then
        local badge = makeBadge(tostring(unread_count) .. " kvar", 10)
        badge.overlap_offset = { 0, -FolderCard.SHADOW_OFFSET }
        children[#children + 1] = badge
    elseif all_read and book_count and book_count > 0 then
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
