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

local Bookshelf = WidgetContainer:extend{
    name        = "bookshelf",
    is_doc_only = false, -- must be false: hook fires in Reader context
}

-- ---------------------------------------------------------------------------
-- init
-- ---------------------------------------------------------------------------

-- Migrate the user's saved bookshelf_hero_lines if it matches a known-old
-- default. The settings.reader.lua file is loaded once at boot and rewritten
-- at shutdown, so a user with an out-of-date saved value would never see
-- our updated default until they manually edit it via Settings (which they
-- can't reach if the access path itself moved). This runs on every plugin
-- init, but is idempotent: once the value matches the new default OR the
-- user has customised it, no further changes happen.
local OLD_DEFAULT_LINES = {
    {
        "%page_num / %page_count · %book_pct",
        "[if:book_time_left]%book_time_left LEFT[else]Open to start reading[/if]",
    },
    {
        "%page_num / %page_count · %book_pct%%",
        "[if:book_time_left]%book_time_left LEFT[else]Open to start reading[/if]",
    },
    {
        "Page %page_num / %page_count · %book_pct",
        "[if:book_time_left]%book_time_left LEFT[else]Open to start reading[/if]",
    },
    {
        "[if:page_num]Page %page_num / %page_count · %book_pct[else]%book_pct[/if]",
        "[if:book_time_left]%book_time_left LEFT[else]Open to start reading[/if]",
    },
}
local NEW_DEFAULT_LINES = {
    "[if:page_num]Page %page_num / %page_count[/if]",
    "[if:book_time_left]%book_time_left LEFT[/if]",
}

local function maybeMigrateHeroLines()
    local saved = G_reader_settings:readSetting("bookshelf_hero_lines")
    if not saved or type(saved) ~= "table" then return end
    for _i, old in ipairs(OLD_DEFAULT_LINES) do
        if saved[1] == old[1] and saved[2] == old[2] then
            G_reader_settings:saveSetting("bookshelf_hero_lines", NEW_DEFAULT_LINES)
            logger.info("[bookshelf] migrated stale hero_lines preference to new default")
            return
        end
    end
end

function Bookshelf:init()
    maybeMigrateHeroLines()
    -- Patch the start_with menu so users can pick Bookshelf as their home.
    self:_registerStartWithMenu()

    -- Register "Open Bookshelf" in the main menu (works in both FM and Reader).
    self.ui.menu:registerToMainMenu(self)

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

        -- Duplicate guard (safety net in case patch fires more than once).
        -- NB: do NOT name the loop index `_` — that would shadow the outer
        -- gettext binding and `_("Bookshelf")` below would call a number.
        for _i, entry in ipairs(result.sub_item_table) do
            if entry.text == _("Bookshelf") then return result end
        end

        table.insert(result.sub_item_table, {
            text    = _("Bookshelf"),
            radio   = true,
            checked_func = function()
                return G_reader_settings:readSetting("start_with") == "bookshelf"
            end,
            callback = function()
                G_reader_settings:saveSetting("start_with", "bookshelf")
            end,
        })
        return result
    end
end

-- ---------------------------------------------------------------------------
-- Main menu entry
-- ---------------------------------------------------------------------------

function Bookshelf:addToMainMenu(menu_items)
    menu_items.bookshelf = {
        text         = _("Open Bookshelf"),
        sorting_hint = "more_tools",
        callback     = function() self:show() end,
    }
    -- Settings entry (replaces the old gear icon in the removed titlebar).
    menu_items.bookshelf_settings = {
        text         = _("Bookshelf settings"),
        sorting_hint = "more_tools",
        callback     = function() require("settings"):show() end,
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
        self._widget:_rebuild()
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

return Bookshelf
