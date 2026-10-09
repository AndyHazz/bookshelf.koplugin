-- tests/_test_editable_themes.lua
-- Every theme is editable, edits saved with the theme (5.4, maintainer
-- 2026-10-08): "you could apply macabre, edit it to change to another
-- wallpaper, swap back to plain, then use macabre again in future on a
-- specific shelf and it'd still have your edits, then reset it back to
-- original". theme_edits holds one entry per pack (or Plain); a part
-- resolves as the edit, else the theme's original, else Custom theme's; every
-- editor writes through one seam (partRead / partSave, choosePlank,
-- switches) that picks Custom theme's keys or the theme on screen's edits.
-- Run from the plugin root: lua tests/_test_editable_themes.lua
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
    local d = string.format("%s/bookshelf_edit_theme_%d_%d", tmp, os.time(), math.random(1e6))
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
    -- As bookshelf_ornaments.listFor: a pack's own pieces, every one; an
    -- edited theme's set (a table).
    function orn.listFor(sp)
        if sp == "mine" then return orn.list() end
        if sp == "plain" then return {} end
        local out = {}
        for _i, e in ipairs((orn.listAll())) do
            if type(sp) == "table" then
                if sp.on[e.name] then out[#out + 1] = e end
            elseif e.pack == sp then out[#out + 1] = e end
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
-- reader's own: a progress bar colour (both slots), a wallpaper, a loose
-- piece, Ukiyo-e with a wallpaper and one piece.
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

-- What the shelf paints: the defaults on an unedited Plain, a theme's
-- colour, else the edit or the reader's own (as bookshelf_cover_progress
-- reads them: defaultColours, colourOverride, then partRead).
local function paint(TP, key)
    if TP.defaultColours() then return "default" end
    local base, night = key:gsub("_night$", "")
    local v = TP.colourOverride(base, night > 0) or TP.partRead(key)
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
local function edits(settings, th) return (settings.theme_edits or {})[th] end
-- on(TP, id): the shelf on screen, after a tab save (a new generation).
local function on(TP, id) TP._store.bump(); TP.setShelf(id) end

t.test("an edit on a pack's shelf goes to that theme's edits, never to Custom theme", function()
    local TP, d, settings, tabs, st = setup()
    world(d, settings)
    tabs.home = { id = "home", theme = "Macabre" }
    on(TP, "home")
    eq(paint(TP, "ink_color"), "#112233")
    local gen = st.gen
    TP.partSave("progress_fill", { hex = "#00AA00" })
    TP.partSave("ink_color", { hex = "#445566" })
    TP.partSave("wallpaper_default", "leaves.png")
    TP.choosePlank("oak")
    TP.partSave("shelf_theme", "light")
    eq(settings.progress_fill.hex, "#AA0000", "Custom theme's colour changed")
    eq(settings.theme_plank_pack, nil); eq(settings.shelf_theme, nil)
    eq(settings.wallpaper_default, "leaves.png")
    assert(st.gen > gen, "an edit did not bump the generation, so nothing repaints")
    local e = edits(settings, "Macabre")
    eq(e.keys.progress_fill.hex, "#00AA00"); eq(e.keys.theme_plank_pack, "oak")
    -- The pack's own colour does not win over the edit (colourOverride).
    eq(paint(TP, "ink_color"), "#445566", "the pack's colour painted over the edit")
    eq(paint(TP, "progress_fill"), "#00AA00")
    eq(TP.shownWallpaper(false, false), "leaves.png")
    eq(TP.activePlank().id, "builtin:oak"); eq(TP.shelfLook(), "light")
    -- Not a part: the reader's preference, as always.
    TP.partSave("chip_bar_transparent", true)
    eq(settings.chip_bar_transparent, true)
    eq(e.keys.chip_bar_transparent, nil)
    eq(TP.editName(), "Macabre", "the menu is not named for the theme it edits")
end)

t.test("the maintainer's round trip: edits come back wherever the theme is used; Custom theme untouched", function()
    local TP, d, settings, tabs = setup()
    world(d, settings)
    tabs.home = { id = "home", theme = "Macabre" }
    tabs.rec = { id = "rec" }
    tabs.mine = { id = "mine", theme = "mine" }
    on(TP, "mine")
    local mine_before = shown(TP)
    on(TP, "home")
    local original = shown(TP)
    TP.partSave("wallpaper_default", "theme-pack\1Ukiyo-e\1wallpaper.jpg")
    TP.partSave("progress_fill", { hex = "#00AA00" })
    TP.switches().setOff("Macabre/skull.png", true)
    local edited = shown(TP)
    assert(edited ~= original, "the edits did not show")
    tabs.home.theme = "plain"
    on(TP, "home")
    eq(TP.shownWallpaper(false, false), nil, "Plain shows the Macabre edit")
    tabs.rec.theme = "Macabre"
    on(TP, "rec")
    eq(shown(TP), edited, "another shelf on Macabre does not show its edits")
    eq(TP.shownWallpaper(false, false), "theme-pack\1Ukiyo-e\1wallpaper.jpg")
    eq(TP.switches().isOff("Macabre/skull.png"), true)
    on(TP, "mine")
    eq(shown(TP), mine_before, "Custom theme changed")
    eq(TP.hasEdits("mine"), false)
    -- Reset: the original back, everywhere.
    eq(TP.resetEdits("Macabre"), true)
    on(TP, "rec")
    eq(shown(TP), original, "Reset did not bring the original back")
    eq(TP.hasEdits("Macabre"), false); eq(settings.theme_edits, nil)
    eq(TP.resetEdits("Macabre"), false, "a theme as original was reset again")
end)

t.test("an edit back to the original is no edit: Reset greys once nothing differs", function()
    local TP, d, settings, tabs = setup()
    world(d, settings)
    tabs.home = { id = "home", theme = "Macabre" }
    on(TP, "home")
    local ink = TP.partRead("ink_color")
    TP.partSave("ink_color", { hex = "#000000" })
    eq(TP.hasEdits("Macabre"), true)
    -- The colour picker's Cancel saves what it opened on.
    TP.partSave("ink_color", ink)
    eq(TP.hasEdits("Macabre"), false, "putting the pack's colour back left an edit")
    TP.switches().setOff("Macabre/skull.png", true)
    TP.switches().setOff("Macabre/skull.png", false)
    eq(TP.hasEdits("Macabre"), false, "switching a piece off and on left an edit")
    TP.choosePlank("Macabre/theme/plank.Ash")
    eq(TP.hasEdits("Macabre"), false, "choosing the pack's own plank is an edit")
end)

t.test("an edit to a part the pack lacks stays an edit, even equal to Custom theme's value", function()
    -- writeEdits compared EVERY stored key with originalPart, which for a
    -- part the pack lacks is Custom theme's live value: an edit equal to it
    -- was dropped, then or on any later write, and the pack followed Custom
    -- theme's next change (review, 2026-10-09).
    local TP, d, settings, tabs = setup()
    world(d, settings)
    tabs.home = { id = "home", theme = "Macabre" }    -- no progress bar colour
    on(TP, "home")
    TP.partSave("progress_fill", { hex = "#AA0000" })   -- Custom theme's own value
    eq(TP.hasEdits("Macabre"), true, "an edit equal to Custom theme's value was dropped")
    settings.progress_fill = { hex = "#BBBBBB" }; on(TP, "home")
    eq(paint(TP, "progress_fill"), "#AA0000", "the pack followed Custom theme's change")
    -- Another write does not re-normalise it away once Custom matches.
    TP.partSave("progress_fill", { hex = "#00AA00" })
    settings.progress_fill = { hex = "#00AA00" }; on(TP, "home")
    TP.partSave("ink_color", { hex = "#445566" })
    settings.progress_fill = { hex = "#CCCCCC" }; on(TP, "home")
    eq(paint(TP, "progress_fill"), "#00AA00", "an unrelated write dropped the edit")
    -- Unset (Default) while Custom theme's is unset too: still the default after.
    TP.partDelete("progress_fill_night")
    settings.progress_fill_night = nil; on(TP, "home")
    TP.partSave("ink_color", { hex = "#000001" })
    settings.progress_fill_night = { hex = "#123123" }; on(TP, "home")
    eq(paint(TP, "progress_fill_night"), "-", "an unset edit followed Custom theme")
    -- The pack's own part put back is still no edit.
    TP.partSave("ink_color", { hex = "#112233" })
    eq(edits(settings, "Macabre").keys.ink_color, nil, "the pack's own colour put back stayed an edit")
end)

t.test("a picker's Cancel puts an unedited part back unedited, an edited one as it was", function()
    local TP, d, settings, tabs = setup()
    world(d, settings)
    tabs.home = { id = "home", theme = "Macabre" }
    on(TP, "home")
    local snap = TP.partSnapshot("progress_fill")
    TP.partSave("progress_fill", { hex = "#00AA00" })   -- the live pick
    TP.partRestore("progress_fill", snap)
    eq(TP.hasEdits("Macabre"), false, "Cancel pinned the part to Custom theme's value")
    settings.progress_fill = { hex = "#BBBBBB" }; on(TP, "home")
    eq(paint(TP, "progress_fill"), "#BBBBBB")
    TP.partSave("badge_bg", { hex = "#010101" })
    snap = TP.partSnapshot("badge_bg")
    TP.partSave("badge_bg", { hex = "#020202" })
    TP.partRestore("badge_bg", snap)
    eq(edits(settings, "Macabre").keys.badge_bg.hex, "#010101")
    -- Custom theme: its own key, as before.
    tabs.home.theme = "mine"; on(TP, "home")
    snap = TP.partSnapshot("progress_fill")
    TP.partSave("progress_fill", { hex = "#00AA00" })
    TP.partRestore("progress_fill", snap)
    eq(settings.progress_fill.hex, "#BBBBBB")
end)

t.test("edited to unset is the default: never the pack's, never the reader's own", function()
    local TP, d, settings, tabs = setup()
    world(d, settings)
    settings.wallpaper_invert_night = true
    settings.wallpaper_full = "trees.png"
    tabs.home = { id = "home", theme = "Ukiyo-e" }     -- no colours, a wallpaper
    tabs.mac = { id = "mac", theme = "Macabre" }
    on(TP, "home")
    eq(TP.partRead("wallpaper_invert_night"), true, "a theme without it does not follow the reader's")
    TP.partSave("wallpaper_invert_night", nil)
    eq(TP.partRead("wallpaper_invert_night"), nil, "invert off on a theme read the reader's own")
    TP.partDelete("progress_fill")                        -- Default, in the picker
    eq(paint(TP, "progress_fill"), "-", "the default colour read the reader's own")
    eq(settings.progress_fill.hex, "#AA0000")
    on(TP, "mac")
    TP.partDelete("ink_color")
    eq(paint(TP, "ink_color"), "-", "the default colour read the pack's")
    -- Reset to default colors: both slots, on this theme only.
    TP.partClear({ "progress_fill" })
    eq(paint(TP, "progress_fill"), "-"); eq(paint(TP, "progress_fill_night"), "-")
    eq(settings.progress_fill_night.hex, "#00FFFF", "Reset reached the reader's own")
end)

t.test("Plain is editable the same way; unedited, it paints the defaults whatever the reader has", function()
    local TP, d, settings, tabs = setup()
    world(d, settings)
    tabs.home = { id = "home", theme = "plain" }
    on(TP, "home")
    eq(TP.defaultColours(), true); eq(paint(TP, "progress_fill"), "default")
    eq(TP.activePlank().id, "builtin:oak"); eq(TP.shownWallpaper(false, false), nil)
    eq(#TP._orn.listFor(TP.ornamentsFor("home")), 0)
    TP.partSave("badge_bg", { hex = "#123456" })
    TP.partSave("wallpaper_default", "leaves.png")
    TP.switches().setOff("cactus.svg", false)
    eq(TP.defaultColours(), false, "an edited colour on Plain is not painted")
    eq(paint(TP, "badge_bg"), "#123456")
    eq(paint(TP, "progress_fill"), "-", "Plain's unedited colour read the reader's own")
    eq(TP.shownWallpaper(false, false), "leaves.png")
    local list = TP._orn.listFor(TP.ornamentsFor("home"))
    eq(#list, 1); eq(list[1].name, "cactus.svg")
    TP.partSave("shelf_theme", "dark"); eq(TP.shelfLook(), "dark", "Plain's light or dark is not editable")
    eq(edits(settings, "plain").keys.badge_bg.hex, "#123456")
    TP.resetEdits("plain")
    on(TP, "home")
    eq(TP.defaultColours(), true); eq(TP.shownWallpaper(false, false), nil)
end)

t.test("ornaments: a theme's set, switched by the browser's seam; any piece may join; the collection untouched", function()
    local TP, d, settings, tabs, _st, off = setup()
    world(d, settings)
    tabs.home = { id = "home", theme = "Macabre" }
    on(TP, "home")
    eq(TP.ornamentsFor("home"), "Macabre", "an unedited pack does not deal its own pieces")
    local key0 = TP.shelfKey()
    local sw = TP.switches()
    eq(sw.isOff("cactus.svg"), true, "a loose piece is on in a pack's set")
    sw.setOff("cactus.svg", false); sw.setOff("Macabre/candle.png", true)
    eq(next(off), nil, "the collection's switches changed")
    eq(sw.isPackOff("Macabre"), false, "a theme has pack switches")
    local pool = TP.ornamentsFor("home")
    eq(type(pool), "table"); eq(pool.on["cactus.svg"], true); eq(pool.on["Macabre/candle.png"], nil)
    assert(TP.ornamentsFor("home") == pool, "the pool is a new table on every ask (the plan keys on it)")
    local key1 = TP.shelfKey()
    assert(key1 ~= key0, "switching a piece kept the cache key, so the pages keep the old pool")
    -- Another part's edit keeps the pool and the key: the pages keep their ornaments.
    TP.partSave("progress_fill", { hex = "#00AA00" })
    assert(TP.ornamentsFor("home") == pool, "a colour edit made a new pool")
    eq(TP.shelfKey(), key1, "a colour edit re-dealt the pages' ornaments")
    -- On a Custom theme shelf the browser switches the collection, as before.
    tabs.rec = { id = "rec", theme = "mine" }
    on(TP, "rec")
    TP.switches().setOff("cactus.svg", true)
    eq(off["cactus.svg"], true)
    eq(edits(settings, "Macabre").pieces["cactus.svg"], true)
end)

t.test("bookshelf_ornaments.listFor deals an edited set, from any pack or loose; a pack all its pieces", function()
    package.loaded["lib/bookshelf_ornaments"] = nil
    local O = dofile("lib/bookshelf_ornaments.lua")
    local all = { { name = "Macabre/skull.png", pack = "Macabre" }, { name = "Ukiyo-e/wave.png", pack = "Ukiyo-e" },
                  { name = "cactus.svg" } }
    O.listAll = function() return all, { "Macabre", "Ukiyo-e" } end
    local mem = { ornaments_off = { ["cactus.svg"] = true, ["Macabre/skull.png"] = true } }
    O._store = { read = function(k) return mem[k] end, save = function(k, v) mem[k] = v end }
    local set = { ["Ukiyo-e/wave.png"] = true, ["cactus.svg"] = true }
    local l1 = O.listFor({ slot = "edit:Macabre", key = "edit:Macabre:1", on = set })
    eq(#l1, 2, "the collection's off switch reached an edited set")
    eq(l1[1].name, "Ukiyo-e/wave.png"); eq(l1[2].name, "cactus.svg")
    assert(O.listFor({ slot = "edit:Macabre", key = "edit:Macabre:1", on = set }) == l1, "the same list while unchanged")
    local set2 = { ["Macabre/skull.png"] = true }
    eq(#O.listFor({ slot = "edit:Macabre", key = "edit:Macabre:2", on = set2 }), 1, "an edit was not seen")
    -- Custom theme's off switches do not reach a pack's shelf any more.
    eq(#O.listFor("Macabre"), 1, "a pack's piece off in the collection is off on the pack's shelf")
end)

t.test("migration 2: a 5.3 pack piece switched off becomes that pack's edit; the own theme is dropped", function()
    local TP, d, settings, tabs, _st, off = setup()
    world(d, settings)
    settings.theme_model = 1
    off["Macabre/skull.png"] = true; off["cactus.svg"] = true
    settings.wallpaper_default = "theme-pack\1Gone\1wallpaper.png"   -- a v1 step would clear it
    tabs.home = { id = "home", theme = "own", own_theme = { keys = {} } }
    tabs.rec = { id = "rec", theme = "Macabre", own_theme = { keys = {} } }
    TP.migrate()
    eq(settings.theme_model, 2)
    eq(settings.wallpaper_default, "theme-pack\1Gone\1wallpaper.png", "a version 1 step ran again")
    local e = edits(settings, "Macabre")
    assert(e and e.pieces, "the off switch did not become Macabre's edit")
    eq(e.pieces["Macabre/candle.png"], true); eq(e.pieces["Macabre/skull.png"], nil)
    eq(edits(settings, "Ukiyo-e"), nil, "a pack with nothing off got an edit")
    eq(off["Macabre/skull.png"], true, "Custom theme's switch went (it deals pack pieces too)")
    eq(tabs.home.own_theme, nil); eq(tabs.home.theme, nil); eq(tabs.rec.own_theme, nil)
    eq(tabs.rec.theme, "Macabre")
    -- Nothing on screen changes: the Macabre shelf deals the candle alone.
    on(TP, "rec")
    local list = TP._orn.listFor(TP.ornamentsFor("rec"))
    eq(#list, 1); eq(list[1].name, "Macabre/candle.png")
    eq(TP.hasEdits("Macabre"), true, "the moved switch is not an edit Reset can undo")
    TP.migrate()
    eq(edits(settings, "Macabre").rev, e.rev, "the migration ran twice")
end)

t.test("migration from 5.3: the library's pack keeps dealing what 5.3 dealt there, loose pieces too", function()
    -- 5.3 applied a pack by switching every other pack off; loose pieces
    -- stayed on and were dealt with the pack's. A pack deals only its own
    -- set now, so without an edit the loose pieces left the shelf (review,
    -- 2026-10-09). A 5.3-shaped settings file:
    local TP, d, settings, tabs, _st, off, packs_off = setup()
    world(d, settings)
    settings.wallpaper_default = nil; settings.progress_fill = nil; settings.progress_fill_night = nil
    settings.shelf_theme = "dark"
    off["Macabre/skull.png"] = true                -- switched off under the theme
    packs_off["Ukiyo-e"] = true                    -- the theme switched it off
    settings.theme_applied = { pack = "Macabre", before = { shelf_theme = "\0nil" }, applied = { shelf_theme = "dark" },
                               packs_before = {}, packs_applied = { ["Ukiyo-e"] = true } }
    tabs.home = { id = "home" }
    local function dealt()
        local names = {}
        for _i, e in ipairs(TP._orn.listFor(TP.ornamentsFor("home"))) do names[#names + 1] = e.name end
        table.sort(names); return table.concat(names, " ")
    end
    eq(dealt(), "Macabre/candle.png cactus.svg", "the fixture is not what 5.3 dealt")  -- 5.3: the collection
    TP.migrate()
    eq(settings.library_theme, "Macabre"); eq(settings.shelf_theme, nil); eq(packs_off["Ukiyo-e"], nil)
    on(TP, "home")
    eq(dealt(), "Macabre/candle.png cactus.svg", "the library's shelf deals other pieces than 5.3 did")
    eq(TP.hasEdits("Macabre"), true)
    -- Only the pack's own set, as 5.3 dealt it: no edit to show.
    local TP2, d2, settings2, _tabs2, _st2, _off2, packs_off2 = setup()
    touch(d2 .. "/Macabre/theme/theme.json", '{"shelf":"dark"}'); touch(d2 .. "/Macabre/skull.png")
    touch(d2 .. "/Ukiyo-e/wave.png")
    packs_off2["Ukiyo-e"] = true; settings2.shelf_theme = "dark"
    settings2.theme_applied = { pack = "Macabre", before = { shelf_theme = "\0nil" }, applied = { shelf_theme = "dark" },
                                packs_before = {}, packs_applied = { ["Ukiyo-e"] = true } }
    TP2.migrate()
    eq(settings2.library_theme, "Macabre"); eq(TP2.hasEdits("Macabre"), false, "the pack's own set became an edit")
end)

t.test("a pack updated in place keeps its edits; one deleted keeps them for when it comes back", function()
    local TP, d, settings, tabs = setup()
    world(d, settings)
    tabs.home = { id = "home", theme = "Macabre" }
    on(TP, "home")
    TP.partSave("progress_fill", { hex = "#00AA00" })
    -- Updated: a new colour; the edit stays over it, Reset gives the new one.
    touch(d .. "/Macabre/theme/colours.json", '{"day":{"text":"#998877","progress bar":"#010203"}}')
    TP.invalidate(); on(TP, "home")
    eq(paint(TP, "progress_fill"), "#00AA00"); eq(paint(TP, "ink_color"), "#998877")
    os.execute("mv '" .. d .. "/Macabre' '" .. d .. "/_away'")
    TP.invalidate(); on(TP, "home")
    eq(TP.shelfTheme(), "mine", "a missing pack's shelf does not follow the library")
    eq(edits(settings, "Macabre").keys.progress_fill.hex, "#00AA00", "a deleted pack's edits went")
    os.execute("mv '" .. d .. "/_away' '" .. d .. "/Macabre'")
    TP.invalidate(); on(TP, "home")
    eq(paint(TP, "progress_fill"), "#00AA00", "the edits did not come back with the pack")
    TP.resetEdits("Macabre"); on(TP, "home")
    eq(paint(TP, "progress_fill"), "#010203", "Reset did not give the updated original")
end)

t.test("an edit naming a reference that has gone falls back as a missing pack does, and the row says so", function()
    local TP, d, settings, tabs = setup()
    world(d, settings)
    touch(d .. "/Planks/theme/plank.Walnut.middle.png")
    tabs.home = { id = "home", theme = "Macabre" }
    on(TP, "home")
    TP.choosePlank("Planks/theme/plank.Walnut")
    eq(TP.activePlank().id, "Planks/theme/plank.Walnut")
    os.execute("rm -rf '" .. d .. "/Planks'")
    TP.invalidate(); on(TP, "home")
    eq(TP.activePlank().id, "builtin:oak", "a gone plank is not the fallback")
    eq(TP.plankRowLabel(), "Walnut (missing)")
    eq(TP.partEdited("theme_plank_pack"), true)
    eq(TP.partEdited("wallpaper_default"), false)
end)

t.test("the own theme is gone: 'own' stored by the unreleased build reads as unset", function()
    local TP, d, settings, tabs = setup()
    world(d, settings)
    settings.library_theme = "Macabre"
    tabs.a = { id = "a", theme = "own", own_theme = { keys = { shelf_theme = "light" } } }
    eq(TP.ownChoice("a"), nil); eq(TP.themeFor("a"), "Macabre")
    eq(TP.isReserved("own"), true)
    for _i, k in ipairs({ "OWN", "ownName", "ownCopy", "ensureOwn", "restartOwn", "deleteOwn",
                          "ownPool", "shownOwn", "ownerOf", "resolveChoice" }) do
        eq(TP[k], nil, "TP." .. k .. " is still there")
    end
    for _i, c in ipairs(TP.choiceList(nil, true)) do assert(c.value ~= "own", "a shelf's list has Own theme") end
end)

t.test("an edit keeps the look key: a colour nudge on a pack's shelf is no full-screen flash", function()
    -- The key was bumped by every edit (its rev), so setShelf bumped the
    -- generation and the widget asked for a "full" refresh on each nudge
    -- (review, 2026-10-09). The edit's own write moves the memos.
    local TP, d, settings, tabs, st = setup()
    world(d, settings)
    tabs.home = { id = "home", theme = "Macabre" }
    tabs.rec = { id = "rec", theme = "Macabre" }
    on(TP, "home")
    local k0 = TP.lookKey()
    local gen = st.gen
    TP.partSave("badge_bg", { hex = "#123456" })
    assert(st.gen > gen, "an edit did not bump the generation, so the memos keep the old colour")
    eq(paint(TP, "badge_bg"), "#123456", "the shelf's memo kept the colour from before the edit")
    eq(TP.lookKey(), k0, "a colour edit changed the look key")
    eq(TP.setShelf("home"), false, "a colour edit asked for a full-screen refresh")
    TP.switches().setOff("Macabre/skull.png", true)
    eq(TP.setShelf("home"), false, "an ornament edit asked for a full-screen refresh")
    on(TP, "rec")
    eq(TP.lookKey(), k0, "two shelves on one theme look different")
    -- A theme switch still does.
    tabs.rec.theme = "Ukiyo-e"; TP._store.bump()
    eq(TP.setShelf("rec"), true, "a theme switch kept the look")
    -- Edited colours on a pack without any: its own now, told apart from
    -- the reader's.
    local k1 = TP.lookKey()
    TP.partSave("badge_bg", { hex = "#654321" })
    eq(TP.coloursSource(), "Ukiyo-e", "a pack with edited colours paints the reader's own")
    assert(TP.lookKey() ~= k1, "edited colours on a pack without any read as the reader's own look")
    -- Its first colour edit is still no flash (rig, 2026-10-09: the rig's
    -- Macabre has no colours.json), though the caches move.
    local g = st.gen
    eq(TP.setShelf("rec"), false, "the first colour edit on a pack without colours asked for a full refresh")
    assert(st.gen > g, "the first colour edit did not move the caches")
    TP.partSave("badge_bg", nil); TP.resetEdits("Ukiyo-e")
    eq(TP.setShelf("rec"), false, "the last colour edit put back asked for a full refresh")
    -- A shelf switch to a look that differs only in its colours still does.
    tabs.home.theme = "Ukiyo-e"; TP.partSave("badge_bg", { hex = "#654321" })
    TP._store.bump(); TP.setShelf("home")
    tabs.rec.theme = "mine"; TP._store.bump()
    eq(TP.setShelf("rec"), true, "a shelf switch to other colours kept the look")
end)

-- ── Wiring: every editor writes through the seam ─────────────────────────
-- Reverting any of these to a direct settings write sends an edit to a
-- theme into Custom theme, which is the bug the seam exists to prevent.
t.test("the editor rows write through the seam", function()
    local set = io.open("lib/bookshelf_settings.lua"):read("*a")
    local function body(sig)
        local b = set:match("\nfunction Settings:" .. sig:gsub("[%(%)]", "%%%0") .. "\n(.-)\nend\n")
        assert(b, sig .. " moved"); return (b:gsub("%-%-[^\n]*", ""))
    end
    local pick = body("_pickColor(raw_key, field, default_pct, title,")
    assert(pick:find("TP.partRead(key)", 1, true), "the colour picker reads Custom theme's key directly")
    assert(not pick:find("BookshelfSettings.save(key", 1, true) and not pick:find("BookshelfSettings.delete(key", 1, true),
        "the colour picker writes Custom theme's key directly")
    local _n, saves = pick:gsub("TP%.partSave%(key", "")
    eq(saves >= 2, true, "the palette and the nudge do not both write through the seam")
    assert(pick:find("TP.partRestore(key, before)", 1, true), "the palette's Cancel does not restore through the seam")
    local ld = body("_lightDarkRow()")
    assert(ld:find("partSave(CP.THEME_SETTING, value)", 1, true), "light or dark writes Custom theme's key directly")
    assert(body("_shelfTheme()"):find("partRead(CP.THEME_SETTING)", 1, true), "light or dark reads Custom theme's key")
    local wm = body("_wallpaperMenu()")
    assert(wm:find("TP.partSave(Wallpaper.INVERT_NIGHT_SETTING", 1, true), "invert writes Custom theme's key directly")
    assert(wm:find("TP.partDelete(Wallpaper.BG_SETTING", 1, true), "the page colour's reset writes Custom theme's key")
    assert(wm:find("local name = TP.partRead(setting)", 1, true), "the wallpaper rows read Custom theme's keys")
    assert(wm:find("if TP.partEdited(setting) then", 1, true), "an edited picture that has gone does not say so")
    assert(body("_plankRow(markDirty)"):find('partDelete("spine_plank_color" .. suffix)', 1, true),
        "the plank colour's reset writes Custom theme's key directly")
    assert(body("_colorValueLabel(raw_key, _default_pct)"):find("partRead(raw_key .. suffix)", 1, true),
        "a colour row's value reads Custom theme's key")
    local colors = body("_colorsSubItems()")
    assert(colors:find("partDelete(base .. suffix)", 1, true), "a colour row's reset writes Custom theme's key")
    assert(colors:find("partClear(keys)", 1, true), "Reset to default colors writes Custom theme's keys")
    assert(body("_ornamentsRow()"):find("listFor(require(\"lib/bookshelf_theme_pack\").editPool())", 1, true),
        "the Ornaments row counts the collection on a theme's shelf")
    local wb = io.open("lib/bookshelf_wallpaper_browser.lua"):read("*a")
    local wch = wb:match("\nfunction WB%.choose%(key, item%)\n(.-)\nend\n")
    assert(wch and wch:find("TP().partSave(key, item.name)", 1, true)
        and not wch:find("BookshelfSettings.save(key", 1, true), "the wallpaper picker writes Custom theme's key directly")
    local ob = io.open("lib/bookshelf_ornament_browser.lua"):read("*a")
    local tog = ob:match("\nfunction Browser:_toggle%(item%)\n(.-)\nend\n")
    assert(tog and tog:find("SW().setOff(", 1, true), "the ornament browser switches the collection directly")
    assert(ob:find('require("lib/bookshelf_theme_pack").switches()', 1, true), "the browser's switches are not the seam's")
    local tp = io.open("lib/bookshelf_theme_pack.lua"):read("*a")
    local cp = tp:match("\nfunction M%.choosePlank%(choice%)\n(.-)\nend\n")
    assert(cp and cp:find("M.partSave(M.PLANK_SETTING, v)", 1, true), "the plank picker writes Custom theme's key directly")
end)

t.test("the paint reads through the seam: colours, bars, chips, the page ground, invert", function()
    local cp = io.open("lib/bookshelf_cover_progress.lua"):read("*a")
    local own = cp:match("\nlocal function _readOwnColor%(base_key, default_day, default_night, suffix%)\n(.-)\nend\n")
    assert(own and own:find("_partRead(base_key .. suffix)", 1, true) and own:find("_partRead(base_key)", 1, true)
        and not own:find("BookshelfSettings.read", 1, true), "the colours read Custom theme's keys on a theme's shelf")
    local bars = cp:match("\nfunction M%.pickedBarColors%(%)\n(.-)\nend\n")
    assert(bars and bars:find('_partRead("progress_fill" .. suffix)', 1, true), "the hero bars read Custom theme's keys")
    local cb = io.open("lib/bookshelf_chip_bar.lua"):read("*a")
    local bar = cb:match("\nlocal function _readBarColor%(base_key%)\n(.-)\nend\n")
    assert(bar and bar:find("TP.partRead(k)", 1, true), "the selected shelf reads Custom theme's keys")
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    local ground = w:match("\nfunction BookshelfWidget:_pageGroundColor%(%)\n(.-)\nend\n")
    assert(ground and ground:find("TP.partRead(Wallpaper.BG_SETTING .. suffix)", 1, true),
        "the page ground reads Custom theme's key")
    local stored = w:match("\nfunction BookshelfWidget:_pageColourStored%(%)\n(.-)\nend\n")
    assert(stored and stored:find("TP.partRead(Wallpaper.BG_SETTING .. suffix)", 1, true),
        "the page colour's presence reads Custom theme's key")
    local wp = io.open("lib/bookshelf_wallpaper.lua"):read("*a")
    local inv = wp:match("\nfunction M%.invertsAtNight%(%)\n(.-)\nend\n")
    assert(inv and inv:find("TP.partRead(M.INVERT_NIGHT_SETTING)", 1, true), "invert at night reads Custom theme's key")
end)

t.test("no Own theme left: no card, no rows, no copy on choosing, the menu named for its theme", function()
    local set = io.open("lib/bookshelf_settings.lua"):read("*a")
    local code = set:gsub("%-%-[^\n]*", "")
    for _i, gone in ipairs({ "own_theme", "_ownRestartRow", "_ownDeleteRow", "ensureOwn", "restartOwn",
                             "deleteOwn", "TP.OWN", "ownerOf", "shownOwn" }) do
        assert(not code:find(gone, 1, true), "settings still has " .. gone)
    end
    for _i, f in ipairs({ "lib/bookshelf_theme_library.lua", "lib/bookshelf_chip_editor.lua" }) do
        local src = io.open(f):read("*a"):gsub("%-%-[^\n]*", "")
        assert(not src:find("own_theme", 1, true) and not src:find("ownName", 1, true)
            and not src:find("ensureOwn", 1, true), f .. " still knows the own theme")
    end
    local main = io.open("main.lua"):read("*a")
    assert(main:find("S:_themeMenuText()", 1, true)
        and set:find('T(_("Theme (%1)"), require("lib/bookshelf_theme_pack").editName())', 1, true),
        "the menu is not named for the theme it edits")
end)

-- withUI(fn): fn(seen) with KOReader's dialogs stubbed: what was shown.
local function withUI(fn)
    local names = { "ui/uimanager", "ui/widget/confirmbox", "ui/widget/infomessage",
                    "lib/bookshelf_wallpaper", "lib/bookshelf_ornaments", "ffi/util" }
    local had = {}
    for _i, n in ipairs(names) do had[n] = package.loaded[n] end
    local seen = { shown = {}, freed = 0 }
    package.loaded["ui/uimanager"] = { show = function(_u, w) seen.shown[#seen.shown + 1] = w end }
    package.loaded["ui/widget/confirmbox"] = { new = function(_c, o) o.kind = "confirm"; return o end }
    package.loaded["ui/widget/infomessage"] = { new = function(_c, o) o.kind = "info"; return o end }
    package.loaded["lib/bookshelf_wallpaper"] = { free = function() seen.freed = seen.freed + 1 end }
    package.loaded["lib/bookshelf_ornaments"] = { dir = function() return "settings/bookshelf/ornaments" end }
    package.loaded["ffi/util"] = {
        realpath = function(p) return "/mnt/us/koreader/" .. p end,
        template = function(f, ...)
            local a = { ... }
            return (f:gsub("%%(%d)", function(i) return tostring(a[tonumber(i)]) end))
        end,
    }
    local ok, err = pcall(fn, seen)
    for _i, n in ipairs(names) do package.loaded[n] = had[n] end
    assert(ok, err)
end

t.test("confirmReset asks first, then resets the theme and calls back; never Custom theme", function()
    -- Maintainer, 2026-10-09: the Theme library's footer Reset and a card's
    -- long-press ask the one question.
    local TP, d, settings, tabs = setup()
    world(d, settings)
    tabs.home = { id = "home", theme = "Macabre" }
    on(TP, "home")
    TP.partSave("ink_color", { hex = "#00FF00" })
    eq(TP.hasEdits("Macabre"), true)
    withUI(function(seen)
        local after = 0
        TP.confirmReset("Macabre", function() after = after + 1 end)
        local box = seen.shown[1]
        eq(box and box.kind, "confirm", "Reset did not ask first")
        eq(box.text, "Reset Macabre to its original settings? Your changes to it are lost.")
        eq(box.ok_text, "Reset")
        eq(TP.hasEdits("Macabre"), true, "the edits went before the question was answered")
        box.ok_callback()
        eq(TP.hasEdits("Macabre"), false, "Reset did not reset")
        -- The decode is keyed by its picture: freeing it blanked the
        -- wallpaper of a shelf on another theme until the next page turn.
        eq(seen.freed, 0, "Reset freed the wallpaper on screen")
        eq(after, 1, "what showed the edits was not told")
        TP.confirmReset("mine", function() after = after + 1 end)
        TP.confirmReset(nil)
        eq(#seen.shown, 1, "Custom theme was offered a reset to an original it does not have")
    end)
end)

t.test("Add theme pack says any theme can be edited and reset; the shop link stays a parameter", function()
    -- Maintainer, 2026-10-09, as Bookends' gallery help: "Once installed,
    -- you can edit each preset freely".
    local TP = setup()
    withUI(function(seen)
        TP.showAddThemeInfo()
        local msg = seen.shown[1]
        eq(msg and msg.kind, "info")
        assert(msg.text:find("You can edit any theme freely; your changes stay with it, and Reset brings back the original.", 1, true),
            "the popup does not say themes can be edited and reset")
        assert(msg.text:find("settings/bookshelf/ornaments", 1, true), "the folder is not named")
        assert(msg.text:find("ko%-fi%.com/andyhazz/shop$"), "the shop link is not the popup's last line")
    end)
    local src = io.open("lib/bookshelf_theme_pack.lua"):read("*a")
    assert(not src:find('_("[^"]*ko%-fi'), "the shop link is inside a msgid, where a translation can break it")
end)

t.done()
