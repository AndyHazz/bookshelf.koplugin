-- lib/bookshelf_pack_editor.lua
-- The pack editor: one ornament pack alone on full-screen shelves, no books,
-- each piece once with its name on a badge, for a pack maker to adjust before
-- giving the pack out (maintainer). Reached from Updates > Developer updates.
--
-- The shelf's own adjust menu stays open over it, on the piece last tapped
-- (one tap switches it to another; swiping to a page opens it on that page's
-- first piece), and the changes
-- land in the reader's ornaments.json as they always do, so every nudge
-- redraws at once. Leaving the editor moves this pack's records from there
-- into the pack's own ornaments.json (Ornaments.commitPack), so they travel
-- with the pack instead of only shaping this reader's shelf.
--
-- Pieces stand at the size a reader sees: the live shelf's row height when
-- it is a spine shelf, a third of the screen otherwise. One row of them, at
-- the bottom, under an empty shelf; the menu opens in the room above.
local Blitbuffer      = require("ffi/blitbuffer")
local Device          = require("device")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local InputContainer  = require("ui/widget/container/inputcontainer")
local OverlapGroup    = require("ui/widget/overlapgroup")
local UIManager       = require("ui/uimanager")
local Widget          = require("ui/widget/widget")
local _               = require("lib/bookshelf_i18n").gettext
local T               = require("ffi/util").template
local Screen          = Device.screen

local M = {}

-- layout(items, row_w, n_rows, margin) -> pages: { { {i, x}, ... } per row }
-- per page. items = { { slot = px each piece takes, with its room }, ... },
-- laid left to right from the margin, a new row when the next one would run
-- past the far margin, a new page after n_rows. A piece wider than a whole
-- row still gets a row of its own. Pure, for the tests.
function M.layout(items, row_w, n_rows, margin)
    local pages, page, row, x = {}, nil, nil, nil
    local function newRow()
        if not page or #page >= n_rows then
            page = {}
            pages[#pages + 1] = page
        end
        row = {}
        page[#page + 1] = row
        x = margin
    end
    for i, it in ipairs(items) do
        if not row or (#row > 0 and x + it.slot > row_w - margin) then newRow() end
        row[#row + 1] = { i = i, x = x }
        x = x + it.slot
    end
    return pages
end

local Ground = Widget:extend{}
function Ground:paintTo(bb, x, y)
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_WHITE)
end

local Editor = InputContainer:extend{
    pack = nil,
    bw = nil,          -- the shelf underneath, rebuilt on the way out
    covers_fullscreen = true,
    -- The adjust menu stays open over the editor (maintainer); its taps
    -- outside it are not its own, so they come here, to pick another piece.
    is_always_active = true,
}

function Editor:init()
    self.page = 1
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = {
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        TapPiece = { GestureRange:new{ ges = "tap", range = self.dimen } },
        HoldPiece = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    -- A piece's own tap and long-press do nothing here: the editor picks
    -- the piece itself (onTapPiece), tap action or not.
    local Orn = require("lib/bookshelf_ornaments")
    self._handlers = Orn.handlers
    Orn.handlers = {}
    self:_rebuild()
    -- The menu, open from the start, on the first piece.
    UIManager:scheduleIn(0.3, function() self:_select(1) end)
end

-- _select(i) -> the adjust menu for the page's ith piece, in place of the
-- one open. The menu redraws the editor as it goes (bw:_rebuild below).
function Editor:_select(i)
    local w_ = self._piece_ws and self._piece_ws[i]
    if not w_ then return end
    if self._menu then UIManager:close(self._menu); self._menu = nil end
    self._selected = w_.placement.entry.name
    local Menu = require("lib/bookshelf_ornament_menu")
    self._menu = Menu.show(w_.placement.entry, self, w_.dimen)
end

function Editor:_pieceAt(pos)
    for i, w_ in ipairs(self._piece_ws or {}) do
        local d = w_.dimen
        if d and d.x and pos.x >= d.x and pos.x < d.x + d.w and pos.y >= d.y and pos.y < d.y + d.h then
            return i
        end
    end
end

function Editor:onTapPiece(_arg, ges)
    local i = ges and ges.pos and self:_pieceAt(ges.pos)
    if i then self:_select(i) end
    return true
end
Editor.onHoldPiece = Editor.onTapPiece

-- The geometry the live shelf uses, when it has spine rows to copy.
function Editor:_rows()
    local bw = self.bw
    local d = bw and bw._shelf_dims
    if bw and bw._isSpineMode and bw:_isSpineMode() and d and d.shelf_h and d.n_shelves then
        return d.shelf_h, d.n_shelves, bw._spine_lift_headroom or 0
    end
    return nil, 3, Screen:scaleBySize(12)
end

function Editor:_rebuild()
    local Orn = require("lib/bookshelf_ornaments")
    local SpineShelf = require("lib/bookshelf_spine_shelf")
    local TitleBar = require("ui/widget/titlebar")
    local TextWidget = require("lib/bookshelf_colour_text")
    local BFont = require("lib/bookshelf_fonts")
    local w, h = self.dimen.w, self.dimen.h

    local title = TitleBar:new{
        title_face = require("lib/bookshelf_popup_kit").titleFace(),
        width = w,
        title = T(_("Pack editor: %1"), self.pack),
        with_bottom_line = true,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }
    require("lib/bookshelf_popup_kit").centreTitle(title)
    local top = title:getSize().h
    local shelf_h, n_rows, headroom = self:_rows()
    local gap = math.max(headroom, Screen:scaleBySize(12))
    local footer_h = Screen:scaleBySize(36)
    if not shelf_h then
        shelf_h = math.floor((h - top - footer_h - n_rows * gap) / n_rows)
    end
    -- One row of pieces, at the bottom: the adjust menu opens in the room
    -- above it, so it never covers the piece being changed (maintainer). An
    -- empty shelf stands over it, for pieces anchored to the top to hang from.
    n_rows = 1

    local fh      = SpineShelf.plankFace(shelf_h)
    local inset   = SpineShelf.plankInset(SpineShelf.plankUnit(shelf_h))
    local stand_h = math.max(1, shelf_h - fh - inset)
    local margin  = SpineShelf.endMargin(shelf_h)
    -- The shelf's own sizing (SpineShelf.plan): one stand height wide at
    -- most by default, the overhang kept on the plank, a plank unit of room.
    local base    = SpineShelf.plankUnit(shelf_h)
    local budget  = Orn.maxWidth(stand_h, w - 2 * margin)
    local below   = SpineShelf.overhangReach(shelf_h)

    -- Every piece in the pack, switched off or not, in the browser's order.
    local scale = 100
    pcall(function()
        scale = require("lib/bookshelf_settings_store").read("stack_label_font_scale", 100) or 100
    end)
    local face = BFont:getFace(BFont.getUIFontFace() or "cfont", math.max(8, math.floor(14 * scale / 100 + 0.5)))
    local items = {}
    local n_on, n_off = 0, 0
    for _i, e in ipairs((Orn.listAll())) do
        if e.pack == self.pack then
            if Orn.isOff(e.name) then n_off = n_off + 1 else n_on = n_on + 1 end
            local pl = Orn.place(e, budget, stand_h,
                                 { max_room = w - 2 * margin, max_below = below }, 1)
            if pl then
                local label = Orn.displayName(e)
                if Orn.isOff(e.name) then label = T(_("%1 (off)"), label) end
                local tw = TextWidget:new{ text = label, face = face, padding = 0 }
                local badge_w = math.min(tw:getSize().w + Screen:scaleBySize(12), w - 2 * margin)
                tw:free()
                local pad = SpineShelf.ornPad(base, pl)
                local slot = math.max(pl.w + 2 * pad, badge_w + Screen:scaleBySize(8))
                items[#items + 1] = { pl = pl, label = label, badge_w = badge_w, slot = slot, pad = pad }
            end
        end
    end
    self._pages = M.layout(items, w, n_rows, margin)
    self.page = math.max(1, math.min(self.page, #self._pages))

    local kids = { dimen = Geom:new{ w = w, h = h }, Ground:new{ dimen = Geom:new{ w = w, h = h } } }
    local rows_w, hang_w = {}, {}
    self._piece_ws = {}
    -- The name badges hang below the plank: room for them over the info line.
    local row_y = h - footer_h - shelf_h - Screen:scaleBySize(26)
    -- The shelf above: a plank and nothing on it, so a top piece meets it.
    local above_y = row_y - gap - shelf_h
    if above_y + shelf_h > top then
        local g0 = SpineShelf.ornamentRow{ width = w, height = shelf_h, row_index = 1,
                                           lift_headroom = headroom, items = {} }
        g0.overlap_offset = { 0, above_y }
        rows_w[#rows_w + 1] = g0
    end
    for r, row in ipairs(self._pages[self.page] or {}) do
        local list = {}
        for _j, cell in ipairs(row) do
            local it = items[cell.i]
            -- Centred in its slot, so a short name's badge and the piece line up.
            list[#list + 1] = { pl = it.pl, label = it.label, badge_w = it.badge_w,
                                x = cell.x + math.floor((it.slot - it.pl.w) / 2) }
        end
        local y = row_y
        local g, hanging = SpineShelf.ornamentRow{
            width = w, height = shelf_h, row_index = r + 1, lift_headroom = headroom, items = list,
        }
        g.overlap_offset = { 0, y }
        rows_w[#rows_w + 1] = g
        -- The pieces, left to right, for picking by tap (their dimen is set
        -- where they paint).
        local ws = {}
        local function collect(n, d)
            if type(n) ~= "table" or d > 4 then return end
            if n.placement and n.placement.entry and not n.placement.crop then ws[#ws + 1] = n end
            for _k, c in ipairs(n) do collect(c, d + 1) end
        end
        collect(g, 0)
        for _k, hw in ipairs(hanging) do ws[#ws + 1] = hw end
        table.sort(ws, function(a, b) return (a.overlap_offset[1] or 0) < (b.overlap_offset[1] or 0) end)
        for _k, pw in ipairs(ws) do self._piece_ws[#self._piece_ws + 1] = pw end
        for _k, hw in ipairs(hanging) do
            hw.overlap_offset = { hw.overlap_offset[1], y + hw.overlap_offset[2] }
            hang_w[#hang_w + 1] = hw
        end
    end
    -- Pieces behind the shelf above first, then the rows over them.
    for _i, hw in ipairs(hang_w) do kids[#kids + 1] = hw end
    for _i, g in ipairs(rows_w) do kids[#kids + 1] = g end
    local foot = TextWidget:new{
        text = T(_("%1 on, %2 off · page %3 of %4 · swipe for more · tap a piece to adjust it"),
                 n_on, n_off, self.page, math.max(1, #self._pages)),
        face = face, padding = 0, max_width = w - 2 * margin,
    }
    foot.overlap_offset = { math.floor((w - foot:getSize().w) / 2), h - footer_h + math.floor((footer_h - foot:getSize().h) / 2) }
    kids[#kids + 1] = foot
    title.overlap_offset = { 0, 0 }
    kids[#kids + 1] = title
    self[1] = OverlapGroup:new(kids)
end

function Editor:onSwipe(_arg, ges)
    local dir = ges and ges.direction
    local n = #(self._pages or {})
    if dir == "west" and self.page < n then self.page = self.page + 1
    elseif dir == "east" and self.page > 1 then self.page = self.page - 1
    else return true end
    self:_rebuild()
    UIManager:setDirty(self, "ui")
    -- The new page's first piece, once it has painted (its place is the menu's).
    UIManager:scheduleIn(0.3, function() self:_select(1) end)
    return true
end

-- KOReader's own gestures (the menu, brightness) keep working over it: it
-- covers the screen, so they get what its own handlers leave
-- (GestureZones.overlayEvent; maintainer, PW5).
function Editor:handleEvent(event)
    return require("lib/bookshelf_gesture_zones").overlayEvent(self, event, InputContainer)
end

function Editor:onClose()
    UIManager:close(self)
    return true
end

function Editor:onCloseWidget()
    if self._menu then UIManager:close(self._menu); self._menu = nil end
    local Orn = require("lib/bookshelf_ornaments")
    Orn.handlers = self._handlers or Orn.handlers
    local ok, n = pcall(Orn.commitPack, self.pack)
    if ok and n and n > 0 then
        UIManager:show(require("ui/widget/infomessage"):new{
            text = T(_("Saved the settings of %1 pieces into the %2 pack."), n, self.pack),
            timeout = 3,
        })
    end
    local bw = self.bw
    if bw and bw._rebuild then
        UIManager:nextTick(function()
            bw:_rebuild()
            UIManager:setDirty(bw, "ui")
        end)
    end
end

function M.open(pack, bw)
    local e = Editor:new{ pack = pack, bw = bw }
    -- A full refresh: it replaces the whole shelf, and a partial one left
    -- the shelf's ghost under it on e-ink (maintainer).
    UIManager:show(e, "full")
    return e
end

-- choose(bw): which pack to edit, then the editor.
function M.choose(bw)
    local Orn = require("lib/bookshelf_ornaments")
    local _all, packs = Orn.listAll()
    if not packs or #packs == 0 then
        UIManager:show(require("ui/widget/infomessage"):new{ text = _("There are no ornament packs to edit."), timeout = 3 })
        return
    end
    local ButtonDialog = require("ui/widget/buttondialog")
    local d
    local rows = {}
    for _i, p in ipairs(packs) do
        rows[#rows + 1] = {{ text = p, callback = function() UIManager:close(d); M.open(p, bw) end }}
    end
    -- The title's X, not a lone Cancel row (STYLE.md).
    d = ButtonDialog:new(require("lib/bookshelf_module_kit").withClose{
        title = _("Pack editor"), title_align = "center", buttons = rows })
    UIManager:show(d)
end

M._Editor = Editor
return M
