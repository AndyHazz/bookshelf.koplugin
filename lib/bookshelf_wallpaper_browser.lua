--[[
The wallpaper picker: every picture the shelf can show behind it, the
reader's own (the wallpapers folder and the extra folders) and the packs'
(a pack's theme/wallpaper), one per page, shown as large as the page allows.
Opened from the reader's own "Wallpaper" and "Full screen wallpaper" rows; a
tap uses that picture there. On the ornament collection's screen
(LibraryModal), like the plank picker.

The pages are pictures only. No wallpaper (and, for full screen, Same as
wallpaper) are buttons in the footer, beside Close, greyed while they are the
choice already (maintainer, 2026-10-08: the picker opened on a None page with
a folder path on it, the pictures pages away). Where the pictures come from
is the Wallpaper row's help, and the picker's own message when there are none.

A pack's wallpaper is an ordinary choice: stored like any other, it takes the
pack's full screen and dark variants by itself, and shows whatever the
collection's pack switches say (they shape ornaments only). The picker never
switches a pack on or off.
]]
local BookshelfSettings = require("lib/bookshelf_settings_store")
local ok_i, I18n = pcall(require, "lib/bookshelf_i18n")
local _ = (ok_i and I18n and I18n.gettext) or function(s) return s end

local WB = {}
WB.ALL, WB.YOURS = "__all", "__yours"

local function WP() return require("lib/bookshelf_wallpaper") end
local function TP() return require("lib/bookshelf_theme_pack") end

-- entries(key, chip) -> the pictures the picker lists for that tab:
--   { kind = "own" | "pack", name, label, path, pack }
-- All: the reader's own, then the packs'. Yours: the reader's own. A pack's
-- tab: its wallpaper alone. No wallpaper and Same as wallpaper are not
-- pictures: footer buttons (WB.show). key is unused, kept for the callers.
function WB.entries(_key, chip)
    local out = {}
    if chip ~= WB.ALL and chip ~= WB.YOURS then
        for _i, e in ipairs(TP().wallpaperEntries()) do
            if e.pack == chip then
                out[#out + 1] = { kind = "pack", name = e.name, label = e.label, path = e.path,
                                  pack = e.pack }
            end
        end
        return out
    end
    for _i, e in ipairs(WP().list()) do
        out[#out + 1] = { kind = "own", name = e.name, label = e.label, path = e.path }
    end
    if chip == WB.ALL then
        for _i, e in ipairs(TP().wallpaperEntries()) do
            out[#out + 1] = { kind = "pack", name = e.name, label = e.label, path = e.path,
                              pack = e.pack }
        end
    end
    return out
end

-- inUse(key, item) -> is this what the setting holds now. The full screen
-- image has three states: unset (Same as wallpaper), false (None), a name.
-- Read and written through the one seam (bookshelf_theme_pack.partRead /
-- partSave): Custom theme's, or the edits to the theme on screen.
function WB.inUse(key, item)
    local v = TP().partRead(key)
    if item.kind == "same" then return v == nil end
    if item.kind == "none" then
        if key == WP().FULL_SETTING then return v == false end
        return not (type(v) == "string" and v ~= "")
    end
    return v == item.name
end

-- perPage() -> pictures to a page: one, large, in portrait; a row of four in
-- landscape, where one would be a small picture in a wide box.
function WB.perPage()
    local Screen = require("device").screen
    return (Screen:getWidth() > Screen:getHeight()) and 4 or 1
end

-- startPage(key, items, per_page) -> the page showing the wallpaper in use,
-- so the picker opens on the current choice; the first page when it is no
-- picture (No wallpaper, Same as wallpaper).
function WB.startPage(key, items, per_page)
    per_page = math.max(1, per_page or 1)
    for i, item in ipairs(items) do
        if WB.inUse(key, item) then return math.ceil(i / per_page) end
    end
    return 1
end

-- choose(key, item): store the choice (the old list menu's semantics: None
-- is false, Same as wallpaper is unset), and drop the decoded bitmap.
function WB.choose(key, item)
    if item.kind == "same" then
        TP().partDelete(key)
    elseif item.kind == "none" then
        TP().partSave(key, false)
    else
        TP().partSave(key, item.name)
    end
    if BookshelfSettings.flush then BookshelfSettings.flush() end
    pcall(function() WP().free() end)
end

-- Decoded previews, a few pages' worth: a page is one picture (four in
-- landscape), and going back a page is free. A page's are always the newest,
-- so the cache never frees a preview still on screen.
local _previews, _order = {}, {}
local PREVIEW_KEEP = 8
local function preview(path, w, h)
    local key = path .. "|" .. w .. "x" .. h
    if _previews[key] then return _previews[key] end
    local RenderImage = require("ui/renderimage")
    local ok, bb = pcall(function() return RenderImage:renderImageFile(path, false) end)
    if not ok or not bb then return nil end
    local iw, ih = bb:getWidth(), bb:getHeight()
    local s = math.min(w / iw, h / ih)
    local tw, th = math.max(1, math.floor(iw * s)), math.max(1, math.floor(ih * s))
    local ok_s, sc = pcall(function() return RenderImage:scaleBlitBuffer(bb, tw, th) end)
    if not ok_s or not sc then return nil end
    _previews[key] = sc
    _order[#_order + 1] = key
    while #_order > PREVIEW_KEEP do
        local old = table.remove(_order, 1)
        if _previews[old] then pcall(function() _previews[old]:free() end) end
        _previews[old] = nil
    end
    return sc
end

local function renderCell(key, item, dimen)
    local Blitbuffer      = require("ffi/blitbuffer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local Font            = require("ui/font")
    local FrameContainer  = require("ui/widget/container/framecontainer")
    local Geom            = require("ui/geometry")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan  = require("ui/widget/horizontalspan")
    local ImageWidget     = require("ui/widget/imagewidget")
    local LeftContainer   = require("ui/widget/container/leftcontainer")
    local Marks           = require("lib/bookshelf_marks")
    local Size            = require("ui/size")
    local Space           = require("lib/bookshelf_space")
    local TextWidget      = require("lib/bookshelf_colour_text")
    local VerticalGroup   = require("ui/widget/verticalgroup")
    local VerticalSpan    = require("ui/widget/verticalspan")
    local T               = require("ffi/util").template
    local pad = Space.padding.small
    local inner_w, inner_h = dimen.w - 2 * pad, dimen.h - 2 * pad
    local name = item.label
    if item.kind == "pack" then name = T(_("%1 pack"), item.label) end
    -- The title row, aligned left as the plank picker's: the radio mark
    -- (filled for the one in use) and the name. The same height on every
    -- card, so the pictures above are all one size whichever is chosen.
    local radio = Marks.Radio:new{ checked = WB.inUse(key, item) }
    local gap = Space.padding.small
    local name_w = inner_w - radio:getSize().w - gap
    local row = HorizontalGroup:new{ align = "center", radio, HorizontalSpan:new{ width = gap },
        TextWidget:new{ text = name, face = Font:getFace("cfont", 15), bold = true, max_width = math.max(1, name_w) } }
    local lines = LeftContainer:new{ dimen = Geom:new{ w = inner_w, h = row:getSize().h }, row }
    local box_h = math.max(1, inner_h - lines:getSize().h - Space.padding.small)
    local pic
    if item.path then
        local bb = preview(item.path, inner_w, box_h)
        if bb then
            pic = ImageWidget:new{ image = bb, image_disposable = false, original_in_nightmode = true }
        end
    end
    if not pic then
        -- A picture that would not decode: a plain frame the size of one,
        -- portrait as the wallpapers are, in either orientation.
        local Screen = require("device").screen
        local sw = math.min(Screen:getWidth(), Screen:getHeight())
        local sh = math.max(Screen:getWidth(), Screen:getHeight())
        local fw = inner_w
        local fh = math.min(box_h, math.floor(fw * sh / sw))
        if fh == box_h then fw = math.floor(fh * sw / sh) end
        pic = FrameContainer:new{
            bordersize = Size.border.thin, padding = 0, margin = 0,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{ dimen = Geom:new{ w = math.max(1, fw - 2 * Size.border.thin),
                                                   h = math.max(1, fh - 2 * Size.border.thin) },
                                 VerticalSpan:new{ width = 1 } },
        }
    end
    return FrameContainer:new{
        bordersize = 0, padding = pad, margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{ align = "left",
            lines,
            VerticalSpan:new{ width = Space.padding.small },
            CenterContainer:new{ dimen = Geom:new{ w = inner_w, h = box_h }, pic },
        },
    }
end

-- NONE, SAME: the two choices that are not a picture, as the footer's
-- buttons hand them to choose().
WB.NONE, WB.SAME = { kind = "none" }, { kind = "same" }

-- footerActions(key, pick, close) -> the footer's one row: Same as wallpaper
-- (the full screen picker only), No wallpaper, Close. A button is greyed
-- while it is the choice in use, so it also shows which is chosen.
-- pick(item) is what a card tap does.
function WB.footerActions(key, pick, close)
    local row = {}
    local function choice(k, label, item)
        row[#row + 1] = { key = k, label = label, on_tap = function() pick(item) end,
                          enabled_when = function() return not WB.inUse(key, item) end }
    end
    if key == WP().FULL_SETTING then choice("same", _("Same as wallpaper"), WB.SAME) end
    choice("none", _("No wallpaper"), WB.NONE)
    row[#row + 1] = { key = "close", label = _("Close"), on_tap = close }
    return row
end

-- show(key, on_change, on_closed): the picker for that setting. on_change()
-- runs after each choice, so the shelf behind can catch up; on_closed() once,
-- however the picker closes (the caller brings its menu back).
function WB.show(key, on_change, on_closed)
    local LibraryModal = require("lib/bookshelf_library_modal")
    local UIManager    = require("ui/uimanager")
    local self = { chip = WB.ALL }
    local function items() return WB.entries(key, self.chip) end
    self.items = items()
    local modal
    local function close() if modal then UIManager:close(modal); modal = nil end end
    -- A card or a footer button: used at once, behind the picker, which
    -- stays open for the next.
    local function pick(item)
        WB.choose(key, item)
        self.changed = true
        if on_change then pcall(on_change) end
        if modal then modal:refresh() end
    end
    local function chips()
        local out = {
            { key = WB.ALL, label = _("All"), is_active = self.chip == WB.ALL },
            { key = WB.YOURS, label = _("Yours"), is_active = self.chip == WB.YOURS },
        }
        for _i, e in ipairs(TP().wallpaperEntries()) do
            out[#out + 1] = { key = e.pack, label = e.pack, is_active = self.chip == e.pack }
        end
        return out
    end
    local config = {
        title = (key == WP().FULL_SETTING) and _("Full screen wallpaper") or _("Wallpaper"),
        no_search = true,
        -- One to a page in portrait, a row of four in landscape (perPage);
        -- each marked by its radio, so choosing one does not resize it.
        grid_cols = function() return WB.perPage() end,
        cells_per_page = function() return WB.perPage() end,
        -- Short, so the shelf shows around it and a tap can be seen there:
        -- the grid about 45% of the screen's height, whatever its DPI.
        rows_per_page = function() return LibraryModal.rowsForShare(0.45) end,
        chip_strip = chips,
        on_chip_tap = function(k) self.chip = k; self.items = items() end,
        cell_renderer = function(item, dimen) return renderCell(key, item, dimen) end,
        -- A tap uses the picture at once, behind the picker, which stays open
        -- for the next (Close, or a tap outside it, when done).
        on_cell_tap = function(item) pick(item) end,
        -- However it closes: one full refresh if the picture changed, to
        -- clear what the quick per-tap updates leave on e-ink.
        on_closed = function()
            if self.changed then UIManager:setDirty("all", "full") end
            if on_closed then pcall(on_closed) end
        end,
        item_count = function() return #self.items end,
        item_at = function(i) return self.items[i] end,
        footer_rows = { WB.footerActions(key, function(item) pick(item) end, close) },
        -- No pictures on this tab: where they come from, the one place the
        -- picker names the folder.
        empty_state = function(w, h)
            local CenterContainer = require("ui/widget/container/centercontainer")
            local Font            = require("ui/font")
            local Geom            = require("ui/geometry")
            local TextBoxWidget   = require("ui/widget/textboxwidget")
            local T               = require("ffi/util").template
            return CenterContainer:new{ dimen = Geom:new{ w = w, h = h },
                TextBoxWidget:new{ text = T(_("No images in %1"), WP().dir and WP().dir() or "?"),
                                   face = Font:getFace("cfont", 16), width = math.floor(w * 0.9),
                                   alignment = "center" } }
        end,
    }
    modal = LibraryModal:new{ config = config, page = WB.startPage(key, self.items, WB.perPage()) }
    UIManager:show(modal)
    return modal
end

return WB
