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

t.test("the strip: No wallpaper (and Same as wallpaper for full screen)", function()
    local picked = {}
    local row = WB.headerActions("wallpaper_default", function(it) picked[#picked + 1] = it end)
    eq(labels(row), "No wallpaper")
    row[1].on_tap(); eq(picked[1].kind, "none", "No wallpaper did not choose none as a card tap does")
    eq(labels(WB.headerActions("wallpaper_full", function() end)), "Same as wallpaper,No wallpaper")
end)

t.test("a strip button is on (black) while it is the choice in use", function()
    store = {}
    local d = WB.headerActions("wallpaper_default", function() end)
    eq(d[1].on_when(), true, "nothing set: No wallpaper is the choice already")
    store.wallpaper_default = "leaves.png"
    eq(d[1].on_when(), false)
    local f = WB.headerActions("wallpaper_full", function() end)
    store.wallpaper_full = nil
    eq(f[1].on_when(), true, "full unset: Same as wallpaper"); eq(f[2].on_when(), false)
    store.wallpaper_full = false
    eq(f[1].on_when(), false); eq(f[2].on_when(), true, "full false: No wallpaper")
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

t.test("no radio: one a page, the page is the choice; several a page, the one in use has the heavy frame", function()
    -- Maintainer, 2026-11-03: the radio was unnecessary with one picture a
    -- page; the name sits centred under the picture.
    local src = io.open("lib/bookshelf_wallpaper_browser.lua"):read("*a")
    assert(not src:find("Marks.Radio", 1, true), "the radio mark is back")
    assert(src:find("local in_use = several and WB.inUse(key, item)", 1, true),
        "landscape lost its mark for the one in use")
    -- On the CARD, not the picture's frame (maintainer, 2026-11-03): the
    -- picture's frame would change size with it.
    assert(src:find("{ outline = in_use })", 1, true), "the in-use mark is not the card's outline")
    assert(not src:find("in_use and Size.border.thick", 1, true), "the picture's frame still thickens")
    assert(not src:find('_("In use")', 1, true), "the In use line is still there")
end)

-- ── paging chooses (portrait) ───────────────────────────────────────────────
local function showWith(w, h)
    local cfg
    local scheduled = {}
    package.loaded["device"] = { screen = { getWidth = function() return w end,
                                            getHeight = function() return h end } }
    package.loaded["ui/uimanager"] = {
        show = function() end, close = function() end, setDirty = function() end,
        scheduleIn = function(_s, _d, fn) scheduled[#scheduled + 1] = fn end,
        unschedule = function(_s, fn)
            for i = #scheduled, 1, -1 do if scheduled[i] == fn then table.remove(scheduled, i) end end
        end,
    }
    package.loaded["lib/bookshelf_library_modal"] = {
        rowsForShare = function() return 4 end,
        new = function(_s, o) cfg = o.config
            return { refresh = function() end } end,
    }
    WB.show("wallpaper_default")
    return cfg, scheduled
end
local function run(list) local l = {}; for i, f in ipairs(list) do l[i] = f end
    for i = #list, 1, -1 do list[i] = nil end
    for _i, f in ipairs(l) do f() end end

t.test("portrait: the page left on screen becomes the wallpaper, once paging stops", function()
    store = {}; chosen = {}
    local cfg, scheduled = showWith(600, 800)
    cfg.on_page_shown(2)
    eq(#scheduled, 1, "the choice should wait for the page to settle")
    eq(store["wallpaper_default"], nil, "chosen before the page settled")
    run(scheduled)
    eq(store["wallpaper_default"], "theme-pack\1Japan\1wallpaper.png")
end)

t.test("flicking through chooses only the page landed on", function()
    store = {}; chosen = {}
    local cfg, scheduled = showWith(600, 800)
    cfg.on_page_shown(2); cfg.on_page_shown(1)
    eq(#scheduled, 1, "each page turn should replace the pending choice")
    run(scheduled)
    eq(store["wallpaper_default"], "leaves.png")
end)

t.test("closing while a page settles chooses nothing", function()
    store = {}; chosen = {}
    local cfg, scheduled = showWith(600, 800)
    cfg.on_page_shown(2)
    cfg.on_closed()
    eq(#scheduled, 0, "the pending choice survived the close")
end)

t.test("landscape (several a page): paging chooses nothing, a tap does", function()
    store = {}; chosen = {}
    local cfg, scheduled = showWith(800, 600)
    cfg.on_page_shown(2)
    eq(#scheduled, 0)
end)


-- ── previews: decoded at their size, kept in memory ─────────────────────────
local function previewSetup(size)
    local decodes, disk = {}, {}
    local function bb(w, h)
        local b = { w = w, h = h }
        function b:getWidth() return self.w end
        function b:getHeight() return self.h end
        function b:getType() return 1 end
        function b:free() self.freed = true end
        function b:fill() end
        function b:blitFrom() end
        return b
    end
    package.loaded["ui/renderimage"] = {
        renderImageFile = function(_s, path, _f, w, h)
            decodes[#decodes + 1] = { path = path, w = w, h = h }
            return bb(w or 1440, h or 1920)
        end,
        scaleBlitBuffer = function(_s, b, w, h) return bb(w, h) end,
    }
    package.loaded["ffi/blitbuffer"] = { COLOR_WHITE = 0, new = function(w, h) return bb(w, h) end }
    package.loaded["lib/bookshelf_cover_disk_cache"] = {
        load = function(k) return disk[k] end,
        store = function(k, b) disk[k] = b; return true end,
    }
    package.loaded["lib/bookshelf_image_source"] = { probeSize = function() return size[1], size[2] end }
    package.loaded["libs/libkoreader-lfs"] = { attributes = function() return { modification = 7, size = 99 } end }
    package.loaded["device"] = { screen = { getWidth = function() return 600 end, getHeight = function() return 800 end,
                                            bb = { getType = function() return 1 end } } }
    local fit = "stretch"
    package.loaded["lib/bookshelf_wallpaper"] = {
        SETTING = "wallpaper_default", FULL_SETTING = "wallpaper_full",
        fitMode = function() return fit end,
        fitLayout = dofile("lib/bookshelf_wallpaper.lua").fitLayout,
        toScreenType = function(b) return b end,
    }
    WB._previewReset()
    return decodes, disk, function(m) fit = m end
end

t.test("a preview is decoded at its own size, not the picture's", function()
    local decodes = previewSetup({ 1440, 1920 })
    WB._preview("/w/a.png", 300, 400, "stretch")
    eq(decodes[1].w, 300); eq(decodes[1].h, 400)
end)

t.test("Crop to fill decodes at the covering size from the file's header", function()
    local decodes = previewSetup({ 1600, 900 })
    WB._preview("/w/a.png", 300, 400, "fill")
    eq(decodes[1].w, 711); eq(decodes[1].h, 400)
end)

t.test("a preview is kept in memory only, never on disk", function()
    local decodes, disk = previewSetup({ 1440, 1920 })
    WB._preview("/w/a.png", 300, 400, "fit")
    WB._preview("/w/a.png", 300, 400, "fit")
    eq(#decodes, 1, "decoded again while in memory")
    eq(next(disk), nil, "a preview was written to disk")
end)

t.test("a different scaling or size is a different preview", function()
    local decodes = previewSetup({ 1440, 1920 })
    WB._preview("/w/a.png", 300, 400, "fit")
    WB._preview("/w/a.png", 300, 400, "fill")
    WB._preview("/w/a.png", 200, 400, "fit")
    eq(#decodes, 3)
end)

t.done()
