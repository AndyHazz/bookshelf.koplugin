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

local Bookshelf = WidgetContainer:extend{
    name        = "bookshelf",
    is_doc_only = false, -- must be false: hook fires in Reader context
}

require("lib/bookshelf_colour_palette").attach(Bookshelf)

-- Tracks the live BookshelfWidget singleton across plugin instances. Two
-- Bookshelf instances exist — one attached to FM, one to Reader — but the
-- widget itself is a single shared overlay. The tracker lets either
-- instance's onCloseWidget find and dismiss the overlay during a KOReader
-- exit, so the UIManager window stack can drain to zero.
local _live_widget = nil
-- Suppresses Bookshelf:onCloseDocument's nextTick(show) for the duration
-- of a _safeShow call. _safeShow already schedules its own show() after
-- onClose+showFileManager, so onCloseDocument's parallel schedule would
-- be a duplicate, producing an extra EPDC commit (visible as an extra
-- flash on colour panels). Set true during the gesture-exit critical
-- section, false again before our deferred work runs the show. (Pattern
-- adapted from komadorirobin's fork.)
local _suppress_close_document_show = false

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
local function _cleanLegacyLayout()
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
        logger.info(string.format(
            "[bookshelf] cleaned %d legacy v1.1 files from %s",
            removed, plugin_dir))
    end
end

function Bookshelf:init()
    _installBroadcastTag()
    -- Run once per init -- no settings flag needed because the clean is
    -- idempotent and cheap (one lfs.dir scan over the plugin root).
    _cleanLegacyLayout()
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

    -- Register Dispatcher actions so users can bind gestures / keys to
    -- Bookshelf show/hide/toggle from KOReader's Gesture Manager. Required
    -- for users who run Bookshelf alongside other home-screen plugins and
    -- want a quick toggle rather than digging through the FM menu.
    self:onDispatcherRegisterActions()

    -- One silent background check per init when the user's opted in.
    self:backgroundUpdateCheck()

    -- Takeover: if start_with=bookshelf and we're in the FileManager context
    -- (no document currently being opened), close FM and present Bookshelf.
    if G_reader_settings:readSetting("start_with") == "bookshelf"
            and not (self.ui and self.ui.document) then
        -- Bookshelf depends on CoverBrowser's BookInfoManager. If
        -- CoverBrowser is disabled, every code path that touches BIM
        -- throws — pre-#49 this manifested as a crash loop on the
        -- onShow handler. Detect at init and bail with a notification
        -- so the user lands on plain FM and knows why.
        local ok_repo, Repo = pcall(require, "bookshelf_book_repository")
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
        -- gettext binding and `_("Bookshelf")` below would call a number.
        local already
        for _i, entry in ipairs(result.sub_item_table) do
            if entry.text == _("Bookshelf") then already = true; break end
        end
        if not already then
            table.insert(result.sub_item_table, {
                text    = _("Bookshelf"),
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
                return T(_("Start with: %1"), _("Bookshelf"))
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
    for _, id in ipairs(order["KOMenu:menu_buttons"]) do
        if id == "bookshelf_tab" then return end
    end
    -- Position 2: filemanager_settings stays at [1] so MenuSorter's orphan
    -- pass (which hardcodes table.insert([1], v)) doesn't dump unrelated
    -- plugin entries into the Bookshelf tab.
    table.insert(order["KOMenu:menu_buttons"], 2, "bookshelf_tab")
    order.bookshelf_tab = {
        "bookshelf_toggle",
        "bookshelf_hero_card",
        "bookshelf_shelf_tabs",
        "bookshelf_settings",
        "bookshelf_updates",
        "bookshelf_about",
    }
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
        -- Visually separate the customisation entries above from the
        -- broader Settings / Updates / About cluster below.
        separator = true,
    }

    menu_items.bookshelf_settings = {
        text                = _("Settings"),
        sub_item_table_func = function()
            S._bw = _live_widget
            return S:_settingsSubItems()
        end,
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
        self._widget:softRefresh()
        return
    end
    local BookshelfWidget = require("lib/bookshelf_widget")
    self._widget = BookshelfWidget:new{}
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
        category  = "none",
        event     = "BookshelfToggleHero",
        title     = _("Bookshelf: expand or collapse hero"),
        general   = true,
        separator = true,
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
-- on colour panels (#35).
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
    --      (escape hatch for colour-panel users who see flashing from
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
-- bookshelf's path WHEN bookshelf is the user's home (start_with =
-- "bookshelf"). For users who have start_with set to the file browser,
-- the FM tab should take them to plain FM, not bookshelf.
--
-- The default tab callback (readermenu.lua:47-54) inlines
-- onTapCloseMenu + onClose + showFileManager. We keep onTapCloseMenu
-- (otherwise the menu overlay lingers above the new layer) and replace
-- the rest with the appropriate path based on start_with.
function Bookshelf:_wireFastFileBrowserTab()
    if not (self.ui and self.ui.document and self.ui.menu) then return end
    local menu_ref = self.ui.menu
    if menu_ref._bookshelf_fm_tab_wrapped then return end
    local items = menu_ref.menu_items
    if not (items and items.filemanager) then return end
    local plugin = self
    items.filemanager.callback = function()
        if menu_ref.onTapCloseMenu then menu_ref:onTapCloseMenu() end
        if G_reader_settings:readSetting("start_with") == "bookshelf" then
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
    -- (visible as a second flash on colour panels). (#35.)
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
    local ok_repo, Repo = pcall(require, "bookshelf_book_repository")
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
    if G_reader_settings:readSetting("start_with") ~= "bookshelf" then return end
    if self.ui and self.ui.tearing_down then return end
    -- _safeShow already scheduled its own show() after the close+showFM
    -- work; skipping ours here avoids a duplicate show()+softRefresh
    -- which would queue an extra EPDC commit (visible as a second
    -- flash on colour panels). Pattern adapted from komadorirobin's
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

local Updater = require("lib/bookshelf_updater")

-- Branch-aware update entry: if a dev branch is configured, install that
-- branch's latest tip (no release needed). Otherwise hit the GitHub
-- releases API and offer the latest stable. Both paths share the same
-- download / unpack / restart-prompt pipeline inside Updater.install.
function Bookshelf:checkForUpdates()
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
            Updater.installLatestStable(function()
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
    Updater.checkBackground(function(ver)
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

-- After wake, the BookshelfWidget (when it's the visible home) needs an
-- explicit setDirty — otherwise the screensaver image sits on the
-- framebuffer until something else triggers a paint. The user's
-- workaround was opening the FM menu (its close fires its own setDirty
-- which incidentally repaints us); now we do it ourselves. "full" forces
-- a panel-wide e-ink refresh which clears any ghost pixels — the right
-- hammer right after wake when the framebuffer state may be stale.
function Bookshelf:_repaintAfterWake()
    if self:_isShowing() then
        UIManager:setDirty(_live_widget, "full")
    end
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
-- The prop_updated arg is sometimes nil (broadcast-everything cases) and
-- sometimes a single field name; we treat every change as potentially
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
        Repo.invalidateBookCache("BookMetadataChanged"
            .. (prop_updated and (":" .. prop_updated) or ""))
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

-- When KOReader toggles colour rendering at runtime, flush the bookshelf_colour
-- hex cache so progress-bar colours pick up the new mode, then rebuild the
-- live widget if it is currently shown.
function Bookshelf:onColorRenderingUpdate()
    local ok, Colour = pcall(require, "lib/bookshelf_colour")
    if ok then Colour.flushCache() end
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
        "progress_fill", "progress_track",
        "progress_badge_enabled", "progress_bar_enabled",
        "progress_bookmark_enabled", "progress_enabled",
        "sort_all_mixed", "sort_all_reverse",
        "check_updates", "dev_branch", "last_install_source",
    }
    for _, k in ipairs(known) do
        G_reader_settings:delSetting(PREFIX .. k)
    end
    for _, chip in ipairs({ "all", "recent", "latest", "series", "authors",
                            "genres", "tags", "favorites" }) do
        G_reader_settings:delSetting(PREFIX .. "sort_" .. chip)
    end
end

return Bookshelf
