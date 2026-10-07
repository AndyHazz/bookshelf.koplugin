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
}
local switched_on = {}
package.loaded["lib/bookshelf_ornaments"] = { setPackOff = function(p, off) if not off then switched_on[#switched_on + 1] = p end end }
local WB = dofile("lib/bookshelf_wallpaper_browser.lua")

t.test("default wallpaper, All: None, the reader's own, then the packs'", function()
    local e = WB.entries("wallpaper_default", WB.ALL)
    eq(#e, 3); eq(e[1].kind, "none"); eq(e[2].kind, "own"); eq(e[3].kind, "pack"); eq(e[3].pack, "Japan")
end)

t.test("full screen: Same as wallpaper first", function()
    local e = WB.entries("wallpaper_full", WB.ALL)
    eq(e[1].kind, "same"); eq(e[1].label, "Same as wallpaper"); eq(e[2].kind, "none"); eq(#e, 4)
end)

t.test("tabs: Yours is None and the reader's own; a pack's tab is its wallpaper", function()
    local y = WB.entries("wallpaper_default", WB.YOURS)
    eq(#y, 2); eq(y[2].kind, "own")
    local j = WB.entries("wallpaper_default", "Japan")
    eq(#j, 1); eq(j[1].pack, "Japan")
end)

t.test("which reads as in use", function()
    store = {}
    local e = WB.entries("wallpaper_default", WB.ALL)
    eq(WB.inUse("wallpaper_default", e[1]), true, "nothing set: None")
    store.wallpaper_default = "leaves.png"
    eq(WB.inUse("wallpaper_default", e[2]), true); eq(WB.inUse("wallpaper_default", e[1]), false)
    local f = WB.entries("wallpaper_full", WB.ALL)
    store.wallpaper_full = nil
    eq(WB.inUse("wallpaper_full", f[1]), true, "full unset: Same as default")
    store.wallpaper_full = false
    eq(WB.inUse("wallpaper_full", f[2]), true, "full false: None")
end)

t.test("a tap stores the choice, and only it: None, Same as wallpaper, a picture", function()
    store = { wallpaper_default = "leaves.png", wallpaper_full = "x.png" }
    local e = WB.entries("wallpaper_default", WB.ALL)
    WB.choose("wallpaper_default", e[1]); eq(store.wallpaper_default, false)
    WB.choose("wallpaper_default", e[3]); eq(store.wallpaper_default, "theme-pack\1Japan\1wallpaper.png")
    eq(store.wallpaper_default_own, nil, "a pack's picture keeps a hidden copy of the reader's own")
    local f = WB.entries("wallpaper_full", WB.ALL)
    WB.choose("wallpaper_full", f[1]); eq(store.wallpaper_full, nil)
end)

t.test("the None card says where the pictures come from", function()
    local src = io.open("lib/bookshelf_wallpaper_browser.lua"):read("*a")
    assert(src:find('_("Images are loaded from %1")', 1, true), "the folder hint is gone")
    assert(src:find('_("No images in %1")', 1, true), "the empty-folder message is gone")
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
    eq(WB.startPage("wallpaper_default", e, 1), 2, "one to a page (portrait): the second page")
    eq(WB.startPage("wallpaper_default", e, 4), 1, "four to a page (landscape): the first")
    store = {}
    eq(WB.startPage("wallpaper_default", e), 1, "nothing chosen: None, the first page")
end)

t.test("the picker marks the one in use with a radio mark, not a line under the picture", function()
    local src = io.open("lib/bookshelf_wallpaper_browser.lua"):read("*a")
    assert(src:find("Marks.Radio:new{ checked = WB.inUse(key, item) }", 1, true), "no radio mark")
    assert(not src:find('_("In use")', 1, true), "the In use line is still there")
end)

t.done()
