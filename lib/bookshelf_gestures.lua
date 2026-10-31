-- lib/bookshelf_gestures.lua
-- Bookshelf's own gestures, each of which the reader can switch off
-- (Settings > Behavior > Bookshelf gestures): to find out what there is, and
-- to lock a device down (maintainer: "for kids"). Tapping a book and swiping
-- the shelf's pages are not listed: without them the shelf cannot be used.
--
-- A gesture switched off does nothing on the shelf; where the handler can
-- decline, the gesture passes on to KOReader as if Bookshelf had none there.
-- Every entry is on by default: nilOrTrue on its key.
local M = {}

local function store()
    if M._store then return M._store end
    return require("lib/bookshelf_settings_store")
end

-- The menu's order. `sep` draws a separator after the entry. `key` names the
-- setting when it predates this list (expanded_swipe_back, from issue 366).
-- tr: the translator (default the plugin's gettext; M.IDS passes the
-- identity so the ids are known without loading translations).
function M.list(tr)
    local _ = tr or require("lib/bookshelf_i18n").gettext
    return {
    { id = "full_screen_up",   text = _("Swipe up for full screen shelves") },
    { id = "full_screen_down", key = "expanded_swipe_back",
      text = _("Swipe down leaves full screen shelves"),
      -- Issue 366's row, moved here word for word (same msgid).
      help = _("When enabled, swiping down in full screen shelves brings"
            .. " the top panel back. Turn off to stay in full screen: the"
            .. " swipe then refreshes the library, as it does with the top"
            .. " panel showing, and the top panel comes back when you tap the"
            .. " book icon at the start of the shelf bar, or with a gesture"
            .. " set to Bookshelf: full screen shelves on or off.") },
    { id = "refresh",          text = _("Swipe down on the shelf to refresh the library") },
    { id = "density",          text = _("Pinch or spread to change the shelf's size") },
    { id = "top_panel_rows",   text = _("Swipe down or up on the top panel for fewer or more rows"), sep = true },
    { id = "top_panel_swipe",  text = _("Swipe left or right on the top panel to preview the next book") },
    { id = "top_panel_hold",   text = _("Long-press the top panel for book details") },
    { id = "rate",             text = _("Tap the stars to rate a book") },
    { id = "description",      text = _("Tap the description to read all of it"), sep = true },
    { id = "edit_shelf",       text = _("Long-press a shelf button to edit the shelf") },
    -- The editor one tap away (maintainer); the tap a shelf switch lands on
    -- by accident (issue 224), so it can be switched off on its own.
    { id = "edit_shelf_tap",   text = _("Tap the current shelf's button to edit the shelf") },
    { id = "shelf_buttons_swipe", text = _("Swipe the shelf buttons to see more of them"), sep = true },
    { id = "book_hold",        text = _("Long-press a book for its details") },
    { id = "group_hold",       text = _("Long-press a series, author or folder for its menu") },
    { id = "double_tap",       text = _("Double-tap a book to open it"), sep = true },
    { id = "style_cycle",      text = _("Long-press the page number to change the view mode") },
    { id = "page_jump",        text = _("Tap the page number to go to a page") },
    { id = "skip_ten",         text = _("Long-press the arrows to skip ten pages"), sep = true },
    { id = "module_hold",      text = _("Long-press a module to edit it") },
    { id = "module_tap",       text = _("Tap a module to use it") },
    { id = "start_menu_hold",  text = _("Long-press a start menu entry to edit it"), sep = true },
    { id = "ornament_hold",    text = _("Long-press an ornament to adjust it") },
    { id = "ornament_tap",     text = _("Tap an ornament to run its action") },
}
end

-- The ids and the older keys, without the translated text, so a check on a
-- hot path never loads the translations.
M.IDS = {}
for _i, g in ipairs(M.list(function(x) return x end)) do
    M.IDS[g.id] = g.key or ("gesture_" .. g.id)
end

function M.key(id)
    return M.IDS[id]
end

-- on(id) -> is this gesture switched on? An unknown id is on, so a typo in a
-- caller never silently disables a gesture.
function M.on(id)
    local k = M.key(id)
    if not k then return true end
    local ok, v = pcall(function() return store().read(k) end)
    if not ok then return true end
    return v ~= false
end

-- set(id, on, deferred): deferred writes in memory only (the caller
-- flushes), for switching many at once: each save flushes the whole
-- settings file, which is slow on a Kindle.
function M.set(id, on, deferred)
    local k = M.key(id)
    if not k then return end
    local st = store()
    local save = (deferred and st.saveDeferred) or st.save
    -- nil for on, so the default applies and the settings file stays small.
    -- (Not `(not on) and false or nil`: `false or nil` is nil.)
    if on then save(k, nil) else save(k, false) end
end

-- allOn() -> is every gesture switched on?
function M.allOn()
    for id in pairs(M.IDS) do if not M.on(id) then return false end end
    return true
end

-- menuItems() -> checkbox rows for the Behavior menu: an "all" row first
-- (ticked when every gesture is on; a tap switches all off, or, if any is
-- off, all on), then one per gesture.
function M.menuItems()
    local _ = require("lib/bookshelf_i18n").gettext
    local items = {
        {
            text = _("All gestures"),
            checked_func = function() return M.allOn() end,
            keep_menu_open = true,
            separator = true,
            callback = function(touchmenu_instance)
                local on = not M.allOn()
                local st = store()
                for id in pairs(M.IDS) do M.set(id, on, true) end
                if st.flush then pcall(st.flush) end
                -- Every row's tick changed, not just this one.
                if touchmenu_instance and touchmenu_instance.updateItems then
                    touchmenu_instance:updateItems()
                end
            end,
        },
    }
    for _i, g in ipairs(M.list()) do
        items[#items + 1] = {
            text = g.text,
            help_text = g.help,
            checked_func = function() return M.on(g.id) end,
            keep_menu_open = true,
            callback = function() M.set(g.id, not M.on(g.id)) end,
            separator = g.sep or nil,
        }
    end
    return items
end

return M
