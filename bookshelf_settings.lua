-- bookshelf_settings.lua
-- Gear-menu settings modal for Bookshelf: hero-card line editor, font scale,
-- progress-bar toggle, latest-walk depth, titlebar-meta toggle, About.
--
-- Public API: Settings:show()
-- All persisted keys use the bookshelf_* prefix.

local InfoMessage  = require("ui/widget/infomessage")
local Menu         = require("ui/widget/menu")
local SpinWidget   = require("ui/widget/spinwidget")
local UIManager    = require("ui/uimanager")
local _            = require("bookshelf_i18n").gettext

-- ─── Settings singleton ───────────────────────────────────────────────────────

local Settings = {}

-- ─── Toggle helpers ───────────────────────────────────────────────────────────

local function isTrue(key)
    return G_reader_settings:isTrue(key)
end

local function checkmark(key)
    -- Return nil (not "") for the off state so Menu omits the mandatory
    -- TextWidget rather than allocating an empty one (which would take
    -- space and misalign rows).
    if isTrue(key) then return "\xe2\x9c\x93" end
    return nil
end

-- ─── Sub-actions ──────────────────────────────────────────────────────────────

-- Token picker: opens a popout Menu listing the bookshelf-scoped token
-- catalogue (defined in tokens.lua). Each row inserts its token at the
-- cursor of the open `dialog` and dismisses the picker; the parent dialog
-- stays open so the user can continue editing.
-- Public entry point: try the bookends LibraryModal for a richer picker
-- when the bookends plugin is installed; otherwise fall back to a Menu.
function Settings:_pickToken(dialog)
    local ok, LibraryModal = pcall(require, "menu.library_modal")
    if ok and LibraryModal then
        return self:_pickTokenViaLibraryModal(LibraryModal, dialog)
    end
    return self:_pickTokenFallback(dialog)
end

-- Bookends-soft-dependency picker. Reuses bookends's LibraryModal shell
-- (chip strip, search, paginated list, footer actions) but feeds it OUR
-- bookshelf-scoped catalogue and renders rows with a live preview using
-- our own Tokens.expand. Bookends's TokensLibrary can't be reused
-- directly because its row renderer calls bookends's Tokens engine
-- (different signature), and its catalogue includes Reader-context
-- tokens we deliberately exclude.
function Settings:_pickTokenViaLibraryModal(LibraryModal, dialog)
    local Tokens          = require("bookshelf_tokens")
    local Font            = require("ui/font")
    local TextWidget      = require("ui/widget/textwidget")
    local VerticalGroup   = require("ui/widget/verticalgroup")
    local VerticalSpan    = require("ui/widget/verticalspan")
    local LeftContainer   = require("ui/widget/container/leftcontainer")
    local InputContainer  = require("ui/widget/container/inputcontainer")
    local FrameContainer  = require("ui/widget/container/framecontainer")
    local GestureRange    = require("ui/gesturerange")
    local Geom            = require("ui/geometry")
    local Size            = require("ui/size")
    local Blitbuffer      = require("ffi/blitbuffer")
    local Screen          = require("device").screen

    local CHIPS = {
        { key = "all",      label = _("All") },
        { key = "Book",     label = _("Book") },
        { key = "Progress", label = _("Progress") },
        { key = "Time",     label = _("Time") },
        { key = "Device",   label = _("Device") },
        { key = "Logic",    label = _("Logic") },
    }
    local active_chip = "all"
    local search_query

    local function items()
        local out = {}
        for _, t in ipairs(Tokens.CATALOGUE) do
            if active_chip == "all" or t.category == active_chip then
                if not search_query or #search_query < 2 then
                    out[#out + 1] = t
                else
                    local hay = ((t.description or "") .. " " .. (t.token or "")):lower()
                    local match = true
                    for term in search_query:lower():gmatch("%S+") do
                        if not hay:find(term, 1, true) then match = false; break end
                    end
                    if match then out[#out + 1] = t end
                end
            end
        end
        return out
    end

    -- Live-preview context: current hero book + device state from the
    -- BookshelfWidget instance the long-press handler stashed on us.
    -- enrichStats fills in book_time_left, book_read_time, book_pages_read,
    -- days_reading_book, pages_per_day, speed_pph — without it the stats
    -- tokens render empty even when readerstatistics is available.
    local preview_book, preview_state
    if self._bw then
        preview_book = self._bw._preview_book
        local ok_repo, Repo = pcall(require, "bookshelf_book_repository")
        if not preview_book and ok_repo and Repo and Repo.getCurrent then
            preview_book = Repo.getCurrent()
        end
        if preview_book and ok_repo and Repo and Repo.enrichStats then
            pcall(Repo.enrichStats, preview_book)
        end
        if self._bw._buildDeviceState then
            local ok_ds, ds = pcall(function() return self._bw:_buildDeviceState() end)
            if ok_ds then preview_state = ds end
        end
    end

    local modal
    modal = LibraryModal:new{
        config = {
            title = _("Insert token"),
            help_title = _("Bookshelf tokens"),
            help_text = _([==[Tokens are placeholders that get replaced with live data when the book detail view or status line renders.

  %title — %book_pct
  → Dune — 36%

Wrap content in [if:foo]…[/if] to show it only when the token has a value. Add [else]…[/if] for a fallback.

  [if:series]Book %series_num of %series_name[/if]
  [if:batt<20]LOW %batt[/if]]==]),
            chip_strip = function()
                local out = {}
                for _, c in ipairs(CHIPS) do
                    out[#out + 1] = { key = c.key, label = c.label, is_active = (c.key == active_chip) }
                end
                return out
            end,
            on_chip_tap = function(key)
                active_chip = key
                if search_query then
                    search_query = nil
                    if modal and modal._search_input then modal._search_input:setText("") end
                end
            end,
            search_placeholder = function() return _("Search tokens…") end,
            on_search_submit = function(query)
                search_query = query
                if query then active_chip = "all" end
            end,
            rows_per_page = function()
                local Screen = require("device").screen
                return Screen:getWidth() > Screen:getHeight() and 4 or 5
            end,
            item_count = function() return #items() end,
            item_at    = function(idx) return items()[idx] end,
            row_renderer = function(item, dimen)
                local inner_pad = Screen:scaleBySize(12)
                local content_w = dimen.w - 2 * inner_pad - 2 * Size.border.thin
                local preview = ""
                if preview_book and item.token and not item.token:match("^%[") then
                    local ok2, val = pcall(Tokens.expand, item.token, preview_book, preview_state)
                    if ok2 and val and val ~= "" and val ~= item.token then
                        if #val > 28 then val = val:sub(1, 27) .. "…" end
                        preview = "    \xe2\x86\x92 " .. val
                    end
                end
                local desc_w = TextWidget:new{
                    text = item.description or "",
                    face = Font:getFace("cfont", 16),
                    bold = true,
                    max_width = content_w,
                }
                local tok_w = TextWidget:new{
                    text = (item.token or "") .. preview,
                    face = Font:getFace("cfont", 13),
                    fgcolor = Blitbuffer.gray(0.4),
                    max_width = content_w,
                }
                local stack = VerticalGroup:new{
                    align = "left",
                    desc_w,
                    VerticalSpan:new{ width = Screen:scaleBySize(4) },
                    tok_w,
                }
                -- Card-style frame: thin border, rounded corners, white bg.
                -- Mirrors bookends's TokensLibrary._renderRow so the look
                -- matches when bookends is installed.
                local card_frame = FrameContainer:new{
                    bordersize     = Size.border.thin,
                    radius         = Size.radius.default,
                    padding        = 0,
                    padding_left   = inner_pad,
                    padding_right  = inner_pad,
                    padding_top    = 0,
                    padding_bottom = 0,
                    margin         = 0,
                    background     = Blitbuffer.COLOR_WHITE,
                    LeftContainer:new{
                        dimen = Geom:new{ w = content_w, h = dimen.h - 2 * Size.border.thin },
                        stack,
                    },
                }
                local row = InputContainer:new{
                    dimen = Geom:new{ w = dimen.w, h = dimen.h },
                    card_frame,
                }
                row.ges_events = {
                    TapSelect = { GestureRange:new{ ges = "tap", range = row.dimen } },
                }
                row.onTapSelect = function()
                    if modal then UIManager:close(modal); modal = nil end
                    if dialog and dialog.addTextToInput then
                        pcall(function() dialog:addTextToInput(item.token or "") end)
                    end
                    return true
                end
                return row
            end,
            footer_actions = {
                { key = "close", label = _("Close"), on_tap = function()
                    if modal then UIManager:close(modal); modal = nil end
                end },
                { key = "help", label = _("Help"), on_tap = function()
                    if modal then modal:_showHelp() end
                end },
            },
        },
    }
    UIManager:show(modal)
end

-- Fallback picker: simple Menu when bookends isn't installed. Centred via
-- UIManager:show offset so Menu's own onCloseAllMenus (which does
-- UIManager:close(self)) finds the Menu in the window stack and tap-outside
-- dismissal works.
function Settings:_pickTokenFallback(dialog)
    local Menu   = require("ui/widget/menu")
    local Screen = require("device").screen
    local Tokens = require("bookshelf_tokens")

    local menu
    local function pickAndClose(tok)
        if menu then UIManager:close(menu) end
        if dialog and dialog.addTextToInput then
            pcall(function() dialog:addTextToInput(tok) end)
        end
    end

    local items = {}
    local current_cat
    for _, t in ipairs(Tokens.CATALOGUE) do
        if t.category ~= current_cat then
            current_cat = t.category
            items[#items + 1] = {
                text           = "── " .. t.category .. " ──",
                bold           = true,
                select_enabled = false,
            }
        end
        local tok = t.token
        items[#items + 1] = {
            text     = tok .. "    " .. t.description,
            callback = function() pickAndClose(tok) end,
        }
    end

    local menu_w = math.floor(Screen:getWidth()  * 0.85)
    local menu_h = math.floor(Screen:getHeight() * 0.7)
    menu = Menu:new{
        title      = _("Insert token"),
        item_table = items,
        is_popout  = true,
        width      = menu_w,
        height     = menu_h,
    }
    -- Position the popout centred. Passing x/y to UIManager:show centres the
    -- menu in the window stack directly — Menu's own onCloseAllMenus calls
    -- UIManager:close(self), so the menu MUST be the registered widget for
    -- tap-outside dismissal to find it.
    local x = math.floor((Screen:getWidth()  - menu_w) / 2)
    local y = math.floor((Screen:getHeight() - menu_h) / 2)
    UIManager:show(menu, nil, nil, x, y)
end

-- Resolve the live preview book + device state used to render the row
-- previews in the chooser menu. Same fallback chain the token picker uses.
function Settings:_previewContext()
    local book, state
    if self._bw then
        book = self._bw._preview_book
        local ok_repo, Repo = pcall(require, "bookshelf_book_repository")
        if not book and ok_repo and Repo and Repo.getCurrent then
            book = Repo.getCurrent()
        end
        if book and ok_repo and Repo and Repo.enrichStats then
            pcall(Repo.enrichStats, book)
        end
        if self._bw._buildDeviceState then
            local ok_ds, ds = pcall(function() return self._bw:_buildDeviceState() end)
            if ok_ds then state = ds end
        end
    end
    return book, state
end

-- _heroSubItems() — sub_item_table_func payload for "Edit hero card".
-- Returns one entry per region with a checkbox showing enabled state and
-- a preview snippet showing how the region's template currently resolves.
-- Tap = open the line editor (chooser is hidden while editor is open).
-- Long-press = toggle enabled.
function Settings:_heroSubItems()
    local Regions = require("bookshelf_hero_regions")
    local Tokens  = require("bookshelf_tokens")
    local items = {
        {
            text      = _("Font scale"),
            callback  = function() self:_pickFontScale() end,
            separator = true,
        },
    }
    for _i, key in ipairs(Regions.ORDER) do
        items[#items + 1] = {
            keep_menu_open = true,
            text_func = function()
                local label    = _(Regions.LABELS[key] or key)
                local resolved = Regions.read()[key]
                local book, state = self:_previewContext()
                local preview = ""
                local ok, expanded = pcall(Tokens.expand,
                    resolved.template or "", book, state)
                if ok and expanded then
                    preview = expanded:gsub("%[/?[biu]%]", "")
                                      :gsub("%%bar", "")
                                      :gsub("%s+", " ")
                    preview = preview:match("^%s*(.-)%s*$") or ""
                end
                if preview == "" then return label end
                if #preview > 36 then preview = preview:sub(1, 35) .. "\xE2\x80\xA6" end
                return label .. ": " .. preview
            end,
            checked_func = function()
                local snap = Regions.snapshot(key)
                return not (snap and snap.disabled)
            end,
            callback = function(touchmenu_instance)
                self:_editHeroRegion(key, touchmenu_instance)
            end,
            hold_callback = function(touchmenu_instance)
                local snap = Regions.snapshot(key) or {}
                snap.disabled = not snap.disabled or nil
                Regions.write(key, next(snap) and snap or nil)
                if self._bw and self._bw._swapHeroRightColumnInPlace then
                    self._bw:_swapHeroRightColumnInPlace(Regions.read())
                end
                if touchmenu_instance and touchmenu_instance.updateItems then
                    touchmenu_instance:updateItems()
                end
            end,
        }
    end
    return items
end

-- _editHeroRegion(key, touchmenu_instance) — open the line editor for a
-- single region. Passes the FM TouchMenu through so the editor can hide
-- it while open and re-show it on Save/Cancel.
function Settings:_editHeroRegion(key, touchmenu_instance)
    local LineEditor = require("bookshelf_hero_line_editor")
    LineEditor.show(key, self._bw, self, touchmenu_instance)
end

-- Kept in sync with _DEFAULT_CHIPS_DISABLED in bookshelf_widget.lua. The
-- widget owns the rendering; this menu is the only writer of the
-- bookshelf_chips_disabled setting. Both files must agree on which chips
-- are off by default, otherwise the menu shows different state than the
-- chip strip.
local _DEFAULT_CHIPS_DISABLED = {
    latest = true, authors = true, genres = true, tags = true,
}
local function _readDisabledSet()
    local saved = G_reader_settings:readSetting("bookshelf_chips_disabled")
    if saved then return saved end
    -- Fresh install: clone the default so the caller can mutate without
    -- corrupting the module-level constant.
    local cloned = {}
    for k, v in pairs(_DEFAULT_CHIPS_DISABLED) do cloned[k] = v end
    return cloned
end

-- _chipsSubItems() — drill-down for "Edit shelf tabs". One row per
-- chip with a checkbox; tapping toggles the chip's disabled flag and
-- (if the bookshelf is live) rebuilds the strip.
function Settings:_chipsSubItems()
    local CHIP_ORDER  = {
        "all", "recent", "latest", "series", "authors", "genres",
        "tags", "favorites",
    }
    local CHIP_LABELS = {
        all       = _("Home"),
        recent    = _("Recent"),
        latest    = _("Latest"),
        series    = _("Series"),
        authors   = _("Authors"),
        genres    = _("Genres"),
        tags      = _("Tags"),
        favorites = _("Favourites"),
    }
    local items = {}
    for _i, key in ipairs(CHIP_ORDER) do
        items[#items + 1] = {
            text           = CHIP_LABELS[key],
            keep_menu_open = true,
            checked_func = function()
                -- Read-only: indexing is safe on the module-level default
                -- if no setting saved, since we never mutate here.
                local set = G_reader_settings:readSetting("bookshelf_chips_disabled")
                              or _DEFAULT_CHIPS_DISABLED
                return not set[key]
            end,
            callback = function(touchmenu_instance)
                local set = _readDisabledSet()
                if set[key] then set[key] = nil else set[key] = true end
                -- Persist the set even when empty: an explicit "everything
                -- enabled" choice must stick. Falling back to delSetting +
                -- defaults would silently re-disable the four default-off
                -- chips the user just turned on.
                G_reader_settings:saveSetting("bookshelf_chips_disabled", set)
                G_reader_settings:flush()
                if self._bw and self._bw._rebuild then
                    self._bw:_rebuild()
                    UIManager:setDirty(self._bw, "ui")
                end
                if touchmenu_instance and touchmenu_instance.updateItems then
                    touchmenu_instance:updateItems()
                end
            end,
        }
    end
    return items
end

-- ---------------------------------------------------------------------------
-- Progress indicators menu
-- ---------------------------------------------------------------------------

function Settings:_progressIndicatorsSubItems()
    local CoverProgress = require("bookshelf_cover_progress")
    local Colour        = require("bookshelf_colour")
    local Screen        = require("device").screen

    local function markDirty()
        if self._bw and self._bw._rebuild then
            self._bw:_rebuild()
            UIManager:setDirty(self._bw, "ui")
        end
    end

    local function valueLabel(field)
        local raw = CoverProgress.rawColours()[field]
        if not raw then return _("default") end
        if raw.hex then return raw.hex end
        if raw.grey then
            local pct = math.floor((0xFF - raw.grey) * 100 / 0xFF + 0.5)
            return pct .. "%"
        end
        return _("default")
    end

    -- Picker dispatch: palette on colour devices, % black nudge on greyscale.
    local function pickColour(field, default_pct, title, touchmenu_instance)
        local raw_key  = "bookshelf_progress_" .. field    -- "_fill" / "_track"
        local raw      = G_reader_settings:readSetting(raw_key)
        local original = raw

        if Screen:isColorEnabled() then
            local current_hex
            if raw and raw.hex then current_hex = raw.hex
            elseif raw and raw.grey then
                local g = string.format("%02X", raw.grey)
                current_hex = "#" .. g .. g .. g
            end
            self._plugin:showColourPicker(
                title, current_hex, Colour.defaultHexFor(field),
                function(new_hex)  -- on_apply
                    G_reader_settings:saveSetting(raw_key, Colour.toStorageShape(new_hex))
                    G_reader_settings:flush()
                    markDirty()
                end,
                function()  -- on_default
                    G_reader_settings:delSetting(raw_key)
                    G_reader_settings:flush()
                    markDirty()
                end,
                function()  -- on_revert
                    if original == nil then
                        G_reader_settings:delSetting(raw_key)
                    else
                        G_reader_settings:saveSetting(raw_key, original)
                    end
                    G_reader_settings:flush()
                    markDirty()
                end,
                touchmenu_instance)
            return
        end

        -- Greyscale: % black nudge dialog. Task 12 ensures self:showNudgeDialog exists.
        local byte
        if raw and raw.grey then byte = raw.grey end
        local current = byte and math.floor((0xFF - byte) * 100 / 0xFF + 0.5) or default_pct
        self:showNudgeDialog(title, current, 0, 100, default_pct, "%",
            function(val)
                G_reader_settings:saveSetting(raw_key, { grey = 0xFF - math.floor(val * 0xFF / 100 + 0.5) })
                G_reader_settings:flush()
                markDirty()
            end,
            nil, nil, nil, touchmenu_instance,
            function()
                G_reader_settings:delSetting(raw_key)
                G_reader_settings:flush()
                markDirty()
            end,
            _("Default"))
    end

    -- Three independent toggles (defaults all ON when unset). Inline the
    -- builder so each row reads/writes its own setting key without
    -- repetition.
    local function toggleRow(setting_key, label, separator)
        return {
            text = label,
            checked_func = function()
                local v = G_reader_settings:readSetting(setting_key)
                if v == nil then return true end
                return v == true
            end,
            callback = function()
                local v = G_reader_settings:readSetting(setting_key)
                if v == nil then v = true end
                G_reader_settings:saveSetting(setting_key, not v)
                G_reader_settings:flush()
                markDirty()
            end,
            separator = separator,
        }
    end
    return {
        toggleRow("bookshelf_progress_bookmark_enabled",
                  _("Show reading bookmarks"), false),
        toggleRow("bookshelf_progress_badge_enabled",
                  _("Show completed book badge"), false),
        toggleRow("bookshelf_show_series_num",
                  _("Show series #"), true),
        -- 'Show progress bars' sits with the colour rows so it's
        -- clear what 'Read color' / 'Unread color' apply to.
        toggleRow("bookshelf_progress_bar_enabled",
                  _("Show progress bars"), false),
        {
            text_func = function()
                return _("Read color") .. ": " .. valueLabel("fill")
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                pickColour("fill", 75, _("Read color (% black)"), touchmenu_instance)
            end,
            hold_callback = function(touchmenu_instance)
                G_reader_settings:delSetting("bookshelf_progress_fill")
                G_reader_settings:flush()
                markDirty()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        },
        {
            text_func = function()
                return _("Unread color") .. ": " .. valueLabel("track")
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                pickColour("track", 25, _("Unread color (% black)"), touchmenu_instance)
            end,
            hold_callback = function(touchmenu_instance)
                G_reader_settings:delSetting("bookshelf_progress_track")
                G_reader_settings:flush()
                markDirty()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        },
        {
            text = _("Reset colours to defaults"),
            separator = true,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                G_reader_settings:delSetting("bookshelf_progress_fill")
                G_reader_settings:delSetting("bookshelf_progress_track")
                G_reader_settings:flush()
                markDirty()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        },
    }
end

-- ---------------------------------------------------------------------------
-- Settings (parent) menu
-- ---------------------------------------------------------------------------

-- Cover-progress + Advanced settings live behind a single "Settings" entry
-- in the main bookshelf menu. Keeps the top level uncluttered while still
-- giving each surface its own sub-screen.
function Settings:_settingsSubItems()
    return {
        {
            text                = _("Cover progress indicators"),
            sub_item_table_func = function()
                return self:_progressIndicatorsSubItems()
            end,
        },
        {
            text                = _("Advanced settings"),
            sub_item_table_func = function()
                return self:_advancedSubItems()
            end,
        },
    }
end

-- Factored out from main.lua so it can be referenced via the new Settings
-- parent menu. Behaviour is identical to the previous inline definition.
function Settings:_advancedSubItems()
    local plugin = self._plugin
    return {
        {
            text     = _("Scan all library metadata"),
            callback = function(touchmenu_instance)
                if touchmenu_instance then
                    UIManager:close(touchmenu_instance)
                end
                UIManager:nextTick(function() plugin:scanAllMetadata() end)
            end,
        },
        {
            text     = _('"Latest" walk depth'),
            callback = function() self:_pickLatestDepth() end,
        },
        {
            text = _("Closing book notification"),
            help_text = _("Show a 'Closing book…' message in the centre "
                .. "of the screen while a book is being closed back to "
                .. "Bookshelf. The book-close work takes a moment, so "
                .. "the message confirms your gesture landed during the "
                .. "wait. Some users on colour e-ink panels see a brief "
                .. "flash from the message appearing. Turn it off here "
                .. "if you prefer no message and no flash."),
            checked_func   = function()
                return G_reader_settings:nilOrTrue("bookshelf_show_close_msg")
            end,
            keep_menu_open = true,
            callback = function()
                local enabled = G_reader_settings:nilOrTrue("bookshelf_show_close_msg")
                G_reader_settings:saveSetting("bookshelf_show_close_msg", not enabled)
                G_reader_settings:flush()
            end,
        },
        {
            text = _("BETA: Read calibre metadata.calibre"),
            help_text = _("For users with a Calibre-managed library. "
                .. "Reads the metadata.calibre JSON file at home_dir to "
                .. "cover title / authors / series / tags / language for "
                .. "every book in the library — no per-book extraction "
                .. "needed. BIM-cached metadata still wins per field; "
                .. "Calibre data only fills gaps."),
            checked_func   = function()
                return G_reader_settings:readSetting("bookshelf_calibre_metadata") == true
            end,
            keep_menu_open = true,
            callback = function()
                local enabled = G_reader_settings:readSetting("bookshelf_calibre_metadata") == true
                G_reader_settings:saveSetting("bookshelf_calibre_metadata", not enabled)
                G_reader_settings:flush()
                local ok, Repo = pcall(require, "bookshelf_book_repository")
                if ok and Repo and Repo.invalidateWalkCache then
                    Repo.invalidateWalkCache()
                end
                if self._bw and self._bw._rebuild then
                    self._bw:_rebuild()
                    UIManager:setDirty(self._bw, "ui")
                end
            end,
        },
    }
end

--- @param extra_button table|nil  Optional shortcut button rendered between
---   Default and Apply, shape `{ text = string, value = number }`. When tapped,
---   the dialog sets `value` to the supplied number, fires on_change, then
---   closes -- matching the one-tap-commit feel of the colour picker's White
---   shortcut on the greyscale nudge for background_color.
function Settings:showNudgeDialog(title, value, min_val, max_val, default_val, unit, on_change, on_close, small_step, large_step, touchmenu_instance, on_default, default_label, extra_button)
    local ButtonDialog = require("ui/widget/buttondialog")
    local restoreMenu = self._plugin:hideMenu(touchmenu_instance)
    local orig_on_close = on_close
    on_close = function()
        restoreMenu()
        if orig_on_close then orig_on_close() end
    end
    local dialog
    local original_value = value
    small_step = small_step or 1
    if large_step == nil then large_step = 10 end

    local function update(delta)
        value = math.max(min_val, math.min(max_val, value + delta))
        on_change(value)
        dialog:reinit()
    end

    local nudge_buttons = {}
    if large_step then
        table.insert(nudge_buttons, { text = "-" .. large_step, callback = function() update(-large_step) end })
    end
    table.insert(nudge_buttons, { text = "-" .. small_step, callback = function() update(-small_step) end })
    table.insert(nudge_buttons, { text_func = function() return tostring(value) .. unit end, enabled = false })
    table.insert(nudge_buttons, { text = "+" .. small_step, callback = function() update(small_step) end })
    if large_step then
        table.insert(nudge_buttons, { text = "+" .. large_step, callback = function() update(large_step) end })
    end

    dialog = ButtonDialog:new{
        dismissable = false,
        title = title .. ": " .. value .. unit,
        tap_close_callback = function()
            if value ~= original_value then
                value = original_value
                on_change(value)
            end
            if on_close then on_close() end
        end,
        buttons = (function()
            local footer = {
                {
                    text = _("Cancel"),
                    callback = function()
                        if value ~= original_value then
                            value = original_value
                            on_change(value)
                        end
                        UIManager:close(dialog)
                        if on_close then on_close() end
                    end,
                },
                { text = default_label or (_("Default") .. " " .. default_val .. unit), callback = function()
                    if on_default then
                        on_default()
                        UIManager:close(dialog)
                        if on_close then on_close() end
                    else
                        value = default_val; on_change(value); dialog:reinit()
                    end
                end },
            }
            if extra_button then
                table.insert(footer, {
                    text = extra_button.text,
                    callback = function()
                        value = extra_button.value
                        on_change(value)
                        UIManager:close(dialog)
                        if on_close then on_close() end
                    end,
                })
            end
            table.insert(footer, {
                text = _("Apply"),
                is_enter_default = true,
                callback = function()
                    UIManager:close(dialog)
                    if on_close then on_close() end
                end,
            })
            return { nudge_buttons, footer }
        end)(),
    }
    UIManager:show(dialog)
end

-- Bookends-style nudge dialog for the hero font scale. Each tap on -/+ saves
-- the new scale, kicks the live BookshelfWidget rebuild, and refreshes the
-- dialog so the value updates. Cancel reverts to the snapshot taken on open;
-- Default resets to 100; Apply commits and closes.
function Settings:_pickFontScale()
    local ButtonDialog = require("ui/widget/buttondialog")
    local key = "bookshelf_font_scale"
    local original = G_reader_settings:readSetting(key) or 100

    local function getValue() return G_reader_settings:readSetting(key) or 100 end
    local function setValue(v)
        v = math.max(50, math.min(200, v))
        G_reader_settings:saveSetting(key, v)
        G_reader_settings:flush()
    end
    local function rebuild()
        if Settings._bw and Settings._bw._rebuild then
            Settings._bw:_rebuild()
            UIManager:setDirty(Settings._bw, "ui")
        end
    end

    local dialog
    local function nudge(delta)
        setValue(getValue() + delta)
        rebuild()
        dialog:reinit()
    end
    local function close()
        UIManager:close(dialog)
    end
    local function revert()
        setValue(original)
        rebuild()
    end

    dialog = ButtonDialog:new{
        title = _("Book detail font scale"),
        buttons = {
            {
                { text = "-10",  callback = function() nudge(-10) end },
                { text = "-5",   callback = function() nudge(-5)  end },
                { text_func = function() return tostring(getValue()) .. "%" end,
                  enabled = false },
                { text = "+5",   callback = function() nudge(5)   end },
                { text = "+10",  callback = function() nudge(10)  end },
            },
            {
                { text = _("Cancel"), callback = function() revert(); close() end },
                { text = _("Default"),
                  callback = function() setValue(100); rebuild(); dialog:reinit() end },
                { text = _("Apply"), is_enter_default = true, callback = close },
            },
        },
        tap_close_callback = revert,
    }
    UIManager:show(dialog)
end

function Settings:_pickLatestDepth()
    local current = G_reader_settings:readSetting("bookshelf_latest_walk_depth") or 3
    UIManager:show(SpinWidget:new{
        value      = current,
        value_min  = 1,
        value_max  = 99,
        value_step = 1,
        title_text = _("\"Latest\" folder walk depth"),
        info_text  = _("How deep to scan your library folder for newly-added books."
                        .. " Higher values take longer on a cold start."),
        callback   = function(spin)
            G_reader_settings:saveSetting("bookshelf_latest_walk_depth", spin.value)
            G_reader_settings:flush()
        end,
    })
end

function Settings:_about()
    -- Load our own _meta.lua by absolute path. `require("_meta")` is
    -- ambiguous because every koplugin has a _meta and they all collide
    -- in package.path — whichever plugin loaded first wins, so the about
    -- box was showing some OTHER plugin's metadata.
    local plugin_dir = debug.getinfo(1, "S").source:match("@(.*/)")
    local meta
    if plugin_dir then
        local ok, m = pcall(dofile, plugin_dir .. "_meta.lua")
        if ok then meta = m end
    end
    local name    = (meta and meta.fullname)    or "Bookshelf"
    local version = (meta and meta.version)     or "0.1.0"
    local desc    = (meta and meta.description) or ""
    UIManager:show(InfoMessage:new{
        text = string.format("%s  v%s\n\n%s", name, version, desc),
    })
end

-- _updateSubItems() — drill-down menu for the in-app updater. Mirrors
-- bookends's structure: a "Notify" toggle, a primary update row that
-- auto-relabels when an update is queued, and an "Advanced" pocket for
-- the dev-branch picker + reset-to-stable.
function Settings:_updateSubItems()
    local Updater = require("bookshelf_updater")
    local plugin = self._plugin   -- the Bookshelf plugin instance
    return {
        {
            text         = _("Notify on wake when update available"),
            checked_func = function() return plugin and plugin.check_updates end,
            callback     = function()
                if not plugin then return end
                plugin.check_updates = not plugin.check_updates
                G_reader_settings:saveSetting("bookshelf_check_updates", plugin.check_updates)
                G_reader_settings:flush()
            end,
        },
        {
            text_func = function()
                local current   = Updater.getInstalledVersion()
                local available = Updater.getAvailableUpdate()
                local source    = (plugin and plugin.last_install_source) or "release"
                local source_suffix = ""
                if source ~= "release" then
                    local branch = source:match("^branch:(.+)$") or source
                    source_suffix = " (branch: " .. branch .. ")"
                end
                if available then
                    return _("Update available") .. ": v" .. current .. source_suffix
                        .. " \xE2\x86\x92 v" .. available
                end
                return _("Installed version") .. ": v" .. current .. source_suffix
            end,
            keep_menu_open = true,
            callback = function() if plugin then plugin:checkForUpdates() end end,
        },
        {
            text = _("Developer updates"),
            sub_item_table = {
                {
                    text_func = function()
                        local b = (plugin and plugin.dev_branch) or ""
                        if b == "" then return _("Development branch") end
                        return _("Development branch") .. ": " .. b
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        if plugin then plugin:editDevBranch(touchmenu_instance) end
                    end,
                },
                {
                    text_func = function()
                        local b = (plugin and plugin.dev_branch) or ""
                        if b == "" then return _("Check for updates") end
                        return _("Install branch") .. ": " .. b
                    end,
                    keep_menu_open = true,
                    callback = function() if plugin then plugin:checkForUpdates() end end,
                },
                {
                    text           = _("Reset to latest stable release"),
                    keep_menu_open = true,
                    callback       = function() if plugin then plugin:resetToStableRelease() end end,
                },
                {
                    -- Disabled status row: shows "Installed: vX (release)" /
                    -- "(branch: foo)". Tap is a no-op via enabled_func=false.
                    text_func = function()
                        local current = Updater.getInstalledVersion()
                        local source  = (plugin and plugin.last_install_source) or "release"
                        if source == "release" then
                            return _("Installed: v") .. current .. " (release)"
                        end
                        local branch = source:match("^branch:(.+)$") or source
                        return _("Installed: v") .. current .. " (branch: " .. branch .. ")"
                    end,
                    enabled_func   = function() return false end,
                    keep_menu_open = true,
                },
            },
        },
    }
end

return Settings
