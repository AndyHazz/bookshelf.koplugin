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
    if v == nil or v == "mine" then return "Custom theme" end
    if v == "plain" then return "Plain" end
    if not themes[v] then return v .. " (missing)" end
    return (themes[v].manifest and themes[v].manifest.name) or v
end
function TP.choices()
    return { { value = "mine", label = "Custom theme" }, { value = "plain", label = "Plain" },
             { value = "Macabre", label = "Macabre" }, { value = "Ukiyo", label = "Ukiyo-e" },
             { value = "Autumn", label = "Autumn" } }
end
function TP.shelfChoices(cur)
    local o = { { same = true, label = "Default theme" } }
    if TP.packOf(cur) and not themes[cur] then o[#o + 1] = { value = cur, label = cur .. " (missing)", missing = true } end
    for _i, c in ipairs(TP.choices()) do o[#o + 1] = c end
    return o
end
function TP.libraryChoice() return library end
function TP.libraryTheme() return themes[library] and library or (TP.packOf(library) and "mine" or library) end
TP.rescans = 0
function TP.rescan() TP.rescans = TP.rescans + 1 end
function TP.addThemeLabel() return "Add theme pack\xE2\x80\xA6" end
function TP.showAddThemeInfo() TP.add_info = (TP.add_info or 0) + 1 end
-- The reader's edits to each theme (bookshelf_theme_pack EDITABLE THEMES).
local edits = {}
function TP.editsOf(th) return edits[th] end
function TP.hasEdits(th) return edits[th] ~= nil end

-- The ornament scan: names and headers only. Rendering must not happen while
-- the cards are listed.
local function piece(pack, file) return { pack = pack, file = file, name = (pack and (pack .. "/") or "") .. file,
                                          path = "/o/" .. (pack and (pack .. "/") or "") .. file } end
-- File times: B07 is Autumn's newest; the starter cactus is newer than
-- everything but switched off.
local mtimes = { ["/o/Autumn/B07.png"] = 300, ["/o/Autumn/B03.png"] = 200, ["/o/cactus.svg"] = 900,
                 ["/o/Macabre/A01.png"] = 100, ["/o/Autumn/B01.png"] = 50 }
local off = { ["cactus.svg"] = true }
package.loaded["libs/libkoreader-lfs"] = { attributes = function(p, what)
    if what == "modification" then return mtimes[p] or 1 end end }
local all = {}
for i = 1, 55 do all[#all + 1] = piece("Macabre", string.format("A%02d.png", i)) end
all[#all + 1] = piece("Macabre", "Munch - The Scream.png")
for i = 1, 27 do all[#all + 1] = piece("Autumn", string.format("B%02d.png", i)) end
all[#all + 1] = piece("Ukiyo", "Wave.png")
local on = { piece("Autumn", "B01.png"), piece(nil, "cactus.svg"), piece("Macabre", "A01.png") }
local listAll_calls = 0
local Orn = {
    -- The settings deferral (Orn.beginDeferred): written once on close.
    _defer = false, deferred = {},
    beginDeferred = function() local O = package.loaded["test/orn"]; O._defer = true; O.deferred[#O.deferred + 1] = "begin" end,
    endDeferred = function() local O = package.loaded["test/orn"]; O._defer = false; O.deferred[#O.deferred + 1] = "end" end,
    listAll = function() listAll_calls = listAll_calls + 1; return all, { "Autumn", "Macabre", "Planks", "Ukiyo" } end,
    list = function() return on end,
    displayName = function(e) return (e.file:gsub("%.[^%.]+$", "")) end,
    isOff = function(name) return off[name] == true end,
    render = function() error("an ornament was decoded while the cards were listed") end,
    contentBox = function() error("an ornament was probed while the cards were listed") end,
}
package.loaded["test/orn"] = Orn
local TL = dofile("lib/bookshelf_theme_library.lua")
TL._tp, TL._orn = TP, Orn

t.test("a pack's summary names only the parts it has, its pieces counted", function()
    -- 56 = the 55 plus the hero
    eq(TL.summary("Macabre"), "Wallpaper" .. DOT .. "Plank" .. DOT .. "56 ornaments" .. DOT .. "Dark")
    eq(TL.summary("Planks"), "3 planks", "a pack of planks")
    eq(TL.summary("Ukiyo"), "Colors" .. DOT .. "1 ornament" .. DOT .. "Light")
    eq(TL.summary("Autumn"), "27 ornaments", "a pack of ornaments only says so by what it lists")
end)

t.test("off Spines, a pack of ornaments only says where they show; nothing else does", function()
    -- Maintainer, 2026-10-08: Autumn chosen for a Covers shelf changed
    -- nothing to be seen, and its card did not say why.
    eq(TL.summary("Autumn", false), "27 ornaments (Spines shelves only)")
    eq(TL.summary("Autumn", true), "27 ornaments")
    eq(TL.summary("Autumn"), "27 ornaments", "no shelf to ask: no note")
    eq(TL.summary("Macabre", false), TL.summary("Macabre"), "a theme with other parts got the note")
    eq(TL.summary("Ukiyo", false), TL.summary("Ukiyo"), "a theme with colors got the note")
    eq(TL.summary("mine", false), TL.summary("mine")); eq(TL.summary("plain", false), TL.summary("plain"))
    local items = TL.items{ current = "mine", spines = false }
    eq(items[5].summary, "27 ornaments (Spines shelves only)", "the cards are not told the shelf's style")
end)

t.test("the shelf's style is asked of the shelf on screen", function()
    local S = { _bw = { _isSpineMode = function() return false end } }
    package.loaded["lib/bookshelf_settings"] = S
    eq(TL.spinesShown(), false)
    S._bw._isSpineMode = function() return true end
    eq(TL.spinesShown(), true)
    package.loaded["lib/bookshelf_settings"] = nil
    eq(TL.spinesShown(), nil, "no shelf: no answer")
end)

t.test("light or dark only when the pack's theme.json says", function()
    eq(TL.summary("Autumn"):find("Dark", 1, true), nil)
    eq(TL.summary("Autumn"):find("Light", 1, true), nil)
end)

t.test("Custom theme is summed up from the reader's own settings; Plain is fixed", function()
    mine_wall, mine_plank = "forest.png", { name = "Oak" }
    eq(TL.summary("mine"), "Your wallpaper" .. DOT .. "Oak" .. DOT .. "3 ornaments")
    mine_wall, mine_plank = nil, nil
    local saved = on; on = {}
    eq(TL.summary("mine"), "No wallpaper" .. DOT .. "Plain color" .. DOT .. "No ornaments")
    on = saved; mine_wall, mine_plank = "forest.png", { name = "Oak" }
    eq(TL.summary("plain"), "No wallpaper" .. DOT .. "Oak" .. DOT .. "No ornaments")
    eq(TL.summary("Gone"), nil, "a missing pack has nothing to say")
end)

t.test("the hero: theme.json's (any case), else the newest piece switched on; none for Plain", function()
    -- Maintainer, 2026-10-07: skip pieces switched off (the starter cacti) and
    -- show the most recently added or changed piece, not the first by name.
    TL._hero_cache = {}
    eq(TL.hero("Macabre").file, "Munch - The Scream.png")
    eq(TL.hero("Autumn").file, "B07.png", "no hero named: not the newest piece")
    eq(TL.hero("Planks"), nil, "a pack without pieces has no hero")
    eq(TL.hero("mine").file, "A01.png", "Custom theme showed a piece switched off, or not its newest on")
    eq(TL.hero("plain"), nil)
    -- A pack's pieces are switched in its own edited set (editable themes,
    -- 2026-10-08); the collection's switches are Custom theme's.
    off["Autumn/B07.png"] = true; TL._hero_cache = {}
    eq(TL.hero("Autumn").file, "B07.png", "the collection's switch reached a pack's hero")
    off["Autumn/B07.png"] = nil
    local set = {}
    for _i, e in ipairs(all) do if e.pack == "Autumn" and e.file ~= "B07.png" then set[e.name] = true end end
    edits.Autumn = { pieces = set }; TL._hero_cache = {}
    eq(TL.hero("Autumn").file, "B03.png", "a piece switched off is still the hero")
    edits.Macabre = { pieces = { ["Macabre/A01.png"] = true } }; TL._hero_cache = {}
    eq(TL.hero("Macabre").file, "A01.png", "the named hero is shown though switched off")
    -- Plain with pieces switched on deals them: its card shows one.
    edits.plain = { pieces = { ["Autumn/B03.png"] = true } }
    eq(TL.hero("plain").file, "B03.png", "Plain's edited set has no hero")
    edits.Autumn, edits.Macabre, edits.plain = nil, nil, nil; TL._hero_cache = {}
end)

t.test("a pack or Plain the reader has edited says Edited first; Custom theme never does", function()
    edits.Macabre = { keys = { wallpaper_default = "leaves.png" } }
    eq(TL.summary("Macabre"), "Edited" .. DOT .. "Wallpaper" .. DOT .. "Plank" .. DOT .. "56 ornaments" .. DOT .. "Dark")
    edits.Autumn = { keys = { progress_fill = { hex = "#00AA00" } } }
    eq(TL.summary("Autumn", false), "Edited" .. DOT .. "27 ornaments (Spines shelves only)")
    edits.plain = { keys = {} }
    eq(TL.summary("plain"), "Edited" .. DOT .. "No wallpaper" .. DOT .. "Oak" .. DOT .. "No ornaments")
    edits.mine = { keys = {} }
    eq(TL.summary("mine"):find("Edited", 1, true), nil, "Custom theme says Edited")
    local items = TL.items{ current = "mine" }
    eq(items[3].summary:sub(1, 6), "Edited", "the card does not say Edited")
    edits.Macabre, edits.Autumn, edits.plain, edits.mine = nil, nil, nil, nil
    eq(TL.summary("Macabre"):find("Edited", 1, true), nil, "a theme reset still says Edited")
end)

t.test("the library's cards: the reader's own, Plain, each theme; titled by name, described by theme.json", function()
    library = "Macabre"
    local items = TL.items{ current = "Macabre" }
    local titles = {}
    for i, it in ipairs(items) do titles[i] = it.title end
    eq(table.concat(titles, ","), "Custom theme,Plain,Macabre,Ukiyo-e,Autumn")
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

t.test("a shelf's cards start with Default theme, which shows the default's theme", function()
    library = "Macabre"
    local items = TL.items{ shelf = "Home", current = nil }
    -- Maintainer, 2026-10-08: it read as a second "Custom theme" card. Named
    -- for following, the theme it follows first in its summary. "Default",
    -- not "library", the picker's own name (maintainer, 2026-10-09).
    eq(items[1].same, true); eq(items[1].title, "Default theme")
    eq(items[1].shows, "Macabre")
    eq(items[1].summary, "Uses: Macabre" .. DOT .. TL.summary("Macabre"))
    eq(items[1].description, "Candles and skulls.")
    eq(TL.isCurrent(items[1], nil), true); eq(TL.isCurrent(items[2], nil), false)
    eq(TL.isCurrent(items[1], "mine"), false, "a shelf on Custom theme read as following the default")
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
local shown, dirty, tasks = {}, {}, {}
package.loaded["ui/uimanager"] = {
    show = function(_u, w) shown[#shown + 1] = w end,
    close = function(_u, w) w.closed = true; if w.config.on_closed then w.config.on_closed() end end,
    setDirty = function(_u, w, mode) dirty[#dirty + 1] = tostring(w) .. ":" .. tostring(mode) end,
    scheduleIn = function(_u, secs, fn) tasks[#tasks + 1] = { secs = secs, fn = fn } end,
    tickAfterNext = function(_u, fn) tasks[#tasks + 1] = { secs = 0, after_paint = true, fn = fn } end,
    unschedule = function(_u, fn)
        for i = #tasks, 1, -1 do if tasks[i].fn == fn then table.remove(tasks, i) end end
    end,
}
-- runTasks() -> how many scheduled tasks ran (the UIManager's next turn).
local function runTasks()
    local due = tasks
    tasks = {}
    for _i, task in ipairs(due) do task.fn() end
    return #due
end
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
    shown, dirty, tasks = {}, {}, {}
    local m = TL.show(opts)
    return m, m.config
end

t.test("the default's picker: titled Default theme, opens on page 1 always, Add theme pack, Reset, Close", function()
    library = "Autumn"
    local before = TP.rescans
    local m, c = open{ current = function() return library end, choose = function(v) library = v end }
    eq(TP.rescans, before + 1, "a pack copied in since start-up is not seen")
    -- Named for what it sets, as its row is (maintainer, 2026-10-09).
    eq(c.title, "Default theme")
    eq(c.grid_cols(), 1, "one card per row")
    -- Maintainer, 2026-10-08: the built-ins stay in sight; the choice in use
    -- (Autumn, the fifth card) is marked on its own page.
    eq(c.cells_per_page() < 5, true)
    eq(m.page, 1, "not opened on the first page, where Custom theme and Plain are")
    eq(m._dpad_idx, 1, "the keys' focus started on a card that is not on the page")
    local f = c.footer_rows[1]
    -- Reset between them (maintainer, 2026-10-09).
    eq(#f, 3); eq(f[1].label, "Add theme pack\xE2\x80\xA6"); eq(f[2].label, "Reset"); eq(f[3].label, "Close")
    f[1].on_tap(); eq(TP.add_info, 1)
    eq(shown[1], m)
    library = "plain"
    local m2 = open{ current = function() return library end, choose = function(v) library = v end }
    eq(m2.page, 1); eq(m2._dpad_idx, 2, "the keys' focus does not start on the choice in use on page 1")
end)

t.test("three cards a page, the picker no taller than they need, the cards as tall as before", function()
    -- Maintainer, 2026-10-07: "shorter so we can see more behind, 3 instead of 5".
    local _m, c = open{ current = function() return library end, choose = function() end }
    eq(c.cells_per_page(), 3)
    -- The card the half-screen picker gave (6 rows of 64dp, 4 cards of ~84dp, at this scale).
    eq(TL.cardHeight(), 185, "a card's height changed")
    eq(c.area_height(1000), 3 * 185 + 2 * 10, "the cards' area is not three cards and their gaps")
    eq(c.anchor, nil, "the picker is not centred")
    local lm = io.open("lib/bookshelf_library_modal.lua"):read("*a")
    assert(lm:find("if self.config.area_height then area_height = self.config.area_height(cw) end", 1, true),
        "the modal ignores the caller's area height")
end)

t.test("a tap chooses and moves the mark, then the shelf behind is rebuilt; the picker stays open", function()
    library = "mine"
    local chosen, built = {}, {}
    local m, c = open{ current = function() return library end,
                       choose = function(v) chosen[#chosen + 1] = tostring(v); library = v end,
                       apply = function() built[#built + 1] = library end }
    c.on_cell_tap(c.item_at(3))
    eq(table.concat(chosen, ","), "Macabre")
    eq(m.refreshes, 2, "the mark did not move")            -- one for the keys' focus, one now
    eq(m._dpad_idx, 3, "the keys' focus did not stay on the card chosen")
    eq(#built, 0, "the shelf was rebuilt before the mark could show")
    eq(tasks[1] and tasks[1].secs, TL.APPLY_DELAY, "the shelf behind is not rebuilt after a tap")
    runTasks()
    eq(table.concat(built, ","), "Macabre", "the shelf behind did not follow the choice while the picker is open")
    eq(dirty[#dirty], "all:full", "a theme is the whole look: one full refresh, the picker repainted over it")
    eq(m.closed, nil, "the picker closed on a choice")
    c.on_cell_tap(c.item_at(3))
    eq(#chosen, 1, "choosing the theme in use again did something")
    eq(runTasks(), 0, "choosing the theme in use again rebuilt the shelf")
end)

t.test("a run of taps is one rebuild, for the last choice", function()
    library = "mine"
    local built = {}
    local _m, c = open{ current = function() return library end,
                        choose = function(v) library = v end,
                        apply = function() built[#built + 1] = library end }
    c.on_cell_tap(c.item_at(3)); c.on_cell_tap(c.item_at(4)); c.on_cell_tap(c.item_at(2))
    eq(#tasks, 1, "every tap queued a rebuild of its own")
    runTasks()
    eq(table.concat(built, ","), "plain", "not one rebuild for the last choice")
    local full = 0
    for _i, d in ipairs(dirty) do if d == "all:full" then full = full + 1 end end
    eq(full, 1, "more than one full refresh for a run of taps")
end)

t.test("a choice still waiting is applied when the picker closes, before the caller comes back", function()
    library = "mine"
    local order = {}
    local m, c = open{ current = function() return library end,
                       choose = function(v) library = v end,
                       apply = function() order[#order + 1] = "apply:" .. tostring(library) end,
                       on_closed = function() order[#order + 1] = "back" end }
    c.on_cell_tap(c.item_at(3))
    c.footer_rows[1][3].on_tap()
    eq(m.closed, true)
    eq(table.concat(order, ","), "apply:Macabre,back", "the menu came back before the shelf followed the choice")
    eq(runTasks(), 0, "a rebuild was left waiting after the picker closed")
end)

t.test("taps keep the choice in memory; the settings are written once, as the picker closes", function()
    -- Measured on a PW5, 2026-10-08: every tap wrote the 125 KB settings
    -- file (~60ms). Deferred as the ornament collection does, flushed on
    -- every way out (on_closed: Close, the X, Back, a tap outside).
    library = "mine"
    -- Pickers opened above were never closed.
    Orn.deferred, Orn._defer = {}, false
    local order = {}
    local m, c = open{ current = function() return library end,
                       choose = function(v) library = v; order[#order + 1] = "choose:" .. tostring(Orn._defer) end,
                       apply = function() order[#order + 1] = "apply" end,
                       on_closed = function() order[#order + 1] = "back:" .. tostring(Orn._defer) end }
    eq(table.concat(Orn.deferred, ","), "begin", "the picker does not defer the settings while open")
    c.on_cell_tap(c.item_at(3)); c.on_cell_tap(c.item_at(4))
    m.config.on_closed()
    eq(table.concat(order, ","), "choose:true,choose:true,apply,back:true",
        "the choices were written before the shelf followed them")
    -- Written once the close has painted, not in its way (~115ms on a PW5).
    eq(table.concat(Orn.deferred, ","), "begin", "the write held up the close")
    eq(#tasks, 1); eq(tasks[1].after_paint, true, "the write is not left for after the close's paint")
    runTasks()
    eq(table.concat(Orn.deferred, ","), "begin,end", "the settings were not written as the picker closed")
    m.config.on_closed(); runTasks()
    eq(table.concat(Orn.deferred, ","), "begin,end", "a second close ended the deferral again")
    -- Opened while something else defers (the collection), it is not ours to end.
    Orn.deferred = {}; Orn._defer = true
    local m2 = open{ current = function() return library end, choose = function() end }
    m2.config.on_closed()
    eq(#Orn.deferred, 0, "the picker ended a deferral it did not begin")
    Orn._defer = false
end)

t.test("a suspend or KOReader's autosave while the picker is open writes its choices", function()
    -- The picker writes as it closes; a Kindle frame switch after a
    -- suspend can kill KOReader before it does.
    local src = io.open("lib/bookshelf_widget.lua"):read("*a")
    local at = src:find("\nlocal function flushOpenPickers%(%)\n")
    local body = src:match("\nlocal function flushOpenPickers%(%)\n(.-)\nend\n")
    assert(at and body, "flushOpenPickers moved")
    assert(body:find("Orn and Orn._defer", 1, true) and body:find("BookshelfSettings.flush()", 1, true),
        "the open picker's choices are not flushed")
    for _i, name in ipairs({ "onSuspend", "onFlushSettings" }) do
        local s0 = src:find("\nfunction BookshelfWidget:" .. name .. "%(%)\n")
        local fn = src:match("\nfunction BookshelfWidget:" .. name .. "%(%)\n(.-)\nend\n")
        assert(fn and fn:find("flushOpenPickers()", 1, true), name .. " does not land an open picker's choices")
        assert(s0 > at, name .. " is above the local it calls")
    end
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
    c.footer_rows[1][3].on_tap()
    eq(m.closed, true); eq(back, 1)
end)

t.test("a card's hero is the ornaments' own cached render, through the collection's preview", function()
    local src = io.open("lib/bookshelf_theme_library.lua"):read("*a")
    local card = src:match("\nfunction TL%._renderCard%(item, dimen, current, all%)\n(.-)\nend\n")
    assert(card, "_renderCard moved")
    assert(card:find('require("lib/bookshelf_ornament_browser").preview(e, hero_w, inner_h)', 1, true),
        "the hero is not drawn as the collection draws a piece")
    assert(card:find("TL.hero(item.shows, all)", 1, true), "the card's hero is not its theme's")
    local ob = io.open("lib/bookshelf_ornament_browser.lua"):read("*a")
    local prev = ob:match("\nfunction Browser%.preview%(e, box_w, box_h%)\n(.-)\nend\n")
    assert(prev and prev:find("night = Screen.night_mode", 1, true), "the preview is not drawn for night mode")
    local crop = ob:match("\nfunction Cropped:paintTo%(bb, x, y%)\n(.-)\nend\n")
    assert(crop and crop:find("O().render(p.entry, p.w, p.h, self.night)", 1, true),
        "the preview does not use the ornaments' cached renderer")
end)

t.test("the ornaments are scanned once per open, not per card, page or tap", function()
    -- Measured on a PW5, 2026-10-08: listAll walks every ornament folder
    -- (~28ms) before answering from its cache, and the cards asked it 18
    -- times for each open and again for each tap.
    library = "mine"
    local scans_seen = {}
    local choices0, shelf0 = TP.choices, TP.shelfChoices
    TP.choices = function(scan) scans_seen[#scans_seen + 1] = scan; return choices0() end
    TP.shelfChoices = function(cur, scan) scans_seen[#scans_seen + 1] = scan; return shelf0(cur) end
    local render0 = TL._renderCard
    -- The card as the picker paints it, its widgets aside: the hero asked of
    -- the scan it is handed.
    TL._renderCard = function(item, _dimen, _current, all) return TL.hero(item.shows, all) end
    listAll_calls = 0
    local _m, c = open{ current = function() return library end, choose = function(v) library = v end }
    for i = 1, c.item_count() do TL._hero_cache = {}; c.cell_renderer(c.item_at(i), {}) end
    c.on_cell_tap(c.item_at(3)); c.on_cell_tap(c.item_at(4))
    for i = 1, c.item_count() do TL._hero_cache = {}; c.cell_renderer(c.item_at(i), {}) end
    eq(listAll_calls, 1, "the ornaments were scanned again by a card, a page or a tap")
    eq(#scans_seen >= 3 and scans_seen[1] ~= nil and scans_seen[1] == scans_seen[#scans_seen], true,
        "the theme list is not handed the picker's scan")
    listAll_calls = 0
    local _m2, c2 = open{ shelf = "Home", current = function() return nil end, choose = function() end }
    eq(listAll_calls, 1, "a shelf's picker scanned more than once")
    eq(c2.item_at(1).same, true)
    -- Listed on its own (no picker), the cards share one scan.
    listAll_calls = 0
    TL.items{ current = "mine" }
    eq(listAll_calls, 1, "items() scanned per card")
    TP.choices, TP.shelfChoices, TL._renderCard = choices0, shelf0, render0
end)

t.test("the choice in use is a heavier frame on a light ground, not a radio mark", function()
    -- Maintainer, 2026-10-07: the radio mark did not look good on a card.
    local src = io.open("lib/bookshelf_theme_library.lua"):read("*a")
    local card = src:match("function TL%._renderCard%(.-\nend\n")
    assert(card, "_renderCard moved")
    assert(not card:find("Marks.Radio", 1, true), "the radio mark is back")
    assert(card:find("current and Size.border.thick or Size.border.thin", 1, true), "no heavier frame for the choice in use")
    assert(card:find("current and Blitbuffer.Color8(0xEE)", 1, true), "no light ground for the choice in use")
end)

t.test("the footer's Reset: the marked theme, greyed unless an edited pack or Plain, asked first", function()
    -- Maintainer, 2026-10-09: Reset left the Theme menu for the picker's
    -- footer, between Add theme pack and Close, acting on the theme marked.
    local asked = {}
    TP.confirmReset = function(th, after) asked[#asked + 1] = { theme = th, after = after } end
    local on_screen = "Macabre"
    TP.shelfTheme = function() return on_screen end
    library = "Macabre"
    local built = 0
    local m, c = open{ current = function() return library end, choose = function(v) library = v end,
                       apply = function() built = built + 1 end }
    local reset = c.footer_rows[1][2]
    eq(reset.key, "reset")
    -- As original: greyed, and a tap (keys can still reach it) does nothing.
    eq(reset.enabled_when(), false, "Reset is not greyed on a theme as original")
    reset.on_tap(); eq(#asked, 0, "a greyed Reset asked")
    edits.Macabre = { keys = { wallpaper_default = "leaves.png" } }
    eq(reset.enabled_when(), true, "Reset is greyed on the marked theme, edited")
    m.refreshes = 0
    reset.on_tap()
    eq(asked[1] and asked[1].theme, "Macabre", "Reset did not ask about the marked theme")
    eq(m.refreshes, 0, "the cards were redrawn before the question was answered")
    edits.Macabre = nil                                -- what confirmReset's OK does
    asked[1].after()
    eq(c.item_at(3).summary:find("Edited", 1, true), nil, "the card still says Edited")
    eq(m.refreshes, 1, "the card and the footer were not redrawn at once")
    eq(reset.enabled_when(), false, "Reset is not greyed once reset")
    local full = 0
    for _i, d in ipairs(dirty) do if d == "all:full" then full = full + 1 end end
    eq(full, 0, "a full refresh before the shelf behind was rebuilt (a second flash)")
    runTasks()
    eq(built, 1, "the shelf behind showing that theme did not follow")
    eq(dirty[#dirty], "all:full", "no full refresh for the whole look changing")
    full = 0
    for _i, d in ipairs(dirty) do if d == "all:full" then full = full + 1 end end
    eq(full, 1, "more than one full refresh for a reset")
    -- Plain, edited, marked: Reset. The shelf behind on another theme: left
    -- alone.
    library = "plain"; edits.plain = { keys = {} }; on_screen = "Ukiyo"
    eq(reset.enabled_when(), true)
    reset.on_tap(); eq(asked[2].theme, "plain")
    edits.plain = nil; asked[2].after()
    eq(runTasks(), 0, "the shelf behind was rebuilt for a theme it does not show")
    -- Custom theme (no original) and Default theme (it stands for another
    -- card): greyed, even when the reader has changed things.
    edits.mine = { keys = {} }; edits.Macabre = { keys = {} }
    library = "mine"
    eq(reset.enabled_when(), false, "Custom theme offered a reset")
    local _m2, c2 = open{ shelf = "Home", current = function() return nil end, choose = function() end }
    eq(c2.footer_rows[1][2].enabled_when(), false, "the Default theme card offered a reset")
    c2.footer_rows[1][2].on_tap(); eq(#asked, 2, "a greyed Reset asked")
    -- A shelf's picker, its own pack marked and edited: Reset.
    local _m3, c3 = open{ shelf = "Home", current = function() return "Macabre" end, choose = function() end }
    eq(c3.footer_rows[1][2].enabled_when(), true)
    edits.mine, edits.Macabre = nil, nil
    TP.confirmReset, TP.shelfTheme = nil, nil
end)

t.test("LibraryModal greys a footer button whose enabled_when says so, and a press on it does nothing", function()
    -- The keys' focus can rest on it (the footer is a row of Buttons), but
    -- its callback runs only while enabled.
    local lm = io.open("lib/bookshelf_library_modal.lua"):read("*a")
    assert(lm:find("if action.enabled_when then enabled = action.enabled_when() end", 1, true),
        "the footer ignores enabled_when")
    assert(lm:find("callback = function() if enabled then action.on_tap() end end,", 1, true)
        and lm:find("enabled = enabled,", 1, true), "a greyed footer button still acts")
    local tl = io.open("lib/bookshelf_theme_library.lua"):read("*a")
    assert(tl:find('{ key = "add", label = tp.addThemeLabel()', 1, true)
        < tl:find('{ key = "reset", label = _("Reset"),', 1, true)
        and tl:find('{ key = "reset", label = _("Reset"),', 1, true) < tl:find('{ key = "close", label = _("Close")', 1, true),
        "Reset is not between Add theme pack and Close")
end)

t.test("a long-press on a pack's or Plain's card offers Reset to original, greyed unless it is edited", function()
    -- Maintainer, 2026-10-09, as a long-press on a Bookends preset opens its
    -- Manage dialog: Reset on the card, asked first (TP.confirmReset, the
    -- Theme menu's question); the card loses Edited, and the shelf behind
    -- follows when it shows that theme.
    package.loaded["ui/widget/buttondialog"] = { new = function(_c, o) o.config = {}; o.dialog = true; return o end }
    local asked = {}
    TP.confirmReset = function(th, after) asked[#asked + 1] = { theme = th, after = after } end
    local on_screen = "Macabre"
    TP.shelfTheme = function() return on_screen end
    library = "mine"
    local built = 0
    local m, c = open{ current = function() return library end, choose = function(v) library = v end,
                       apply = function() built = built + 1 end }
    assert(c.cell_long_tap, "a card has no long-press")
    edits.Macabre = { keys = { wallpaper_default = "leaves.png" } }
    m.refreshes = 0
    local mac = c.item_at(3)
    eq(mac.title, "Macabre")
    c.cell_long_tap(mac)
    local d = shown[#shown]
    assert(d and d.dialog, "the long-press showed no dialog")
    eq(d.title, "Macabre", "the dialog does not say which theme")
    local b = d.buttons[1][1]
    eq(#d.buttons, 1); eq(b.text, "Reset to original")
    eq(b.enabled, true, "Reset is greyed on an edited theme")
    b.callback()
    eq(d.closed, true, "the dialog stayed over the question")
    eq(asked[1] and asked[1].theme, "Macabre", "Reset did not ask about that card's theme")
    edits.Macabre = nil                                -- what confirmReset's OK does
    asked[1].after()
    eq(c.item_at(3).summary:find("Edited", 1, true), nil, "the card still says Edited")
    eq(m.refreshes, 1, "the cards were not redrawn")
    runTasks()
    eq(built, 1, "the shelf behind showing that theme did not follow")
    eq(dirty[#dirty], "all:full")
    -- Unedited: greyed. Plain: the same dialog. The shelf behind on another
    -- theme: left alone.
    c.cell_long_tap(c.item_at(3))
    eq(shown[#shown].buttons[1][1].enabled, false, "Reset is not greyed on a theme as original")
    edits.plain = { keys = {} }
    on_screen = "Ukiyo"
    c.cell_long_tap(c.item_at(2))
    eq(shown[#shown].title, "Plain"); eq(shown[#shown].buttons[1][1].enabled, true)
    shown[#shown].buttons[1][1].callback()
    edits.plain = nil
    asked[#asked].after()
    eq(runTasks(), 0, "the shelf behind was rebuilt for a theme it does not show")
    -- Custom theme (no original), Default theme (it stands for another card)
    -- and a missing pack: nothing.
    local n = #shown
    eq(c.item_at(1).value, "mine")
    c.cell_long_tap(c.item_at(1))
    eq(#shown, n, "Custom theme's card showed a dialog")
    local _m2, c2 = open{ shelf = "Home", current = function() return nil end, choose = function() end }
    n = #shown
    eq(c2.item_at(1).same, true)
    c2.cell_long_tap(c2.item_at(1))
    eq(TL.showReset({ value = "Gone", missing = true, title = "Gone (missing)" }), nil)
    eq(#shown, n, "a card with nothing to reset showed a dialog")
    eq(TL.showReset({ value = "mine", title = "Custom theme" }), nil, "Custom theme offered a reset")
    TP.confirmReset, TP.shelfTheme = nil, nil
    package.loaded["ui/widget/buttondialog"] = nil
end)

t.done()
