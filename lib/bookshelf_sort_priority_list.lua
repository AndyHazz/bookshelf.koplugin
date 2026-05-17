-- bookshelf_sort_priority_list.lua
-- Vertical list of rows where each row can be nudged up/down by tapping
-- arrow buttons at its left, and optionally toggled (reverse direction)
-- or deleted at its right. The on_change callback fires with the freshly
-- ordered items table after every interaction.
--
-- Used by:
--   * the chip editor (sort priority levels, with show_reverse = true)
--   * the tabs-list editor (tab order, with show_delete = true for custom)

local Button         = require("ui/widget/button")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup= require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local TextWidget     = require("ui/widget/textwidget")
local VerticalGroup  = require("ui/widget/verticalgroup")
local CenterContainer= require("ui/widget/container/centercontainer")
local Geom           = require("ui/geometry")
local Size           = require("ui/size")
local Font           = require("ui/font")
local Screen         = require("device").screen
local _              = require("lib/bookshelf_i18n").gettext

local List = {}
List.__index = List

local function copy(t)
    local r = {} for k, v in pairs(t) do r[k] = v end return r
end

function List:new(o)
    o = setmetatable(o or {}, self)
    o:_init()
    return o
end

function List:_init()
    self.items = self.items or {}
    self.width = self.width or math.floor(Screen:getWidth() * 0.8)
    self.row_h = self.row_h or Screen:scaleBySize(48)
    self.show_reverse = self.show_reverse and true or false
    self.show_delete  = self.show_delete and true or false
    self._vg = VerticalGroup:new{ align = "left" }
    self:_rebuild()
end

function List:_swap(i, j)
    self.items[i], self.items[j] = self.items[j], self.items[i]
    if self.on_change then self.on_change(self.items) end
    self:_rebuild()
end

function List:_toggleReverse(i)
    self.items[i].reverse = not self.items[i].reverse
    if self.on_change then self.on_change(self.items) end
    self:_rebuild()
end

function List:_delete(i)
    table.remove(self.items, i)
    if self.on_change then self.on_change(self.items) end
    self:_rebuild()
end

local function chev_button(glyph, enabled, w, h, cb)
    return Button:new{
        text       = glyph,
        text_font_size = 18,
        enabled    = enabled,
        width      = w,
        height     = h,
        bordersize = 0,
        margin     = 0,
        callback   = cb,
    }
end

function List:_rebuild()
    -- VerticalGroup has no public clear(); rebuild by emptying numeric indices.
    for k in pairs(self._vg) do
        if type(k) == "number" then self._vg[k] = nil end
    end
    local btn_w = Screen:scaleBySize(48)
    for i, item in ipairs(self.items) do
        local label = item.label_func and item.label_func(item) or item.label or ""
        if self.show_reverse and item.reverse then
            label = label .. "  \xE2\x86\x93\xE2\x86\x91"  -- "↓↑" reversed marker
        end
        local up   = chev_button("\xE2\x86\x91", i > 1,            btn_w, self.row_h,
                                  function() self:_swap(i, i - 1) end)
        local down = chev_button("\xE2\x86\x93", i < #self.items,  btn_w, self.row_h,
                                  function() self:_swap(i, i + 1) end)
        local label_w = self.width - btn_w * 2 - (self.show_reverse and btn_w or 0) - (self.show_delete and btn_w or 0)
        local InputContainer = require("ui/widget/container/inputcontainer")
        local GestureRange   = require("ui/gesturerange")
        local label_inner = CenterContainer:new{
            dimen = Geom:new{ w = label_w, h = self.row_h },
            TextWidget:new{
                text = label,
                face = Font:getFace("infofont", 16),
                max_width = label_w - Size.padding.default * 2,
            },
        }
        local label_widget
        if self.on_row_tap then
            label_widget = InputContainer:new{
                dimen = Geom:new{ w = label_w, h = self.row_h },
                label_inner,
            }
            label_widget.ges_events = {
                Tap = { GestureRange:new{ ges = "tap",
                    range = Geom:new{ w = label_w, h = self.row_h } } },
            }
            local row_index = i
            label_widget.onTap = function() self.on_row_tap(self.items[row_index], row_index) end
        else
            label_widget = label_inner
        end
        local row_children = { up, down, label_widget }
        if self.show_reverse then
            row_children[#row_children + 1] = chev_button(
                item.reverse and "\xE2\x86\x91" or "\xE2\x86\x93",
                true, btn_w, self.row_h,
                function() self:_toggleReverse(i) end)
        end
        if self.show_delete and item.can_delete then
            row_children[#row_children + 1] = chev_button(
                "\xE2\x9C\x95", true, btn_w, self.row_h,
                function() self:_delete(i) end)
        end
        local row = HorizontalGroup:new{ align = "center" }
        for _i, c in ipairs(row_children) do row[#row + 1] = c end
        self._vg[#self._vg + 1] = FrameContainer:new{
            bordersize = Size.border.thin,
            padding    = 0,
            margin     = 0,
            row,
        }
    end
end

function List:getWidget()
    return self._vg
end

function List:getItems()
    return self.items
end

return List
