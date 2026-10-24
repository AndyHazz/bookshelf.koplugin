-- tests/_test_module_card_menu.lua
-- lib/bookshelf_module_card_menu: the palette icon's menu for one module --
-- its card rows and its spec's own colours, for the look on screen, saved on
-- the module (not the theme) through the module's ctx.save.
package.path = "./?.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()

local suffix = ""
local shown, closed, picked = nil, 0, nil
local function c8(v) return { a = v, getColor8 = function(self) return self end } end
package.loaded["ffi/blitbuffer"] = { Color8 = c8 }
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
package.loaded["ffi/util"] = { template = function(s, ...)
    local a = { ... }
    return (s:gsub("%%(%d)", function(n) return tostring(a[tonumber(n)]) end))
end }
package.loaded["lib/bookshelf_cover_progress"] = {
    modeSuffix = function() return suffix end,
    editSuffix = function() return suffix end,
    setEditSlot = function() end,
    resolvePicked = function(raw) return raw and c8(raw.grey or 0) end,
}
package.loaded["lib/bookshelf_color"] = { invertValue = function(r) return r end }
package.loaded["lib/bookshelf_settings"] = {
    valueText = function(raw) return raw and ("grey " .. raw.grey) or "default" end,
    _pickColor = function(_self, key, field, _pct, _title, _menu, refresh, _anchor, wood)
        picked = { key = key, field = field, store = wood and wood.store, refresh = refresh }
    end,
}
local DEF = { title = "Quote", colors = { { id = "bar", text = "Bar" } } }
package.loaded["lib/bookshelf_start_menu_modules"] = { get = function() return DEF end }
package.loaded["ui/uimanager"] = {
    show = function(_s, d) shown = d end,
    close = function() closed = closed + 1 end,
    setDirty = function() end,
}
local Dialog = {}
function Dialog:new(o)
    o.byid = {}
    for _r, row in ipairs(o.buttons) do
        for _i, b in ipairs(row) do
            local btn = { text = b.text, width = 1, callback = b.callback }
            function btn:setText(tx) self.text = tx end
            if b.id then o.byid[b.id] = btn end
        end
    end
    function o:getButtonById(id) return self.byid[id] end
    return o
end
package.loaded["ui/widget/buttondialog"] = Dialog
local Menu = dofile("lib/bookshelf_module_card_menu.lua")

local function ctxFor(entry)
    local ctx = { entry = entry, saves = 0 }
    function ctx.save() ctx.saves = ctx.saves + 1 end
    return ctx
end

t.test("its rows: the card's four, then the spec's, labelled for the look on screen", function()
    suffix = ""
    Menu.show(ctxFor({ id = "q", module = "quote" }))
    assert(shown and shown.title:find("Quote", 1, true) and shown.title:find("Light", 1, true), tostring(shown and shown.title))
    local ids = {}
    for _r, row in ipairs(shown.buttons) do
        for _i, b in ipairs(row) do ids[#ids + 1] = b.id or b.text end
    end
    assert(table.concat(ids, ",") == "bg,border,border_color,ink,bar,Reset,Close", table.concat(ids, ","))
    assert(shown:getButtonById("bg").text == "Card background: default", shown:getButtonById("bg").text)
    assert(shown:getButtonById("border").text == "Card border: On")
    -- No background of its own: the text is the shared ink, so "default".
    assert(shown:getButtonById("ink").text == "Card text: default", shown:getButtonById("ink").text)
    Menu.show(ctxFor({ id = "q", module = "quote", colors = { bg = { grey = 3 } } }))
    assert(shown:getButtonById("ink").text == "Card text: Auto", "its own background: Auto")
end)

t.test("Card border switches off and on, saved on the module", function()
    suffix = ""
    local ctx = ctxFor({ id = "q", module = "quote" })
    Menu.show(ctx)
    shown:getButtonById("border").callback()
    assert(ctx.entry.colors.border == false and ctx.saves == 1, "not switched off and saved")
    assert(shown:getButtonById("border").text == "Card border: Off", "label not updated in place")
    shown:getButtonById("border").callback()
    assert(ctx.entry.colors == nil, "on again leaves the default, nothing stored")
end)

t.test("a colour row picks into the module, for the look on screen", function()
    suffix = "_night"
    local ctx = ctxFor({ id = "q", module = "quote" })
    Menu.show(ctx)
    assert(shown.title:find("Dark", 1, true), "not the dark look")
    shown:getButtonById("bar").callback()
    assert(picked and picked.key == "bar" and picked.store, "the picker isn't given the module's store")
    picked.store.partSave("bar_night", { grey = 0x40 })
    picked.refresh()
    assert(ctx.entry.colors.bar_night.grey == 0x40 and ctx.saves == 1, "not stored on the module")
    assert(shown:getButtonById("bar").text == "Bar: grey 64", shown:getButtonById("bar").text)
    local snap = picked.store.partSnapshot("bar_night")
    picked.store.partDelete("bar_night")
    assert(ctx.entry.colors == nil, "delete left an empty table")
    picked.store.partRestore("bar_night", snap)
    assert(ctx.entry.colors.bar_night.grey == 0x40, "revert didn't restore")
end)

t.test("Reset clears this look only", function()
    suffix = ""
    local ctx = ctxFor({ id = "q", module = "quote",
        colors = { bg = { grey = 1 }, bg_night = { grey = 2 }, border = false } })
    Menu.show(ctx)
    for _r, row in ipairs(shown.buttons) do
        for _i, b in ipairs(row) do if b.text == "Reset" then b.callback() end end
    end
    assert(ctx.entry.colors.bg == nil and ctx.entry.colors.border == nil, "light look not cleared")
    assert(ctx.entry.colors.bg_night.grey == 2, "the dark look was cleared too")
end)

t.test("changes stay in memory while the menu is up, and are written once as it closes", function()
    -- Each write is the whole settings file (~300 ms a tap on a PW5).
    suffix = ""
    local flushed = 0
    package.loaded["lib/bookshelf_settings_store"] = { flush = function() flushed = flushed + 1 end }
    local ctx = ctxFor({ id = "q", module = "quote" })
    local deferred = 0
    function ctx.saveDeferred() deferred = deferred + 1 end
    Menu.show(ctx)
    shown:getButtonById("border").callback()
    shown:getButtonById("border").callback()
    assert(deferred == 2 and ctx.saves == 0, "wrote the file on a tap")
    assert(flushed == 0)
    shown:onCloseWidget()
    assert(flushed == 1, "not written as the menu closed")
end)

t.done()
