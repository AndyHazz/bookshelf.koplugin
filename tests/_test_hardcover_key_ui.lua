-- tests/_test_hardcover_key_ui.lua
-- The settings row and dialog for the Hardcover API key
-- (lib/bookshelf_hardcover_key_ui): what it says about where the key comes
-- from, and what each button does.
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t, eq = helpers.runner(), helpers.eq

package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
package.loaded["ffi/util"] = { template = function(s, ...)
    local a = { ... }
    return (s:gsub("%%(%d)", function(i) return tostring(a[tonumber(i)]) end))
end }
local shown, closed, notes
package.loaded["ui/uimanager"] = {
    show = function(_s, w) shown[#shown + 1] = w end,
    close = function(_s, w) closed[#closed + 1] = w end,
}
package.loaded["ui/widget/buttondialog"] = { new = function(_s, o) o.kind = "buttons"; return o end }
package.loaded["ui/widget/inputdialog"] = { new = function(_s, o)
    o.kind = "input"
    o.getInputText = function(self) return self.typed end
    o.onShowKeyboard = function() end
    return o
end }
package.loaded["ui/widget/infomessage"] = { new = function(_s, o) notes[#notes + 1] = o.text; o.kind = "info"; return o end }
package.loaded["lib/bookshelf_gesture_zones"] = { passSwipesOn = function() end }

local key, plugin, set_calls, import_ok
local Key = {
    get = function() if key then return "TOKEN", key end end,
    hasOwn = function() return key == "own" end,
    pluginSource = function() return plugin end,
    set = function(text)
        set_calls[#set_calls + 1] = text
        if text == "bad" then return false end
        key = "own"; return true
    end,
    keepCopy = function() if plugin then key = "own"; return true end return false end,
    clear = function() key = plugin end,
    importFile = function() if import_ok then key = "own" end return import_ok end,
    importPath = function() return "/ko/settings/bookshelf/hardcover_api_key.txt" end,
}
package.loaded["lib/bookshelf_hardcover_key"] = Key
local invalidated, available, me_reply, plugin_on
package.loaded["lib/bookshelf_hardcover"] = {
    invalidateSource = function(changed) invalidated[#invalidated + 1] = changed and true or false end,
    -- As in the real module: on with Bookshelf's own key, or a plugin that
    -- is running (plugin_on).
    isAvailable = function() return key == "own" or (key ~= nil and plugin_on) end,
}
package.loaded["lib/bookshelf_hardcover_client"] = {
    me = function() if me_reply then return me_reply end return nil, { request_error = "Hardcover rejected the API key" } end,
}
package.loaded["lib/bookshelf_cover_fetch"] = { runWhenOnline = function(fn) fn() end }

local UI = dofile("lib/bookshelf_hardcover_key_ui.lua")

local changes
local function reset()
    shown, closed, notes, set_calls, invalidated = {}, {}, {}, {}, {}
    key, plugin, import_ok, available, me_reply, changes, plugin_on = nil, nil, false, false, nil, 0, true
end
local function button(dialog, text)
    for _i, row in ipairs(dialog.buttons) do
        for _j, b in ipairs(row) do if b.text == text then return b end end
    end
end
local function open()
    UI.open{ on_change = function() changes = changes + 1 end }
    return shown[#shown]
end

t.test("the row says where the key comes from", function()
    reset()
    eq(UI.statusText(), "Hardcover API key: not set")
    key = "own"
    eq(UI.statusText(), "Hardcover API key: Bookshelf's own")
    key = "hardcover"
    eq(UI.statusText(), "Hardcover API key: from the Hardcover plugin")
    key = "shelfsync"
    eq(UI.statusText(), "Hardcover API key: from your sync plugin")
    -- A key that is there but not in use must not read as in use.
    plugin_on = false
    eq(UI.statusText(), "Hardcover API key: in a plugin that is off")
end)

t.test("with no key anywhere: enter one or read a file; nothing to check, copy or remove", function()
    reset()
    local d = open()
    assert(d.title:find("hardcover_api_key.txt", 1, true), "the file's name is not given")
    assert(button(d, "Enter key\xE2\x80\xA6") and button(d, "Read key from file"))
    eq(button(d, "Check key"), nil)
    eq(button(d, "Copy the key from the Hardcover plugin"), nil)
    eq(button(d, "Remove Bookshelf's key"), nil)
end)

t.test("typing a key saves it, tells Hardcover, and says a restart shows the menu", function()
    reset()
    local d = open()
    button(d, "Enter key\xE2\x80\xA6").callback()
    local input = shown[#shown]
    eq(input.kind, "input")
    input.typed = "  Bearer abc.def.ghi "
    button(input, "Save").callback()
    eq(set_calls[1], "  Bearer abc.def.ghi ")
    eq(invalidated[1], true, "a new key can be another account")
    eq(changes, 1)
    assert(notes[#notes]:find("Restart KOReader", 1, true), notes[#notes])
    -- Something that is not a key is refused, and the dialog stays.
    reset()
    d = open()
    button(d, "Enter key\xE2\x80\xA6").callback()
    input = shown[#shown]
    input.typed = "bad"
    button(input, "Save").callback()
    eq(#invalidated, 0); eq(changes, 0)
    assert(notes[#notes]:find("does not look like", 1, true), notes[#notes])
end)

t.test("a key is read from the file, or the reader is told where to put it", function()
    reset()
    local d = open()
    button(d, "Read key from file").callback()
    assert(notes[#notes]:find("/ko/settings/bookshelf/hardcover_api_key.txt", 1, true), notes[#notes])
    eq(#invalidated, 0)
    import_ok = true
    d = open()
    button(d, "Read key from file").callback()
    eq(invalidated[1], true); eq(changes, 1)
end)

t.test("a plugin's key: keeping a copy is offered, and makes it Bookshelf's own", function()
    reset()
    key, plugin = "hardcover", "hardcover"
    local d = open()
    assert(d.title:find("from the Hardcover plugin", 1, true), d.title)
    assert(d.title:find("only needed to use Hardcover without that plugin", 1, true),
        "the dialog does not say when a copy is wanted: " .. d.title)
    eq(button(d, "Remove Bookshelf's key"), nil)
    eq(button(d, "Keep a copy of the plugin's key"), nil, "the old label nobody understood")
    button(d, "Copy the key from the Hardcover plugin").callback()
    eq(key, "own"); eq(invalidated[1], true); eq(changes, 1)
    -- Hardcover was already on: no talk of a restart.
    assert(not notes[#notes]:find("Restart", 1, true), notes[#notes])
end)

t.test("a key in a plugin that is switched off: said plainly, and a copy switches Hardcover on", function()
    reset()
    key, plugin, plugin_on = "hardcover", "hardcover", false
    local d = open()
    assert(d.title:find("switched off", 1, true), d.title)
    button(d, "Copy the key from the Hardcover plugin").callback()
    eq(key, "own")
    assert(notes[#notes]:find("Restart KOReader", 1, true), "Hardcover came on: its menu needs a restart")
end)

t.test("the copy button names the plugin that holds the key", function()
    reset()
    key, plugin = "shelfsync", "shelfsync"
    local d = open()
    assert(button(d, "Copy the key from ShelfSync"), "ShelfSync is not named")
end)

t.test("Bookshelf's own key can be removed, falling back to the plugin's", function()
    reset()
    key, plugin = "own", "shelfsync"
    local d = open()
    eq(button(d, "Copy the key from ShelfSync"), nil, "it has its own already")
    button(d, "Remove Bookshelf's key").callback()
    eq(key, "shelfsync"); eq(invalidated[1], true); eq(changes, 1)
end)

t.test("Check key asks Hardcover who the key belongs to", function()
    reset()
    key = "own"
    me_reply = { id = 7, username = "reader" }
    local d = open()
    button(d, "Check key").callback()
    eq(notes[#notes], "Hardcover accepts this key (reader).")
    me_reply = nil
    button(d, "Check key").callback()
    eq(notes[#notes], "The key was not accepted: Hardcover rejected the API key")
end)

t.test("the menu row opens the dialog and keeps the menu up", function()
    reset()
    local item = UI.menuItem(function() changes = changes + 1 end)
    eq(item.text_func(), "Hardcover API key: not set")
    eq(item.keep_menu_open, true)
    local updated = 0
    item.callback({ updateItems = function() updated = updated + 1 end })
    eq(shown[#shown].kind, "buttons")
    import_ok = true
    button(shown[#shown], "Read key from file").callback()
    eq(changes, 1); eq(updated, 1, "the row's text is stale after a change")
end)

t.test("the key row is in Hardcover's menu, which is always there now", function()
    local f = assert(io.open("lib/bookshelf_settings.lua")); local src = f:read("*a"); f:close()
    assert(src:find('require("lib/bookshelf_hardcover_key_ui").menuItem(function() markDirty("hardcover-key") end)', 1, true),
        "not in the Hardcover menu")
    assert(not src:find('local row = require("lib/bookshelf_hardcover_key_ui").menuItem()', 1, true),
        "a second copy in Library settings")
    f = assert(io.open("main.lua")); src = f:read("*a"); f:close()
    local block = src:match("(menu_items%.bookshelf_hardcover = {.-\n        }\n)")
    assert(block, "no Hardcover menu")
    local before = src:sub(1, src:find("menu_items.bookshelf_hardcover = {", 1, true))
    assert(not before:sub(-400):find("isAvailable", 1, true), "the Hardcover menu still waits for a plugin")
end)

t.test("Hardcover's menu says what it is connected through, and the reviews hint asks for a key only", function()
    local f = assert(io.open("lib/bookshelf_settings.lua")); local src = f:read("*a"); f:close()
    assert(src:find("Hardcover.connection()", 1, true), "the menu does not say which plugin or sign-in is in use")
    assert(src:find('_("Connected through %1 (%2)")', 1, true))
    local w = dofile("tests/_widget_source.lua")
    assert(not w:find("sign out of Hardcover", 1, true), "the hint still tells the reader to sign out")
    assert(w:find("Hardcover enrichment > Hardcover API key", 1, true), "the hint does not say where to add a key")
end)

t.done()
