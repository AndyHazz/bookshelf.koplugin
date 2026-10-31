-- bookshelf_ornament_browser.lua
-- Browse the ornaments folder: see every ornament, switch any of them (or a
-- whole pack) off and on, and delete them. On the shared LibraryModal chrome,
-- like the micro-module picker.
--
-- A pack is a subfolder of the ornaments folder (lib/bookshelf_ornaments);
-- the chips across the top are All (every ornament) and one per pack.
-- The footer's Select all / Select none switch every ornament on the tab.
--
--   tap        switch that ornament off / on
--   long-press switch it, or delete it
--
-- Switching off leaves the file where it is, so it can come back; deleting
-- removes it. Seeds that are deleted stay deleted (the folder is only seeded
-- when it does not exist).

local Blitbuffer      = require("ffi/blitbuffer")
local ButtonDialog    = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox      = require("ui/widget/confirmbox")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local InfoMessage     = require("ui/widget/infomessage")
local LibraryModal    = require("lib/bookshelf_library_modal")
local Size            = require("ui/size")
local Space           = require("lib/bookshelf_space")
local TextWidget      = require("lib/bookshelf_colour_text")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Widget          = require("ui/widget/widget")
local T               = require("ffi/util").template
local _               = require("lib/bookshelf_i18n").gettext
local Screen          = Device.screen

local Browser = {}

local ALL = "__all"

local function O() return require("lib/bookshelf_ornaments") end
-- The switches this browser reads and writes: the collection's, or the set
-- of the theme on screen, a pack or Plain, which the reader is editing
-- (bookshelf_theme_pack.switches, the one seam). Asked each time: the
-- browser can outlive a change of shelf.
local function SW() return require("lib/bookshelf_theme_pack").switches() end
local function TP() return require("lib/bookshelf_theme_pack") end

-- An ornament's PICTURE is faded while it will not be placed, whether switched
-- off itself or through its pack: the grid reads as "what the shelf uses".
-- Only the picture: the checkbox over it (and "Pack off" under it) is what
-- says why, so they stay at full strength (maintainer).
local Faded = Widget:extend{ child = nil, fade = 0.6 }
function Faded:getSize() return self.child:getSize() end
function Faded:paintTo(bb, x, y)
    self.child:paintTo(bb, x, y)
    local s = self.child:getSize()
    pcall(function() bb:lightenRect(x, y, s.w, s.h, self.fade) end)
    self.dimen = Geom:new{ x = x, y = y, w = s.w, h = s.h }
end

-- A preview: renders the ornament at the size that makes its picture fill
-- w x h, and blits just that part (src_x, src_y) of the render.
local Cropped = Widget:extend{ placement = nil, night = false, src_x = 0, src_y = 0, w = 1, h = 1 }
function Cropped:getSize() return Geom:new{ w = self.w, h = self.h } end
function Cropped:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.w, h = self.h }
    local p = self.placement
    local img = O().render(p.entry, p.w, p.h, self.night, p.mirror)
    if not img then return end
    pcall(function() bb:alphablitFrom(img, x, y, self.src_x, self.src_y, self.w, self.h) end)
end

-- preview(e, box_w, box_h) -> the ornament's picture as large as fits
-- box_w x box_h, the transparent room its file carries for the shelf cropped
-- off. Rendered at paint by the ornaments' own renderer (cached; drawn for
-- night mode as the shelf draws it). The collection's cards and the Theme
-- library's heroes (bookshelf_theme_library) both show pieces this way.
-- A piece seen for the first time is decoded once, not twice: contentBox
-- holds its decode, and the render the paint will ask for is made from it
-- here (bookshelf_ornaments ONE DECODE PER PREVIEW).
-- mirror: draw it flipped left to right (the Ornament module's setting).
function Browser.preview(e, box_w, box_h, mirror)
    local aspect = (e.aspect and e.aspect > 0) and e.aspect or 1
    local Orn = O()
    local l, t, r, b = Orn.contentBox(e, true)
    if not l then l, t, r, b = 0, 0, 1, 1 end
    -- The drawing's box flips with the picture (as M.hits does for a piece).
    if mirror then l, r = 1 - r, 1 - l end
    local cut_aspect = aspect * (r - l) / (b - t)
    local cw, ch = box_w, math.floor(box_w / cut_aspect)
    if ch > box_h then ch = box_h; cw = math.floor(box_h * cut_aspect) end
    cw, ch = math.max(1, cw), math.max(1, ch)
    local preview = Cropped:new{
        placement = { entry = e, w = math.max(1, math.floor(cw / (r - l) + 0.5)),
                      h = math.max(1, math.floor(ch / (b - t) + 0.5)),
                      mirror = mirror or nil },
        night = Screen.night_mode and true or false,
        src_x = 0, src_y = 0, w = cw, h = ch,
    }
    preview.src_x = math.floor(l * preview.placement.w + 0.5)
    preview.src_y = math.floor(t * preview.placement.h + 0.5)
    -- Cropped:paintTo asks for exactly this render; made now from the held
    -- decode, the paint finds it cached.
    if Orn.holds(e) then
        Orn.render(e, preview.placement.w, preview.placement.h, preview.night, mirror)
        Orn.releaseHeld()
    end
    return preview
end

function Browser._renderCell(item, dimen)
    local e = item.entry
    local Kit = require("lib/bookshelf_popup_kit")
    -- No border in the sizes: the kit's card (cardify) has none, so counted,
    -- the card came out short of its slot by twice the border.
    local border = 0
    local pad = Space.padding.default
    local label_face = require("lib/bookshelf_fonts"):getFace("cfont", 16)
    local state_face = require("lib/bookshelf_fonts"):getFace("cfont", 13)
    local inner_w = dimen.w - 2 * (border + pad)
    local label = TextWidget:new{ text = O().displayName(e), face = label_face, max_width = inner_w }
    -- On or off is the checkbox in the corner; the only state line left is
    -- a pack that is off, which a piece's own box cannot say.
    local state = (item.pack_off and not item.pick) and TextWidget:new{
        text = _("Pack off"),
        face = state_face, fgcolor = Blitbuffer.COLOR_BLACK, max_width = inner_w,
    } or nil
    local text_h = label:getSize().h + (state and state:getSize().h or 0)
    local box_h = math.max(1, dimen.h - 2 * (border + pad) - text_h - Space.padding.small)
    -- Preview the picture, not the file: the transparent room an ornament
    -- carries for the shelf is cropped off, and what is left fits the box.
    local preview = Browser.preview(e, inner_w, box_h)
    -- Faded only for a pack switched off as a whole. A piece that is merely
    -- not in the set shows as it is, its box empty: faded, every piece on a
    -- Plain shelf looked greyed out for no reason (maintainer).
    if item.pack_off and not item.pick then preview = Faded:new{ child = preview } end
    local inner_h = dimen.h - 2 * (border + pad)
    local body = VerticalGroup:new{
        align = "center",
        CenterContainer:new{ dimen = Geom:new{ w = inner_w, h = box_h }, preview },
        VerticalSpan:new{ width = Space.padding.small },
        label,
        state,
    }
    -- Sized by its content, not FrameContainer's width/height (its getSize
    -- ignores them), so every card fills its grid slot exactly.
    local card = FrameContainer:new{
        bordersize = border,
        radius = Kit.RADIUS,
        padding = pad,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{ dimen = Geom:new{ w = inner_w, h = inner_h }, body },
    }
    Kit.cardify(card)
    -- Picking (Swap): no box, a tap chooses the piece; there is nothing to
    -- switch.
    if item.pick then return card end
    -- The checkbox, over the card's top right corner: ticked when the piece
    -- is on, grey when its pack is off (a tap switches the pack on too).
    local Marks = require("lib/bookshelf_marks")
    local OverlapGroup = require("ui/widget/overlapgroup")
    local box = Marks.Check:new{ checked = not item.off, enabled = not item.pack_off }
    local cs, bs = card:getSize(), box:getSize()
    box.overlap_offset = { cs.w - bs.w - border - Space.padding.small, border + Space.padding.small }
    return OverlapGroup:new{ dimen = Geom:new{ w = cs.w, h = cs.h }, card, box }
end

-- One fresh look at the folders (a piece just dropped in shows), then the
-- recent window held while each piece is asked about: its isOff reaches
-- listAll through the theme's set, and outside the window listAll reads
-- every folder again. On a PW5 with 443 pieces that was 889 scans and a
-- 32 s open (measured 2026-10-30); _chips is the same per pack.
function Browser:_items()
    local Orn, sw = O(), SW()
    local all = Orn.listAll()
    local was = Orn.allowRecent(true)
    local out = {}
    -- What the summary line counts: the pieces on in these switches, of all.
    local on = 0
    local pick = self.opts.pick ~= nil
    for _i, e in ipairs(all) do
        -- opts.pool: the pieces a shelf deals from (Swap on a shelf that
        -- wears a pack offers only those).
        local keep = (self.chip == ALL or (e.pack ~= nil and e.pack == self.chip))
                     and (not self.opts.pool or self.opts.pool(e))
        if keep then
            out[#out + 1] = { entry = e, off = sw.isOff(e.name),
                              pack_off = sw.isPackOff(e.pack), pick = pick }
        end
        if not pick and not sw.isOff(e.name) and not sw.isPackOff(e.pack) then on = on + 1 end
    end
    self.on_count, self.all_count = on, #all
    if not was then Orn.allowRecent(false) end
    return out
end

-- _intro() -> the line over the grid saying whose set the boxes are: the
-- theme of the shelf the browser was opened from (Plain's starts empty, and
-- with no word on it every piece looked switched off, maintainer), and how
-- many of the pieces it uses. None when picking (Swap): there are no boxes.
function Browser:_intro()
    if self.opts.pick then return nil end
    local name = TP().themeName(TP().shelfTheme())
    if (self.on_count or 0) == 0 then
        return T(_("On %1 shelves: none yet. Check a piece to add it."), name)
    end
    return T(_("On %1 shelves: %2 of %3. Check a piece to add it, uncheck to take it off."),
        name, self.on_count, self.all_count)
end

-- _toggle(item): switch an ornament on or off. (Planks are chosen in the
-- plank picker, wallpapers in the wallpaper picker.)
function Browser:_toggle(item)
    SW().setOff(item.entry.name, not item.off)
    self:_changed()
end

-- _pick(item): pick mode (the long-press menu's Swap). The chosen piece
-- takes the slot; a switched-off one, or one in a switched-off pack, is
-- switched on, or the swap would put nothing there. Not the pack on a
-- themed shelf (opts.pool): a theme deals its pieces whatever the
-- collection's pack switches say, which shape the reader's own ornaments.
function Browser:_pick(item)
    local sw = SW()
    if item.off then sw.setOff(item.entry.name, false) end
    if item.pack_off and item.entry.pack and not self.opts.pool then
        sw.setPackOff(item.entry.pack, false)
    end
    self.opts.pick(item.entry)
    self._dirty = true
    self._close()
end

-- _changed(rescan): redraw the browser after a switch. The shelf behind is
-- rebuilt once, when the browser closes (see show): it is almost all covered,
-- and rebuilding it per tap made tapping through a pack slow. rescan (after a
-- delete) re-lists the folders; a switch only changes what is filtered out.
function Browser:_changed(rescan)
    local ok_t, TP = pcall(require, "lib/bookshelf_theme_pack")
    if rescan then
        O().invalidate()
        if ok_t and TP then TP.invalidate() end
    elseif ok_t and TP then
        -- Which plank shows is memoised; a switch must be seen at once.
        TP.forgetChoice()
    end
    self._dirty = true
    -- A tick changes no files: the list and the chips read the folders as
    -- they were (the recent window), where each read every folder again,
    -- twice a tap (~28 ms a scan on a PW5). After a delete (rescan) they
    -- look afresh.
    local Orn = O()
    local was = (not rescan) and Orn.allowRecent(true)
    self.items = self:_items()
    if self._config then self._config.footer_rows = self:_footerRows() end
    if self.modal then self.modal:refresh() end
    if not rescan and not was then Orn.allowRecent(false) end
end

function Browser:_chips()
    local Orn, sw = O(), SW()
    local all, packs = Orn.listAll()
    local was = Orn.allowRecent(true)
    -- All, then one per pack. No tab for the loose ornaments on their own:
    -- All already shows them, and a tab is for something you switch as one
    -- (maintainer). Nor for a pack with no ornaments: a planks-only pack's
    -- designs are in the plank picker, and its tab here was an empty page.
    local has = {}
    for _i, e in ipairs(all or {}) do if e.pack then has[e.pack] = true end end
    local chips = { { key = ALL, label = _("All"), is_active = self.chip == ALL } }
    for _i, pack in ipairs(packs) do
        if has[pack] then chips[#chips + 1] = {
            key = pack,
            label = sw.isPackOff(pack) and T(_("%1 (off)"), pack) or pack,
            is_active = self.chip == pack,
        } end
    end
    if not was then Orn.allowRecent(false) end
    return chips
end

function Browser:_isPack(key)
    return key ~= nil and key ~= ALL
end

function Browser:_confirmDelete(item)
    UIManager:show(ConfirmBox:new{
        text = T(_("Delete %1?\n\nThe file is removed from the ornaments folder."), item.entry.name),
        ok_text = _("Delete"),
        ok_callback = function()
            if not O().delete(item.entry) then
                UIManager:show(InfoMessage:new{ text = _("Could not delete the file."), timeout = 3 })
            end
            self:_changed(true)
        end,
    })
end

function Browser:_longTap(item)
    local d
    local buttons = {
        {{
            -- The ornament menu's words for it (Hide / Show).
            text = item.off and _("Show") or _("Hide"),
            callback = function()
                UIManager:close(d)
                self:_toggle(item)
            end,
        }},
    }
    buttons[#buttons + 1] = {{
        text = _("Delete\xe2\x80\xa6"),
        callback = function()
            UIManager:close(d)
            self:_confirmDelete(item)
        end,
    }}
    -- The title's X is the way out (STYLE.md).
    d = ButtonDialog:new(require("lib/bookshelf_module_kit").withClose{ title = item.entry.name, buttons = buttons })
    UIManager:show(d)
end

-- _addButton() -> Add ornaments...: where to put them, how a folder becomes a
-- pack, and where to get ready-made packs. On the All tab.
function Browser:_addButton()
    return {
        key = "add",
        label = _("Add ornaments\xe2\x80\xa6"),
        on_tap = function()
            -- A findable path: the settings dir can be relative.
            local d = O().dir() or "?"
            local ok, util = pcall(require, "ffi/util")
            local real = ok and util.realpath and util.realpath(d)
            -- As Add theme pack: a panel with the shop's QR code.
            require("lib/bookshelf_link_panel").showShop{
                title = _("Add ornaments"),
                text = T(_("Put PNG or SVG files in\n%1\n\nA folder of them inside it becomes a pack, with its own tab here."),
                    real or d),
                shop = _("Ready-made packs"),
            }
        end,
    }
end

-- _selectButton(on) -> Select all (on) or Select none: every ornament on the
-- tab on or off (maintainer: plainer than Switch pack on/off, which is the
-- theme packs' job now).
function Browser:_selectButton(on)
    return {
        key = on and "all" or "none",
        label = on and _("Select all") or _("Select none"),
        on_tap = function() self:_setAll(on) end,
    }
end

-- _setAll(on): every ornament on this tab on or off, one by one. Select all
-- also switches on a pack a theme had switched off, or its ornaments would be
-- on and still not show.
function Browser:_setAll(on)
    local sw = SW()
    for _i, item in ipairs(self.items or {}) do
        local e = item.entry
        if e then
            sw.setOff(e.name, not on)
            if on and e.pack and sw.isPackOff(e.pack) then sw.setPackOff(e.pack, false) end
        end
    end
    self:_changed()
end

-- _headerActions() -> the screen's own actions, on the strip under the title:
-- Select all and Select none (Add ornaments first on the All tab). Nothing
-- when picking a replacement. A theme is chosen in the Theme menu, not here.
function Browser:_headerActions()
    if self.opts.pick then return {} end
    if self:_isPack(self.chip) then
        return { self:_selectButton(true), self:_selectButton(false) }
    end
    return { self:_addButton(), self:_selectButton(true), self:_selectButton(false) }
end

-- _footerRows() -> the footer: Close, which the modal makes the title's X
-- (switches are live and written as it closes, however it closes, so
-- "Apply" promised a step there is not); Cancel when picking a replacement.
function Browser:_footerRows()
    local close = { key = "close", label = self.opts.pick and _("Cancel") or _("Close"), on_tap = self._close }
    return { { close } }
end

-- show(on_change, opts): on_change() runs once when the browser closes, if
-- anything changed, so the caller can redraw the shelf. opts.pick(entry)
-- turns it into a chooser (the long-press menu's Swap): tapping a piece
-- picks it and closes.
--
-- Building the first page decodes a picture per piece, which takes seconds on
-- an e-reader with a big pack; with nothing on screen meanwhile it looks like
-- a crash. So a message goes up and is painted first, and the browser is
-- built on the next tick behind it.
function Browser.show(on_change, opts)
    local msg = InfoMessage:new{ text = _("Loading ornaments\xE2\x80\xA6") }
    UIManager:show(msg)
    UIManager:forceRePaint()
    UIManager:nextTick(function()
        local ok, err = pcall(Browser._open, on_change, opts)
        UIManager:close(msg)
        if not ok then
            require("logger").warn("[bookshelf] ornament browser failed to open:", err)
        end
    end)
end

function Browser._open(on_change, opts)
    local self = setmetatable({ chip = ALL, on_change = on_change, opts = opts or {} },
                              { __index = Browser })
    O().beginDeferred()
    self.items = self:_items()
    local function cols() return Screen:getWidth() > Screen:getHeight() and 4 or 3 end
    local function close()
        if self.modal then UIManager:close(self.modal); self.modal = nil end
    end
    -- However it closes (Close, the title's X, Back): write the switches and
    -- rebuild the shelf once.
    local function closed()
        O().endDeferred()
        if not self._dirty then return end
        if self.on_change then pcall(self.on_change) end
    end
    local config = {
        title = self.opts.title or (self.opts.pick and _("Swap for") or _("Ornament collection")),
        no_search = true,
        grid_cols = cols,
        cells_per_page = function() return cols() * 3 end,
        rows_per_page = 6,
        chip_strip = function() return self:_chips() end,
        on_chip_tap = function(key)
            self.chip = key
            self.items = self:_items()
            if self._config then self._config.footer_rows = self:_footerRows() end
        end,
        cell_renderer = Browser._renderCell,
        intro = function() return self:_intro() end,
        intro_below = true,
        on_cell_tap = function(item)
            if self.opts.pick then self:_pick(item) else self:_toggle(item) end
        end,
        -- Switching a piece on or off marks it at once, its own feedback (no
        -- pressed look first); picking one closes, so it keeps the press.
        select_on_tap = not self.opts.pick,
        cell_long_tap = function(item) self:_longTap(item) end,
        item_count = function() return #self.items end,
        item_at = function(idx) return self.items[idx] end,
        empty_state = function(w, _h)
            local dir = O().dir() or "?"
            return CenterContainer:new{
                dimen = Geom:new{ w = w, h = _h },
                TextBoxWidget:new{
                    text = T(_("No ornaments here.\n\nDrop PNG or SVG files into\n%1\nor a folder of them, which becomes a pack."), dir),
                    face = require("lib/bookshelf_fonts"):getFace("cfont", 16),
                    width = math.floor(w * 0.9),
                    alignment = "center",
                },
            }
        end,
        header_actions = function() return self:_headerActions() end,
        footer_rows = {},
        on_closed = closed,
    }
    self._close, self._config = close, config
    config.footer_rows = self:_footerRows()
    self.modal = LibraryModal:new{ config = config }
    UIManager:show(self.modal)
    return self
end

return Browser
