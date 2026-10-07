-- tests/_test_theme_library.lua
-- The Theme library (lib/bookshelf_theme_library): one card per theme, with
-- what it brings ("Wallpaper · Plank · 55 ornaments · Dark", only the parts it
-- has), its description and its hero ornament; the choice in use marked; a
-- missing pack listed but not chosen again. One picker for the library and
-- every shelf. Building the cards decodes nothing.
-- Usage (from plugin root): lua tests/_test_theme_library.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["logger"] = { dbg = function() end, info = function() end,
                             warn = function() end, err = function() end }
-- Source strings, whatever the machine's locale.
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq
local DOT = " \xC2\xB7 "

-- The theme scan, as bookshelf_theme_pack reports it.
local themes = {
    Macabre = { exists = true, wallpaper = { base = "wallpaper.png" }, planks = { { name = "Gothic Stone" } },
                manifest = { name = "Macabre", description = "Candles and skulls.", shelf = "dark",
                             hero = "munch - the scream" } },
    Planks  = { exists = true, planks = { {}, {}, {} } },
    Ukiyo   = { exists = true, colours = { day = {}, night = {} }, manifest = { name = "Ukiyo-e", shelf = "light" } },
    Autumn  = { exists = true, planks = {} },
}
local library, mine_wall, mine_plank = "mine", "forest.png", { name = "Oak" }
local TP = { MINE = "mine", PLAIN = "plain" }
function TP.theme(p) return themes[p] or { exists = false, planks = {} } end
function TP.packOf(v) if v == nil or v == "mine" or v == "plain" then return nil end return v end
function TP.mineWallpaper() return mine_wall end
function TP.minePlank() return mine_plank end
function TP.plankLabel(p) return p.name end
function TP.themeName(v)
    if v == nil or v == "mine" then return "My theme" end
    if v == "plain" then return "Plain" end
    if not themes[v] then return v .. " (missing)" end
    return (themes[v].manifest and themes[v].manifest.name) or v
end
function TP.choices()
    return { { value = "mine", label = "My theme" }, { value = "plain", label = "Plain" },
             { value = "Macabre", label = "Macabre" }, { value = "Ukiyo", label = "Ukiyo-e" },
             { value = "Autumn", label = "Autumn" } }
end
function TP.shelfChoices(cur)
    local o = { { same = true, label = "Same as library" } }
    if TP.packOf(cur) and not themes[cur] then o[#o + 1] = { value = cur, label = cur .. " (missing)", missing = true } end
    for _i, c in ipairs(TP.choices()) do o[#o + 1] = c end
    return o
end
function TP.libraryChoice() return library end
function TP.libraryTheme() return themes[library] and library or (TP.packOf(library) and "mine" or library) end
function TP.shelfChoiceLabel(v) if v == nil then return "Same as library (" .. TP.themeName(library) .. ")" end return TP.themeName(v) end
TP.rescans = 0
function TP.rescan() TP.rescans = TP.rescans + 1 end
function TP.addThemeLabel() return "Add theme pack\xE2\x80\xA6" end
function TP.showAddThemeInfo() TP.add_info = (TP.add_info or 0) + 1 end

-- The ornament scan: names and headers only. Rendering must not happen while
-- the cards are listed.
local function piece(pack, file) return { pack = pack, file = file, name = (pack and (pack .. "/") or "") .. file } end
local all = {}
for i = 1, 55 do all[#all + 1] = piece("Macabre", string.format("A%02d.png", i)) end
all[#all + 1] = piece("Macabre", "Munch - The Scream.png")
for i = 1, 27 do all[#all + 1] = piece("Autumn", string.format("B%02d.png", i)) end
all[#all + 1] = piece("Ukiyo", "Wave.png")
local on = { piece("Autumn", "B01.png"), piece(nil, "cactus.svg"), piece("Macabre", "A01.png") }
local listAll_calls = 0
local Orn = {
    listAll = function() listAll_calls = listAll_calls + 1; return all, { "Autumn", "Macabre", "Planks", "Ukiyo" } end,
    list = function() return on end,
    displayName = function(e) return (e.file:gsub("%.[^%.]+$", "")) end,
    render = function() error("an ornament was decoded while the cards were listed") end,
    contentBox = function() error("an ornament was probed while the cards were listed") end,
}
local TL = dofile("lib/bookshelf_theme_library.lua")
TL._tp, TL._orn = TP, Orn

t.test("a pack's summary names only the parts it has, its pieces counted", function()
    -- 56 = the 55 plus the hero
    eq(TL.summary("Macabre"), "Wallpaper" .. DOT .. "Plank" .. DOT .. "56 ornaments" .. DOT .. "Dark")
    eq(TL.summary("Planks"), "3 planks", "a pack of planks")
    eq(TL.summary("Ukiyo"), "Colors" .. DOT .. "1 ornament" .. DOT .. "Light")
    eq(TL.summary("Autumn"), "27 ornaments", "a pack of ornaments only says so by what it lists")
end)

t.test("light or dark only when the pack's theme.json says", function()
    eq(TL.summary("Autumn"):find("Dark", 1, true), nil)
    eq(TL.summary("Autumn"):find("Light", 1, true), nil)
end)

t.test("My theme is summed up from the reader's own settings; Plain is fixed", function()
    mine_wall, mine_plank = "forest.png", { name = "Oak" }
    eq(TL.summary("mine"), "Your wallpaper" .. DOT .. "Oak" .. DOT .. "3 ornaments")
    mine_wall, mine_plank = nil, nil
    local saved = on; on = {}
    eq(TL.summary("mine"), "No wallpaper" .. DOT .. "Plain color" .. DOT .. "No ornaments")
    on = saved; mine_wall, mine_plank = "forest.png", { name = "Oak" }
    eq(TL.summary("plain"), "No wallpaper" .. DOT .. "Oak" .. DOT .. "No ornaments")
    eq(TL.summary("Gone"), nil, "a missing pack has nothing to say")
end)

t.test("the hero: theme.json's (any case), else the pack's first piece; the reader's own loose piece; none for Plain", function()
    eq(TL.hero("Macabre").file, "Munch - The Scream.png")
    eq(TL.hero("Autumn").file, "B01.png", "no hero named: the first piece by name")
    eq(TL.hero("Planks"), nil, "a pack without pieces has no hero")
    eq(TL.hero("mine").file, "cactus.svg", "My theme shows a piece of the reader's own first")
    eq(TL.hero("plain"), nil)
end)

t.test("the library's cards: the reader's own, Plain, each theme; titled by name, described by theme.json", function()
    library = "Macabre"
    local items = TL.items{ current = "Macabre" }
    local titles = {}
    for i, it in ipairs(items) do titles[i] = it.title end
    eq(table.concat(titles, ","), "My theme,Plain,Macabre,Ukiyo-e,Autumn")
    eq(items[3].description, "Candles and skulls.")
    eq(items[1].description, nil); eq(items[5].description, nil)
    eq(items[5].summary, "27 ornaments")
    eq(TL.isCurrent(items[3], "Macabre"), true); eq(TL.isCurrent(items[1], "Macabre"), false)
    eq(TL.indexOf(items, "Macabre"), 3); eq(TL.indexOf(items, "nothing"), 1)
end)

t.test("a missing pack still chosen is listed first, marked, with nothing to show", function()
    local items = TL.items{ current = "Gone" }
    eq(items[1].title, "Gone (missing)"); eq(items[1].missing, true)
    eq(items[1].summary, nil); eq(TL.isCurrent(items[1], "Gone"), true)
    eq(#TL.items{ current = "Macabre" }, 5, "a missing pack listed when it is not the choice")
end)

t.test("a shelf's cards start with Same as library, which shows the library's theme", function()
    library = "Macabre"
    local items = TL.items{ shelf = "Home", current = nil }
    eq(items[1].same, true); eq(items[1].title, "Same as library (Macabre)")
    eq(items[1].shows, "Macabre"); eq(items[1].summary, TL.summary("Macabre"))
    eq(items[1].description, "Candles and skulls.")
    eq(TL.isCurrent(items[1], nil), true); eq(TL.isCurrent(items[2], nil), false)
    eq(TL.isCurrent(items[1], "mine"), false, "a shelf on My theme read as following the library")
    local gone = TL.items{ shelf = "Home", current = "Gone" }
    eq(gone[2].missing, true); eq(TL.indexOf(gone, "Gone"), 2)
end)

t.test("listing the cards decodes nothing: counts from the scan, heroes only at paint", function()
    -- Orn.render and Orn.contentBox raise here; every card of every kind
    -- is built without them.
    for _i, ctx in ipairs({ { current = "mine" }, { shelf = "Home" }, { current = "Gone" } }) do
        local ok, err = pcall(TL.items, ctx)
        assert(ok, tostring(err))
    end
end)

-- ── The picker ──────────────────────────────────────────────────────────
local shown, dirty = {}, {}
package.loaded["ui/uimanager"] = {
    show = function(_u, w) shown[#shown + 1] = w end,
    close = function(_u, w) w.closed = true; if w.config.on_closed then w.config.on_closed() end end,
    setDirty = function(_u, w, mode) dirty[#dirty + 1] = tostring(w) .. ":" .. tostring(mode) end,
}
package.loaded["device"] = { screen = { getWidth = function() return 1236 end, getHeight = function() return 1648 end,
                                        scaleBySize = function(_s, v) return math.floor(v * 1.875) end } }
package.loaded["lib/bookshelf_space"] = { px = function(v) return v end }
package.loaded["lib/bookshelf_library_modal"] = {
    rowsForShare = function() return 6 end,
    new = function(_c, o)
        o.refreshes = 0
        function o:refresh() self.refreshes = self.refreshes + 1 end
        o._dpad_idx = 1                     -- a keys device
        return o
    end,
}

local function open(opts)
    shown, dirty = {}, {}
    local m = TL.show(opts)
    return m, m.config
end

t.test("the library's picker: titled Theme, opens on the choice in use, Add theme pack and Close", function()
    library = "Autumn"
    local before = TP.rescans
    local m, c = open{ current = function() return library end, choose = function(v) library = v end }
    eq(TP.rescans, before + 1, "a pack copied in since start-up is not seen")
    eq(c.title, "Theme")
    eq(c.grid_cols(), 1, "one card per row")
    local per = c.cells_per_page()
    eq(m.page, math.ceil(5 / per), "not opened on the page of the choice in use")
    eq(m._dpad_idx, 5, "the keys' focus does not start on the choice in use")
    local f = c.footer_rows[1]
    eq(f[1].label, "Add theme pack\xE2\x80\xA6"); eq(f[2].label, "Close")
    f[1].on_tap(); eq(TP.add_info, 1)
    eq(shown[1], m)
end)

t.test("a tap chooses, refreshes the whole screen and moves the mark; the picker stays open", function()
    library = "mine"
    local chosen = {}
    local m, c = open{ current = function() return library end,
                       choose = function(v) chosen[#chosen + 1] = tostring(v); library = v end }
    c.on_cell_tap(c.item_at(3))
    eq(table.concat(chosen, ","), "Macabre")
    eq(dirty[#dirty], "all:full", "a theme is the whole look: one full refresh")
    eq(m.refreshes, 2, "the mark did not move")            -- one for the keys' focus, one now
    eq(m.closed, nil, "the picker closed on a choice")
    eq(m._dpad_idx, 3, "the keys' focus did not stay on the card chosen")
    c.on_cell_tap(c.item_at(3))
    eq(#chosen, 1, "choosing the theme in use again did something")
end)

t.test("a missing pack cannot be chosen again; once left it drops out of the list", function()
    library = "Gone"
    local chosen = 0
    local _m, c = open{ current = function() return library end,
                        choose = function(v) chosen = chosen + 1; library = v end }
    eq(c.item_at(1).missing, true)
    c.on_cell_tap(c.item_at(1)); eq(chosen, 0)
    c.on_cell_tap(c.item_at(3)); eq(chosen, 1)
    eq(c.item_count(), 5, "the missing pack is still listed after leaving it")
end)

t.test("a shelf's picker is titled for it, and Close brings the caller back once", function()
    local back = 0
    local m, c = open{ shelf = "Home", current = function() return nil end, choose = function() end,
                       on_closed = function() back = back + 1 end }
    eq(c.title, "Theme: Home")
    eq(c.item_at(1).same, true)
    c.footer_rows[1][2].on_tap()
    eq(m.closed, true); eq(back, 1)
end)

t.test("a card's hero is the ornaments' own cached render, through the collection's preview", function()
    local src = io.open("lib/bookshelf_theme_library.lua"):read("*a")
    local card = src:match("\nfunction TL%._renderCard%(item, dimen, current%)\n(.-)\nend\n")
    assert(card, "_renderCard moved")
    assert(card:find('require("lib/bookshelf_ornament_browser").preview(e, hero_w, inner_h)', 1, true),
        "the hero is not drawn as the collection draws a piece")
    assert(card:find("TL.hero(item.shows)", 1, true), "the card's hero is not its theme's")
    local ob = io.open("lib/bookshelf_ornament_browser.lua"):read("*a")
    local prev = ob:match("\nfunction Browser%.preview%(e, box_w, box_h%)\n(.-)\nend\n")
    assert(prev and prev:find("night = Screen.night_mode", 1, true), "the preview is not drawn for night mode")
    local crop = ob:match("\nfunction Cropped:paintTo%(bb, x, y%)\n(.-)\nend\n")
    assert(crop and crop:find("O().render(p.entry, p.w, p.h, self.night)", 1, true),
        "the preview does not use the ornaments' cached renderer")
end)

t.done()
