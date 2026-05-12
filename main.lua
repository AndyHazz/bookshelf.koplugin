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
local UIManager       = require("ui/uimanager")
local logger          = require("logger")
local _               = require("bookshelf_i18n").gettext
local T               = require("ffi/util").template
local Profiles        = require("bookshelf_profiles")

local Bookshelf = WidgetContainer:extend{
    name        = "bookshelf",
    is_doc_only = false, -- must be false: hook fires in Reader context
}

require("bookshelf_colour_palette").attach(Bookshelf)

-- Tracks the live BookshelfWidget singleton across plugin instances. Two
-- Bookshelf instances exist — one attached to FM, one to Reader — but the
-- widget itself is a single shared overlay. The tracker lets either
-- instance's onCloseWidget find and dismiss the overlay during a KOReader
-- exit, so the UIManager window stack can drain to zero.
local _live_widget = nil

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
        if event then event._bookshelf_from_broadcast = true end
        return orig(self_um, event, ...)
    end
end

function Bookshelf:init()
    _installBroadcastTag()
    -- Cache update-related settings on the instance for the menu's text_func
    -- closures. Defaults match bookends: branch empty, source = "release",
    -- background check OFF (opt-in via the menu toggle).
    self.dev_branch          = G_reader_settings:readSetting("bookshelf_dev_branch") or ""
    self.last_install_source = G_reader_settings:readSetting("bookshelf_last_install_source") or "release"
    self.check_updates       = G_reader_settings:isTrue("bookshelf_check_updates")

    -- Patch the start_with menu so users can pick Bookshelf as their home.
    self:_registerStartWithMenu()

    -- Add bookshelf anchors to the FM menu_order so our entries don't get
    -- the "NEW:" prefix MenuSorter applies to anything orphan-positioned.
    self:_extendMenuOrder()

    -- Register "Open Bookshelf" in the main menu (works in both FM and Reader).
    self.ui.menu:registerToMainMenu(self)

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

local function _isWidgetTopmost(widget)
    if not widget then return false end
    if UIManager.topdown_widgets_iter then
        for w in UIManager:topdown_widgets_iter() do
            if not w.invisible and not w.toast then return w == widget end
        end
    end
    if UIManager.getTopmostVisibleWidget then
        return UIManager:getTopmostVisibleWidget() == widget
    end
    if UIManager.getNthTopWidget then
        return UIManager:getNthTopWidget(1) == widget
    end
    return UIManager:isWidgetShown(widget)
end

local function _isLiveWidgetTopmost()
    return _live_widget and UIManager:isWidgetShown(_live_widget)
        and _isWidgetTopmost(_live_widget)
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
    local S = require("bookshelf_settings")
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
        text                = _("Choose Bookshelf tabs"),
        enabled_func        = function() return outer:_isShowing() end,
        separator           = true,
        sub_item_table_func = function()
            S._bw = _live_widget
            return S:_chipsSubItems()
        end,
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

    menu_items.bookshelf_advanced = {
        text           = _("Advanced settings"),
        sub_item_table = {
            {
                text     = _("Scan all library metadata"),
                callback = function(touchmenu_instance)
                    if touchmenu_instance then
                        UIManager:close(touchmenu_instance)
                    end
                    UIManager:nextTick(function() outer:scanAllMetadata() end)
                end,
            },
            {
                text     = _('"Latest" walk depth'),
                callback = function() S:_pickLatestDepth() end,
            },
            {
                text = _("Fade finished book covers"),
                help_text = _("Lightens covers for books marked as finished in Bookshelf."),
                checked_func = function()
                    return G_reader_settings:isTrue("bookshelf_fade_finished_books")
                end,
                keep_menu_open = true,
                callback = function()
                    local enabled = G_reader_settings:isTrue("bookshelf_fade_finished_books")
                    G_reader_settings:saveSetting("bookshelf_fade_finished_books", not enabled)
                    G_reader_settings:flush()
                    if S._bw and S._bw._rebuild then
                        S._bw:_rebuild()
                        UIManager:setDirty(S._bw, "ui")
                    end
                end,
            },
            {
                text = _("Fade finished folders"),
                help_text = _("Lightens folders where every book inside is marked as finished."),
                checked_func = function()
                    return G_reader_settings:isTrue("bookshelf_fade_finished_folders")
                end,
                keep_menu_open = true,
                callback = function()
                    local enabled = G_reader_settings:isTrue("bookshelf_fade_finished_folders")
                    G_reader_settings:saveSetting("bookshelf_fade_finished_folders", not enabled)
                    G_reader_settings:flush()
                    if S._bw and S._bw._rebuild then
                        S._bw:_rebuild()
                        UIManager:setDirty(S._bw, "ui")
                    end
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
                    if S._bw and S._bw._rebuild then
                        S._bw:_rebuild()
                        UIManager:setDirty(S._bw, "ui")
                    end
                end,
            },
        },
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
function Bookshelf:show(profile_key)
    -- Discard a stale self._widget without a stack walk. _live_widget
    -- is the canonical "what's actually on screen" pointer (set/cleared
    -- in sync with the widget's _on_close_callback), so anything else
    -- this instance is pointing at can't be the live one.
    if self._widget and self._widget ~= _live_widget then
        self._widget = nil
    end
    -- If another home UI (notably SimpleUI's "always start on Home" path
    -- after wake) has been shown on top of Bookshelf, the widget is still in
    -- UIManager's stack but is no longer the visible surface. Treat that as
    -- stale: remove it so this explicit open can create a fresh topmost
    -- Bookshelf. Otherwise navbar actions only refresh the hidden instance.
    if _live_widget and UIManager:isWidgetShown(_live_widget)
            and not _isWidgetTopmost(_live_widget) then
        local stale = _live_widget
        logger.dbg("[bookshelf] closing covered live widget before show")
        UIManager:close(stale, "ui")
        if self._widget == stale then self._widget = nil end
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
        if profile_key and not (self._widget.profile and self._widget.profile.key == profile_key) then
            self._widget:setProfile(profile_key)
            return
        end
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
    local BookshelfWidget = require("bookshelf_widget")
    self._widget = BookshelfWidget:new{ profile_key = profile_key }
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

function Bookshelf:_notifyOpeningBookshelf(profile_key)
    local label = profile_key == "comics" and _("Comics")
        or profile_key == "prose" and _("Books")
        or _("Bookshelf")
    local ok, Notification = pcall(require, "ui/widget/notification")
    if ok and Notification and Notification.notify then
        Notification:notify(_("Opening ") .. label, Notification.SOURCE_ALWAYS_SHOW, true)
        return
    end
    local ok_info, InfoMessage = pcall(require, "ui/widget/infomessage")
    if ok_info and InfoMessage then
        UIManager:show(InfoMessage:new{
            text    = _("Opening ") .. label,
            timeout = 1,
        })
        UIManager:forceRePaint()
    end
end

function Bookshelf:_showAfterReaderReturn(profile_key)
    if not self._widget then
        self:show(profile_key)
        return
    end
    -- Same rotation restore as show(), but without the full widget rebuild.
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
    if profile_key and not (self._widget.profile and self._widget.profile.key == profile_key) then
        self._widget:setProfile(profile_key)
        if self._widget._startStatusTimer then
            self._widget:_startStatusTimer()
        end
        return
    end
    if self._widget.refreshAfterReaderReturn then
        self._widget:refreshAfterReaderReturn()
    else
        self:show(profile_key)
    end
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
    Dispatcher:registerAction("open_bookshelf_prose", {
        category = "none",
        event    = "OpenBookshelfProse",
        title    = _("Bookshelf: open Books profile"),
        general  = true,
    })
    Dispatcher:registerAction("open_bookshelf_comics", {
        category = "none",
        event    = "OpenBookshelfComics",
        title    = _("Bookshelf: open Comics profile"),
        general  = true,
    })
    Dispatcher:registerAction("open_bookshelf_auto", {
        category = "none",
        event    = "OpenBookshelfAuto",
        title    = _("Bookshelf: open matching profile"),
        general  = true,
    })
end

-- _safeShow — show bookshelf, doing the right thing depending on whether
-- the action was invoked from FM or Reader.
--
-- Fast path: if Bookshelf is already under Reader in UIManager's stack,
-- close Reader directly. This skips ReaderUI:onHome()'s showFileManager()
-- call, which otherwise builds SimpleUI/FileManager only to cover it with
-- Bookshelf one tick later.
--
-- Fallback: if Bookshelf is not in the stack, route through onHome() so a
-- FileManager instance is created underneath. Bookshelf forwards top-zone
-- menu gestures to FileManager.instance, so direct onClose() from a
-- start_with=last boot would leave those gestures without a receiver.
function Bookshelf:_safeShow(profile_key)
    if self.ui and self.ui.document and self.ui.onHome then
        self:_notifyOpeningBookshelf(profile_key)
        if self:_isShowing() and self.ui.onClose then
            self.ui:onClose(false)
            UIManager:nextTick(function() self:_showAfterReaderReturn(profile_key) end)
        else
            self.ui:onHome()
            -- onCloseDocument fires synchronously inside onHome → FM is
            -- foreground. We schedule bookshelf for the next tick so FM's
            -- creation/show completes first, leaving FM as the painting
            -- surface beneath the bookshelf overlay.
            UIManager:nextTick(function() self:show(profile_key) end)
        end
    else
        self:show(profile_key)
    end
end

-- Close the live widget if showing, otherwise safe-show. Mirrors the
-- "Open Bookshelf" / "Close Bookshelf" menu entry.
function Bookshelf:onToggleBookshelf()
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
    if visible then
        if not self:_isShowing() or not _isLiveWidgetTopmost() then self:_safeShow() end
    else
        if self:_isShowing() then UIManager:close(_live_widget) end
    end
    return true
end

function Bookshelf:onOpenBookshelfProfile(profile_key)
    self:_safeShow(profile_key)
    return true
end

function Bookshelf:onOpenBookshelfProse()
    self:_safeShow("prose")
    return true
end

function Bookshelf:onOpenBookshelfComics()
    self:_safeShow("comics")
    return true
end

function Bookshelf:_currentDocumentFile()
    local doc = self.ui and self.ui.document
    if doc then
        if type(doc.file) == "string" and doc.file ~= "" then
            return doc.file
        end
        if type(doc.getFileName) == "function" then
            local ok, file = pcall(function() return doc:getFileName() end)
            if ok and type(file) == "string" and file ~= "" then return file end
        end
    end
    local lastfile = G_reader_settings:readSetting("lastfile")
    if type(lastfile) == "string" and lastfile ~= "" then return lastfile end
    return nil
end

function Bookshelf:onOpenBookshelfAuto()
    local file = self:_currentDocumentFile()
    local profile_key = Profiles.matchFile(file)
    if not profile_key then
        logger.dbg("[bookshelf] open_bookshelf_auto: no profile match for " .. tostring(file))
    end
    self:_safeShow(profile_key)
    return true
end

function Bookshelf:_takeOver(fm_instance)
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
    local Repo = require("bookshelf_book_repository")
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
    -- If Bookshelf is already on the stack (the typical "open book from
    -- home, close back to home" flow now that _openBook leaves it there),
    -- self:show()'s refresh path handles the repaint without ever exposing
    -- FileManager. Fresh boot path through onCloseDocument (rare) creates
    -- a new instance.
    UIManager:nextTick(function() self:show() end)
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

local Updater = require("bookshelf_updater")

-- Branch-aware update entry: if a dev branch is configured, install that
-- branch's latest tip (no release needed). Otherwise hit the GitHub
-- releases API and offer the latest stable. Both paths share the same
-- download / unpack / restart-prompt pipeline inside Updater.install.
function Bookshelf:checkForUpdates()
    if self.dev_branch and self.dev_branch ~= "" then
        local branch = self.dev_branch
        Updater.installBranch(branch, function()
            self.last_install_source = "branch:" .. branch
            G_reader_settings:saveSetting("bookshelf_last_install_source", self.last_install_source)
            G_reader_settings:flush()
        end)
    else
        Updater.check(function()
            self.last_install_source = "release"
            G_reader_settings:saveSetting("bookshelf_last_install_source", "release")
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
                    G_reader_settings:saveSetting("bookshelf_dev_branch", trimmed)
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
        local Repo = require("bookshelf_book_repository")
        Repo.invalidateWalkCache()
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
            G_reader_settings:saveSetting("bookshelf_dev_branch", "")
            G_reader_settings:flush()
            Updater.installLatestStable(function()
                self.last_install_source = "release"
                G_reader_settings:saveSetting("bookshelf_last_install_source", "release")
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
    if _isLiveWidgetTopmost() then
        UIManager:setDirty(_live_widget, "full")
    end
end

-- When KOReader toggles colour rendering at runtime, flush the bookshelf_colour
-- hex cache so progress-bar colours pick up the new mode, then rebuild the
-- live widget if it is currently shown.
function Bookshelf:onColorRenderingUpdate()
    local ok, Colour = pcall(require, "bookshelf_colour")
    if ok then Colour.flushCache() end
    if _live_widget and _live_widget._rebuild then
        _live_widget:_rebuild()
        UIManager:setDirty(_live_widget, "ui")
    end
end

return Bookshelf
