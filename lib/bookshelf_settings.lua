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
local _            = require("lib/bookshelf_i18n").gettext

local BookshelfSettings = require("lib/bookshelf_settings_store")

-- ─── Settings singleton ───────────────────────────────────────────────────────

local Settings = {}

-- ─── Toggle helpers ───────────────────────────────────────────────────────────

local function isTrue(key)
    return BookshelfSettings.isTrue(key)
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
    local Tokens          = require("lib/bookshelf_tokens")
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
        for _i, t in ipairs(Tokens.CATALOGUE) do
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
        local ok_repo, Repo = pcall(require, "lib/bookshelf_book_repository")
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
                for _i, c in ipairs(CHIPS) do
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
    local Tokens = require("lib/bookshelf_tokens")

    local menu
    local function pickAndClose(tok)
        if menu then UIManager:close(menu) end
        if dialog and dialog.addTextToInput then
            pcall(function() dialog:addTextToInput(tok) end)
        end
    end

    local items = {}
    local current_cat
    for _i, t in ipairs(Tokens.CATALOGUE) do
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
        local ok_repo, Repo = pcall(require, "lib/bookshelf_book_repository")
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
    local Regions = require("lib/bookshelf_hero_regions")
    local Tokens  = require("lib/bookshelf_tokens")
    local items = {
        {
            text      = _("Font scale"),
            callback  = function() self:_pickFontScale() end,
            separator = true,
        },
    }
    -- Translation extraction markers: Regions.LABELS values reach the
    -- runtime via the _(Regions.LABELS[key]) dynamic lookup below, which
    -- xgettext cannot follow. Most labels ("Status line", "Title", ...)
    -- pick up translations because the same string appears in a direct
    -- _() call elsewhere, but "Rating (interactive)" is unique to this
    -- surface. Listing it here is dead code at runtime but lets xgettext
    -- emit the msgid so translators see it.
    if false then
        local _ignore = { _("Rating (interactive)") }
    end
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
                -- Read RESOLVED state, not raw snapshot: rating's default is
                -- disabled=true, so an absent snapshot still means disabled.
                return not Regions.read()[key].disabled
            end,
            callback = function(touchmenu_instance)
                -- Rating is interactive in the hero (tap stars to set/clear),
                -- not text-templated -- a line editor for it is meaningless.
                -- Tap on this row toggles enabled, same as hold elsewhere.
                if key == "rating" then
                    self:_toggleRegionEnabled(key, touchmenu_instance)
                    return
                end
                self:_editHeroRegion(key, touchmenu_instance)
            end,
            hold_callback = function(touchmenu_instance)
                self:_toggleRegionEnabled(key, touchmenu_instance)
            end,
        }
    end
    return items
end

-- _editHeroRegion(key, touchmenu_instance) — open the line editor for a
-- single region. Passes the FM TouchMenu through so the editor can hide
-- it while open and re-show it on Save/Cancel.
function Settings:_editHeroRegion(key, touchmenu_instance)
    local LineEditor = require("lib/bookshelf_hero_line_editor")
    LineEditor.show(key, self._bw, self, touchmenu_instance)
end

-- Flip a region's enabled flag, writing the EXPLICIT new value rather
-- than relying on absence-equals-default. Critical for rating, whose
-- default is disabled=true: without an explicit false override, the
-- resolved value stays true regardless of how many times the user taps.
function Settings:_toggleRegionEnabled(key, touchmenu_instance)
    local Regions = require("lib/bookshelf_hero_regions")
    local now_disabled = Regions.read()[key].disabled == true
    local snap = Regions.snapshot(key) or {}
    snap.disabled = not now_disabled  -- explicit true / false
    Regions.write(key, snap)
    if self._bw and self._bw._swapHeroRightColumnInPlace then
        self._bw:_swapHeroRightColumnInPlace(Regions.read())
    end
    if touchmenu_instance and touchmenu_instance.updateItems then
        touchmenu_instance:updateItems()
    end
end

-- ---------------------------------------------------------------------------
-- Progress indicators menu
-- ---------------------------------------------------------------------------

function Settings:_coverDisplaySubItems()
    local function markDirty()
        if self._bw and self._bw._rebuild then
            self._bw:_rebuild()
            UIManager:setDirty(self._bw, "ui")
        end
    end

    -- Three independent toggles (defaults all ON when unset). Inline the
    -- builder so each row reads/writes its own setting key without
    -- repetition.
    -- default_off: when true, treats nil as false. Used for opt-in
    -- toggles like Show page count where defaulting ON would be
    -- intrusive for users upgrading from a prior version.
    local function toggleRow(setting_key, label, separator, default_off)
        local default_value = not default_off  -- true unless explicitly off
        return {
            text = label,
            checked_func = function()
                local v = BookshelfSettings.read(setting_key)
                if v == nil then return default_value end
                return v == true
            end,
            callback = function()
                local v = BookshelfSettings.read(setting_key)
                if v == nil then v = default_value end
                BookshelfSettings.save(setting_key, not v)
                markDirty()
            end,
            separator = separator,
        }
    end
    return {
        toggleRow("progress_bookmark_enabled",
                  _("Show reading bookmarks"), false),
        -- Completed book badge: three-state. "bookmark" (default;
        -- pre-v2.1 dangling outlined check), "tickbox" (v2.1 square
        -- pill), "none". Legacy boolean progress_badge_enabled still
        -- honoured as a fallback when progress_badge_style is unset:
        -- true / nil -> bookmark, false -> none. cover_progress.decide()
        -- runs the same migration so the rendering side and the menu
        -- agree.
        (function()
            local function readMode()
                local v = BookshelfSettings.read("progress_badge_style")
                if v == "tickbox" or v == "bookmark" or v == "none" then
                    return v
                end
                local legacy = BookshelfSettings.read("progress_badge_enabled")
                if legacy == false then return "none" end
                return "bookmark"
            end
            local function setMode(mode, touchmenu_instance)
                BookshelfSettings.save("progress_badge_style", mode)
                markDirty()
                if touchmenu_instance and touchmenu_instance.updateItems then
                    touchmenu_instance:updateItems()
                end
            end
            local labels = {
                none     = _("None"),
                bookmark = _("Bookmark style"),
                tickbox  = _("Small tick box"),
            }
            local function optionRow(mode, label)
                return {
                    text           = label,
                    checked_func   = function() return readMode() == mode end,
                    radio          = true,
                    keep_menu_open = true,
                    callback       = function(touchmenu_instance)
                        setMode(mode, touchmenu_instance)
                    end,
                }
            end
            return {
                text_func = function()
                    return _("Completed book badge") .. ": " .. labels[readMode()]
                end,
                sub_item_table_func = function()
                    return {
                        optionRow("none",     labels.none),
                        optionRow("bookmark", labels.bookmark),
                        optionRow("tickbox",  labels.tickbox),
                    }
                end,
            }
        end)(),
        -- Show series #: three-state. "always" (default), "in_series"
        -- (only inside a single-series view), or "never". Legacy boolean
        -- values are still honoured: true reads as "always", false as
        -- "never", so existing user settings keep working without a
        -- migration. The sub-menu re-renders both itself and the live
        -- shelf on every selection so the change is immediately visible.
        (function()
            local function readMode()
                local v = BookshelfSettings.read("show_series_num")
                if v == nil or v == true or v == "always" then return "always" end
                if v == "in_series"                       then return "in_series" end
                return "never"
            end
            local function setMode(mode, touchmenu_instance)
                BookshelfSettings.save("show_series_num", mode)
                markDirty()
                if touchmenu_instance and touchmenu_instance.updateItems then
                    touchmenu_instance:updateItems()
                end
            end
            local labels = {
                always    = _("Always"),
                in_series = _("Within series folder"),
                never     = _("Never"),
            }
            local function optionRow(mode, label)
                return {
                    text           = label,
                    checked_func   = function() return readMode() == mode end,
                    radio          = true,
                    keep_menu_open = true,
                    callback       = function(touchmenu_instance)
                        setMode(mode, touchmenu_instance)
                    end,
                }
            end
            return {
                text_func = function()
                    return _("Show series #") .. ": " .. labels[readMode()]
                end,
                separator = true,
                sub_item_table_func = function()
                    return {
                        optionRow("always",    labels.always),
                        optionRow("in_series", labels.in_series),
                        optionRow("never",     labels.never),
                    }
                end,
            }
        end)(),
        -- Stack count badge mode: four-state. Decides whether the
        -- "×N" / "K/N" count badge renders on (a) filesystem folder
        -- cards, (b) group stacks (series/author/genre/tag/format/
        -- rating), (c) both, or (d) neither. Default "groups"
        -- preserves the pre-v2.2.2 behaviour where only group stacks
        -- carried the badge. Folder badges added in v2.2.2 are an
        -- opt-in for users who want at-a-glance counts on file
        -- folders too.
        (function()
            local function readMode()
                local v = BookshelfSettings.read("stack_count_badge_mode")
                if v == "off" or v == "folders" or v == "groups" or v == "all" then
                    return v
                end
                return "groups"
            end
            local function setMode(mode, touchmenu_instance)
                BookshelfSettings.save("stack_count_badge_mode", mode)
                markDirty()
                if touchmenu_instance and touchmenu_instance.updateItems then
                    touchmenu_instance:updateItems()
                end
            end
            local labels = {
                off     = _("Off"),
                folders = _("Folders only"),
                groups  = _("Groups only"),
                all     = _("All stacks"),
            }
            local function optionRow(mode, label)
                return {
                    text           = label,
                    checked_func   = function() return readMode() == mode end,
                    radio          = true,
                    keep_menu_open = true,
                    callback       = function(touchmenu_instance)
                        setMode(mode, touchmenu_instance)
                    end,
                }
            end
            return {
                text_func = function()
                    return _("Stack count badge") .. ": " .. labels[readMode()]
                end,
                sub_item_table_func = function()
                    return {
                        optionRow("off",     labels.off),
                        optionRow("folders", labels.folders),
                        optionRow("groups",  labels.groups),
                        optionRow("all",     labels.all),
                    }
                end,
            }
        end)(),
        -- Stack count format: when the badge is shown, choose what the
        -- numerator counts outside of selection mode. "total" (default)
        -- → "×N"; "finished_total" → "F/N" where F is the count of
        -- books in the stack marked finished. In selection mode the
        -- partial-overlap "K/N" still wins regardless of this setting.
        (function()
            local function readMode()
                local v = BookshelfSettings.read("stack_count_badge_format")
                if v == "total" or v == "finished_total" then return v end
                return "total"
            end
            local function setMode(mode, touchmenu_instance)
                BookshelfSettings.save("stack_count_badge_format", mode)
                markDirty()
                if touchmenu_instance and touchmenu_instance.updateItems then
                    touchmenu_instance:updateItems()
                end
            end
            local labels = {
                total          = _("Total"),
                finished_total = _("Finished / Total"),
            }
            local function optionRow(mode, label)
                return {
                    text           = label,
                    checked_func   = function() return readMode() == mode end,
                    radio          = true,
                    keep_menu_open = true,
                    callback       = function(touchmenu_instance)
                        setMode(mode, touchmenu_instance)
                    end,
                }
            end
            return {
                text_func = function()
                    return _("Stack count format") .. ": " .. labels[readMode()]
                end,
                sub_item_table_func = function()
                    return {
                        optionRow("total",          labels.total),
                        optionRow("finished_total", labels.finished_total),
                    }
                end,
            }
        end)(),
        toggleRow("progress_bar_enabled",
                  _("Show progress bars"), false),
        -- Page count: defaults off so existing users aren't surprised
        -- by an extra element appearing on every cover after upgrade.
        toggleRow("progress_page_count_enabled",
                  _("Show page count"), true, true),
        {
            text_func = function()
                local v = BookshelfSettings.read("cover_badge_font_scale", 100)
                return _("Badge font scale") .. ": " .. tostring(v) .. "%"
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:_pickCoverBadgeFontScale(touchmenu_instance)
            end,
        },
    }
end

-- Colours sub-menu: progress-bar Read / Unread colours today;
-- folder colour, cover badge colour, progress bookmark colour all
-- expected to land here as they ship. Greyscale devices get a
-- nudge dialog (% black); colour devices get the palette picker.
function Settings:_coloursSubItems()
    local CoverProgress = require("lib/bookshelf_cover_progress")
    local Colour        = require("lib/bookshelf_colour")
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

    local function pickColour(field, default_pct, title, touchmenu_instance)
        local raw_key  = "progress_" .. field
        local raw      = BookshelfSettings.read(raw_key)
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
                function(new_hex)
                    BookshelfSettings.save(raw_key, Colour.toStorageShape(new_hex))
                    markDirty()
                end,
                function()
                    BookshelfSettings.delete(raw_key)
                    markDirty()
                end,
                function()
                    if original == nil then
                        BookshelfSettings.delete(raw_key)
                    else
                        BookshelfSettings.save(raw_key, original)
                    end
                    markDirty()
                end,
                touchmenu_instance)
            return
        end

        local byte
        if raw and raw.grey then byte = raw.grey end
        local current = byte and math.floor((0xFF - byte) * 100 / 0xFF + 0.5) or default_pct
        self:showNudgeDialog(title, current, 0, 100, default_pct, "%",
            function(val)
                BookshelfSettings.save(raw_key, { grey = 0xFF - math.floor(val * 0xFF / 100 + 0.5) })
                markDirty()
            end,
            nil, nil, nil, touchmenu_instance,
            function()
                BookshelfSettings.delete(raw_key)
                markDirty()
            end,
            _("Default"))
    end

    return {
        {
            text_func = function()
                return _("Progress bar") .. ": " .. valueLabel("fill")
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                pickColour("fill", 75, _("Progress bar (% black)"), touchmenu_instance)
            end,
            hold_callback = function(touchmenu_instance)
                BookshelfSettings.delete("progress_fill")
                markDirty()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        },
        {
            text_func = function()
                return _("Progress bar track") .. ": " .. valueLabel("track")
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                pickColour("track", 25, _("Progress bar track (% black)"), touchmenu_instance)
            end,
            hold_callback = function(touchmenu_instance)
                BookshelfSettings.delete("progress_track")
                markDirty()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        },
        {
            text = _("Reset to default colours"),
            separator = true,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                BookshelfSettings.delete("progress_fill")
                BookshelfSettings.delete("progress_track")
                markDirty()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        },
    }
end

-- Nudge dialog for the cover-badge font scale (series #, stack count,
-- page count, completed-tick). Same shape as _pickFontScale /
-- _pickChipFontScale; +5/+10 steps so the small badge changes by a
-- noticeable amount per tap without overshooting.
function Settings:_pickCoverBadgeFontScale(touchmenu_instance)
    local ButtonDialog = require("ui/widget/buttondialog")
    local key = "cover_badge_font_scale"
    local original = BookshelfSettings.read(key, 100)

    local function getValue() return BookshelfSettings.read(key, 100) end
    local function setValue(v)
        v = math.max(50, math.min(200, v))
        BookshelfSettings.save(key, v)
    end
    local function rebuild()
        if self._bw and self._bw._rebuild then
            self._bw:_rebuild()
            UIManager:setDirty(self._bw, "ui")
        end
        if touchmenu_instance and touchmenu_instance.updateItems then
            touchmenu_instance:updateItems()
        end
    end

    local dialog
    local function nudge(delta)
        setValue(getValue() + delta)
        rebuild()
        dialog:reinit()
    end
    local function close() UIManager:close(dialog) end
    local function revert() setValue(original); rebuild() end

    dialog = ButtonDialog:new{
        title = _("Badge font scale"),
        buttons = {
            {
                { text = "-10", callback = function() nudge(-10) end },
                { text = "-5",  callback = function() nudge(-5)  end },
                { text_func = function() return tostring(getValue()) .. "%" end,
                  enabled = false },
                { text = "+5",  callback = function() nudge(5)   end },
                { text = "+10", callback = function() nudge(10)  end },
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

-- ---------------------------------------------------------------------------
-- Settings (parent) menu
-- ---------------------------------------------------------------------------

-- Cover-progress + Advanced settings live behind a single "Settings" entry
-- in the main bookshelf menu. Keeps the top level uncluttered while still
-- giving each surface its own sub-screen.
function Settings:_settingsSubItems()
    return {
        {
            text                = _("Cover display"),
            sub_item_table_func = function()
                return self:_coverDisplaySubItems()
            end,
        },
        {
            text                = _("Colours"),
            sub_item_table_func = function()
                return self:_coloursSubItems()
            end,
        },
        {
            text                = _("Expanded shelf"),
            sub_item_table_func = function()
                return self:_expandedShelfSubItems()
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

-- Expanded-shelf settings sub-menu. "Expanded shelf" is the mode where
-- the hero card is hidden and the book grid fills the screen, with a
-- thin label strip below each cover. The label content is configurable
-- here.
function Settings:_expandedShelfSubItems()
    -- Local markDirty mirrors the helper in _coverDisplaySubItems
    -- (line ~415). Lifting it to a method on Settings would be the
    -- cleaner long-term move but stays out of scope for this change.
    local function markDirty()
        if self._bw and self._bw._rebuild then
            self._bw:_rebuild()
            UIManager:setDirty(self._bw, "ui")
        end
    end
    local function readMode()
        local v = BookshelfSettings.read("expanded_shelf_label")
        if v == "title" or v == "author" or v == "series" or v == "none" then
            return v
        end
        return "title"
    end
    local function setMode(mode, touchmenu_instance)
        BookshelfSettings.save("expanded_shelf_label", mode)
        markDirty()
        if touchmenu_instance and touchmenu_instance.updateItems then
            touchmenu_instance:updateItems()
        end
    end
    local labels = {
        title  = _("Title"),
        author = _("Author"),
        series = _("Series"),
        none   = _("None"),
    }
    local function optionRow(mode, label)
        return {
            text           = label,
            checked_func   = function() return readMode() == mode end,
            radio          = true,
            keep_menu_open = true,
            callback       = function(touchmenu_instance)
                setMode(mode, touchmenu_instance)
            end,
        }
    end
    return {
        {
            text_func = function()
                return _("Show text below covers") .. ": " .. labels[readMode()]
            end,
            sub_item_table_func = function()
                return {
                    optionRow("title",  labels.title),
                    optionRow("author", labels.author),
                    optionRow("series", labels.series),
                    optionRow("none",   labels.none),
                }
            end,
        },
        {
            text_func = function()
                local v = BookshelfSettings.read("expanded_shelf_font_scale", 100)
                return _("Font scale") .. ": " .. tostring(v) .. "%"
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:_pickExpandedShelfFontScale(touchmenu_instance)
            end,
        },
    }
end

-- Nudge dialog for the expanded-shelf label font scale. Same shape as
-- _pickFontScale; live preview kicks the live widget's _rebuild.
function Settings:_pickExpandedShelfFontScale(touchmenu_instance)
    local ButtonDialog = require("ui/widget/buttondialog")
    local key = "expanded_shelf_font_scale"
    local original = BookshelfSettings.read(key, 100)

    local function getValue() return BookshelfSettings.read(key, 100) end
    local function setValue(v)
        v = math.max(50, math.min(300, v))
        BookshelfSettings.save(key, v)
    end
    local function rebuild()
        if self._bw and self._bw._rebuild then
            self._bw:_rebuild()
            UIManager:setDirty(self._bw, "ui")
        end
        if touchmenu_instance and touchmenu_instance.updateItems then
            touchmenu_instance:updateItems()
        end
    end

    local dialog
    local function nudge(delta)
        setValue(getValue() + delta)
        rebuild()
        dialog:reinit()
    end
    local function close() UIManager:close(dialog) end
    local function revert() setValue(original); rebuild() end

    dialog = ButtonDialog:new{
        title = _("Expanded shelf font scale"),
        buttons = {
            {
                { text = "-10", callback = function() nudge(-10) end },
                { text = "-5",  callback = function() nudge(-5)  end },
                { text_func = function() return tostring(getValue()) .. "%" end,
                  enabled = false },
                { text = "+5",  callback = function() nudge(5)   end },
                { text = "+10", callback = function() nudge(10)  end },
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
                return BookshelfSettings.nilOrTrue("show_close_msg")
            end,
            keep_menu_open = true,
            callback = function()
                local enabled = BookshelfSettings.nilOrTrue("show_close_msg")
                BookshelfSettings.save("show_close_msg", not enabled)
            end,
        },
        {
            text     = _("Reset chip bar to defaults"),
            help_text = _("Clears your custom chip layout (which chips are "
                .. "shown, their order, their labels and icons, their "
                .. "sources and filters and sorts) and restores the "
                .. "fresh-install chip set: Home / Recent / Series / "
                .. "Favourites enabled, the rest available to toggle on. "
                .. "Also returns the active chip to Home and the page "
                .. "indicator to 1. Other settings (hero text, fonts, "
                .. "colours) are unaffected."),
            callback = function(touchmenu_instance)
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text = _("Reset the chip bar to default settings?\n\n"
                        .. "All custom chips you have created or edited "
                        .. "will be lost. Other Bookshelf settings (hero "
                        .. "text, fonts, colours) are unaffected."),
                    ok_text = _("Reset"),
                    ok_callback = function()
                        BookshelfSettings.delete("tabs")
                        -- The active chip / cursor / page might point at a
                        -- custom chip ID that no longer exists after reset.
                        -- Drop them so the next render starts cleanly on
                        -- Home (the default).
                        BookshelfSettings.save("active_chip",   "all")
                        BookshelfSettings.save("active_cursor", 1)
                        BookshelfSettings.save("active_page",   1)
                        BookshelfSettings.flush()
                        if touchmenu_instance then
                            UIManager:close(touchmenu_instance)
                        end
                        -- Rebuild the live bookshelf so the new chip
                        -- layout paints immediately (also clears any
                        -- in-memory state from the chip bar widget).
                        if self._bw and self._bw._rebuild then
                            self._bw.chip    = "all"
                            self._bw._cursor = 1
                            if self._bw._syncPageFromCursor then
                                self._bw:_syncPageFromCursor()
                            end
                            self._bw._drilldown_path = {}
                            self._bw:_rebuild()
                            UIManager:setDirty(self._bw, "ui")
                        end
                    end,
                })
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
                return BookshelfSettings.read("calibre_metadata") == true
            end,
            keep_menu_open = true,
            callback = function()
                local enabled = BookshelfSettings.read("calibre_metadata") == true
                BookshelfSettings.save("calibre_metadata", not enabled)
                local ok, Repo = pcall(require, "lib/bookshelf_book_repository")
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
    local key = "font_scale"
    local original = BookshelfSettings.read(key, 100)

    local function getValue() return BookshelfSettings.read(key, 100) end
    local function setValue(v)
        v = math.max(50, math.min(200, v))
        BookshelfSettings.save(key, v)
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

-- Bookends-style nudge dialog for the chip-strip font scale. Same shape as
-- _pickFontScale but lives in its own method so the live preview only kicks
-- the rebuild path bookshelf needs and the +/- step sizes can match the
-- user's preferred resolution (1 / 10 here vs 5 / 10 for hero text).
function Settings:_pickChipFontScale()
    local ButtonDialog = require("ui/widget/buttondialog")
    local key = "chip_font_scale"
    local original = BookshelfSettings.read(key, 100)

    local function getValue() return BookshelfSettings.read(key, 100) end
    local function setValue(v)
        v = math.max(50, math.min(300, v))
        BookshelfSettings.save(key, v)
    end
    local function rebuild()
        if self._bw and self._bw._rebuild then
            self._bw:_rebuild()
            UIManager:setDirty(self._bw, "ui")
        end
    end

    local dialog
    local function nudge(delta)
        setValue(getValue() + delta)
        rebuild()
        dialog:reinit()
    end
    local function close() UIManager:close(dialog) end
    local function revert()
        setValue(original)
        rebuild()
    end

    dialog = ButtonDialog:new{
        title = _("Chip bar font size"),
        buttons = {
            {
                { text = "-10",  callback = function() nudge(-10) end },
                { text = "-1",   callback = function() nudge(-1)  end },
                { text_func = function() return tostring(getValue()) .. "%" end,
                  enabled = false },
                { text = "+1",   callback = function() nudge(1)   end },
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
    local current = BookshelfSettings.read("latest_walk_depth") or 3
    UIManager:show(SpinWidget:new{
        value      = current,
        value_min  = 1,
        value_max  = 99,
        value_step = 1,
        title_text = _("\"Latest\" folder walk depth"),
        info_text  = _("How deep to scan your library folder for newly-added books."
                        .. " Higher values take longer on a cold start."),
        callback   = function(spin)
            BookshelfSettings.save("latest_walk_depth", spin.value)
        end,
    })
end

-- _about() — small popup with the logo, plugin name + installed version,
-- the one-paragraph description (sourced from _meta.lua so translators
-- can localise it the same way they localise the plugin's own
-- description), and the GitHub URL. Deliberately simple -- an earlier
-- iteration rendered the full README which read as overwhelming.
function Settings:_about()
    -- Find the plugin root from this file's path. settings.lua sits at
    -- <plugin_dir>/lib/<file>.lua so strip one segment to reach
    -- _meta.lua and assets/.
    local src = debug.getinfo(1, "S").source:match("@(.*)$")
    local plugin_dir = src and src:match("^(.*)/lib/[^/]+%.lua$")
    local meta
    if plugin_dir then
        local ok, m = pcall(dofile, plugin_dir .. "/_meta.lua")
        if ok then meta = m end
    end
    local name        = (meta and meta.fullname)    or "Bookshelf"
    local version     = (meta and meta.version)     or "?"
    local description = (meta and meta.description) or ""

    -- Hard-coded English URL; not translatable. Display form drops the
    -- https:// prefix for compactness; the bare host+path reads as a
    -- URL on its own. Full URL with scheme is what Device:openLink and
    -- the clipboard receive on tap.
    local GITHUB_URL_DISPLAY = "github.com/AndyHazz/bookshelf.koplugin"
    local GITHUB_URL         = "https://github.com/AndyHazz/bookshelf.koplugin"

    local Device           = require("device")
    local Screen           = Device.screen
    local Font             = require("ui/font")
    local Geom             = require("ui/geometry")
    local Size             = require("ui/size")
    local Blitbuffer       = require("ffi/blitbuffer")
    local FrameContainer   = require("ui/widget/container/framecontainer")
    local CenterContainer  = require("ui/widget/container/centercontainer")
    local MovableContainer = require("ui/widget/container/movablecontainer")
    local InputContainer   = require("ui/widget/container/inputcontainer")
    local VerticalGroup    = require("ui/widget/verticalgroup")
    local VerticalSpan     = require("ui/widget/verticalspan")
    local TextBoxWidget    = require("ui/widget/textboxwidget")
    local TextWidget       = require("ui/widget/textwidget")
    local GestureRange     = require("ui/gesturerange")

    local sw, sh = Screen:getWidth(), Screen:getHeight()
    -- Frame target: ~75% of width on phone-sized portraits, capped so it
    -- doesn't sprawl on landscape / tablet sizes.
    local frame_w = math.min(math.floor(sw * 0.8), Screen:scaleBySize(420))
    -- Inner padding: Size.padding.large (10dp) reads as cramped at this
    -- frame size; the text edges sit ~1mm from the rounded border on
    -- PW5. Scale up to ~24dp -- still snug but visibly breathable.
    local FRAME_PAD = Screen:scaleBySize(24)
    local content_w = frame_w - FRAME_PAD * 2

    local column = VerticalGroup:new{ align = "center" }

    -- Logo at the top, centred. The PNG is 900x380 (2.37:1) with a
    -- transparent background, so we MUST pass alpha=true -- the
    -- default (alpha=false) ignores the alpha channel and renders the
    -- transparent area as opaque black. Width caps at content_w or
    -- ~220dp, whichever is smaller; height is derived from the image's
    -- native aspect so the widget doesn't reserve a tall square box
    -- with empty vertical bands above and below the actual logo.
    local LOGO_NATIVE_W, LOGO_NATIVE_H = 900, 380
    if plugin_dir then
        local logo_path = plugin_dir .. "/assets/bookshelf-logo.png"
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if ok_lfs and lfs and lfs.attributes and lfs.attributes(logo_path) then
            local ImageWidget = require("ui/widget/imagewidget")
            local logo_w = math.min(content_w, Screen:scaleBySize(220))
            local logo_h = math.floor(logo_w * LOGO_NATIVE_H / LOGO_NATIVE_W)
            column[#column + 1] = ImageWidget:new{
                file         = logo_path,
                width        = logo_w,
                height       = logo_h,
                scale_factor = 0,
                alpha        = true,
            }
            column[#column + 1] = VerticalSpan:new{ width = Size.padding.default }
        end
    end

    -- Version-only line below the logo. "Bookshelf" would duplicate the
    -- name baked into the logo; the version digits stand alone. Sourced
    -- live from _meta.lua so any release that touches version=... in
    -- that file flows through automatically -- there's no other
    -- string to keep in sync.
    column[#column + 1] = TextWidget:new{
        text = "v" .. version,
        face = Font:getFace("cfont", 16),
    }
    column[#column + 1] = VerticalSpan:new{ width = Size.padding.large }
    column[#column + 1] = TextBoxWidget:new{
        text      = description,
        face      = Font:getFace("cfont", 16),
        width     = content_w,
        alignment = "center",
    }
    column[#column + 1] = VerticalSpan:new{ width = Size.padding.large }
    -- Tappable URL: tries Device:openLink (works on SDL / Android), then
    -- falls back to copying to KOReader's internal clipboard + a brief
    -- Notification. On Kindle there's no native browser so the
    -- clipboard path is the user-meaningful one (paste into a Send-to-
    -- Kindle-style helper, or just read the URL clearly).
    local Button = require("ui/widget/button")
    local function open_github()
        local ok = false
        if Device.openLink then
            local _ok, ret = pcall(function() return Device:openLink(GITHUB_URL) end)
            if _ok and ret then ok = true end
        end
        if not ok and Device.input and Device.input.setClipboardText then
            pcall(function() Device.input.setClipboardText(GITHUB_URL) end)
            local Notification = require("ui/widget/notification")
            UIManager:show(Notification:new{
                text = _("Link copied to clipboard"),
            })
        end
    end
    column[#column + 1] = Button:new{
        text       = GITHUB_URL_DISPLAY,
        bordersize = 0,
        padding    = 0,
        margin     = 0,
        text_font_face = "cfont",
        text_font_size = 14,
        callback   = open_github,
    }

    -- Frame styling matches the other Bookshelf modals (chip editor,
    -- hero line editor): default Size.border.window thickness (thicker
    -- than Size.border.thin) and Size.radius.window for rounded
    -- corners. Earlier the popup used thin + square, which read as
    -- subtly out-of-family next to the rest of the plugin's dialogs.
    -- Per-side padding: tighter at the top because the BOOKSHELF logo's
    -- bold glyphs carry their own visual mass and don't need as much
    -- breathing room above them. Equal padding made the popup read as
    -- top-heavy in the screenshot. Bottom keeps the full FRAME_PAD so
    -- the URL has the same air the description gets.
    local frame = FrameContainer:new{
        radius        = Size.radius.window,
        padding       = FRAME_PAD,
        padding_top   = math.floor(FRAME_PAD * 0.5),
        margin        = 0,
        background    = Blitbuffer.COLOR_WHITE,
        column,
    }

    local dialog
    dialog = InputContainer:new{
        align = "center",
        dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh },
        CenterContainer:new{
            dimen = Geom:new{ w = sw, h = sh },
            MovableContainer:new{ frame },
        },
    }
    if Device:isTouchDevice() then
        dialog.ges_events = {
            TapClose = { GestureRange:new{
                ges   = "tap",
                range = Geom:new{ x = 0, y = 0, w = sw, h = sh },
            } },
        }
        dialog.onTapClose = function(self_d, _arg, ges_ev)
            if not frame.dimen or ges_ev.pos:notIntersectWith(frame.dimen) then
                UIManager:close(self_d)
            end
            return true
        end
    end
    if Device:hasKeys() then
        dialog.key_events = { Close = { { Device.input.group.Back } } }
        dialog.onClose = function(self_d)
            UIManager:close(self_d)
            return true
        end
    end

    UIManager:show(dialog)
end

-- _updateSubItems() — drill-down menu for the in-app updater. Mirrors
-- bookends's structure: a "Notify" toggle, a primary update row that
-- auto-relabels when an update is queued, and an "Advanced" pocket for
-- the dev-branch picker + reset-to-stable.
function Settings:_updateSubItems()
    local Updater = require("lib/bookshelf_updater")
    local plugin = self._plugin   -- the Bookshelf plugin instance
    return {
        {
            text         = _("Notify on wake when update available"),
            checked_func = function() return plugin and plugin.check_updates end,
            callback     = function()
                if not plugin then return end
                plugin.check_updates = not plugin.check_updates
                BookshelfSettings.save("check_updates", plugin.check_updates)
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

-- _tabsMenuItems() -- sub_item_table_func payload for "Bookshelf tabs...".
-- Each tab gets a checkbox row: tap toggles enabled, long-press opens the
-- per-tab editor. A footer row creates a new custom tab and opens its editor.
--
-- hideParentMenu pattern mirrors bookshelf_hero_line_editor.lua: close the
-- CenterContainer wrapping the TouchMenu so the editor has a clear canvas,
-- then do NOT re-show -- the user can re-open the menu if they want to edit
-- another tab. The chevron buttons inside editTab let them reach adjacent
-- tabs by holding a neighbour chip instead.
function Settings:_tabsMenuItems()
    local TabModel = require("lib/bookshelf_tab_model")
    local Editor   = require("lib/bookshelf_chip_editor")
    local UIManager_ref = require("ui/uimanager")

    local function rebuild()
        if self._bw and self._bw._rebuild then
            self._bw:_rebuild()
            UIManager_ref:setDirty(self._bw, "ui")
        end
    end

    local function hideParentMenu(touchmenu_instance)
        if not touchmenu_instance then return end
        local container = touchmenu_instance.show_parent or touchmenu_instance
        UIManager_ref:close(container, "ui")
    end

    local items = {
        {
            text = _("Chip bar font size"),
            callback = function() self:_pickChipFontScale() end,
        },
        {
            text = _("Flexible chip widths"),
            help_text = _("Off: every chip gets the same width. On: each "
                .. "chip is sized to its label, so single-icon chips stay "
                .. "narrow and longer text labels get more room. Falls "
                .. "back to equal widths when natural sizes don't fit."),
            checked_func   = function()
                return BookshelfSettings.isTrue("chip_flex_widths")
            end,
            keep_menu_open = true,
            callback = function()
                local on = BookshelfSettings.isTrue("chip_flex_widths")
                BookshelfSettings.save("chip_flex_widths", not on)
                rebuild()
            end,
            separator = true,
        },
    }
    local tabs = TabModel.load()
    for _i, tab in ipairs(tabs) do
        local tab_id = tab.id
        items[#items + 1] = {
            keep_menu_open = true,
            text_func = function()
                -- Re-read from model so label reflects any edits made via
                -- the long-press editor without re-opening the menu.
                local fresh = TabModel.load()
                for _i, t in ipairs(fresh) do
                    if t.id == tab_id then return t.label end
                end
                return tab_id
            end,
            checked_func = function()
                local fresh = TabModel.load()
                for _i, t in ipairs(fresh) do
                    if t.id == tab_id then return t.enabled ~= false end
                end
                return true
            end,
            callback = function(touchmenu_instance)
                local fresh = TabModel.load()
                for _i, t in ipairs(fresh) do
                    if t.id == tab_id then
                        t.enabled = (t.enabled == false) and true or false
                        TabModel.save(fresh)
                        rebuild()
                        break
                    end
                end
                if touchmenu_instance and touchmenu_instance.updateItems then
                    touchmenu_instance:updateItems()
                end
            end,
            hold_callback = function(touchmenu_instance)
                hideParentMenu(touchmenu_instance)
                Editor:editTab(tab_id, { on_change = function() rebuild() end })
            end,
        }
    end

    -- Footer: add a new custom tab and open its editor immediately.
    items[#items + 1] = {
        text = _("+ Add new chip"),
        callback = function(touchmenu_instance)
            -- Generate a unique custom_N id.
            local fresh = TabModel.load()
            local n = 1
            while true do
                local candidate = "custom_" .. n
                local taken = false
                for _i, t in ipairs(fresh) do
                    if t.id == candidate then taken = true; break end
                end
                if not taken then break end
                n = n + 1
            end
            local new_id = "custom_" .. n
            local new_tab = {
                id            = new_id,
                label         = _("New chip"),
                icon          = nil,
                source        = { kind = "all" },
                filter        = {},
                sort_priority = { { key = "title", reverse = false } },
                enabled       = true,
            }
            fresh[#fresh + 1] = new_tab
            TabModel.save(fresh)
            hideParentMenu(touchmenu_instance)
            Editor:editTab(new_id, { on_change = function() rebuild() end })
        end,
    }

    return items
end

return Settings
