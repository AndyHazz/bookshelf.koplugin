--[[
The wallpaper picker: every picture the shelf can show behind it, the
reader's own (the wallpapers folder and the extra folders) and the packs'
(a pack's theme/wallpaper), one per page, shown as large as the page allows.
Opened from the reader's own "Wallpaper" and "Full screen wallpaper" rows; a
tap uses that picture there. On the ornament collection's screen
(LibraryModal), like the plank picker.

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

-- entries(key, chip) -> what the picker lists for that setting and tab:
--   { kind = "same" | "none" | "own" | "pack", name, label, path, pack }
-- All: (Same as default), None, the reader's own, then the packs'. Yours:
-- the same without the packs'. A pack's tab: its wallpaper alone.
function WB.entries(key, chip)
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
    if key == WP().FULL_SETTING then out[#out + 1] = { kind = "same", label = _("Same as wallpaper") } end
    out[#out + 1] = { kind = "none", label = _("None") }
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
-- image has three states: unset (Same as default), false (None), a name.
function WB.inUse(key, item)
    local v = BookshelfSettings.read(key)
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
-- so the picker opens on the current choice.
function WB.startPage(key, items, per_page)
    per_page = math.max(1, per_page or 1)
    for i, item in ipairs(items) do
        if WB.inUse(key, item) then return math.ceil(i / per_page) end
    end
    return 1
end

-- choose(key, item): store the choice (the old list menu's semantics: None
-- is false, Same as default is unset), and drop the decoded bitmap.
function WB.choose(key, item)
    if item.kind == "same" then
        BookshelfSettings.delete(key)
    elseif item.kind == "none" then
        BookshelfSettings.save(key, false)
    else
        BookshelfSettings.save(key, item.name)
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
    local TextBoxWidget   = require("ui/widget/textboxwidget")
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
        -- None / Same as default: a plain frame the size of a picture, with
        -- where the reader's pictures come from under None.
        -- Portrait, as the wallpapers are, in either orientation.
        local Screen = require("device").screen
        local sw = math.min(Screen:getWidth(), Screen:getHeight())
        local sh = math.max(Screen:getWidth(), Screen:getHeight())
        local fw = inner_w
        local fh = math.min(box_h, math.floor(fw * sh / sw))
        if fh == box_h then fw = math.floor(fh * sw / sh) end
        local hint
        if item.kind == "none" then
            local Wallpaper = WP()
            local dir, user = Wallpaper.dir and Wallpaper.dir() or "?", Wallpaper.userDir and Wallpaper.userDir()
            if #Wallpaper.list() == 0 then
                hint = T(_("No images in %1"), dir)
            elseif user then
                hint = T(_("Images are loaded from %1 and %2"), dir, user)
            else
                hint = T(_("Images are loaded from %1"), dir)
            end
        elseif item.kind == "same" then
            hint = _("Full screen shelves show the default wallpaper.")
        end
        -- The hint only where it fits: on a small screen's card the folder
        -- path would run out of the frame a letter to a line.
        local inner_fw, inner_fh = fw - 2 * Size.border.thin, fh - 2 * Size.border.thin
        local hint_w
        if hint then
            hint_w = TextBoxWidget:new{ text = hint, face = Font:getFace("cfont", 12),
                                        width = math.max(1, math.floor(inner_fw * 0.9)), alignment = "center" }
            local hs = hint_w:getSize()
            if inner_fw < Screen:scaleBySize(90) or hs.h > inner_fh then hint_w:free(); hint_w = nil end
        end
        pic = FrameContainer:new{
            bordersize = Size.border.thin, padding = 0, margin = 0,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{ dimen = Geom:new{ w = inner_fw, h = inner_fh },
                hint_w or VerticalSpan:new{ width = 1 } },
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
        on_cell_tap = function(item)
            WB.choose(key, item)
            self.changed = true
            if on_change then pcall(on_change) end
            if modal then modal:refresh() end
        end,
        -- However it closes: one full refresh if the picture changed, to
        -- clear what the quick per-tap updates leave on e-ink.
        on_closed = function()
            if self.changed then UIManager:setDirty("all", "full") end
            if on_closed then pcall(on_closed) end
        end,
        item_count = function() return #self.items end,
        item_at = function(i) return self.items[i] end,
        footer_rows = { { { key = "close", label = _("Close"), on_tap = close } } },
    }
    modal = LibraryModal:new{ config = config, page = WB.startPage(key, self.items, WB.perPage()) }
    UIManager:show(modal)
    return modal
end

return WB
