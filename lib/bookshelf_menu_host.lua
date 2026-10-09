--[[
Hosts a TouchMenu-style item table (as produced by Dispatcher:addSubMenu or
bookshelf_settings' sub-item builders) inside a stock Menu widget, outside
KOReader's main menu. Items' callbacks expect a touchmenu_instance argument;
we pass a duck-typed shim with this contract:
  - updateItems() re-renders the current level;
  - closeMenu() closes the host;
  - show_parent is the REAL Menu widget. Settings callbacks hide their menu
    behind a modal dialog and re-show it afterwards (main.lua's hideMenu:
    UIManager:close(show_parent), later UIManager:show(show_parent)), and
    hideMenu prefers show_parent unconditionally - so those calls must land
    on a paintable widget, never on this plain table;
  - handleEvent() is a no-op safety net for any code path that does treat
    the shim itself as a widget (e.g. UIManager:close on it).
Long-press is wired through the host Menu's onMenuHold: the source item's
hold_callback (or hold_callback_func) runs with the shim as its
touchmenu_instance, mirroring TouchMenu:onMenuHold semantics - menu stays
open by default, hold_keep_menu_open == false closes it before the callback.
Owners may wrap host._shim methods (action picker wraps updateItems to
observe async commits, e.g. Dispatcher's SpinWidget OK path); because a
wrapper can close the host mid-callback, _refresh no-ops once closed.
]]
local _ = require("lib/bookshelf_i18n").gettext

local MenuHost = {}

local BACK_PREFIX  = "\xE2\x80\xB9 " -- ‹

-- Leading check/radio glyphs, mirroring TouchMenu's CheckMark/RadioMark
-- column. PUA codepoints from KOReader's bundled nerdfonts/symbols.ttf
-- (see lib/bookshelf_nerdfont_names.lua); KOReader registers that face as
-- a global text fallback (font.lua), so Menu's plain TextWidgets render
-- them without a special face.
local GLYPH_CHECK_ON  = "\xEE\xA0\xB1" -- U+E831 checkbox-marked
local GLYPH_CHECK_OFF = "\xEE\xA0\xB0" -- U+E830 checkbox-blank-outline
local GLYPH_RADIO_ON  = "\xEE\xAC\xBD" -- U+EB3D radiobox-marked
local GLYPH_RADIO_OFF = "\xEE\xAC\xBC" -- U+EB3C radiobox-blank
-- TouchMenu reserves the checkmark column on every row; we approximate that
-- with an em space so box-less labels line up with boxed siblings. Applied
-- only when a sibling in the same level renders a box.
local NOBOX_PAD = "\xE2\x80\x83  " -- U+2003 em space + glyph's trailing gap

local function mapItems(host, src_items)
    local any_box = false
    for _i, it in ipairs(src_items) do
        if type(it) == "table" and it.checked_func then
            any_box = true
            break
        end
    end
    local out = {}
    for _i, it in ipairs(src_items) do
        if type(it) == "table" and (it.text or it.text_func) then
            local enabled = (it.enabled_func == nil) or it.enabled_func()
            local text = it.text or it.text_func()
            if it.checked_func then
                -- TouchMenu treats an item as checkable only when it has a
                -- checked_func; `radio` selects the radiobutton glyph pair.
                local checked = it.checked_func()
                local glyph
                if it.radio then
                    glyph = checked and GLYPH_RADIO_ON or GLYPH_RADIO_OFF
                else
                    glyph = checked and GLYPH_CHECK_ON or GLYPH_CHECK_OFF
                end
                text = glyph .. "  " .. text
            elseif any_box then
                text = NOBOX_PAD .. text
            end
            -- _src: the source item, so the host Menu's onMenuHold can run
            -- its hold_callback with TouchMenu semantics.
            local row = { text = text, dim = not enabled or nil, _src = it }
            local has_sub = it.sub_item_table ~= nil or it.sub_item_table_func ~= nil
            if has_sub then
                -- Drill-down marker: Menu.getMenuText appends its native
                -- (BiDi-aware) submenu arrow when the row has a
                -- sub_item_table_func. Only getMenuText reads that field -
                -- onMenuSelect branches on sub_item_table alone (which we
                -- deliberately leave unset so taps run our callback and the
                -- push goes through host:_push, not Menu's own stack).
                row.sub_item_table_func = it.sub_item_table_func
                    or function() return it.sub_item_table end
            end
            if enabled then
                row.callback = function()
                    if it.sub_item_table or it.sub_item_table_func then
                        local sub = it.sub_item_table or it.sub_item_table_func()
                        -- guard nil/non-table result from sub_item_table_func
                        if type(sub) ~= "table" then return end
                        host:_push(it.text or (it.text_func and it.text_func()) or "", sub, it)
                    elseif it.callback then
                        it.callback(host._shim)
                        if host._refresh then host:_refresh() end
                        if host.on_item_activated then host.on_item_activated(it) end
                    end
                end
            else
                -- native convention: select_enabled=false blocks tap silently
                row.select_enabled = false
            end
            out[#out + 1] = row
        end
    end
    return out
end

-- Long-press handler for a mapped row, mirroring TouchMenu:onMenuHold:
-- resolve hold_callback_func/hold_callback, close the host first only when
-- hold_keep_menu_open == false (default keeps it open - holds usually show
-- a cancellable dialog), call it with the shim as touchmenu_instance, then
-- re-render so toggled checked state repaints (_refresh no-ops if the
-- callback closed the host). Disabled items block hold, as in TouchMenu.
local function holdItem(host, row)
    local it = row and row._src
    if not it then return true end -- synthetic rows (e.g. Back) have no source
    if it.enabled_func and not it.enabled_func() then return true end
    local hold_cb = it.hold_callback_func and it.hold_callback_func()
        or it.hold_callback
    if not hold_cb then return true end
    if it.hold_keep_menu_open == false then
        MenuHost.close(host)
    end
    hold_cb(host._shim, it)
    if host._refresh then host:_refresh() end
    return true
end

-- Builds the rows for one level. Pushed (non-root) levels get a synthetic
-- "‹ Back" first row mirroring the title-bar return arrow; _push and
-- _refresh both go through here so the row survives re-renders.
local function levelItems(host, src_items, is_pushed)
    local rows = mapItems(host, src_items)
    if is_pushed then
        table.insert(rows, 1, {
            text = BACK_PREFIX .. _("Back"),
            callback = function() host:_pop() end,
        })
    end
    return rows
end

-- opts: { title, item_table, on_item_activated?, close_callback? }
-- Returns the host object; MenuHost.close(host) closes it.
function MenuHost.show(opts)
    local Menu      = require("ui/widget/menu")
    local UIManager = require("ui/uimanager")
    local Screen    = require("device").screen

    local host = { on_item_activated = opts.on_item_activated, _stack = {} }
    -- store the owner's close callback so all close routes fire it
    host._close_callback = opts.close_callback
    host._shim = {
        updateItems = function() if host._refresh then host:_refresh() end end,
        closeMenu   = function() MenuHost.close(host) end,
        -- safety net: the shim is not a widget; swallow events sent at it
        handleEvent = function() return false end,
        -- The open level's own rows, which a caller that changes the SET of
        -- rows rebuilds in place (Settings:_reopenSubMenu) as it does a
        -- TouchMenu's item_table: the Theme menu after a Theme library closes
        -- gains or loses its This shelf row with the shelf on screen.
        liveItems = function()
            local lvl = host._stack[#host._stack]
            return lvl and lvl.src or nil
        end,
        -- show_parent (the real Menu widget) is attached below, once built
    }
    function host:_current()
        return self._stack[#self._stack]
    end
    function host:_refresh()
        if self._closed then return end -- shim wrappers may close mid-callback
        local lvl = self:_current()
        if not lvl then return end
        -- preserve the current page across switchItemTable (which resets to 1)
        local saved_page = self._menu.page
        -- The title is the row that opened this level: renamed with it (a
        -- choice made in a picker from here can change it, "Theme: %1").
        local from = lvl.from
        if from and from.text_func then
            local ok, t = pcall(from.text_func)
            if ok and type(t) == "string" then lvl.title = t end
        end
        self._menu:switchItemTable(lvl.title,
            levelItems(self, lvl.src, #self._stack > 1))
        if saved_page and saved_page > 1
                and self._menu.page_num and saved_page <= self._menu.page_num then
            self._menu:onGotoPage(saved_page)
        end
    end
    function host:_push(title, src, from)
        -- save the current level's page before descending
        local lvl = self:_current()
        if lvl then lvl.page = self._menu.page end
        self._stack[#self._stack + 1] = { title = title, src = src, from = from }
        -- paths drives the return-arrow enabled state (menu.lua:1040)
        self._menu.paths[#self._menu.paths + 1] = { title = title }
        self._menu:switchItemTable(title, levelItems(self, src, true))
    end
    function host:_pop()
        if #self._stack <= 1 then MenuHost.close(self) return end
        table.remove(self._stack)
        table.remove(self._menu.paths)
        -- restore the parent level's saved page after _refresh
        local parent = self:_current()
        self:_refresh()
        if parent and parent.page and parent.page > 1
                and self._menu.page_num and parent.page <= self._menu.page_num then
            self._menu:onGotoPage(parent.page)
        end
    end

    host._stack[1] = { title = opts.title, src = opts.item_table }
    host._menu = Menu:new{
        title          = opts.title,
        item_table     = mapItems(host, opts.item_table),
        width          = Screen:getWidth(),
        height         = Screen:getHeight(),
        is_borderless  = true,
        is_popout      = false,
        onReturn       = function() host:_pop() end,
        -- close_callback intentionally omitted here: Menu:onMenuSelect fires
        -- close_callback after every leaf item tap (menu.lua:1360), which
        -- would close the host on each selection. We gate the owner's callback
        -- through MenuHost.close instead.
    }
    -- The shim's show_parent must be the real Menu widget so hideMenu-style
    -- hide/re-show cycles close and re-show something paintable.
    host._shim.show_parent = host._menu
    -- all close routes go through MenuHost.close (single close path)
    host._menu.onCloseAllMenus = function(_self_menu)
        MenuHost.close(host)
        return true
    end
    -- long-press: Menu's MenuItem:onHoldSelect calls menu:onMenuHold(entry)
    -- with the mapped row; the row carries its source item in _src.
    host._menu.onMenuHold = function(_self_menu, row)
        return holdItem(host, row)
    end
    UIManager:show(host._menu)
    return host
end

-- single authoritative close path; fires close_callback exactly once
function MenuHost.close(host)
    if not host or host._closed then return end
    host._closed = true
    local UIManager = require("ui/uimanager")
    UIManager:close(host._menu)
    if host._close_callback then host._close_callback() end
end

MenuHost._test = { mapItems = mapItems, levelItems = levelItems,
                   holdItem = holdItem }
return MenuHost
