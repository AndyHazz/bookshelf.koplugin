package.path = "./?.lua;./?/init.lua;" .. package.path
for _i, name in ipairs({ "ui/widget/menu", "ui/geometry" }) do
    package.loaded[name] = {}
end
-- MenuHost.close calls UIManager:close (exercised by the hold_keep_menu_open
-- test), so the uimanager stub needs callable methods, not a bare table.
package.loaded["ui/uimanager"] = { close = function() end, show = function() end }
package.loaded["device"] = { screen = { getWidth = function() return 600 end,
                                        getHeight = function() return 800 end } }
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
package.loaded["logger"] = { dbg = function() end, info = function() end,
                             warn = function() end, err = function() end }

local Host = dofile("lib/bookshelf_menu_host.lua")
local map = assert(Host._test and Host._test.mapItems, "mapItems not exposed via _test")
local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()

-- nerdfont glyphs mirroring TouchMenu's CheckMark/RadioMark column
local CHECK_ON  = "\xEE\xA0\xB1" -- U+E831 checkbox-marked
local CHECK_OFF = "\xEE\xA0\xB0" -- U+E830 checkbox-blank-outline
local RADIO_ON  = "\xEE\xAC\xBD" -- U+EB3D radiobox-marked
local RADIO_OFF = "\xEE\xAC\xBC" -- U+EB3C radiobox-blank
local PAD       = "\xE2\x80\x83  " -- em-space column stand-in for box-less rows

t.test("maps text, text_func, checkbox glyphs, enabled_func dim", function()
    local src = {
        { text = "Plain", callback = function() end },
        { text_func = function() return "Dynamic" end, callback = function() end },
        { text = "Checked", checked_func = function() return true end, callback = function() end },
        { text = "Unchecked", checked_func = function() return false end, callback = function() end },
        { text = "Disabled", enabled_func = function() return false end, callback = function() end },
    }
    local host = { on_item_activated = nil, _shim = {} }
    local out = map(host, src)
    -- a sibling has a box, so box-less rows get the alignment pad
    assert(out[1].text == PAD .. "Plain", "box-less row must be padded, not boxed")
    assert(out[2].text == PAD .. "Dynamic")
    assert(out[3].text == CHECK_ON .. "  Checked", "checked box glyph missing")
    assert(out[4].text == CHECK_OFF .. "  Unchecked", "unchecked box glyph missing")
    assert(out[5].dim == true and out[5].callback == nil)
end)

t.test("no box and no pad when no sibling has a checked_func", function()
    local src = {
        { text = "Plain", callback = function() end },
        { text = "Other", callback = function() end },
    }
    local out = map({ _shim = {} }, src)
    assert(out[1].text == "Plain" and out[2].text == "Other",
        "levels without any box must not pad")
end)

t.test("radio items render radiobutton glyphs", function()
    local src = {
        { text = "On", radio = true, checked_func = function() return true end },
        { text = "Off", radio = true, checked_func = function() return false end },
        { text = "NoCheck", radio = true }, -- radio without checked_func: no glyph
    }
    local out = map({ _shim = {} }, src)
    assert(out[1].text == RADIO_ON .. "  On", "checked radio glyph missing")
    assert(out[2].text == RADIO_OFF .. "  Off", "unchecked radio glyph missing")
    assert(out[3].text == PAD .. "NoCheck", "radio without checked_func must get no glyph")
end)

t.test("mapped rows carry the source item in _src", function()
    local src = {
        { text = "Leaf", callback = function() end },
        { text = "Sub", sub_item_table = { { text = "child" } } },
    }
    local out = map({ _shim = {} }, src)
    assert(out[1]._src == src[1] and out[2]._src == src[2], "row._src must be the source item")
end)

t.test("leaf callback receives the shim; sub tables push", function()
    local got_shim, pushed
    local src = {
        { text = "Leaf", callback = function(tmi) got_shim = tmi end },
        { text = "Sub", sub_item_table = { { text = "child", callback = function() end } } },
    }
    local host = { _shim = { updateItems = function() end } }
    host._push = function(_self, title, sub) pushed = { title = title, sub = sub } end
    local out = map(host, src)
    out[1].callback()
    assert(got_shim == host._shim, "shim not passed to leaf callback")
    out[2].callback()
    assert(pushed and pushed.title == "Sub" and #pushed.sub == 1)
end)

t.test("sub rows carry the native drill-down marker, leaves do not", function()
    local src = {
        { text = "Leaf", callback = function() end },
        { text = "Sub", sub_item_table = { { text = "child" } } },
        { text = "SubFunc", sub_item_table_func = function() return {} end },
    }
    local host = { _shim = {} }
    local out = map(host, src)
    -- Menu.getMenuText appends its submenu arrow when the row has a
    -- sub_item_table_func; onMenuSelect only branches on sub_item_table,
    -- which must stay unset so taps still run our callback.
    assert(out[1].sub_item_table_func == nil, "leaf must not carry the marker")
    assert(type(out[2].sub_item_table_func) == "function", "sub row needs marker")
    assert(type(out[3].sub_item_table_func) == "function", "sub_func row needs marker")
    assert(out[2].sub_item_table == nil and out[3].sub_item_table == nil,
        "sub_item_table must stay unset on mapped rows")
end)

local levelItems = assert(Host._test.levelItems, "levelItems not exposed via _test")

t.test("pushed levels get a Back first row that pops; root does not", function()
    local src = { { text = "A", callback = function() end } }
    local popped = false
    local host = { _shim = {} }
    host._pop = function() popped = true end
    local root = levelItems(host, src, false)
    assert(#root == 1 and root[1].text == "A", "root must not get a Back row")
    local pushed = levelItems(host, src, true)
    assert(#pushed == 2, "pushed level must gain exactly one row")
    assert(pushed[1].text:find("Back"), "first row must be Back")
    assert(pushed[2].text == "A")
    pushed[1].callback()
    assert(popped, "Back row callback must call host:_pop")
end)

t.test("sub_item_table_func returning nil does not push and does not error", function()
    local push_called = false
    local src = {
        { text = "NilSub", sub_item_table_func = function() return nil end },
    }
    local host = { _shim = { updateItems = function() end } }
    host._push = function(_self, _title, _sub) push_called = true end
    local out = map(host, src)
    -- must not error
    out[1].callback()
    assert(not push_called, "_push must not be called when sub_item_table_func returns nil")
end)

local holdItem = assert(Host._test.holdItem, "holdItem not exposed via _test")

t.test("hold runs the source hold_callback with the shim, then refreshes", function()
    local got_tmi, got_item, refreshed
    local it = { text = "Region",
                 hold_callback = function(tmi, item) got_tmi, got_item = tmi, item end }
    local host = { _shim = { updateItems = function() end } }
    host._refresh = function() refreshed = true end
    local out = map(host, { it })
    assert(holdItem(host, out[1]) == true)
    assert(got_tmi == host._shim, "hold_callback must receive the shim as touchmenu_instance")
    assert(got_item == it, "hold_callback must receive the source item")
    assert(refreshed, "host must refresh after the hold callback")
end)

t.test("hold is a no-op for rows without hold_callback, Back rows, disabled items", function()
    local host = { _shim = {} }
    host._refresh = function() end
    -- no hold_callback: must not error
    local out = map(host, { { text = "Plain", callback = function() end } })
    assert(holdItem(host, out[1]) == true)
    -- synthetic Back row carries no _src
    assert(holdItem(host, { text = "Back" }) == true)
    -- disabled item: hold blocked (TouchMenu blocks hold on disabled items)
    local held = false
    out = map(host, { { text = "Off", enabled_func = function() return false end,
                        hold_callback = function() held = true end } })
    assert(holdItem(host, out[1]) == true)
    assert(not held, "hold must be blocked on disabled items")
end)

t.test("hold_keep_menu_open == false closes the host before the callback", function()
    local closed_states = {}
    local it = { text = "X", hold_keep_menu_open = false,
                 hold_callback = function() end }
    local host = { _shim = {}, _menu = {} }
    host._refresh = function()
        if host._closed then return end
        closed_states.refreshed_open = true
    end
    it.hold_callback = function() closed_states.closed_at_callback = host._closed end
    local out = map(host, { it })
    assert(holdItem(host, out[1]) == true)
    assert(closed_states.closed_at_callback == true, "host must be closed before the callback")
    assert(not closed_states.refreshed_open, "no re-render after close")
end)

t.test("hold_callback_func wins over hold_callback", function()
    local which
    local it = { text = "X",
                 hold_callback_func = function()
                     return function() which = "func" end
                 end,
                 hold_callback = function() which = "plain" end }
    local host = { _shim = {} }
    host._refresh = function() end
    local out = map(host, { it })
    holdItem(host, out[1])
    assert(which == "func", "hold_callback_func result must take precedence")
end)

t.test("a level's title follows the row that opened it when the level is refreshed", function()
    -- Theme > Default theme: Macabre chosen in the Theme library: the level's title
    -- was "Theme: Custom theme" until the menu was closed and opened again.
    local Menu = package.loaded["ui/widget/menu"]
    Menu.new = function(_c, o)
        o.paths = {}
        o.switchItemTable = function(self, title) self.title = title end
        return o
    end
    local theme = "Custom theme"
    local src = { { text_func = function() return "Theme: " .. theme end,
                    sub_item_table = { { text = "Library", callback = function() end } } } }
    local host = Host.show{ title = "Bookshelf", item_table = src }
    map(host, src)[1].callback()
    assert(host._menu.title == "Theme: Custom theme", "pushed under " .. tostring(host._menu.title))
    theme = "Macabre"
    host._shim.updateItems()
    assert(host._menu.title == "Theme: Macabre", "the title stayed " .. tostring(host._menu.title))
    Menu.new = nil
end)

t.test("a level's rows can be rebuilt in place, as a TouchMenu's item_table is", function()
    -- The Theme menu gains or loses its Reset row with the theme on screen
    -- after a Theme library closes (Settings:_reopenSubMenu); from the start
    -- menu's route the shim hands over the open level's rows to rebuild.
    local Menu = package.loaded["ui/widget/menu"]
    Menu.new = function(_c, o)
        o.paths = {}
        o.switchItemTable = function(self, title, items) self.title = title; self.items = items end
        return o
    end
    local sub = { { text = "Theme library" }, { text = "Reset Macabre to original" } }
    local src = { { text = "Theme (Macabre)", sub_item_table = sub } }
    local host = Host.show{ title = "Bookshelf", item_table = src }
    assert(host._shim.liveItems() == src, "the root level's rows are not handed over")
    map(host, src)[1].callback()
    assert(host._shim.liveItems() == sub, "the open level's rows are not handed over")
    -- What Settings:_reopenSubMenu does with them.
    local src_settings = io.open("lib/bookshelf_settings.lua"):read("*a")
    local body = src_settings:match("\nfunction Settings:_reopenSubMenu%(touchmenu_instance, build%)\n(.-)\nend\n")
    assert(body and body:find("touchmenu_instance.liveItems()", 1, true),
        "_reopenSubMenu does not rebuild a MenuHost level")
    local live = host._shim.liveItems()
    for i = #live, 1, -1 do live[i] = nil end
    live[1] = { text = "Theme library" }
    host._shim.updateItems()
    local n = 0
    for _i, r in ipairs(host._menu.items) do if not r.text:find("Back", 1, true) then n = n + 1 end end
    assert(n == 1, "the rebuilt level shows " .. n .. " rows")
    Menu.new = nil
end)

t.done()
