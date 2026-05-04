-- settings.lua
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
    local Tokens          = require("tokens")
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
        local ok_repo, Repo = pcall(require, "book_repository")
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
            help_text = _([==[Tokens are placeholders that get replaced with live data when the hero card or status line renders.

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
    local Tokens = require("tokens")

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

-- _pickHeroRegion() — opens a 5-row modal listing the editable hero regions.
-- Tapping a row delegates to hero_line_editor for that region.
function Settings:_pickHeroRegion()
    local Regions = require("hero_regions")
    local Screen  = require("device").screen
    local items = {}
    for _, key in ipairs(Regions.ORDER) do
        items[#items + 1] = {
            text     = _(Regions.LABELS[key] or key),
            callback = function()
                if self._region_chooser then
                    UIManager:close(self._region_chooser)
                    self._region_chooser = nil
                end
                self:_editHeroRegion(key)
            end,
        }
    end
    local menu_w = math.floor(Screen:getWidth()  * 0.7)
    local menu_h = math.floor(Screen:getHeight() * 0.5)
    self._region_chooser = Menu:new{
        title      = _("Edit hero card"),
        item_table = items,
        is_popout  = true,
        width      = menu_w,
        height     = menu_h,
    }
    local x = math.floor((Screen:getWidth()  - menu_w) / 2)
    local y = math.floor((Screen:getHeight() - menu_h) / 2)
    UIManager:show(self._region_chooser, nil, nil, x, y)
end

-- _editHeroRegion(key) — open the line editor for a single region. The
-- editor lives in hero_line_editor; settings just supplies the live
-- BookshelfWidget handle so the editor can repaint the hero on edits.
function Settings:_editHeroRegion(key)
    local LineEditor = require("hero_line_editor")
    LineEditor.show(key, self._bw, self)
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
        title = _("Hero card font scale"),
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

-- ─── Main settings menu ───────────────────────────────────────────────────────

-- Settings:show()
-- Opens the settings menu as a popout modal.  Toggle items show "✓" on the
-- right when enabled (via mandatory_func).  After toggling, the menu is
-- re-opened so the user can see the updated state.
-- show(bw)
-- bw (optional) is the live BookshelfWidget instance, stashed on the
-- Settings module so the font-scale nudge dialog can call _rebuild on it
-- for live preview. Long-press handlers in bookshelf_widget.lua pass `self`.
-- Returns the Bookshelf settings as a KOReader sub_item_table. main.lua
-- consumes this to nest the settings under the FM menu's folder/file tab.
-- Optional `bw` lets the nudge dialog reach the live BookshelfWidget for
-- font-scale preview rebuilds.
function Settings:menuItems(bw)
    if bw then self._bw = bw end
    return {
        {
            text     = _("Edit hero card\xE2\x80\xA6"),  -- ellipsis
            callback = function() self:_pickHeroRegion() end,
        },
        {
            text     = _("Hero card font scale"),
            callback = function() self:_pickFontScale() end,
        },
        {
            text     = _("\"Latest\" walk depth"),
            callback = function() self:_pickLatestDepth() end,
        },
        {
            text     = _("About"),
            callback = function() self:_about() end,
            separator = true,
        },
    }
end

-- show(bw) — back-compat shim for any caller that still uses the old API
-- (the main-menu now feeds menuItems() directly). Opens the FM menu so
-- the user can navigate to the Bookshelf submenu.
function Settings:show(bw)
    if bw then self._bw = bw end
    local FileManager = require("apps/filemanager/filemanager")
    if FileManager and FileManager.instance and FileManager.instance.menu then
        FileManager.instance.menu:onShowMenu()
    end
end

return Settings
