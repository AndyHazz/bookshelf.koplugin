-- tests/_test_theme_packs.lua
-- Theme packs: the theme/ subfolder of an ornament pack (wallpaper variants,
-- plank design, colours.json), and themes as layers: choosing, migration.
-- Run from the plugin root: lua tests/_test_theme_packs.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["logger"] = { dbg = function() end, info = function() end,
                             warn = function() end, err = function() end }

local function sh(cmd)
    local f = io.popen(cmd .. " 2>/dev/null"); local out = f:read("*a"); f:close(); return out
end
local lfs_shim = {
    attributes = function(path, attr)
        local q = "'" .. path .. "'"
        if attr == "mode" then
            if sh("test -d " .. q .. " && echo d"):match("d") then return "directory" end
            if sh("test -e " .. q .. " && echo f"):match("f") then return "file" end
            return nil
        elseif attr == "modification" then return tonumber(sh(dofile("tests/_helpers.lua").statCmd("mtime", q))) end
        return nil
    end,
    dir = function(path)
        local list = {}
        for name in sh("ls -a '" .. path .. "'"):gmatch("[^\n]+") do list[#list + 1] = name end
        local i = 0
        return function() i = i + 1; return list[i] end
    end,
}

local t  = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq

-- A tiny JSON decoder for the tests only (the module uses rapidjson on the
-- device): objects of objects of strings, which is all colours.json holds.
local function tiny_json(s)
    local f, err = load("return " .. s:gsub('"([^"]-)"%s*:', '["%1"]='))
    if not f then error(err) end
    return f()
end

local tmp = os.getenv("TMPDIR") or "/tmp"
local function scratch()
    local d = string.format("%s/bookshelf_theme_test_%d_%d", tmp, os.time(), math.random(1e6))
    os.execute("rm -rf '" .. d .. "' && mkdir -p '" .. d .. "'")
    return d
end
local function touch(p, body)
    os.execute("mkdir -p \"$(dirname '" .. p .. "')\"")
    local f = io.open(p, "wb"); f:write(body or "x"); f:close()
end

-- Fake ornaments module + store, so the suite needs neither KOReader nor
-- the real ornaments scan.
local function setup()
    local d = scratch()
    local settings = {}
    local off, packs_off = {}, {}
    local orn = {
        dir = function() return d end,
        listAll = function()
            local packs = {}
            for name in sh("ls '" .. d .. "'"):gmatch("[^\n]+") do
                if lfs_shim.attributes(d .. "/" .. name, "mode") == "directory" then
                    packs[#packs + 1] = name
                end
            end
            table.sort(packs)
            return {}, packs
        end,
        isPackOff = function(p) return packs_off[p] == true end,
        isOff = function(r) return off[r] == true end,
        setPackOff = function(p, v) packs_off[p] = v and true or nil end,
        setOff = function(r, v) off[r] = v and true or nil end,
    }
    package.loaded["lib/bookshelf_theme_pack"] = nil
    local TP = dofile("lib/bookshelf_theme_pack.lua")
    TP._lfs = lfs_shim
    TP._orn = orn
    TP._decode = tiny_json
    TP._store = { read = function(k) return settings[k] end,
                  save = function(k, v) settings[k] = v end,
                  flush = function() end }
    TP.SCAN_TTL = 0
    return TP, d, settings, packs_off, off
end

t.test("a pack without theme/ has no parts", function()
    local TP, d = setup()
    touch(d .. "/Autumn/Owl.png")
    local th = TP.theme("Autumn")
    eq(th.wallpaper, nil); eq(th.plank, nil); eq(th.colours, nil)
end)

t.test("wallpaper variants are found and chosen per view and look", function()
    local TP, d = setup()
    for _, f in ipairs({ "wallpaper.jpg", "wallpaper.full.png", "wallpaper.dark.jpg", "other.png" }) do
        touch(d .. "/Xmas/theme/" .. f)
    end
    local w = TP.theme("Xmas").wallpaper
    eq(w.base, "wallpaper.jpg"); eq(w.full, "wallpaper.full.png"); eq(w.dark, "wallpaper.dark.jpg")
    eq(w.full_dark, nil)
    eq(TP.wallpaperFile(w, false, false), "wallpaper.jpg")
    local f, dv = TP.wallpaperFile(w, false, true); eq(f, "wallpaper.dark.jpg"); eq(dv, true)
    eq(TP.wallpaperFile(w, true, false), "wallpaper.full.png")
    f, dv = TP.wallpaperFile(w, true, true)
    eq(f, "wallpaper.full.png", "full screen + dark: full.dark missing, full wins over dark")
    eq(dv, false)
end)

t.test("a wallpaper variant without the base file is no wallpaper", function()
    local TP, d = setup()
    touch(d .. "/Xmas/theme/wallpaper.dark.jpg")
    eq(TP.theme("Xmas").wallpaper, nil)
end)

t.test("plank files: middle required, ends optional", function()
    local TP, d = setup()
    touch(d .. "/A/theme/plank.left.png")
    eq(#TP.theme("A").planks, 0, "no middle, no plank")
    touch(d .. "/B/theme/plank.middle.png"); touch(d .. "/B/theme/plank.right.png")
    local p = TP.theme("B").planks[1]
    assert(p.middle:match("/B/theme/plank%.middle%.png$")); eq(p.left, nil)
    assert(p.right:match("plank%.right%.png$"))
    eq(p.id, "B/theme/plank"); eq(p.name, nil); eq(p.pack, "B")
end)

t.test("a pack of planks: each named plank is its own design", function()
    local TP, d = setup()
    for _, f in ipairs({ "plank.Dark Oak.middle.png", "plank.Dark Oak.left.png",
                         "plank.birch.middle.png", "plank.middle.png", "plank.ash.left.png" }) do
        touch(d .. "/Woods/theme/" .. f)
    end
    local ps = TP.theme("Woods").planks
    eq(#ps, 3, "unnamed, birch, Dark Oak; ash has no middle")
    eq(ps[1].name, nil); eq(ps[2].name, "birch"); eq(ps[3].name, "Dark Oak")
    eq(ps[3].id, "Woods/theme/plank.Dark Oak")
    assert(ps[3].left:match("plank%.Dark Oak%.left%.png$")); eq(ps[2].left, nil)
    eq(TP.plankLabel(ps[3]), "Dark Oak"); eq(TP.plankLabel(ps[1]), "Woods")
end)

t.test("colours.json maps friendly names to settings", function()
    local TP, d = setup()
    touch(d .. "/Xmas/theme/colours.json",
        '{"day": {"plank": "#8A5A3C", "selected shelf": "#B22222"}, "night": {"text": "#EEEEEE"}}')
    local c = TP.theme("Xmas").colours
    eq(c.day.spine_plank_color, "#8A5A3C"); eq(c.day.chip_selected_bg, "#B22222")
    eq(c.night.ink_color, "#EEEEEE")
end)

t.test("bad colours.json: good entries apply, bad ones are skipped", function()
    local TP, d = setup()
    touch(d .. "/A/theme/colours.json", '{"day": {"plank": "#12", "sparkles": "#FFFFFF", "text": "#000000"}}')
    local c = TP.theme("A").colours
    eq(c.day.ink_color, "#000000"); eq(c.day.spine_plank_color, nil)
    touch(d .. "/B/theme/colours.json", "{ not json")
    eq(TP.theme("B").colours, nil, "unparseable file: no colour theme, no error")
end)

local function mkwall(d, p) touch(d .. "/" .. p .. "/theme/wallpaper.png") end
local function mkplank(d, p, n) touch(d .. "/" .. p .. "/theme/plank." .. n .. ".middle.png") end
local function mkcolours(d, p) touch(d .. "/" .. p .. "/theme/colours.json", '{"day":{"text":"#112233"},"night":{}}') end
local function mkmanifest(d, p, body) touch(d .. "/" .. p .. "/theme/theme.json", body or "{}") end

t.test("a gone pack: its wallpaper names nothing, its colours are not shown", function()
    local TP, d = setup()
    touch(d .. "/A/theme/wallpaper.png")
    touch(d .. "/A/theme/colours.json", '{"day": {"text": "#101010"}}')
    TP.setLibraryTheme("A")
    local name = TP.wallpaperEntries()[1].name
    os.execute("rm -rf '" .. d .. "/A'")
    TP.invalidate()
    eq(TP.variantName(name, false, false), nil, "a gone pack's wallpaper names nothing")
    eq(TP.coloursSource(), "mine"); eq(TP.colourOverride("ink_color", false), nil)
    eq(TP.libraryChoice(), "A", "the library keeps the name, for when the pack comes back")
end)

t.test("colour override: day as written, night pre-inverted, plank never", function()
    local TP, d = setup()
    touch(d .. "/A/theme/colours.json",
        '{"day": {"text": "#101010"}, "night": {"text": "#F0F0F0", "plank": "#806040"}}')
    TP.setLibraryTheme("A")
    eq(TP.colourOverride("ink_color", false).hex, "#101010")
    eq(TP.colourOverride("ink_color", true).hex:upper(), "#0F0F0F", "night slot is stored pre-inverted")
    eq(TP.colourOverride("spine_plank_color", true).hex, "#806040", "plank is display space")
    eq(TP.colourOverride("badge_bg", false), nil, "a colour the pack does not set")
    TP.setLibraryTheme("mine")
    eq(TP.colourOverride("ink_color", false), nil)
end)

t.test("a theme's colours show whatever the collection's switch says", function()
    local TP, d, _s, packs_off = setup()
    touch(d .. "/A/theme/colours.json", '{"day": {"text": "#101010"}}')
    TP.setLibraryTheme("A")
    packs_off["A"] = true
    eq(TP.colourOverride("ink_color", false).hex, "#101010",
        "a pack switched off in the collection hid a chosen theme's colours")
end)

t.test("every colour read asks the theme first, Plain for defaults; the menu reads the reader's own", function()
    local cp = io.open("lib/bookshelf_cover_progress.lua"):read("*a")
    assert(cp:find("local function _readOwnColor", 1, true), "no _readOwnColor")
    local rm = cp:match("local function _readModeColor%(.-\nend\n")
    assert(rm and rm:find("TP.colourOverride, base_key", 1, true), "_readModeColor does not ask the theme")
    assert(rm:find("TP.defaultColours", 1, true), "_readModeColor ignores Plain's defaults")
    local raw = cp:match("function M%.rawColors%(%).-\nend")
    assert(raw and not raw:find("_readModeColor(", 1, true), "rawColors must read the reader's OWN colours")
    local pb = cp:match("function M%.pickedBarColors%(%).-\nend")
    assert(pb and pb:find("TP.defaultColours", 1, true), "the bars ignore Plain's defaults")
    local cb = io.open("lib/bookshelf_chip_bar.lua"):read("*a")
    local rb = cb:match("local function _readBarColor%(.-\nend\n")
    assert(rb and rb:find("TP.colourOverride, base_key", 1, true), "selected chip colours ignore the theme")
    assert(rb:find("TP.defaultColours", 1, true), "selected chip colours ignore Plain")
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    local pg = w:match("function BookshelfWidget:_pageGroundColor%(%).-\nend")
    assert(pg and pg:find("colourOverride(", 1, true) and pg:find("defaultColours", 1, true),
        "the page ground ignores the theme or Plain")
    local ps = w:match("function BookshelfWidget:_pageColourStored%(%).-\nend")
    assert(ps and ps:find("defaultColours", 1, true), "the ground state ignores the theme or Plain")
end)

t.test("theme colours cost no file checks per read within the scan TTL", function()
    local TP, d = setup()
    touch(d .. "/A/theme/colours.json", '{"day": {"text": "#101010"}}')
    TP.setLibraryTheme("A")
    TP.SCAN_TTL = 15; TP._clock = function() return 5 end
    TP.colourOverride("ink_color", false)
    local stats = 0
    local real = TP._lfs.attributes
    TP._lfs.attributes = function(...) stats = stats + 1; return real(...) end
    for _i = 1, 20 do TP.colourOverride("ink_color", false) end
    TP._lfs.attributes = real
    eq(stats, 0, "twenty colour reads, no stat calls")
end)

t.test("the browser: a tap redraws only itself; the shelf waits for close", function()
    local b = io.open("lib/bookshelf_ornament_browser.lua"):read("*a")
    local changed = b:match("function Browser:_changed%(.-\nend")
    assert(changed and changed:find("forgetChoice", 1, true),
        "a switch must drop the cached plank choice")
    assert(not changed:find("on_change", 1, true), "every tap still rebuilds the shelf behind")
    assert(changed:find("if rescan then", 1, true), "every tap still rescans the ornament folders")
    local toggle = b:match("function Browser:_toggle%(item%).-\nend")
    assert(toggle and not toggle:find('setDirty("all", "full")', 1, true),
        "a tap still flashes the whole screen")
    local closed = b:match("local function closed%(%).-\n    end")
    assert(closed and closed:find("endDeferred", 1, true) and closed:find("on_change", 1, true),
        "closing must flush and rebuild the shelf once")
    assert(not closed:find('setDirty("all", "full")', 1, true), "closing still flashes the whole screen")
    local pb = io.open("lib/bookshelf_plank_browser.lua"):read("*a")
    local closed_pb = pb:match("on_closed = function%(%).-\n        end,")
    assert(closed_pb and closed_pb:find('setDirty("all", "full")', 1, true),
        "closing the plank picker after a change must repaint fully")
    local st = io.open("lib/bookshelf_settings.lua"):read("*a")
    local row = st:match("function Settings:_plankRow%(.-\nend\n")
    assert(row and row:find('UIManager:setDirty(bw, "ui")', 1, true), "a plank tap does not repaint the shelf behind")
end)

t.test("Swap on a themed shelf never switches the theme's pack on in the collection", function()
    local b = io.open("lib/bookshelf_ornament_browser.lua"):read("*a")
    local pick = b:match("function Browser:_pick%(item%)(.-)\nend\n")
    assert(pick and pick:find("not self.opts.pool", 1, true),
        "a pick on a themed shelf flips a pack switch of the reader's own collection")
end)

t.test("plankRowLabel: the reader's own plank: Oak, a pack plank with its pack, nil for the colour", function()
    local TP, d = setup()
    TP._plugin_root = "."
    touch(d .. "/Planks/theme/plank.Walnut.middle.png")
    mkmanifest(d, "H"); mkplank(d, "H", "Ash")
    TP.invalidate()
    TP.setLibraryTheme("H")                    -- a theme's plank does not change the row
    TP.choosePlank("oak"); eq(TP.plankRowLabel(), "Oak")
    TP.choosePlank("Planks/theme/plank.Walnut"); eq(TP.plankRowLabel(), "Walnut (Planks pack)")
    TP.choosePlank("colour"); eq(TP.plankRowLabel(), nil)
end)

-- ── The plank: one choice (theme_plank_pack) ─────────────────────────────
t.test("plank choice: a fresh install is Oak; an own plank colour stays a colour", function()
    local TP, _d, settings = setup()
    TP._plugin_root = "."
    eq(TP.plankChoice(), "oak")
    assert(TP.activePlank().builtin, "Oak is not what shows")
    settings["spine_plank_color"] = { hex = "#806040" }
    TP.forgetChoice()
    eq(TP.plankChoice(), "colour", "an upgrader's own plank colour was replaced")
    settings["spine_plank_color"] = nil; settings["spine_plank_color_night"] = { grey = 90 }
    eq(TP.plankChoice(), "colour", "so was a night one")
    settings["spine_plank_color_night"] = nil; settings[TP.WOOD_SETTING] = false
    eq(TP.plankChoice(), "colour", "an Oak switched off before stays off")
end)

t.test("plank choice: installing a pack's plank does not switch it on", function()
    local TP, d = setup()
    TP._plugin_root = "."
    touch(d .. "/Planks/theme/plank.Walnut.middle.png")
    TP.invalidate()
    eq(TP.plankChoice(), "oak")
    assert(TP.activePlank().builtin)
end)

t.test("choosePlank: a pack plank, Oak or the colour; a design choice switches designs on", function()
    local TP, d, settings = setup()
    TP._plugin_root = "."
    touch(d .. "/Planks/theme/plank.Walnut.middle.png")
    TP.invalidate()
    TP.setDesignsOn(false)
    TP.choosePlank("Planks/theme/plank.Walnut")
    eq(TP.plankChoice(), "Planks/theme/plank.Walnut")
    eq(TP.designsOn(), true)
    eq(TP.activePlank().name, "Walnut")
    TP.setDesignsOn(false)
    eq(TP.activePlank(), nil, "designs off: none drawn")
    eq(TP.chosenPlank().name, "Walnut", "but the menu still knows which is chosen")
    TP.choosePlank("colour")
    eq(TP.designsOn(), false, "choosing the colour is not a choice of design")
    TP.setDesignsOn(true)
    eq(TP.activePlank(), nil)
    TP.choosePlank("oak")
    assert(TP.activePlank().builtin)
    eq(settings[TP.WOOD_SETTING], nil, "plank_wood is folded into the one choice")
end)

t.test("a chosen pack plank shows whatever the collection's switch says; gone, it falls back", function()
    local TP, d, _s, packs_off = setup()
    TP._plugin_root = "."
    touch(d .. "/Planks/theme/plank.Walnut.middle.png")
    TP.invalidate()
    TP.choosePlank("Planks/theme/plank.Walnut")
    packs_off["Planks"] = true
    TP.forgetChoice()
    eq(TP.plankChoice(), "Planks/theme/plank.Walnut", "a pack switch hid the reader's plank")
    os.execute("rm -rf '" .. d .. "/Planks'"); TP.invalidate()
    eq(TP.plankChoice(), "oak")
end)

t.test("plankOptions: the colour, Oak, then each pack's planks by pack, with no off state", function()
    local TP, d, _s, packs_off = setup()
    TP._plugin_root = "."
    touch(d .. "/Planks/theme/plank.Walnut.middle.png"); touch(d .. "/Planks/theme/plank.Ash.middle.png")
    touch(d .. "/Japan/theme/plank.Gallery.middle.png")
    packs_off["Planks"] = true
    TP.invalidate()
    local o = TP.plankOptions()
    eq(o[1].kind, "colour"); eq(o[2].kind, "oak")
    eq(o[3].pack, "Japan"); eq(o[4].plank.name, "Ash"); eq(o[5].plank.name, "Walnut")
    eq(o[4].pack_off, nil, "the picker shows no pack switch")
end)

t.test("activePlank is cached for the scan TTL; a choice is seen at once", function()
    local TP, d = setup()
    TP._plugin_root = "."
    touch(d .. "/A/theme/plank.middle.png")
    local now, calls = 0, 0
    TP._clock = function() return now end
    TP.SCAN_TTL = 15
    local real = TP.theme
    TP.theme = function(p) calls = calls + 1; return real(p) end
    TP.choosePlank("A/theme/plank")
    eq(TP.activePlank().pack, "A"); eq(TP.activePlank().pack, "A")
    TP.choosePlank("colour"); eq(TP.activePlank(), nil, "a choice is seen at once")
    TP.choosePlank("A/theme/plank"); eq(TP.activePlank().pack, "A")
    now = now + 16; TP.activePlank(); eq(calls >= 2, true, "and it expires")
end)

-- ── A pack's wallpaper is an ordinary choice ──────────────────────────────
t.test("pack wallpapers are listed as ordinary choices", function()
    local TP, d, _s, packs_off = setup()
    touch(d .. "/Japan/theme/wallpaper.png"); touch(d .. "/Autumn/Owl.png")
    packs_off["Japan"] = true
    local e = TP.wallpaperEntries()
    eq(#e, 1); eq(e[1].pack, "Japan"); eq(e[1].pack_off, nil)
    eq(TP.isPackName(e[1].name), true); eq(TP.isPackName("leaves.png"), false)
    eq(e[1].path, d .. "/Japan/theme/wallpaper.png")
end)

t.test("a pack wallpaper name resolves to its view's variant, whatever its pack switch says", function()
    local TP, d, _s, packs_off = setup()
    for _, f in ipairs({ "wallpaper.png", "wallpaper.full.png", "wallpaper.dark.png" }) do
        touch(d .. "/Xmas/theme/" .. f)
    end
    local base = TP.wallpaperEntries()[1].name
    eq(TP.variantName(base, false, false), base)
    eq(TP.variantName(base, true, false), TP.NAME_PREFIX .. "Xmas\1wallpaper.full.png")
    local dark = TP.variantName(base, false, true)
    eq(dark, TP.NAME_PREFIX .. "Xmas\1wallpaper.dark.png"); eq(TP.isDarkName(dark), true)
    eq(TP.wallpaperPath("Xmas\1wallpaper.png"), d .. "/Xmas/theme/wallpaper.png")
    eq(TP.wallpaperPath("Xmas\1../../etc/passwd"), nil, "no path escapes")
    eq(TP.wallpaperPath("..\1wallpaper.png"), nil)
    eq(TP.wallpaperPath("Xmas\1missing.png"), nil)
    packs_off["Xmas"] = true
    eq(TP.variantName(base, false, false), base, "a pack switch hid the reader's own wallpaper")
    eq(TP.variantName("my.png", false, false), "my.png", "a reader's own name passes through")
end)

t.test("shownWallpaper: full screen None stays None; unset follows the wallpaper's own view", function()
    local TP, d, settings = setup()
    touch(d .. "/Japan/theme/wallpaper.png"); touch(d .. "/Japan/theme/wallpaper.full.png")
    TP.invalidate()
    local jp = TP.wallpaperEntries()[1].name
    settings.wallpaper_default = jp
    eq(TP.shownWallpaper(true, false), TP.NAME_PREFIX .. "Japan\1wallpaper.full.png")
    settings.wallpaper_full = false
    eq(TP.shownWallpaper(true, false), nil)
    settings.wallpaper_full = "sky.png"
    eq(TP.shownWallpaper(true, false), "sky.png")
    eq(TP.shownWallpaper(false, false), jp)
end)

t.test("the shelf maps a pack wallpaper to its variant", function()
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    local b = w:match("function BookshelfWidget:_wallpaperName%(%)(.-)\nend\n")
    assert(b and b:find("TP.shownWallpaper(full,", 1, true), "the shelf does not ask shownWallpaper")
    assert(w:find("TP.isDarkName(", 1, true), "_wallpaperWidget does not skip the invert for a dark variant")
    assert(w:find('bookshelf_theme_pack").migrate()', 1, true), "the shelf does not migrate")
    local wp = io.open("lib/bookshelf_wallpaper.lua"):read("*a")
    assert(wp:find("wallpaperPath(", 1, true), "pathFor does not resolve theme names")
end)

-- ── Theme packs: the manifest ─────────────────────────────────────────────
t.test("theme.json is read: name, description, shelf and plank", function()
    local TP, d = setup()
    mkmanifest(d, "Halloween", '{"name":"Halloween night","description":"Bats.","shelf":"dark","plank":"Ash"}')
    TP.invalidate()
    local m = TP.theme("Halloween").manifest
    eq(m.name, "Halloween night"); eq(m.description, "Bats."); eq(m.shelf, "dark"); eq(m.plank, "Ash")
end)

t.test("a shelf that is not light or dark is ignored", function()
    local TP, d = setup()
    mkmanifest(d, "A", '{"shelf":"auto"}')
    TP.invalidate()
    eq(TP.theme("A").manifest.shelf, nil)
end)

t.test("non-string fields are ignored", function()
    local TP, d = setup()
    mkmanifest(d, "A", '{"name":3,"shelf":true,"plank":{}}')
    TP.invalidate()
    local m = TP.theme("A").manifest
    eq(m.name, nil); eq(m.shelf, nil); eq(m.plank, nil)
end)

t.test("an unreadable theme.json still makes a theme, by its folder name", function()
    local TP, d = setup()
    mkmanifest(d, "Broken", '{"name": ')
    TP.invalidate()
    local m = TP.theme("Broken").manifest
    assert(m, "a typo hid the pack")
    eq(m.name, nil)
    local list = TP.allThemes()
    eq(#list, 1); eq(list[1].pack, "Broken"); eq(list[1].name, "Broken")
end)

t.test("a theme/ without theme.json and no ornaments is not a theme", function()
    local TP, d = setup()
    mkplank(d, "Planks", "Walnut"); touch(d .. "/Planks/theme/wallpaper.png")
    TP.invalidate()
    eq(TP.theme("Planks").manifest, nil)
    eq(#TP.allThemes(), 0)
end)

t.test("allThemes lists theme packs by name, switched-off ones too", function()
    local TP, d, _s, packs_off = setup()
    mkmanifest(d, "zz", '{"name":"Autumn"}'); mkmanifest(d, "Ukiyo-e")
    packs_off["Ukiyo-e"] = true
    TP.invalidate()
    local list = TP.allThemes()
    eq(#list, 2)
    eq(list[1].pack, "zz"); eq(list[1].name, "Autumn")
    eq(list[2].pack, "Ukiyo-e"); eq(list[2].name, "Ukiyo-e")
end)

t.test("rescan drops the theme folders' cache, not the ornaments list's", function()
    local TP = setup()
    local n = 0
    TP._orn.invalidate = function() n = n + 1 end
    TP._cache["X"] = { at = 0, v = {} }
    TP.rescan()
    eq(n, 0, "the ornaments list was rescanned in full")
    eq(next(TP._cache), nil, "the theme folders were not rescanned")
end)

t.test("the theme's plank: the manifest's by name, else the first by name", function()
    local TP, d = setup()
    TP._plugin_root = "."
    mkmanifest(d, "W", '{"plank":"walnut"}'); mkplank(d, "W", "Ash"); mkplank(d, "W", "Walnut")
    mkmanifest(d, "F"); mkplank(d, "F", "Walnut"); mkplank(d, "F", "Ash")
    TP.invalidate()
    eq(TP.themePlank("W").name, "Walnut")
    eq(TP.themePlank("F").name, "Ash")
    eq(TP.themePlank("Nope"), nil)
end)

-- ── Choosing a theme writes one key ───────────────────────────────────────
local function halloween(d, manifest)
    mkmanifest(d, "Halloween", manifest or '{"shelf":"dark"}')
    mkwall(d, "Halloween"); mkcolours(d, "Halloween"); mkplank(d, "Halloween", "Ash")
    touch(d .. "/Autumn/owl.png")
end

t.test("choosing a theme writes library_theme and nothing else; the reader's own comes back exactly", function()
    local TP, d, settings, packs_off = setup()
    TP._plugin_root = "."
    halloween(d); TP.invalidate()
    settings.wallpaper_default = "leaves.png"; settings.shelf_theme = "light"
    packs_off["Halloween"] = true
    local before = {}
    for k, v in pairs(settings) do before[k] = v end
    TP.setLibraryTheme("Halloween")
    eq(settings.library_theme, "Halloween")
    for k, v in pairs(settings) do
        if k ~= "library_theme" then eq(v, before[k], "choosing a theme wrote " .. k) end
    end
    eq(packs_off["Halloween"], true, "choosing a theme flipped a pack switch")
    eq(packs_off["Autumn"], nil, "choosing a theme flipped a pack switch")
    eq(TP.shownWallpaper(false, false), "theme-pack\1Halloween\1wallpaper.png")
    eq(TP.shelfLook(), "dark")
    TP.setLibraryTheme("mine")
    eq(settings.library_theme, nil)
    eq(TP.shownWallpaper(false, false), "leaves.png"); eq(TP.shelfLook(), "light")
end)

t.test("migrate: the 5.3 betas' borrowed wallpaper becomes the reader's choice", function()
    local TP, d, settings = setup()
    touch(d .. "/Japan/theme/wallpaper.png")
    settings.wallpaper_default = "leaves.png"
    settings.theme_wallpaper_pack = "Japan"
    TP.migrate()
    eq(settings.wallpaper_default, "theme-pack\1Japan\1wallpaper.png")
    eq(settings.theme_wallpaper_pack, nil)
end)

t.done()
