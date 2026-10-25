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
            UIManager:setDirty(editor, "ui")
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
            UIManager:setDirty(editor, "ui")
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
        add_picker = host.add_picker or function(on_added)
            local ok, Edit = pcall(require, "lib/bookshelf_hero_modules_edit")
            if ok and Edit then Edit.showAdd(bw, nil, on_added) end
        end,
        open_settings = host.open_settings or function(entry)
            local def = entry and Modules.get(entry.module)
            if def and type(def.show_settings) == "function" then
                local ok, err = pcall(def.show_settings, HeroModules._ctx(bw, nil, entry))
                if not ok then logger.warn("[bookshelf] module settings failed:", entry.module, err) end
            end
        end,
        -- The palette icon: the module's card and colours, saved on it.
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
        -- A size button that would do nothing is greyed, so the toolbar
        -- keeps its shape under the finger. On a shelf Shorter and Taller
        -- are left out: a shelf module is one row tall, so they never apply
        -- there (maintainer). Narrower and Wider stay, greyed at their limits.
        local on_shelf = self.host.shelf
        local function sizeButton(text, axis, delta)
            if on_shelf and axis == "h" then return nil end
            return button(text, function() s:resize(axis, delta) end, s:canResize(axis, delta))
        end
        -- Previous / next page, leading the two rows: the footer's page dots
        -- also take the selection there, but nothing said so (maintainer).
        local function pageButton(glyph, dir)
            local p = s:adjacentPage(dir)
            local b = chevron(glyph, function() if p then s:moveToPage(p) end end)
            b.enabled = p ~= nil
            return b
        end
        -- The row's buttons less the ones left out (nil). Counted with
        -- select("#"): a table literal with holes has no reliable length.
        local function compact(...)
            local out = {}
            for i = 1, select("#", ...) do
                local b = select(i, ...)
                if b then out[#out + 1] = b end
            end
            return out
        end
        if on_shelf then
            -- No height buttons, so Narrower and Wider stand one above the
            -- other: two rows of four, as the panels' rows are (maintainer).
            rows = {
                compact(
                    pageButton(Session.PAGE_PREV, -1),
                    sizeButton(_("Narrower"), "w", -1),
                    chevron(Session.CHEV_LEFT,  function() s:moveBy(-1, 0) end),
                    chevron(Session.CHEV_RIGHT, function() s:moveBy(1, 0) end)
                ),
                compact(
                    pageButton(Session.PAGE_NEXT, 1),
                    sizeButton(_("Wider"),    "w", 1),
                    chevron(Session.CHEV_UP,    function() s:moveBy(0, -1) end),
                    chevron(Session.CHEV_DOWN,  function() s:moveBy(0, 1) end)
                ),
                bottom,
            }
        else
            rows = {
                -- Page, then size, then position; each row one axis.
                compact(
                    pageButton(Session.PAGE_PREV, -1),
                    sizeButton(_("Narrower"), "w", -1),
                    sizeButton(_("Wider"),    "w", 1),
                    chevron(Session.CHEV_LEFT,  function() s:moveBy(-1, 0) end),
                    chevron(Session.CHEV_RIGHT, function() s:moveBy(1, 0) end)
                ),
                compact(
                    pageButton(Session.PAGE_NEXT, 1),
                    sizeButton(_("Shorter"),  "h", -1),
                    sizeButton(_("Taller"),   "h", 1),
                    chevron(Session.CHEV_UP,    function() s:moveBy(0, -1) end),
                    chevron(Session.CHEV_DOWN,  function() s:moveBy(0, 1) end)
                ),
                bottom,
            }
        end
    end
    local title_row = self:_titleRow(title, face, width - 2 * self.margin, entry)
    self._palette = type(title_row) == "table" and title_row.palette_button or nil
    local vg = VerticalGroup:new{
        align = "center",
        title_row,
    }
    self._bar_table = nil
    if rows then
        vg[#vg + 1] = VerticalSpan:new{ width = Screen:scaleBySize(6) }
        self._bar_table = ButtonTable:new{
            width = width - 2 * Size.border.window - 2 * Size.padding.default,
            buttons = rows,
            zero_sep = true,
            show_parent = self,
        }
        -- The arrows are the editor's (_keyRows): a ButtonTable is a
        -- FocusManager, and KOReader offers a key to children first.
        self._bar_table.key_events = {}
        vg[#vg + 1] = self._bar_table
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

-- _titleRow(title, face, w, entry): the toolbar's title, with the palette
-- icon when the module has colours to set (bookshelf_module_card_menu).
function Editor:_titleRow(title, face, w, entry)
    local s = self.session
    return require("lib/bookshelf_module_card_menu").titleRow(title, face, w, entry, self,
        function() s:colors() end)
end

function Editor:_buildFooter(rect_w)
    local s = self.session
    -- On a shelf the pages are the shelf's own, of books: no page dots, no
    -- New page (maintainer). A module moves a page with the toolbar's
    -- double chevrons.
    local info = self.host and self.host.gridInfo and self.host:gridInfo()
    local on_shelf = info and info.surface == "shelf"
    -- + Add first and Done last, where a dialog's confirm sits (maintainer).
    local row = { button("+ " .. _("Add"), function() s:add() end) }
    if not s.selected_id and (on_shelf or #s:pageList() <= 1) then
        row[#row + 1] = button(_("Tap a module to select it"), nil, false)
    end
    local pages = s:pageList()
    if #pages > 1 and not on_shelf then
        for _i, p in ipairs(pages) do
            local label = (p == s.page) and "\xE2\x97\x8F" or "\xE2\x97\x8B"
            row[#row + 1] = button(label, function()
                if s.selected_id then s:moveToPage(p) else s:goPage(p) end
            end)
        end
    end
    local nxt = s.selected_id and not on_shelf and s:newPage()
    if nxt then
        row[#row + 1] = button(_("New page"), function() s:moveToPage(nxt) end)
    end
    row[#row + 1] = button("\xE2\x9C\x93 " .. _("Done"), function() self:_finish() end)
    self._foot_table = ButtonTable:new{ width = rect_w, buttons = { row }, zero_sep = true, show_parent = self }
    self._foot_table.key_events = {}   -- the arrows are the editor's (see the toolbar)
    return FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding    = 0,
        self._foot_table,
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
    self._palette = nil
    self[1] = self:_buildFooter(fr.w)
    self[2] = self:_buildToolbar()
    -- Rebuilt after every change: key focus goes back on the same button.
    if self._key_focus then self:_applyKeyFocus() end
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
    local fr = self:_footerRect()
    local footer = self[1]
    local fh = footer:getSize().h
    local fy = math.max(fr.y, fr.y + fr.h - fh)
    footer:paintTo(bb, fr.x, fy)
    self._footer_rect = Geom:new{ x = fr.x, y = fy, w = fr.w, h = fh }

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
    bar:paintTo(bb, self.margin, ty)
    self._bar_rect = Geom:new{ x = self.margin, y = ty, w = self:_toolbarWidth(), h = bh }
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
    if nid then s:select(nid) end
    return true
end
-- ── Keys on the toolbar ──────────────────────────────────────────────────
-- Press puts key focus on the toolbar on screen: the palette icon in its
-- title, its rows of buttons and the footer below, a grid the arrows move
-- along. Press then presses the focused button and Back goes back to the
-- grid, where the arrows select modules (maintainer: on the desktop emulator
-- keys could not reach the toolbar). _key_focus = { row, col } in _keyRows.
function Editor:_keyRows()
    local rows = {}
    if self._palette then rows[#rows + 1] = { self._palette } end
    for _i, t in ipairs({ self._bar_table, self._foot_table }) do
        for _j, r in ipairs(t and t.buttons_layout or {}) do
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
    if not f or #rows == 0 then self._key_focus = nil; UIManager:setDirty(self, "ui"); return end
    f.row = math.max(1, math.min(f.row, #rows))
    f.col = math.max(1, math.min(f.col, #rows[f.row]))
    local b = rows[f.row][f.col]
    if b and b.onFocus then b:onFocus() end
    self._focused_btn = b
    UIManager:setDirty(self, "ui")
end
-- The first button that does something, from the toolbar's first row (the
-- palette above it is one Up away), else the footer.
function Editor:_enterKeyFocus()
    local rows = self:_keyRows()
    local start = (self._palette and #rows > 1) and 2 or 1
    for r = start, #rows do
        for c, b in ipairs(rows[r]) do
            if usable(b) then self._key_focus = { row = r, col = c }; self:_applyKeyFocus(); return true end
        end
    end
    return false
end
function Editor:_keyMove(dr, dc)
    local f = self._key_focus
    f.row, f.col = f.row + dr, f.col + dc
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
