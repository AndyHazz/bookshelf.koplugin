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
    pcall(function() require("lib/bookshelf_hero_modules")._dropDimCache() end)
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
        -- A new selection alone: the host repaints its grid as built, if
        -- it can (MicroFullscreen:reselect), else the whole render.
        reselect = function(_r, edit)
            if not (host.reselect and host:reselect(edit)) then return false end
            local Perf = require("lib/bookshelf_perf")
            local t = Perf.now()
            editor:_buildBands()
            Perf.part("bars", t)
            editor:_dirty()
            return true
        end,
        render = function(_r, edit)
            local Perf = require("lib/bookshelf_perf")
            if not Perf.active() then Perf.start("editor change") end
            local t = Perf.now()
            host:render(edit)
            Perf.part("grid", t)
            t = Perf.now()
            editor:_buildBands()
            Perf.part("bars", t)
            editor:_dirty()
        end,
    }
    self.session = Session.new{
        host = relay,
        items = host:model().load(),
        boxes = info.boxes, dims = info.dims, key = info.key,
        page = info.page, selected_id = self.select_id,
        max_pages = host.max_pages and host.max_pages() or nil,
        notify = function(text) UIManager:show(Notification:new{ text = text }) end,
        -- A host may bring its own (the shelf's cards number their own ids).
        add_picker = host.add_picker or function(on_added, pick)
            local ok, Edit = pcall(require, "lib/bookshelf_hero_modules_edit")
            if ok and Edit then Edit.showAdd(bw, nil, on_added, pick) end
        end,
        open_settings = host.open_settings or function(entry)
            local def = entry and Modules.get(entry.module)
            if def and type(def.show_settings) == "function" then
                local ok, err = pcall(def.show_settings, HeroModules._ctx(bw, nil, entry))
                if not ok then logger.warn("[bookshelf] module settings failed:", entry.module, err) end
            end
        end,
        -- Style: the module's card and colours, saved on it.
        -- host.ctx_for (optional) is how the host saves a module (a shelf
        -- saves its own list); else the module's own ctx.
        open_colors = function(entry)
            local ctx = (host.ctx_for and host.ctx_for(entry)) or HeroModules._ctx(bw, nil, entry)
            require("lib/bookshelf_module_card_menu").show(ctx)
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
-- The toolbar and the edit footer are the popup kit's controls (STYLE.md):
-- closed rounded buttons set in from the frame, steppers for a size, the X
-- in the title for Close. A stock button grid's separators ran into the
-- frame and, in the footer with no frame, ended nowhere.

local FS = 18

-- kbutton(o) -> a kit button the keys can press too: o.text and/or o.glyph
-- (symbols font), o.on_tap, o.enabled, o.bold, o.inverted, o.h, o.pad_h, o.width,
-- o.card (a kit card: grey, no outline, a hairline shadow), o.square_bottom.
-- callback and enabled are what the editor's keys read (_keyRows).
local function kbutton(o)
    local Kit  = require("lib/bookshelf_popup_kit")
    local enabled = o.enabled ~= false
    local btn = Kit.button{
        text = o.text, face = o.text and require("lib/bookshelf_fonts"):getFace("cfont", o.font_size or FS) or nil,
        bold = o.bold, inverted = o.inverted,
        icon_glyph = o.glyph,
        icon_face = o.glyph and Font:getFace("symbols", o.glyph_size or (FS + 6)) or nil,
        height = o.h, pad_h = o.pad_h, width = o.width, enabled = enabled, on_tap = o.on_tap,
        card = o.card, square_bottom = o.square_bottom,
        -- A nudge acts at once, no pressed look first (STYLE.md).
        instant = o.instant,
    }
    btn.callback = o.on_tap
    btn.enabled = enabled
    return btn
end

-- line(items, gap) -> items side by side, centred on one line.
local function line(items, gap)
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan  = require("ui/widget/horizontalspan")
    local hg = HorizontalGroup:new{ align = "center" }
    for i, w in ipairs(items) do
        if i > 1 then hg[#hg + 1] = HorizontalSpan:new{ width = gap } end
        hg[#hg + 1] = w
    end
    return hg
end

function Editor:_toolbarWidth()
    return self._built_w - 2 * self.margin
end

-- The keys' rows of the toolbar and the footer, top to bottom (_keyRows).
function Editor:_buildToolbar()
    local s = self.session
    local width = self:_toolbarWidth()
    local id = s.selected_id
    local entry = id and s:item(id)
    local box = id and s:box(id)
    self._bar_rows = nil
    -- Nothing selected: no toolbar at all (the hint lives in the footer), so
    -- the whole grid stays tappable.
    if not (entry and box) then return nil end
    local Space = require("lib/bookshelf_space")
    local inset = Space.px(16)
    local gap   = Space.px(10)
    local face  = require("lib/bookshelf_fonts"):getFace("cfont", FS)
    local h = TextWidget:new{ text = "Hg", face = face }:getSize().h + 2 * Space.px(10)
    local def = Modules.get(entry.module)
    local title = (def and def.title) or entry.module
    -- A size button that would do nothing is greyed, so the toolbar keeps
    -- its shape under the finger. On a shelf Height is left out: a shelf
    -- module is one row tall, so it never applies there (maintainer).
    local on_shelf = self.host.shelf
    local rows = {}
    -- stepper(label, axis, value) -> "Width  − 2 +", its two buttons a keys row.
    local function stepper(label, axis, value)
        if on_shelf and axis == "h" then return nil end
        -- Grey cards: they nudge a value (STYLE.md), as every stepper's.
        local Kit = require("lib/bookshelf_popup_kit")
        local minus = kbutton{ glyph = Kit.MINUS, h = h, pad_h = Space.px(14), card = true, instant = true,
            enabled = s:canResize(axis, -1), on_tap = function() s:resize(axis, -1) end }
        local plus = kbutton{ glyph = Kit.PLUS, h = h, pad_h = Space.px(14), card = true, instant = true,
            enabled = s:canResize(axis, 1), on_tap = function() s:resize(axis, 1) end }
        local CenterContainer = require("ui/widget/container/centercontainer")
        local val = CenterContainer:new{ dimen = Geom:new{ w = Space.px(48), h = h },
            TextWidget:new{ text = tostring(value), face = face, bold = true } }
        return { label = label, ctl = line({ minus, val, plus }, 0) }, { minus, plus }
    end
    local width_ctl, wf = stepper(_("Width"), "w", box.w)
    local height_ctl, hf = stepper(_("Height"), "h", box.h)
    -- Move by a cell on a d-pad, and to the previous or next page: the
    -- footer's page numbers also take the selection there, but nothing said
    -- so (maintainer). The d-pad's keys are cards, grey with no outline,
    -- so it reads as one pad beside the outlined buttons (maintainer).
    local function chev(glyph, dx, dy)
        return kbutton{ glyph = glyph, h = h, pad_h = Space.px(14), card = true, instant = true,
            on_tap = function() s:moveBy(dx, dy) end }
    end
    local function pageButton(glyph, dir)
        local p = s:adjacentPage(dir)
        return kbutton{ glyph = glyph, h = h, pad_h = Space.px(14), enabled = p ~= nil,
            on_tap = function() if p then s:moveToPage(p) end end }
    end
    local up, left = chev(Session.CHEV_UP, 0, -1), chev(Session.CHEV_LEFT, -1, 0)
    local right, down = chev(Session.CHEV_RIGHT, 1, 0), chev(Session.CHEV_DOWN, 0, 1)
    local prev, nxt = pageButton(Session.PAGE_PREV, -1), pageButton(Session.PAGE_NEXT, 1)
    -- Settings, Style (its colours: the palette, out of the title,
    -- maintainer) and Remove, one width: built once to measure, then at the
    -- widest one's width.
    local CardMenu = require("lib/bookshelf_module_card_menu")
    local function actionButtons(w)
        local out = {}
        if def and type(def.show_settings) == "function" then
            out[#out + 1] = kbutton{ text = _("Settings"), glyph = "\xEF\x80\x93", glyph_size = FS,
                h = h, width = w, on_tap = function() s:settings() end }
        end
        if CardMenu.hasColours(entry) then
            out[#out + 1] = kbutton{ text = _("Style"), glyph = require("lib/bookshelf_menu_icons").COLORS,
                glyph_size = FS, h = h, width = w, on_tap = function() s:colors() end }
        end
        out[#out + 1] = kbutton{ text = _("Remove"), glyph = "\xEE\xA2\xBF", glyph_size = FS,
            h = h, width = w, on_tap = function() s:remove() end }
        return out
    end
    local actions = actionButtons()
    local aw = 0
    for _i, b in ipairs(actions) do aw = math.max(aw, b:getSize().w) end
    if #actions > 1 then actions = actionButtons(aw) end
    -- The keys' rows in reading order, one per line of the d-pad (the
    -- arrows move by where the buttons are, _keyMove).
    local function join(...)
        local out = {}
        for _i, t in ipairs({ ... }) do
            for _j, b in ipairs(t) do out[#out + 1] = b end
        end
        return out
    end

    -- The d-pad at the left: three rows of square cells, the arrows round
    -- an empty middle. Beside it, a line for each of its rows: Width,
    -- Height and Page; then Settings, Style and Remove.
    local CenterContainer = require("ui/widget/container/centercontainer")
    local HorizontalSpan  = require("ui/widget/horizontalspan")
    local cell = h
    for _i, b in ipairs({ up, left, right, down }) do cell = math.max(cell, b:getSize().w) end
    local dgap = Space.px(4)
    local function slot(b)
        if b then return CenterContainer:new{ dimen = Geom:new{ w = cell, h = h }, b } end
        return HorizontalSpan:new{ width = cell }
    end
    local dpad = VerticalGroup:new{ align = "left",
        line({ slot(), slot(up), slot() }, dgap),
        VerticalSpan:new{ width = dgap },
        line({ slot(left), slot(), slot(right) }, dgap),
        VerticalSpan:new{ width = dgap },
        line({ slot(), slot(down), slot() }, dgap),
    }
    -- Page: « number » under the steppers' − value +, so the three line up.
    local page_ctl = { label = _("Page"), ctl = line({ prev,
        CenterContainer:new{ dimen = Geom:new{ w = Space.px(48), h = h },
            TextWidget:new{ text = tostring(s.page or 1), face = face, bold = true } },
        nxt }, 0) }
    -- Width, Height and Page share one label width, so their controls line up.
    local lw = 0
    for _i, it in ipairs({ width_ctl, height_ctl, page_ctl }) do
        if it then
            local t = TextWidget:new{ text = it.label, face = face }
            lw = math.max(lw, t:getSize().w)
            if t.free then t:free() end
        end
    end
    local LeftContainer = require("ui/widget/container/leftcontainer")
    local function labelled(it)
        return line({ LeftContainer:new{ dimen = Geom:new{ w = lw, h = h },
            TextWidget:new{ text = it.label, face = face } }, it.ctl }, gap)
    end
    -- On a shelf there is no Height: Width and Page close up, and with the
    -- actions they sit centred on the d-pad, not with a row's gap between
    -- them (maintainer).
    local side = VerticalGroup:new{ align = "left" }
    for _i, it in ipairs({ width_ctl or false, height_ctl or false, page_ctl }) do
        if it then
            if #side > 0 then side[#side + 1] = VerticalSpan:new{ width = dgap } end
            side[#side + 1] = labelled(it)
        end
    end
    -- Settings, Style and Remove at the right, level with the d-pad's rows.
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local stack = VerticalGroup:new{ align = "left" }
    for i, b in ipairs(actions) do
        if i > 1 then stack[#stack + 1] = VerticalSpan:new{ width = dgap } end
        stack[#stack + 1] = b
    end
    local col_gap = Space.px(32)
    local pad_side = HorizontalGroup:new{ align = "center",
        dpad, HorizontalSpan:new{ width = col_gap }, side }
    -- The room inside the frame. With no room for the actions' column (a
    -- small screen), they go on a line of their own under the rest, so the
    -- toolbar fits any screen (STYLE.md) instead of running off its edges.
    local room = width - 2 * inset - 2 * Size.border.window
    local body
    if pad_side:getSize().w + col_gap + stack:getSize().w > room then
        body = VerticalGroup:new{ align = "center", pad_side,
            VerticalSpan:new{ width = Space.px(14) }, line(actions, gap) }
        rows[#rows + 1] = join({ up }, wf)
        rows[#rows + 1] = join({ left, right }, hf or {})
        rows[#rows + 1] = join({ down, prev, nxt })
        rows[#rows + 1] = actions
    else
        body = HorizontalGroup:new{ align = "center",
            pad_side, HorizontalSpan:new{ width = col_gap }, stack }
        rows[#rows + 1] = join({ up }, wf, { actions[1] })
        rows[#rows + 1] = join({ left, right }, hf or {}, { actions[2] })
        rows[#rows + 1] = join({ down, prev, nxt }, { actions[3] })
    end
    -- As wide as its controls, not the screen, so it covers less of the
    -- grid (maintainer); centred over it (paintTo).
    width = math.min(width, body:getSize().w + 2 * inset + 2 * Size.border.window)

    -- Title: the module's name, centred, and the X that closes the toolbar
    -- (Close alone is the X, STYLE.md).
    local xb = require("ui/widget/iconbutton"):new{
        icon = "close", width = math.floor(h * 0.6), height = math.floor(h * 0.6),
        padding = Space.px(4), show_parent = self,
        callback = function() s:select(nil) end,
    }
    xb.enabled = true
    local tw = width - 2 * Size.border.window - 2 * Size.padding.default - xb:getSize().w
    local xw = xb:getSize().w
    -- In a menu's title font, bold, and only as tall as it and the X
    -- (the library pickers' title bar).
    local title_face, title_bold = require("lib/bookshelf_fonts"):getFace("cfont", 22, { bold = true })
    local title_w = TextWidget:new{ text = title, face = title_face, bold = title_bold,
        max_width = math.max(1, tw - xw) }
    local title_h = math.max(title_w:getSize().h, xb:getSize().h)
    local title_row = line({ HorizontalSpan:new{ width = xw },
        CenterContainer:new{ dimen = Geom:new{ w = math.max(1, tw - xw), h = title_h }, title_w } }, 0)
    -- The X is the keys' first row.
    table.insert(rows, 1, { xb })
    local VG = VerticalGroup:new{ align = "left", body }
    local LineWidget = require("ui/widget/linewidget")
    local inner_w = width - 2 * Size.border.window
    local vg = VerticalGroup:new{
        align = "center",
        FrameContainer:new{ bordersize = 0, padding = Size.padding.default,
            padding_top = Space.px(8), padding_bottom = Space.px(8),
            line({ title_row, xb }, 0) },
        LineWidget:new{ background = Blitbuffer.COLOR_DARK_GRAY,
            dimen = Geom:new{ w = inner_w, h = Size.line.thin } },
        FrameContainer:new{ bordersize = 0, padding = inset, padding_top = Space.px(14),
            width = inner_w, VG },
    }
    self._bar_rows = rows
    return FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius     = Size.radius.window,
        padding    = 0,
        width      = width,
        vg,
    }
end

-- _buildFooter(rect_w, rect_h): the edit footer, rect_w wide (the screen)
-- and rect_h tall (from the shelf's footer to the bottom of the screen), its
-- buttons flush with the bottom, square there: there is no room for a
-- margin under them, and cut off they looked like a mistake (maintainer).
function Editor:_buildFooter(rect_w, rect_h)
    local s = self.session
    local Space = require("lib/bookshelf_space")
    local Kit   = require("lib/bookshelf_popup_kit")
    local inset = Space.px(16)
    local gap   = Space.px(10)
    local pad_top = Space.px(8)
    local h = TextWidget:new{ text = "Hg", face = require("lib/bookshelf_fonts"):getFace("cfont", FS) }:getSize().h + 2 * Space.px(10)
    h = math.min(h, math.max(Space.px(32), (rect_h or 0) - Size.line.thin - pad_top))
    pad_top = math.max(pad_top, (rect_h or 0) - Size.line.thin - h)
    -- On a shelf the pages are the shelf's own, of books: no page dots, no
    -- New page (maintainer). A module moves a page with the toolbar's
    -- double chevrons.
    local info = self.host and self.host.gridInfo and self.host:gridInfo()
    local on_shelf = info and info.surface == "shelf"
    -- + Add first and Done last, where a dialog's confirm sits (maintainer).
    local left = { kbutton{ text = _("Add"), glyph = "\xEF\x91\x8D", glyph_size = FS, h = h,
        square_bottom = true, on_tap = function() s:add() end } }
    local middle = {}
    local pages = s:pageList()
    if #pages > 1 and not on_shelf then
        -- The page dots: the one shown black (on), a tap goes there or takes
        -- the selection there.
        for _i, p in ipairs(pages) do
            middle[#middle + 1] = kbutton{ text = tostring(p), h = h, pad_h = Space.px(14),
                square_bottom = true, inverted = p == s.page, bold = p == s.page,
                on_tap = function()
                    if s.selected_id then s:moveToPage(p) else s:goPage(p) end
                end }
        end
    end
    local nxt = s.selected_id and not on_shelf and s:newPage()
    if nxt then
        middle[#middle + 1] = kbutton{ text = _("New page"), h = h, square_bottom = true,
            on_tap = function() s:moveToPage(nxt) end }
    end
    local done = kbutton{ text = _("Done"), glyph = "\xEE\xA0\xAB", glyph_size = FS, h = h,
        bold = true, square_bottom = true, on_tap = function() self:_finish() end }
    local inner = rect_w - 2 * inset
    local lw = left[1]:getSize().w
    local dw = done:getSize().w
    local mid
    if #middle > 0 then
        mid = line(middle, gap)
    elseif not s.selected_id then
        -- A hint, grey text: not a greyed-out button (STYLE.md). The room
        -- between Add and Done, centred in it: with no width it took a fixed
        -- box, off centre, and on a narrow screen ran under the buttons.
        mid = Kit.hintText(_("Tap a module to select it"), FS,
            math.max(Space.px(40), inner - lw - dw - 2 * gap), "center")
    end
    local CenterContainer = require("ui/widget/container/centercontainer")
    local row = line({ left[1],
        CenterContainer:new{ dimen = Geom:new{ w = math.max(0, inner - lw - dw - 2 * gap), h = h },
            mid or VerticalSpan:new{ width = 0 } },
        done }, gap)
    local keys = { left[1] }
    for _i, b in ipairs(middle) do keys[#keys + 1] = b end
    keys[#keys + 1] = done
    self._foot_rows = { keys }
    local LineWidget = require("ui/widget/linewidget")
    return FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding    = 0,
        VerticalGroup:new{ align = "left",
            LineWidget:new{ background = Blitbuffer.COLOR_DARK_GRAY,
                dimen = Geom:new{ w = rect_w, h = Size.line.thin } },
            FrameContainer:new{ bordersize = 0, margin = 0, width = rect_w,
                padding_left = inset, padding_right = inset,
                padding_top = pad_top, padding_bottom = 0, row } },
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
    -- The footer runs the screen's width, from the shelf's footer down.
    self[1] = self:_buildFooter(self._built_w, self._built_h - fr.y)
    self[2] = self:_buildToolbar()
    -- Rebuilt after every change: key focus goes back on the same button.
    if self._key_focus then self:_applyKeyFocus() end
    -- A piece newly selected other than by the grid's arrows (opened on it
    -- from a menu, just added) with the keys: focus on its toolbar, not the
    -- grid, where only Enter reached it and nothing said so (maintainer,
    -- desktop).
    local sel = self.session and self.session.selected_id
    if sel ~= self._last_sel then
        self._last_sel = sel
        if sel and not self._key_focus and not self._nav_selecting and Device:hasDPad() then
            self:_enterKeyFocus()
        end
    end
    for _i, w in ipairs({ old1, old2 }) do
        if w and w.free then
            UIManager:nextTick(function() pcall(function() w:free() end) end)
        end
    end
end

-- _dirty(): repaint the editor and refresh only what a change can touch:
-- the toolbar where it was and where it is now, the footer, the grid (with
-- room for its rings and shadows) and what modules drew past it, before and
-- after. The screen outside stays as faded; a whole-screen refresh for
-- every tap and arrow was e-ink time for nothing.
function Editor:_dirty()
    local before = { self._bar_rect }
    for _i, o in ipairs(self._last_overs or {}) do before[#before + 1] = o end
    UIManager:setDirty(self, function()
        -- Added one by one: a literal starting with a nil (the toolbar just
        -- closed) has a hole, and # past it can be 0 on LuaJIT, which left
        -- where the toolbar was unrefreshed.
        local rects = {}
        local function add(r) if r then rects[#rects + 1] = r end end
        add(self._bar_rect); add(self._footer_rect)
        for _i, r in ipairs(before) do add(r) end
        for _i, o in ipairs(self._last_overs or {}) do rects[#rects + 1] = o end
        local info = self.host:gridInfo()
        local d = info and info.container and info.container.dimen
        if not (d and d.x) then return "ui" end
        local pad = Screen:scaleBySize(8)
        local u = Geom:new{ x = d.x - pad, y = d.y - pad, w = d.w + 2 * pad, h = d.h + 2 * pad }
        for _i, r in ipairs(rects) do
            if r and r.w and r.w > 0 then u = u:combine(Geom:new{ x = r.x, y = r.y, w = r.w, h = r.h }) end
        end
        return "ui", u
    end)
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

-- How far the screen around the editable modules is faded: towards white,
-- which a night-mode panel shows as towards black, or towards black on a dark
-- theme. The background either way.
Editor.FADE = 0.6

-- _fadeDark() -> true when darkening is what shows as the dark theme's
-- background: the shelf wants dark and the frame doesn't invert (night mode
-- inverts lightened paint to dark already). The theme, not the cards: a
-- light shelf may have dark cards, and its fade should still be light.
function Editor._fadeDark()
    local ok, CP = pcall(require, "lib/bookshelf_cover_progress")
    if not (ok and CP and CP.theme) then return false end
    local want_dark, inverting = CP.theme()
    return want_dark ~= inverting
end

-- _fadeAround(bb): fade everything on screen but the modules on this page,
-- so it is plain that only they answer while the editor is up (maintainer:
-- with the shelf looking as usual, taps on books or a page swipe doing
-- nothing was a puzzle, and the edit bar alone was easy to miss). Each
-- module's rect, with room for its ring and shadow, is copied out, the whole
-- screen is lightened, and the copies go back.
-- The faded screen outside the grid is the same paint after paint while the
-- editor is up (the top panel's shelf, the full-screen view's ground): it was
-- faded afresh every time, 600-740 ms of each select or change on a PW5. The
-- first fade is kept (_fade_cache, the whole screen as faded, the grid and a
-- heading hanging past it left clear) and its outside put back after that.
-- Keyed on the kept rect, the fade's direction and the screen; a minute old
-- it is redone, so the status line's clock can't go stale. A cover shelf's
-- modules move among the books, which reflow, so it fades afresh each time.
Editor.FADE_CACHE_SECS = 60

-- _fadeFromCache(bb, key, x0, y0, w, h) -> true when the cached fade was put
-- back around the kept rect.
function Editor:_fadeFromCache(bb, key, x0, y0, w, h)
    local c = self._fade_cache
    if not (c and c.key == key and os.time() - c.t < Editor.FADE_CACHE_SECS) then return false end
    local W, H = bb:getWidth(), bb:getHeight()
    if c.bb:getWidth() ~= W or c.bb:getHeight() ~= H then return false end
    -- The four bands around the kept rect.
    if y0 > 0 then bb:blitFrom(c.bb, 0, 0, 0, 0, W, y0) end
    if y0 + h < H then bb:blitFrom(c.bb, 0, y0 + h, 0, y0 + h, W, H - y0 - h) end
    if x0 > 0 then bb:blitFrom(c.bb, 0, y0, 0, y0, x0, h) end
    if x0 + w < W then bb:blitFrom(c.bb, x0 + w, y0, x0 + w, y0, W - x0 - w, h) end
    return true
end

function Editor:_dropFadeCache()
    local c = self._fade_cache
    self._fade_cache = nil
    if c and c.bb then c.bb:free() end
end

function Editor:_fadeAround(bb)
    local info = self.host:gridInfo()
    local d = info and info.container and info.container.dimen
    local keep = {}
    local cache_key, kx, ky, kw, kh
    local overs = {}
    if d and d.x and info.surface ~= "shelf" then
        -- The top panel and full screen: their whole grid stays clear, so
        -- the empty cells' dashed outlines show where a module can go
        -- (maintainer). A cover shelf's grid is its books' slots: only its
        -- modules stay clear there.
        local pad = Screen:scaleBySize(8)
        local _gx, _gy, gw, gh = Grid.rect(info.dims, { col = 1, row = 1,
            w = info.dims.cols, h = info.dims.rows })
        local x0 = math.max(0, d.x + info.ox - pad)
        local y0 = math.max(0, d.y + info.oy - pad)
        local w = math.min(bb:getWidth() - x0, gw + 2 * pad)
        local h = math.min(bb:getHeight() - y0, gh + 2 * pad)
        kx, ky, kw, kh = x0, y0, w, h
        -- What the modules drew past the grid in its latest paint (a Shelf
        -- module's heading, below its plank): clear, not half faded. Taken
        -- off the screen as it is now and put back over the fade, never
        -- kept in the stored fade: a heading hidden since stayed painted
        -- there, put back with every repaint (maintainer).
        overs = Editor._overhangCopies(bb, x0, y0, w, h)
        self._last_overs = overs
        -- Where they are is in the key: the stored fade was made with them on
        -- screen, so a heading hidden since left its faded ghost in it.
        local where = {}
        for _i, k in ipairs(overs) do where[#where + 1] = k.x .. ":" .. k.y .. ":" .. k.w .. ":" .. k.h end
        cache_key = table.concat({ x0, y0, w, h, tostring(Editor._fadeDark()),
            bb:getWidth(), bb:getHeight(), table.concat(where, ";") }, ",")
        if self:_fadeFromCache(bb, cache_key, x0, y0, w, h) then
            Editor._putBack(bb, overs)
            return
        end
        if w > 0 and h > 0 then
            local copy = Blitbuffer.new(w, h, bb:getType())
            copy:blitFrom(require("lib/bookshelf_clip_bb").real(bb), 0, 0, x0, y0, w, h)
            keep[#keep + 1] = { copy = copy, x = x0, y = y0, w = w, h = h }
        end
    elseif d and d.x then
        -- Nothing under the editor repainted since its last fade (a key
        -- focus move repaints the editor alone): the screen is still faded,
        -- and fading it again darkened it at every arrow (maintainer).
        if Editor._stillFaded(require("lib/bookshelf_clip_bb").real(bb), self._fade_marks) then return end
        local pad = Screen:scaleBySize(8)
        for _i, b in ipairs(self.session.boxes) do
            if b.page == self.session.page then
                local rx, ry, rw, rh = Grid.rect(info.dims, b)
                local x0 = math.max(0, d.x + info.ox + rx - pad)
                local y0 = math.max(0, d.y + info.oy + ry - pad)
                local w = math.min(bb:getWidth() - x0, rw + 2 * pad)
                local h = math.min(bb:getHeight() - y0, rh + 2 * pad)
                if w > 0 and h > 0 then
                    local copy = Blitbuffer.new(w, h, bb:getType())
                    copy:blitFrom(require("lib/bookshelf_clip_bb").real(bb), 0, 0, x0, y0, w, h)
                    keep[#keep + 1] = { copy = copy, x = x0, y = y0, w = w, h = h }
                end
            end
        end
    end
    -- Faded in a copy, then written back: never blended on the screen
    -- itself. A Kindle's framebuffer is slow memory to read back, and the
    -- blend reads every pixel: ~650 ms on a PW5, where the same blend in a
    -- copy is 23 ms and the copy itself 70 ms (editdrive probe).
    local W, H = bb:getWidth(), bb:getHeight()
    local c = Blitbuffer.new(W, H, bb:getType())
    c:blitFrom(require("lib/bookshelf_clip_bb").real(bb), 0, 0, 0, 0, W, H)
    local fade = Editor._fadeDark() and c.darkenRect or c.lightenRect
    fade(c, 0, 0, W, H, Editor.FADE)
    for _i, k in ipairs(keep) do
        c:blitFrom(k.copy, k.x, k.y, 0, 0, k.w, k.h)
        k.copy:free()
    end
    if not cache_key then
        self._fade_marks = Editor._fadeMarks(require("lib/bookshelf_clip_bb").real(bb), c, keep)
    end
    if cache_key and kw and kw > 0 and kh > 0 then
        -- Kept, and its outside written to the screen as a kept one is.
        self:_dropFadeCache()
        self._fade_cache = { key = cache_key, bb = c, t = os.time() }
        self:_fadeFromCache(bb, cache_key, kx, ky, kw, kh)
    else
        bb:blitFrom(c, 0, 0, 0, 0, W, H)
        c:free()
    end
    Editor._putBack(bb, overs)
end

-- _fadeMarks(orig, faded, keep) -> up to 24 points, outside the kept rects,
-- where the fade changed the screen, with the faded value. _stillFaded(bb,
-- marks) -> true when most of them still hold it: nothing under the editor
-- was repainted, so there is nothing to fade. Most, not all: the toolbar may
-- since have been painted over a few. A fade that changed nothing leaves no
-- marks, and doing it again changes nothing either.
local function grey(bb, x, y) return bb:getPixel(x, y):getColor8().a end
function Editor._fadeMarks(orig, faded, keep)
    local W, H = faded:getWidth(), faded:getHeight()
    local N = 12
    local marks = {}
    for i = 1, N do
        for j = 1, N do
            local x, y = math.floor((i - 0.5) * W / N), math.floor((j - 0.5) * H / N)
            local inside = false
            for _k, k in ipairs(keep) do
                if x >= k.x and x < k.x + k.w and y >= k.y and y < k.y + k.h then inside = true; break end
            end
            if not inside then
                local v = grey(faded, x, y)
                if v ~= grey(orig, x, y) then
                    marks[#marks + 1] = { x = x, y = y, v = v }
                    if #marks >= 24 then return marks end
                end
            end
        end
    end
    return marks
end
function Editor._stillFaded(bb, marks)
    if not marks or #marks == 0 then return false end
    local same = 0
    for _i, m in ipairs(marks) do
        if grey(bb, m.x, m.y) == m.v then same = same + 1 end
    end
    return same * 2 > #marks
end

-- _overhangCopies(bb, x0, y0, w, h) -> copies, off the screen, of what the
-- grid's modules drew past the kept rect in its latest paint
-- (HeroModules._frame_overhangs).
function Editor._overhangCopies(bb, x0, y0, w, h)
    local out = {}
    local ok, HeroModules = pcall(require, "lib/bookshelf_hero_modules")
    for _i, r in ipairs(ok and HeroModules._frame_overhangs or {}) do
        local inside = r.x >= x0 and r.y >= y0 and r.x + r.w <= x0 + w and r.y + r.h <= y0 + h
        local bx, by = math.max(0, r.x), math.max(0, r.y)
        local bw = math.min(bb:getWidth() - bx, r.x + r.w - bx)
        local bh = math.min(bb:getHeight() - by, r.y + r.h - by)
        if not inside and bw > 0 and bh > 0 then
            local c = Blitbuffer.new(bw, bh, bb:getType())
            c:blitFrom(require("lib/bookshelf_clip_bb").real(bb), 0, 0, bx, by, bw, bh)
            out[#out + 1] = { copy = c, x = bx, y = by, w = bw, h = bh }
        end
    end
    return out
end

function Editor._putBack(bb, copies)
    for _i, k in ipairs(copies or {}) do
        bb:blitFrom(k.copy, k.x, k.y, 0, 0, k.w, k.h)
        k.copy:free()
    end
end

function Editor:paintTo(bb, x, y)
    if Screen:getWidth() ~= self._built_w or Screen:getHeight() ~= self._built_h then
        -- The screen changed under us (rotation, window resize): keep what was
        -- edited and leave rather than draw at stale positions.
        UIManager:nextTick(function() self:_finish() end)
        return
    end
    local Perf = require("lib/bookshelf_perf")
    local t_paint = Perf.now()
    pcall(self._fadeAround, self, bb)
    Perf.part("fade", t_paint)
    local footer = self[1]
    local fh = footer:getSize().h
    local fy = self._built_h - fh
    footer:paintTo(bb, 0, fy)
    self._footer_rect = Geom:new{ x = 0, y = fy, w = self._built_w, h = fh }

    local bar = self[2]
    if not bar then
        self._bar_rect = nil
        Perf.part("paint editor", t_paint)
        Perf.finish("editor painted")
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
    local bw = bar:getSize().w
    local tx = math.floor((self._built_w - bw) / 2)
    bar:paintTo(bb, tx, ty)
    self._bar_rect = Geom:new{ x = tx, y = ty, w = bw, h = bh }
    Perf.part("paint editor", t_paint)
    Perf.finish("editor painted")
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
    pcall(function() require("lib/bookshelf_gesture_zones").tryLiveZones(ges, { open_book = true }) end)
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
        return require("lib/bookshelf_gesture_zones").forwardToLive(event, self, { open_book = true })
    end)
    return ok and r or false
end

function Editor:_nav(dir)
    local HeroModules = require("lib/bookshelf_hero_modules")
    local s = self.session
    local rows = Grid.navRows(s.boxes, s.page)
    local nid = HeroModules.navMove(rows, s.selected_id, dir)
    if nid then
        -- The arrows walk the grid: the toolbar does not take them.
        self._nav_selecting = true
        pcall(s.select, s, nid)
        self._nav_selecting = nil
    end
    return true
end
-- ── Keys on the toolbar ──────────────────────────────────────────────────
-- Press puts key focus on the toolbar on screen: the X in its title, its
-- rows of buttons and the footer below, a grid the arrows move
-- along. Press then presses the focused button and Back goes back to the
-- grid, where the arrows select modules (maintainer: on the desktop emulator
-- keys could not reach the toolbar). _key_focus = { row, col } in _keyRows.
function Editor:_keyRows()
    local rows = {}
    for _i, t in ipairs({ self._bar_rows or {}, self._foot_rows or {} }) do
        for _j, r in ipairs(t) do
            if #r > 0 then rows[#rows + 1] = r end
        end
    end
    return rows
end
local function usable(b) return b and b.enabled ~= false end
function Editor:_applyKeyFocus()
    local rows = self:_keyRows()
    local f = self._key_focus
    if self._focused_btn and self._focused_btn.onUnfocus then self._focused_btn:onUnfocus() end
    self._focused_btn = nil
    if not f or #rows == 0 then self._key_focus = nil; self:_dirty(); return end
    f.row = math.max(1, math.min(f.row, #rows))
    f.col = math.max(1, math.min(f.col, #rows[f.row]))
    local b = rows[f.row][f.col]
    if b and b.onFocus then b:onFocus() end
    self._focused_btn = b
    self:_dirty()
end
-- The first button that does something, from the toolbar's first row (the
-- title's X above it is one Up away), else the footer.
function Editor:_enterKeyFocus()
    local rows = self:_keyRows()
    local start = (self._bar_rows and #rows > 1) and 2 or 1
    for r = start, #rows do
        for c, b in ipairs(rows[r]) do
            if usable(b) then self._key_focus = { row = r, col = c }; self:_applyKeyFocus(); return true end
        end
    end
    return false
end
-- The arrows go to the nearest button that way on screen, Left and Right
-- along the line first, so the d-pad is walked as it looks. Before the buttons
-- have been painted (no position yet), by row and column.
local function centre(b)
    local d = b and b.dimen
    if not (d and d.x and d.w) then return nil end
    return d.x + d.w / 2, d.y + d.h / 2
end
function Editor:_keyMove(dr, dc)
    local f = self._key_focus
    local rows = self:_keyRows()
    local cur = rows[f.row] and rows[f.row][f.col]
    local cx, cy = centre(cur)
    local placed = cx ~= nil
    for _i, r in ipairs(rows) do
        for _j, b in ipairs(r) do
            if not centre(b) then placed = false end
        end
    end
    if not placed then
        f.row, f.col = f.row + dr, f.col + dc
        self:_applyKeyFocus()
        return true
    end
    -- Left and Right stay on the line first: a keys row is a line on screen
    -- (the d-pad's row, then what sits level with it). Past its end only a
    -- line next to it, as Left from the d-pad's Up is its Left, never a
    -- jump across the toolbar (Right from the title's X went to Done, rig).
    if dc ~= 0 then
        local best, best_d
        for ci, b in ipairs(rows[f.row]) do
            local bx = centre(b)
            local d = (bx - cx) * dc
            if b ~= cur and usable(b) and d > 0 and (not best_d or d < best_d) then
                best, best_d = ci, d
            end
        end
        if best then f.col = best; self:_applyKeyFocus(); return true end
    end
    local reach = dc ~= 0 and 1.5 * cur.dimen.h or math.huge
    local best, best_score
    for ri, r in ipairs(rows) do
        for ci, b in ipairs(r) do
            local bx, by = centre(b)
            local along = dc ~= 0 and (bx - cx) * dc or (by - cy) * dr
            local across = dc ~= 0 and math.abs(by - cy) or math.abs(bx - cx)
            if b ~= cur and usable(b) and along > 0 and across <= reach then
                -- Off to the side counts three times over: Down from Up is
                -- Down, not Left, which is nearer but not below it.
                local score = along + 3 * across
                if not best_score or score < best_score then
                    best, best_score = { ri, ci }, score
                end
            end
        end
    end
    if best then f.row, f.col = best[1], best[2] end
    self:_applyKeyFocus()
    return true
end
function Editor:_leaveKeyFocus()
    self._key_focus = nil
    self:_applyKeyFocus()
    return true
end

function Editor:onEdUp()    if self._key_focus then return self:_keyMove(-1, 0) end return self:_nav("up") end
function Editor:onEdDown()  if self._key_focus then return self:_keyMove(1, 0) end return self:_nav("down") end
function Editor:onEdLeft()  if self._key_focus then return self:_keyMove(0, -1) end return self:_nav("left") end
function Editor:onEdRight() if self._key_focus then return self:_keyMove(0, 1) end return self:_nav("right") end

function Editor:onEdPress()
    if self._key_focus then
        local b = self._focused_btn
        if usable(b) and b.callback then b.callback() end
        return true
    end
    if self:_enterKeyFocus() then return true end
    return self:_actionsDialog()
end

-- Nothing on screen to focus: everything the toolbar and edit footer offer as
-- a dialog (which brings its own focus handling). It closes after each action
-- so the result isn't hidden under it; Press again for the next one.
function Editor:_actionsDialog()
    local s = self.session
    local entry = s.selected_id and s:item(s.selected_id)
    local def = entry and Modules.get(entry.module)
    local rows = s:keyActions{
        has_settings = def and type(def.show_settings) == "function",
        has_colours = entry and require("lib/bookshelf_module_card_menu").hasColours(entry),
        on_shelf = self.host and self.host.shelf,
        on_done = function() self:_finish() end,
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

-- Back: from the toolbar, back to the grid; else Done.
function Editor:onDone()
    if self._key_focus then return self:_leaveKeyFocus() end
    return self:_finish()
end

-- _finish(): Done. The footer's Done button and the actions dialog's call it
-- straight, so it finishes with the toolbar focused too.
function Editor:_finish()
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
    self:_dropFadeCache()
    pcall(function() require("lib/bookshelf_hero_modules")._dropDimCache() end)
    if self._closed then return end
    self._closed = true
    pcall(function() self.session:commit() end)
    pcall(BookshelfSettings.flush)
    pcall(function() self.host:render(nil) end)
end

return Editor
