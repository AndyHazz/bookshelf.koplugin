-- main.lua
-- Plugin entry point. Registers start_with=bookshelf, hooks close-document,
-- and takes over the home screen on launch when configured to do so.
--
-- KOReader API notes (verified against KOReader source):
--
--   * FileManagerMenu.menu_items is an *instance* attribute built lazily in
--     setUpdateItemTable(), which is called the first time the menu opens.
--     The class table itself has no menu_items — so we cannot patch it via
--     FMMenu.menu_items at init time.
--
--   * The start_with sub_item_table is constructed inside
--     FileManagerMenu:getStartWithMenuTable() and assigned to
--     self.menu_items.start_with only *after* addToMainMenu callbacks have
--     already fired (addToMainMenu runs at line ~458, start_with is set at
--     line ~491 in filemanagermenu.lua).
--
--   * Therefore we monkey-patch FileManagerMenu.getStartWithMenuTable at the
--     *class* level so that every instance builds the table with our entry
--     already included. The patch is idempotent (duplicate-guard on "bookshelf").
--
--   * onCloseDocument is dispatched via ReaderUI:handleEvent(Event:new(
--     "CloseDocument")) which propagates to all registered child widgets
--     (plugins are inserted via registerModule → table.insert(self, ...)). So
--     defining Bookshelf:onCloseDocument() is sufficient — no manual subscribe
--     needed.
--
--   * is_doc_only = false — plugin loads in both FileManager and Reader contexts,
--     which is required so the close-document hook fires inside the Reader.

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local BookshelfSettings = require("lib/bookshelf_settings_store")
local UIManager       = require("ui/uimanager")
local logger          = require("logger")
local _               = require("lib/bookshelf_i18n").gettext
local T               = require("ffi/util").template

-- Wall-clock timer for perf instrumentation. Same pattern as
-- bookshelf_widget.lua / bookshelf_book_repository.lua so [bookshelf perf]
-- timestamps share a clock across modules.
local _gettime
do
    local ok, s = pcall(require, "socket")
    _gettime = (ok and s and type(s.gettime) == "function")
        and function() return s.gettime() end
        or  os.clock
end

local Bookshelf = WidgetContainer:extend{
    name        = "bookshelf",
    is_doc_only = false, -- must be false: hook fires in Reader context
}

-- Canonical order of the plugin's main-menu entries. Consumed by the
-- KOMenu order hook below AND by the start menu's "Bookshelf menu"
-- action, which probes addToMainMenu and hosts these in this order.
Bookshelf.MENU_ORDER = {
    "bookshelf_toggle",
    "bookshelf_hero_card",
    "bookshelf_shelf_tabs",
    "bookshelf_collections",
    "bookshelf_hardcover",
    "bookshelf_settings",
    "bookshelf_selection_mode",
    "bookshelf_updates",
    "bookshelf_about",
}

-- Color picker UI: attached lazily on first use. The palette module
-- pulls ~two dozen widget modules (InputText among them) for a dialog
-- most sessions never open; requiring it at plugin load taxed every
-- boot. attach() overwrites this stub with the real method, so the
-- lazy hop happens at most once per session.
function Bookshelf:showColorPicker(...)
    require("lib/bookshelf_color_palette").attach(Bookshelf)
    return Bookshelf.showColorPicker(self, ...)
end

-- Tracks the live BookshelfWidget singleton across plugin instances. Two
-- Bookshelf instances exist — one attached to FM, one to Reader — but the
-- widget itself is a single shared overlay. The tracker lets either
-- instance's onCloseWidget find and dismiss the overlay during a KOReader
-- exit, so the UIManager window stack can drain to zero.
local _live_widget = nil
-- The FileManager path the overlay was sitting over when it last (re)appeared.
-- onPathChanged compares against this so the PathChanged that FileManager
-- fires during our OWN takeover (the onShow chain, same path) is ignored,
-- while a genuine navigation underneath (folder shortcut, "go to parent", a
-- "go home" gesture) -- which moves to a DIFFERENT path -- triggers a drill.
local _overlay_open_path = nil
-- Suppresses Bookshelf:onCloseDocument's nextTick(show) for the duration
-- of a _safeShow call. _safeShow already schedules its own show() after
-- onClose+showFileManager, so onCloseDocument's parallel schedule would
-- be a duplicate, producing an extra EPDC commit (visible as an extra
-- flash on color panels). Set true during the gesture-exit critical
-- section, false again before our deferred work runs the show. (Pattern
-- adapted from komadorirobin's fork.)
local _suppress_close_document_show = false
-- True once the cold-boot start_with=bookshelf takeover has run. Only the
-- first FileManager init of the session (app start) should auto-raise
-- Bookshelf; later FM inits are reader-close re-instantiations, where the
-- destination is decided by the close path (onCloseDocument / _safeShow,
-- both keyed on _isShowing()). This is what lets a user who closed Bookshelf
-- and opened a book from the raw FileManager stay in the FileManager on
-- close, while a cold boot still lands on Bookshelf (issue #110).
local _did_initial_takeover = false

-- Close a TouchMenu we received as the first callback argument. Used
-- whenever a menu callback changes the visible UI layer (e.g. opens or
-- closes the bookshelf widget, switches start_with) — without this, the
-- menu lingers above the new layer and can end up orphaned in the stack.
local function _closeTouchMenu(touchmenu_instance)
    if touchmenu_instance and touchmenu_instance.closeMenu then
        touchmenu_instance:closeMenu()
    end
end

-- ---------------------------------------------------------------------------
-- init
-- ---------------------------------------------------------------------------

-- Tag every event delivered via UIManager:broadcastEvent so BookshelfWidget's
-- "forward to FM" path can distinguish broadcasts (which already reach FM
-- via the broadcast loop) from sendEvents (which only reach the topmost
-- widget and DO need our forward). See BookshelfWidget:handleEvent for the
-- consumer side. Fixes issue #19 (Night Mode toggle double-handled).
--
-- Install is idempotent: if the plugin's init runs again (second host
-- context, plugin reload), we skip the wrap. The wrapper delegates to the
-- original so other listeners and any future KOReader changes are
-- unaffected.
local function _installBroadcastTag()
    if UIManager._bookshelf_broadcast_wrapped then return end
    UIManager._bookshelf_broadcast_wrapped = true
    local orig = UIManager.broadcastEvent
    UIManager.broadcastEvent = function(self_um, event, ...)
        -- type-guard: some upstream plugins (autodim's ramp_task etc.)
        -- call broadcastEvent with a bare string as the event name.
        -- Reading fields from a string returns nil (Lua string metatable),
        -- so the rest of the broadcast pipeline tolerates it -- but
        -- WRITING a field to a string crashes the VM. Issue #39: the
        -- autodim dimmer fired every 3 minutes and tore down KOReader
        -- with "attempt to index local 'event' (a string value)".
        if type(event) == "table" then
            event._bookshelf_from_broadcast = true
        end
        return orig(self_um, event, ...)
    end
end

-- Remove leftover v1.1.x bookshelf_*.lua files from the plugin root that
-- KOReader's archive extractor (Device:unpackArchive) leaves behind when a
-- user upgrades over the top of an older install. Every helper now lives
-- in lib/, so any bookshelf_*.lua sitting at the root after a v1.2 upgrade
-- is dead code. Idempotent: a fresh v1.2 install has nothing matching, so
-- this is a no-op on clean installs. Safe: only removes files matching
-- "bookshelf_*.lua" at the koplugin root -- main.lua / _meta.lua / lib/
-- contents / README / LICENSE are untouched.
local _legacy_clean_done = false
local function _cleanLegacyLayout()
    -- Once per session: init() re-runs on every FM/Reader re-instantiation
    -- (each book open and close), and the v1.1 leftovers can't reappear
    -- mid-session, so repeating the lfs.dir scan buys nothing.
    if _legacy_clean_done then return end
    _legacy_clean_done = true
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or not lfs or not lfs.dir then return end
    local DataStorage = require("datastorage")
    local plugin_dir = DataStorage:getDataDir() .. "/plugins/bookshelf.koplugin"
    local ok, iter, dir_obj = pcall(lfs.dir, plugin_dir)
    if not ok or type(iter) ~= "function" then return end
    local removed = 0
    for entry in iter, dir_obj do
        if entry:match("^bookshelf_.+%.lua$") then
            -- These are leftovers from the v1.1.x flat layout. The new
            -- helpers all live in lib/. Removing the root copy prevents
            -- accidental shadowing if any old code still did
            -- require("bookshelf_X") without the lib/ prefix.
            if os.remove(plugin_dir .. "/" .. entry) then
                removed = removed + 1
            end
        end
    end
    if removed > 0 then
        logger.dbg(string.format(
            "[bookshelf] cleaned %d legacy v1.1 files from %s",
            removed, plugin_dir))
    end
end

function Bookshelf:init()
    _installBroadcastTag()
    -- Run once per init -- no settings flag needed because the clean is
    -- idempotent and cheap (one lfs.dir scan over the plugin root).
    _cleanLegacyLayout()
    -- Bundled fonts: install (best-effort, for pickers) and seed fresh-install
    -- defaults exactly once. Must run before any other settings write so the
    -- "settings file present" fresh-install signal is accurate.
    local Fonts = require("lib/bookshelf_fonts")
    Fonts.maybeSeedFreshInstall()
    Fonts.ensureInstalled()

    -- Cache update-related settings on the instance for the menu's text_func
    -- closures. Defaults match bookends: branch empty, source = "release",
    -- background check OFF (opt-in via the menu toggle).
    self.dev_branch          = BookshelfSettings.read("dev_branch") or ""
    self.last_install_source = BookshelfSettings.read("last_install_source") or "release"
    self.check_updates       = BookshelfSettings.isTrue("check_updates")

    -- Patch the start_with menu so users can pick Bookshelf as their home.
    self:_registerStartWithMenu()

    -- Add bookshelf anchors to the FM menu_order so our entries don't get
    -- the "NEW:" prefix MenuSorter applies to anything orphan-positioned.
    self:_extendMenuOrder()

    -- Register "Open Bookshelf" in the main menu (works in both FM and Reader).
    self.ui.menu:registerToMainMenu(self)

    -- In reader context, swap the file-browser menu-tab callback for our
    -- fast-path version so the user gets the same raise-to-top + toast UX
    -- as the gesture path. No-op when self.ui.menu hasn't built its
    -- menu_items yet — but ReaderMenu:init populates them synchronously
    -- during registerModule, before plugins load, so it's safe here.
    self:_wireFastFileBrowserTab()

    -- Re-assert ownership of that callback AFTER the reader is shown.
    -- Another home-screen-replacement plugin can wrap the same
    -- items.filemanager.callback from inside a UIManager.show patch (firing
    -- during ReaderUI's UIManager:show, i.e. after our init-time wrap above)
    -- and re-point it at its own home view, ignoring "Start with". Whoever
    -- writes the callback last wins. A nextTick scheduled here runs after the
    -- reader's show (where such a plugin would wrap) but long before any tap,
    -- so re-wrapping with force=true makes Bookshelf the deterministic final
    -- writer. With no competing plugin this is a harmless re-install of our
    -- own callback. Reader context only (self.ui.document set); a no-op in FM.
    if self.ui and self.ui.document then
        UIManager:nextTick(function()
            self:_wireFastFileBrowserTab(true)
        end)
    end

    -- Register Dispatcher actions so users can bind gestures / keys to
    -- Bookshelf show/hide/toggle from KOReader's Gesture Manager. Required
    -- for users who run Bookshelf alongside other home-screen plugins and
    -- want a quick toggle rather than digging through the FM menu.
    self:onDispatcherRegisterActions()

    -- One silent background check per init when the user's opted in.
    self:backgroundUpdateCheck()

    -- One-shot bookinfo_cache staleness sweep. Detects EPUBs whose
    -- on-disk size/mtime has diverged from BIM's cached values (typical
    -- cause: Syncthing pushed an enricher-rewritten file between
    -- KOReader sessions) and purges those rows so the existing kickoff
    -- requeues fresh extraction. Deferred 2s so init isn't blocked and
    -- so BIM's own scan-on-start has settled. Module guards against
    -- double-fire across FM+Reader init contexts.
    UIManager:scheduleIn(2, function()
        local ok, StaleSweep = pcall(require, "lib/bookshelf_stale_sweep")
        if ok and StaleSweep then
            pcall(function() StaleSweep:run() end)
        end
    end)

    -- Takeover: if start_with=bookshelf and we're in the FileManager context
    -- (no document currently being opened), close FM and present Bookshelf.
    -- Only on the FIRST FM init of the session (cold boot). Later FM inits are
    -- reader-close re-instantiations; whether Bookshelf returns then is decided
    -- by the close path (onCloseDocument / _safeShow gate on _isShowing()), so a
    -- user who closed Bookshelf and opened a book from the raw FileManager stays
    -- in the FileManager when the book closes (issue #110).
    if G_reader_settings:readSetting("start_with") == "bookshelf"
            and not (self.ui and self.ui.document)
            and not _did_initial_takeover then
        -- Mark the attempt now (before the CoverBrowser bail below) so a
        -- missing-CoverBrowser notification fires once, not on every FM init.
        _did_initial_takeover = true
        -- Bookshelf depends on CoverBrowser's BookInfoManager. If
        -- CoverBrowser is disabled, every code path that touches BIM
        -- throws — pre-#49 this manifested as a crash loop on the
        -- onShow handler. Detect at init and bail with a notification
        -- so the user lands on plain FM and knows why.
        local ok_repo, Repo = pcall(require, "lib/bookshelf_book_repository")
        if ok_repo and Repo and Repo.hasBookInfoManager
                and not Repo.hasBookInfoManager() then
            local Notification = require("ui/widget/notification")
            Notification:notify(_("Bookshelf requires the CoverBrowser plugin. Enable it under Settings > More plugins."),
                Notification.SOURCE_ALWAYS_SHOW)
            return
        end
        -- Capture FileManager.instance at schedule time. By the time the tick
        -- fires we want a known reference, not a fresh require lookup that
        -- could see different state.
        local FileManager = require("apps/filemanager/filemanager")
        local fm_instance = FileManager.instance
        UIManager:nextTick(function() self:_takeOver(fm_instance) end)
    end
end

-- ---------------------------------------------------------------------------
-- Start-with menu registration
-- ---------------------------------------------------------------------------

function Bookshelf:_registerStartWithMenu()
    local plugin = self  -- captured by the patches below for runtime access

    -- Monkey-patch FileManagerMenu.getStartWithMenuTable at the class level.
    -- This is the only reliable way to inject into the lazy-built start_with
    -- sub_item_table (see API notes at top of file).
    local ok, FMMenu = pcall(require, "apps/filemanager/filemanagermenu")
    if not ok or not FMMenu then
        logger.dbg("[bookshelf] FileManagerMenu not available; skipping start_with registration")
        return
    end

    local orig_fn = FMMenu.getStartWithMenuTable
    if type(orig_fn) ~= "function" then
        logger.dbg("[bookshelf] getStartWithMenuTable not found; skipping start_with registration")
        return
    end

    -- Wrap once — idempotent across multiple plugin init() calls.
    if FMMenu._bookshelf_patched then return end
    FMMenu._bookshelf_patched = true

    FMMenu.getStartWithMenuTable = function(self_fm)
        local result = orig_fn(self_fm)
        -- result = { text_func = ..., sub_item_table = {...} }
        if type(result) ~= "table" or type(result.sub_item_table) ~= "table" then
            return result
        end

        -- Wrap the OTHER start_with options' callbacks: if the user picks
        -- file browser / history / etc. while Bookshelf is currently up,
        -- close it so they immediately see the new home (otherwise they'd
        -- have to manually dismiss Bookshelf and the change wouldn't seem
        -- to take effect until next launch).
        for _i, entry in ipairs(result.sub_item_table) do
            local orig_cb = entry.callback
            entry.callback = function(touchmenu_instance, ...)
                if orig_cb then orig_cb(touchmenu_instance, ...) end
                if _live_widget and UIManager:isWidgetShown(_live_widget) then
                    UIManager:close(_live_widget)
                    -- Close the start_with menu too: the user just chose
                    -- a different home and expects to land on it. Radio
                    -- items go through TouchMenu's updateItems() branch
                    -- (refresh checkmark), not the auto-close branch.
                    _closeTouchMenu(touchmenu_instance)
                end
            end
        end

        -- Duplicate guard (safety net in case patch fires more than once).
        -- NB: do NOT name the loop index `_` — that would shadow the outer
        -- gettext binding and `_("bookshelf")` below would call a number.
        -- Lowercase matches the other "Start with: …" options (file
        -- browser / history / favorites / last file / folder shortcuts),
        -- which all use lowercase initial caps (issue #69).
        local already
        for _i, entry in ipairs(result.sub_item_table) do
            if entry.text == _("bookshelf") then already = true; break end
        end
        if not already then
            table.insert(result.sub_item_table, {
                text    = _("bookshelf"),
                radio   = true,
                checked_func = function()
                    return G_reader_settings:readSetting("start_with") == "bookshelf"
                end,
                callback = function(touchmenu_instance)
                    G_reader_settings:saveSetting("start_with", "bookshelf")
                    G_reader_settings:flush()
                    -- Close the menu BEFORE showing bookshelf — otherwise
                    -- UIManager:show inserts the new widget above the
                    -- still-open menu_container, leaving the menu hidden
                    -- but still on the stack. The orphan would later be
                    -- exposed when the user closes bookshelf and absorb
                    -- input beneath FM.
                    _closeTouchMenu(touchmenu_instance)
                    -- Show Bookshelf immediately if not already showing.
                    if plugin._isShowing and not plugin:_isShowing() then
                        plugin:show()
                    end
                end,
            })
        end

        -- Upstream text_func iterates a hard-coded list of start_with values
        -- (file browser / history / favorites / folder shortcuts / last
        -- file). When the user picks Bookshelf, none match — so the parent
        -- menu row reads "Start with: nil". Wrap text_func to label our
        -- value; defer to the original for everything else.
        local orig_text_func = result.text_func
        result.text_func = function()
            if G_reader_settings:readSetting("start_with") == "bookshelf" then
                return T(_("Start with: %1"), _("bookshelf"))
            end
            return orig_text_func and orig_text_func() or ""
        end
        return result
    end

end

-- ---------------------------------------------------------------------------
-- Auto-refresh on sort change (beta)
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Main menu entry
-- ---------------------------------------------------------------------------

-- Inject a dedicated "bookshelf_tab" top-level tab into the FM menu.
-- Patching the cached order module is safe because addToMainMenu fires
-- before MenuSorter:mergeAndSort runs. Idempotent.
function Bookshelf:_extendMenuOrder()
    local ok, order = pcall(require, "ui/elements/filemanager_menu_order")
    if not ok or type(order) ~= "table"
       or type(order["KOMenu:menu_buttons"]) ~= "table" then
        return
    end
    for _i, id in ipairs(order["KOMenu:menu_buttons"]) do
        if id == "bookshelf_tab" then return end
    end
    -- Position 2: filemanager_settings stays at [1] so MenuSorter's orphan
    -- pass (which hardcodes table.insert([1], v)) doesn't dump unrelated
    -- plugin entries into the Bookshelf tab.
    table.insert(order["KOMenu:menu_buttons"], 2, "bookshelf_tab")
    order.bookshelf_tab = Bookshelf.MENU_ORDER
end

-- True when the BookshelfWidget singleton is in the UIManager window stack
-- (i.e. it's currently shown over FM, regardless of whether a Reader is
-- ALSO on top of it).
--
-- Two Bookshelf plugin instances exist concurrently (one per host: FM and
-- Reader), and several code paths can each be the one that created the
-- widget (Bookshelf:show called from _takeOver, from a menu callback, from
-- the start_with patch, from onShow). Tracking the widget on the
-- per-instance self._widget made the canonical state ambiguous — e.g. the
-- start_with menu callback captures `plugin` from _registerStartWithMenu
-- and the main menu's text_func captures `outer` from addToMainMenu; if
-- those bindings disagree about which instance owns the widget, the menu
-- text drifts out of sync with what's on screen.
--
-- Module-level _live_widget is the only thing every code path agrees on,
-- so use it as the source of truth here.
function Bookshelf:_isShowing()
    if not _live_widget then return false end
    return UIManager:isWidgetShown(_live_widget)
end

-- Hide the touchmenu while a modal dialog is shown on top; returns a
-- callback that restores the menu (re-shows it and refreshes items).
-- Mirrors bookends' DialogHelpers.hideParentMenu so a ported widget that
-- expects bookshelf:hideMenu(touchmenu_instance) works unchanged.
function Bookshelf:hideMenu(touchmenu_instance)
    if not touchmenu_instance then
        return function() end
    end
    local menu_container = touchmenu_instance.show_parent
        or touchmenu_instance.menu_container
        or touchmenu_instance
    if menu_container and UIManager and UIManager.close then
        UIManager:close(menu_container)
    end
    return function()
        if menu_container and UIManager and UIManager.show then
            UIManager:show(menu_container)
        end
        if touchmenu_instance and touchmenu_instance.updateItems then
            touchmenu_instance:updateItems()
        end
    end
end

function Bookshelf:addToMainMenu(menu_items)
    -- Skip reader context entirely: bookshelf is a home-screen plugin and has
    -- nothing useful to add to the reader menu. is_doc_only=false is required
    -- only so onCloseDocument fires; self.ui.document is nil in FM context.
    if self.ui.document then return end

    local outer = self
    local S = require("lib/bookshelf_settings")
    -- Stash plugin ref now so _updateSubItems callbacks resolve correctly.
    S._plugin = outer

    menu_items.bookshelf_tab = { icon = "book.opened", text = _("Bookshelf") }

    menu_items.bookshelf_toggle = {
        text_func = function()
            return outer:_isShowing() and _("Close Bookshelf") or _("Open Bookshelf")
        end,
        callback = function(touchmenu_instance)
            if outer:_isShowing() then
                UIManager:close(_live_widget)
                -- Workaround: SimpleUI (since April 2026 v1.5.0
                -- changes) installs a covers_fullscreen=true
                -- "homescreen" widget on the UIManager stack at
                -- plugin init regardless of simpleui_enabled.
                -- KOReader's compositor uses covers_fullscreen as a
                -- paint-skip hint -- everything below the topmost
                -- such widget isn't painted. When SimpleUI is
                -- disabled, the homescreen widget's paintTo is a
                -- no-op, so closing bookshelf leaves the framebuffer
                -- holding the bookshelf pixels with no widget
                -- repainting on top. When SimpleUI is enabled the
                -- same widget IS the intended home screen and paints
                -- correctly. We only force-close it when SUISettings
                -- explicitly says simpleui_enabled = false.
                local ok_sui, SUISettings = pcall(require, "sui_store")
                local sui_disabled = ok_sui and SUISettings
                    and SUISettings.nilOrTrue
                    and not SUISettings:nilOrTrue("simpleui_enabled")
                if sui_disabled and UIManager._window_stack then
                    for i = #UIManager._window_stack, 1, -1 do
                        local w = UIManager._window_stack[i]
                            and UIManager._window_stack[i].widget
                        if w and w.name == "homescreen"
                           and w.covers_fullscreen then
                            UIManager:close(w)
                        end
                    end
                end
                UIManager:setDirty("all", "full")
            else
                outer:show()
            end
            -- Always close the menu so the user lands on the new state.
            _closeTouchMenu(touchmenu_instance)
        end,
        separator = true,
    }

    menu_items.bookshelf_hero_card = {
        text                = _("Edit book detail view"),
        enabled_func        = function() return outer:_isShowing() end,
        sub_item_table_func = function()
            S._bw = _live_widget
            return S:_heroSubItems()
        end,
    }

    menu_items.bookshelf_shelf_tabs = {
        text                = _("Bookshelf chips\xE2\x80\xA6"),
        sub_item_table_func = function()
            S._bw = _live_widget
            return S:_tabsMenuItems()
        end,
    }

    menu_items.bookshelf_collections = {
        text     = _("Manage collections\xE2\x80\xA6"),
        callback = function()
            S._bw = _live_widget
            local CollectionManager = require("lib/bookshelf_collection_manager")
            CollectionManager.show{
                bw = _live_widget,
                on_close = function()
                    if _live_widget and _live_widget._rebuild then
                        _live_widget:_rebuild()
                        UIManager:setDirty(_live_widget, "ui")
                    end
                end,
            }
        end,
        -- Visually separate the customisation entries above (chip
        -- editor, collection manager) from the broader Settings /
        -- Updates / About cluster below.
        separator = true,
    }

    -- Hardcover enrichment, promoted from Settings to the top level (below
    -- Manage collections). Only present when Hardcover is in play -- the plugin
    -- is installed/enabled, or we have cached Hardcover data -- mirroring the
    -- old Settings-submenu gate. Defined conditionally (rather than greyed out)
    -- so it's hidden entirely otherwise; the order list keeps its slot and
    -- KOMenu skips a missing key.
    do
        local ok_hc, HC = pcall(require, "lib/bookshelf_hardcover")
        if ok_hc and HC and HC.shouldShowEnrichmentUI and HC.shouldShowEnrichmentUI() then
            menu_items.bookshelf_hardcover = {
                text                = _("Hardcover enrichment"),
                sub_item_table_func = function()
                    S._bw = _live_widget
                    return S:_hardcoverSubItems()
                end,
            }
        end
    end

    menu_items.bookshelf_settings = {
        text                = _("Settings"),
        sub_item_table_func = function()
            S._bw = _live_widget
            return S:_settingsSubItems()
        end,
    }

    menu_items.bookshelf_selection_mode = {
        text_func = function()
            local bw = _live_widget
            if bw and bw._selection and bw._selection:isActive() then
                return _("Selection mode") .. "  \xE2\x9C\x93"
            else
                return _("Selection mode")
            end
        end,
        callback = function()
            if not outer:_isShowing() then
                outer:show()
            end
            if _live_widget then
                _live_widget:onBookshelfToggleSelectionMode()
            end
        end,
        separator = true,
    }

    menu_items.bookshelf_updates = {
        text                = _("Updates"),
        sub_item_table_func = function() return S:_updateSubItems() end,
    }

    menu_items.bookshelf_about = {
        text     = _("About"),
        callback = function() S:_about() end,
    }
end

-- ---------------------------------------------------------------------------
-- Show / takeover
-- ---------------------------------------------------------------------------

-- Show or refresh the BookshelfWidget. We keep a single instance live
-- across the plugin's lifetime so opening a book and closing it doesn't
-- require destroying + recreating + flashing the FileManager underneath.
function Bookshelf:show()
    -- Diag: cradle the whole call so the log shows whether this was a
    -- cold start (new widget) or a warm refresh (existing widget got a
    -- softRefresh). The cold-start path runs BookshelfWidget:init ->
    -- _rebuild -> UIManager:show; warm runs softRefresh which itself
    -- splits paint + deferred shelf reload.
    local _diag_t0 = _gettime()
    local _diag_branch
    -- Stash the plugin ref for settings callbacks (hideMenu, color picker).
    -- addToMainMenu also stashes it, but FileManagerMenu builds its item
    -- table lazily on first menu open - the start menu's "Bookshelf
    -- settings" host can be reached before that ever happens (e.g.
    -- start_with auto-open), so anchor the ref to the widget's own
    -- lifecycle too.
    require("lib/bookshelf_settings")._plugin = self
    -- Record the FileManager path the overlay is (re)appearing over, so
    -- onPathChanged can tell its own-takeover PathChanged (same path) apart
    -- from a real navigation underneath (different path -> drill in).
    _overlay_open_path = (self.ui and self.ui.file_chooser and self.ui.file_chooser.path) or nil
    -- Discard a stale self._widget without a stack walk. _live_widget
    -- is the canonical "what's actually on screen" pointer (set/cleared
    -- in sync with the widget's _on_close_callback), so anything else
    -- this instance is pointing at can't be the live one.
    if self._widget and self._widget ~= _live_widget then
        self._widget = nil
    end
    -- Idempotency: if a bookshelf widget already exists on the UIManager
    -- stack (created by some other plugin instance — a fresh
    -- bookshelf_fm:init + _takeOver after a reader-return, say — at the
    -- same time onCloseDocument's nextTick(show) was already scheduled),
    -- adopt it instead of creating a second one on top. Two widgets in
    -- the stack would let "Close Bookshelf" remove just the topmost,
    -- leaving its twin visible and fully interactive underneath.
    if not self._widget and _live_widget
            and UIManager:isWidgetShown(_live_widget) then
        self._widget = _live_widget
        -- Rebind the close callback so closing the adopted widget clears
        -- state on THIS plugin instance too (the original callback was
        -- bound to a plugin instance that may now be gone).
        local outer = self
        local widget_instance = _live_widget
        self._widget._on_close_callback = function()
            outer._widget = nil
            if _live_widget == widget_instance then _live_widget = nil end
        end
    end
    if self._widget then
        -- Already on the stack (probably underneath the Reader). Refresh data
        -- and request a repaint so freshly-closed books surface in Recent etc.
        -- Restore screen rotation saved before the reader opened — the reader
        -- may have left the display in a different orientation (upside-down,
        -- landscape) and KOReader does not reset it on close.
        if self._widget._pre_read_rotation ~= nil then
            local Screen = require("device").screen
            Screen:setRotationMode(self._widget._pre_read_rotation)
            self._widget._pre_read_rotation = nil
            self._widget.width  = Screen:getWidth()
            self._widget.height = Screen:getHeight()
            if self._widget.dimen then
                self._widget.dimen.w = self._widget.width
                self._widget.dimen.h = self._widget.height
            end
        end
        -- softRefresh splits the warm-path update so the existing tree
        -- paints immediately and the heavier shelf re-sort runs ~150ms
        -- later — much snappier than the previous full _rebuild() inline.
        _diag_branch = "warm-softRefresh"
        self._widget:softRefresh()
        logger.dbg(string.format(
            "[bookshelf perf] Bookshelf:show: branch=%s elapsed=%.0fms",
            _diag_branch, (_gettime() - _diag_t0) * 1000))
        self:_evictHomescreenOverlay()
        return
    end
    _diag_branch = "cold-create"
    local BookshelfWidget = require("lib/bookshelf_widget")
    local _t_pre_new = _gettime()
    self._widget = BookshelfWidget:new{}
    local _t_post_new = _gettime()
    -- Clear our reference if the widget is dismissed for any reason, so a
    -- subsequent show() falls back to the create path.
    local outer = self
    local widget_instance = self._widget
    self._widget._on_close_callback = function()
        outer._widget = nil
        if _live_widget == widget_instance then _live_widget = nil end
    end
    _live_widget = self._widget
    -- Pass "ui" so UIManager:show enqueues a full-screen refresh alongside
    -- our paint. Without it, setDirty(widget, nil) marks us dirty but
    -- _refresh(nil) is a no-op, and any small-region refreshes already in
    -- the queue (e.g. CoverMenu's items_update_action firing every 1s after
    -- a BIM "extract and cache" scan) become the ONLY refreshes drained.
    -- The EPDC then updates just those tiny cover-cell regions and leaves
    -- the rest of the panel showing FileManager underneath, even though
    -- Screen.bb is fully bookshelf. The collision-merge pass in _refresh
    -- subsumes the small-region refreshes into our full-screen one. The
    -- existing-widget path below already uses setDirty(..., "ui"); this
    -- keeps the fresh-create path consistent. (Issue #18.)
    UIManager:show(self._widget, "ui")
    logger.dbg(string.format(
        "[bookshelf perf] Bookshelf:show: branch=%s init+rebuild=%.0fms TOTAL=%.0fms (paint follows)",
        _diag_branch,
        (_t_post_new - _t_pre_new) * 1000,
        (_gettime() - _diag_t0) * 1000))
    self:_evictHomescreenOverlay()
end

-- ---------------------------------------------------------------------------
-- Dispatcher actions
-- ---------------------------------------------------------------------------

-- Register Bookshelf actions in KOReader's Dispatcher so they appear in the
-- Gesture Manager's action picker. Titles all begin with "Bookshelf:" so the
-- two actions read as a related block. IDs are kept stable — renaming would
-- silently break existing bindings users have set up.
function Bookshelf:onDispatcherRegisterActions()
    local Dispatcher = require("dispatcher")
    -- Action ID stays "toggle_bookshelf" to preserve existing user
    -- gesture bindings; only the user-visible title changes to match
    -- what the handler actually does (close the live widget if showing,
    -- otherwise open it). The earlier "toggle visibility" label dated
    -- back to a removed menu option that flipped a hide flag without
    -- closing the widget — the close/open semantics here have nothing
    -- to do with that.
    --
    -- general=true marks the action as "available in every context"
    -- (FM and Reader). The earlier registration used filemanager=true
    -- and reader=true which LOOK like "available in both" but actually
    -- mean the opposite: dispatcher.lua's isActionEnabled() treats
    -- action.reader as "disable everywhere except reader" and
    -- action.filemanager as "disable everywhere except FM". Setting
    -- both meant the action was disabled in BOTH contexts — the gesture
    -- fired, dispatcher ran, isActionEnabled returned false, sendEvent
    -- was skipped, and the user saw a silent no-op. Stock actions like
    -- "File browser" (line 58 of dispatcher.lua) use general=true.
    Dispatcher:registerAction("toggle_bookshelf", {
        category = "none",
        event    = "ToggleBookshelf",
        title    = _("Bookshelf: open or close"),
        general  = true,
    })
    Dispatcher:registerAction("set_bookshelf", {
        category  = "string",
        event     = "SetBookshelf",
        title     = _("Bookshelf: open"),
        general   = true,
        args      = { true, false },
        toggle    = { _("on"), _("off") },
        separator = true,
    })
    Dispatcher:registerAction("bookshelf_next_tab", {
        category = "none",
        event    = "BookshelfNextChip",
        title    = _("Bookshelf: next chip"),
        general  = true,
    })
    Dispatcher:registerAction("bookshelf_prev_tab", {
        category = "none",
        event    = "BookshelfPrevChip",
        title    = _("Bookshelf: previous chip"),
        general  = true,
    })
    Dispatcher:registerAction("bookshelf_toggle_hero", {
        category = "none",
        event    = "BookshelfToggleHero",
        title    = _("Bookshelf: expand or collapse hero"),
        general  = true,
    })
    Dispatcher:registerAction("bookshelf_toggle_selection_mode", {
        category  = "none",
        event     = "BookshelfToggleSelectionMode",
        title     = _("Bookshelf: toggle selection mode"),
        general   = true,
        separator = true,
    })
    Dispatcher:registerAction("bookshelf_select_focused_book", {
        category = "none",
        event    = "BookshelfSelectFocusedBook",
        title    = _("Bookshelf: toggle selection on focused book"),
        general  = true,
    })
    Dispatcher:registerAction("bookshelf_add_focused_stack_to_selection", {
        category = "none",
        event    = "BookshelfAddFocusedStackToSelection",
        title    = _("Bookshelf: add focused stack to selection"),
        general  = true,
    })
    Dispatcher:registerAction("bookshelf_open_bulk_menu", {
        category = "none",
        event    = "BookshelfOpenBulkMenu",
        title    = _("Bookshelf: open bulk action menu"),
        general  = true,
    })
end

-- _raiseInPlace — splice the live BookshelfWidget to the top of
-- UIManager's window stack and mark it dirty for a partial repaint.
--
-- Used by _safeShow's fast path. When the user is inside a book opened
-- from bookshelf, the widget sits on the stack underneath the Reader.
-- Painting it in place lets the user see bookshelf within one EPDC
-- refresh (~700ms on Kindle) instead of waiting through the full
-- onClose + FM rebuild + paint cycle (~2–4s of EPDC + disk I/O).
--
-- Does NOT call forceRePaint — the caller is expected to queue any
-- additional widgets (e.g. a Notification toast) and force the drain
-- once, so both paints land in a single EPDC cycle.
--
-- Returns true if the widget was found and raised; false when bookshelf
-- isn't on the stack (cold-boot `start_with=last` + corner-tap from
-- inside the reader). The caller can still queue a notification and
-- forceRePaint; show() on the create path will land bookshelf on top
-- naturally a tick later.
function Bookshelf:_raiseInPlace()
    if not _live_widget then return false end
    local stack = UIManager._window_stack
    if not stack then return false end
    local idx
    for i, entry in ipairs(stack) do
        if entry.widget == _live_widget then
            idx = i
            break
        end
    end
    if not idx then return false end
    if idx ~= #stack then
        local entry = table.remove(stack, idx)
        table.insert(stack, entry)
    end
    -- "ui" rather than "partial": on Colorsoft, "partial" of a full-
    -- screen region gets promoted to a full flash refresh by the EPDC
    -- driver. "ui" uses a smoother waveform that doesn't get promoted.
    -- Same type the create path uses (UIManager:show(self._widget, "ui")
    -- at line 454). (#35.)
    UIManager:setDirty(_live_widget, function()
        return "ui", _live_widget.dimen
    end)
    return true
end

-- _safeShow — exit the reader and show bookshelf.
--
-- Adapted from komadorirobin's fork pattern with one Colorsoft-targeted
-- tweak: replace ui:onHome() with ui:onClose(false) + showFileManager(file)
-- so the reader's internal UIManager:close(self.dialog, "full") doesn't
-- queue a full-flash refresh that the merged EPDC commit would inherit.
-- We get the same effect (close reader, restore FM.instance for the
-- screensaver host check, raise bookshelf) but the merged refresh type
-- on commit is "ui" instead of "full" — significantly less visible
-- on color panels (#35).
--
-- A "Closing book…" InfoMessage shows synchronously for feedback during
-- the 1–3s onClose disk-I/O block. _suppress_close_document_show stops
-- onCloseDocument's parallel nextTick(show) so we don't double-trigger.
function Bookshelf:_safeShow()
    if not (self.ui and self.ui.document and self.ui.onHome) then
        self:show()
        return
    end
    local file = self.ui.document.file
    -- Feedback: centered InfoMessage with scoped partial refresh so the
    -- show doesn't trigger a full-screen flash. Skip when:
    --   a. SimpleUI is set to "always" mode (it'll show its own
    --      equivalent — avoid doubling up).
    --   b. The user has disabled our notice in Settings > Advanced
    --      (escape hatch for color-panel users who see flashing from
    --      the message itself; the close still happens, just silently).
    local our_close_msg = nil
    local sui_mode = G_reader_settings:readSetting("simpleui_hs_closing_notice_mode")
    local show_msg = BookshelfSettings.nilOrTrue("show_close_msg")
    if show_msg and sui_mode ~= "always" then
        local InfoMessage = require("ui/widget/infomessage")
        our_close_msg = InfoMessage:new{
            text = _("Closing book…"),
            timeout = 0.0,
        }
        UIManager:show(our_close_msg)
        UIManager:setDirty(our_close_msg, function()
            return "partial", our_close_msg.dimen
        end)
    end
    UIManager:forceRePaint()  -- commit the InfoMessage before onClose blocks
    _suppress_close_document_show = true
    UIManager:nextTick(function()
        self.ui:onClose(false)
        if self.ui and self.ui.showFileManager then
            self.ui:showFileManager(file)
        end
        self:_raiseInPlace()
        self:show()
        if our_close_msg then
            UIManager:close(our_close_msg, "partial", our_close_msg.dimen)
        end
        -- Keep the suppress flag set through the NEXT nextTick too so the
        -- FM-side _takeOver (scheduled by the freshly-instantiated FM
        -- plugin in showFileManager → FM:init → Bookshelf:init) sees it
        -- and skips its own self:show() call. Without this, _takeOver
        -- fires one iteration after ours, calls softRefresh again, and
        -- queues a separate EPDC commit visible as a second flash.
        UIManager:nextTick(function()
            _suppress_close_document_show = false
        end)
    end)
end

-- Wrap the reader-side filemanager tab callback so it routes through
-- bookshelf's path WHEN bookshelf is the user's live home (its widget is on
-- the stack — true when the book was opened from Bookshelf). For users in
-- plain FM, the FM tab should take them to plain FM, not bookshelf. This is
-- independent of the "Start with" restart setting (issue #98).
--
-- The default tab callback (readermenu.lua:47-54) inlines
-- onTapCloseMenu + onClose + showFileManager. We keep onTapCloseMenu
-- (otherwise the menu overlay lingers above the new layer) and replace
-- the rest based on whether Bookshelf is the live home.
-- `force` re-installs the callback even when we've already wrapped this
-- menu instance. Needed because another home-screen-replacement plugin can
-- re-wrap this same callback when the reader is shown — AFTER our init-time
-- wrap — routing the File-browser tab to its own home view. Re-asserting on
-- a post-show nextTick makes Bookshelf the deterministic last writer. See the
-- scheduling site in init().
function Bookshelf:_wireFastFileBrowserTab(force)
    if not (self.ui and self.ui.document and self.ui.menu) then return end
    local menu_ref = self.ui.menu
    if menu_ref._bookshelf_fm_tab_wrapped and not force then return end
    local items = menu_ref.menu_items
    if not (items and items.filemanager) then return end
    local plugin = self
    items.filemanager.callback = function()
        if menu_ref.onTapCloseMenu then menu_ref:onTapCloseMenu() end
        -- Decoupled from "Start with" (issue #98): route back to Bookshelf
        -- whenever it is the live home — i.e. its widget is on the stack,
        -- which is true exactly when the book was opened from Bookshelf. This
        -- makes the reader-close destination independent of the restart
        -- setting, so a user who keeps "Start with: History" still lands on
        -- Bookshelf after finishing a book.
        --
        -- "Return to where you came from" (issue #110): if the book was opened
        -- from the raw FileManager (Bookshelf not on the stack — e.g. the user
        -- closed Bookshelf, browsed FM and opened a book there), the File
        -- browser tab takes them back to the FileManager, not Bookshelf, even
        -- when Start with = Bookshelf. The session-once takeover guard keeps
        -- the cold-boot FM init from re-raising Bookshelf behind this.
        if plugin:_isShowing() then
            -- Bookshelf is home: same fast-path as the gesture.
            plugin:_safeShow()
        else
            -- File browser is home: plain go-to-FM, no bookshelf raise.
            -- onClose(false) to suppress reader's internal full refresh,
            -- showFileManager re-instantiates FM. Bookshelf may still be
            -- on the stack from earlier gestures, but FM lands on top.
            local file = plugin.ui and plugin.ui.document
                and plugin.ui.document.file
            UIManager:nextTick(function()
                if plugin.ui and plugin.ui.onClose then
                    plugin.ui:onClose(false)
                end
                if plugin.ui and plugin.ui.showFileManager then
                    plugin.ui:showFileManager(file)
                end
            end)
        end
    end
    menu_ref._bookshelf_fm_tab_wrapped = true
end

-- Close the live widget if showing, otherwise safe-show. Mirrors the
-- "Open Bookshelf" / "Close Bookshelf" menu entry.
function Bookshelf:onToggleBookshelf()
    -- Inside a book, the BookshelfWidget is still on the UIManager stack
    -- (left there by _openBook so the close-book path can reuse it) but
    -- is visually covered by the Reader. UIManager:isWidgetShown reports
    -- stack membership, not visibility, so _isShowing() returns true —
    -- and we'd silently close the hidden widget on first press, forcing
    -- the user to fire the gesture twice. Treat any in-book context as
    -- "not visible to user" and let _safeShow drop the reader. (Issue #27.)
    if self.ui and self.ui.document then
        self:_safeShow()
        return true
    end
    if self:_isShowing() then
        UIManager:close(_live_widget)
    else
        self:_safeShow()
    end
    return true
end

-- Explicit show/hide — used by the Set Bookshelf action with on/off args.
-- Hide is a no-op when nothing's showing, mirroring how Set Bookends behaves.
function Bookshelf:onSetBookshelf(visible)
    -- Same stack-shown ≠ visually-shown caveat as onToggleBookshelf. From
    -- a book: "on" routes through _safeShow; "off" is a no-op because
    -- nothing is visible to hide. (Issue #27.)
    if self.ui and self.ui.document then
        if visible then self:_safeShow() end
        return true
    end
    if visible then
        if not self:_isShowing() then self:_safeShow() end
    else
        if self:_isShowing() then UIManager:close(_live_widget) end
    end
    return true
end

function Bookshelf:_takeOver(fm_instance)
    -- Skip when _safeShow has already shown bookshelf in the current
    -- close-cycle. showFileManager re-instantiated FM, which spun up
    -- this fresh plugin instance and scheduled us via init's
    -- nextTick(_takeOver). _safeShow's show() already painted; calling
    -- show() again here would softRefresh + queue an extra EPDC commit
    -- (visible as a second flash on color panels). (#35.)
    if _suppress_close_document_show then
        return
    end
    -- Leave FileManager loaded *underneath* Bookshelf — don't close it. Two
    -- reasons:
    --   1. KOReader's standard menu (FileManagerMenu top-zone tap/swipe) is
    --      registered against the FM instance via touch zones; if we close
    --      FM, those gestures have nowhere to land and the system menu
    --      stops working anywhere on the home screen.
    --   2. Closing back out of Bookshelf (e.g. user dismisses it through a
    --      future "show file browser" path) hits FM directly with no need
    --      to re-instantiate.
    -- Bookshelf paints fully opaque (white page bg) over FM, so there's no
    -- visible bleed-through; the only cost is a few hundred KB of FM widget
    -- tree in memory, which is acceptable on every target device.
    -- fm_instance is kept in the signature for diagnostic use only —
    -- closing it is intentional dead code now.
    self:show()
end

-- Bookshelf:onShow — fired when our host (FileManager) is shown via
-- UIManager:show. Propagates SYNCHRONOUSLY through the host's children,
-- before anything outside the show call has a chance to run.
--
-- The reader→home path goes: ReaderUI:onClose → ... → showFileManager →
-- FileManager:new (which instantiates this plugin instance and runs init,
-- scheduling _takeOver on a nextTick) → UIManager:show(fm). After
-- UIManager:show returns, the synchronous chain continues with various
-- event handling (PathChanged, etc), and at some point a forceRePaint
-- fires (e.g. CoverBrowser's BookInfoManager scanning Calibre metadata)
-- which paints FileManager onto Screen.bb before our nextTick has a
-- chance to add bookshelf on top. The user sees FileManager briefly.
--
-- Catching Show synchronously creates the bookshelf widget on top of
-- FileManager before any forceRePaint can fire. The
-- init+nextTick(_takeOver) path becomes a no-op fallback via show()'s
-- idempotency check.
function Bookshelf:onShow()
    if G_reader_settings:readSetting("start_with") ~= "bookshelf" then return end
    if self.ui and self.ui.document then return end
    if _live_widget and UIManager:isWidgetShown(_live_widget) then return end
    -- CoverBrowser disabled: every code path that touches BIM crashes.
    -- Bail silently here (init showed the notification once); just let
    -- FM stay visible. (#49.)
    local ok_repo, Repo = pcall(require, "lib/bookshelf_book_repository")
    if not (ok_repo and Repo and Repo.hasBookInfoManager
            and Repo.hasBookInfoManager()) then
        return
    end
    self:show()
end

-- ---------------------------------------------------------------------------
-- Close-document hook
-- ---------------------------------------------------------------------------

-- KOReader's main loop only quits when the UIManager window stack empties
-- (uimanager.lua:1474-1478). BookshelfWidget is a separate top-level window,
-- so when the user picks Exit, the host (FM or Reader) is removed but the
-- overlay remains and the loop keeps running. (Issue #15.)
--
-- We disambiguate exit from FM↔Reader transitions via `tearing_down`:
-- KOReader sets it on the host that's transitioning to the other
-- (filemanager.lua:837, readerui.lua:588) but not on a real exit. The
-- Reader→Home path (folder tab) doesn't set it either, but that's fine:
-- onCloseDocument schedules a nextTick(show) for that case and show()'s
-- idempotency check adopts whatever live widget already exists. So
-- closing the widget here is safe — either a fresh one comes back on
-- the next tick, or the stack drains and KOReader exits.
-- Bookshelf:onPathChanged(path) — fired when the FileManager underneath us
-- navigates (filemanager.lua emits PathChanged on changeToPath). This fires
-- for any folder navigation while our overlay is up: folder shortcuts, the
-- parent/home gestures, or any plugin/gesture that jumps to a folder. Rather
-- than leave the user staring at a stale overlay covering the folder they just
-- navigated to, follow the navigation: drill the bookshelf into that folder so
-- browsing stays inside the library view. The folder is pushed onto the
-- breadcrumb stack, so a swipe-back returns to where the user was before.
--
-- Guards: never while a document is open (we're not the home view then), only
-- when the overlay is actually shown, and only when the path differs from
-- where the overlay opened -- the last check skips the PathChanged that
-- FileManager fires during our own takeover (same path).
function Bookshelf:onPathChanged(path)
    if self.ui and self.ui.document then return end
    if not (_live_widget and UIManager:isWidgetShown(_live_widget)) then return end
    if not path or path == "" then return end
    -- Absorb the single PathChanged that FileManager fires while Bookshelf is
    -- taking over the home screen (same path the overlay opened over).
    -- Consume it ONCE, then forget. Previously the snapshot stayed set for the
    -- rest of the session, so re-selecting that same folder later (e.g. a
    -- folder shortcut to a folder you'd visited before, after switching chips)
    -- was silently swallowed -- it looked like nothing happened (issue #88
    -- follow-up). changeToPath re-emits PathChanged even for the current
    -- folder, so this guard was the only thing suppressing the re-navigation.
    if path == _overlay_open_path then
        _overlay_open_path = nil
        return
    end
    -- Don't re-drill the folder we're already showing: a redundant PathChanged
    -- echo for the current drilldown would push a duplicate breadcrumb entry.
    -- (Reading the widget's drilldown stack here mirrors how this file already
    -- reaches into _live_widget for _expandFolder / the window-stack walk.)
    local dd  = _live_widget._drilldown_path
    local top = dd and dd[#dd]
    if top and top.kind == "folder" and top.payload and top.payload.path == path then
        return
    end
    if _live_widget._expandFolder then
        local label = path:match("([^/]+)/?$") or path
        _live_widget:_expandFolder{ path = path, label = label }
    end
end

function Bookshelf:onCloseWidget()
    if not _live_widget then return end
    if self.ui and self.ui.tearing_down then return end
    if not UIManager:isWidgetShown(_live_widget) then return end
    UIManager:close(_live_widget)
end

function Bookshelf:onCloseDocument()
    -- The walk cache has a 30s TTL; sideloaded / moved / mtime-changed files
    -- surface within that window without an explicit invalidate. Skipping
    -- invalidation here avoids re-walking the entire library + per-candidate
    -- meta build on every close-book → home transition (the common case).

    -- The just-closed file's stats DID change (new pages read), so its
    -- cached enrichStats fields should be dropped — the hero rebuild that
    -- follows must see the new totals. Targeted to the closed file only.
    local Repo = require("lib/bookshelf_book_repository")
    if Repo and self.ui and self.ui.document and self.ui.document.file then
        local fp = self.ui.document.file
        if Repo.invalidateStatsCache then Repo.invalidateStatsCache(fp) end
        -- Same reasoning for the progress cache: percent_finished /
        -- summary.status are now stale for this file specifically.
        if Repo.invalidateProgressCache then Repo.invalidateProgressCache(fp) end
    end
    -- The just-closed book jumped to the top of ReadHistory and its progress
    -- moved, so any chip whose SORT depends on read state has a stale cached
    -- order. The Recent chip is the visible casualty (issue 85): its tab sort
    -- {last_opened, reverse} routes through the predicate/cache path, so the
    -- book didn't pop to the top until a manual swipe-down. Drop just those
    -- read-state-sorted cache entries (walk cache stays warm) so the
    -- softRefresh shelf-swap on return re-sorts with current read times.
    if Repo and Repo.invalidateReadStateCache then
        Repo.invalidateReadStateCache()
    end

    -- Only re-show Bookshelf if the user is actually returning to "home"
    -- — not if the Reader is closing this document only to immediately
    -- open another. ReaderUI sets tearing_down=true (readerui.lua:588)
    -- when it's about to be replaced by a new ReaderUI; on a real home
    -- transition (folder tab, "File browser" end-of-doc action) it stays
    -- false, which is exactly the case where we want to show.
    --
    -- (The previous gate here was "self.ui.document is still set" — but
    -- the CloseDocument event fires inside ReaderUI:onClose *before*
    -- closeDocument() nils self.document, so that check always returned
    -- early and the nextTick(show) below never fired. The result was an
    -- FM flash whenever bookshelf wasn't already on the stack.)
    --
    -- Re-show Bookshelf on close only when it is the live home — i.e. its
    -- widget is on the stack, which is true exactly when the book was opened
    -- from Bookshelf (issue #98 decouple; #110 "return to where you came
    -- from"). This covers a user on any "Start with" who opened Bookshelf via
    -- gesture and read from it. A user who closed Bookshelf and opened a book
    -- from the raw FileManager matches neither and falls through to KOReader's
    -- normal file-browser path — so they stay in the FileManager on close,
    -- even with Start with = Bookshelf. Cold boot still lands on Bookshelf via
    -- the session-once init takeover, not this handler.
    if not self:_isShowing() then
        return
    end
    if self.ui and self.ui.tearing_down then return end
    -- _safeShow already scheduled its own show() after the close+showFM
    -- work; skipping ours here avoids a duplicate show()+softRefresh
    -- which would queue an extra EPDC commit (visible as a second
    -- flash on color panels). Pattern adapted from komadorirobin's
    -- fork.
    if _suppress_close_document_show then
        return
    end
    -- Normal path (close-document not via _safeShow, e.g. exit-to-FM
    -- from KOReader's own menu): schedule show so bookshelf reappears
    -- on the next tick. self:show()'s refresh path handles the repaint
    -- without exposing FileManager.
    UIManager:nextTick(function()
        self:show()
    end)
end

-- ---------------------------------------------------------------------------
-- Updates / dev-branch install
-- ---------------------------------------------------------------------------
-- Mirrors bookends's flow (bookends_updater.lua + Bookends:checkForUpdates,
-- editDevBranch, resetToStableRelease, backgroundUpdateCheck). Lets the user
-- bring new bookshelf code onto the device without an SSH push from the
-- laptop — useful when away from the home network.
--
-- Settings written here all use the bookshelf_ prefix on G_reader_settings:
--   bookshelf_dev_branch          — empty for stable, branch name for branch path
--   bookshelf_last_install_source — "release" or "branch:<name>"
--   bookshelf_check_updates       — boolean: silent wake-time check

-- Lazy-required inside each entry point: the updater is menu/wake-time
-- functionality most sessions never reach, so it shouldn't cost plugin
-- load time. require() memoizes, so repeat calls are table lookups.
local function _updater()
    return require("lib/bookshelf_updater")
end

-- Branch-aware update entry: if a dev branch is configured, install that
-- branch's latest tip (no release needed). Otherwise hit the GitHub
-- releases API and offer the latest stable. Both paths share the same
-- download / unpack / restart-prompt pipeline inside Updater.install.
function Bookshelf:checkForUpdates()
    local Updater = _updater()
    if self.dev_branch and self.dev_branch ~= "" then
        local branch = self.dev_branch
        Updater.installBranch(branch, function()
            self.last_install_source = "branch:" .. branch
            BookshelfSettings.save("last_install_source", self.last_install_source)
            G_reader_settings:flush()
        end)
    else
        Updater.check(function()
            self.last_install_source = "release"
            BookshelfSettings.save("last_install_source", "release")
            G_reader_settings:flush()
        end)
    end
end

-- Open a single-line dialog to set / change / clear the dev branch.
function Bookshelf:editDevBranch(touchmenu_instance)
    local InputDialog = require("ui/widget/inputdialog")
    local dlg
    dlg = InputDialog:new{
        title       = _("Development branch"),
        input       = self.dev_branch or "",
        input_hint  = _("Branch name (leave empty for stable)"),
        buttons = {{
            {
                text     = _("Cancel"),
                id       = "close",
                callback = function() UIManager:close(dlg) end,
            },
            {
                text             = _("Save"),
                is_enter_default = true,
                callback         = function()
                    local raw = dlg:getInputText() or ""
                    local trimmed = raw:gsub("^%s+", ""):gsub("%s+$", "")
                    self.dev_branch = trimmed
                    BookshelfSettings.save("dev_branch", trimmed)
                    G_reader_settings:flush()
                    UIManager:close(dlg)
                    if touchmenu_instance and touchmenu_instance.updateItems then
                        touchmenu_instance:updateItems()
                    end
                end,
            },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

-- Trigger a full BIM metadata scan of the library directory. Uses
-- extractBooksInDirectory which provides interactive progress dialogs and
-- handles recursive/refresh/prune choices. After completion, invalidates
-- Repo's caches so the next Bookshelf open picks up the fresh data.
function Bookshelf:scanAllMetadata()
    local ok, BIM = pcall(require, "bookinfomanager")
    if not ok or not BIM or type(BIM.extractBooksInDirectory) ~= "function" then
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{
            text    = _("Book metadata scanner not available.\nInstall the CoverBrowser plugin to enable it."),
            timeout = 4,
        })
        return
    end
    local home = G_reader_settings:readSetting("home_dir") or "/"
    -- BIM:extractBooksInDirectory uses Trapper:confirm for four prompts
    -- in fixed order: Continue / Recursive / Refresh / Prune. We don't
    -- need to ask the user about the first two — they already chose
    -- this menu item (= Continue), and we always want to recurse into
    -- subdirectories under home_dir (= Here and under). So we
    -- auto-answer the first two and let the user respond to the
    -- meaningful Refresh and Prune prompts.
    --
    -- Trapper:confirm requires running inside a coroutine started by
    -- Trapper:wrap — otherwise it silently returns true for EVERY
    -- prompt. That's how the first run of this menu item silently
    -- enabled "Refresh existing", which combined with INSERT OR
    -- REPLACE wiped all has_cover / cover_bb rows.
    --
    -- cover_specs MUST be supplied even if the user only wants a
    -- metadata pass: with cover_specs = nil and Refresh = true, every
    -- existing row's cover columns get replaced with NULLs. Hero card
    -- covers are ~30% of screen width × 1.5 aspect — match those.
    local Screen  = require("device").screen
    local Trapper = require("ui/trapper")
    local hero_w  = math.floor(Screen:getWidth() * 0.30)
    local hero_h  = math.floor(hero_w * 1.5)
    Trapper:wrap(function()
        local original_confirm = Trapper.confirm
        local prompt_idx = 0
        Trapper.confirm = function(self, text, cancel_text, ok_text)
            prompt_idx = prompt_idx + 1
            -- 1: "This will extract metadata…" → Continue
            -- 2: "Also extract from subdirectories?" → Here and under
            if prompt_idx <= 2 then return true end
            -- 3: Refresh, 4: Prune — pass through to the user.
            return original_confirm(self, text, cancel_text, ok_text)
        end
        local ok, err = pcall(BIM.extractBooksInDirectory, BIM, home, {
            max_cover_w = hero_w,
            max_cover_h = hero_h,
        })
        Trapper.confirm = original_confirm
        if not ok then error(err) end
        local Repo = require("lib/bookshelf_book_repository")
        Repo.invalidateWalkCache()
        -- Also drop per-chip book-list caches so the next tab render
        -- re-reads from the fresh BIM data rather than the pre-scan
        -- cached order. Without this the user has to switch tabs to
        -- see the newly-populated authors/series come through.
        if Repo.invalidateBookCache then
            Repo.invalidateBookCache("scanAllMetadata")
        end
    end)
end

-- Clear dev branch + install latest stable release. Used when escaping a
-- broken branch back to a known-good release.
function Bookshelf:resetToStableRelease()
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = _("This will clear the development branch setting and install the latest stable release of Bookshelf, then restart KOReader. Continue?"),
        ok_text = _("Reset"),
        ok_callback = function()
            self.dev_branch = ""
            BookshelfSettings.save("dev_branch", "")
            G_reader_settings:flush()
            _updater().installLatestStable(function()
                self.last_install_source = "release"
                BookshelfSettings.save("last_install_source", "release")
                G_reader_settings:flush()
            end)
        end,
    })
end

-- Silent background poll: checks at most once an hour, only when the user
-- has opted in via "Notify on wake when update available". Surfaces a
-- short notification if a newer release tag is found.
function Bookshelf:backgroundUpdateCheck()
    if not self.check_updates then return end
    _updater().checkBackground(function(ver)
        local Notification = require("ui/widget/notification")
        Notification:notify(_("Bookshelf update available: v") .. ver,
            Notification.SOURCE_ALWAYS_SHOW)
    end)
end

-- Wake-from-sleep also fires backgroundUpdateCheck, mirroring bookends.
-- The Updater's 1-hour internal cache prevents wake-spam.
function Bookshelf:onResume()
    self:_repaintAfterWake()
    self:backgroundUpdateCheck()
end

-- Some Kindles use a lighter "standby" mode that broadcasts
-- LeaveStandby instead of Resume on wake. Hook both so the screensaver
-- pixels can't linger on top of the home regardless of which path the
-- device took.
function Bookshelf:onLeaveStandby()
    self:_repaintAfterWake()
end

-- NetworkConnected / NetworkDisconnected are broadcast by NetworkMgr
-- on every Wi-Fi state change (manager.lua:68/95/372). Some home-
-- replacement plugins react to these by re-showing their own
-- homescreen widget on top of bookshelf -- see
-- _evictHomescreenOverlay below for the full pattern. Issue #77.
function Bookshelf:onNetworkConnected()
    self:_evictHomescreenOverlay()
end

function Bookshelf:onNetworkDisconnected()
    self:_evictHomescreenOverlay()
end

-- Some home-replacement plugins react to system broadcasts
-- (NetworkConnected, NetworkDisconnected, Resume, LeaveStandby,
-- ReaderUI close → FM re-init, etc.) by closing and re-showing their
-- own homescreen widget. The re-show pushes onto the TOP of the
-- UIManager stack, BURYING bookshelf underneath. The intruder
-- widget is covers_fullscreen, so it intercepts all input and
-- bookshelf becomes unreachable until the user manually toggles it
-- off and on again from the menu. (SimpleUI's _refreshCurrentView
-- -> _navigate("home", ...) flow is the observed-in-the-wild case;
-- the same pattern can come from any plugin that competes for the
-- home-screen slot.)
--
-- When start_with == "bookshelf", any covers_fullscreen widget above
-- us is unwanted -- bookshelf IS the home, and the intruder is
-- dormant placeholder state that doesn't belong on top. Modals
-- (InfoMessage, ConfirmBox, InputDialog, KOReader's TouchMenu, etc.)
-- don't set covers_fullscreen, so they're naturally excluded by the
-- flag check; we only catch widgets that structurally claim to be a
-- home-screen replacement.
--
-- nextTick deferral is required: the offending plugin's handler and
-- ours often fire in the same broadcastEvent dispatch in non-
-- deterministic order. Running inline can hit the stack BEFORE the
-- intruder has been pushed, finding nothing to close. Deferring
-- past the current dispatch guarantees we see the post-cascade
-- state.
--
-- Closing the offending widget is sufficient -- UIManager:close
-- marks its (fullscreen) dimen dirty automatically and uses a nil
-- refresh type (uimanager.lua:1119) so no explicit refresh is
-- enqueued. The natural repaint pass renders bookshelf in its
-- place via incremental refresh. No setDirty / forceRePaint needed
-- (and "full" would cause an unnecessary flash).
--
-- Call sites: network events (onNetworkConnected /
-- onNetworkDisconnected), wake events (folded into
-- _repaintAfterWake which fires on onResume / onLeaveStandby), and
-- the tail of Bookshelf:show() (so every reader-return,
-- toggle-on, and takeover flow gets defense for free). The walk is
-- a cheap no-op when nothing's on top, so the redundancy across
-- multiple trigger paths costs essentially nothing.
--
-- Complements the existing homescreen-overlay cleanup in
-- bookshelf_toggle (main.lua:466-479): that path walks the whole
-- stack and needs the name=="homescreen" filter to avoid closing FM
-- or bookshelf themselves. We walk only above bookshelf, so the
-- index filter already protects the widgets below.
function Bookshelf:_evictHomescreenOverlay()
    UIManager:nextTick(function()
        -- _isShowing() (bookshelf on the stack) is the decoupled "are we the
        -- live home?" test (issue #98) — it replaces the old
        -- start_with=="bookshelf" gate, so the eviction defends bookshelf
        -- whenever it is the home, regardless of the restart setting.
        if not self:_isShowing() then return end
        -- CRITICAL (issue #82): never touch the window stack while a
        -- book is open. _isShowing() is true even when bookshelf is
        -- backgrounded UNDER ReaderUI (it only checks stack presence,
        -- not topmost), and ReaderUI is itself covers_fullscreen and
        -- sits above bookshelf. _repaintAfterWake fires this on wake;
        -- without this guard the loop below closed the active reader,
        -- crashing KOReader on every wake-from-sleep while reading.
        local ok_rui, ReaderUI = pcall(require, "apps/reader/readerui")
        if ok_rui and ReaderUI and ReaderUI.instance then return end
        if not UIManager._window_stack then return end
        local bookshelf_idx
        for i, entry in ipairs(UIManager._window_stack) do
            if entry and entry.widget == _live_widget then
                bookshelf_idx = i
                break
            end
        end
        if not bookshelf_idx then return end
        for i = #UIManager._window_stack, bookshelf_idx + 1, -1 do
            local w = UIManager._window_stack[i]
                and UIManager._window_stack[i].widget
            -- Only close home-replacement widgets, identified by the
            -- conventional "homescreen" widget name. covers_fullscreen
            -- ALONE is too broad -- ReaderUI (name "ReaderUI") and the
            -- screensaver are also covers_fullscreen and can legitimately
            -- sit above bookshelf; closing them is exactly the #82 crash.
            -- The name filter is still generic: any home-replacement
            -- plugin that names its fullscreen widget "homescreen"
            -- (SimpleUI's does) is covered, without us having to know
            -- the plugin.
            if w and w.covers_fullscreen and w.name == "homescreen" then
                UIManager:close(w)
            end
        end
    end)
end

-- After wake, the BookshelfWidget (when it's the visible home) needs an
-- explicit setDirty — otherwise the screensaver image sits on the
-- framebuffer until something else triggers a paint. The user's
-- workaround was opening the FM menu (its close fires its own setDirty
-- which incidentally repaints us); now we do it ourselves. "full" forces
-- a panel-wide e-ink refresh which clears any ghost pixels — the right
-- hammer right after wake when the framebuffer state may be stale.
--
-- We also run _evictHomescreenOverlay because wake events trigger the
-- same plugin-refresh cascade as network events: a home-replacement
-- plugin may close and re-show its homescreen widget on top of
-- bookshelf as part of its onResume / onLeaveStandby handler, burying
-- us. The eviction logic is cheap when there's nothing on top
-- (single stack walk), so calling it here is essentially free
-- defence.
function Bookshelf:_repaintAfterWake()
    -- Stay completely inert while a gesture-unlock screensaver is still
    -- showing (Device.screen_saver_lock, set by ScreenSaverLockWidget
    -- when screensaver_delay == "gesture"). In that state KOReader is
    -- waiting for the user's "Exit sleep screen" gesture; bookshelf
    -- repainting over the lock's "waiting for gesture" prompt -- or its
    -- eviction walk touching the stack -- can leave the device stuck,
    -- unable to register the unlock gesture (issue #84, reproducible on
    -- Kindle Oasis with a corner-tap exit gesture + bookshelf as home).
    -- The lock's own onClose does a full panel refresh once the user
    -- finally unlocks, so bookshelf still gets repainted then.
    if require("device").screen_saver_lock then return end
    if self:_isShowing() then
        UIManager:setDirty(_live_widget, "full")
    end
    self:_evictHomescreenOverlay()
end

-- KOReader broadcasts BookMetadataChanged when a book's metadata is edited
-- (status / rating / tags / series / authors / cover / etc) from any entry
-- point: the long-press menu on a shelf cover, FileManager's book-info
-- screen, the History panel, the reader's book-info screen. Any of those
-- can shift a book's membership in a status- or filter-driven chip, or
-- reorder it within a sort that depends on the changed field.
--
-- Without this handler, bookshelf's per-chip result caches stay stale --
-- the user has to swipe-down or restart to see the change (issue #40).
-- The prop_updated arg is sometimes nil (broadcast-everything cases),
-- sometimes a single field name, and on some KOReader versions / async paths
-- a table of changed props; we treat every change as potentially
-- membership-affecting since chips can sort or filter on any field.
--
-- Coalescing: a single user action can fire BookMetadataChanged twice
-- (e.g. filemanagerbookinfo close_callback emits one event with the
-- specific prop_updated and a second with nil for the summary-folder
-- side-effect). Cache invalidation is cheap and runs every time; the
-- rebuild is deferred to nextTick and gated by a pending flag so we
-- repaint at most once per user action.
--
-- Hidden-bookshelf case: when bookshelf isn't visible (reader on top, or
-- editing from History over FileManager), invalidating the cache alone
-- isn't enough -- softRefresh's _needsReaderReturnShelfRefresh gate is
-- keyed on chip+sort and doesn't know about metadata edits, so a status
-- change that should re-shuffle membership would be skipped. The flag on
-- the widget forces softRefresh down the heavy path on next return.
function Bookshelf:onBookMetadataChanged(prop_updated)
    local Repo = require("lib/bookshelf_book_repository")
    -- Progress cache also stores summary.status -- drop the whole map.
    -- The event doesn't carry the filepath, so we can't be surgical.
    if Repo.invalidateProgressCache then
        Repo.invalidateProgressCache()
    end
    if Repo.invalidateBookCache then
        -- prop_updated is usually nil or a single field-name string, but some
        -- KOReader versions / async close paths (e.g. exiting a book via a
        -- gesture shortcut) pass a TABLE of changed props; only fold a string
        -- into the reason label, never concatenate a table (issue #164).
        local tag = (type(prop_updated) == "string") and (":" .. prop_updated) or ""
        Repo.invalidateBookCache("BookMetadataChanged" .. tag)
    end
    if not _live_widget then return end
    if self:_isShowing() then
        if self._metadata_rebuild_pending then return end
        self._metadata_rebuild_pending = true
        UIManager:nextTick(function()
            self._metadata_rebuild_pending = false
            if _live_widget and self:_isShowing() and _live_widget._rebuild then
                _live_widget:_rebuild()
                UIManager:setDirty(_live_widget, "ui")
            end
        end)
    else
        _live_widget._metadata_dirty_force_full_refresh = true
    end
end

-- KOReader fires SetMixedSorting via the dispatcher (gesture / action)
-- path but NOT from the File Browser's Sort menu — that callback
-- writes G_reader_settings:collate_mixed directly and calls
-- FileChooser:refreshPath() without dispatching an Event. So this
-- hook only covers the dispatcher path; the menu path is caught by
-- BookshelfWidget:paintTo, which fires when the FM menu closes and
-- bookshelf returns to the top of the widget stack. Both paths end
-- up calling _rebuild, whose internal polling check is the single
-- source of truth for cache invalidation.
function Bookshelf:onSetMixedSorting(toggle)
    if _live_widget and self:_isShowing() and _live_widget._rebuild then
        _live_widget:_rebuild()
        UIManager:setDirty(_live_widget, "ui")
    end
end

-- When KOReader toggles color rendering at runtime, flush the bookshelf_color
-- hex cache so progress-bar colors pick up the new mode, then rebuild the
-- live widget if it is currently shown.
function Bookshelf:onColorRenderingUpdate()
    local ok, Color = pcall(require, "lib/bookshelf_color")
    if ok then Color.flushCache() end
    if _live_widget and _live_widget._rebuild then
        _live_widget:_rebuild()
        UIManager:setDirty(_live_widget, "ui")
    end
end

-- deletePluginSettings(): called by KOReader's plugin manager AFTER the
-- .koplugin directory has been removed, when the user opted in to "also
-- delete plugin settings". (Available in KOReader nightly via upstream
-- PR #15240, expected in the next stable release.) Anything outside the
-- install directory we need to clean up:
--   - <settings_dir>/bookshelf.lua (the LuaSettings file the store writes)
--   - any legacy bookshelf_* keys in G_reader_settings that the migration
--     never moved (e.g. user deleted the plugin before ever opening it
--     post-upgrade)
function Bookshelf:deletePluginSettings()
    local DataStorage = require("datastorage")
    local settings_dir = DataStorage:getSettingsDir()
    os.remove(settings_dir .. "/bookshelf.lua")
    os.remove(settings_dir .. "/bookshelf.lua.old")
    -- Clear any legacy global keys that never migrated. The migration
    -- normally drains them on first plugin init, but a "install plugin,
    -- never open it, uninstall" sequence would leave them behind.
    local PREFIX = "bookshelf_"
    local known = {
        "active_chip", "active_page", "drill_path", "tabs",
        "chips_disabled", "font_scale", "chip_font_scale",
        "chip_flex_widths", "calibre_metadata", "latest_walk_depth",
        "show_close_msg", "show_series_num",
        "progress_fill", "progress_track", "bookmark_color",
        "badge_fg", "badge_bg",
        "folder_overlay_bg", "folder_overlay_fg",
        "progress_badge_enabled", "progress_bar_enabled",
        "progress_bookmark_enabled", "progress_enabled",
        "sort_all_mixed", "sort_all_reverse",
        "check_updates", "dev_branch", "last_install_source",
    }
    for _i, k in ipairs(known) do
        G_reader_settings:delSetting(PREFIX .. k)
    end
    for _i, chip in ipairs({ "all", "recent", "latest", "series", "authors",
                            "genres", "tags", "favorites" }) do
        G_reader_settings:delSetting(PREFIX .. "sort_" .. chip)
    end
end

return Bookshelf
