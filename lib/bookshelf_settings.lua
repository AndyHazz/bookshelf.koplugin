-- bookshelf_settings.lua
-- Gear-menu settings modal for Bookshelf: hero-card line editor, font scale,
-- progress-bar toggle, latest-walk depth, titlebar-meta toggle, About.
--
-- Public API: Settings:show()
-- All persisted keys use the bookshelf_* prefix.

local Menu         = require("ui/widget/menu")
local Notification = require("ui/widget/notification")
local SpinWidget   = require("ui/widget/spinwidget")
local UIManager    = require("ui/uimanager")
local T            = require("ffi/util").template
local _            = require("lib/bookshelf_i18n").gettext
local Focus        = require("lib/bookshelf_focus")

local BookshelfSettings = require("lib/bookshelf_settings_store")
local BFont        = require("lib/bookshelf_fonts")

-- ─── Settings singleton ───────────────────────────────────────────────────────

local Settings = {}

-- Re-setup the in-reader launcher buttons after a setting that affects them
-- (start-menu position, micro placement, the launcher toggle) so they update
-- live instead of only on the next book open. The bookshelf plugin instance is
-- a registered module on ReaderUI; no-op outside the reader.
local function refreshReaderLauncher()
    local rd = package.loaded["apps/reader/readerui"]
    rd = rd and rd.instance
    if not rd then return end
    for _i, m in ipairs(rd) do
        if type(m) == "table" and type(m._setupReaderButtons) == "function" then
            pcall(function() m:_setupReaderButtons() end)
            return
        end
    end
end

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
        { key = "Authors",  label = _("Authors") },
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
                local desc_face, desc_bold = BFont:getFace("cfont", 16, { bold = true })
                local desc_w = TextWidget:new{
                    text = item.description or "",
                    face = desc_face,
                    bold = desc_bold,
                    max_width = content_w,
                }
                local tok_face, tok_bold = BFont:getFace("cfont", 13)
                local tok_w = TextWidget:new{
                    text = (item.token or "") .. preview,
                    face = tok_face,
                    bold = tok_bold,
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
                text           = "── " .. Tokens.categoryLabel(t.category) .. " ──",
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
    -- Hero font scale moved to Settings -> Text size (#60). Keeping a
    -- single place to dial every font scale beats sprinkling the same
    -- knob across each context-specific submenu.
    local items = {}
    -- Translation extraction markers: Regions.LABELS values reach the
    -- runtime via the _(Regions.LABELS[key]) dynamic lookup below (and the
    -- same lookup in bookshelf_hero_line_editor), which xgettext cannot
    -- follow. List EVERY region label here -- not just the ones unique to
    -- this surface -- so none can silently drop from the .pot on regen.
    -- Relying on "it also appears in a direct _() elsewhere" already failed
    -- once: "Status line" and "Metadata" were never extracted and so were
    -- untranslatable in every locale (surfaced via the zh_CN PR #109). Keep
    -- this list in sync with Regions.LABELS. Dead code at runtime; it
    -- exists only so xgettext emits the msgids.
    if false then
        local _ignore = {
            _("Status line"),
            _("Title"),
            _("Author"),
            _("Rating (interactive)"),
            _("Metadata"),
            _("Description"),
            _("Tags (interactive)"),
            _("Progress"),
        }
    end
    for _i, key in ipairs(Regions.ORDER) do
        local item = {
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
                -- Rating is an interactive widget, not a text-templated
                -- region — a line editor for it is meaningless. Tap toggles
                -- enabled, same as hold elsewhere.
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
        if key == "tags" then
            -- Tags is interactive AND configurable (#99): the row opens a
            -- submenu (enable + per-category visibility + font size +
            -- alignment) instead of a plain enable toggle. Drop the toggle
            -- callbacks and the checkbox; the submenu carries the enable
            -- switch itself.
            item.checked_func   = nil
            item.callback       = nil
            item.hold_callback  = nil
            item.sub_item_table_func = function()
                return self:_tagsRegionSubItems()
            end
        end
        items[#items + 1] = item
    end
    return items
end

-- _tagsRegionSubItems() — the "Tags (interactive)" configuration submenu
-- (#99). Enable switch, per-category visibility checkboxes, font size, and
-- alignment. Each control writes one merged field on the tags region and
-- live-refreshes the hero (which re-reads the config on its next pill
-- build) so the change is visible behind the open menu.
function Settings:_tagsRegionSubItems()
    local Regions = require("lib/bookshelf_hero_regions")
    -- Merge one field into the tags region and refresh. _swapHeroInPlace
    -- rebuilds the hero card (recreating the tags pill builder), so the
    -- new categories / font / alignment show immediately.
    local function setTagsField(field, value, touchmenu_instance)
        local snap = Regions.snapshot("tags") or {}
        snap[field] = value
        Regions.write("tags", snap)
        if self._bw and self._bw._swapHeroInPlace then
            self._bw:_swapHeroInPlace()
        end
        if touchmenu_instance and touchmenu_instance.updateItems then
            touchmenu_instance:updateItems()
        end
    end
    -- A category visibility checkbox row. show_<cat> defaults true (every
    -- category shown == pre-#99 behaviour), so nil reads as on.
    local function categoryRow(field, label, separator)
        return {
            text = label,
            checked_func = function() return Regions.read().tags[field] ~= false end,
            keep_menu_open = true,
            separator = separator,
            callback = function(touchmenu_instance)
                setTagsField(field, Regions.read().tags[field] == false,
                             touchmenu_instance)
            end,
        }
    end
    local function alignmentRow(value, label)
        return {
            text = label,
            radio = true,
            checked_func = function()
                return (Regions.read().tags.alignment or "left") == value
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                setTagsField("alignment", value, touchmenu_instance)
            end,
        }
    end
    return {
        {
            text = _("Show tags line"),
            checked_func = function() return not Regions.read().tags.disabled end,
            keep_menu_open = true,
            separator = true,
            callback = function(touchmenu_instance)
                setTagsField("disabled", not Regions.read().tags.disabled,
                             touchmenu_instance)
            end,
        },
        categoryRow("show_author",      _("Author")),
        categoryRow("show_series",      _("Series")),
        categoryRow("show_collections", _("Collections")),
        categoryRow("show_genres",      _("Genres")),
        categoryRow("show_folder",      _("Folder"), true),
        {
            text_func = function()
                return _("Font size") .. ": "
                    .. tostring(Regions.read().tags.font_size or 14)
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                -- Same bookends-style nudge dialog the hero line editor uses
                -- for text-region sizes. Hide the settings menu first so the
                -- live hero is visible while nudging; restoreMenu reopens THIS
                -- submenu (and refreshes its rows) when the nudge closes.
                local LineEditor  = require("lib/bookshelf_hero_line_editor")
                local restoreMenu = LineEditor.hideParentMenu(touchmenu_instance)
                local cur     = Regions.read().tags.font_size or 14
                local default = Regions.DEFAULTS.tags.font_size or 14
                LineEditor.showSizeNudge(
                    cur, default,
                    -- on_change: persist + live-refresh the hero each nudge.
                    -- No touchmenu_instance (it's hidden), so no menu update.
                    function(val) setTagsField("font_size", val) end,
                    -- on_close: reopen the settings submenu.
                    function() restoreMenu() end,
                    { title = _("Tags font size") })
            end,
        },
        {
            text_func = function()
                local a = Regions.read().tags.alignment or "left"
                local labels = { left = _("Left"), center = _("Centre"), right = _("Right") }
                return _("Alignment") .. ": " .. (labels[a] or labels.left)
            end,
            keep_menu_open = true,
            sub_item_table = {
                alignmentRow("left",   _("Left")),
                alignmentRow("center", _("Centre")),
                alignmentRow("right",  _("Right")),
            },
        },
        {
            -- Caps how many rows of pills the hero shows; the overflow folds
            -- into the tappable "+N" button (which opens the full tags sheet).
            -- 1 row reads cleanest now that nothing is lost to the cap; more
            -- rows suit a hero with the spare height (e.g. description off).
            text_func = function()
                return _("Maximum tag rows") .. ": "
                    .. tostring(Regions.read().tags.max_rows or 2)
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local SpinWidget = require("ui/widget/spinwidget")
                local UIManager_ = require("ui/uimanager")
                local cur = tonumber(Regions.read().tags.max_rows) or 2
                UIManager_:show(SpinWidget:new{
                    title_text = _("Maximum tag rows"),
                    info_text  = _("How many rows of tag pills the hero shows before the rest collapse into a tappable +N button."),
                    value      = cur,
                    value_min  = 1,
                    value_max  = 5,
                    value_step = 1,
                    ok_text    = _("Set"),
                    callback   = function(spin)
                        setTagsField("max_rows", spin.value, touchmenu_instance)
                    end,
                })
            end,
        },
    }
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
        -- On-hold display: four-state. "both" (default; pause badge +
        -- faded cover), "pause" (badge only), "fade" (faded cover only),
        -- "none". Replaces the old Show on-hold badge boolean, which
        -- gated both cues together; issue #121 asked for them split (one
        -- reporter fades DNF books and wants no badge, another keeps the
        -- badge but wants no fade). Legacy on_hold_badge_enabled still
        -- honoured when on_hold_display is unset: false -> "none",
        -- true / nil -> "both". cover_progress.decide() runs the same
        -- migration so the rendering side and the menu agree.
        (function()
            local function readMode()
                local v = BookshelfSettings.read("on_hold_display")
                if v == "none" or v == "pause" or v == "fade" or v == "both" then
                    return v
                end
                local legacy = BookshelfSettings.read("on_hold_badge_enabled")
                if legacy == false then return "none" end
                return "both"
            end
            local function setMode(mode, touchmenu_instance)
                BookshelfSettings.save("on_hold_display", mode)
                markDirty()
                if touchmenu_instance and touchmenu_instance.updateItems then
                    touchmenu_instance:updateItems()
                end
            end
            local labels = {
                none  = _("None"),
                pause = _("Pause badge"),
                fade  = _("Faded cover"),
                both  = _("Both"),
            }
            -- The parent row spells "both" out: "On-hold display: Both"
            -- reads as nonsense without the sub-menu options around it.
            local parent_labels = setmetatable(
                { both = _("Pause badge + faded cover") },
                { __index = labels })
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
                    return _("On-hold display") .. ": " .. parent_labels[readMode()]
                end,
                sub_item_table_func = function()
                    return {
                        optionRow("none",  labels.none),
                        optionRow("pause", labels.pause),
                        optionRow("fade",  labels.fade),
                        optionRow("both",  labels.both),
                    }
                end,
            }
        end)(),
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
        -- Cover-badge font scale moved to Settings -> Text size (#60).
        -- Favourites icon at top-left of covers for books in the favourites
        -- collection. Defaults ON: favouriting a book should mark it without
        -- a second opt-in (render gate uses nilOrTrue to match). Users who
        -- explicitly turn it off keep it off.
        toggleRow("show_fav_badge",
                  _("Show favourites icon"), false, false),
        -- Favourite icon glyph: heart (default; reads distinctly from the
        -- rating stars) or star. The chosen icon also selects which colour
        -- the Colors -> Favourite entry edits.
        (function()
            local function readIcon()
                return require("lib/bookshelf_cover_progress").favoriteIcon()
            end
            local function setIcon(icon, touchmenu_instance)
                BookshelfSettings.save("fav_icon", icon)
                markDirty()
                if touchmenu_instance and touchmenu_instance.updateItems then
                    touchmenu_instance:updateItems()
                end
            end
            local labels = { heart = _("Heart"), star = _("Star") }
            local function optionRow(icon, label)
                return {
                    text           = label,
                    checked_func   = function() return readIcon() == icon end,
                    radio          = true,
                    keep_menu_open = true,
                    callback       = function(touchmenu_instance)
                        setIcon(icon, touchmenu_instance)
                    end,
                }
            end
            return {
                text_func = function()
                    return _("Favourite icon") .. ": " .. labels[readIcon()]
                end,
                sub_item_table_func = function()
                    return {
                        optionRow("heart", labels.heart),
                        optionRow("star",  labels.star),
                    }
                end,
            }
        end)(),
    }
end

-- Colors sub-menu: progress-bar Read / Unread colors today;
-- folder color, cover badge color, progress bookmark color all
-- expected to land here as they ship. Greyscale devices get a
-- nudge dialog (% black); color devices get the palette picker.
function Settings:_colorsSubItems()
    local CoverProgress = require("lib/bookshelf_cover_progress")
    local Color        = require("lib/bookshelf_color")
    local Screen        = require("device").screen

    local function markDirty()
        if self._bw and self._bw._rebuild then
            self._bw:_rebuild()
            UIManager:setDirty(self._bw, "ui")
        end
    end

    -- "% black" semantics: ALWAYS describe what the user SEES ON SCREEN,
    -- regardless of mode. In day mode the painted byte is what hits the
    -- panel: 0xFF = white = 0% black, 0x00 = black = 100% black. In
    -- night mode KOReader inverts the framebuffer at refresh, so a
    -- painted 0x00 ends up WHITE on screen — the picker needs to flip
    -- the % so "100%" stays "dark on screen" regardless of mode. The
    -- two helpers below do that conversion, used by both valueLabel
    -- (read) and pickColor (read + write).
    local function _isNight()
        return G_reader_settings:isTrue("night_mode") or false
    end
    local function _byteToScreenPct(byte)
        if _isNight() then
            return math.floor(byte * 100 / 0xFF + 0.5)
        end
        return math.floor((0xFF - byte) * 100 / 0xFF + 0.5)
    end
    local function _screenPctToByte(pct)
        if _isNight() then
            return math.floor(pct * 0xFF / 100 + 0.5)
        end
        return 0xFF - math.floor(pct * 0xFF / 100 + 0.5)
    end

    local function valueLabel(field)
        local raw = CoverProgress.rawColors()[field]
        if not raw then return _("default") end
        if raw.hex then
            if Screen:isColorEnabled() then return raw.hex end
            -- B&W device: render hex as the Rec.601 luminance %. Routes
            -- through the screen-pct helper so the displayed value
            -- matches what the panel will actually show after night-mode
            -- inversion (if active).
            local hex = raw.hex
            local r = tonumber(hex:sub(2, 3), 16) or 0
            local g = tonumber(hex:sub(4, 5), 16) or 0
            local b = tonumber(hex:sub(6, 7), 16) or 0
            local lum = math.floor(0.299 * r + 0.587 * g + 0.114 * b + 0.5)
            return _byteToScreenPct(lum) .. "%"
        end
        if raw.grey then
            return _byteToScreenPct(raw.grey) .. "%"
        end
        return _("default")
    end

    -- raw_key   : the BookshelfSettings storage key (e.g. "progress_fill").
    -- field     : the bookshelf_color DEFAULT_HEX field name (e.g. "fill").
    --             Decoupled from raw_key so the color-picker default tile
    --             can stay stable even as new storage keys are introduced.
    -- default_pct: greyscale nudge dialog default (% black) for the
    --             pre-color-mode picker path on Kindle / older Kobo.
    local function pickColor(raw_key, field, default_pct, title, touchmenu_instance)
        -- Suffix routes day vs night-mode storage to separate keys so
        -- editing in night mode doesn't clobber the user's day colors
        -- and vice versa. Mirrors CoverProgress.resolvedColors().
        local suffix = CoverProgress.modeSuffix and CoverProgress.modeSuffix() or ""
        local key      = raw_key .. suffix
        local raw      = BookshelfSettings.read(key)
        local original = raw

        if Screen:isColorEnabled() then
            local current_hex
            if raw and raw.hex then current_hex = raw.hex
            elseif raw and raw.grey then
                local g = string.format("%02X", raw.grey)
                current_hex = "#" .. g .. g .. g
            end
            self._plugin:showColorPicker(
                title, current_hex, Color.defaultHexFor(field),
                function(new_hex)
                    BookshelfSettings.save(key, Color.toStorageShape(new_hex))
                    markDirty()
                end,
                function()
                    BookshelfSettings.delete(key)
                    markDirty()
                end,
                function()
                    if original == nil then
                        BookshelfSettings.delete(key)
                    else
                        BookshelfSettings.save(key, original)
                    end
                    markDirty()
                end,
                touchmenu_instance)
            return
        end

        local byte
        if raw and raw.grey then byte = raw.grey end
        -- Nudge dialog speaks in "% black on screen". _byteToScreenPct
        -- handles the inversion in night mode so the user picks what
        -- they want to SEE; _screenPctToByte does the inverse when we
        -- write back, so the paint byte stored is whatever produces
        -- that on-screen result through the framework's render path.
        local current = byte and _byteToScreenPct(byte) or default_pct
        self:showNudgeDialog(title, current, 0, 100, default_pct, "%",
            function(val)
                BookshelfSettings.save(key, { grey = _screenPctToByte(val) })
                markDirty()
            end,
            nil, nil, nil, touchmenu_instance,
            function()
                BookshelfSettings.delete(key)
                markDirty()
            end,
            _("Default"))
    end

    -- Helper for the hold-to-reset path so we don't repeat the suffix
    -- decision per row. Deletes the active mode's storage key.
    local function deleteModeKey(base)
        local suffix = CoverProgress.modeSuffix and CoverProgress.modeSuffix() or ""
        BookshelfSettings.delete(base .. suffix)
    end

    return {
        {
            text_func = function()
                if G_reader_settings:isTrue("night_mode") then
                    return _("\xe2\x97\x90 Editing night-mode colors (tap to switch)")
                end
                return _("\xe2\x98\x80 Editing day-mode colors (tap to switch)")
            end,
            keep_menu_open = true,
            separator = true,
            callback = function(touchmenu_instance)
                -- Toggle KOReader's night-mode setting + broadcast the
                -- ToggleNightMode event so the FB inversion path runs
                -- exactly as it does when the user toggles from the
                -- gear menu / a gesture. The colour menu's text_func
                -- runs again on the next paint, so the header label
                -- flips itself.
                local Event = require("ui/event")
                UIManager:broadcastEvent(Event:new("ToggleNightMode"))
                markDirty()
                if touchmenu_instance and touchmenu_instance.updateItems then
                    touchmenu_instance:updateItems()
                end
            end,
        },
        {
            text_func = function()
                return _("Progress bar") .. ": " .. valueLabel("fill")
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                pickColor("progress_fill", "fill", 75,
                    _("Progress bar (% black)"), touchmenu_instance)
            end,
            hold_callback = function(touchmenu_instance)
                deleteModeKey("progress_fill")
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
                pickColor("progress_track", "track", 25,
                    _("Progress bar track (% black)"), touchmenu_instance)
            end,
            hold_callback = function(touchmenu_instance)
                deleteModeKey("progress_track")
                markDirty()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        },
        {
            text_func = function()
                return _("Bookmark color") .. ": " .. valueLabel("bookmark")
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                pickColor("bookmark_color", "bookmark", 75,
                    _("Bookmark color (% black)"), touchmenu_instance)
            end,
            hold_callback = function(touchmenu_instance)
                deleteModeKey("bookmark_color")
                markDirty()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        },
        {
            text_func = function()
                return _("Finished bookmark color") .. ": "
                    .. valueLabel("complete_bookmark")
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                pickColor("complete_bookmark_color", "complete_bookmark", 0,
                    _("Finished bookmark color (% black)"), touchmenu_instance)
            end,
            hold_callback = function(touchmenu_instance)
                deleteModeKey("complete_bookmark_color")
                markDirty()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        },
        {
            -- Edits the colour for whichever favourite icon is active, so
            -- switching Heart/Star in Cover display points this entry (label,
            -- value, picker, reset) at that icon's own colour key.
            text_func = function()
                local is_heart = require("lib/bookshelf_cover_progress").favoriteIcon() == "heart"
                local label   = is_heart and _("Favourite heart color") or _("Favourite star color")
                return label .. ": " .. valueLabel(is_heart and "favorite_heart" or "favorite_star")
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local is_heart = require("lib/bookshelf_cover_progress").favoriteIcon() == "heart"
                if is_heart then
                    pickColor("favorite_heart_color", "favorite_heart", 15,
                        _("Favourite heart color (% black)"), touchmenu_instance)
                else
                    pickColor("favorite_star_color", "favorite_star", 15,
                        _("Favourite star color (% black)"), touchmenu_instance)
                end
            end,
            hold_callback = function(touchmenu_instance)
                local is_heart = require("lib/bookshelf_cover_progress").favoriteIcon() == "heart"
                deleteModeKey(is_heart and "favorite_heart_color" or "favorite_star_color")
                markDirty()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        },
        {
            text_func = function()
                return _("Badge foreground") .. ": " .. valueLabel("badge_fg")
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                pickColor("badge_fg", "badge_fg", 100,
                    _("Badge foreground (% black)"), touchmenu_instance)
            end,
            hold_callback = function(touchmenu_instance)
                deleteModeKey("badge_fg")
                markDirty()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        },
        {
            text_func = function()
                return _("Badge background") .. ": " .. valueLabel("badge_bg")
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                pickColor("badge_bg", "badge_bg", 0,
                    _("Badge background (% black)"), touchmenu_instance)
            end,
            hold_callback = function(touchmenu_instance)
                deleteModeKey("badge_bg")
                markDirty()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        },
        {
            text_func = function()
                return _("Border color") .. ": " .. valueLabel("border")
            end,
            help_text = _("Color of the book cover frame border + pill"
                .. " badge / page-count badge borders. Badge foreground"
                .. " is now just badge text. Default black."),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                pickColor("border_color", "border", 100,
                    _("Border color (% black)"), touchmenu_instance)
            end,
            hold_callback = function(touchmenu_instance)
                deleteModeKey("border_color")
                markDirty()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        },
        {
            text_func = function()
                return _("Folder overlay background") .. ": " .. valueLabel("folder_bg")
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                pickColor("folder_overlay_bg", "folder_bg", 20,
                    _("Folder overlay background (% black)"), touchmenu_instance)
            end,
            hold_callback = function(touchmenu_instance)
                deleteModeKey("folder_overlay_bg")
                markDirty()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        },
        {
            text_func = function()
                return _("Folder text color") .. ": " .. valueLabel("folder_fg")
            end,
            help_text = _("Color of the label text inside folder / series"
                .. " / author / genre / tag cards. The cardboard outline"
                .. " around the card itself follows the Border color"
                .. " setting above."),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                pickColor("folder_overlay_fg", "folder_fg", 100,
                    _("Folder text color (% black)"), touchmenu_instance)
            end,
            hold_callback = function(touchmenu_instance)
                deleteModeKey("folder_overlay_fg")
                markDirty()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        },
        {
            text = _("Reset to default colors"),
            separator = true,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local keys = {
                    "progress_fill", "progress_track",
                    "bookmark_color", "complete_bookmark_color",
                    "favorite_star_color", "favorite_heart_color",
                    "badge_fg", "badge_bg", "border_color",
                    "folder_overlay_bg", "folder_overlay_fg",
                }
                -- Clear both day AND night variants so "Reset" lives up
                -- to its name regardless of which mode the menu is in.
                for _i, k in ipairs(keys) do
                    BookshelfSettings.delete(k)
                    BookshelfSettings.delete(k .. "_night")
                end
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

    -- Hide the TouchMenu sitting behind the nudge so the user can see
    -- the live preview update on every tap (the menu would otherwise
    -- obscure the badge / shelf / hero being scaled). restoreMenu is
    -- called from close() on Cancel and Apply so the next "Tap to
    -- nudge a different font" lands on the menu they came from.
    -- Reused pattern: see showNudgeDialog (~line 1230) and
    -- Bookshelf:hideMenu in main.lua. (#60 follow-up.)
    local restoreMenu = self._plugin:hideMenu(touchmenu_instance)

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
        Focus.reinit(dialog)
    end
    local function close() UIManager:close(dialog); restoreMenu() end
    local function revert() setValue(original); rebuild() end

    dialog = ButtonDialog:new{
        -- dismissable=false + movable.ges_events wipe below: the nudge
        -- workflow is "tap +/- repeatedly, then tap Apply / Cancel /
        -- Default to close". Default ButtonDialog UX has rapid taps
        -- fall through to the modal background and dismiss mid-edit,
        -- and any long-press on a button propagates as a
        -- MovableContainer hold-release that toggles the dialog to
        -- 70% alpha. Both surprise in a nudge context; lock the
        -- dialog to its own three close buttons.
        dismissable = false,
        title = _("Cover badge size"),
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
                  callback = function() setValue(100); rebuild(); Focus.reinit(dialog) end },
                { text = _("Apply"), is_enter_default = true, callback = close },
            },
        },
        tap_close_callback = revert,
    }
    if dialog.movable then dialog.movable.ges_events = {} end
    UIManager:show(dialog)
end

-- ---------------------------------------------------------------------------
-- Settings (parent) menu
-- ---------------------------------------------------------------------------

-- Cover-progress + Advanced settings live behind a single "Settings" entry
-- in the main bookshelf menu. Keeps the top level uncluttered while still
-- giving each surface its own sub-screen.
function Settings:_settingsSubItems()
    local items = {}

    -- ── layout band: shelf grid + hero area ──
    items[#items + 1] = {
        text     = _("Edit shelf size") .. "…",
        help_text = _("Open a small overlay that lets you set the number of"
            .. " columns and rows of books on the shelf, with the bookshelf"
            .. " visible behind it. Cover size follows the column count and"
            .. " the hero area fills the space left over. Changes preview in"
            .. " realtime; Accept keeps them, Cancel reverts."),
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            self:_openLayoutEditor(touchmenu_instance)
        end,
    }
    items[#items + 1] = {
        text                = _("Expanded shelf"),
        sub_item_table_func = function()
            return self:_expandedShelfSubItems()
        end,
    }
    -- Micro-module placement: three INDEPENDENT surfaces (start menu / hero /
    -- full-screen button), each a checkbox, so any combination can run at once.
    -- Promoted here from Advanced so it sits directly above "Hero area starts
    -- with" -- the row the hero checkbox governs -- which shows/hides live.
    -- Turning all three off is the kill switch (microAnyEnabled() false).
    items[#items + 1] = {
        text_func = function()
            if not BookshelfSettings.microAnyEnabled() then
                return _("Micro modules") .. ": " .. _("Off")
            end
            return _("Micro modules")
        end,
        help_text = _("Where micro-modules appear. Each surface is independent:"
            .. " In start menu shows module cards in the start-menu launcher; In"
            .. " hero area gives a chip that swaps the hero card for the grid;"
            .. " Full-screen button adds a footer button opening a full-screen"
            .. " grid. The hero and full-screen surfaces keep their own module"
            .. " lists. Turn all three off to disable micro-modules entirely."),
        sub_item_table_func = function()
            -- Flip one surface. Snapshot the current (possibly still
            -- legacy-derived) state of all three and persist them explicitly, so
            -- after the first toggle we no longer depend on the old
            -- micro_modules_placement key.
            local function toggle(which, touchmenu_instance)
                local sm   = BookshelfSettings.microInStartMenu()
                local hero = BookshelfSettings.microInHero()
                local fs   = BookshelfSettings.microFullscreenButton()
                if     which == "start_menu" then sm   = not sm
                elseif which == "hero"       then hero = not hero
                elseif which == "fullscreen" then fs   = not fs end
                BookshelfSettings.save("micro_in_start_menu", sm)
                BookshelfSettings.save("micro_in_hero", hero)
                BookshelfSettings.save("micro_fullscreen_button", fs)
                BookshelfSettings.delete("micro_modules_placement")  -- fully migrated
                BookshelfSettings.delete("micro_modules_disabled")   -- legacy
                refreshReaderLauncher()
                BookshelfSettings.flush()
                if self._bw then
                    if hero and BookshelfSettings.read("hero_area_mode") == "micro_modules" then
                        self._bw._hero_mode = "micro"
                        self._bw._expanded = false
                    elseif (not hero) and self._bw._hero_mode == "micro" then
                        -- Hero surface off: the chip that switches back is gone,
                        -- so drop to the book hero.
                        self._bw._hero_mode = "current"
                    end
                    if self._bw._rebuild then
                        self._bw:_rebuild()
                        UIManager:setDirty(self._bw, "ui")
                    end
                end
                if touchmenu_instance and touchmenu_instance.updateItems then
                    touchmenu_instance:updateItems()
                end
            end
            local function row(which, label, accessor)
                return {
                    text           = label,
                    checked_func   = accessor,
                    keep_menu_open = true,
                    callback       = function(tmi) toggle(which, tmi) end,
                }
            end
            return {
                row("start_menu", _("In start menu"),     BookshelfSettings.microInStartMenu),
                row("hero",       _("In hero area"),       BookshelfSettings.microInHero),
                row("fullscreen", _("Full-screen button"), BookshelfSettings.microFullscreenButton),
            }
        end,
    }
    -- Hero-area-starts-with only matters when micro-modules are in the hero
    -- area; hidden otherwise. Two-state radio: "currently_reading" (default)
    -- shows the book hero; "micro_modules" shows the micro-module grid. Seeds
    -- _hero_mode on each fresh widget; the chip-bar toggle owns the live
    -- switch, and changing it here applies live too.
    if BookshelfSettings.microInHero() then
        items[#items + 1] = (function()
            local function readMode()
                local v = BookshelfSettings.read("hero_area_mode")
                if v == "micro_modules" then return v end
                return "currently_reading"
            end
            local labels = {
                currently_reading = _("Currently reading"),
                micro_modules     = _("Micro modules"),
            }
            local function setMode(mode, touchmenu_instance)
                BookshelfSettings.save("hero_area_mode", mode)
                if self._bw then
                    self._bw._hero_mode =
                        (mode == "micro_modules") and "micro" or "current"
                    if mode == "micro_modules" then
                        -- Leave the expanded strip state if we're entering
                        -- micro mode, mirroring the chip handler.
                        self._bw._expanded = false
                    end
                    if self._bw._rebuild then
                        self._bw:_rebuild()
                        UIManager:setDirty(self._bw, "ui")
                    end
                end
                if touchmenu_instance and touchmenu_instance.updateItems then
                    touchmenu_instance:updateItems()
                end
            end
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
                    return _("Hero area starts with") .. ": " .. labels[readMode()]
                end,
                help_text = _("What the hero area at the top of the bookshelf"
                    .. " shows when it opens: the book you're currently"
                    .. " reading, or a grid of micro-modules (clock, quote,"
                    .. " random book, reading goals…). You can also switch"
                    .. " between them with the chips above the shelves."),
                sub_item_table_func = function()
                    return {
                        optionRow("currently_reading", labels.currently_reading),
                        optionRow("micro_modules",     labels.micro_modules),
                    }
                end,
            }
        end)()
    end
    -- End the layout band on whatever is last (Hero area if shown, else
    -- Micro-modules).
    items[#items].separator = true

    -- ── appearance band ──
    items[#items + 1] = {
        text                = _("Cover display"),
        sub_item_table_func = function()
            return self:_coverDisplaySubItems()
        end,
    }
    items[#items + 1] = {
        text                = _("Text size"),
        sub_item_table_func = function()
            return self:_textSizeSubItems()
        end,
    }
    items[#items + 1] = {
        text                = _("Colors"),
        sub_item_table_func = function()
            return self:_colorsSubItems()
        end,
    }
    -- Bookshelf UI font: promoted here from Advanced to sit with the other
    -- appearance settings.
    items[#items + 1] = {
        text_func = function()
            local Fonts = require("lib/bookshelf_fonts")
            local f = Fonts.getUIFontFace()
            local label = _("Follow KOReader")
            if f then label = f:gsub("^.*/", ""):gsub("%.%w+$", "") end  -- basename, no extension
            return T(_("Bookshelf UI font: %1"), label)
        end,
        help_text = _("The font Bookshelf uses for its own UI text (chips, "
            .. "labels, metadata). Pick any installed font (same picker as the "
            .. "hero card); '(Default)' follows your KOReader UI font. The hero "
            .. "title and author have their own fonts in the hero card editor."),
        keep_menu_open = true,
        callback = function(touchmenu_instance) self:_pickBookshelfUIFont(touchmenu_instance) end,
    }
    items[#items].separator = true  -- end appearance band

    -- ── start menu & reader band ──
    -- Start-menu position: three-state radio. "left" (default; an absent key
    -- reads as left), "right" mirrors the whole stack (footer button, popup
    -- anchor, leftward flyout), "off" removes the button and its d-pad slot.
    items[#items + 1] = (function()
        local function readPos()
            local v = BookshelfSettings.read("start_menu_position", "left")
            if v == "right" or v == "off" then return v end
            return "left"
        end
        local labels = {
            left  = _("Left"),
            right = _("Right"),
            off   = _("Off"),
        }
        local function optionRow(pos, label)
            return {
                text           = label,
                checked_func   = function() return readPos() == pos end,
                radio          = true,
                keep_menu_open = true,
                callback       = function(touchmenu_instance)
                    BookshelfSettings.save("start_menu_position", pos)
                    refreshReaderLauncher()
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
        return {
            text_func = function()
                return _("Start menu") .. ": " .. labels[readPos()]
            end,
            help_text = _("Where the start-menu button sits in the"
                .. " footer. Right moves the button and its menu to"
                .. " the bottom-right corner; Off hides the button"
                .. " entirely."),
            sub_item_table_func = function()
                return {
                    optionRow("left",  labels.left),
                    optionRow("right", labels.right),
                    optionRow("off",   labels.off),
                }
            end,
        }
    end)()
    -- In-reader launcher (opt-in, off by default): a small persistent button
    -- in the reader's bottom corner that opens the start menu. Registered at
    -- reader init, so it takes effect the next time a book is opened.
    items[#items + 1] = {
        text = _("Show launcher button while reading"),
        help_text = _("Adds a small Bookshelf button to the bottom corner of"
            .. " the reader that opens the start menu. Takes effect the next"
            .. " time you open a book."),
        checked_func = function()
            return BookshelfSettings.read("reader_launcher_button", false) == true
        end,
        callback = function()
            local on = BookshelfSettings.read("reader_launcher_button", false) == true
            BookshelfSettings.save("reader_launcher_button", not on)
            refreshReaderLauncher()
        end,
    }
    items[#items].separator = true  -- end start menu & reader band

    -- "Hardcover enrichment" was promoted to the top-level Bookshelf menu
    -- (below Manage collections) -- see main.lua addToMainMenu. It no longer
    -- lives under Settings.
    items[#items + 1] = {
        text                = _("Advanced settings"),
        sub_item_table_func = function()
            return self:_advancedSubItems()
        end,
    }
    return items
end

local function _formatCacheTime(ts)
    ts = tonumber(ts)
    if not ts then return _("never") end
    return os.date("%Y-%m-%d %H:%M", ts)
end

function Settings:_hardcoverSubItems()
    local function markDirty(reason)
        pcall(function()
            local Repo = require("lib/bookshelf_book_repository")
            Repo.invalidateBookCache(reason or "hardcover")
            -- Also drop the light-meta cache: Hardcover changes (linking,
            -- "Use Hardcover metadata", auto-link) rewrite the title/author/
            -- series/genre fields the genre/author/series chips group from, so
            -- the chips must rebuild from fresh records, not just the per-chip
            -- result caches invalidateBookCache clears.
            if Repo.invalidateLightMeta then Repo.invalidateLightMeta() end
        end)
        pcall(function()
            require("lib/bookshelf_image_source").invalidateCache()
        end)
        if self._bw and self._bw._rebuild then
            self._bw:_rebuild()
            UIManager:setDirty(self._bw, "ui")
        end
    end

    local function notify(text, timeout)
        UIManager:show(Notification:new{
            text    = text,
            timeout = timeout or 3,
        })
    end

    -- Bulk auto-link: scan the whole library and link any book that carries
    -- an embedded ISBN / Hardcover id -- the single-book "Auto link" applied
    -- across the library. Throttled to ~1 request/second to stay under
    -- Hardcover's 60/min API limit; shows cancellable progress.
    -- Shared driver for the long Hardcover scans (auto-link, refresh). Runs one
    -- item per scheduler tick so the UI event loop keeps running between books:
    -- the progress message stays tappable (cancel works) and nothing freezes,
    -- unlike a blocking loop. Network items are paced by `rate` to respect
    -- Hardcover's ~60/min limit; cheap items just yield a tick.
    --   opts.items     array to walk
    --   opts.rate      seconds between network ticks (default 1.2)
    --   opts.step(item, st) -> did_network   (mutates st counters)
    --   opts.progress(st, total) -> string   progress message text
    --   opts.summary(st, total)  -> string   final message text
    --   opts.on_finish(st)        optional, before the summary shows
    local function runPacedScan(opts)
        local InfoMessage = require("ui/widget/infomessage")
        local items = opts.items
        local total = #items
        local rate  = opts.rate or 1.2
        local st = { i = 0, cancelled = false }
        -- Ignore taps briefly after start: the tap that launched the scan can
        -- bleed onto the freshly-shown progress message and cancel it instantly.
        local armed = false
        UIManager:scheduleIn(0.6, function() armed = true end)
        local info
        -- InfoMessage:onCloseWidget fires dismiss_callback on ANY close, incl.
        -- our own close when swapping in an updated message. Detach before a
        -- programmatic close so only a genuine user dismissal counts as cancel.
        local function closeInfo()
            if info then
                info.dismiss_callback = nil
                UIManager:close(info)
                info = nil
            end
        end
        local function refresh()
            closeInfo()
            info = InfoMessage:new{
                text = opts.progress(st, total),
                dismiss_callback = function()
                    if armed then st.cancelled = true end
                end,
            }
            UIManager:show(info)
        end
        local function finish()
            closeInfo()
            if opts.on_finish then opts.on_finish(st) end
            -- summary is optional: callers that present their own completion UI
            -- (e.g. the auto-link HTML report) omit it.
            if opts.summary then
                UIManager:show(InfoMessage:new{ text = opts.summary(st, total) })
            end
        end
        local step
        step = function()
            if st.cancelled or st.i >= total then return finish() end
            st.i = st.i + 1
            local did_network = opts.step(items[st.i], st)
            if did_network or st.i % 10 == 0 or st.i == total then refresh() end
            if did_network then
                UIManager:scheduleIn(rate, step)
            else
                UIManager:nextTick(step)
            end
        end
        refresh()
        UIManager:nextTick(step)
    end

    local function autoLinkAll(touchmenu_instance)
        local ok_hc, Hardcover = pcall(require, "lib/bookshelf_hardcover")
        if not ok_hc or not Hardcover
                or not (Hardcover.isAvailable and Hardcover.isAvailable()) then
            notify(_("Hardcover plugin is not available"))
            return
        end
        local Repo = require("lib/bookshelf_book_repository")
        local filepaths = Repo.getAllFilepaths() or {}
        -- Pre-filter: drop already-linked books (cheap -- reads the link cache,
        -- no network), so only genuine candidates cost an API call.
        local candidates = {}
        for _i, fp in ipairs(filepaths) do
            if not Hardcover.getLink(fp) then
                candidates[#candidates + 1] = fp
            end
        end
        local total = #candidates
        if total == 0 then
            notify(_("No unlinked books to auto-link."))
            return
        end

        -- ~2 Hardcover calls per processed book (resolve/search, then fetch
        -- details), so pace at ~2.5s/book to stay under the ~60/min API limit.
        local RATE = 2.5
        local est_min = math.max(1, math.ceil(total * RATE / 60))

        -- Display name for the report: prefer the book's title, fall back to a
        -- de-extensioned filename.
        local function nameFor(fp, meta)
            if meta and type(meta.title) == "string" and meta.title ~= "" then
                return meta.title
            end
            return (fp:match("([^/]+)$") or fp):gsub("%.[^%.]+$", "")
        end

        local function showReport(st, best_guess)
            local ok_tok, Tokens = pcall(require, "lib/bookshelf_tokens")
            if not ok_tok or not Tokens or not Tokens.autoLinkReportHtml then return end
            local Screen = require("device").screen
            UIManager:show(require("lib/bookshelf_reviews_modal"):new{
                title     = _("Auto-link report"),
                html_body = Tokens.autoLinkReportHtml{
                    best_guess = best_guess,
                    cancelled  = st.cancelled,
                    linked     = st.linked_list or {},
                    nomatch    = st.nomatch_list or {},
                    no_id      = st.no_id or 0,
                    errors     = st.errors or 0,
                },
                width  = math.floor(Screen:getWidth() * 0.92),
                height = math.floor(Screen:getHeight() * 0.86),
            })
        end

        local function run(best_guess)
            if touchmenu_instance then UIManager:close(touchmenu_instance) end
            runPacedScan{
                items = candidates,
                rate  = RATE,
                step = function(fp, st)
                    st.linked_list  = st.linked_list  or {}
                    st.nomatch_list = st.nomatch_list or {}
                    if best_guess then
                        -- Needs title/author, so build the record first, then
                        -- search Hardcover and score the hits.
                        local meta = (Repo.buildBookMeta and Repo.buildBookMeta(fp))
                                     or { filepath = fp }
                        local ok_call, linked_ok, details =
                            pcall(Hardcover.bestGuessLink, meta)
                        if ok_call and linked_ok then
                            st.linked = (st.linked or 0) + 1
                            pcall(Hardcover.refreshBook, meta, {})
                            local d = type(details) == "table" and details or {}
                            local score
                            if tonumber(d.title_score) and tonumber(d.author_score) then
                                score = math.floor((d.title_score + d.author_score) / 2 + 0.5)
                            end
                            st.linked_list[#st.linked_list + 1] = {
                                name = nameFor(fp, meta), matched = d.title,
                                author = d.author, score = score,
                            }
                        else
                            st.no_match = (st.no_match or 0) + 1
                            st.nomatch_list[#st.nomatch_list + 1] = { name = nameFor(fp, meta) }
                        end
                        return true
                    end
                    -- Exact: embedded ISBN / Hardcover id only.
                    local book = { filepath = fp }
                    local ids = Hardcover.getEmbeddedIdentifiers
                                and Hardcover.getEmbeddedIdentifiers(book)
                    if not ids then
                        st.no_id = (st.no_id or 0) + 1
                        return false  -- no network, next tick immediately
                    end
                    local ok_call, linked_ok, hc =
                        pcall(Hardcover.linkFromEmbeddedIdentifiers, book)
                    if not ok_call then
                        st.errors = (st.errors or 0) + 1
                    elseif linked_ok then
                        st.linked = (st.linked or 0) + 1
                        -- Fetch details + apply the cover/description decision
                        -- now, so the book is fully populated in one pass.
                        local meta = (Repo.buildBookMeta and Repo.buildBookMeta(fp))
                                     or book
                        pcall(Hardcover.refreshBook, meta, {})
                        st.linked_list[#st.linked_list + 1] = {
                            name = nameFor(fp, meta),
                            matched = type(hc) == "table" and hc.title or nil,
                        }
                    else
                        st.no_match = (st.no_match or 0) + 1
                        st.nomatch_list[#st.nomatch_list + 1] = { name = nameFor(fp, book) }
                    end
                    return true
                end,
                progress = function(st, n)
                    return T(_("Auto-linking from Hardcover…\n\n%1 / %2 checked  ·  %3 linked\n\n(tap to cancel)"),
                             tostring(st.i), tostring(n), tostring(st.linked or 0))
                end,
                on_finish = function(st)
                    if (st.linked or 0) > 0 then markDirty("hardcover-auto-link-all") end
                    showReport(st, best_guess)
                end,
            }
        end

        -- Mode picker: exact (embedded id, fast) vs best guess (title/author
        -- full-text search + fuzzy match, slower but catches books with no id).
        local ButtonDialog = require("ui/widget/buttondialog")
        local dialog
        dialog = ButtonDialog:new{
            title = T(_("Auto-link %1 unlinked book(s)?\n\nContacts Hardcover (rate-limited), up to ~%2 min. Cancellable, with a report at the end."),
                      tostring(total), tostring(est_min)),
            title_align = "center",
            buttons = {
                {{
                    text = _("Exact match (ISBN / Hardcover id)"),
                    callback = function() UIManager:close(dialog); run(false) end,
                }},
                {{
                    text = _("Best guess (title & author)"),
                    callback = function() UIManager:close(dialog); run(true) end,
                }},
                {{
                    text = _("Cancel"),
                    callback = function() UIManager:close(dialog) end,
                }},
            },
        }
        UIManager:show(dialog)
    end

    return {
        {
            text_func = function()
                local ok_hc, Hardcover = pcall(require, "lib/bookshelf_hardcover")
                if not ok_hc or not Hardcover or not Hardcover.getCacheStats then
                    return _("Cached Hardcover ratings: unavailable")
                end
                local stats = Hardcover.getCacheStats()
                return string.format(_("Cached Hardcover ratings: %d/%d · %s"),
                    stats.rated or 0,
                    stats.linked or 0,
                    _formatCacheTime(stats.fetched_at))
            end,
            enabled_func = function() return false end,
        },
        {
            -- Primary action: the first thing a new Hardcover user wants is to
            -- link their library, so it sits at the top.
            text = _("Auto-link all books"),
            help_text = _("Scan the library and link books to Hardcover, fetching each match's details (description, cover, rating) in the same pass. Choose Exact match (uses an embedded ISBN / Hardcover id, fast) or Best guess (searches by title and author and picks the most confident match, slower but catches books with no embedded id). A report at the end lists exactly what was linked. Contacts Hardcover (rate-limited) with cancellable progress."),
            enabled_func = function()
                local ok_hc, HC = pcall(require, "lib/bookshelf_hardcover")
                return (ok_hc and HC and HC.isAvailable and HC.isAvailable()) or false
            end,
            callback = function(touchmenu_instance)
                autoLinkAll(touchmenu_instance)
            end,
        },
        {
            text = _("Show Hardcover ratings in hero"),
            help_text = _("When enabled, the Hero rating row shows the cached public Hardcover rating instead of KOReader's local rating. Enabling this also turns on the Hero rating row. Normal Bookshelf rendering only reads the local cache."),
            checked_func = function()
                return BookshelfSettings.isTrue("hardcover_hero_rating")
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local enabled = BookshelfSettings.isTrue("hardcover_hero_rating")
                BookshelfSettings.save("hardcover_hero_rating", not enabled)
                if not enabled then
                    local Regions = require("lib/bookshelf_hero_regions")
                    local regions = Regions.read()
                    if regions.rating and regions.rating.disabled then
                        regions.rating.disabled = false
                        Regions.write("rating", regions.rating)
                    end
                end
                if touchmenu_instance and touchmenu_instance.updateItems then
                    touchmenu_instance:updateItems()
                end
                markDirty("hardcover-rating-toggle")
            end,
        },
        {
            text = _("Use Hardcover metadata"),
            help_text = _("For books linked to Hardcover, show Hardcover's title, author, series and genres in place of the book's own -- a clean switch, no merging. Covers and descriptions stay under their per-book toggles. This affects sorting, search and series grouping for linked books; non-linked books are unaffected. Metadata is always cached, so this only decides whether it's used."),
            checked_func = function()
                return BookshelfSettings.isTrue("hardcover_use_metadata")
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local enabled = BookshelfSettings.isTrue("hardcover_use_metadata")
                BookshelfSettings.save("hardcover_use_metadata", not enabled)
                if touchmenu_instance and touchmenu_instance.updateItems then
                    touchmenu_instance:updateItems()
                end
                markDirty("hardcover-use-metadata")
            end,
        },
        {
            text = _("Download covers from Hardcover"),
            help_text = _("When on, linking a book also downloads its Hardcover cover and stores it as the book's cover. Off by default: most books already have a cover, and downloaded covers use storage and get picked up by the library metadata scan. Descriptions, ratings and metadata are fetched either way; turn this on only if you want Hardcover covers too."),
            checked_func = function()
                return BookshelfSettings.isTrue("hardcover_download_covers")
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local enabled = BookshelfSettings.isTrue("hardcover_download_covers")
                BookshelfSettings.save("hardcover_download_covers", not enabled)
                if touchmenu_instance and touchmenu_instance.updateItems then
                    touchmenu_instance:updateItems()
                end
            end,
        },
        {
            text_func = function()
                local n = tonumber(BookshelfSettings.read("hardcover_max_genres")) or 5
                return T(_("Hardcover genres used: %1"), tostring(n))
            end,
            help_text = _("How many of a linked book's Hardcover genres to use -- for the tag pills and the genre chips/stacks -- when Use Hardcover metadata is on. 0 uses none."),
            enabled_func = function()
                return BookshelfSettings.isTrue("hardcover_use_metadata")
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local SpinWidget = require("ui/widget/spinwidget")
                local cur = tonumber(BookshelfSettings.read("hardcover_max_genres")) or 5
                UIManager:show(SpinWidget:new{
                    title_text     = _("Hardcover genres used"),
                    info_text      = _("How many of a book's Hardcover genres to use for tag pills and the genre chips/stacks."),
                    value          = cur,
                    value_min      = 0,
                    value_max      = 20,
                    value_step     = 1,
                    value_hold_step = 5,
                    ok_text        = _("Set"),
                    callback = function(spin)
                        BookshelfSettings.save("hardcover_max_genres", spin.value)
                        if touchmenu_instance and touchmenu_instance.updateItems then
                            touchmenu_instance:updateItems()
                        end
                        markDirty("hardcover-max-genres")
                    end,
                })
            end,
        },
        {
            -- Maintenance lives one level down: refreshing cached data and
            -- clearing it are occasional housekeeping, not everyday settings.
            text = _("Manage Hardcover data"),
            sub_item_table = {
                {
                    -- Auto-link all books now fetches details as it links, so
                    -- there's no separate "fetch missing data" step. This just
                    -- keeps the public ratings current as they drift on
                    -- Hardcover (one batched query, no per-book covers/text).
                    text = _("Refresh ratings only"),
                    help_text = _("Fetch up-to-date public ratings and review counts for linked Hardcover books. Covers and descriptions are fetched when a book is linked, so this only updates the ratings."),
                    callback = function(touchmenu_instance)
                        if touchmenu_instance then
                            UIManager:close(touchmenu_instance)
                        end
                        UIManager:nextTick(function()
                            local ok_hc, Hardcover = pcall(require, "lib/bookshelf_hardcover")
                            if not ok_hc or not Hardcover or not Hardcover.refreshRatingsOnline then
                                notify(_("Hardcover integration could not be loaded"))
                                return
                            end
                            notify(_("Fetching Hardcover ratings..."), 1)
                            Hardcover.refreshRatingsOnline(function(ok, stats)
                                if not ok then
                                    notify(tostring(stats or _("Hardcover ratings refresh failed")), 5)
                                    return
                                end
                                markDirty("hardcover-ratings-refresh")
                                stats = type(stats) == "table" and stats or {}
                                notify(T(_("Hardcover ratings refreshed: %1 rated of %2 linked books"),
                                         tostring(stats.rated or 0),
                                         tostring(stats.linked or 0)), 4)
                            end)
                        end)
                    end,
                },
                {
                    -- One clear for everything cached. Links are kept, so a
                    -- refresh repopulates afterwards.
                    text = _("Clear cache (keeps links)"),
                    help_text = _("Remove Bookshelf's cached Hardcover descriptions, cover images, ratings, review counts and review text. Existing book links are kept, so you can refresh again later."),
                    callback = function(touchmenu_instance)
                        if touchmenu_instance then
                            UIManager:close(touchmenu_instance)
                        end
                        UIManager:nextTick(function()
                            local ok_hc, Hardcover = pcall(require, "lib/bookshelf_hardcover")
                            if ok_hc and Hardcover then
                                if Hardcover.clearEnrichmentCache then Hardcover.clearEnrichmentCache() end
                                if Hardcover.clearRatingsCache then Hardcover.clearRatingsCache() end
                                if Hardcover.clearReviewsCache then Hardcover.clearReviewsCache() end
                            end
                            markDirty("hardcover-clear-cache")
                            notify(_("Hardcover cache cleared"))
                        end)
                    end,
                },
                {
                    -- Cover-only cleanup (issue #111): reclaim the storage that
                    -- downloaded covers use without unlinking or losing
                    -- descriptions. Restores each book's original cover.
                    text = _("Remove downloaded covers"),
                    help_text = _("Delete every downloaded Hardcover cover and restore each book's original cover, keeping links, descriptions and ratings. Frees the storage the covers use and clears them out of the library metadata scan."),
                    callback = function(touchmenu_instance)
                        local ConfirmBox = require("ui/widget/confirmbox")
                        UIManager:show(ConfirmBox:new{
                            text = _("Remove all downloaded Hardcover covers?\n\nEach book's original cover is restored; links, descriptions and ratings are kept."),
                            ok_text = _("Remove covers"),
                            ok_callback = function()
                                if touchmenu_instance then
                                    UIManager:close(touchmenu_instance)
                                end
                                UIManager:nextTick(function()
                                    local ok_hc, Hardcover = pcall(require, "lib/bookshelf_hardcover")
                                    local n = 0
                                    if ok_hc and Hardcover and Hardcover.removeDownloadedCovers then
                                        local ok_run, res = pcall(Hardcover.removeDownloadedCovers)
                                        if ok_run then n = res or 0 end
                                    end
                                    markDirty("hardcover-remove-covers")
                                    notify(T(_("Removed downloaded covers (%1 book(s))."), tostring(n)))
                                end)
                            end,
                        })
                    end,
                },
                {
                    -- Full reset: unlink everything and undo all changes. Guarded
                    -- by a warning; only Hardcover-installed covers are removed
                    -- and any displaced original cover is put back.
                    text = _("Remove all Hardcover data"),
                    help_text = _("Unlink every book and delete all cached Hardcover descriptions, covers, ratings and reviews, resetting the library to how it was before any Hardcover linking. Only covers Hardcover added are removed; a cover you had before is restored. Cannot be undone."),
                    callback = function(touchmenu_instance)
                        local ConfirmBox = require("ui/widget/confirmbox")
                        UIManager:show(ConfirmBox:new{
                            text = _("Remove ALL Hardcover data?\n\nThis unlinks every book and deletes all cached Hardcover covers, descriptions, ratings and reviews. Covers Hardcover saved into book folders are removed and any cover you had before is put back.\n\nThis cannot be undone."),
                            ok_text = _("Remove all"),
                            ok_callback = function()
                                if touchmenu_instance then
                                    UIManager:close(touchmenu_instance)
                                end
                                UIManager:nextTick(function()
                                    local ok_hc, Hardcover = pcall(require, "lib/bookshelf_hardcover")
                                    local n = 0
                                    if ok_hc and Hardcover and Hardcover.removeAllData then
                                        local ok_run, res = pcall(Hardcover.removeAllData)
                                        if ok_run then n = res or 0 end
                                    end
                                    markDirty("hardcover-remove-all")
                                    notify(T(_("All Hardcover data removed (%1 book(s) unlinked)."),
                                             tostring(n)))
                                end)
                            end,
                        })
                    end,
                },
            },
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
        return "none"
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
    -- What a tap on a book in the expanded shelf does. Defaults (via
    -- expandedTapAction) honour the legacy tap_to_open_double toggle so
    -- existing users keep their behaviour; that toggle still governs the
    -- hero-card double-tap separately.
    local tap_labels = {
        show_detail = _("Show book detail in hero"),
        open        = _("Open with a single tap"),
        open_double = _("Open with a double tap"),
    }
    local function tapRow(action, label)
        return {
            text           = label,
            checked_func   = function() return BookshelfSettings.expandedTapAction() == action end,
            radio          = true,
            keep_menu_open = true,
            callback       = function(touchmenu_instance)
                BookshelfSettings.save("expanded_tap_action", action)
                BookshelfSettings.flush()
                -- Clear any pending tap-selection so switching mid-session
                -- doesn't leave a stale focus ring.
                if self._bw then self._bw._tap_selected_fp = nil end
                if touchmenu_instance and touchmenu_instance.updateItems then
                    touchmenu_instance:updateItems()
                end
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
                return _("Tap a book") .. ": " .. tap_labels[BookshelfSettings.expandedTapAction()]
            end,
            help_text = _("What tapping a book does in the expanded shelf: show"
                .. " that book's detail in the hero area, open it with a single"
                .. " tap, or open it with a double tap (first tap selects). The"
                .. " hero card's own double-tap-to-open is set in Advanced settings."),
            sub_item_table_func = function()
                return {
                    tapRow("show_detail", tap_labels.show_detail),
                    tapRow("open",        tap_labels.open),
                    tapRow("open_double", tap_labels.open_double),
                }
            end,
        },
        -- Expanded-shelf label font scale moved to
        -- Settings -> Text size (#60).
    }
end

-- Nudge dialog for the expanded-shelf label font scale. Same shape as
-- _pickFontScale; live preview kicks the live widget's _rebuild.
function Settings:_pickExpandedShelfFontScale(touchmenu_instance)
    local ButtonDialog = require("ui/widget/buttondialog")
    local key = "expanded_shelf_font_scale"
    local original = BookshelfSettings.read(key, 100)
    -- See _pickCoverBadgeFontScale for the hide+restore rationale.
    local restoreMenu = self._plugin:hideMenu(touchmenu_instance)

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
        Focus.reinit(dialog)
    end
    local function close() UIManager:close(dialog); restoreMenu() end
    local function revert() setValue(original); rebuild() end

    dialog = ButtonDialog:new{
        dismissable = false,  -- nudge-dialog lockdown; see _pickCoverBadgeFontScale
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
                  callback = function() setValue(100); rebuild(); Focus.reinit(dialog) end },
                { text = _("Apply"), is_enter_default = true, callback = close },
            },
        },
        tap_close_callback = revert,
    }
    if dialog.movable then dialog.movable.ges_events = {} end
    UIManager:show(dialog)
end

-- Factored out from main.lua so it can be referenced via the new Settings
-- parent menu. Behaviour is identical to the previous inline definition.
-- Performance levers, grouped under one "Performance tweaks" submenu so the
-- Advanced menu stays scannable.
function Settings:_performanceSubItems()
    return {
        {
            text = _("Pre-warm chip cache"),
            help_text = _("Warms each chip's data in the background shortly"
                .. " after launch so switching chips is instant. On a large"
                .. " library with many chips this adds a few seconds of work"
                .. " after startup; turn it off for a quicker, lighter launch"
                .. " (chips then load on first use)."),
            checked_func = function()
                return BookshelfSettings.nilOrTrue("prewarm_chip_cache")
            end,
            callback = function()
                local on = BookshelfSettings.nilOrTrue("prewarm_chip_cache")
                BookshelfSettings.save("prewarm_chip_cache", not on)
                BookshelfSettings.flush()
            end,
        },
        {
            text     = _('"Latest" walk depth'),
            callback = function() self:_pickLatestDepth() end,
        },
        {
            text_func = function()
                return _("Cover cache") .. ": "
                    .. tostring(BookshelfSettings.read("cover_cache_mb") or 24)
                    .. " MB"
            end,
            help_text = _("How much memory to use for ready-scaled book covers. "
                .. "A bigger cache keeps more covers warm -- smoother paging and "
                .. "preloading -- at the cost of RAM. Default 24 MB. Lower it if "
                .. "memory is tight; raise it on a device with plenty of RAM. "
                .. "(How many covers that holds depends on their size: roughly "
                .. "200-400 small grayscale covers, fewer large or colour ones.)"),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:_pickCoverCacheBudget(touchmenu_instance)
            end,
        },
        {
            text = _("Clear cover cache"),
            help_text = _("Drop all cached scaled covers from memory. "
                .. "Use this when a book's cover has been updated outside "
                .. "KOReader (e.g. a metadata-enrichment tool rewrote the "
                .. "EPUB) and the old cover is still showing on the shelf. "
                .. "The next render fetches fresh covers from the EPUBs. "
                .. "Restarting KOReader has the same effect."),
            keep_menu_open = true,
            callback = function()
                local ScaledCoverCache = require("lib/bookshelf_scaled_cover_cache")
                ScaledCoverCache:clear()
                UIManager:show(Notification:new{
                    text    = _("Cover cache cleared"),
                    timeout = 2,
                })
            end,
        },
    }
end

function Settings:_advancedSubItems()
    local plugin = self._plugin
    local items = {
        -- ── library & metadata ──
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
            text_func = function()
                local v = BookshelfSettings.read("author_format") or "auto"
                local label = ({ auto = _("Auto"),
                                 first_last = _("First Last"),
                                 last_first = _("Last, First") })[v]
                                 or _("Auto")
                return _("Author name formatting") .. ": " .. label
            end,
            help_text = _("How author names are displayed on the Authors"
                .. " chip. Auto keeps whichever form was first found"
                .. " (\"Richard Osman\" or \"Osman, Richard\"). First Last"
                .. " and Last, First force every author card into the same"
                .. " shape regardless of how each book stored the name."),
            keep_menu_open = true,
            sub_item_table_func = function()
                local function row(label, value)
                    return {
                        text = label,
                        checked_func = function()
                            local v = BookshelfSettings.read("author_format") or "auto"
                            return v == value
                        end,
                        callback = function()
                            BookshelfSettings.save("author_format", value)
                            BookshelfSettings.flush()
                            local Repo = require("lib/bookshelf_book_repository")
                            if Repo.invalidateSeriesCache then
                                Repo.invalidateSeriesCache()
                            end
                            if self._bw and self._bw._rebuild then
                                self._bw:_rebuild()
                                UIManager:setDirty(self._bw, "ui")
                            end
                        end,
                    }
                end
                return {
                    row(_("Auto"),         "auto"),
                    row(_("First Last"),   "first_last"),
                    row(_("Last, First"),  "last_first"),
                }
            end,
        },
        {
            text = _("Hide single-book series and genres"),
            help_text = _("When a series or genre contains only one book, hide"
                .. " it from the Series and Genres tabs. Useful when a book"
                .. " carries a one-off series name, or its own title as the"
                .. " series. Off by default."),
            checked_func = function()
                return BookshelfSettings.isTrue("hide_single_book_stacks")
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local on = BookshelfSettings.isTrue("hide_single_book_stacks")
                BookshelfSettings.save("hide_single_book_stacks", not on)
                BookshelfSettings.flush()
                -- Rebuild the series/genre group shapes from scratch. The
                -- filter is read-time, but a warm cache can hold shapes built
                -- by the background chip-preload before the library walk
                -- finished -- a multi-book series caught mid-walk is cached as
                -- a one-book shape, which the toggle would then wrongly hide.
                -- Invalidating forces a complete, correct rebuild on toggle.
                local Repo = require("lib/bookshelf_book_repository")
                if Repo.invalidateSeriesCache then Repo.invalidateSeriesCache() end
                if touchmenu_instance and touchmenu_instance.updateItems then
                    touchmenu_instance:updateItems()
                end
                if self._bw and self._bw._rebuild then
                    self._bw:_rebuild()
                    UIManager:setDirty(self._bw, "ui")
                end
            end,
        },
        {
            text = _("Include folder names in search results"),
            help_text = _("When searching, also match the names of folders in"
                .. " your library and list them as folder results. Off by"
                .. " default: most libraries file books into author, series or"
                .. " genre folders, so a matching folder just duplicates the"
                .. " author / series / genre result of the same name. Turn on"
                .. " if you navigate by folder and want folders in search."),
            checked_func   = function()
                return BookshelfSettings.read("search_include_folders") == true
            end,
            keep_menu_open = true,
            callback = function()
                local enabled = BookshelfSettings.read("search_include_folders") == true
                BookshelfSettings.save("search_include_folders", not enabled)
                BookshelfSettings.flush()
            end,
        },
        {
            text = _("Sort Chinese text by pinyin"),
            help_text = _("Sorts Chinese characters by their Mandarin "
                .. "pinyin reading, so Chinese titles and authors file "
                .. "alphabetically alongside Latin names. When off, "
                .. "Chinese text sorts in Unicode order (roughly by "
                .. "radical and stroke count), after Latin names. "
                .. "Japanese kanji are also affected, so leave this off "
                .. "for Japanese-language libraries."),
            checked_func   = function()
                return BookshelfSettings.read("cjk_pinyin_sort") == true
            end,
            keep_menu_open = true,
            callback = function()
                local enabled = BookshelfSettings.read("cjk_pinyin_sort") == true
                BookshelfSettings.save("cjk_pinyin_sort", not enabled)
                -- No explicit cache invalidation needed: the save bumps the
                -- settings generation, and the sort engine re-reads the flag
                -- (and epoch-invalidates its per-record keys) on the next
                -- sort. The rebuild below triggers that sort.
                if self._bw and self._bw._rebuild then
                    self._bw:_rebuild()
                    UIManager:setDirty(self._bw, "ui")
                end
            end,
        },
        {
            text_func = function()
                local ImageSource = require("lib/bookshelf_image_source")
                local p = ImageSource.getImageLibraryPath()
                local short = p
                if type(p) == "string" then
                    -- Show just the last two segments so the row
                    -- doesn't truncate; settings menus are narrow.
                    short = p:match("([^/]+/[^/]+/?)$") or p
                end
                return _("Image library") .. ": " .. (short or _("(none)"))
            end,
            keep_menu_open = true,
            help_text = _("Where Bookshelf looks for custom cover images. For stacks, place files like authors/author-name.jpg into the matching subfolder (authors, series, genres, collections). For folders, drop a cover.jpg into the folder itself. See the README for more matching options."),
            callback = function(touchmenu_instance)
                self:_pickImageLibraryPath(touchmenu_instance)
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
            -- End the library & metadata band.
            separator = true,
        },
        {
            text = _("Double tap to open books"),
            help_text = _("When enabled, opening a book from the hero "
                .. "card or from a shelf cover in expanded mode requires "
                .. "two taps -- the first selects the cover (focus "
                .. "ring), the second commits. Useful if you tend to "
                .. "open books accidentally while browsing. Regular "
                .. "shelf covers (with the hero visible) already work "
                .. "this way -- tap stages the book as the hero "
                .. "preview, tap the hero opens it -- and are "
                .. "unaffected by this setting."),
            checked_func   = function()
                return BookshelfSettings.isTrue("tap_to_open_double")
            end,
            keep_menu_open = true,
            callback = function()
                local enabled = BookshelfSettings.isTrue("tap_to_open_double")
                BookshelfSettings.save("tap_to_open_double", not enabled)
                BookshelfSettings.flush()
                -- Clear any pending tap-selection on the live widget so
                -- toggling the setting off mid-session doesn't leave a
                -- stale focus ring on the hero / shelf cover.
                if self._bw then self._bw._tap_selected_fp = nil end
            end,
        },
        {
            text_func = function()
                local v = BookshelfSettings.read("shelf_page_animation") or "medium"
                local label = ({ off    = _("Off"),
                                 fast   = _("Fast"),
                                 medium = _("Medium"),
                                 slow   = _("Slow") })[v] or _("Medium")
                return _("Page turn animation") .. ": " .. label
            end,
            help_text = _("Animate shelf page turns with a page-wipe effect: "
                .. "the new page sweeps in from the side. E-ink only (the "
                .. "effect relies on the panel's refresh, so it does nothing "
                .. "on LCD screens). Fast / Medium / Slow trade snappiness for "
                .. "smoothness. Slow looks smoothest but takes longer on "
                .. "older panels."),
            keep_menu_open = true,
            sub_item_table_func = function()
                local function row(label, value)
                    return {
                        text = label,
                        radio = true,
                        checked_func = function()
                            local v = BookshelfSettings.read("shelf_page_animation") or "medium"
                            return v == value
                        end,
                        callback = function()
                            BookshelfSettings.save("shelf_page_animation", value)
                            BookshelfSettings.flush()
                        end,
                    }
                end
                return {
                    row(_("Off"),    "off"),
                    row(_("Fast"),   "fast"),
                    row(_("Medium"), "medium"),
                    row(_("Slow"),   "slow"),
                }
            end,
        },
        {
            text = _("Closing book notification"),
            help_text = _("Show a 'Closing book…' message in the centre "
                .. "of the screen while a book is being closed back to "
                .. "Bookshelf. The book-close work takes a moment, so "
                .. "the message confirms your gesture landed during the "
                .. "wait. Some users on color e-ink panels see a brief "
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
            -- End the reading behaviour band.
            separator = true,
        },
        {
            text                = _("Performance tweaks"),
            sub_item_table_func = function()
                return self:_performanceSubItems()
            end,
            -- End the performance band (before the resets).
            separator = true,
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
                .. "colors) are unaffected."),
            callback = function(touchmenu_instance)
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text = _("Reset the chip bar to default settings?\n\n"
                        .. "All custom chips you have created or edited "
                        .. "will be lost. Other Bookshelf settings (hero "
                        .. "text, fonts, colors) are unaffected."),
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
            text     = _("Reset book detail area to defaults"),
            help_text = _("Clears your hero/book-detail customizations and "
                .. "restores the fresh-install detail layout, including the "
                .. "bundled title (Inter ExtraBold) and author (Caveat) fonts. "
                .. "The Bookshelf UI font and chip bar are unaffected."),
            callback = function(touchmenu_instance)
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text = _("Reset the book detail area to default settings?\n\n"
                        .. "All hero/detail text and font customizations will be "
                        .. "lost. The Bookshelf UI font and chip bar are unaffected."),
                    ok_text = _("Reset"),
                    ok_callback = function()
                        local Regions = require("lib/bookshelf_hero_regions")
                        Regions.applyFreshInstallDefaults()
                        BookshelfSettings.flush()
                        if touchmenu_instance then UIManager:close(touchmenu_instance) end
                        if self._bw and self._bw._rebuild then
                            self._bw:_rebuild()
                            UIManager:setDirty(self._bw, "ui")
                        end
                    end,
                })
            end,
        },
    }

    -- Kobo virtual-library shelf (beta). Always listed (like the calibre beta
    -- toggle) so Kobo users can reliably find and enable it -- on non-Kobo
    -- devices the option simply does nothing, because the "Kobo" chip is
    -- separately gated on this setting AND KoboSource.isAvailable() (false
    -- off-Kobo). Toggling rebuilds so the chip appears/disappears immediately.
    items[#items + 1] = {
        text = _("BETA: Kobo library shelf"),
        help_text = _("Adds a \"Kobo\" chip that surfaces your Kobo "
            .. "virtual library (the books managed by the Kobo store / "
            .. "OGKevin's kobo.koplugin) as a Bookshelf shelf. Read-only; "
            .. "covers and opening depend on that plugin. Kobo devices only."),
        checked_func = function()
            return BookshelfSettings.read("kobo_shelf") == true
        end,
        keep_menu_open = true,
        callback = function()
            local enabled = BookshelfSettings.read("kobo_shelf") == true
            BookshelfSettings.save("kobo_shelf", not enabled)
            if self._bw and self._bw._rebuild then
                self._bw:_rebuild()
                UIManager:setDirty(self._bw, "ui")
            end
        end,
    }
    return items
end

--- @param extra_button table|nil  Optional shortcut button rendered between
---   Default and Apply, shape `{ text = string, value = number }`. When tapped,
---   the dialog sets `value` to the supplied number, fires on_change, then
---   closes -- matching the one-tap-commit feel of the color picker's White
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
        Focus.reinit(dialog)
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
                        value = default_val; on_change(value); Focus.reinit(dialog)
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
    if dialog.movable then dialog.movable.ges_events = {} end
    UIManager:show(dialog)
end

-- Tiny centred dialog that lets the user cycle through cover size and
-- hero size with the bookshelf visible behind. Each cycle saves the new
-- value in-memory and rebuilds the widget so the preview is realtime;
-- Cancel restores the snapshot, Accept commits to disk. Closing either
-- way restores the touchmenu the user came from.
function Settings:_openLayoutEditor(touchmenu_instance)
    local ButtonDialog = require("ui/widget/buttondialog")

    local bw = self._bw
    -- Snapshot the stored values (may be nil = legacy/unset) so Cancel can
    -- restore the exact prior state, including "never set".
    local original_columns = BookshelfSettings.read("bookshelf_columns")
    local original_rows    = BookshelfSettings.read("bookshelf_rows")

    local restoreMenu = self._plugin:hideMenu(touchmenu_instance)

    -- Effective current grid, reading through the widget so an unset (legacy)
    -- value still shows the real column/row count being rendered.
    local function curCols()
        return (bw and bw._nCols and bw:_nCols()) or 4
    end
    local function curRows()
        return (bw and bw._baseShelves and bw:_baseShelves()) or 2
    end
    local function maxRows()
        return (bw and bw._maxShelfRows and bw:_maxShelfRows()) or 6
    end
    local COLS_MIN, COLS_MAX = 2, 6

    local function rebuild()
        if bw and bw._rebuild then
            bw:_rebuild()
            UIManager:setDirty(bw, "ui")
        end
    end

    local dialog
    local function nudgeCols(delta)
        local v = math.max(COLS_MIN, math.min(COLS_MAX, curCols() + delta))
        BookshelfSettings.save("bookshelf_columns", v)
        rebuild()
        Focus.reinit(dialog)
    end
    local function nudgeRows(delta)
        local v = math.max(1, math.min(maxRows(), curRows() + delta))
        BookshelfSettings.save("bookshelf_rows", v)
        rebuild()
        Focus.reinit(dialog)
    end
    local function restore(key, val)
        if val == nil then
            BookshelfSettings.delete(key)
        else
            BookshelfSettings.save(key, val)
        end
    end
    local function close()
        UIManager:close(dialog)
        restoreMenu()
    end
    local function cancel()
        restore("bookshelf_columns", original_columns)
        restore("bookshelf_rows", original_rows)
        rebuild()
        close()
    end
    local function accept()
        BookshelfSettings.flush()
        close()
    end

    dialog = ButtonDialog:new{
        dismissable = false,  -- explicit Cancel/Accept; tap-outside disabled
        title = _("Edit shelf size"),
        width_factor = 0.6,

        buttons = {
            {
                { text = "−", callback = function() nudgeCols(-1) end },
                { text_func = function() return _("Columns: ") .. curCols() end,
                  enabled = false },
                { text = "+", callback = function() nudgeCols(1) end },
            },
            {
                { text = "−", callback = function() nudgeRows(-1) end },
                { text_func = function() return _("Rows: ") .. curRows() end,
                  enabled = false },
                { text = "+", callback = function() nudgeRows(1) end },
            },
            {
                { text = _("Cancel"), callback = cancel },
                { text = _("Accept"), is_enter_default = true, callback = accept },
            },
        },
        tap_close_callback = cancel,
    }
    if dialog.movable then dialog.movable.ges_events = {} end
    UIManager:show(dialog)
end

-- Bookends-style nudge dialog for the hero font scale. Each tap on -/+ saves
-- the new scale, kicks the live BookshelfWidget rebuild, and refreshes the
-- dialog so the value updates. Cancel reverts to the snapshot taken on open;
-- Default resets to 100; Apply commits and closes.
function Settings:_pickFontScale(touchmenu_instance)
    local ButtonDialog = require("ui/widget/buttondialog")
    local key = "font_scale"
    local original = BookshelfSettings.read(key, 100)
    -- See _pickCoverBadgeFontScale for the hide+restore rationale.
    local restoreMenu = self._plugin:hideMenu(touchmenu_instance)

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
        if touchmenu_instance and touchmenu_instance.updateItems then
            touchmenu_instance:updateItems()
        end
    end

    local dialog
    local function nudge(delta)
        setValue(getValue() + delta)
        rebuild()
        Focus.reinit(dialog)
    end
    local function close()
        UIManager:close(dialog)
        restoreMenu()
    end
    local function revert()
        setValue(original)
        rebuild()
    end

    dialog = ButtonDialog:new{
        dismissable = false,  -- nudge-dialog lockdown; see _pickCoverBadgeFontScale
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
                  callback = function() setValue(100); rebuild(); Focus.reinit(dialog) end },
                { text = _("Apply"), is_enter_default = true, callback = close },
            },
        },
        tap_close_callback = revert,
    }
    if dialog.movable then dialog.movable.ges_events = {} end
    UIManager:show(dialog)
end

-- Hero micro-modules size knob (issue #180). Same nudge-dialog shape as
-- _pickFontScale, but a SEPARATE key so the micro-module grid scales
-- independently of the currently-reading card / status line. It's a multiplier
-- on each module's cell auto-fit (100 = unchanged), so lower renders the modules
-- smaller with more whitespace. Live preview = the bookshelf rebuild behind.
function Settings:_pickHeroModuleFontScale(touchmenu_instance)
    local ButtonDialog = require("ui/widget/buttondialog")
    local key = "hero_module_font_scale"
    local original = BookshelfSettings.read(key, 100)
    local restoreMenu = self._plugin:hideMenu(touchmenu_instance)

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
        if touchmenu_instance and touchmenu_instance.updateItems then
            touchmenu_instance:updateItems()
        end
    end

    local dialog
    local function nudge(delta)
        setValue(getValue() + delta)
        rebuild()
        Focus.reinit(dialog)
    end
    local function close()
        UIManager:close(dialog)
        restoreMenu()
    end
    local function revert()
        setValue(original)
        rebuild()
    end

    dialog = ButtonDialog:new{
        dismissable = false,
        title = _("Hero micro-modules font scale"),
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
                  callback = function() setValue(100); rebuild(); Focus.reinit(dialog) end },
                { text = _("Apply"), is_enter_default = true, callback = close },
            },
        },
        tap_close_callback = revert,
    }
    if dialog.movable then dialog.movable.ges_events = {} end
    UIManager:show(dialog)
end

-- Bookends-style nudge dialog for the chip-strip font scale. Same shape as
-- _pickFontScale but lives in its own method so the live preview only kicks
-- the rebuild path bookshelf needs and the +/- step sizes can match the
-- user's preferred resolution (1 / 10 here vs 5 / 10 for hero text).
function Settings:_pickChipFontScale(touchmenu_instance)
    local ButtonDialog = require("ui/widget/buttondialog")
    local key = "chip_font_scale"
    local original = BookshelfSettings.read(key, 100)
    -- See _pickCoverBadgeFontScale for the hide+restore rationale.
    local restoreMenu = self._plugin:hideMenu(touchmenu_instance)

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
        Focus.reinit(dialog)
    end
    local function close() UIManager:close(dialog); restoreMenu() end
    local function revert()
        setValue(original)
        rebuild()
    end

    dialog = ButtonDialog:new{
        dismissable = false,  -- nudge-dialog lockdown; see _pickCoverBadgeFontScale
        title = _("Chip bar font scale"),
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
                  callback = function() setValue(100); rebuild(); Focus.reinit(dialog) end },
                { text = _("Apply"), is_enter_default = true, callback = close },
            },
        },
        tap_close_callback = revert,
    }
    if dialog.movable then dialog.movable.ges_events = {} end
    UIManager:show(dialog)
end

-- Nudge dialog for the stack & folder cardboard-label font scale --
-- Series / Author / Genre / Tag stack names and folder card names
-- (FolderCard.build, lib/bookshelf_folder_card.lua). Same shape as
-- the other pick functions; 50-300% range so users with very long
-- Genre / Tag strings (issue #60) can fit more text per card.
function Settings:_pickStackLabelFontScale(touchmenu_instance)
    local ButtonDialog = require("ui/widget/buttondialog")
    local key = "stack_label_font_scale"
    local original = BookshelfSettings.read(key, 100)
    -- See _pickCoverBadgeFontScale for the hide+restore rationale.
    local restoreMenu = self._plugin:hideMenu(touchmenu_instance)

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
        Focus.reinit(dialog)
    end
    local function close() UIManager:close(dialog); restoreMenu() end
    local function revert()
        setValue(original)
        rebuild()
    end

    dialog = ButtonDialog:new{
        dismissable = false,  -- nudge-dialog lockdown; see _pickCoverBadgeFontScale
        title = _("Stack & folder label scale"),
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
                  callback = function() setValue(100); rebuild(); Focus.reinit(dialog) end },
                { text = _("Apply"), is_enter_default = true, callback = close },
            },
        },
        tap_close_callback = revert,
    }
    if dialog.movable then dialog.movable.ges_events = {} end
    UIManager:show(dialog)
end

function Settings:_pickStartMenuFontScale(touchmenu_instance)
    local ButtonDialog = require("ui/widget/buttondialog")
    local StartMenu    = require("lib/bookshelf_start_menu")
    local key = "start_menu_font_scale"
    local original = BookshelfSettings.read(key, 100)
    local restoreMenu = self._plugin:hideMenu(touchmenu_instance)

    -- Open the start menu as a live preview (same approach as the hero scale
    -- picker showing the bookshelf behind the dialog). Only open if one is
    -- not already visible; track whether we opened it so close() can shut it.
    local opened_preview = false
    if self._bw and not StartMenu._live then
        self._bw:_openStartMenu()
        opened_preview = true
    end

    local function getValue() return BookshelfSettings.read(key, 100) end
    local function setValue(v)
        v = math.max(50, math.min(200, v))
        BookshelfSettings.save(key, v)
    end
    local function refreshPreview()
        if StartMenu._live then StartMenu._live:_reload() end
    end

    local dialog
    local function applyReinit()
        Focus.reinit(dialog)
        if dialog.movable then dialog.movable.ges_events = {} end
        UIManager:setDirty(dialog, "ui")
    end
    local function nudge(delta)
        setValue(getValue() + delta)
        refreshPreview()
        applyReinit()
    end
    local function close()
        if opened_preview and StartMenu._live then
            StartMenu._live:_close()
        end
        UIManager:close(dialog)
        restoreMenu()
    end
    local function revert()
        setValue(original)
        refreshPreview()
    end

    dialog = ButtonDialog:new{
        dismissable = false,
        title = _("Start menu font scale"),
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
                  callback = function() setValue(100); refreshPreview(); applyReinit() end },
                { text = _("Apply"), is_enter_default = true, callback = close },
            },
        },
        tap_close_callback = revert,
    }
    if dialog.movable then dialog.movable.ges_events = {} end
    UIManager:show(dialog)
end

-- Nudge dialog for the book-detail popup's tab bar (Edit/Description/
-- Reviews/Tags) label font scale. Same shape as _pickChipFontScale, but no
-- live-rebuild call: the popup is per-book and not open while in Settings,
-- so there's nothing on-screen to preview -- just persist and let the touch
-- menu row's own label refresh.
function Settings:_pickModalTabFontScale(touchmenu_instance)
    local ButtonDialog = require("ui/widget/buttondialog")
    local ReviewsModal = require("lib/bookshelf_reviews_modal")
    local key = "modal_tab_font_scale"
    local original = BookshelfSettings.read(key, 100)
    -- See _pickCoverBadgeFontScale for the hide+restore rationale.
    local restoreMenu = self._plugin:hideMenu(touchmenu_instance)

    local function getValue() return BookshelfSettings.read(key, 100) end
    local function setValue(v)
        v = math.max(50, math.min(200, v))
        BookshelfSettings.save(key, v)
    end
    local function refresh()
        -- Live preview: if the book-detail popup is open (this setting is
        -- normally tuned with it open, watching the tab strip), rebuild its
        -- tab strip at the new label size in place. Only that strip changes.
        local live = ReviewsModal._live
        if live and not live._dismissed and live.refreshTabBar then
            live:refreshTabBar()
        end
        -- Every font-scale picker here dirties a real on-screen widget in its
        -- nudge callback; the one that didn't (this one, originally) stalled
        -- the e-ink refresh pipeline and taps stopped registering (confirmed
        -- on-device). The shelf rebuild is the proven repaint -- kept even
        -- though this setting doesn't change the shelf itself.
        if self._bw and self._bw._rebuild then
            self._bw:_rebuild()
            UIManager:setDirty(self._bw, "ui")
        end
        if touchmenu_instance and touchmenu_instance.updateItems then
            touchmenu_instance:updateItems()
        end
    end

    local dialog
    -- ButtonDialog:reinit() is free()+init(), and init() unconditionally
    -- rebuilds self.movable as a FRESH MovableContainer with its default
    -- drag/hold/pan gestures -- discarding the lockdown below. Without
    -- re-clearing it here, the second nudge's Focus.reinit() silently
    -- restores dragging, and a tap on the closely-packed -/+ buttons that
    -- lingers a touch too long gets claimed by the movable's hold/pan
    -- handling instead of the button, wedging the touch state machine
    -- (confirmed on-device: a detected tap with no callback firing, then
    -- all further input going quiet).
    local function reinitLocked()
        Focus.reinit(dialog)
        if dialog.movable then dialog.movable.ges_events = {} end
    end
    local function nudge(delta)
        setValue(getValue() + delta)
        refresh()
        reinitLocked()
    end
    local function close() UIManager:close(dialog); restoreMenu() end
    local function revert()
        setValue(original)
        refresh()
    end

    dialog = ButtonDialog:new{
        dismissable = false,  -- nudge-dialog lockdown; see _pickCoverBadgeFontScale
        title = _("Modal tab label font scale"),
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
                  callback = function() setValue(100); refresh(); reinitLocked() end },
                { text = _("Apply"), is_enter_default = true, callback = close },
            },
        },
        tap_close_callback = revert,
    }
    if dialog.movable then dialog.movable.ges_events = {} end
    UIManager:show(dialog)
end

-- Bookshelf UI font picker -- reuses the hero line editor's font picker
-- (bookends-rich preview when available, FontList file picker otherwise).
-- Applies on tap: the chosen font is saved and the live bookshelf rebuilt
-- immediately. "(Default)" in the picker clears the setting -> follow KOReader.
function Settings:_pickBookshelfUIFont(touchmenu_instance)
    local Fonts      = require("lib/bookshelf_fonts")
    local LineEditor = require("lib/bookshelf_hero_line_editor")
    LineEditor.showFontPicker(Fonts.getUIFontFace(), nil, function(face)
        Fonts.setUIFontFace(face)            -- face is a resolvable path, or nil = follow
        if self._bw and self._bw._rebuild then
            self._bw:_rebuild()
            UIManager:setDirty(self._bw, "ui")
        end
        -- Refresh the menu row's text_func so "Bookshelf UI font: X" updates
        -- without leaving and re-entering the menu (the pick is async).
        if touchmenu_instance and touchmenu_instance.updateItems then
            touchmenu_instance:updateItems()
        end
    end)
end

-- _textSizeSubItems() -- single home for every font-scale knob in the
-- plugin (issue #60). Pre-#60 these were scattered: Hero in Edit hero
-- card, Cover badges in Cover display, Expanded shelf labels in
-- Expanded shelf, Chip bar in Tabs..., and stack/folder labels weren't
-- configurable at all. Bringing them under one Settings menu makes the
-- "where do I dial X smaller?" question single-answer.
function Settings:_textSizeSubItems()
    -- Labels are pre-translated at call time (each menu open). Going
    -- through `row(_("..."), ...)` instead of `row("...", ...)` so
    -- xgettext sees the literal strings -- dynamic `_(label_key)` in
    -- text_func would not be picked up by extraction.
    local function row(label, setting_key, default, pick_fn)
        return {
            text_func = function()
                local v = BookshelfSettings.read(setting_key, default)
                return label .. ": " .. tostring(v) .. "%"
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self[pick_fn](self, touchmenu_instance)
            end,
        }
    end
    -- Prefix the two hero rows with their chip glyphs so they read as a pair and
    -- map onto the on-screen chips: open-book (U+E7BD) = currently-reading hero,
    -- view-grid (U+EC6F) = micro-module hero. Glyphs render via KOReader's
    -- symbols-font fallback, same as the chips.
    local HERO_BOOK = "\xEE\x9E\xBD  "
    local HERO_GRID = "\xEE\xB1\xAF  "
    return {
        row(HERO_BOOK .. _("Hero card"),         "font_scale",             100, "_pickFontScale"),
        row(HERO_GRID .. _("Hero micro-modules"),"hero_module_font_scale", 100, "_pickHeroModuleFontScale"),
        row(_("Chip bar"),              "chip_font_scale",           100, "_pickChipFontScale"),
        row(_("Stack & folder labels"), "stack_label_font_scale",    100, "_pickStackLabelFontScale"),
        row(_("Expanded shelf labels"), "expanded_shelf_font_scale", 100, "_pickExpandedShelfFontScale"),
        row(_("Cover badges"),          "cover_badge_font_scale",    100, "_pickCoverBadgeFontScale"),
        row(_("Start menu"),            "start_menu_font_scale",     100, "_pickStartMenuFontScale"),
        row(_("Modal tabs"),            "modal_tab_font_scale",      100, "_pickModalTabFontScale"),
    }
end

-- _pickImageLibraryPath() -- folder picker for the image-library root
-- (#70 extension). Resolution: inside that folder bookshelf looks for
-- <kind>s/<name>.<ext> when rendering author / series / genre / tag
-- stacks. Default lives at <home_dir>/.bookshelf-images; the picker
-- defaults to that location so users converging on the default get a
-- one-tap setup. A long-press confirms the current folder per
-- PathChooser's UX.
function Settings:_pickImageLibraryPath(touchmenu_instance)
    local PathChooser = require("ui/widget/pathchooser")
    local ImageSource = require("lib/bookshelf_image_source")
    local start_path = ImageSource.getImageLibraryPath()
        or G_reader_settings:readSetting("home_dir") or "/"
    UIManager:show(PathChooser:new{
        title            = _("Choose image library folder"),
        path             = start_path,
        select_directory = true,
        select_file      = false,
        show_files       = false,
        onConfirm        = function(folder)
            ImageSource.setImageLibraryPath(folder)
            ImageSource.invalidateCache()
            if Settings._bw and Settings._bw._rebuild then
                Settings._bw:_rebuild()
                UIManager:setDirty(Settings._bw, "ui")
            end
            if touchmenu_instance and touchmenu_instance.updateItems then
                touchmenu_instance:updateItems()
            end
        end,
    })
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

function Settings:_pickCoverCacheBudget(touchmenu_instance)
    local current = BookshelfSettings.read("cover_cache_mb") or 24
    UIManager:show(SpinWidget:new{
        value      = current,
        value_min  = 8,
        value_max  = 128,
        value_step = 8,
        default_value = 24,
        unit       = _("MB"),
        title_text = _("Cover cache budget"),
        info_text  = _("Memory budget for ready-scaled book covers (MB)."
                        .. " Higher = smoother paging and preloading, more RAM."
                        .. " Default 24 MB."),
        callback   = function(spin)
            BookshelfSettings.save("cover_cache_mb", spin.value)
            -- Apply immediately so the change takes effect without a restart
            -- (shrinking evicts down to the new budget right away).
            require("lib/bookshelf_scaled_cover_cache")
                :setByteBudget(spin.value * 1024 * 1024)
            if touchmenu_instance and touchmenu_instance.updateItems then
                touchmenu_instance:updateItems()
            end
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
    local ver_face, ver_bold = BFont:getFace("cfont", 16)
    column[#column + 1] = TextWidget:new{
        text = "v" .. version,
        face = ver_face,
        bold = ver_bold,
    }
    column[#column + 1] = VerticalSpan:new{ width = Size.padding.large }
    local desc_face, desc_bold = BFont:getFace("cfont", 16)
    column[#column + 1] = TextBoxWidget:new{
        text      = description,
        face      = desc_face,
        bold      = desc_bold,
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

    -- Chip bar font scale moved to Settings -> Text size (#60).
    local items = {
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
