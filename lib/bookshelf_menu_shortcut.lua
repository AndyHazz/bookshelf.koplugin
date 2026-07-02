-- bookshelf_menu_shortcut.lua
-- Capture a KOReader file-manager menu item as a replayable Bookshelf action
-- (issue #142). The pure path core (label/segment/childrenOf/matchChild/walk/
-- buildCaptureTree) operates on plain TouchMenu-style item tables and is
-- headless-testable. The KOReader-coupled glue (buildMenuTree/openCapture/
-- replay, added in a later task) lazy-requires FileManager/MenuHost so this
-- module still loads under plain lua.

-- logger/socket are KOReader-provided; this module must still load under
-- plain lua for the headless test (see file header), so both are guarded.
local ok_logger, logger = pcall(require, "logger")
if not ok_logger then logger = { dbg = function() end } end

-- Wall-clock timer for perf instrumentation, matching bookshelf_widget.lua's
-- own [bookshelf perf] convention.
local _gettime
do
    local ok, s = pcall(require, "socket")
    _gettime = (ok and s and type(s.gettime) == "function")
        and function() return s.gettime() end
        or  os.clock
end

local MenuShortcut = {}

-- A row's display label (text, or text_func resolved once), or "".
function MenuShortcut._label(item)
    if type(item) ~= "table" then return "" end
    if item.text then return item.text end
    if item.text_func then
        local ok, t = pcall(item.text_func)
        if ok and type(t) == "string" then return t end
    end
    return ""
end

-- One path segment for an item: its stable id when present, else its label.
function MenuShortcut._segment(item)
    if type(item) == "table" and item.id ~= nil and item.id ~= "" then
        return { id = item.id }
    end
    return { text = MenuShortcut._label(item) }
end

-- Humanise an id ("network_proxy" -> "Network proxy") for display when a node
-- has no text of its own (KOReader's top-level menu tabs are icon-only).
local function humanize(id)
    local s = tostring(id):gsub("_", " ")
    return (s:gsub("^%l", string.upper))
end

-- Display label for a row: the real text if present, else a humanised id, else
-- a placeholder. Used ONLY for what is shown; path matching still uses _segment.
function MenuShortcut._displayLabel(item)
    local l = MenuShortcut._label(item)
    if l ~= "" then return l end
    if type(item) == "table" and item.id ~= nil and item.id ~= "" then
        return humanize(item.id)
    end
    return "(unnamed)"
end

-- Resolve an item's submenu children, or nil if it is a leaf. Children live
-- under sub_item_table / sub_item_table_func for normal entries; but in
-- MenuSorter's output a menu node IS an array of its children (the top-level
-- icon tabs especially), carrying id/text/icon as hash fields - so an array
-- part counts as the submenu content too.
function MenuShortcut._childrenOf(item)
    if type(item) ~= "table" then return nil end
    if type(item.sub_item_table) == "table" then return item.sub_item_table end
    if type(item.sub_item_table_func) == "function" then
        local ok, sub = pcall(item.sub_item_table_func)
        if ok and type(sub) == "table" then return sub end
    end
    if #item > 0 then return item end
    return nil
end

-- Find the child of `items` matching a path segment: by id if the segment has
-- one, else by label.
function MenuShortcut._matchChild(items, seg)
    if type(items) ~= "table" or type(seg) ~= "table" then return nil end
    for _i, it in ipairs(items) do
        if seg.id ~= nil then
            if it.id == seg.id then return it end
        elseif seg.text ~= nil then
            if MenuShortcut._label(it) == seg.text then return it end
        end
    end
    return nil
end

-- Walk a saved menu_path against a live tree; return the matched leaf item
-- (carrying its real callback) or nil if any segment fails to resolve.
function MenuShortcut.walk(items, menu_path)
    if type(items) ~= "table" or type(menu_path) ~= "table" then return nil end
    local cur, matched = items, nil
    for i = 1, #menu_path do
        matched = MenuShortcut._matchChild(cur, menu_path[i])
        if not matched then return nil end
        if i < #menu_path then
            cur = MenuShortcut._childrenOf(matched)
            if type(cur) ~= "table" then return nil end
        end
    end
    return matched
end

-- Transform ONE level of a live menu tree into a capture level. Submenus get a
-- sub_item_table_func that transforms THEIR level only when drilled into, so the
-- whole (large, dynamic) menu isn't resolved up front - resolving every
-- sub_item_table_func eagerly was a multi-second open. A submenu is detected by
-- its FIELDS (sub_item_table / sub_item_table_func / an array part) WITHOUT
-- calling the func. Leaves get a callback reporting their path + label to
-- on_capture. Non-actionable rows (separators, unmatchable) are dropped. `path`
-- is the accumulated segments to the parent.
function MenuShortcut.buildCaptureTree(items, on_capture, path)
    path = path or {}
    local out = {}
    if type(items) ~= "table" then return out end
    for _i, it in ipairs(items) do
        if type(it) == "table" then
            local seg = MenuShortcut._segment(it)
            local disp = MenuShortcut._displayLabel(it)
            local has_key = (it.id ~= nil and it.id ~= "") or MenuShortcut._label(it) ~= ""
            local this_path = {}
            for j = 1, #path do this_path[j] = path[j] end
            this_path[#this_path + 1] = seg
            -- Detect a submenu by shape, not by resolving it (lazy).
            local is_sub = type(it.sub_item_table) == "table"
                or type(it.sub_item_table_func) == "function"
                or #it > 0
            if is_sub then
                out[#out + 1] = {
                    text = disp,
                    sub_item_table_func = function()
                        return MenuShortcut.buildCaptureTree(
                            MenuShortcut._childrenOf(it), on_capture, this_path)
                    end,
                }
            elseif type(it.callback) == "function" and has_key then
                -- capturable leaf (matchable by id or text). A checked_func means
                -- it's a toggle, so the shortcut can show a live checkbox icon.
                local is_toggle = type(it.checked_func) == "function"
                out[#out + 1] = {
                    text = disp,
                    callback = function() on_capture(this_path, disp, is_toggle) end,
                }
            end
            -- else: separator / unmatchable / non-actionable -> dropped
        end
    end
    return out
end

-- Assemble KOReader's file-manager menu the same way the real menu does
-- (FileManagerMenu:setUpdateItemTable -> self.tab_item_table). Returns the root
-- item tree, or nil if the file manager / menu module isn't available or
-- assembly fails. pcall-guarded; this is the one version-coupled point.
-- Build (or reuse) a menu's tab_item_table tree. Prefer the cached tree:
-- setUpdateItemTable re-probes every registered widget's addToMainMenu and can
-- intermittently error in MenuSorter when run repeatedly outside the normal
-- menu-open flow, so only rebuild when nothing is cached yet (mirrors
-- onShowMenu). nil when the menu can't produce a usable tree.
local function treeFromMenu(menu)
    if type(menu) ~= "table" or type(menu.setUpdateItemTable) ~= "function" then return nil end
    local tree = menu.tab_item_table
    if type(tree) ~= "table" then
        local _t0 = _gettime()
        local ok = pcall(function() menu:setUpdateItemTable() end)
        logger.dbg(string.format(
            "[bookshelf perf] MenuShortcut.treeFromMenu: setUpdateItemTable"
            .. " (cache MISS) ok=%s took=%.0fms", tostring(ok), (_gettime() - _t0) * 1000))
        if not ok then return nil end
        tree = menu.tab_item_table
    end
    if type(tree) ~= "table" then return nil end
    return tree
end

-- Source the menu of the ACTIVE UI: the reader's menu when a book is open, else
-- the file manager's. ReaderUI.instance is set on reader open and cleared on
-- close, so its presence reliably means "in the reader" -- and ReaderMenu
-- exposes the same setUpdateItemTable/tab_item_table API as FileManagerMenu.
-- This makes capture, replay and the toggle checkbox work in whichever view the
-- start menu is open in (#211). When in the reader we do NOT fall back to a
-- parked FileManager menu -- that would capture/replay the wrong view's items.
function MenuShortcut.buildMenuTree()
    local ok_r, ReaderUI = pcall(require, "apps/reader/readerui")
    if ok_r and ReaderUI and ReaderUI.instance then
        return treeFromMenu(ReaderUI.instance.menu)
    end
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    if ok_fm and FileManager and FileManager.instance then
        return treeFromMenu(FileManager.instance.menu)
    end
    return nil
end

-- Open the file-manager menu in capture mode: drill submenus, tap a leaf to
-- capture it (never executes the real item). on_pick is called with
-- { label, menu_path } on capture.
function MenuShortcut.openCapture(on_pick)
    local _ = require("lib/bookshelf_i18n").gettext
    local tree = MenuShortcut.buildMenuTree()
    if not tree then
        local Notification = require("ui/widget/notification")
        local UIManager    = require("ui/uimanager")
        UIManager:show(Notification:new{ text = _("Menu unavailable") })
        return
    end
    local MenuHost = require("lib/bookshelf_menu_host")
    local host
    local function on_capture(menu_path, label, is_toggle)
        if host then MenuHost.close(host) end
        on_pick{ label = label, menu_path = menu_path, menu_toggle = is_toggle or nil }
    end
    local capture_tree = MenuShortcut.buildCaptureTree(tree, on_capture, {})
    host = MenuHost.show{ title = _("Add as shortcut"), item_table = capture_tree }
end

-- Live on/off state of a toggle menu item, for its shortcut's checkbox icon.
-- Builds the menu once if needed (then cached), walks to the leaf and calls its
-- checked_func. Returns true/false, or nil if the item isn't a resolvable toggle
-- (so the caller can fall back to the static icon). checked_func reads the live
-- setting on each call, so the result is always current once the leaf is found.
function MenuShortcut.toggleState(menu_path)
    local tree = MenuShortcut.buildMenuTree()
    if not tree then return nil end
    local leaf = MenuShortcut.walk(tree, menu_path)
    if type(leaf) ~= "table" or type(leaf.checked_func) ~= "function" then return nil end
    local ok, v = pcall(leaf.checked_func)
    if not ok then return nil end
    return v and true or false
end

-- Whether a menu shortcut should be shown in the CURRENT view: its captured
-- path resolves to a callable leaf in the active UI's menu (reader vs file
-- manager). Lets the start menu hide shortcuts that don't exist here, so each
-- auto-appears only where it works -- no "not available" tap (#211).
-- Fail-OPEN: a non-table path, or a menu tree that can't be built (transient
-- MenuSorter error), returns true so shortcuts never vanish on a hiccup.
function MenuShortcut.isAvailable(menu_path)
    if type(menu_path) ~= "table" then return true end
    local tree = MenuShortcut.buildMenuTree()
    if type(tree) ~= "table" then return true end
    local leaf = MenuShortcut.walk(tree, menu_path)
    return type(leaf) == "table" and type(leaf.callback) == "function"
end

-- Replay a saved menu_path: re-assemble the menu, walk to the leaf, fire its
-- callback with a minimal touchmenu shim. Fail safe: any miss -> toast, no fire.
function MenuShortcut.replay(menu_path)
    local _ = require("lib/bookshelf_i18n").gettext
    local UIManager    = require("ui/uimanager")
    local Notification = require("ui/widget/notification")
    local function unavailable()
        UIManager:show(Notification:new{ text = _("That menu item isn't available") })
    end
    local tree = MenuShortcut.buildMenuTree()
    if not tree then return unavailable() end
    local leaf = MenuShortcut.walk(tree, menu_path)
    if type(leaf) ~= "table" or type(leaf.callback) ~= "function" then
        return unavailable()
    end
    -- Minimal touchmenu_instance shim (no real parent menu to refresh/hide).
    local shim = {
        updateItems = function() end,
        closeMenu   = function() end,
        handleEvent = function() return false end,
        show_parent = nil,
    }
    local ok = pcall(leaf.callback, shim)
    if not ok then unavailable() end
end

return MenuShortcut
