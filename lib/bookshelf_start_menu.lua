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
local OverlapGroup    = require("ui/widget/overlapgroup")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger          = require("logger")
local Screen          = Device.screen
local Model           = require("lib/bookshelf_start_menu_model")
local Modules         = require("lib/bookshelf_start_menu_modules")
local Store           = require("lib/bookshelf_settings_store")
local _               = require("lib/bookshelf_i18n").gettext

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
function StartMenu.open(bw, bottom_inset, burger_dimen)
    local menu = StartMenu:new{
        bw           = bw,
        bottom_inset = bottom_inset + Screen:scaleBySize(6),
        burger_dimen = burger_dimen,
    }
    UIManager:show(menu, "ui", menu._dirty_region)
    StartMenu._live = menu -- test/introspection hook; cleared in onCloseWidget
end

function StartMenu:init()
    -- Menu-open signal: bump the loader's generation counter exactly once
    -- per open (init runs once per StartMenu instance; _reload does not
    -- re-init). Modules key per-open caches on it — see the README.
    pcall(Modules.bumpGeneration)
    self.dimen = Geom:new{ x = 0, y = 0,
        w = Screen:getWidth(), h = Screen:getHeight() }
    -- Side margin matches the bookshelf's own side gap (same formula as
    -- _computeDims' PAD: fullscreen padding scaled, capped at 3% of width)
    -- so the popup sits off the screen edge like the shelf content does.
    local Size = require("ui/size")
    self._margin = math.min(
        math.floor(Size.padding.fullscreen * 2 * 0.8),
        math.floor(Screen:getWidth() * 0.03))
    self._pad      = Screen:scaleBySize(10)
    self._row_face  = Fonts:getFace("cfont", 18)
    self._icon_face = Fonts:getFace("cfont", 22)
    self._icon_col_w = Screen:scaleBySize(30)
    self._icon_gap   = math.floor(self._pad / 2) -- breathing room icon → label
    self._row_h     = Screen:scaleBySize(40)
    -- Chrome constants shared by row building and the pagination budget.
    self._focus_border = Screen:scaleBySize(2) -- row margin/border swap
    self._panel_border = Screen:scaleBySize(2) -- panel FrameContainer border
    self._panel_pad    = Screen:scaleBySize(3) -- panel FrameContainer padding
    self._items    = Model.load()
    self._page     = 1     -- root panel page (panel-internal pagination)
    self._fly_page = 1     -- flyout panel page
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
    self:_build()
    -- Seed focus after the first build so _panelEntries can inspect the
    -- rendered rows. If nothing is focusable yet (empty menu with no __add)
    -- _focus.entry_id stays nil and the menu opens without a focus ring.
    if self._focus then
        local first = self:_firstFocusable(self._focus.panel)
        if first then
            self._focus.entry_id = first
            self:_rebuild_only()
        end
    end
end

function StartMenu:_panelWidthBounds()
    local sw = Screen:getWidth()
    return Screen:scaleBySize(180), math.floor(sw * 0.6)
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
    local has_folder = false
    for _i, e in ipairs(entries) do
        if e.type == "folder" then has_folder = true; break end
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
    end
    local icon = TextWidget:new{
        text = icon_text or " ", face = self._icon_face, fgcolor = fg,
    }
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
        sm:_activate(entry); return true
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
function StartMenu:_buildModuleRow(entry, w, in_flyout)
    local def = Modules.get(entry.module)
    local card_margin = math.floor(self._pad / 2) -- inset from panel edges
    local card_pad    = self._pad
    local inner_w     = w - 2 * card_margin - 2 * card_pad
    local inner
    if def then
        local ok, widget = pcall(def.render, inner_w)
        inner = ok and widget or nil
        if not ok then
            logger.warn("[bookshelf] start menu module render failed:",
                entry.module, widget)
        end
    end
    if not inner then
        inner = TextWidget:new{
            text = (def and def.title) or entry.module,
            face = self._row_face, fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }
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
    -- Spans pad the row back out to exactly `w` so the row's dimen (and
    -- tap range) spans the whole panel width, same contract as _buildRow.
    local card_row = HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = card_margin },
        card,
        HorizontalSpan:new{
            width = math.max(0, w - card_margin - card:getSize().w),
        },
    }
    local frame = FrameContainer:new{
        bordersize     = 0,
        padding        = 0,
        padding_top    = card_margin,
        padding_bottom = card_margin,
        card_row,
    }
    local sm = self
    local row = InputContainer:new{ dimen = frame:getSize(), frame }
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
        sm:_activate(entry); return true
    end
    function row:onHold(_a, ges)
        if flyoutOwns(ges) then return false end
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
        local row = entry.type == "module"
            and self:_buildModuleRow(entry, w, in_flyout)
            or  self:_buildRow(entry, w,
                self._focus and self._focus.entry_id == entry.id, in_flyout)
        vg[#vg + 1] = row
        rows[#rows + 1] = { row = row, entry = entry }
    end
    local frame = PanelFrame:new{
        bordersize = self._panel_border,
        padding    = self._panel_pad,
        radius     = Screen:scaleBySize(4), -- bookshelf's card radius (CARD_RADIUS)
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
function StartMenu:_pageSlice(entries, page, max_rows)
    local total = #entries
    if total <= max_rows then return entries, false, false end
    local per = max_rows - 1 -- reserve one row slot for the pager
    local first = (page - 1) * per + 1
    local out = {}
    for i = first, math.min(first + per - 1, total) do
        out[#out + 1] = entries[i]
    end
    return out, first > 1, first + per - 1 < total
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
        mk("\xE2\x80\xB9", has_prev, on_prev),  -- ‹
        mk("\xE2\x80\xBA", has_next, on_next),  -- ›
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
    local ids = {}
    local function walk(list)
        for _i, it in ipairs(list) do
            if it.type == "action" and type(it.plugin) == "table" then
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
    self:_markUnresolved(self._items)
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    local max_rows = self:_maxRows()

    -- Root panel: measure the FULL item list (not just the visible page slice)
    -- so the panel width is stable across page turns.
    local root_w = self:_measurePanelWidth(self._items)

    -- Root panel
    local slice, has_prev, has_next =
        self:_pageSlice(self._items, self._page, max_rows)
    local root_frame, root_rows = self:_buildPanel(slice, root_w)
    if has_prev or has_next then
        local sm = self
        -- Paging the root may scroll the open folder's row off the page;
        -- close the flyout rather than leave it orphaned bottom-anchored.
        root_frame[1][#root_frame[1] + 1] = self:_pagerRow(root_w, has_prev, has_next,
            function() sm._flyout_for = nil; sm._page = sm._page - 1; sm:_reload() end,
            function() sm._flyout_for = nil; sm._page = sm._page + 1; sm:_reload() end,
            true)
    end
    self._root_rows = root_rows
    -- Position setting read straight from the store (single source; the
    -- footer reads the same key). "right" mirrors the whole layout:
    -- root panel bottom-right, flyout opening leftward.
    local on_right = Store.read("start_menu_position", "left") == "right"
    local root_sz = root_frame:getSize()
    local root_x  = on_right and (sw - self._margin - root_sz.w) or self._margin
    local root_y  = sh - self.bottom_inset - root_sz.h
    local group = OverlapGroup:new{
        dimen = self.dimen:copy(),
        allow_mirroring = false, -- OffsetContainer children self-position
        OffsetContainer:new{ x_off = root_x, y_off = root_y, root_frame },
    }
    self._root_region = Geom:new{ x = root_x, y = root_y,
        w = root_sz.w, h = root_sz.h }

    -- Flyout panel
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
                if r.entry.id == self._flyout_for then
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
                w = fly_sz.w, h = fly_sz.h }
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
        -- padding_bottom baked into bd.h by _wrapAsFooterButton
        local hit_ext = (self.bw and self.bw.FOOTER_HIT_EXTENSION)
            or Screen:scaleBySize(12)
        local visual_h = bd.h - hit_ext
        local ind_y    = bd.y
        -- Clip the indicator to below the panel's bottom edge: the burger
        -- frame can be taller than the footer band (it is vertically
        -- centered into it), and an unclipped opaque white frame would
        -- erase the panel's bottom-left border corner.
        local panel_bottom = sh - self.bottom_inset
        if ind_y < panel_bottom then
            visual_h = visual_h - (panel_bottom - ind_y)
            ind_y = panel_bottom
        end
        visual_h = math.max(0, visual_h) -- short dimens: never go negative
        -- Custom-painted X, NOT a glyph: the close X replaces the painted
        -- hamburger bars in the same slot, so the two must read at the SAME
        -- stroke weight — and glyph strokes can't be tuned (U+2715 was the
        -- thinnest candidate and still rendered heavier than the bars).
        -- Two diagonal strokes of EXACTLY the bars' thickness
        -- (BookshelfWidget.FOOTER_STROKE_W), traced as stroke×stroke squares
        -- stepped 1px along both diagonals — renders clean at e-ink sizes,
        -- same precedent as _buildStartMenuIcon's painted bars.
        local art_size = Screen:scaleBySize(32)
        local stroke   = (self.bw and self.bw.FOOTER_STROKE_W)
            or math.max(1, math.floor(art_size / 14))
        -- Ink footprint matches the bars' span (~62% of the art square),
        -- which also tracks the old glyph's ~70%-of-em ink box.
        local xspan = math.floor(art_size * 0.62)
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
            dimen = Geom:new{ w = bd.w, h = visual_h },
            glyph,
        }
        local close_frame = FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            bordersize = 0,
            padding    = 0,
            centered,
        }
        group[#group + 1] = OffsetContainer:new{
            x_off = bd.x, y_off = ind_y, close_frame,
        }
        self._burger_region = Geom:new{ x = bd.x, y = ind_y,
            w = bd.w, h = visual_h }
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
end

-- Rebuild from the store and repaint (after edits / paging / flyout toggle).
function StartMenu:_reload()
    local old_region = self._dirty_region
    self._items = Model.load()
    local max_rows = self:_maxRows()
    if #self._items <= max_rows then
        self._page = 1
    elseif self._page > 1 then
        local pages = math.max(1, math.ceil(#self._items / (max_rows - 1)))
        if self._page > pages then self._page = pages end
    end
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
    local region = self._dirty_region:copy()
    if old_region then region = region:combine(old_region) end
    -- Dirty the widget BELOW us: UIManager repaints from the first dirty
    -- widget up the stack, and this overlay only paints its panels, so a
    -- shrinking rebuild would otherwise leave the vacated area's old pixels
    -- on screen. Repainting the bookshelf underneath restores the backdrop
    -- before we paint on top.
    UIManager:setDirty(self.bw or self, function() return "ui", region end)
end

function StartMenu:_toggleFlyout(folder_id)
    local new_for = (self._flyout_for ~= folder_id) and folder_id or nil
    if new_for ~= self._flyout_for then self._fly_page = 1 end
    self._flyout_for = new_for
    self:_reload()
end

function StartMenu:_close()
    UIManager:close(self, "ui", self._dirty_region)
end

function StartMenu:onCloseWidget()
    if StartMenu._live == self then StartMenu._live = nil end
    if self[1] and self[1].free then self[1]:free() end
end

function StartMenu:_activate(entry)
    if entry.type == "folder" then
        self:_toggleFlyout(entry.id)
        return
    end
    if self._unresolved_ids and self._unresolved_ids[entry.id] then return end
    if entry.type == "module" then
        -- Resolve before closing: a module without a tap target is a no-op
        -- (the menu stays open) rather than a close-for-nothing.
        local def = Modules.get(entry.module)
        if not (def and def.on_tap) then return end
        -- on_tap receives a context table (modules that ignore the arg keep
        -- working): bw = the bookshelf widget, menu = this start menu.
        local ctx = { bw = self.bw, menu = self }
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
            self:_reload()
            return
        end
        self:_close()
        UIManager:nextTick(function() def.on_tap(ctx) end)
        return
    end
    local bw = self.bw
    self:_close()
    UIManager:nextTick(function()
        if entry.internal == "close" then
            if bw and bw.onClose then
                bw:onClose()
                -- bw:onClose() is UIManager:close() with no refresh args:
                -- that repaints the widgets it reveals into the buffer but
                -- enqueues NO screen refresh (UIManager:_refresh drops a
                -- nil mode), so on e-ink only our scoped menu-close region
                -- got flushed and the rest of the screen kept stale
                -- bookshelf pixels. "all" re-flags the whole remaining
                -- window stack for repaint; "full" enqueues the
                -- full-screen refresh that flushes the result.
                UIManager:setDirty("all", "full")
            end
        elseif entry.internal == "settings" then
            -- Host the plugin's FULL top-level menu (hero card, shelf tabs,
            -- collections, hardcover, settings, ...), not just the settings
            -- subtree: probe the live plugin module's addToMainMenu (the
            -- same technique the plugin scanner uses) and assemble the
            -- entries in the canonical MENU_ORDER from main.lua.
            local MenuHost = require("lib/bookshelf_menu_host")
            local S = require("lib/bookshelf_settings")
            S._bw = bw
            local items
            local ok_probe = pcall(function()
                local fm_mod = package.loaded["apps/filemanager/filemanager"]
                local fm  = fm_mod and fm_mod.instance
                local mod = fm and fm.bookshelf
                if not (mod and type(mod.addToMainMenu) == "function") then
                    return
                end
                local probe = {}
                mod:addToMainMenu(probe)
                -- Plugin instances inherit class fields, so MENU_ORDER
                -- resolves from the Bookshelf class; if it ever moves,
                -- fall back to the probe's keys alphabetically.
                local order = mod.MENU_ORDER
                if type(order) ~= "table" then
                    order = {}
                    for k in pairs(probe) do order[#order + 1] = k end
                    table.sort(order)
                end
                local out = {}
                for _i, key in ipairs(order) do
                    local it = probe[key]
                    if type(it) == "table" and key ~= "bookshelf_tab" then
                        out[#out + 1] = it
                    end
                end
                if #out > 0 then items = out end
            end)
            if not (ok_probe and items) then
                -- Fallback: the settings subtree (pre-probe behavior).
                items = S:_settingsSubItems()
            end
            MenuHost.show{
                title = _("Bookshelf"),
                item_table = items,
            }
        elseif type(entry.plugin) == "table" then
            -- FM plugin launcher: resolve against the LIVE FileManager
            -- instance at activation time (the stored method name may be
            -- the scanner's re-probe sentinel). No full-screen dirty
            -- needed - the launched plugin shows its own UI.
            local PluginScan = require("lib/bookshelf_plugin_scan")
            local launch = PluginScan.resolve(entry.plugin.key, entry.plugin.method)
            if launch then
                local ok_l, err = pcall(launch)
                if not ok_l then
                    logger.warn("[bookshelf] start menu plugin launch failed:",
                        entry.plugin.key, err)
                end
            end
        elseif type(entry.action) == "table" then
            local ok, Dispatcher = pcall(require, "dispatcher")
            if ok then Dispatcher:execute(entry.action) end
        end
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
-- for the CURRENT visible page slice. Module entries are excluded because they
-- have no meaningful "Press to activate" target. The synthetic __add row IS
-- included (it is the only focusable on an empty root panel).
function StartMenu:_panelEntries(panel)
    local rows = panel == "flyout" and self._flyout_rows or self._root_rows
    if not rows then return {} end
    local out = {}
    for _i, r in ipairs(rows) do
        local e = r.entry
        if e and e.type ~= "module" then
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
    -- clamp pages (same logic as _reload)
    local max_rows = self:_maxRows()
    if #self._items <= max_rows then
        self._page = 1
    elseif self._page > 1 then
        local pages = math.max(1, math.ceil(#self._items / (max_rows - 1)))
        if self._page > pages then self._page = pages end
    end
    if self[1] and self[1].free then self[1]:free() end
    self:_build()
    local region = self._dirty_region:copy()
    if old_region then region = region:combine(old_region) end
    UIManager:setDirty(self.bw or self, function() return "ui", region end)
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
                self._items = Model.load()
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
            self._items = Model.load()
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
        if self._flyout_for then
            self:_toggleFlyout(self._flyout_for)
        end
        return true
    end
    self:_close()
    return true
end
return StartMenu
