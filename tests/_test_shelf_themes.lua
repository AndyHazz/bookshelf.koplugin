-- tests/_test_theme_packs.lua
-- Theme packs: the theme/ subfolder of an ornament pack (wallpaper variants,
-- plank design, colours.json) and the "which pack is borrowed" state.
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
        elseif attr == "modification" then return tonumber(sh("stat -c %Y " .. q)) end
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
    local tabs, bumps = {}, { n = 0 }
    TP._tab = function(id) return tabs[id] end
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

t.test("an untouched shelf resolves as the library", function()
    local TP, d, settings, _po, _o, tabs = setup()
    halloween(d); TP.invalidate()
    tabs.home = { id = "home" }
    TP.setShelf("home")
    eq(TP.shelfPack(), nil); eq(TP.shelfKey(), "lib")
    eq(TP.colourOverride("ink_color", false), nil, "a shelf with no theme borrowed colours")
end)

t.test("unknown chip resolves as the library", function()
    local TP = setup()
    TP.setShelf("kobo")
    eq(TP.shelfPack(), nil); eq(TP.shelfKey(), "lib")
    TP.setShelf(nil)
    eq(TP.shelfKey(), "lib")
end)

t.test("a shelf pack lends its wallpaper, colours, plank and light/dark", function()
    local TP, d, _s, _po, _o, tabs = setup()
    TP._plugin_root = "."
    halloween(d); TP.invalidate()
    tabs.manga = { id = "manga", theme = "Halloween" }
    TP.setShelf("manga")
    eq(TP.shelfKey(), "pack:Halloween")
    eq(TP.shownWallpaper(false, false), "theme-pack\1Halloween\1wallpaper.png")
    assert(TP.colourOverride("ink_color", false), "no colour from the shelf pack")
    eq(TP.activePlank().id, "Halloween/theme/plank.Ash")
    eq(TP.shelfLook(), "dark")
end)

t.test("night on a shelf pack: dark variant and pre-inverted night colours", function()
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

t.test("parts a shelf pack lacks fall through to the library's look", function()
    local TP, d, settings, _po, _o, tabs = setup()
    TP._plugin_root = "."
    halloween(d); touch(d .. "/Gallery/frame.png"); TP.invalidate()
    eq(TP.chooseTheme("Halloween"), true)
    tabs.art = { id = "art", theme = "Gallery" }
    TP.setShelf("art")
    eq(TP.shelfKey(), "pack:Gallery")
    eq(TP.shownWallpaper(false, false), "theme-pack\1Halloween\1wallpaper.png")
    assert(TP.colourOverride("ink_color", false), "the library's colours did not fall through")
    eq(TP.activePlank().id, "Halloween/theme/plank.Ash")
    eq(TP.shelfLook(), "dark")
end)

t.test("none skips library-held groups: the reader's pre-theme plank and look", function()
    local TP, d, settings, _po, _o, tabs = setup()
    TP._plugin_root = "."
    settings.shelf_theme = "light"
    settings.theme_plank_pack = false
    halloween(d); TP.invalidate()
    eq(TP.chooseTheme("Halloween"), true)
    tabs.mine = { id = "mine", theme = "none" }
    TP.setShelf("mine")
    eq(TP.shelfKey(), "none")
    eq(TP.shelfLook(), "light", "No theme pack showed the library theme's light/dark")
    eq(TP.activePlank(), nil, "No theme pack showed the library theme's plank")
    eq(TP.colourOverride("ink_color", false), nil, "No theme pack borrowed the library's colours")
    eq(TP.shownWallpaper(false, false), nil, "No theme pack showed the library theme's wallpaper")
end)

t.test("theme_look precedence: the shelf's own, then its pack's, then the library's", function()
    local TP, d, settings, _po, _o, tabs = setup()
    halloween(d); mkmanifest(d, "Ukiyo-e"); TP.invalidate()
    settings.shelf_theme = "light"
    tabs.a = { id = "a", theme = "Halloween" }
    tabs.b = { id = "b", theme = "Halloween", theme_look = "light" }
    tabs.c = { id = "c", theme = "Ukiyo-e" }
    TP.setShelf("a"); eq(TP.shelfLook(), "dark")
    TP.setShelf("b"); eq(TP.shelfLook(), "light", "the shelf's own choice lost to its pack")
    TP.setShelf("c"); eq(TP.shelfLook(), "light")
    settings.shelf_theme = "dark"
    eq(TP.shelfLook(), "dark", "a shelf without a choice did not follow the library")
    tabs.c.theme_look = "auto"
    eq(TP.shelfKey(), "pack:Ukiyo-e|auto")
end)

t.test("missing pack resolves as library and keeps the name", function()
    local TP, d, _s, _po, _o, tabs = setup()
    tabs.manga = { id = "manga", theme = "Gone" }
    TP.setShelf("manga")
    eq(TP.shelfChoiceFor("manga"), "Gone")
    eq(TP.shelfPackFor("manga"), nil)
    eq(TP.shelfKey(), "lib")
end)

t.test("setShelf bumps the generation only when the look changes", function()
    local TP, d, _s, _po, _o, tabs, bumps = setup()
    halloween(d); TP.invalidate()
    tabs.a = { id = "a" }; tabs.b = { id = "b" }
    tabs.c = { id = "c", theme = "Halloween" }
    local n0 = bumps.n
    TP.setShelf("a"); TP.setShelf("b")
    eq(bumps.n, n0, "two library shelves bumped")
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
    TP.setShelf("a"); local lib = TP.activePlank()
    TP.setShelf("c"); eq(TP.activePlank().id, "Halloween/theme/plank.Ash", "the library's plank was served from the memo")
    TP.setShelf("a"); eq(TP.activePlank() and TP.activePlank().id, lib and lib.id)
end)

t.test("an ornament-only pack is a theme named by its folder", function()
    local TP, d = setup()
    halloween(d); touch(d .. "/Gallery/frame.png"); TP.invalidate()
    local all = TP.allThemes()
    eq(#all, 2)
    eq(all[1].pack, "Halloween"); eq(all[1].ornaments_only, false)
    eq(all[2].pack, "Gallery"); eq(all[2].name, "Gallery"); eq(all[2].ornaments_only, true)
    eq(TP.displayName("Gallery"), "Gallery")
end)

t.test("choosing an ornament-only pack as the library theme: its pack on, others off, nothing else", function()
    local TP, d, settings, packs_off = setup()
    halloween(d); touch(d .. "/Gallery/frame.png"); TP.invalidate()
    packs_off["Gallery"] = true
    eq(TP.chooseTheme("Gallery"), true)
    eq(packs_off["Gallery"], nil); eq(packs_off["Halloween"], true)
    eq(settings.wallpaper_default, nil, "an ornament pack set a wallpaper")
    eq(TP.currentTheme(), "Gallery")
    TP.clearTheme()
    eq(packs_off["Gallery"], true, "No theme pack did not give the packs back")
end)

t.done()
