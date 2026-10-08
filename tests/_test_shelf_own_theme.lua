-- tests/_test_shelf_own_theme.lua
-- A shelf's own theme (5.4, maintainer 2026-10-08): tab.theme = "own" and
-- tab.own_theme, a complete theme like My theme owned by one shelf. It
-- starts as a copy of what the shelf shows, part by part as it resolves; it
-- is kept when the shelf switches away; every editor writes through one seam
-- (partRead / partSave, choosePlank, switches) that picks My theme's keys or
-- the shelf on screen's own theme.
-- Run from the plugin root: lua tests/_test_shelf_own_theme.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["logger"] = { dbg = function() end, info = function() end,
                             warn = function() end, err = function() end }
package.loaded["ui/widget/widget"] = { extend = function(_, t) return t end }
package.loaded["ui/geometry"] = { new = function(_, t) return t end }

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
        end
        return nil
    end,
    dir = function(path)
        local list = {}
        for name in sh("ls -a '" .. path .. "'"):gmatch("[^\n]+") do list[#list + 1] = name end
        local i = 0
        return function() i = i + 1; return list[i] end
    end,
}

local H  = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

local function tiny_json(s)
    local f, err = (loadstring or load)("return " .. s:gsub('"([^"]-)"%s*:', '["%1"]='))
    if not f then error(err) end
    return f()
end

local tmp = os.getenv("TMPDIR") or "/tmp"
local function scratch()
    local d = string.format("%s/bookshelf_own_theme_%d_%d", tmp, os.time(), math.random(1e6))
    os.execute("rm -rf '" .. d .. "' && mkdir -p '" .. d .. "'")
    return d
end
local function touch(p, body)
    os.execute("mkdir -p \"$(dirname '" .. p .. "')\"")
    local f = io.open(p, "wb"); f:write(body or "x"); f:close()
end

-- setup(): TP over a scratch ornaments folder, a settings table and a
-- tab list (the tab model's load/save seam writes into the same records).
local function setup()
    local d = scratch()
    local settings = {}
    local off, packs_off = {}, {}
    local orn = { dir = function() return d end }
    function orn.listAll()
        local packs = {}
        for name in sh("ls '" .. d .. "'"):gmatch("[^\n]+") do
            if lfs_shim.attributes(d .. "/" .. name, "mode") == "directory" then packs[#packs + 1] = name end
        end
        table.sort(packs)
        local entries = {}
        for name in sh("ls '" .. d .. "'"):gmatch("[^\n]+") do
            if name:match("%.svg$") then entries[#entries + 1] = { name = name } end
        end
        for _i, p in ipairs(packs) do
            for f in sh("ls '" .. d .. "/" .. p .. "'"):gmatch("[^\n]+") do
                if f:match("%.png$") or f:match("%.svg$") then
                    entries[#entries + 1] = { name = p .. "/" .. f, pack = p }
                end
            end
        end
        return entries, packs
    end
    function orn.isPackOff(p) return packs_off[p] == true end
    function orn.isOff(r) return off[r] == true end
    function orn.setPackOff(p, v) packs_off[p] = v and true or nil end
    function orn.setOff(r, v) off[r] = v and true or nil end
    function orn.list()
        local out = {}
        for _i, e in ipairs((orn.listAll())) do
            if not off[e.name] and not (e.pack and packs_off[e.pack]) then out[#out + 1] = e end
        end
        return out
    end
    function orn.listFor(sp)
        if sp == "mine" then return orn.list() end
        local out = {}
        for _i, e in ipairs((orn.listAll())) do
            if e.pack == sp and not off[e.name] then out[#out + 1] = e end
        end
        return out
    end
    package.loaded["lib/bookshelf_theme_pack"] = nil
    local TP = dofile("lib/bookshelf_theme_pack.lua")
    TP._lfs, TP._orn, TP._decode = lfs_shim, orn, tiny_json
    TP._plugin_root = "."
    TP.SCAN_TTL = 0
    local st = { gen = 0, tab_saves = 0, saves = 0 }
    TP._store = { read = function(k) return settings[k] end,
                  save = function(k, v) settings[k] = v; st.saves = st.saves + 1; st.gen = st.gen + 1 end,
                  flush = function() end,
                  generation = function() return st.gen end,
                  bump = function() st.gen = st.gen + 1 end }
    local list = {}
    local tabs = setmetatable({}, { __newindex = function(m, k, v) rawset(m, k, v); list[#list + 1] = v end })
    TP._tab = function(id) return rawget(tabs, id) end
    TP._tabmodel = { load = function() return list end,
                     save = function() st.tab_saves = st.tab_saves + 1; st.gen = st.gen + 1 end }
    return TP, d, settings, tabs, st, off, packs_off
end

-- Macabre: dark, a wallpaper, a text colour, a plank, two pieces. The
-- reader's own: a progress bar colour (both slots), a loose piece, Ukiyo-e
-- with one piece.
local function world(d, settings)
    touch(d .. "/Macabre/theme/theme.json", '{"shelf":"dark"}')
    touch(d .. "/Macabre/theme/wallpaper.png")
    touch(d .. "/Macabre/theme/colours.json", '{"day":{"text":"#112233"},"night":{"text":"#112233"}}')
    touch(d .. "/Macabre/theme/plank.Ash.middle.png")
    touch(d .. "/Macabre/skull.png"); touch(d .. "/Macabre/candle.png")
    touch(d .. "/Ukiyo-e/theme/wallpaper.jpg"); touch(d .. "/Ukiyo-e/wave.png")
    touch(d .. "/cactus.svg")
    settings.progress_fill = { hex = "#AA0000" }
    settings.progress_fill_night = { hex = "#00FFFF" }
    settings.wallpaper_default = "leaves.png"
end

-- choose(TP, tabs, id, value): what the Theme library's choose does for a
-- shelf (Settings:_setShelfThemeField): a first Own theme copies what the
-- shelf shows, before the choice is written.
local function choose(TP, tabs, id, value)
    if value == TP.OWN then TP.ensureOwn(tabs[id], TP.themeFor(id)) end
    tabs[id].theme = value
    TP._store.bump()            -- the tab save's new generation
end

-- What the shelf paints: a theme's colour, else the reader's own or the
-- own theme's (as bookshelf_cover_progress reads them).
local function paint(TP, key)
    local v = TP.colourOverride(key:gsub("_night$", ""), key:find("_night$") ~= nil) or TP.partRead(key)
    return v and v.hex or "-"
end
local function shown(TP)
    local pl = TP.activePlank()
    return table.concat({
        tostring(TP.shownWallpaper(false, false)), tostring(TP.shownWallpaper(true, true)),
        tostring(pl and pl.id), TP.shelfLook(),
        paint(TP, "ink_color"), paint(TP, "ink_color_night"),
        paint(TP, "progress_fill"), paint(TP, "progress_fill_night"), paint(TP, "badge_bg"),
    }, " ")
end
local function ownInk(TP) return (TP.partRead("ink_color") or {}).hex end

t.test("'own' is a stored choice; a pack folder named own is never a theme; the library never wears one", function()
    local TP, d, settings, tabs = setup()
    world(d, settings)
    touch(d .. "/Own/x.png")
    tabs.a = { id = "a", theme = "own", own_theme = TP.ownCopy("plain") }
    eq(TP.ownChoice("a"), "own")
    eq(TP.isReserved("own"), true); eq(TP.isReserved("Own"), true)
    for _i, th in ipairs(TP.allThemes()) do assert(th.pack ~= "Own", "a pack folder named Own is listed") end
    settings.library_theme = "own"
    eq(TP.libraryChoice(), "mine"); eq(TP.libraryTheme(), "mine")
    TP.setLibraryTheme("own"); eq(settings.library_theme, nil)
    eq(TP.themeName("own"), "Own theme")
    -- "own" with no own theme stored (a hand edit) follows the library.
    tabs.b = { id = "b", theme = "own" }
    eq(TP.themeFor("b"), "mine")
end)

t.test("choosing Own theme copies what the shelf shows, part by part, so nothing on screen changes", function()
    local TP, d, settings, tabs = setup()
    world(d, settings)
    tabs.home = { id = "home", theme = "Macabre" }
    TP.setShelf("home")
    local before = shown(TP)
    choose(TP, tabs, "home", "own")
    TP.setShelf("home")
    eq(TP.shelfTheme(), "own")
    eq(shown(TP), before, "the shelf looked different on its own copy")
    -- The pack's colour is the own theme's now; the one it lacks came from
    -- the reader's own, both slots, as stored.
    eq(ownInk(TP), "#112233")
    eq(TP.partRead("progress_fill").hex, "#AA0000")
    eq(TP.partRead("ink_color_night").hex, TP.invertHex("#112233"), "the night slot is not pre-inverted")
    local own = tabs.home.own_theme
    eq(own.from, "Macabre")
    eq(own.keys.shelf_theme, "dark")
    eq(own.keys.theme_plank_pack, "Macabre/theme/plank.Ash")
    assert(own.keys.wallpaper_default:find("Macabre", 1, true), "the wallpaper is not the pack's, by name")
    -- A pack deals its own pieces: so does the copy, and no loose one.
    local on = {}
    for k in pairs(own.pieces) do on[#on + 1] = k end
    table.sort(on)
    eq(table.concat(on, ","), "Macabre/candle.png,Macabre/skull.png")
    assert(own.keys.progress_fill ~= settings.progress_fill, "a colour table is shared with the reader's own")
end)

t.test("a copy of My theme or of Plain resolves as they do", function()
    local TP, d, settings = setup()
    world(d, settings)
    settings.theme_plank_pack = false            -- the reader's plain colour plank
    settings.spine_plank_color = { hex = "#806040" }
    local mine = TP.ownCopy("mine")
    eq(mine.keys.wallpaper_default, "leaves.png")
    eq(mine.keys.theme_plank_pack, false)
    eq(mine.keys.spine_plank_color.hex, "#806040")
    eq(mine.keys.progress_fill_night.hex, "#00FFFF")
    assert(mine.pieces["cactus.svg"] and mine.pieces["Ukiyo-e/wave.png"], "the collection's pieces were not copied")
    local plain = TP.ownCopy("plain")
    eq(plain.keys.wallpaper_default, nil); eq(plain.keys.theme_plank_pack, "oak")
    eq(plain.keys.progress_fill, nil, "Plain has the default colours")
    eq(next(plain.pieces), nil, "Plain has no ornaments")
end)

t.test("an edit on a shelf showing its own theme goes to that theme, not to My theme", function()
    local TP, d, settings, tabs, st = setup()
    world(d, settings)
    tabs.home = { id = "home", theme = "Macabre" }
    choose(TP, tabs, "home", "own")
    TP.setShelf("home")
    local key0, rev0 = TP.shelfKey(), tabs.home.own_theme.rev
    local saves = st.saves
    TP.partSave("progress_fill", { hex = "#00AA00" })
    eq(settings.progress_fill.hex, "#AA0000", "My theme's colour changed")
    eq(st.saves, saves, "a settings key of the reader's own was written")
    eq(tabs.home.own_theme.keys.progress_fill.hex, "#00AA00")
    eq(tabs.home.own_theme.rev, rev0 + 1)
    assert(TP.shelfKey() ~= key0, "an edit kept the cache key, so nothing repaints")
    eq(TP.partRead("progress_fill").hex, "#00AA00")
    -- Not a part: the reader's preference, as always.
    TP.partSave("chip_bar_transparent", true)
    eq(settings.chip_bar_transparent, true)
    eq(tabs.home.own_theme.keys.chip_bar_transparent, nil)
    -- The plank and light or dark too.
    TP.choosePlank("oak")
    eq(tabs.home.own_theme.keys.theme_plank_pack, "oak"); eq(settings.theme_plank_pack, nil)
    eq(TP.activePlank().id, "builtin:oak")
    TP.partSave("shelf_theme", "light")
    eq(TP.shelfLook(), "light"); eq(settings.shelf_theme, nil)
end)

t.test("another shelf on My theme is untouched, and its edits still go to My theme", function()
    local TP, d, settings, tabs = setup()
    world(d, settings)
    tabs.home = { id = "home", theme = "Macabre" }
    tabs.rec = { id = "rec", theme = "mine" }
    choose(TP, tabs, "home", "own")
    TP.setShelf("home")
    TP.partSave("progress_fill", { hex = "#00AA00" })
    TP.setShelf("rec")
    eq(TP.shelfTheme(), "mine")
    eq(TP.partRead("progress_fill").hex, "#AA0000", "My theme shows the own theme's edit")
    eq(TP.shownWallpaper(false, false), "leaves.png")
    TP.partSave("progress_fill", { hex = "#0000AA" })
    eq(settings.progress_fill.hex, "#0000AA", "an edit on a My theme shelf missed My theme")
    eq(tabs.home.own_theme.keys.progress_fill.hex, "#00AA00", "My theme's edit reached the own theme")
    eq(TP.shownOwn(), nil); eq(TP.editName(), "My theme")
    TP.setShelf("home")
    eq(TP.editName(), "Own theme: home")
end)

t.test("switching away keeps the own theme; choosing it again restores it exactly", function()
    local TP, d, settings, tabs = setup()
    world(d, settings)
    tabs.home = { id = "home", theme = "Macabre" }
    choose(TP, tabs, "home", "own")
    TP.setShelf("home")
    TP.partSave("progress_fill", { hex = "#00AA00" })
    TP.switches().setOff("Macabre/skull.png", true)
    local kept = tabs.home.own_theme
    choose(TP, tabs, "home", "plain")
    TP.setShelf("home")
    eq(TP.shelfTheme(), "plain"); eq(TP.shownOwn(), nil)
    assert(tabs.home.own_theme == kept, "the own theme was dropped or replaced on switching away")
    choose(TP, tabs, "home", "own")
    TP.setShelf("home")
    assert(tabs.home.own_theme == kept, "choosing it again made a new copy")
    eq(TP.partRead("progress_fill").hex, "#00AA00")
    eq(TP.switches().isOff("Macabre/skull.png"), true)
    eq(TP.switches().isOff("Macabre/candle.png"), false)
end)

t.test("ornaments: the own theme's set, switched by the browser's seam; the collection untouched", function()
    local TP, d, settings, tabs, _st, off = setup()
    world(d, settings)
    tabs.home = { id = "home", theme = "Macabre" }
    choose(TP, tabs, "home", "own")
    TP.setShelf("home")
    local pool = TP.ornamentsFor("home")
    eq(type(pool), "table"); eq(pool.on["Macabre/skull.png"], true)
    assert(TP.ornamentsFor("home") == pool, "the pool is a new table on every ask (the plan keys on it)")
    local sw = TP.switches()
    -- Any installed piece may be switched on: a loose one, another pack's.
    sw.setOff("cactus.svg", false); sw.setOff("Ukiyo-e/wave.png", false); sw.setOff("Macabre/candle.png", true)
    eq(next(off), nil, "the collection's switches changed")
    eq(sw.isPackOff("Macabre"), false, "an own theme has pack switches")
    local p2 = TP.ornamentsFor("home")
    assert(p2 ~= pool, "an edit kept the old pool")
    eq(p2.on["cactus.svg"], true); eq(p2.on["Macabre/candle.png"], nil)
    -- On a My theme shelf the browser switches the collection, as before.
    tabs.rec = { id = "rec", theme = "mine" }
    TP.setShelf("rec")
    TP.switches().setOff("cactus.svg", true)
    eq(off["cactus.svg"], true)
    eq(tabs.home.own_theme.pieces["cactus.svg"], true)
end)

t.test("bookshelf_ornaments.listFor deals an own pool's pieces, from any pack or loose, and follows edits", function()
    package.loaded["lib/bookshelf_ornaments"] = nil
    local O = dofile("lib/bookshelf_ornaments.lua")
    local all = { { name = "Macabre/skull.png", pack = "Macabre" }, { name = "Ukiyo-e/wave.png", pack = "Ukiyo-e" },
                  { name = "cactus.svg" } }
    O.listAll = function() return all, { "Macabre", "Ukiyo-e" } end
    local mem = { ornaments_off = { ["cactus.svg"] = true } }
    O._store = { read = function(k) return mem[k] end, save = function(k, v) mem[k] = v end }
    local on = { ["Ukiyo-e/wave.png"] = true, ["cactus.svg"] = true }
    local l1 = O.listFor({ key = "own:home:1:1", on = on })
    eq(#l1, 2, "the collection's off switch reached the own theme")
    eq(l1[1].name, "Ukiyo-e/wave.png"); eq(l1[2].name, "cactus.svg")
    assert(O.listFor({ key = "own:home:1:1", on = on }) == l1, "the same list while unchanged")
    on["Macabre/skull.png"] = true
    local l2 = O.listFor({ key = "own:home:1:2", on = on })
    eq(#l2, 3, "an edit was not seen")
end)

t.test("Start again from replaces the copy; Delete own theme removes it and the shelf follows the library", function()
    local TP, d, settings, tabs = setup()
    world(d, settings)
    tabs.home = { id = "home", theme = "Macabre" }
    choose(TP, tabs, "home", "own")
    TP.setShelf("home")
    TP.partSave("progress_fill", { hex = "#00AA00" })
    local key0 = TP.shelfKey()
    TP.restartOwn("home", "Ukiyo-e")
    TP.setShelf("home")
    local own = tabs.home.own_theme
    eq(own.from, "Ukiyo-e")
    eq(own.keys.progress_fill.hex, "#AA0000", "the old edit survived a fresh start (Ukiyo-e lends no colours)")
    assert(own.keys.wallpaper_default:find("Ukiyo-e", 1, true), "not Ukiyo-e's wallpaper")
    eq(own.pieces["Ukiyo-e/wave.png"], true); eq(own.pieces["Macabre/skull.png"], nil)
    assert(TP.shelfKey() ~= key0, "a fresh start kept the cache key")
    TP.deleteOwn("home")
    TP.setShelf("home")
    eq(tabs.home.own_theme, nil); eq(tabs.home.theme, nil)
    eq(TP.shelfTheme(), "mine", "the shelf does not follow the library")
end)

t.test("Reset to default colors in an own theme resets its colours, nothing of the reader's own", function()
    local TP, d, settings, tabs = setup()
    world(d, settings)
    settings.chip_bar_transparent = true
    tabs.home = { id = "home", theme = "Macabre" }
    choose(TP, tabs, "home", "own")
    TP.setShelf("home")
    TP.partClear({ "ink_color", "progress_fill", "chip_bar_transparent" })
    local k = tabs.home.own_theme.keys
    eq(k.ink_color, nil); eq(k.ink_color_night, nil); eq(k.progress_fill, nil); eq(k.progress_fill_night, nil)
    eq(TP.partRead("progress_fill"), nil, "an unset own colour read the reader's own")
    eq(settings.progress_fill.hex, "#AA0000"); eq(settings.chip_bar_transparent, true)
    eq(k.theme_plank_pack, "Macabre/theme/plank.Ash", "Reset reached a part that is not a colour")
end)

t.test("a sub-shelf shows its shelf of shelves' own theme, and edits there reach the owner", function()
    local TP, d, settings, tabs = setup()
    world(d, settings)
    tabs.top = { id = "top", theme = "Macabre" }
    choose(TP, tabs, "top", "own")
    tabs.sub = { id = "sub", parent = "top" }
    TP.setShelf("sub")
    local th, owner = TP.themeFor("sub")
    eq(th, "own"); eq(owner.id, "top")
    TP.partSave("progress_fill", { hex = "#123456" })
    eq(tabs.top.own_theme.keys.progress_fill.hex, "#123456")
    eq(tabs.sub.own_theme, nil)
end)

t.test("a reference that has gone falls back as a missing pack does, and the row says so", function()
    local TP, d, settings, tabs = setup()
    world(d, settings)
    tabs.home = { id = "home", theme = "Macabre" }
    choose(TP, tabs, "home", "own")
    os.execute("rm -rf '" .. d .. "/Macabre'")
    TP.invalidate()
    TP.setShelf("home")
    eq(TP.shownWallpaper(false, false), nil, "a gone pack's wallpaper still shows")
    eq(TP.activePlank().id, "builtin:oak", "a gone plank is not the built-in Oak")
    eq(TP.plankRowLabel(), "Ash (missing)")
    eq(TP.shelfTheme(), "own", "the own theme went with the pack it started from")
end)

t.test("the Theme library: a shelf's picker has Own theme after the built-ins, the library's has none", function()
    local TP, d, settings, tabs = setup()
    world(d, settings)
    package.loaded["lib/bookshelf_theme_library"] = nil
    local TL = dofile("lib/bookshelf_theme_library.lua")
    TL._tp, TL._orn = TP, TP._orn
    local function titles(items)
        local o = {}
        for i, it in ipairs(items) do o[i] = it.title end
        return table.concat(o, ",")
    end
    eq(titles(TL.items{ shelf = "Home", current = nil, showing = "Macabre" }),
       "Same as library,My theme,Plain,Own theme,Macabre,Ukiyo-e")
    eq(titles(TL.items{ current = "mine" }), "My theme,Plain,Macabre,Ukiyo-e")
    eq(titles(TL.items{ themes = true }), "My theme,Plain,Macabre,Ukiyo-e", "Start again from lists more than every theme")
    local card = TL.items{ shelf = "Home", showing = "Macabre" }[4]
    eq(card.value, "own"); eq(card.summary, "Starts as a copy of Macabre")
    -- Not made yet: its hero is what it would copy, not a blank box.
    eq(card.copies, "Macabre", "an Own theme not made yet shows no hero")
    tabs.home = { id = "home", theme = "Macabre" }
    choose(TP, tabs, "home", "own")
    card = TL.items{ shelf = "Home", current = "own", own = tabs.home.own_theme }[4]
    eq(card.summary, "Started from Macabre")
    assert(TL.isCurrent(card, "own"), "the Own theme card is not marked in use")
    eq(TL.hero("own", tabs.home.own_theme).name:match("^Macabre/") ~= nil, true, "the hero is not from its own set")
end)

-- ── Wiring: every editor writes through the seam ─────────────────────────
-- Reverting any of these to a direct settings write sends an own theme's
-- edit to My theme, which is the bug the seam exists to prevent.
t.test("the editor rows write through the seam", function()
    local set = io.open("lib/bookshelf_settings.lua"):read("*a")
    local function body(sig)
        local b = set:match("\nfunction Settings:" .. sig:gsub("[%(%)]", "%%%0") .. "\n(.-)\nend\n")
        assert(b, sig .. " moved"); return (b:gsub("%-%-[^\n]*", ""))
    end
    local pick = body("_pickColor(raw_key, field, default_pct, title,")
        or body("_pickColor(raw_key, field, default_pct, title, touchmenu_instance, refresh, anchor, wood)")
    assert(pick:find("TP.partRead(key)", 1, true), "the colour picker reads My theme's key directly")
    assert(not pick:find("BookshelfSettings.save(key", 1, true) and not pick:find("BookshelfSettings.delete(key", 1, true),
        "the colour picker writes My theme's key directly")
    local _n, saves = pick:gsub("TP%.partSave%(key", "")
    eq(saves >= 3, true, "the palette, its revert and the nudge do not all write through the seam")
    local ld = body("_lightDarkRow()")
    assert(ld:find("partSave(CP.THEME_SETTING, value)", 1, true), "light or dark writes My theme's key directly")
    assert(body("_shelfTheme()"):find("partRead(CP.THEME_SETTING)", 1, true), "light or dark reads My theme's key")
    local wm = body("_wallpaperMenu()")
    assert(wm:find("TP.partSave(Wallpaper.INVERT_NIGHT_SETTING", 1, true), "invert writes My theme's key directly")
    assert(wm:find("TP.partDelete(Wallpaper.BG_SETTING", 1, true), "the page colour's reset writes My theme's key")
    assert(wm:find("local name = TP.partRead(setting)", 1, true), "the wallpaper rows read My theme's keys")
    assert(body("_plankRow(markDirty)"):find('partDelete("spine_plank_color" .. suffix)', 1, true),
        "the plank colour's reset writes My theme's key directly")
    assert(body("_colorValueLabel(raw_key, _default_pct)"):find("partRead(raw_key .. suffix)", 1, true),
        "a colour row's value reads My theme's key")
    local colors = body("_colorsSubItems()")
    assert(colors:find("partDelete(base .. suffix)", 1, true), "a colour row's reset writes My theme's key")
    local wb = io.open("lib/bookshelf_wallpaper_browser.lua"):read("*a")
    local wch = wb:match("\nfunction WB%.choose%(key, item%)\n(.-)\nend\n")
    assert(wch and wch:find("TP().partSave(key, item.name)", 1, true)
        and not wch:find("BookshelfSettings.save(key", 1, true), "the wallpaper picker writes My theme's key directly")
    local ob = io.open("lib/bookshelf_ornament_browser.lua"):read("*a")
    local tog = ob:match("\nfunction Browser:_toggle%(item%)\n(.-)\nend\n")
    assert(tog and tog:find("SW().setOff(", 1, true), "the ornament browser switches the collection directly")
    assert(ob:find('require("lib/bookshelf_theme_pack").switches()', 1, true), "the browser's switches are not the seam's")
    local tp = io.open("lib/bookshelf_theme_pack.lua"):read("*a")
    local cp = tp:match("\nfunction M%.choosePlank%(choice%)\n(.-)\nend\n")
    assert(cp and cp:find("M.partSave(M.PLANK_SETTING, v)", 1, true), "the plank picker writes My theme's key directly")
end)

t.test("the paint reads through the seam: colours, bars, chips, the page ground, invert", function()
    local cp = io.open("lib/bookshelf_cover_progress.lua"):read("*a")
    local own = cp:match("\nlocal function _readOwnColor%(base_key, default_day, default_night, suffix%)\n(.-)\nend\n")
    assert(own and own:find("_partRead(base_key .. suffix)", 1, true) and own:find("_partRead(base_key)", 1, true)
        and not own:find("BookshelfSettings.read", 1, true), "the colours read My theme's keys on an own theme shelf")
    local bars = cp:match("\nfunction M%.pickedBarColors%(%)\n(.-)\nend\n")
    assert(bars and bars:find('_partRead("progress_fill" .. suffix)', 1, true), "the hero bars read My theme's keys")
    local cb = io.open("lib/bookshelf_chip_bar.lua"):read("*a")
    local bar = cb:match("\nlocal function _readBarColor%(base_key%)\n(.-)\nend\n")
    assert(bar and bar:find("TP.partRead(k)", 1, true), "the selected shelf reads My theme's keys")
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    local ground = w:match("\nfunction BookshelfWidget:_pageGroundColor%(%)\n(.-)\nend\n")
    assert(ground and ground:find("TP.partRead(Wallpaper.BG_SETTING .. suffix)", 1, true),
        "the page ground reads My theme's key")
    local stored = w:match("\nfunction BookshelfWidget:_pageColourStored%(%)\n(.-)\nend\n")
    assert(stored and stored:find("TP.partRead(Wallpaper.BG_SETTING .. suffix)", 1, true),
        "the page colour's presence reads My theme's key")
    local wp = io.open("lib/bookshelf_wallpaper.lua"):read("*a")
    local inv = wp:match("\nfunction M%.invertsAtNight%(%)\n(.-)\nend\n")
    assert(inv and inv:find("TP.partRead(M.INVERT_NIGHT_SETTING)", 1, true), "invert at night reads My theme's key")
end)

t.test("the menu: This shelf, then Start again from, Delete own theme last, only while the shelf shows its own", function()
    local set = io.open("lib/bookshelf_settings.lua"):read("*a"):gsub("%-%-[^\n]*", "")
    local bg = set:match("\nfunction Settings:_backgroundSubItems%(%)\n(.-)\nend\n")
    assert(bg, "_backgroundSubItems moved")
    -- The choice reads before what can be done with it (maintainer's
    -- screenshot review, 2026-10-08).
    local r = bg:find("local restart = self:_ownRestartRow(owner)", 1, true)
    local this = bg:find("rows[#rows + 1] = this_shelf", 1, true)
    assert(r and this and this < r, "Start again from is not right after This shelf")
    local del = bg:find("rows[#rows + 1] = self:_ownDeleteRow(owner)", 1, true)
    assert(del and del > bg:find("_newOrnamentsRow", 1, true), "Delete own theme is not the last row")
    local restart = set:match("\nfunction Settings:_ownRestartRow%(id%)\n(.-)\nend\n")
    assert(restart and restart:find("ConfirmBox", 1, true) and restart:find("TP.restartOwn(id, value)", 1, true),
        "Start again from replaces the copy without asking")
    local delete = set:match("\nfunction Settings:_ownDeleteRow%(id%)\n(.-)\nend\n")
    assert(delete and delete:find("ConfirmBox", 1, true) and delete:find(".deleteOwn(id)", 1, true),
        "Delete own theme removes it without asking")
    local main = io.open("main.lua"):read("*a")
    assert(main:find('require("lib/bookshelf_theme_pack").editName())', 1, true),
        "the menu is not titled for the own theme it edits")
    local field = set:match("\nfunction Settings:_setShelfThemeField%(id, field, value%)\n(.-)\nend\n")
    local ens = field and field:find("TP.ensureOwn(t, showing)", 1, true)
    assert(ens and ens < field:find("t[field] = value", 1, true),
        "a first Own theme is not copied before the choice is written")
end)

t.done()
