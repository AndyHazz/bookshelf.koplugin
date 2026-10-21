--[[
Micro-module layout editor.

Opens on top of whichever surface owns the grid (the top panel in the shelf,
or the full-screen view) and edits it in place, at real size: the host keeps
drawing its own grid -- from the editor's working copy, with empty cells
dashed and the selection outlined -- and this widget only adds a floating
toolbar for the selected module and an edit footer (Done, pages, Add) over
the shelf's footer. All state and actions live in a ModuleGridSession; this
file draws it and routes taps and keys to it.

Host contract (HeroModules.heroEditHost, MicroFullscreen):
  host:gridInfo()    the host's own last-built grid (dims, boxes, page, ...)
  host:model()       the surface's model (load / save / nextId)
  host:render(edit)  rebuild the grid from edit (nil = from the store)
  host:footerRect()  Geom of the footer band the edit footer covers
]]
local Blitbuffer      = require("ffi/blitbuffer")
local ButtonDialog    = require("ui/widget/buttondialog")
local ButtonTable     = require("ui/widget/buttontable")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local InputContainer  = require("ui/widget/container/inputcontainer")
local Notification    = require("ui/widget/notification")
local TextWidget      = require("lib/bookshelf_colour_text")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Font            = require("ui/font")
local Size            = require("ui/size")
local logger          = require("logger")
local Grid            = require("lib/bookshelf_module_grid")
local Session         = require("lib/bookshelf_module_grid_session")
local Modules         = require("lib/bookshelf_start_menu_modules")
local BookshelfSettings = require("lib/bookshelf_settings_store")
local _               = require("lib/bookshelf_i18n").gettext
local T               = require("ffi/util").template
local Screen          = Device.screen

local Editor = InputContainer:extend{
    bw        = nil,
    host      = nil,
    select_id = nil,
}

--- Open the editor over the host's current grid, with select_id selected.
--- Returns the editor, or nil when the host has no grid to edit.
function Editor.open(o)
    local bw, host = o.bw, o.host
    -- The host's OWN grid: bw._module_grid is shared by both surfaces and the
    -- other one's rebuild can overwrite it.
    local info = bw and host and host.gridInfo and host:gridInfo()
    if not info then return nil end
    if bw._module_editor then return bw._module_editor end
    local ed = Editor:new{ bw = bw, host = host, info = info, select_id = o.select_id }
    UIManager:show(ed)
    -- Registered only once it is up: a failed open must not leave a dead
    -- editor that every later long-press would return.
    bw._module_editor = ed
    return ed
end

function Editor:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self._built_w, self._built_h = sw, sh
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    self.margin = Screen:scaleBySize(12)
    local bw, host = self.bw, self.host
    local info = self.info
    local HeroModules = require("lib/bookshelf_hero_modules")
    local editor = self
    -- The session re-renders through this: the host redraws its grid, then
    -- the editor rebuilds its toolbar for the new selection and repaints.
    local relay = {
        model  = function() return host:model() end,
        render = function(_r, edit)
            host:render(edit)
            editor:_buildBands()
            UIManager:setDirty(editor, "ui")
        end,
    }
    self.session = Session.new{
        host = relay,
        items = host:model().load(),
        boxes = info.boxes, dims = info.dims, key = info.key,
        page = info.page, selected_id = self.select_id,
        notify = function(text) UIManager:show(Notification:new{ text = text }) end,
        add_picker = function(on_added)
            local ok, Edit = pcall(require, "lib/bookshelf_hero_modules_edit")
            if ok and Edit then Edit.showAdd(bw, nil, on_added) end
        end,
        open_settings = function(entry)
            local def = entry and Modules.get(entry.module)
            if def and type(def.show_settings) == "function" then
                local ok, err = pcall(def.show_settings, HeroModules._ctx(bw, nil, entry))
                if not ok then logger.warn("[bookshelf] module settings failed:", entry.module, err) end
            end
        end,
        size_for = function(entry) return HeroModules._sizeFor(entry, info.dims) end,
        title_for = function(entry)
            local def = Modules.get(entry.module)
            return (def and def.title) or entry.module
        end,
        min_for = function(entry)
            local def = entry and Modules.get(entry.module)
            return (def and def.min_w) or 1, (def and def.min_h) or 1
        end,
    }
    if Device:hasKeys() then
        self.key_events = { Done = { { Device.input.group.Back } } }
    end
    if Device:hasDPad() then
        self.key_events.EdUp    = { { "Up" } }
        self.key_events.EdDown  = { { "Down" } }
        self.key_events.EdLeft  = { { "Left" } }
        self.key_events.EdRight = { { "Right" } }
        self.key_events.EdPress = { { "Press" } }
    end
    if Device:isTouchDevice() then
        self.ges_events = {
            EdTap   = { GestureRange:new{ ges = "tap",   range = self.dimen } },
            EdHold  = { GestureRange:new{ ges = "hold",  range = self.dimen } },
            EdSwipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
            EdPinch  = { GestureRange:new{ ges = "pinch",  range = self.dimen } },
            EdSpread = { GestureRange:new{ ges = "spread", range = self.dimen } },
        }
    end
    -- Draw the grid in edit mode, then the bands over it.
    self.session:_render()
end

-- ── Bands ────────────────────────────────────────────────────────────────────

local function button(text, callback, enabled)
    return { text = text, callback = callback, enabled = enabled ~= false }
end

-- A move chevron, in the symbols font at the size the other editors use.
local function chevron(glyph, callback)
    return { text = glyph, callback = callback,
             font_face = "symbols", font_size = 28, font_bold = false }
end

function Editor:_toolbarWidth()
    return self._built_w - 2 * self.margin
end

function Editor:_buildToolbar()
    local s = self.session
    local width = self:_toolbarWidth()
    local id = s.selected_id
    local entry = id and s:item(id)
    local box = id and s:box(id)
    -- Nothing selected: no toolbar at all (the hint lives in the footer), so
    -- the whole grid stays tappable.
    if not (entry and box) then return nil end
    local face = Font:getFace("cfont", 18)
    local rows
    local title
    do
        local def = Modules.get(entry.module)
        title = T(_("%1 · %2 × %3"), (def and def.title) or entry.module, box.w, box.h)
        local bottom = {}
        if def and type(def.show_settings) == "function" then
            bottom[#bottom + 1] = button(_("Settings"), function() s:settings() end)
        end
        bottom[#bottom + 1] = button(_("Remove"), function() s:remove() end)
        bottom[#bottom + 1] = button(_("Close"), function() s:select(nil) end)
        rows = {
            -- Size on the left, position on the right; each row one axis.
            {
                button(_("Narrower"), function() s:resize("w", -1) end),
                button(_("Wider"),    function() s:resize("w", 1) end),
                chevron(Session.CHEV_LEFT,  function() s:moveBy(-1, 0) end),
                chevron(Session.CHEV_RIGHT, function() s:moveBy(1, 0) end),
            },
            {
                button(_("Shorter"),  function() s:resize("h", -1) end),
                button(_("Taller"),   function() s:resize("h", 1) end),
                chevron(Session.CHEV_UP,    function() s:moveBy(0, -1) end),
                chevron(Session.CHEV_DOWN,  function() s:moveBy(0, 1) end),
            },
            bottom,
        }
    end
    local vg = VerticalGroup:new{
        align = "center",
        TextWidget:new{ text = title, face = face, max_width = width - 2 * self.margin },
    }
    if rows then
        vg[#vg + 1] = VerticalSpan:new{ width = Screen:scaleBySize(6) }
        vg[#vg + 1] = ButtonTable:new{
            width = width - 2 * Size.border.window - 2 * Size.padding.default,
            buttons = rows,
            zero_sep = true,
            show_parent = self,
        }
    end
    return FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius     = Size.radius.window,
        padding    = Size.padding.default,
        width      = width,
        vg,
    }
end

function Editor:_buildFooter(rect_w)
    local s = self.session
    local row = { button("\xE2\x9C\x93 " .. _("Done"), function() self:onDone() end) }
    if not s.selected_id and #s:pageList() <= 1 then
        row[#row + 1] = button(_("Tap a module to select it"), nil, false)
    end
    local pages = s:pageList()
    if #pages > 1 then
        for _i, p in ipairs(pages) do
            local label = (p == s.page) and "\xE2\x97\x8F" or "\xE2\x97\x8B"
            row[#row + 1] = button(label, function()
                if s.selected_id then s:moveToPage(p) else s:goPage(p) end
            end)
        end
    end
    local nxt = s.selected_id and s:newPage()
    if nxt then
        row[#row + 1] = button(_("New page"), function() s:moveToPage(nxt) end)
    end
    row[#row + 1] = button("+ " .. _("Add"), function() s:add() end)
    return FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding    = 0,
        ButtonTable:new{ width = rect_w, buttons = { row }, zero_sep = true, show_parent = self },
    }
end

function Editor:_footerRect()
    local r = self.host.footerRect and self.host:footerRect()
    if r and r.w and r.w > 0 then return r end
    local h = Screen:scaleBySize(60)
    return Geom:new{ x = 0, y = self._built_h - h, w = self._built_w, h = h }
end

function Editor:_buildBands()
    local old1, old2 = self[1], self[2]
    local fr = self:_footerRect()
    -- [1] the footer (always), [2] the toolbar (only with a selection).
    self[1] = self:_buildFooter(fr.w)
    self[2] = self:_buildToolbar()
    for _i, w in ipairs({ old1, old2 }) do
        if w and w.free then
            UIManager:nextTick(function() pcall(function() w:free() end) end)
        end
    end
end

-- Screen rect of the selected module, or nil.
function Editor:_selectionRect()
    local info = self.host:gridInfo()
    local s = self.session
    local box = s.selected_id and s:box(s.selected_id)
    if not (info and info.container and info.container.dimen and box and box.page == s.page) then
        return nil
    end
    local d = info.container.dimen
    if not d.x then return nil end
    local x, y, w, h = Grid.rect(info.dims, box)
    return Geom:new{ x = d.x + info.ox + x, y = d.y + info.oy + y, w = w, h = h }
end

function Editor:paintTo(bb, x, y)
    if Screen:getWidth() ~= self._built_w or Screen:getHeight() ~= self._built_h then
        -- The screen changed under us (rotation, window resize): keep what was
        -- edited and leave rather than draw at stale positions.
        UIManager:nextTick(function() self:onDone() end)
        return
    end
    local fr = self:_footerRect()
    local footer = self[1]
    local fh = footer:getSize().h
    local fy = math.max(fr.y, fr.y + fr.h - fh)
    footer:paintTo(bb, fr.x, fy)
    self._footer_rect = Geom:new{ x = fr.x, y = fy, w = fr.w, h = fh }

    local bar = self[2]
    if not bar then
        self._bar_rect = nil
        return
    end
    local bh = bar:getSize().h
    local sel = self:_selectionRect()
    local side = sel and Grid.toolbarSide(sel.y, sel.h, self._built_h) or "bottom"
    local ty
    if side == "bottom" then
        ty = fy - bh - self.margin
    else
        ty = self.margin
    end
    bar:paintTo(bb, self.margin, ty)
    self._bar_rect = Geom:new{ x = self.margin, y = ty, w = self:_toolbarWidth(), h = bh }
end

-- ── Input ────────────────────────────────────────────────────────────────────

local function inRect(pos, r)
    return pos and r and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

-- The module (on the current page) under a cell, or nil.
function Editor:_boxAt(col, row)
    local s = self.session
    for _i, b in ipairs(s.boxes) do
        if b.page == s.page and col >= b.col and col < b.col + b.w
                and row >= b.row and row < b.row + b.h then
            return b
        end
    end
end

-- The grid cell under a screen point (gaps snap to the nearer cell), or nil
-- when the point is off the grid.
function Editor:_cellAt(p)
    local info = self.host:gridInfo()
    local d = info and info.container and info.container.dimen
    if not (p and d and d.x) then return nil end
    return Grid.nearestCell(info.dims, p.x - d.x - info.ox, p.y - d.y - info.oy)
end

-- Off the grid and off our own bands: KOReader's gesture zones get it (the
-- top-edge menu, brightness and warmth swipes, corner taps), as they do in
-- the normal full-screen view. Swallowed either way.
local function passThrough(ges)
    pcall(function() require("lib/bookshelf_gesture_zones").tryLiveZones(ges) end)
    return true
end

function Editor:onEdTap(_arg, ges)
    local p = ges and ges.pos
    if inRect(p, self._bar_rect) or inRect(p, self._footer_rect) then return true end
    local col, row = self:_cellAt(p)
    if not col then return passThrough(ges) end
    local b = self:_boxAt(col, row)
    if b then
        self.session:select(b.id)
    elseif self.session.selected_id then
        self.session:moveToCell(col, row)
    end
    return true
end

-- Long-press: on a module, select it; on an empty cell, add a module there.
function Editor:onEdHold(_arg, ges)
    local p = ges and ges.pos
    if inRect(p, self._bar_rect) or inRect(p, self._footer_rect) then return true end
    local col, row = self:_cellAt(p)
    if not col then return passThrough(ges) end
    local b = self:_boxAt(col, row)
    if b then
        self.session:select(b.id)
    else
        self.session:add(col, row)
    end
    return true
end

local SWIPE_MOVE = { east = { 1, 0 }, west = { -1, 0 }, north = { 0, -1 }, south = { 0, 1 } }

-- Swipe a module to move it a cell that way (as the chevrons do, without
-- selecting it); a sideways
-- swipe over an empty cell turns the page; one that starts off the grid is
-- KOReader's.
function Editor:onEdSwipe(_arg, ges)
    local p = ges and ges.pos
    local dir = ges and ges.direction
    if inRect(p, self._bar_rect) or inRect(p, self._footer_rect) then return true end
    local col, row = self:_cellAt(p)
    if not col then return passThrough(ges) end
    local s = self.session
    local b = self:_boxAt(col, row)
    local mv = SWIPE_MOVE[dir]
    if b and mv then
        -- Moves the module under the finger without selecting it: the
        -- toolbar opens on a tap only.
        s:moveIdBy(b.id, mv[1], mv[2])
        return true
    end
    local pages = s:pageList()
    local idx = 1
    for i, pg in ipairs(pages) do if pg == s.page then idx = i end end
    if dir == "west" and pages[idx + 1] then s:goPage(pages[idx + 1])
    elseif dir == "east" and pages[idx - 1] then s:goPage(pages[idx - 1]) end
    return true
end

-- Two fingers on a module: spread to grow it, pinch to shrink it, along the
-- direction the fingers moved (diagonal: both ways). Like a swipe, it acts on
-- the module under the fingers without opening the toolbar.
local PINCH_AXES = { horizontal = { "w" }, vertical = { "h" }, diagonal = { "w", "h" } }

function Editor:_pinch(ges, delta)
    local col, row = self:_cellAt(ges and ges.pos)
    local b = col and self:_boxAt(col, row)
    local axes = PINCH_AXES[ges and ges.direction]
    if not (b and axes) then return true end
    for _i, axis in ipairs(axes) do self.session:resizeId(b.id, axis, delta) end
    return true
end
function Editor:onEdSpread(_arg, ges) return self:_pinch(ges, 1) end
function Editor:onEdPinch(_arg, ges)  return self:_pinch(ges, -1) end

-- Events a gesture zone emits (brightness, warmth, night mode, the menu) arrive
-- here, the topmost widget: hand on what we don't handle ourselves, as the
-- full-screen view does.
function Editor:handleEvent(event)
    if InputContainer.handleEvent(self, event) then return true end
    if event.handler == "onGesture" then return false end
    local ok, r = pcall(function()
        return require("lib/bookshelf_gesture_zones").forwardToLive(event, self)
    end)
    return ok and r or false
end

function Editor:_nav(dir)
    local HeroModules = require("lib/bookshelf_hero_modules")
    local s = self.session
    local rows = Grid.navRows(s.boxes, s.page)
    local nid = HeroModules.navMove(rows, s.selected_id, dir)
    if nid then s:select(nid) end
    return true
end
function Editor:onEdUp()    return self:_nav("up") end
function Editor:onEdDown()  return self:_nav("down") end
function Editor:onEdLeft()  return self:_nav("left") end
function Editor:onEdRight() return self:_nav("right") end

-- Keys-only: Press opens everything the toolbar and edit footer offer as a
-- dialog (which brings its own focus handling). It closes after each action
-- so the result isn't hidden under it; Press again for the next one.
function Editor:onEdPress()
    local s = self.session
    local entry = s.selected_id and s:item(s.selected_id)
    local def = entry and Modules.get(entry.module)
    local rows = s:keyActions{
        has_settings = def and type(def.show_settings) == "function",
        on_done = function() self:onDone() end,
    }
    local dialog
    for _i, row in ipairs(rows) do
        for _j, b in ipairs(row) do
            local fn = b.callback
            b.callback = function()
                UIManager:close(dialog)
                fn()
            end
        end
    end
    dialog = ButtonDialog:new{ buttons = rows }
    UIManager:show(dialog)
    return true
end

function Editor:onDone()
    if self._closed then return true end
    self._closed = true
    local ok, err = pcall(function() self.session:commit() end)
    if not ok then logger.warn("[bookshelf] layout editor: save failed:", err) end
    pcall(BookshelfSettings.flush)
    if self.bw._module_editor == self then self.bw._module_editor = nil end
    UIManager:close(self)
    self.host:render(nil)
    return true
end

-- Closed by anything other than Done (another widget closing the stack, the
-- shelf going away): still keep the edits and take the host out of edit mode,
-- or it would go on drawing the working copy with edit decorations.
function Editor:onCloseWidget()
    if self.bw and self.bw._module_editor == self then self.bw._module_editor = nil end
    if self._closed then return end
    self._closed = true
    pcall(function() self.session:commit() end)
    pcall(BookshelfSettings.flush)
    pcall(function() self.host:render(nil) end)
end

return Editor
