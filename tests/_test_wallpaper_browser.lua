-- tests/_test_wallpaper_browser.lua
-- The wallpaper picker: the reader's own pictures and the packs', one large
-- preview per page. Pins what it lists, in which order, per tab, which one
-- reads as in use, and what a tap stores.
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["logger"] = { dbg = function() end, info = function() end,
                             warn = function() end, err = function() end }
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

local store = {}
package.loaded["lib/bookshelf_settings_store"] = {
    read = function(k) return store[k] end,
    save = function(k, v) store[k] = v end,
    delete = function(k) store[k] = nil end,
    flush = function() end,
}
package.loaded["lib/bookshelf_wallpaper"] = {
    SETTING = "wallpaper_default", FULL_SETTING = "wallpaper_full",
    list = function() return { { name = "leaves.png", label = "leaves", path = "/w/leaves.png" } } end,
    free = function() end,
}
local chosen = {}
package.loaded["lib/bookshelf_theme_pack"] = {
    wallpaperEntries = function() return { { name = "theme-pack\1Japan\1wallpaper.png", label = "Japan",
                                             pack = "Japan", path = "/o/Japan/theme/wallpaper.png" } } end,
    isPackName = function(n) return type(n) == "string" and n:sub(1, 11) == "theme-pack\1" end,
    chooseWallpaper = function(k, n) chosen[#chosen + 1] = { k, n }; store[k] = n end,
    -- The editing seam: the reader's own keys (a Custom theme shelf).
    partRead = function(k) return store[k] end,
    partSave = function(k, v) store[k] = v end,
    partDelete = function(k) store[k] = nil end,
}
local switched_on = {}
package.loaded["lib/bookshelf_ornaments"] = { setPackOff = function(p, off) if not off then switched_on[#switched_on + 1] = p end end }
local WB = dofile("lib/bookshelf_wallpaper_browser.lua")

t.test("All: the reader's own, then the packs': pictures only, no None page", function()
    -- Maintainer, 2026-10-08: the picker opened on a None page with a folder
    -- path, the pictures pages away. No wallpaper is a footer button now.
    local e = WB.entries("wallpaper_default", WB.ALL)
    eq(#e, 2); eq(e[1].kind, "own"); eq(e[2].kind, "pack"); eq(e[2].pack, "Japan")
    local f = WB.entries("wallpaper_full", WB.ALL)
    eq(#f, 2, "full screen: Same as wallpaper or None came back as a page"); eq(f[1].kind, "own")
end)

t.test("tabs: Yours is the reader's own; a pack's tab is its wallpaper", function()
    local y = WB.entries("wallpaper_default", WB.YOURS)
    eq(#y, 1); eq(y[1].kind, "own")
    local j = WB.entries("wallpaper_default", "Japan")
    eq(#j, 1); eq(j[1].pack, "Japan")
end)

local function labels(row)
    local o = {}
    for i, a in ipairs(row) do o[i] = a.label end
    return table.concat(o, ",")
end

t.test("the footer: No wallpaper (and Same as wallpaper for full screen) beside Close", function()
    local picked, closed = {}, 0
    local row = WB.footerActions("wallpaper_default", function(it) picked[#picked + 1] = it end, function() closed = closed + 1 end)
    eq(labels(row), "No wallpaper,Close")
    row[1].on_tap(); eq(picked[1].kind, "none", "No wallpaper did not choose none as a card tap does")
    row[2].on_tap(); eq(closed, 1)
    eq(labels(WB.footerActions("wallpaper_full", function() end, function() end)), "Same as wallpaper,No wallpaper,Close")
end)

t.test("a footer button is greyed while it is the choice in use", function()
    store = {}
    local d = WB.footerActions("wallpaper_default", function() end, function() end)
    eq(d[1].enabled_when(), false, "nothing set: No wallpaper is the choice already")
    store.wallpaper_default = "leaves.png"
    eq(d[1].enabled_when(), true)
    local f = WB.footerActions("wallpaper_full", function() end, function() end)
    store.wallpaper_full = nil
    eq(f[1].enabled_when(), false, "full unset: Same as wallpaper"); eq(f[2].enabled_when(), true)
    store.wallpaper_full = false
    eq(f[1].enabled_when(), true); eq(f[2].enabled_when(), false, "full false: No wallpaper")
end)

t.test("which picture reads as in use", function()
    store = {}
    local e = WB.entries("wallpaper_default", WB.ALL)
    eq(WB.inUse("wallpaper_default", e[1]), false)
    store.wallpaper_default = "leaves.png"
    eq(WB.inUse("wallpaper_default", e[1]), true); eq(WB.inUse("wallpaper_default", WB.NONE), false)
end)

t.test("a choice stores it, and only it: No wallpaper, Same as wallpaper, a picture", function()
    store = { wallpaper_default = "leaves.png", wallpaper_full = "x.png" }
    local e = WB.entries("wallpaper_default", WB.ALL)
    WB.choose("wallpaper_default", WB.NONE); eq(store.wallpaper_default, false)
    WB.choose("wallpaper_default", e[2]); eq(store.wallpaper_default, "theme-pack\1Japan\1wallpaper.png")
    eq(store.wallpaper_default_own, nil, "a pack's picture keeps a hidden copy of the reader's own")
    WB.choose("wallpaper_full", WB.SAME); eq(store.wallpaper_full, nil)
end)

t.test("the folder is named only where there are no pictures; the Wallpaper row's help names it", function()
    local src = io.open("lib/bookshelf_wallpaper_browser.lua"):read("*a")
    assert(not src:find('_("Images are loaded from %1")', 1, true), "the picker still prints the folder path")
    local empty = src:match("empty_state = function%(w, h%)(.-)\n        end,")
    assert(empty and empty:find('_("No images in %1")', 1, true), "an empty tab does not say where pictures go")
    local st = io.open("lib/bookshelf_settings.lua"):read("*a")
    local row = st:match('_%("Wallpaper: %%1"%)(.-)callback = openPicker%(Wallpaper%.SETTING%)')
    assert(row and row:find("help_text_func", 1, true) and row:find('_("Images are loaded from %1")', 1, true),
        "the Wallpaper row's help does not say where the pictures come from")
end)

t.test("choosing a pack's wallpaper never switches its pack on (the switches shape ornaments only)", function()
    store = {}
    WB.choose("wallpaper_default", { kind = "pack", name = "theme-pack\1Japan\1wallpaper.png", pack = "Japan", pack_off = true })
    eq(#switched_on, 0, "the picker switched a pack on")
    eq(store.wallpaper_default, "theme-pack\1Japan\1wallpaper.png")
end)

t.test("the picker opens on the page of the wallpaper in use", function()
    store = { wallpaper_default = "leaves.png" }
    local e = WB.entries("wallpaper_default", WB.ALL)
    store = { wallpaper_default = "theme-pack\1Japan\1wallpaper.png" }
    eq(WB.startPage("wallpaper_default", e, 1), 2, "one to a page (portrait): the second page")
    eq(WB.startPage("wallpaper_default", e, 4), 1, "four to a page (landscape): the first")
    store = { wallpaper_default = "leaves.png" }
    eq(WB.startPage("wallpaper_default", e, 1), 1, "the first picture: the first page")
    store = {}
    eq(WB.startPage("wallpaper_default", e), 1, "no wallpaper: the first page")
end)

t.test("the picker marks the one in use with a radio mark, not a line under the picture", function()
    local src = io.open("lib/bookshelf_wallpaper_browser.lua"):read("*a")
    assert(src:find("Marks.Radio:new{ checked = WB.inUse(key, item) }", 1, true), "no radio mark")
    assert(not src:find('_("In use")', 1, true), "the In use line is still there")
end)

t.done()
