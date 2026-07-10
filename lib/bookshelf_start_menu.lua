--[[
The start-menu popup: full-screen transparent InputContainer (one outside-tap
dismissal zone, one key scope) painting a root panel anchored bottom-left
above the footer, plus at most one cascade-flyout panel for an open folder.
Rebuilt fresh from the model on every open and after every edit.
]]
local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Fonts           = require("lib/bookshelf_fonts")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local Size            = require("ui/size")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger          = require("logger")
local Screen          = Device.screen
local Model           = require("lib/bookshelf_start_menu_model")
local Modules         = require("lib/bookshelf_start_menu_modules")
local Breaker         = require("lib/bookshelf_module_breaker")
local Store           = require("lib/bookshelf_settings_store")
local PageWipe        = require("lib/bookshelf_page_wipe")
local _               = require("lib/bookshelf_i18n").gettext
local T               = require("ffi/util").template

-- Wall-clock timer for perf instrumentation, matching bookshelf_widget.lua's
-- own [bookshelf perf] convention.
local _gettime
do
    local ok, s = pcall(require, "socket")
    _gettime = (ok and s and type(s.gettime) == "function")
        and function() return s.gettime() end
        or  os.clock
end

-- When the "Disable micro-modules" advanced setting is on, micro-module
-- entries are hidden from the start menu (the model keeps them, so re-enabling
-- restores them). Returns a fresh structure — folders are shallow-copied so
-- filtering their children never mutates the (possibly by-reference) stored
-- model.
local function stripModules(items)
    local out = {}
    for _i, e in ipairs(items) do
        if e.type ~= "module" then
            if e.type == "folder" and e.children then
                local copy = {}
                for k, v in pairs(e) do copy[k] = v end
                copy.children = stripModules(e.children)
                out[#out + 1] = copy
            else
                out[#out + 1] = e
            end
        end
    end
    return out
end

-- Drop menu-action shortcuts whose captured menu item doesn't resolve in the
-- current view's menu (reader vs file manager) -- so each auto-appears only
-- where it works (#211). Display-only: folders are shallow-copied when their
-- children change, never mutating the stored model. Fail-open via
-- MenuShortcut.isAvailable (shows everything if the menu tree can't be built).
local function filterByMenuAvailability(items)
    local ok_ms, MS = pcall(require, "lib/bookshelf_menu_shortcut")
    if not ok_ms or not MS or type(MS.isAvailable) ~= "function" then return items end
    local function keep(e)
        -- Only "Auto" menu actions (scope nil) are availability-gated. An
        -- explicit scope (library/reader/both) is the user's manual override --
        -- honour it as-is, even into a view where the item may not exist.
        if type(e) == "table" and type(e.menu_path) == "table" and e.scope == nil then
            return MS.isAvailable(e.menu_path, e.menu_page)
        end
        return true
    end
    local out = {}
    for _i, e in ipairs(items) do
        if keep(e) then
            if e.type == "folder" and e.children then
                local kids = {}
                for _j, c in ipairs(e.children) do
                    if keep(c) then kids[#kids + 1] = c end
                end
                local copy = {}
                for k, v in pairs(e) do copy[k] = v end
                copy.children = kids
                out[#out + 1] = copy
            else
                out[#out + 1] = e
            end
        end
    end
    return out
end

-- Paints its single child at a fixed offset within the overlay.
local OffsetContainer = WidgetContainer:extend{ x_off = 0, y_off = 0 }
function OffsetContainer:getSize()
    return self[1]:getSize()
end
function OffsetContainer:paintTo(bb, x, y)
    local sz = self[1]:getSize()
    self.dimen = Geom:new{ x = x + self.x_off, y = y + self.y_off, w = sz.w, h = sz.h }
    self[1]:paintTo(bb, x + self.x_off, y + self.y_off)
end

local CHEVRON_RIGHT = "\xEE\xA1\x81" -- U+E841 mdi-chevron-right (used by book menu)

-- Default icon for folder rows with no user-chosen icon: U+E94A mdi-folder
-- ("folder" in bookshelf_nerdfont_names). Render-time fallback only — never
-- written to the model — so existing icon-less folders gain it too and
-- "Change icon" still overrides it.
local FOLDER_ICON      = "\xEE\xA5\x8A" -- U+E94A mdi-folder
local FOLDER_ICON_OPEN = "\xEE\xB9\xAE" -- U+EE6E mdi-folder-open (flyout open)
-- Render-time checkbox glyphs for a menu shortcut that targets a toggle item;
-- the live on/off state comes from MenuShortcut.toggleState (same glyphs the
-- menu host uses). Static icon is the fallback when state can't be resolved.
local CHECK_ON_ICON    = "\xEF\x85\x8A" -- U+F14A fa-check-square
local CHECK_OFF_ICON   = "\xEF\x82\x96" -- U+F096 fa-square-o

-- Drop shadow matching the shelf cover cards (bookshelf_spine_widget) but at
-- HALF their distance: same mode-aware grey and the panel's own corner radius,
-- offset down-right so the popup casts the same shadow the covers do. The grey
-- is mode-aware because KOReader inverts the framebuffer in night mode, so a
-- fixed mid-grey would read as a bright halo there (see the spine widget for
-- the full rationale). Covers offset by scaleBySize(4); half = scaleBySize(2).
local PANEL_SHADOW_DIST  = Screen:scaleBySize(2)
local PANEL_SHADOW_DAY   = Blitbuffer.gray(0.5)
local PANEL_SHADOW_NIGHT = Blitbuffer.gray(0.15)
local function _panelShadowGray()
    if G_reader_settings and G_reader_settings:isTrue("night_mode") then
        return PANEL_SHADOW_NIGHT
    end
    return PANEL_SHADOW_DAY
end

-- Rounded panel frame. Stock FrameContainer paints its background fill and
-- its border with arcs of DIFFERENT centers when both radius and bordersize
-- are set (framecontainer.lua adds bordersize to the fill radius), leaving a
-- notched crescent at every corner. Painting two CONCENTRIC rounded rects
-- (outer = border color at radius r, inner = white at radius r - border,
-- inset by border) shares one arc center per corner, so the ring is clean -
-- same approach the cover cards take in bookshelf_spine_widget.lua.
local PanelFrame = WidgetContainer:extend{
    bordersize = 0,
    padding    = 0,
    radius     = 0,
    margin     = 0, -- consumers read frame.margin (FrameContainer parity)
    shadow     = 0, -- drop-shadow distance; 0 = none
}
function PanelFrame:getSize()
    local s = self[1]:getSize()
    local chrome = 2 * (self.bordersize + self.padding)
    return Geom:new{ w = s.w + chrome, h = s.h + chrome }
end
function PanelFrame:paintTo(bb, x, y)
    local sz = self:getSize()
    self.dimen = Geom:new{ x = x, y = y, w = sz.w, h = sz.h }
    local t = self.bordersize
    if self.shadow and self.shadow > 0 then
        -- Painted first, under the panel; the panel's opaque fill overpaints
        -- all but the down-right strip, leaving the cover-style drop shadow.
        bb:paintRoundedRect(x + self.shadow, y + self.shadow, sz.w, sz.h,
            _panelShadowGray(), self.radius)
    end
    bb:paintRoundedRect(x, y, sz.w, sz.h, Blitbuffer.COLOR_BLACK, self.radius)
    bb:paintRoundedRect(x + t, y + t, sz.w - 2 * t, sz.h - 2 * t,
        Blitbuffer.COLOR_WHITE, math.max(0, self.radius - t))
    self[1]:paintTo(bb, x + t + self.padding, y + t + self.padding)
end

-- NOT modal: UIManager inserts non-modal widgets BELOW modal ones, so a
-- modal start menu would trap every edit dialog (context ButtonDialog,
-- InputDialog, ConfirmBox, icon picker, action-picker menu) underneath
-- its full-screen tap-dismiss zone, unreachable by touch.
local StartMenu = InputContainer:extend{}

-- Entry point used by bookshelf_widget. bottom_inset = footer height (+margin).
-- burger_dimen: live Geom of the hamburger InputContainer (optional); when
-- provided the overlay paints an opaque close glyph over that region.
-- context: "library" (home screen, default) | "reader" (in-reader launcher).
-- Items whose scope is set to the other context are filtered out (#scope feat).
function StartMenu.open(bw, bottom_inset, burger_dimen, context)
    -- In reader context there's no bookshelf widget to repaint the area an
    -- in-place rebuild vacates (e.g. a closed folder flyout), so the flyout
    -- pixels would linger. Target ReaderUI instead, so the page beneath repaints
    -- and clears it. (In the library, bw -- the bookshelf -- does this.)
    local under = (context == "reader")
        and package.loaded["apps/reader/readerui"]
        and package.loaded["apps/reader/readerui"].instance or nil
    -- No burger_dimen => no footer button to sit above (gesture-opened). In that
    -- case ignore the passed inset and balance the bottom gap to the side margin
    -- in init() (once _margin is known), so the panel is evenly inset from the
    -- bottom and the side. With a button, sit above it plus a small gap.
    local no_button = (burger_dimen == nil)
    local menu = StartMenu:new{
        bw            = bw,
        bottom_inset  = no_button and 0 or (bottom_inset + Screen:scaleBySize(6)),
        _balance_bottom_margin = no_button,
        burger_dimen  = burger_dimen,
        context       = (context == "reader") and "reader" or "library",
        _repaint_under = under,
    }
    -- Open animation: capture the background, paint the panel into the buffer,
    -- then reveal it bottom-up over its region (the menu is bottom-anchored, so
    -- it reads as "opening upward"). E-ink only -- on LCD the per-strip
    -- refreshes coalesce and nothing shows, so we fall through to the instant
    -- show; likewise on any error.
    local _sr = menu._dirty_region
    local anim_steps = PageWipe.resolveSteps("start_menu_animation")
    if anim_steps and _sr and Screen.refreshUI then
        local shown = pcall(function()
            local rx, ry, rw, rh = _sr.x, _sr.y, _sr.w, _sr.h
            local old_bb = Screen.bb:copy()
            menu:paintTo(Screen.bb, 0, 0)
            local new_bb = Screen.bb:copy()
            local STEPS, prev_dh = anim_steps, 0
            for i = 1, STEPS do
                local dh = math.floor(rh * i / STEPS)
                if rh - dh > 0 then
                    Screen.bb:blitFrom(old_bb, rx, ry, rx, ry, rw, rh - dh)
                end
                Screen.bb:blitFrom(new_bb, rx, ry + rh - dh, rx, ry + rh - dh, rw, dh)
                if i < STEPS then
                    local strip_h = dh - prev_dh
                    if strip_h > 0 then
                        Screen:refreshUI(rx, ry + rh - dh, rw, strip_h)
                        UIManager:yieldToEPDC(20000)
                    end
                else
                    Screen:refreshUI(rx, ry, rw, rh)
                end
                prev_dh = dh
            end
            new_bb:free()
            menu._bg_snapshot = old_bb  -- kept for the close wipe-down
        end)
        if shown then
            -- Register the widget (stack + Show event) but suppress the initial
            -- repaint: the wipe already painted AND flushed the panel. show()
            -- always setDirty's, and a dirty widget with no enqueued refresh
            -- makes _repaint fall back to a full-screen refresh -- so clear the
            -- dirty flag it just set. The menu repaints normally on first tap.
            UIManager:show(menu)
            if UIManager._dirty then UIManager._dirty[menu] = nil end
            StartMenu._live = menu
            return
        end
    end
    -- Non-eink / animation-failed: normal instant show.
    UIManager:show(menu, "ui", menu._dirty_region)
    StartMenu._live = menu -- test/introspection hook; cleared in onCloseWidget
end

-- Model.load() filtered by the "In start menu" micro-module surface toggle.
-- Display-only: mutations go through bookshelf_start_menu_edit's own fresh
-- Model.load, so the stored model (with its module entries) is never touched by
-- the filtering -- toggling the surface back on restores the cards untouched.
function StartMenu:_loadItems()
    local _t0 = _gettime()
    local items = Model.load()
    local _t1 = _gettime()
    if not Store.microInStartMenu() then
        items = stripModules(items)
    end
    local _t2 = _gettime()
    -- Hide entries scoped to the other context (library vs the in-reader
    -- launcher). nil scope shows in both, so default menus are unaffected.
    items = Model.filterByScope(items, self.context or "library")
    local _t3 = _gettime()
    -- Hide menu-action shortcuts whose captured menu item doesn't exist in the
    -- CURRENT view's menu (reader vs file manager), so a shortcut auto-appears
    -- only where it works -- no "not available" tap, no manual scoping (#211).
    -- Display-only (like the scope filter); folder entries are shallow-copied
    -- when their children change so the stored model is never mutated.
    items = filterByMenuAvailability(items)
    local _t4 = _gettime()
    logger.dbg(string.format(
        "[bookshelf perf] StartMenu:_loadItems: load=%.0fms stripModules=%.0fms"
        .. " filterByScope=%.0fms filterByMenuAvailability=%.0fms TOTAL=%.0fms context=%s",
        (_t1 - _t0) * 1000, (_t2 - _t1) * 1000, (_t3 - _t2) * 1000, (_t4 - _t3) * 1000,
        (_t4 - _t0) * 1000, tostring(self.context)))
    return items
end

-- Set of entry ids currently RENDERED in this view (top level + folder
-- children), i.e. the post-filter list the user can actually see. Used as the
-- visibility predicate for reorder so a move skips entries hidden from this view
-- (Auto menu shortcuts not available here) and lands the held row past its
-- nearest visible neighbour in one tap. Greyed rows are present in _items, so
-- they count as visible -- only truly-hidden entries are skipped.
function StartMenu:_visibleIds()
    local set = {}
    local function walk(list)
        for _i, it in ipairs(list or {}) do
            if it.id then set[it.id] = true end
            if it.type == "folder" then walk(it.children) end
        end
    end
    walk(self._items)
    return set
end

function StartMenu:init()
    local _t0 = _gettime()
    -- Menu-open signal: bump the loader's generation counter exactly once
    -- per open (init runs once per StartMenu instance; _reload does not
    -- re-init). Modules key per-open caches on it — see the README.
    pcall(Modules.bumpGeneration)
    -- Crash recovery (issue #163): if the LAST open armed but never painted
    -- (a paint-pass segfault, or a render hard-crash safeText didn't prevent),
    -- the marker is still on disk - open in SAFE MODE with every module
    -- suppressed so the user can still get in and remove the culprit. Prevention
    -- is safeText; this is just the recovery net. openCrashed must be read
    -- BEFORE armOpen re-arms it for this open.
    local ok_o, crashed = pcall(Breaker.openCrashed, Store)
    self._safe_mode = (ok_o and crashed) or false
    pcall(Breaker.armOpen, Store)
    self.dimen = Geom:new{ x = 0, y = 0,
        w = Screen:getWidth(), h = Screen:getHeight() }
    -- Side margin matches the bookshelf's own side gap (same formula as
    -- _computeDims' PAD: fullscreen padding scaled, capped at 3% of width)
    -- so the popup sits off the screen edge like the shelf content does.
    local Size = require("ui/size")
    self._margin = math.min(
        math.floor(Size.padding.fullscreen * 2 * 0.8),
        math.floor(Screen:getWidth() * 0.03))
    -- Gesture-opened with no footer button: mirror the side margin onto the
    -- bottom so the panel is evenly inset (the horizontal anchor already
    -- mirrors _margin left/right, so this balances all three edges).
    if self._balance_bottom_margin then
        self.bottom_inset = self._margin
    end
    -- Chrome constants shared by row building and the pagination budget.
    self._focus_border = Screen:scaleBySize(2) -- row margin/border swap
    self._panel_border = Screen:scaleBySize(2) -- panel FrameContainer border
    self._panel_pad    = Screen:scaleBySize(3) -- panel FrameContainer padding
    self:_applyFontScale()
    local _t1 = _gettime()
    self._items    = self:_loadItems()
    local _t2 = _gettime()
    -- Open on the LAST page (the menu is anchored bottom-left, so the final
    -- rows sit by the thumb). Seeding the page past the end makes the first
    -- build clamp it to the real last page; _build runs once per open, so this
    -- is the open-time default and edits/reloads keep the page.
    self._page     = #self._items -- root panel page (panel-internal pagination)
    self._fly_page = 1            -- flyout panel page (folders open at top)
    self._flyout_for = nil -- id of the open folder, or nil
    self._focus    = nil   -- key-nav focus { panel, entry_id }; set when hasDPad
    if Device:isTouchDevice() then
        self.ges_events = {
            TapDismiss = { GestureRange:new{ ges = "tap", range = self.dimen } },
        }
    end
    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
        }
    end
    if Device:hasDPad() then
        self.key_events = self.key_events or {}
        self.key_events.SMFocusUp    = { { "Up" } }
        self.key_events.SMFocusDown  = { { "Down" } }
        self.key_events.SMFocusLeft  = { { "Left" } }
        self.key_events.SMFocusRight = { { "Right" } }
        self.key_events.SMPress      = { { "Press" } }
        self.key_events.SMHold = {
            { "ScreenKB", "Press" },
            { "Shift", "Press" },
            { "Sym", "AA" },
        }
        self._focus = { panel = "root", entry_id = nil }
    end
    local _t3 = _gettime()
    self:_build()
    local _t4 = _gettime()
    -- Seed focus after the first build so _panelEntries can inspect the
    -- rendered rows. If nothing is focusable yet (empty menu with no __add)
    -- _focus.entry_id stays nil and the menu opens without a focus ring.
    if self._focus then
        -- Seed at the bottom so the first arrow press moves upward -- matches
        -- the menu's visual anchor in the bottom corner of the screen.
        local last = self:_lastFocusable(self._focus.panel)
        if last then
            self._focus.entry_id = last
            self:_rebuild_only()
        end
    end
    local _t5 = _gettime()
    logger.dbg(string.format(
        "[bookshelf perf] StartMenu:init: setup=%.0fms loadItems=%.0fms"
        .. " prebuild=%.0fms build=%.0fms focusSeed=%.0fms TOTAL=%.0fms context=%s items=%d",
        (_t1 - _t0) * 1000, (_t2 - _t1) * 1000, (_t3 - _t2) * 1000, (_t4 - _t3) * 1000,
        (_t5 - _t4) * 1000, (_t5 - _t0) * 1000, tostring(self.context), #self._items))
end

function StartMenu:_panelWidthBounds()
    local sw  = Screen:getWidth()
    local pct = self._scale_pct or 100
    -- Scale the minimum panel width with the start-menu font setting. A fixed
    -- 180 left panels (and especially module-only flyouts, which fall back to
    -- this floor) too narrow at large text: the analogue clock sized its face
    -- to the cramped cell and its rim painted out of position. Both the root
    -- and flyout panels go through here, so both widen together. Clamp to the
    -- max so a very large font can't exceed the panel cap.
    local max_w = math.floor(sw * 0.6)
    local min_w = math.min(max_w, math.floor(Screen:scaleBySize(180) * pct / 100))
    return min_w, max_w
end

-- Recomputes font-scaled row dimensions and faces from the current setting.
-- Called from init() and from _build() so live nudge-dialog changes take
-- effect on the next rebuild without restarting KOReader.
function StartMenu:_applyFontScale()
    local pct = Store.read("start_menu_font_scale") or 100
    local function sc(n) return math.max(1, math.floor(n * pct / 100 + 0.5)) end
    self._pad      = Screen:scaleBySize(sc(10))
    self._row_face  = Fonts:getFace("cfont", sc(18))
    self._icon_face = Fonts:getFace("cfont", sc(22))
    self._icon_col_w = Screen:scaleBySize(sc(30))
    self._icon_gap   = math.floor(self._pad / 2) -- breathing room icon → label
    self._row_h     = Screen:scaleBySize(sc(40))
    self._chev_nat  = nil -- invalidate cached chevron width
    self._scale_pct = pct
end

-- Natural width of the widest row in `entries`, matching _buildRow's layout
-- arithmetic exactly. Returns a value already clamped to _panelWidthBounds().
-- Module entries are skipped (their content adapts to whatever width the panel
-- chooses; a panel of only modules gets the min bound). An empty list (or
-- all-module list) also returns the min bound.
-- Single source for the horizontal chrome surrounding a row label (pads,
-- icon column, icon gap, focus frame, optional chevron slot). Used by BOTH
-- _measurePanelWidth and _buildRow's label budget so the two can't drift
-- apart - drift shows up as phantom ellipsis on labels the panel was sized
-- to fit.
function StartMenu:_rowChromeWidth(with_chevron)
    if not self._chev_nat then
        local probe = TextWidget:new{ text = CHEVRON_RIGHT, face = self._row_face }
        self._chev_nat = probe:getSize().w + self._pad
        probe:free()
    end
    local w = self._pad + self._icon_col_w + self._icon_gap + self._pad
        + 2 * self._focus_border
    if with_chevron then w = w + self._chev_nat end
    return w
end

function StartMenu:_measurePanelWidth(entries)
    local min_w, max_w = self:_panelWidthBounds()
    -- Reserve the chevron slot for the whole panel when ANY entry is a
    -- folder (all rows share one fixed width).
    local has_folder, has_module = false, false
    for _i, e in ipairs(entries) do
        if e.type == "folder" then has_folder = true end
        if e.type == "module" then has_module = true end
    end
    -- Micro-modules render at the panel width; give a panel that contains one
    -- a floor 25% above the plain-row minimum so modules get more room.
    if has_module then
        min_w = math.min(max_w, math.floor(min_w * 1.25))
    end
    local chrome = self:_rowChromeWidth(has_folder)
    local max_natural = 0
    for _i, e in ipairs(entries) do
        if e.type ~= "module" then
            local label_probe = TextWidget:new{
                text = e.label or "?",
                face = self._row_face,
                -- No max_width: measure the untruncated natural width.
            }
            local label_w = label_probe:getSize().w
            label_probe:free()
            local row_w = label_w + chrome
            if row_w > max_natural then max_natural = row_w end
        end
    end
    if max_natural == 0 then return min_w end
    return math.min(max_w, math.max(min_w, max_natural))
end

-- One menu row: [icon] label [chevron-if-folder]. Returns an InputContainer.
-- The group is padded out to exactly `w` because FrameContainer's `width`
-- only affects painting, not getSize() - row dimens must report full width
-- so the tap ranges cover the whole panel row.
function StartMenu:_buildRow(entry, w, focused, in_flyout)
    local unresolved = self._unresolved_ids and self._unresolved_ids[entry.id]
    local fg = unresolved and Blitbuffer.COLOR_DARK_GRAY
        or Blitbuffer.COLOR_BLACK
    local icon_w   = self._icon_col_w
    local icon_gap = self._icon_gap
    local icon_text = entry.icon
    if entry.type == "folder" then
        if not icon_text or icon_text == "" then
            icon_text = FOLDER_ICON
        end
        -- Folder-glyph rows flip to the open-folder glyph while their
        -- flyout is showing (default AND explicitly-chosen folder icons;
        -- custom icons are left alone).
        if icon_text == FOLDER_ICON and self._flyout_for == entry.id then
            icon_text = FOLDER_ICON_OPEN
        end
    elseif entry.menu_path and entry.menu_toggle then
        -- Menu shortcut targeting a toggle: show its live on/off state as a
        -- checkbox. toggleState builds the menu once (then cached) and reads the
        -- item's checked_func; nil (unresolvable) keeps the static icon.
        local ok_ms, MS = pcall(require, "lib/bookshelf_menu_shortcut")
        local state = ok_ms and MS.toggleState and MS.toggleState(entry.menu_path)
        if state ~= nil then
            icon_text = state and CHECK_ON_ICON or CHECK_OFF_ICON
        end
    end
    local icon
    local img_name = Model.imageIconName(icon_text)
    if img_name then
        local IconWidget = require("ui/widget/iconwidget")
        local isz = (self._icon_face and self._icon_face.size) or Screen:scaleBySize(22)
        local iw = IconWidget:new{
            icon = img_name,
            width = isz,
            height = isz,
            alpha = true,   -- render as-is (SVG/PNG own colours honoured)
        }
        -- Missing-file guard: a row referencing an icon the user no longer has
        -- degrades to a blank icon column (the label still shows) rather than
        -- KOReader's "icon-not-found" glyph.
        if iw.file and iw.file:find("icon-not-found", 1, true) then
            if iw.free then iw:free() end
            icon = TextWidget:new{ text = " ", face = self._icon_face, fgcolor = fg }
        else
            icon = iw
        end
    else
        icon = TextWidget:new{
            text = icon_text or " ", face = self._icon_face, fgcolor = fg,
        }
    end
    -- Label budget mirrors _measurePanelWidth via the shared chrome width.
    -- TextWidget max_width must stay positive (makeLine aborts otherwise).
    local label_max = math.max(Screen:scaleBySize(40),
        w - self:_rowChromeWidth(entry.type == "folder"))
    local label = TextWidget:new{
        text = entry.label or "?", face = self._row_face, fgcolor = fg,
        max_width = label_max,
    }
    local group = HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = self._pad },
        CenterContainer:new{
            dimen = Geom:new{ w = icon_w, h = self._row_h },
            icon,
        },
        HorizontalSpan:new{ width = icon_gap },
        label,
    }
    local focus_border = self._focus_border
    local inner_w = w - 2 * focus_border -- frame chrome: margin/border swap
    local used = 0
    for _i, child in ipairs(group) do
        used = used + child:getSize().w
    end
    local chev = entry.type == "folder" and TextWidget:new{
        text = CHEVRON_RIGHT, face = self._row_face, fgcolor = fg,
    } or nil
    local chev_used = chev and (chev:getSize().w + self._pad) or 0
    group[#group + 1] = HorizontalSpan:new{
        width = math.max(0, inner_w - used - chev_used),
    }
    if chev then
        group[#group + 1] = chev
        group[#group + 1] = HorizontalSpan:new{ width = self._pad }
    end
    local frame = FrameContainer:new{
        width      = w,
        bordersize = focused and focus_border or 0,
        margin     = focused and 0 or focus_border,
        padding    = 0,
        group,
    }
    local sm = self
    local row = InputContainer:new{ dimen = frame:getSize(), frame }

    -- Instant tap feedback: underline the label the moment the row is pressed,
    -- before _activate runs its (possibly slow) action -- otherwise a tap reads
    -- as dead until the menu closes/redraws. Modelled on the tag pills' pre-
    -- callback highlight (widgetRepaint + fast setDirty + forceRePaint). Skipped
    -- for folders, which already give feedback by opening their flyout (and would
    -- otherwise keep a stuck underline while the root panel stays painted).
    --
    -- Folders instead get the SAME underline as a persistent active-state cue
    -- while they're the currently-open folder -- mirrors the open-folder icon
    -- glyph swap above (icon_text == FOLDER_ICON_OPEN), so other menu items
    -- (tap feedback) and open folders (active feedback) both read consistently
    -- via an underline. Driven by folder_open (rebuilt fresh on every flyout
    -- toggle, like the icon) rather than the transient _tapped flag.
    local is_folder     = entry.type == "folder"
    local folder_open   = is_folder and self._flyout_for == entry.id
    local ul_tap_enable = not is_folder
    local ul_x_off  = focus_border + self._pad + icon_w + icon_gap
    local ul_w      = label:getSize().w
    local ul_h      = label:getSize().h
    local ul_row_h  = self._row_h
    local ul_fg     = fg
    if ul_tap_enable or folder_open then
        function row:paintTo(bb, x, y)
            InputContainer.paintTo(self, bb, x, y)
            if (folder_open or self._tapped) and ul_w > 0 then
                local th = Screen:scaleBySize(2)
                -- Just below the vertically-centred label baseline.
                local cy = y + focus_border
                    + math.floor((ul_row_h + ul_h) / 2) + Screen:scaleBySize(1)
                bb:paintRect(x + ul_x_off, cy, ul_w, th, ul_fg)
            end
        end
    end

    if Device:isTouchDevice() then
        row.ges_events = {
            Tap  = { GestureRange:new{ ges = "tap",  range = row.dimen } },
            Hold = { GestureRange:new{ ges = "hold", range = row.dimen } },
        }
    end
    -- The flyout overlaps the root panel's right edge and is painted on
    -- top of it, but the root panel sits earlier in the OverlapGroup so
    -- its rows see gestures FIRST. Root rows decline gestures that land
    -- inside the open flyout so they propagate through to the flyout's
    -- own rows (the visually-hit target).
    local function flyoutOwns(ges)
        return not in_flyout and sm._flyout_region and ges and ges.pos
            and ges.pos:intersectWith(sm._flyout_region)
    end
    function row:onTap(_a, ges)
        if flyoutOwns(ges) then return false end
        -- Flush the underline to the panel BEFORE _activate (which may close the
        -- menu or run a slow action); forceRePaint drains the queue so the eink
        -- panel actually shows it first. The follow-up action either tears the
        -- panel down or re-renders this row fresh (without _tapped), clearing it.
        if ul_tap_enable and self.dimen then
            self._tapped = true
            UIManager:widgetRepaint(self, self.dimen.x, self.dimen.y)
            UIManager:setDirty(nil, "fast", self.dimen)
            UIManager:forceRePaint()
        end
        -- Pass the tapped row's painted rect so a keep_open re-render can scope
        -- its refresh to this row and below, rather than flashing the whole
        -- panel (rows above the tapped one shouldn't redraw).
        sm:_activate(entry, self.dimen and self.dimen:copy()); return true
    end
    function row:onHold(_a, ges)
        if flyoutOwns(ges) then return false end
        sm:_editEntry(entry); return true
    end
    return row
end

-- A module row: rendered panel (or muted fallback), tappable, holdable.
-- The content sits on a light-grey rounded card inset from the panel
-- edges so module panels read as distinct from plain action rows.
function StartMenu:_buildModuleRow(entry, w, focused, in_flyout)
    local def = Modules.get(entry.module)
    local focus_border = self._focus_border
    -- Content fits in (w - 2*focus_border) so the margin/border swap keeps
    -- the row's outer dimen at exactly w regardless of focus state, matching
    -- the same contract as _buildRow.
    local inner_w_frame = w - 2 * focus_border
    local card_margin = math.floor(self._pad / 2) -- inset from panel edges
    local card_pad    = self._pad
    local inner_w     = inner_w_frame - 2 * card_margin - 2 * card_pad
    -- Parent-owned scoped refresh for THIS module's row: passed to render() as
    -- the 5th arg so a module can refresh itself after async work (weather /
    -- daily_fun / trivia) via the parent instead of a full-screen setDirty or
    -- a hardcoded StartMenu._live:_reload. `row` is forward-declared; the
    -- closure reads it at call time (after the row is built + painted), so the
    -- async fire scopes the reload from this row down (cards above don't
    -- redraw). Mirrors the hero's per-cell refresh.
    local sm = self
    local row
    local function refresh()
        if sm._reload then sm:_reload(row and row.dimen and row.dimen:copy()) end
    end
    -- In safe mode every module is suppressed (a previous open crashed before
    -- painting); the row renders as a removable, tappable fallback instead.
    local blocked = self._safe_mode
    local inner, errored
    if def and not blocked then
        -- Render under pcall so a Lua error degrades to an "(error)" row rather
        -- than taking down the build. Force getSize() inside the guard so any
        -- layout/shaping error is caught here too. No disk writes on this path.
        -- The render still gets the scoped refresh (5th arg) for async redraws.
        local ok, widget = Breaker.guard(function()
            local wgt = def.render({
                width = inner_w, height = nil,
                scale = self._scale_pct or 100,
                preview = false, refresh = refresh, shape = nil, entry = entry,
                surface = "start_menu", bw = self.bw, menu = self,
                config = require("lib/bookshelf_module_kit").entryConfig(entry, nil),
            })
            if wgt then wgt:getSize() end
            return wgt
        end)
        inner = ok and widget or nil
        if not ok then
            errored = true
            logger.warn("[bookshelf] start menu module render failed:",
                entry.module, widget)
        end
    end
    if not inner then
        local label = (def and def.title) or entry.module
        if blocked then
            -- This module crashed the menu last open and was auto-disabled so
            -- the user isn't locked out (issue #163). Tapping retries it; a
            -- long-press still removes the row like any other.
            label = T(_("%1 (disabled - tap to retry)"), label)
        elseif errored then
            -- render threw a (catchable) Lua error: show it inline and log the
            -- detail, rather than rendering nothing or taking the menu down.
            label = T(_("%1 (error)"), label)
        end
        inner = TextWidget:new{
            text = label,
            face = self._row_face, fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            max_width = math.max(1, inner_w),
        }
    end
    -- Resize hysteresis: hold this module's previous rendered height across
    -- re-renders unless the content changed by more than ~half a line, so a
    -- slightly taller/shorter async re-render (weather / trivia / etc.) doesn't
    -- shuffle every row below it a few pixels (a visible glitch). Slight shrink
    -- pads; slight grow clips a few px of trailing whitespace; a significant
    -- change adopts the new height. Per StartMenu instance, keyed by entry id.
    if entry.id then
        local iw, ih = inner:getSize().w, inner:getSize().h
        self._module_heights = self._module_heights or {}
        local prev = self._module_heights[entry.id]
        if prev and math.abs(ih - prev) <= Screen:scaleBySize(6) then
            local ClipContainer = require("lib/bookshelf_clip_container")
            inner = ClipContainer:new{ w = iw, h = prev, bg = Modules.CARD_BG, inner }
        else
            self._module_heights[entry.id] = ih
        end
    end
    -- Pad content to the card's full inner width so the card spans the
    -- panel (minus its margins) regardless of the module's natural width.
    local content = HorizontalGroup:new{
        align = "center",
        inner,
        HorizontalSpan:new{
            width = math.max(0, inner_w - inner:getSize().w),
        },
    }
    -- Shared card-surface grey (Modules.CARD_BG): light enough that the
    -- modules' COLOR_DARK_GRAY muted text stays readable, while still
    -- reading as a distinct surface against the panel's white.
    local card = FrameContainer:new{
        background = Modules.CARD_BG,
        radius     = Screen:scaleBySize(4),
        bordersize = 0,
        padding    = card_pad,
        content,
    }
    -- Spans pad the card row out to inner_w_frame so the margin/border swap
    -- on the outer frame keeps the total row width at exactly w.
    local card_row = HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = card_margin },
        card,
        HorizontalSpan:new{
            width = math.max(0, inner_w_frame - card_margin - card:getSize().w),
        },
    }
    local frame = FrameContainer:new{
        bordersize     = focused and focus_border or 0,
        margin         = focused and 0 or focus_border,
        padding        = 0,
        padding_top    = card_margin,
        padding_bottom = card_margin,
        card_row,
    }
    -- Assign the forward-declared `row`/`sm` (see top of _buildModuleRow) so
    -- the refresh closure binds to this row, not a shadowing local.
    row = InputContainer:new{ dimen = frame:getSize(), frame }
    if Device:isTouchDevice() then
        row.ges_events = {
            Tap  = { GestureRange:new{ ges = "tap",  range = row.dimen } },
            Hold = { GestureRange:new{ ges = "hold", range = row.dimen } },
        }
    end
    -- Same overlap-strip guard as _buildRow (see comment there).
    local function flyoutOwns(ges)
        return not in_flyout and sm._flyout_region and ges and ges.pos
            and ges.pos:intersectWith(sm._flyout_region)
    end
    function row:onTap(_a, ges)
        if flyoutOwns(ges) then return false end
        -- Pass the tapped row's painted rect so a keep_open re-render can scope
        -- its refresh to this row and below, rather than flashing the whole
        -- panel (rows above the tapped one shouldn't redraw).
        sm:_activate(entry, self.dimen and self.dimen:copy()); return true
    end
    function row:onHold(_a, ges)
        if flyoutOwns(ges) then return false end
        sm:_editEntry(entry); return true
    end
    return row
end

-- A divider row: a bare horizontal line, no label/icon, matching KOReader's
-- own native menu-separator styling (touchmenu.lua's split_line: medium-
-- weight gray line inset on both sides). Not tappable. Holdable for the
-- generic Move up/down + Delete options (Edit.show trims the rest for this
-- type). Deliberately NOT given an `entry` field by _buildPanel's row list,
-- so it never appears in d-pad/chevron focus navigation -- nothing to land
-- on, nothing to activate.
function StartMenu:_buildDividerRow(entry, w)
    local inset = Size.span.horizontal_default
    local line = HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = inset },
        LineWidget:new{
            background = Blitbuffer.COLOR_GRAY,
            dimen = Geom:new{ w = w - 2 * inset, h = Size.line.medium },
        },
        HorizontalSpan:new{ width = inset },
    }
    local row_h = math.floor(self._row_h / 2)
    local centered = CenterContainer:new{
        dimen = Geom:new{ w = w, h = row_h },
        line,
    }
    local row = InputContainer:new{ dimen = Geom:new{ w = w, h = row_h }, centered }
    local sm = self
    if Device:isTouchDevice() then
        row.ges_events = {
            Hold = { GestureRange:new{ ges = "hold", range = row.dimen } },
        }
    end
    function row:onHold()
        sm:_editEntry(entry); return true
    end
    return row
end

-- Builds one panel (list of entries) as a framed VerticalGroup.
-- folder_id: when non-nil, the "Add..." synthetic row in an empty panel
-- targets that folder rather than the top level.
-- Returns frame, rows (list of {row=widget, entry=entry}).
function StartMenu:_buildPanel(entries, w, folder_id)
    local in_flyout = folder_id ~= nil
    local vg = VerticalGroup:new{ align = "left" }
    local rows = {}
    if #entries == 0 then
        local sm = self
        local add_entry = { id = "__add", type = "action", label = _("Add…") }
        local row = self:_buildRow(add_entry, w, false, in_flyout)
        function row:onTap() sm:_addEntry(nil, folder_id); return true end
        function row:onHold() sm:_addEntry(nil, folder_id); return true end
        vg[#vg + 1] = row
        rows[#rows + 1] = { row = row, entry = add_entry }
    end
    for _i, entry in ipairs(entries) do
        local is_focused = self._focus and self._focus.entry_id == entry.id
        local row
        if entry.type == "divider" then
            row = self:_buildDividerRow(entry, w)
        elseif entry.type == "module" then
            row = self:_buildModuleRow(entry, w, is_focused, in_flyout)
        else
            row = self:_buildRow(entry, w, is_focused, in_flyout)
        end
        vg[#vg + 1] = row
        -- Dividers are never focus targets -- omit `entry` so _panelEntries
        -- (which filters on its truthiness) skips them for free.
        rows[#rows + 1] = { row = row, entry = entry.type ~= "divider" and entry or nil }
    end
    local frame = PanelFrame:new{
        bordersize = self._panel_border,
        padding    = self._panel_pad,
        radius     = Screen:scaleBySize(4), -- bookshelf's card radius (CARD_RADIUS)
        shadow     = PANEL_SHADOW_DIST,
        vg,
    }
    return frame, rows
end

-- Rows that fit the vertical budget. Each row paints at row_h plus the
-- focus margin/border swap on both edges; the panel frame adds its own
-- border+padding chrome. The pager-row slot is NOT reserved here:
-- _pageSlice reserves it (per = max_rows - 1) only when paging is needed.
function StartMenu:_maxRows()
    local avail_h = Screen:getHeight() - self.bottom_inset - 2 * self._margin
    local row_stride = self._row_h + 2 * self._focus_border
    local chrome = 2 * (self._panel_border + self._panel_pad)
    return math.max(3, math.floor((avail_h - chrome) / row_stride))
end

-- Panel-internal pagination: slice entries to what fits the height budget.
-- Pages are tiled from the BOTTOM, so any short remainder lands on page 1 (the
-- top) and every lower page is full. The menu opens on the last page (see
-- init), so its first view is a full page rather than a 1-2 item remainder.
function StartMenu:_pageSlice(entries, page, max_rows)
    local total = #entries
    if total <= max_rows then return entries, false, false end
    local per   = max_rows - 1 -- reserve one row slot for the pager
    local pages = math.ceil(total / per)
    local rem   = total - (pages - 1) * per -- size of page 1 (top), in 1..per
    local first, last
    if page <= 1 then
        first, last = 1, rem
    else
        first = rem + (page - 2) * per + 1
        last  = math.min(first + per - 1, total)
    end
    local out = {}
    for i = first, last do
        out[#out + 1] = entries[i]
    end
    return out, first > 1, last < total
end

-- is_root: root-panel pagers decline taps that land inside the open flyout's
-- region (a tall flyout can overhang the root's pager in the overlap strip;
-- the flyout row under the finger must win, same as the root rows' guard).
function StartMenu:_pagerRow(w, has_prev, has_next, on_prev, on_next, is_root)
    local face = self._row_face
    local sm = self
    local mk = function(txt, enabled, fn)
        local t = TextWidget:new{ text = txt, face = face,
            fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY }
        local c = InputContainer:new{ dimen = Geom:new{
            w = math.floor(w / 2), h = self._row_h },
            CenterContainer:new{
                dimen = Geom:new{ w = math.floor(w / 2), h = self._row_h },
                t,
            },
        }
        if Device:isTouchDevice() then
            c.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = c.dimen } } }
        end
        function c:onTap(_arg, ges)
            if is_root and sm._flyout_region and ges and ges.pos
                    and ges.pos:intersectWith(sm._flyout_region) then
                return false
            end
            if enabled then fn() end
            return true
        end
        return c
    end
    return HorizontalGroup:new{
        mk("\xE2\x86\x91", has_prev, on_prev),  -- ↑
        mk("\xE2\x86\x93", has_next, on_next),  -- ↓
    }
end

-- Grey out dispatcher actions whose registry entry is gone (plugin disabled),
-- and plugin-launcher entries whose module no longer resolves on the live
-- FileManager instance (plugin uninstalled/disabled).
-- getNameFromItem returns _("Unknown item") for any key not in settingsList;
-- it never returns nil and never errors, so we detect the sentinel via
-- require("gettext") which is the same module dispatcher uses.
-- Marks live in self._unresolved_ids (keyed by entry id), NOT on the entry
-- tables: Model.load can return the live settings-store list by reference,
-- so a field written onto an entry would be flushed into settings and
-- round-trip forever (sanitize also strips any persisted leftovers).
function StartMenu:_markUnresolved(items)
    local ok, Dispatcher = pcall(require, "dispatcher")
    local unknown_sentinel = ok and require("gettext")("Unknown item") or nil
    local ok_ps, PluginScan = pcall(require, "lib/bookshelf_plugin_scan")
    local ok_ms, MS = pcall(require, "lib/bookshelf_menu_shortcut")
    local ids = {}
    local function walk(list)
        for _i, it in ipairs(list) do
            if it.type == "action" and type(it.menu_path) == "table" then
                -- Menu shortcut: grey it out when its target item doesn't exist
                -- in the current view. Auto-scoped shortcuts (scope nil) are
                -- already dropped by filterByMenuAvailability before this runs,
                -- so this only marks explicitly-scoped ones the user forced into
                -- a view where the item isn't available -- the tap is a no-op,
                -- and the grey signals that up front. isAvailable fails open, so
                -- a transient menu-build hiccup never greys a working shortcut.
                if ok_ms and MS.isAvailable and not MS.isAvailable(it.menu_path, it.menu_page) then
                    if it.id then ids[it.id] = true end
                end
            elseif it.type == "action" and type(it.plugin) == "table" then
                -- exists() never calls third-party code (resolve() may
                -- probe the plugin's addToMainMenu), so marking stays
                -- cheap even though _build runs on every focus step.
                local present = ok_ps
                    and PluginScan.exists(it.plugin.key, it.plugin.method)
                if not present and it.id then ids[it.id] = true end
            elseif it.type == "action" and type(it.action) == "table" then
                local resolved = false
                if ok then
                    for k, v in pairs(it.action) do
                        if k ~= "settings" and v ~= nil then
                            local ok2, name = pcall(Dispatcher.getNameFromItem,
                                Dispatcher, k, it.action, true)
                            resolved = ok2 and name ~= unknown_sentinel
                            break
                        end
                    end
                end
                if not resolved and it.id then ids[it.id] = true end
            elseif it.type == "folder" then
                walk(it.children or {})
            end
        end
    end
    walk(items)
    self._unresolved_ids = ids
end

function StartMenu:_build()
    local _bt0 = _gettime()
    self:_applyFontScale()
    self:_markUnresolved(self._items)
    local _bt1 = _gettime()
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    local max_rows = self:_maxRows()

    -- Root panel: measure the FULL item list (not just the visible page slice)
    -- so the panel width is stable across page turns.
    local root_w = self:_measurePanelWidth(self._items)

    -- Root panel. Module rows render taller than the _row_h budget used by
    -- _maxRows, so the initial slice may overflow the screen. Reduce max_rows
    -- by 1 and rebuild until the panel fits, or until max_rows reaches 1.
    -- The pager row (if active) adds roughly one row_stride to the total, so
    -- its estimated height is included in the overflow check.
    local avail_panel_h = sh - self.bottom_inset
    -- Module rows render taller than the _row_h estimate _maxRows uses, so the
    -- first build may overflow. Rather than decrement max_rows by 1 and rebuild
    -- repeatedly (each rebuild re-renders every module), build ONCE, then if it
    -- overflows use the MEASURED row heights to pick how many bottom rows fit
    -- and rebuild ONCE at that count. Worst case two builds, not ~N.
    local function _overflows(frame, hp, hn)
        local h = frame:getSize().h
        if hp or hn then h = h + self._row_h + 2 * self._focus_border end
        return h > avail_panel_h
    end
    local slice, has_prev, has_next = self:_pageSlice(self._items, self._page, max_rows)
    local _bt2 = _gettime()
    local root_frame, root_rows = self:_buildPanel(slice, root_w)
    local _bt3 = _gettime()
    local need_rebuild = false
    if max_rows > 1 and _overflows(root_frame, has_prev, has_next) then
        -- Sum measured row heights from the bottom (the panel is bottom-
        -- anchored), reserving the pager slot, to find how many rows fit.
        local chrome = 2 * (self._panel_border + self._panel_pad)
        local budget = avail_panel_h - chrome - (self._row_h + 2 * self._focus_border)
        local acc, fit = 0, 0
        for i = #root_rows, 1, -1 do
            acc = acc + root_rows[i].row:getSize().h
            if acc > budget then break end
            fit = fit + 1
        end
        local new_max = math.max(2, fit + 1) -- +1: _pageSlice reserves a pager row
        if new_max < max_rows then max_rows = new_max; need_rebuild = true end
    end
    -- Clamp the scroll offset to the final max_rows (bottom-seeded _page).
    if max_rows > 1 then
        local _per   = math.max(1, max_rows - 1)
        local _pages = math.max(1, math.ceil(#self._items / _per))
        if self._page > _pages then self._page = _pages; need_rebuild = true end
    end
    local _bt4 = _gettime()
    if need_rebuild then
        root_frame:free()
        slice, has_prev, has_next = self:_pageSlice(self._items, self._page, max_rows)
        root_frame, root_rows = self:_buildPanel(slice, root_w)
    end
    local _bt5 = _gettime()
    self._root_pager = nil
    if has_prev or has_next then
        local sm = self
        -- Paging the root may scroll the open folder's row off the page;
        -- close the flyout rather than leave it orphaned bottom-anchored.
        root_frame[1][#root_frame[1] + 1] = self:_pagerRow(root_w, has_prev, has_next,
            function() sm._flyout_for = nil; sm._page = sm._page - 1; sm:_reload() end,
            function() sm._flyout_for = nil; sm._page = sm._page + 1; sm:_reload() end,
            true)
        root_frame[1]._size = nil -- invalidate cached layout; getSize() was called before pager row existed
    end
    self._root_rows = root_rows
    -- Position setting read straight from the store (single source; the
    -- footer reads the same key). "right" mirrors the whole layout:
    -- root panel bottom-right, flyout opening leftward.
    local on_right = Store.read("start_menu_position", "left") == "right"
    local root_sz = root_frame:getSize()
    local root_x  = on_right and (sw - self._margin - root_sz.w) or self._margin
    local root_y  = sh - self.bottom_inset - root_sz.h
    -- Store pager hit region for onTapDismiss routing (backup tap path).
    -- The pager row sits at the bottom of the panel content; its top is
    -- root_sz.h minus the panel chrome minus one row_h.
    if has_prev or has_next then
        local chrome = self._panel_border + self._panel_pad
        local sm = self
        self._root_pager = {
            region = Geom:new{
                x = root_x + chrome,
                y = root_y + root_sz.h - chrome - self._row_h,
                w = root_w,
                h = self._row_h,
            },
            has_prev = has_prev,
            has_next = has_next,
            on_prev = function() sm._flyout_for = nil; sm._page = sm._page - 1; sm:_reload() end,
            on_next = function() sm._flyout_for = nil; sm._page = sm._page + 1; sm:_reload() end,
        }
    end
    local group = OverlapGroup:new{
        dimen = self.dimen:copy(),
        allow_mirroring = false, -- OffsetContainer children self-position
        OffsetContainer:new{ x_off = root_x, y_off = root_y, root_frame },
    }
    -- Include the down-right drop shadow so scoped refreshes clear it too.
    self._root_region = Geom:new{ x = root_x, y = root_y,
        w = root_sz.w + PANEL_SHADOW_DIST, h = root_sz.h + PANEL_SHADOW_DIST }

    -- Flyout panel
    local _bt6 = _gettime()
    self._flyout_region = nil
    self._flyout_rows = nil
    if self._flyout_for then
        local _l, _i, folder = Model.findById(self._items, self._flyout_for)
        if folder and folder.type == "folder" then
            local kids = folder.children or {}
            -- Clamp the flyout page (children may have shrunk since last build).
            if #kids <= max_rows then
                self._fly_page = 1
            else
                local pages = math.max(1, math.ceil(#kids / (max_rows - 1)))
                if self._fly_page > pages then self._fly_page = pages end
            end
            -- Flyout width is measured from the folder's full child list
            -- (not the visible page slice) so it is stable across page turns.
            -- Sized independently of root_w.
            local fly_w = self:_measurePanelWidth(kids)
            local fly_slice, fly_prev, fly_next =
                self:_pageSlice(kids, self._fly_page, max_rows)
            local fly_frame, fly_rows = self:_buildPanel(fly_slice, fly_w, self._flyout_for)
            if fly_prev or fly_next then
                local sm = self
                fly_frame[1][#fly_frame[1] + 1] = self:_pagerRow(fly_w, fly_prev, fly_next,
                    function() sm._fly_page = sm._fly_page - 1; sm:_reload() end,
                    function() sm._fly_page = sm._fly_page + 1; sm:_reload() end)
            end
            self._flyout_rows = fly_rows
            local fly_sz = fly_frame:getSize()
            -- Horizontal: always overlap the root panel slightly so the
            -- two panels read as connected (a gap beside the root made
            -- the flyout feel detached). Narrow screens overlap deeper.
            -- With the menu on the right the flyout opens LEFTWARD, the
            -- mirror image of the default layout (same overlap, mirrored
            -- narrow-screen clamp).
            local overlap = Screen:scaleBySize(14)
            local fly_x
            if on_right then
                fly_x = root_x - fly_sz.w + overlap
                if fly_x < self._margin then
                    -- Narrow screen: overlap the parent, keep a sliver visible.
                    fly_x = math.min(
                        root_x + root_sz.w - Screen:scaleBySize(24) - fly_sz.w,
                        self._margin)
                end
            else
                fly_x = root_x + root_sz.w - overlap
                if fly_x + fly_sz.w + self._margin > sw then
                    -- Narrow screen: overlap the parent, keep a sliver visible.
                    fly_x = math.max(root_x + Screen:scaleBySize(24),
                        sw - self._margin - fly_sz.w)
                end
            end
            -- Vertical: the flyout opens DOWNWARD from the folder row (top
            -- edges aligned) while it fits above the footer; when it would
            -- overrun, it shifts up just enough, floored at the top margin.
            -- Row positions are computed arithmetically (fresh rows haven't
            -- painted, so their dimens still sit at 0,0 here).
            local row_top = root_y
            local acc = root_y + root_frame.margin + root_frame.bordersize
                + root_frame.padding
            for _j, r in ipairs(self._root_rows) do
                if r.entry and r.entry.id == self._flyout_for then
                    row_top = acc
                    break
                end
                acc = acc + r.row.dimen.h
            end
            local bottom_limit = sh - self.bottom_inset -- flush above footer,
                -- same floor the root panel sits on
            local fly_y = row_top
            if fly_y + fly_sz.h > bottom_limit then
                fly_y = bottom_limit - fly_sz.h
            end
            fly_y = math.max(self._margin, fly_y)
            group[#group + 1] = OffsetContainer:new{
                x_off = fly_x, y_off = fly_y, fly_frame }
            self._flyout_region = Geom:new{ x = fly_x, y = fly_y,
                w = fly_sz.w + PANEL_SHADOW_DIST, h = fly_sz.h + PANEL_SHADOW_DIST }
        else
            self._flyout_for = nil
        end
    end

    -- Close-icon overlay: if the caller passed the hamburger button's live
    -- dimen, paint an opaque mdi-close glyph over that region so the user
    -- sees a clear close target while the menu is open.
    self._burger_region = nil
    if self.burger_dimen and self.burger_dimen.w > 0 then
        local bd = self.burger_dimen
        -- Mask EXACTLY the hamburger's art cell (art × art), centred on the
        -- button's centre x at the art-box top (focusBorder() below the frame
        -- top -- the same anchor the painted bars use). NOT the full button
        -- frame: bd spans the whole side strip, so an opaque box that wide
        -- blanks out everything beside the glyph (e.g. a reader progress bar).
        local FG  = require("lib/bookshelf_footer_geom")
        local art = FG.barMetrics().art
        local cx    = bd.x + math.floor(bd.w / 2)
        local box_x = cx - math.floor(art / 2)
        local box_y = bd.y + FG.focusBorder()
        local box_h = art
        -- Clip to below the panel's bottom edge so the opaque box never erases
        -- the panel's bottom-left border corner.
        local panel_bottom = sh - self.bottom_inset
        if box_y < panel_bottom then
            box_h = box_h - (panel_bottom - box_y)
            box_y = panel_bottom
        end
        box_h = math.max(0, box_h) -- short dimens: never go negative
        -- Custom-painted X, NOT a glyph: the close X replaces the painted
        -- hamburger bars in the same slot, so the two must read at the SAME
        -- stroke weight — and glyph strokes can't be tuned (U+2715 was the
        -- thinnest candidate and still rendered heavier than the bars).
        -- Two diagonal strokes of EXACTLY the bars' thickness
        -- (BookshelfWidget.FOOTER_STROKE_W), traced as stroke×stroke squares
        -- stepped 1px along both diagonals — renders clean at e-ink sizes,
        -- same precedent as _buildStartMenuIcon's painted bars.
        local stroke = (self.bw and self.bw.FOOTER_STROKE_W)
            or math.max(1, math.floor(art / 14))
        -- Ink footprint matches the bars' span (~62% of the art square),
        -- which also tracks the old glyph's ~70%-of-em ink box.
        local xspan = math.floor(art * 0.62)
        local Widget  = require("ui/widget/widget")
        local XWidget = Widget:extend{}
        function XWidget:getSize() return Geom:new{ w = xspan, h = xspan } end
        function XWidget:paintTo(bb, x, y)
            self.dimen = Geom:new{ x = x, y = y, w = xspan, h = xspan }
            -- Clamp so every square stays inside the art box.
            local last = xspan - stroke
            for t = 0, last do
                bb:paintRect(x + t, y + t, stroke, stroke,
                    Blitbuffer.COLOR_BLACK)              -- ↘ diagonal
                bb:paintRect(x + last - t, y + t, stroke, stroke,
                    Blitbuffer.COLOR_BLACK)              -- ↙ diagonal
            end
        end
        local glyph = XWidget:new{}
        local centered = CenterContainer:new{
            dimen = Geom:new{ w = art, h = box_h },
            glyph,
        }
        local close_frame = FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            bordersize = 0,
            padding    = 0,
            centered,
        }
        group[#group + 1] = OffsetContainer:new{
            x_off = box_x, y_off = box_y, close_frame,
        }
        self._burger_region = Geom:new{ x = box_x, y = box_y,
            w = art, h = box_h }
    end

    self[1] = group
    -- Union of panel regions, used for scoped refreshes.
    self._dirty_region = self._root_region:copy()
    if self._flyout_region then
        self._dirty_region = self._dirty_region:combine(self._flyout_region)
    end
    if self._burger_region then
        self._dirty_region = self._dirty_region:combine(self._burger_region)
    end
    logger.dbg(string.format(
        "[bookshelf perf] StartMenu:_build: markUnresolved=%.0fms rootPanel=%.0fms"
        .. " overflowCheck=%.0fms rebuildPanel=%.0fms flyout=%.0fms TOTAL=%.0fms"
        .. " items=%d rows=%d flyout_for=%s",
        (_bt1 - _bt0) * 1000, (_bt3 - _bt2) * 1000, (_bt4 - _bt3) * 1000,
        (_bt5 - _bt4) * 1000, (_gettime() - _bt6) * 1000, (_gettime() - _bt0) * 1000,
        #self._items, #root_rows, tostring(self._flyout_for)))
end

-- Rebuild from the store and repaint (after edits / paging / flyout toggle).
function StartMenu:_reload(scope_rect)
    local old_region = self._dirty_region
    -- Snapshot each panel's rect (not just their union): a bottom-anchored
    -- flyout can grow UPWARD while the union bbox stays fixed (root's top still
    -- dominates, the flyout's bottom stays pinned above the footer), so the
    -- union alone misses a flyout height change. Compare panels individually.
    local old_root = self._root_region and self._root_region:copy()
    local old_fly  = self._flyout_region and self._flyout_region:copy()
    self._items = self:_loadItems()
    -- Page clamping is handled in _build() after the overflow loop determines
    -- the effective max_rows; don't pre-reset here with the nominal value.
    if self._page < 1 then self._page = 1 end
    if self[1] and self[1].free then self[1]:free() end
    self:_build()
    -- The rebuild can orphan the key-nav focus (focused entry edited away,
    -- or its flyout panel gone): revalidate against the fresh rows and
    -- rebuild once more if the ring has to move.
    if self._focus then
        local p0, e0 = self._focus.panel, self._focus.entry_id
        self:_validateFocus()
        if self._focus.panel ~= p0 or self._focus.entry_id ~= e0 then
            if self[1] and self[1].free then self[1]:free() end
            self:_build()
        end
    end
    local region
    local d = self._dirty_region
    -- A panel is BOTTOM-anchored (root_y = bottom - height; the flyout shifts
    -- up when it would overrun the footer). When a module's height changes its
    -- panel grows/shrinks and every row ABOVE the changed one moves with it.
    -- Detect that by comparing EACH panel's rect before/after the rebuild (the
    -- union can stay fixed even when the flyout moves — see the snapshot above).
    local function _rectMoved(a, b)
        if not a or not b then return a ~= b end -- appeared / disappeared
        return a.x ~= b.x or a.y ~= b.y or a.w ~= b.w or a.h ~= b.h
    end
    local panel_moved = _rectMoved(old_root, self._root_region)
        or _rectMoved(old_fly, self._flyout_region)
    if scope_rect and d and not panel_moved then
        -- Scoped reload (a keep_open module re-render at the SAME height):
        -- refresh only from the tapped row's top down to the panel bottom, so
        -- module cards ABOVE the tapped one don't redraw. NOT combined with
        -- old_region (the whole-panel rect) — that would re-expand to the full
        -- panel and defeat the scoping.
        local bottom = d.y + d.h
        local top = math.max(d.y, scope_rect.y)
        region = Geom:new{ x = d.x, y = top, w = d.w, h = math.max(1, bottom - top) }
    else
        region = self._dirty_region:copy()
        if old_region then region = region:combine(old_region) end
    end
    -- Dirty the widget BELOW us: UIManager repaints from the first dirty
    -- widget up the stack, and this overlay only paints its panels, so a
    -- shrinking rebuild would otherwise leave the vacated area's old pixels
    -- on screen. Repainting the bookshelf underneath restores the backdrop
    -- before we paint on top.
    UIManager:setDirty(self.bw or self._repaint_under or self, function() return "ui", region end)
end

function StartMenu:_toggleFlyout(folder_id)
    local new_for = (self._flyout_for ~= folder_id) and folder_id or nil
    if new_for ~= self._flyout_for then self._fly_page = 1 end
    self._flyout_for = new_for
    self:_reload()
end

function StartMenu:_close()
    -- Close animation: reverse of the open reveal. The background (stashed at
    -- open) reappears from the top of the panel region downward, so the panel
    -- reads as wiping
    -- down out of view. Then close for real (repaints the live background).
    local bg = self._bg_snapshot
    local r  = self._dirty_region
    local anim_steps = PageWipe.resolveSteps("start_menu_animation")
    local wiped = false
    if bg and r and anim_steps and Screen.refreshUI then
        wiped = pcall(function()
            local rx, ry, rw, rh = r.x, r.y, r.w, r.h
            local panel_bb = Screen.bb:copy()   -- current: background + panel
            local STEPS, prev_dh = anim_steps, 0
            for i = 1, STEPS do
                local dh = math.floor(rh * i / STEPS)  -- background revealed top-down
                Screen.bb:blitFrom(bg, rx, ry, rx, ry, rw, dh)
                if rh - dh > 0 then
                    Screen.bb:blitFrom(panel_bb, rx, ry + dh, rx, ry + dh, rw, rh - dh)
                end
                if i < STEPS then
                    local strip_h = dh - prev_dh
                    if strip_h > 0 then
                        Screen:refreshUI(rx, ry + prev_dh, rw, strip_h)
                        UIManager:yieldToEPDC(20000)
                    end
                else
                    Screen:refreshUI(rx, ry, rw, rh)   -- final frame = the background
                end
                prev_dh = dh
            end
            panel_bb:free()
        end)
    end
    if bg then bg:free(); self._bg_snapshot = nil end
    if wiped then
        -- The wipe already painted + refreshed the post-close frame (the
        -- background). `invisible` makes UIManager:close skip its redundant
        -- underlying repaint + refresh; it still unregisters + fires CloseWidget.
        self.invisible = true
        UIManager:close(self)
    else
        UIManager:close(self, "ui", self._dirty_region)
    end
end

-- Clear the open-in-progress marker once the first paint has actually
-- completed: if a module segfaults the paint pass, InputContainer.paintTo
-- never returns, the marker stays set, and the next open detects the crash and
-- enters safe mode (issue #163). Gated on a flag so it fires once per survived
-- paint; _activate resets the flag when leaving safe mode so a retry's paint
-- is re-evaluated.
function StartMenu:paintTo(bb, x, y)
    InputContainer.paintTo(self, bb, x, y)
    if not self._open_painted then
        self._open_painted = true
        pcall(Breaker.endOpen, Store)
    end
end

function StartMenu:onCloseWidget()
    if StartMenu._live == self then StartMenu._live = nil end
    if self._bg_snapshot then self._bg_snapshot:free(); self._bg_snapshot = nil end  -- free if close was skipped
    if self[1] and self[1].free then self[1]:free() end
end

function StartMenu:_activate(entry, tap_rect)
    if entry.type == "folder" then
        self:_toggleFlyout(entry.id)
        return
    end
    if self._unresolved_ids and self._unresolved_ids[entry.id] then return end
    if entry.type == "module" then
        -- Safe-mode open (a previous open crashed before painting): every
        -- module is suppressed. Tapping any of them means "turn modules back
        -- on": leave safe mode and reload so they render again. Re-arm the
        -- open marker and reset the paint flag so a fresh paint-pass crash on
        -- retry is still caught on the next open.
        if self._safe_mode then
            self._safe_mode = false
            self._open_painted = false
            pcall(Breaker.armOpen, Store)
            self:_reload()
            return
        end
        -- Resolve before closing: a module without a tap target is a no-op
        -- (the menu stays open) rather than a close-for-nothing.
        local def = Modules.get(entry.module)
        if not (def and def.on_tap) then return end
        -- on_tap receives a context table (modules that ignore the arg keep
        -- working): bw = the bookshelf widget, menu = this start menu.
        local menu = self
        local ctx = { bw = self.bw, menu = self, entry = entry, surface = "start_menu" }
        -- Per-instance save: persist a change the module made to ctx.entry into
        -- the start-menu list, then reload. (Mirrors the hero ctx.save.)
        function ctx.save()
            local Model = require("lib/bookshelf_start_menu_model")
            local items = Model.load()
            local list, i = Model.findById(items, entry.id)
            if list and i then list[i] = entry end
            Model.save(items)
            menu:_reload()
        end
        ctx.config = require("lib/bookshelf_module_kit").entryConfig(entry, ctx.save)
        -- keep_open may be a boolean or a function(ctx) -> bool resolved at
        -- tap time (e.g. quote_of_day keeps the menu only for its "New
        -- quote" tap action). pcall: a broken module must not wedge the
        -- menu; on error fall back to the close-then-act path.
        local keep = def.keep_open
        if type(keep) == "function" then
            local ok_k, v = pcall(keep, ctx)
            keep = ok_k and v
        end
        if keep then
            -- keep_open modules act WITHOUT closing the menu (e.g. load a
            -- book into the hero behind it), then the menu reloads so the
            -- module re-renders its fresh state. pcall: a broken module
            -- must not wedge the open menu.
            local ok, err = pcall(def.on_tap, ctx)
            if not ok then
                logger.warn("[bookshelf] start menu module tap failed:",
                    entry.module, err)
            end
            self:_reload(tap_rect)
            return
        end
        self:_close()
        -- Contain a broken on_tap: the menu has already closed, so an unguarded
        -- error here would surface as an unhandled nextTick crash.
        UIManager:nextTick(function()
            local ok, err = pcall(def.on_tap, ctx)
            if not ok then
                logger.warn("[bookshelf] start menu module tap failed:",
                    entry.module, err)
            end
        end)
        return
    end
    local bw = self.bw
    self:_close()
    UIManager:nextTick(function()
        require("lib/bookshelf_action_exec").dispatch(entry, bw)
    end)
end

-- Long-press editing. pcall keeps the widget resilient if the edit module
-- is missing or broken (e.g. a load-time error in bookshelf_start_menu_edit).
function StartMenu:_editEntry(entry)
    local ok, Edit = pcall(require, "lib/bookshelf_start_menu_edit")
    if ok and Edit then Edit.show(self, entry) end
end
-- anchor_id: entry after which the new item is inserted (or nil for append).
-- folder_id: when set, the new item goes inside that folder regardless of anchor.
function StartMenu:_addEntry(anchor_id, folder_id)
    local ok, Edit = pcall(require, "lib/bookshelf_start_menu_edit")
    if ok and Edit then Edit.showAdd(self, anchor_id, folder_id) end
end

-- ── Key-nav helpers ──────────────────────────────────────────────────────────

-- Returns the list of focusable entries in the named panel ("root"/"flyout")
-- for the CURRENT visible page slice. The synthetic __add row IS included
-- (it is the only focusable on an empty root panel).
function StartMenu:_panelEntries(panel)
    local rows = panel == "flyout" and self._flyout_rows or self._root_rows
    if not rows then return {} end
    local out = {}
    for _i, r in ipairs(rows) do
        local e = r.entry
        if e then
            out[#out + 1] = e
        end
    end
    return out
end

-- Returns the id of the first focusable entry in the named panel, or nil.
function StartMenu:_firstFocusable(panel)
    local entries = self:_panelEntries(panel)
    return entries[1] and entries[1].id or nil
end

-- Returns the id of the last focusable entry in the named panel, or nil.
function StartMenu:_lastFocusable(panel)
    local entries = self:_panelEntries(panel)
    return entries[#entries] and entries[#entries].id or nil
end

-- Returns the current focused entry table, or nil.
function StartMenu:_focusedEntry()
    if not self._focus or not self._focus.entry_id then return nil end
    local entries = self:_panelEntries(self._focus.panel)
    for _i, e in ipairs(entries) do
        if e.id == self._focus.entry_id then return e end
    end
    return nil
end

-- Rebuild from self._items WITHOUT reloading from disk. Used for focus-ring
-- updates where the data hasn't changed.
function StartMenu:_rebuild_only()
    local old_region = self._dirty_region
    if self._page < 1 then self._page = 1 end
    if self[1] and self[1].free then self[1]:free() end
    self:_build()
    local region = self._dirty_region:copy()
    if old_region then region = region:combine(old_region) end
    UIManager:setDirty(self.bw or self._repaint_under or self, function() return "ui", region end)
end

-- Ensure focus points at a visible focusable. If the focused panel itself is
-- gone (flyout closed externally) drop back to root; if the focused entry is
-- no longer visible (deleted, or moved off the page) fall back to the first
-- focusable of the panel.
function StartMenu:_validateFocus()
    if not self._focus then return end
    if self._focus.panel == "flyout" and not self._flyout_rows then
        self._focus.panel = "root"
        self._focus.entry_id = nil
    end
    local entries = self:_panelEntries(self._focus.panel)
    if #entries == 0 then self._focus.entry_id = nil; return end
    for _i, e in ipairs(entries) do
        if e.id == self._focus.entry_id then return end -- still visible, ok
    end
    self._focus.entry_id = entries[1].id
end

-- ── Key-nav event handlers ────────────────────────────────────────────────────

function StartMenu:onSMFocusDown()
    if not self._focus then return true end
    local panel = self._focus.panel
    local entries = self:_panelEntries(panel)
    -- Find current position (nil when page has no focusables).
    local idx = nil
    for i, e in ipairs(entries) do
        if e.id == self._focus.entry_id then idx = i; break end
    end
    if #entries > 0 and idx == nil then
        -- No valid focus: seed first.
        self._focus.entry_id = entries[1].id
        self:_rebuild_only()
        return true
    end
    if idx ~= nil and idx < #entries then
        -- Step within the page.
        self._focus.entry_id = entries[idx + 1].id
        self:_rebuild_only()
        return true
    end
    -- At the bottom edge (or page has no focusables): try to advance the page.
    local max_rows = self:_maxRows()
    if panel == "root" then
        local total = #self._items
        if total > max_rows then
            local per = max_rows - 1
            local pages = math.max(1, math.ceil(total / per))
            if self._page < pages then
                self._flyout_for = nil
                self._page = self._page + 1
                self._items = self:_loadItems()
                self:_rebuild_only()
                self._focus.entry_id = self:_firstFocusable("root")
                self:_rebuild_only()
            end
        end
    elseif panel == "flyout" and self._flyout_for then
        local _l, _i, folder = Model.findById(self._items, self._flyout_for)
        local kids = folder and folder.children or {}
        if #kids > max_rows then
            local per = max_rows - 1
            local pages = math.max(1, math.ceil(#kids / per))
            if self._fly_page < pages then
                self._fly_page = self._fly_page + 1
                self:_rebuild_only()
                self._focus.entry_id = self:_firstFocusable("flyout")
                self:_rebuild_only()
            end
        end
    end
    return true
end

function StartMenu:onSMFocusUp()
    if not self._focus then return true end
    local panel = self._focus.panel
    local entries = self:_panelEntries(panel)
    local idx = nil
    for i, e in ipairs(entries) do
        if e.id == self._focus.entry_id then idx = i; break end
    end
    if #entries > 0 and idx == nil then
        self._focus.entry_id = entries[1].id
        self:_rebuild_only()
        return true
    end
    if idx ~= nil and idx > 1 then
        self._focus.entry_id = entries[idx - 1].id
        self:_rebuild_only()
        return true
    end
    -- At the top edge (or page has no focusables): try to go to previous page.
    local max_rows = self:_maxRows()
    if panel == "root" then
        local total = #self._items
        if total > max_rows and self._page > 1 then
            self._flyout_for = nil
            self._page = self._page - 1
            self._items = self:_loadItems()
            self:_rebuild_only()
            self._focus.entry_id = self:_lastFocusable("root")
            self:_rebuild_only()
        end
    elseif panel == "flyout" and self._flyout_for then
        if self._fly_page > 1 then
            local max_rows2 = self:_maxRows()
            local _l, _i, folder = Model.findById(self._items, self._flyout_for)
            local kids = folder and folder.children or {}
            if #kids > max_rows2 and self._fly_page > 1 then
                self._fly_page = self._fly_page - 1
                self:_rebuild_only()
                self._focus.entry_id = self:_lastFocusable("flyout")
                self:_rebuild_only()
            end
        end
    end
    return true
end

function StartMenu:onSMFocusRight()
    if not self._focus then return true end
    if self._focus.panel ~= "root" then return true end
    local entry = self:_focusedEntry()
    if not entry or entry.type ~= "folder" then return true end
    -- Open the flyout if not already open for this folder.
    if self._flyout_for ~= entry.id then
        self._flyout_for = entry.id
        self._fly_page = 1
        self:_rebuild_only()
    end
    -- Move focus into the flyout.
    self._focus.panel = "flyout"
    self._focus.entry_id = self:_firstFocusable("flyout")
    self:_rebuild_only()
    return true
end

function StartMenu:onSMFocusLeft()
    if not self._focus then return true end
    if self._focus.panel ~= "flyout" then return true end
    -- Close the flyout, return focus to the folder entry in root.
    local folder_id = self._flyout_for
    self._flyout_for = nil
    self._fly_page = 1
    self._focus.panel = "root"
    self._focus.entry_id = folder_id
    self:_rebuild_only()
    return true
end

function StartMenu:onSMPress()
    if not self._focus then return true end
    local entry = self:_focusedEntry()
    if not entry then return true end
    if entry.id == "__add" then
        -- Pass folder_id when the __add row is inside a flyout panel so the
        -- new entry lands in the folder, not at the top level.
        local fid = (self._focus.panel == "flyout") and self._flyout_for or nil
        self:_addEntry(nil, fid)
    else
        self:_activate(entry)
    end
    return true
end

function StartMenu:onSMHold()
    if not self._focus then return true end
    local entry = self:_focusedEntry()
    if entry and entry.id ~= "__add" then
        self:_editEntry(entry)
    end
    return true
end

-- Back: close the flyout first (returning focus to its folder), then the menu.
function StartMenu:onClose()
    if self._flyout_for then
        local folder_id = self._flyout_for
        self._flyout_for = nil
        self._fly_page = 1
        if self._focus then
            self._focus.panel = "root"
            self._focus.entry_id = folder_id
            self:_validateFocus()
        end
        self:_rebuild_only()
        return true
    end
    self:_close()
    return true
end

-- ── End key-nav ───────────────────────────────────────────────────────────────

-- Children see gestures before this handler (WidgetContainer propagates
-- child-first), so a tap reaching here hit no row. Taps inside a panel are
-- swallowed (or close an open flyout); anywhere else dismisses the menu.
function StartMenu:onTapDismiss(_arg, ges)
    local p = ges.pos
    local in_root = self._root_region and p:intersectWith(self._root_region)
    local in_fly  = self._flyout_region and p:intersectWith(self._flyout_region)
    -- Flyout first: it overlaps the root panel's right edge and is
    -- painted on top, so taps in the overlap strip belong to it.
    if in_fly then
        return true
    end
    if in_root then
        -- Pager row (backup tap handler): route taps on the pager area even
        -- if the InputContainer ges_events path didn't fire.
        local pg = self._root_pager
        if pg and p:intersectWith(pg.region) then
            local mid = pg.region.x + pg.region.w / 2
            if p.x < mid then
                if pg.has_prev then pg.on_prev() end
            else
                if pg.has_next then pg.on_next() end
            end
            return true
        end
        if self._flyout_for then
            self:_toggleFlyout(self._flyout_for)
        end
        return true
    end
    self:_close()
    return true
end
return StartMenu
