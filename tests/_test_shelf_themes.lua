-- tests/_test_shelf_themes.lua
-- Themes per shelf: library_theme and tab.theme resolved at paint, part by
-- part, over the reader's own look (5.4).
-- Run from the plugin root: lua tests/_test_shelf_themes.lua
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
            -- The pieces: png/svg one level inside a pack, as the real scan.
            local entries = {}
            for _i, p in ipairs(packs) do
                for f in sh("ls '" .. d .. "/" .. p .. "'"):gmatch("[^\n]+") do
                    if f:lower():match("%.png$") or f:lower():match("%.svg$") then
                        entries[#entries + 1] = { name = p .. "/" .. f, pack = p }
                    end
                end
            end
            return entries, packs
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
    local tabs, bumps = {}, { n = 0, gen = 0, lookups = 0 }
    TP._tab = function(id) bumps.lookups = bumps.lookups + 1; return tabs[id] end
    TP._store.generation = function() return bumps.gen end
    -- Like the real store: every save is a new generation.
    TP._store.save = function(k, v) settings[k] = v; bumps.gen = bumps.gen + 1 end
    TP._store.bump = function() bumps.n = bumps.n + 1 end
    return TP, d, settings, packs_off, off, tabs, bumps
end

local function mkwall(d, p) touch(d .. "/" .. p .. "/theme/wallpaper.png") end
local function mkplank(d, p, n) touch(d .. "/" .. p .. "/theme/plank." .. n .. ".middle.png") end
local function mkcolours(d, p) touch(d .. "/" .. p .. "/theme/colours.json", '{"day":{"text":"#112233"},"night":{}}') end
local function mkmanifest(d, p, body) touch(d .. "/" .. p .. "/theme/theme.json", body or "{}") end

local function halloween(d)
    mkmanifest(d, "Halloween", '{"shelf":"dark"}')
    mkwall(d, "Halloween"); mkcolours(d, "Halloween"); mkplank(d, "Halloween", "Ash")
end

local function lib(TP, v) TP.setLibraryTheme(v) end

t.test("an untouched shelf under no library theme is the reader's own", function()
    local TP, d, settings, _po, _o, tabs = setup()
    halloween(d); TP.invalidate()
    tabs.home = { id = "home" }
    TP.setShelf("home")
    eq(TP.shelfTheme(), "mine"); eq(TP.shelfKey(), "t:mine")
    eq(TP.colourOverride("ink_color", false), nil, "a shelf with no theme borrowed colours")
end)

t.test("an unknown chip, or none, resolves as the library", function()
    local TP, d = setup()
    halloween(d); TP.invalidate()
    lib(TP, "Halloween")
    TP.setShelf("kobo"); eq(TP.shelfTheme(), "Halloween")
    TP.setShelf(nil); eq(TP.shelfTheme(), "Halloween")
end)

t.test("a theme shows its wallpaper, colours, plank and light/dark", function()
    local TP, d, _s, _po, _o, tabs = setup()
    TP._plugin_root = "."
    halloween(d); TP.invalidate()
    tabs.manga = { id = "manga", theme = "Halloween" }
    TP.setShelf("manga")
    eq(TP.shelfKey(), "t:Halloween")
    eq(TP.shownWallpaper(false, false), "theme-pack\1Halloween\1wallpaper.png")
    assert(TP.colourOverride("ink_color", false), "no colour from the shelf's theme")
    eq(TP.activePlank().id, "Halloween/theme/plank.Ash")
    eq(TP.shelfLook(), "dark")
end)

t.test("night on a theme: dark variant and pre-inverted night colours", function()
    local TP, d, _s, _po, _o, tabs = setup()
    mkmanifest(d, "Halloween", '{"shelf":"dark"}'); mkwall(d, "Halloween")
    touch(d .. "/Halloween/theme/colours.json", '{"day":{"text":"#112233"},"night":{"text":"#445566"}}')
    touch(d .. "/Halloween/theme/wallpaper.dark.png"); TP.invalidate()
    tabs.manga = { id = "manga", theme = "Halloween" }
    TP.setShelf("manga")
    eq(TP.shownWallpaper(false, true), "theme-pack\1Halloween\1wallpaper.dark.png")
    local night = TP.colourOverride("ink_color", true)
    eq(night and night.hex, TP.invertHex("#445566"))
end)

t.test("parts a theme lacks are the reader's own, never another theme's", function()
    local TP, d, settings, _po, _o, tabs = setup()
    TP._plugin_root = "."
    halloween(d); touch(d .. "/Gallery/frame.png"); TP.invalidate()
    settings.wallpaper_default = "green.jpg"
    settings.theme_plank_pack = false
    settings.shelf_theme = "light"
    lib(TP, "Halloween")                                -- the library wears Halloween
    tabs.art = { id = "art", theme = "Gallery" }        -- ornaments only
    TP.setShelf("art")
    eq(TP.shelfKey(), "t:Gallery")
    eq(TP.shownWallpaper(false, false), "green.jpg", "the library theme's wallpaper leaked onto another theme")
    eq(TP.colourOverride("ink_color", false), nil, "the library theme's colours leaked")
    eq(TP.activePlank(), nil, "the library theme's plank leaked")
    eq(TP.shelfLook(), "light")
end)

t.test("the reader's own on one shelf under a library theme: exactly their own look", function()
    local TP, d, settings, _po, _o, tabs = setup()
    TP._plugin_root = "."
    settings.shelf_theme = "light"
    settings.theme_plank_pack = false
    settings.wallpaper_default = "green.jpg"
    halloween(d); TP.invalidate()
    lib(TP, "Halloween")
    tabs.mine = { id = "mine", theme = "mine" }
    TP.setShelf("mine")
    eq(TP.shelfKey(), "t:mine")
    eq(TP.shelfLook(), "light"); eq(TP.activePlank(), nil)
    eq(TP.colourOverride("ink_color", false), nil)
    eq(TP.shownWallpaper(false, false), "green.jpg")
    -- And choosing the library theme wrote nothing of theirs.
    eq(settings.wallpaper_default, "green.jpg"); eq(settings.shelf_theme, "light")
    eq(settings.theme_plank_pack, false)
end)

t.test("rc/5.4's 'none' is read as the reader's own", function()
    local TP, d, _s, _po, _o, tabs = setup()
    halloween(d); TP.invalidate()
    lib(TP, "Halloween")
    tabs.x = { id = "x", theme = "none" }
    eq(TP.themeFor("x"), "mine")
end)

t.test("Plain: no wallpaper, the oak plank, default colours, no ornaments, the reader's light or dark", function()
    local TP, d, settings, _po, _o, tabs = setup()
    TP._plugin_root = "."
    settings.wallpaper_default = "green.jpg"
    settings.theme_plank_pack = false
    settings.shelf_theme = "dark"
    halloween(d); TP.invalidate()
    lib(TP, "Halloween")
    tabs.p = { id = "p", theme = "plain" }
    TP.setShelf("p")
    eq(TP.shownWallpaper(false, false), nil); eq(TP.shownWallpaper(true, false), nil)
    local pl = TP.activePlank()
    eq(pl and pl.id, "builtin:oak")
    eq(TP.defaultColours(), true, "Plain did not ask for the default colours")
    eq(TP.colourOverride("ink_color", false), nil)
    eq(TP.ornamentsFor("p"), "plain")
    eq(TP.shelfLook(), "dark", "Plain does not follow the reader's light or dark")
    eq(TP.themeName("plain"), "Plain")
end)

t.test("ornaments: a theme deals its own; Plain none; a theme without pieces, the reader's", function()
    local TP, d, _s, _po, _o, tabs = setup()
    halloween(d); touch(d .. "/Gallery/frame.png"); TP.invalidate()
    tabs.h = { id = "h", theme = "Halloween" }        -- no pieces in this fixture
    tabs.g = { id = "g", theme = "Gallery" }
    tabs.m = { id = "m" }
    eq(TP.ornamentsFor("g"), "Gallery")
    eq(TP.ornamentsFor("h"), "mine", "a theme with no pieces should deal the reader's own")
    eq(TP.ornamentsFor("m"), "mine")
    lib(TP, "Gallery")
    eq(TP.ornamentsFor("m"), "Gallery", "a shelf following the library deals the library theme's")
end)

t.test("a sub-shelf wears its shelf of shelves' theme", function()
    local TP, d, _s, _po, _o, tabs = setup()
    halloween(d); TP.invalidate()
    tabs.top = { id = "top", theme = "plain" }
    tabs.sub = { id = "sub", parent = "top" }
    eq(TP.themeFor("sub"), "plain")
end)

t.test("a missing pack resolves as the library and keeps the name", function()
    local TP, d, _s, _po, _o, tabs = setup()
    halloween(d); TP.invalidate()
    lib(TP, "Halloween")
    tabs.manga = { id = "manga", theme = "Gone" }
    eq(TP.shelfChoiceFor("manga"), "Gone")
    eq(TP.themeFor("manga"), "Halloween")
    eq(TP.themeName("Gone"), "Gone (missing)")
    lib(TP, "AlsoGone")
    eq(TP.libraryChoice(), "AlsoGone"); eq(TP.libraryTheme(), "mine")
end)

t.test("setShelf bumps the generation only when the look changes", function()
    local TP, d, _s, _po, _o, tabs, bumps = setup()
    halloween(d); TP.invalidate()
    tabs.a = { id = "a" }; tabs.b = { id = "b" }
    tabs.c = { id = "c", theme = "Halloween" }
    local n0 = bumps.n
    TP.setShelf("a"); TP.setShelf("b")
    eq(bumps.n, n0, "two shelves of the reader's own bumped")
    eq(TP.setShelf("c"), true); eq(TP.setShelf("c"), false)
    eq(TP.setShelf("a"), true)
    eq(bumps.n, n0 + 2)
end)

t.test("the plank memo follows the shelf", function()
    local TP, d, _s, _po, _o, tabs = setup()
    TP._plugin_root = "."
    TP.SCAN_TTL = 60
    halloween(d); TP.invalidate()
    tabs.a = { id = "a" }; tabs.c = { id = "c", theme = "Halloween" }
    TP.setShelf("a"); local mine = TP.activePlank()
    TP.setShelf("c"); eq(TP.activePlank().id, "Halloween/theme/plank.Ash", "the reader's plank was served from the memo")
    TP.setShelf("a"); eq(TP.activePlank() and TP.activePlank().id, mine and mine.id)
end)

t.test("ornaments only: said only when a pack truly has nothing else", function()
    local TP, d = setup()
    halloween(d); touch(d .. "/Gallery/frame.png")
    touch(d .. "/Snow/flake.png"); mkwall(d, "Snow")           -- no theme.json, but a wallpaper
    TP.invalidate()
    local all = TP.allThemes()
    eq(#all, 3)
    eq(all[1].pack, "Halloween"); eq(all[1].ornaments_only, false)
    eq(all[2].pack, "Gallery"); eq(all[2].ornaments_only, true)
    eq(all[3].pack, "Snow"); eq(all[3].ornaments_only, false, "Snow brings a wallpaper")
    local labels = {}
    for i, c in ipairs(TP.choices()) do labels[i] = c.label end
    eq(table.concat(labels, ","), "My theme,Plain,Halloween,Gallery (ornaments only),Snow")
end)

t.test("lookOf answers for any shelf, not just the one on screen", function()
    local TP, d, settings, _po, _o, tabs = setup()
    halloween(d); mkmanifest(d, "Ukiyo-e"); TP.invalidate()
    settings.shelf_theme = "light"
    tabs.home = { id = "home" }
    tabs.latest = { id = "latest", theme = "Halloween" }
    tabs.uk = { id = "uk", theme = "Ukiyo-e" }                 -- says nothing: the reader's
    TP.setShelf("home")
    eq(TP.lookOf("latest"), "dark", "a theme's light/dark was not seen from another shelf")
    eq(TP.lookOf("uk"), "light")
    eq(TP.lookOf("home"), "light")
end)

t.test("a pack with only planks is not a theme; with a theme.json it is", function()
    local TP, d = setup()
    halloween(d); touch(d .. "/Gallery/frame.png")
    mkplank(d, "Planks", "Walnut")                      -- planks only, no theme.json
    mkplank(d, "Woods", "Oak"); mkmanifest(d, "Woods")  -- planks only, but a theme
    TP.invalidate()
    local names = {}
    for i, th in ipairs(TP.allThemes()) do names[i] = th.pack end
    eq(table.concat(names, ","), "Halloween,Woods,Gallery")
end)

t.test("the reader's own pack wallpaper shows whatever the pack switch says", function()
    local TP, d, settings, packs_off, _o, tabs = setup()
    mkmanifest(d, "Ukiyo-e"); mkwall(d, "Ukiyo-e"); TP.invalidate()
    settings.wallpaper_default = "theme-pack\1Ukiyo-e\1wallpaper.png"   -- picked in the wallpaper picker
    packs_off["Ukiyo-e"] = true
    tabs.mine = { id = "mine" }
    TP.setShelf("mine")
    eq(TP.shownWallpaper(false, false), "theme-pack\1Ukiyo-e\1wallpaper.png",
       "a pack switched off in the collection hid the reader's own wallpaper choice")
end)

t.test("the shelf on screen is resolved once per settings generation", function()
    local TP, d, settings, _po, _o, tabs, bumps = setup()
    halloween(d); TP.invalidate()
    tabs.c = { id = "c", theme = "Halloween" }
    TP.setShelf("c")
    TP.shelfLook(); TP.shelfTheme()
    local n = bumps.lookups
    for _k = 1, 20 do TP.shelfLook(); TP.shelfTheme() end
    eq(bumps.lookups, n, "every read looked the tab up again")
    bumps.gen = bumps.gen + 1
    tabs.c.theme = "plain"
    eq(TP.shelfTheme(), "plain", "a new generation did not re-resolve")
end)

t.test("a shelf that looks the same as the last one asks for no repaint", function()
    local TP, d, settings, _po, _o, tabs, bumps = setup()
    TP._plugin_root = "."
    halloween(d); touch(d .. "/Gallery/frame.png"); TP.invalidate()
    lib(TP, "Halloween")
    tabs.home = { id = "home" }
    tabs.same = { id = "same", theme = "Halloween" }          -- the library's own theme
    tabs.art = { id = "art", theme = "Gallery" }              -- ornaments only
    tabs.mine = { id = "mine", theme = "mine" }
    TP.setShelf("art")
    local n = bumps.n
    eq(TP.setShelf("mine"), false, "an ornaments-only theme counted as a new look")
    eq(TP.setShelf("home"), true)
    eq(TP.setShelf("same"), false, "the library's own theme counted as a new look")
    eq(bumps.n, n + 1)
end)

t.test("anyShelfTheme: an enabled shelf with a theme of its own", function()
    local TP = setup()
    TP._tabs_list = function() return { { id = "a" }, { id = "b", enabled = false, theme = "X" } } end
    eq(TP.anyShelfTheme(), false, "a disabled shelf counted")
    TP._tabs_list = function() return { { id = "a" }, { id = "c", theme = "mine" } } end
    eq(TP.anyShelfTheme(), true)
end)

t.test("Auto and Light that look the same do not count as a new look", function()
    local TP, d, settings, _po, _o, tabs = setup()
    mkmanifest(d, "Day", '{"shelf":"light"}'); TP.invalidate()
    tabs.home = { id = "home" }                               -- the reader's Auto
    tabs.day = { id = "day", theme = "Day" }                  -- Light, nothing else
    local night = false
    TP._autoDark = function() return night end
    TP.setShelf("home")
    eq(TP.setShelf("day"), false, "Auto in daylight flashed against Light")
    night = true
    eq(TP.setShelf("home"), true, "Auto at night is dark, a different look from Light")
end)

t.test("brings: what each theme replaces of the reader's own", function()
    local TP, d = setup()
    halloween(d); touch(d .. "/Gallery/frame.png"); TP.invalidate()
    eq(TP.brings("Halloween", "wallpaper"), true); eq(TP.brings("Halloween", "look"), true)
    eq(TP.brings("Halloween", "ornaments"), false)
    eq(TP.brings("Gallery", "ornaments"), true); eq(TP.brings("Gallery", "wallpaper"), false)
    eq(TP.brings("plain", "plank"), true); eq(TP.brings("plain", "look"), false)
    eq(TP.brings("mine", "wallpaper"), false)
end)

t.test("the shelf editor's live preview (a tab override) is seen without a settings save", function()
    local TP, d, _s, _po, _o, tabs = setup()
    halloween(d); TP.invalidate()
    tabs.c = { id = "c" }
    local TM = { overrideGen = 0 }
    package.loaded["lib/bookshelf_tab_model"] = TM
    TP.setShelf("c")
    eq(TP.shelfTheme(), "mine")
    tabs.c = { id = "c", theme = "plain" }        -- the override, same settings generation
    TM.overrideGen = TM.overrideGen + 1
    eq(TP.shelfTheme(), "plain", "the preview was served the memo from before it")
    package.loaded["lib/bookshelf_tab_model"] = nil
end)

t.test("a pack folder named like a built-in, in any case, is never a theme", function()
    local TP, d, settings, _po, _o, tabs = setup()
    TP._plugin_root = "."
    halloween(d)
    for _i, p in ipairs({ "Plain", "mine", "NONE" }) do
        mkmanifest(d, p); mkwall(d, p); touch(d .. "/" .. p .. "/piece.png")
    end
    TP.invalidate()
    local names = {}
    for i, th in ipairs(TP.allThemes()) do names[i] = th.pack end
    eq(table.concat(names, ","), "Halloween", "a reserved folder was listed as a theme")
    for _i, c in ipairs(TP.choices()) do
        assert(c.value == "mine" or c.value == "plain" or c.value == "Halloween", "listed: " .. c.value)
    end
    TP.setLibraryTheme("Halloween")
    tabs.a = { id = "a", theme = "Plain" }        -- stored before: never the pack
    tabs.b = { id = "b", theme = "NONE" }
    tabs.c = { id = "c", theme = "plain" }        -- the built-in
    tabs.e = { id = "e", theme = "mine" }
    eq(TP.themeFor("a"), "Halloween", "a reserved pack name was worn as a theme")
    eq(TP.themeFor("b"), "Halloween")
    eq(TP.themeFor("c"), "plain")
    TP.setShelf("c")
    eq(TP.shownWallpaper(false, false), nil, "the built-in Plain showed the 'Plain' folder's wallpaper")
    eq(TP.ornamentsFor("c"), "plain")
    eq(TP.themeFor("e"), "mine")
    settings.library_theme = "Mine"
    eq(TP.libraryChoice(), "mine"); eq(TP.libraryTheme(), "mine")
    eq(TP.themeName("Plain"), "My theme", "a stored reserved name is named as unset")
end)

t.test("one shelf theme list for every menu: Same as library, a missing pack, mine, Plain, each theme", function()
    local TP, d, _s, _po, _o, tabs = setup()
    halloween(d); TP.invalidate()
    local function labels(l)
        local o = {}
        for i, c in ipairs(l) do o[i] = c.label .. (c.same and "*" or "") .. (c.missing and "!" or "") end
        return table.concat(o, ",")
    end
    eq(labels(TP.shelfChoices(nil)), "Same as library*,My theme,Plain,Halloween")
    eq(labels(TP.shelfChoices("Gone")), "Same as library*,Gone (missing)!,My theme,Plain,Halloween")
    eq(TP.shelfChoices(nil)[1].value, nil, "Same as library stores nothing")
    tabs.a = { id = "a", theme = "none" }; tabs.b = { id = "b" }; tabs.s = { id = "s", parent = "a" }
    eq(TP.ownChoice("a"), "mine"); eq(TP.ownChoice("b"), nil)
    eq(TP.ownChoice("s"), nil, "ownChoice is the shelf's own, not inherited")
    eq(TP.shelfChoiceLabel(nil), "Same as library (My theme)")
    TP.setLibraryTheme("Halloween")
    eq(TP.shelfChoiceLabel(nil), "Same as library (Halloween)")
    eq(TP.shelfChoiceLabel("plain"), "Plain"); eq(TP.shelfChoiceLabel("none"), "My theme")
end)

t.done()
