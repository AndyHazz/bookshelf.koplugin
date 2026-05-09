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

local Bookshelf = WidgetContainer:extend{
    name        = "bookshelf",
    is_doc_only = false, -- must be false: hook fires in Reader context
}

-- ---------------------------------------------------------------------------
-- init
-- ---------------------------------------------------------------------------

function Bookshelf:init()
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
            entry.callback = function(...)
                if orig_cb then orig_cb(...) end
                if plugin._isShowing and plugin:_isShowing()
                        and plugin._widget then
                    UIManager:close(plugin._widget)
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
                callback = function()
                    G_reader_settings:saveSetting("start_with", "bookshelf")
                    G_reader_settings:flush()
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
        "bookshelf_updates",
        "bookshelf_advanced",
        "bookshelf_about",
    }
end

-- True when the BookshelfWidget instance is in the UIManager window stack
-- (i.e. it's currently shown over FM, regardless of whether a Reader is
-- ALSO on top of it). Cleared via _on_close_callback when UIManager:close
-- removes our widget from the stack.
function Bookshelf:_isShowing()
    if not self._widget then return false end
    local stack = UIManager._window_stack
    if type(stack) ~= "table" then return false end
    for _i, win in ipairs(stack) do
        if win.widget == self._widget then return true end
    end
    return false
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
        callback = function()
            if outer:_isShowing() then
                UIManager:close(outer._widget)
            else
                outer:show()
            end
        end,
        separator = true,
    }

    menu_items.bookshelf_hero_card = {
        text                = _("Edit book detail view"),
        enabled_func        = function() return outer:_isShowing() end,
        sub_item_table_func = function()
            S._bw = outer._widget
            return S:_heroSubItems()
        end,
    }

    menu_items.bookshelf_shelf_tabs = {
        text                = _("Choose Bookshelf tabs"),
        enabled_func        = function() return outer:_isShowing() end,
        separator           = true,
        sub_item_table_func = function()
            S._bw = outer._widget
            return S:_chipsSubItems()
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
                    local ok, Repo = pcall(require, "book_repository")
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
function Bookshelf:show()
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
        self._widget:_rebuild()
        -- _openBook stopped the status timer when the reader took over;
        -- restart it now that bookshelf is the foreground again.
        if self._widget._startStatusTimer then
            self._widget:_startStatusTimer()
        end
        UIManager:setDirty(self._widget, "ui")
        return
    end
    local BookshelfWidget = require("bookshelf_widget")
    self._widget = BookshelfWidget:new{}
    -- Clear our reference if the widget is dismissed for any reason, so a
    -- subsequent show() falls back to the create path.
    local outer = self
    self._widget._on_close_callback = function()
        outer._widget = nil
    end
    UIManager:show(self._widget)
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
end

-- _safeShow — show bookshelf, doing the right thing depending on whether
-- the action was invoked from FM (overlay bookshelf directly) or from the
-- reader (route through the standard ReaderUI:onHome() path so the reader
-- closes AND FM is recreated underneath, then schedule the bookshelf show
-- on the next tick).
--
-- Why onHome() vs raw onClose: BookshelfWidget's gesture handling forwards
-- top-zone taps / swipes to FileManager.instance's touch zones (so the
-- standard FM menu is reachable from bookshelf). If the reader was launched
-- directly (start_with=last) FM was never created — calling onClose alone
-- leaves nothing underneath bookshelf and the menu becomes unreachable.
-- onHome calls showFileManager which creates FM if missing.
function Bookshelf:_safeShow()
    if self.ui and self.ui.document and self.ui.onHome then
        self.ui:onHome()
        -- onCloseDocument fires synchronously inside onHome → FM is
        -- foreground. We schedule bookshelf for the next tick so FM's
        -- creation/show completes first, leaving FM as the painting
        -- surface beneath the bookshelf overlay.
        UIManager:nextTick(function() self:show() end)
    else
        self:show()
    end
end

-- Close the live widget if showing, otherwise safe-show. Mirrors the
-- "Open Bookshelf" / "Close Bookshelf" menu entry.
function Bookshelf:onToggleBookshelf()
    if self:_isShowing() then
        UIManager:close(self._widget)
    else
        self:_safeShow()
    end
    return true
end

-- Explicit show/hide — used by the Set Bookshelf action with on/off args.
-- Hide is a no-op when nothing's showing, mirroring how Set Bookends behaves.
function Bookshelf:onSetBookshelf(visible)
    if visible then
        if not self:_isShowing() then self:_safeShow() end
    else
        if self:_isShowing() then UIManager:close(self._widget) end
    end
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
    -- (We keep `fm_instance` in the signature for diagnostic use only —
    -- closing it is now intentional dead code.)
    local _ = fm_instance
    self:show()
end

-- ---------------------------------------------------------------------------
-- Close-document hook
-- ---------------------------------------------------------------------------

function Bookshelf:onCloseDocument()
    -- The walk cache has a 30s TTL; sideloaded / moved / mtime-changed files
    -- surface within that window without an explicit invalidate. Skipping
    -- invalidation here avoids re-walking the entire library + per-candidate
    -- meta build on every close-book → home transition (the common case).

    -- The just-closed file's stats DID change (new pages read), so its
    -- cached enrichStats fields should be dropped — the hero rebuild that
    -- follows must see the new totals. Targeted to the closed file only.
    local Repo = require("book_repository")
    if Repo and Repo.invalidateStatsCache and self.ui and self.ui.document
       and self.ui.document.file then
        Repo.invalidateStatsCache(self.ui.document.file)
    end

    -- Only re-show Bookshelf if the user is actually returning to "home"
    -- — not if the Reader is closing this document only to immediately open
    -- another. self.ui.document is still set in the latter case.
    if G_reader_settings:readSetting("start_with") ~= "bookshelf" then return end
    if self.ui and self.ui.document then return end
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

-- Open a single-line dialog to set / change / clear the GitHub PAT used for
-- authenticated downloads from the private repo.
function Bookshelf:editGitHubToken(touchmenu_instance)
    local InputDialog = require("ui/widget/inputdialog")
    local dlg
    dlg = InputDialog:new{
        title      = _("GitHub access token"),
        input      = G_reader_settings:readSetting("bookshelf_github_pat") or "",
        input_hint = _("Personal access token (leave empty to clear)"),
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
                    local raw     = dlg:getInputText() or ""
                    local trimmed = raw:gsub("^%s+", ""):gsub("%s+$", "")
                    if trimmed == "" then
                        G_reader_settings:delSetting("bookshelf_github_pat")
                    else
                        G_reader_settings:saveSetting("bookshelf_github_pat", trimmed)
                    end
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
        local Repo = require("book_repository")
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
    if self._widget and self:_isShowing() then
        UIManager:setDirty(self._widget, "full")
    end
end

return Bookshelf
