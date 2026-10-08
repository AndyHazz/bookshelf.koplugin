-- tests/_test_shelf_theme_menu.lua
-- The Theme menu (maintainer, 2026-10-07): the library's row, then every
-- library's row. Every theme is chosen in the Theme library
-- (bookshelf_theme_library, its own suite): the library's, each shelf's from
-- Each shelf and from My theme's This shelf row. Choosing writes ONE key and
-- nothing of the reader's own look. Built each time it opens, after a
-- rescan, so a pack copied in since start-up is counted.
-- Usage (from plugin root): lua tests/_test_shelf_theme_menu.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq
local src = io.open("lib/bookshelf_settings.lua"):read("*a")

local function grab(pat, what)
    local body = src:match(pat)
    assert(body, what .. " not found")
    return body
end
local CODE = table.concat({
    grab("\n(Settings%.SHELF_THEMES = {.-\n})\n", "SHELF_THEMES"),
    grab("\n(function Settings:_shelfTheme%(%).-\nend)\n", "_shelfTheme"),
    grab("\n(function Settings:_shelfThemeLabel%(%).-\nend)\n", "_shelfThemeLabel"),
    grab("\n(function Settings:_thisShelfRow%(%).-\nend)\n", "_thisShelfRow"),
    grab("\n(function Settings:_themeCovered%(part%).-\nend)\n", "_themeCovered"),
    grab("\n(function Settings:_lightDarkRow%(%).-\nend)\n", "_lightDarkRow"),
    grab("\n(function Settings:_shelfThemeSubItems%(%).-\nend)\n", "_shelfThemeSubItems"),
    grab("\n(function Settings:_shelfThemeText%(%).-\nend)\n", "_shelfThemeText"),
    grab("\n(function Settings:_shelfThemeHelp%(%).-\nend)\n", "_shelfThemeHelp"),
    grab("\n(function Settings:_setShelfThemeField%(id, field, value%).-\nend)\n", "_setShelfThemeField"),
    grab("\n(function Settings:_shelfThemeLabelFor%(tab%).-\nend)\n", "_shelfThemeLabelFor"),
    grab("\n(function Settings:_openThemeLibrary%(id, touchmenu_instance%).-\nend)\n", "_openThemeLibrary"),
    grab("\n(function Settings:_perShelfThemeRows%(%).-\nend)\n", "_perShelfThemeRows"),
}, "\n")

-- build(packs, library, tabs, opts) -> the menu's rows and what the stubs saw.
-- packs: { pack, name, description, ornaments_only, brings = { part = true } }
local function build(packs, library, tabs, opts)
    opts = opts or {}
    local seen = { rescans = 0, chosen = {}, toasts = {}, dirty = 0, full = 0, store = {}, saves = 0,
                   opened = {}, hidden = 0, restored = 0 }
    tabs = tabs or { { id = "home", label = "Home" }, { id = "manga", label = "Manga" } }
    local tabs_by = {}
    for _i, tb in ipairs(tabs) do tabs_by[tb.id] = tb end
    local by = {}
    for _i, p in ipairs(packs) do by[p.pack] = p end
    local TP = {
        MINE = "mine", PLAIN = "plain",
        rescan = function() seen.rescans = seen.rescans + 1 end,
        mineName = function() return "My theme" end,
        addThemeLabel = function() return "Add theme pack\xE2\x80\xA6" end,
        showAddThemeInfo = function() seen.add_info = (seen.add_info or 0) + 1 end,
        packOf = function(v) if v == nil or v == "mine" or v == "plain" then return nil end return v end,
        theme = function(p) return { exists = by[p] ~= nil } end,
        themeName = function(v)
            if v == nil or v == "mine" or v == "none" then return "My theme" end
            if v == "plain" then return "Plain" end
            if not by[v] then return v .. " (missing)" end
            return by[v].name
        end,
        choices = function()
            local o = { { value = "mine", label = "My theme" }, { value = "plain", label = "Plain" } }
            for _i, p in ipairs(packs) do
                o[#o + 1] = { value = p.pack, help = p.description,
                              label = p.name }
            end
            return o
        end,
        libraryChoice = function() return library or "mine" end,
        shelfChoiceLabel = function(v)
            if v == nil then return "Same as library (" .. (library and by[library] and by[library].name or library or "My theme") .. ")" end
            if v == "mine" then return "My theme" end
            if v == "plain" then return "Plain" end
            return by[v] and by[v].name or (v .. " (missing)")
        end,
        setLibraryTheme = function(v)
            seen.chosen[#seen.chosen + 1] = v
            library = (v ~= "mine") and v or nil
        end,
        shelfTheme = function() return opts.on_screen or library or "mine" end,
        ownChoice = function(id)
            local v = tabs_by[id] and tabs_by[id].theme
            if v == "none" then v = "mine" end
            return v
        end,
        brings = function(th, part)
            if th == "mine" then return false end
            if th == "plain" then return part ~= "look" end
            return by[th] and by[th].brings and by[th].brings[part] or false
        end,
    }
    TP.shelfChoices = function(cur)
        local o = { { same = true, label = "Same as library" } }
        if cur and cur ~= "mine" and cur ~= "plain" and not by[cur] then
            o[#o + 1] = { value = cur, label = cur .. " (missing)", missing = true }
        end
        for _i, c in ipairs(TP.choices()) do o[#o + 1] = c end
        return o
    end
    local env = setmetatable({
        Settings = {},
        _ = function(s) return s end,
        T = function(f, ...)
            local a = { ... }
            return (f:gsub("%%(%d)", function(i) return tostring(a[tonumber(i)]) end))
        end,
        BookshelfSettings = { read = function(k) return seen.store[k] end,
                              save = function(k, v) seen.store[k] = v; seen.saves = seen.saves + 1 end,
                              flush = function() end },
        UIManager = { show = function(_u, w) seen.toasts[#seen.toasts + 1] = w.text end,
                      setDirty = function(_u, w, mode) if w == "all" and mode == "full" then seen.full = seen.full + 1 end end },
        require = function(m)
            if m == "lib/bookshelf_theme_pack" then return TP end
            if m == "lib/bookshelf_tab_model" then
                return { load = function() return tabs end, save = function(v) seen.saved = v end,
                         getActive = function()
                             local on = {}
                             for _i, tb in ipairs(tabs) do if tb.enabled ~= false then on[#on + 1] = tb end end
                             return on
                         end,
                         getById = function(id) return tabs_by[id] end,
                         rootOf = function(id)
                             local tb = tabs_by[id]
                             while tb and tb.parent and tabs_by[tb.parent] do tb = tabs_by[tb.parent] end
                             return tb and tb.id or id
                         end }
            end
            if m == "lib/bookshelf_theme_library" then
                return { show = function(o) seen.opened[#seen.opened + 1] = o; return o end }
            end
            if m == "lib/bookshelf_cover_progress" then return { THEME_SETTING = "shelf_theme" } end
            if m == "ui/widget/infomessage" then return { new = function(_s, o) return o end } end
            if m == "lib/bookshelf_ornaments" then return { dir = function() return "settings/bookshelf/ornaments" end } end
            if m == "ffi/util" then return { realpath = function(p) return "/mnt/us/koreader/" .. p end } end
            return require(m)
        end,
    }, { __index = _G })
    local chunk = assert((loadstring or load)(CODE, "=menu", "t", env))
    if setfenv then setfenv(chunk, env) end
    chunk()
    local self = setmetatable({ _markDirty = function() seen.dirty = seen.dirty + 1 end,
                                _hidePickerMenu = function()
                                    seen.hidden = seen.hidden + 1
                                    return function() seen.restored = seen.restored + 1 end
                                end },
                              { __index = env.Settings })
    return self, env.Settings, seen, tabs_by
end

local MAC = { pack = "Macabre", name = "Macabre", description = "Candles and skulls.",
              brings = { wallpaper = true, plank = true, look = true, ornaments = true } }
local UK  = { pack = "Ukiyo-e", name = "Ukiyo-e" }
local AUT = { pack = "Autumn", name = "Autumn", brings = { ornaments = true } }

local function texts(rows)
    local o = {}
    for i, r in ipairs(rows) do o[i] = r.text or (r.text_func and r.text_func()) or "?" end
    return table.concat(o, " | ")
end

t.test("the Theme menu: the library's row (set apart), then every shelf with its theme", function()
    -- Maintainer, 2026-10-07: one level, no Each shelf submenu to drill into.
    local self, S, seen = build({ MAC, UK, AUT }, "Macabre")
    local rows = S._shelfThemeSubItems(self)
    eq(texts(rows), "Library: Macabre | Home: Same as library | Manga: Same as library")
    eq(rows[1].separator, true, "the library's row is not set apart")
    eq(seen.rescans, 1, "opening the menu did not rescan the packs")
    eq(rows[1].radio, nil, "a radio list again"); eq(rows[1].keep_menu_open, true)
    for _i, r in ipairs(rows) do eq(r.sub_item_table_func, nil, "a submenu to drill into again") end
    rows[1].callback({})
    local o = seen.opened[1]
    assert(o, "the library's row did not open the Theme library")
    eq(o.shelf, nil, "the library's picker opened as a shelf's")
    eq(o.current(), "Macabre")
    eq(seen.hidden, 1, "the menu stayed over the shelf"); o.on_closed(); eq(seen.restored, 1)
end)

t.test("choosing for the library writes the library's theme and nothing else, and rebuilds the shelf", function()
    local self, S, seen = build({ MAC, UK }, nil)
    S._shelfThemeSubItems(self)[1].callback({})
    local o = seen.opened[1]
    eq(o.current(), "mine")
    o.choose("Macabre")
    eq(table.concat(seen.chosen, ","), "Macabre")
    eq(seen.saves, 0, "choosing a theme wrote a setting of the reader's own look")
    eq(seen.dirty, 0, "a choice rebuilt the shelf itself (the picker asks, once a run of taps settles)")
    o.apply()
    eq(seen.dirty, 1, "the shelf was not rebuilt")
    eq(o.current(), "Macabre", "the picker's mark does not follow the choice")
    eq(#seen.toasts, 0, "a toast over the picker again")
    o.choose("mine"); eq(seen.chosen[2], "mine")
end)

t.test("no theme list of its own in any menu: no radio rows, no Add theme pack row", function()
    local body = src:gsub("%-%-[^\n]*", "")
    assert(not body:find("_themeRadios", 1, true) and not body:find("_oneShelfThemeItems", 1, true),
        "a menu builds its own theme list again")
    assert(not body:find("TP.addThemeLabel()", 1, true), "Add theme pack is a menu row again (it is the picker's)")
    local ce = io.open("lib/bookshelf_chip_editor.lua"):read("*a"):gsub("%-%-[^\n]*", "")
    assert(not ce:find("TP.shelfChoices", 1, true), "Shelf style builds its own theme list again")
end)

t.test("the top-level row names the library's theme; the help names the reader's own", function()
    local self, S = build({ MAC }, "Macabre")
    eq(S._shelfThemeText(self), "Theme: Macabre")
    local self2, S2 = build({ MAC }, nil)
    eq(S2._shelfThemeText(self2), "Theme: My theme")
    assert(S2._shelfThemeHelp(self2):find("Choosing a theme never changes My theme", 1, true))
end)

t.test("each enabled shelf is listed with its theme, a disabled one is not", function()
    local tabs = { { id = "home", label = "Home" }, { id = "manga", label = "Manga", theme = "Ukiyo-e" },
                   { id = "rec", label = "Recent", theme = "mine" }, { id = "x", label = "Off", enabled = false, theme = "plain" } }
    local self, S = build({ MAC, UK }, "Macabre", tabs)
    local rows = S._shelfThemeSubItems(self)
    eq(texts(rows), "Library: Macabre | Home: Same as library | Manga: Ukiyo-e | Recent: My theme")
end)

t.test("a shelf's row opens that shelf's Theme library; a choice writes that shelf only", function()
    local tabs = { { id = "home", label = "Home" }, { id = "manga", label = "Manga", theme = "Ukiyo-e" } }
    local self, S, seen, by = build({ MAC, UK }, "Macabre", tabs)
    local rows = S._perShelfThemeRows(self)
    eq(rows[1].sub_item_table_func, nil, "a radio submenu again"); eq(rows[1].keep_menu_open, true)
    rows[1].callback({})
    local o = seen.opened[1]
    eq(o.shelf, "Home", "the picker is not titled for the shelf")
    eq(o.current(), nil, "a shelf with nothing of its own is Same as library")
    o.choose("plain")
    eq(by.home.theme, "plain", "Plain was not written to the shelf")
    eq(by.manga.theme, "Ukiyo-e", "another shelf changed")
    eq(seen.saves, 0, "choosing a shelf's theme wrote the reader's own look")
    o.apply()
    eq(seen.dirty, 1, "the shelf was not rebuilt")
    eq(o.current(), "plain")
    o.choose(nil)
    eq(by.home.theme, nil, "Same as library did not clear the shelf's own")
end)

t.test("rc/5.4's 'none' reads as the reader's own in a shelf's picker", function()
    local tabs = { { id = "a", label = "A", theme = "none" } }
    local self, S, seen = build({ UK }, nil, tabs)
    S._perShelfThemeRows(self)[1].callback({})
    eq(seen.opened[1].current(), "mine")
end)

t.test("opening another shelf's picker shows that shelf behind it", function()
    local self, S, seen = build({ UK }, nil)
    local switched
    self._bw = { chip = "home", _setActiveChip = function(_bw, id) switched = id end }
    local rows = S._perShelfThemeRows(self)
    rows[2].callback({})
    eq(switched, "manga"); eq(seen.opened[1].shelf, "Manga")
end)

t.test("Light or dark: Auto (follow night mode), Light, Dark; the theme's own named when it sets it", function()
    local self, S, seen = build({ MAC }, nil)
    local row = S._lightDarkRow(self)
    eq(row.text_func(), "Light or dark: Auto (follow night mode)")
    local sub = row.sub_item_table_func()
    eq(texts(sub), "Auto (follow night mode) | Light | Dark")
    sub[3].callback()
    eq(seen.store.shelf_theme, "dark")
    local self2, S2 = build({ MAC }, nil, nil, { on_screen = "Macabre" })
    eq(S2._lightDarkRow(self2).text_func(), "Light or dark: Auto (follow night mode)",
        "a theme on screen puts a suffix on the row again")
end)

local function onShelf(self, id) self._bw = { chip = id } return self end

t.test("My theme's first row names what the shelf on screen wears and opens its theme list", function()
    local tabs = { { id = "home", label = "Home" }, { id = "rec", label = "Recent", theme = "plain" },
                   { id = "sub", label = "Sub", parent = "rec" } }
    local self, S, seen, by = build({ MAC, UK }, "Macabre", tabs)
    local row = S._thisShelfRow(onShelf(self, "home"))
    eq(row.text_func(), "This shelf: Same as library (Macabre)")
    eq(row.separator, true)
    eq(row.sub_item_table_func, nil, "a radio submenu again")
    row.callback({})
    local o = seen.opened[1]
    assert(o, "the row did not open the Theme library"); eq(o.shelf, "Home")
    o.choose("mine")
    eq(by.home.theme, "mine"); eq(by.rec.theme, "plain", "another shelf changed")
    eq(seen.saves, 0, "the shelf's theme wrote the reader's own look")
    o.apply()
    eq(seen.dirty, 1, "the shelf was not rebuilt")
    o.on_closed(); eq(seen.restored, 1, "the menu did not come back")
    eq(row.text_func(), "This shelf: My theme", "the row did not follow the choice")
    eq(S._thisShelfRow(onShelf(self, "rec")).text_func(), "This shelf: Plain")
    local sub = S._thisShelfRow(onShelf(self, "sub"))
    eq(sub.text_func(), "This shelf: Plain",
        "a sub-shelf wears its shelf of shelves' theme: the row is that shelf's")
    sub.callback({}); eq(seen.opened[2].shelf, "Recent", "a sub-shelf's row opened the sub-shelf's picker")
    self._bw = nil
    eq(S._thisShelfRow(self), nil, "no shelf on screen: no row")
end)

t.test("a row of the reader's own is greyed while the theme on screen replaces its part", function()
    local AUT2 = { pack = "Autumn", name = "Autumn", brings = { ornaments = true } }
    local self, S = build({ MAC, AUT2 }, nil, nil, { on_screen = "Autumn" })
    eq(S._themeCovered(self, "ornaments")(), false, "Autumn deals its own pieces")
    eq(S._themeCovered(self, "wallpaper")(), true, "Autumn brings no wallpaper")
    local self2, S2 = build({ MAC }, nil, nil, { on_screen = "plain" })
    for _i, part in ipairs({ "wallpaper", "page", "plank", "ornaments", "colours" }) do
        eq(S2._themeCovered(self2, part)(), false, "Plain covers " .. part)
    end
    eq(S2._themeCovered(self2, "look")(), true, "Plain follows the reader's light or dark")
    local self3, S3 = build({ MAC }, nil, nil, { on_screen = "mine" })
    eq(S3._themeCovered(self3, "wallpaper")(), true)
end)

t.test("My theme: This shelf first; every part row greys with its part; New ornaments go with Ornaments", function()
    local body = src:gsub("%-%-[^\n]*", "")
    local bg = body:match("function Settings:_backgroundSubItems%(%)(.-)\nend\n")
    assert(bg, "_backgroundSubItems moved")
    assert(bg:find("self:_thisShelfRow()", 1, true) < bg:find("_lightDarkRow", 1, true), "This shelf is not first")
    for _i, pair in ipairs({ { "_lightDarkRow%(%)", "look" }, { "_plankRow%(%)", "plank" },
                             { "_ornamentsRow%(%)", "ornaments" }, { "_newOrnamentsRow%(%)", "ornaments" } }) do
        assert(bg:find("part%(self:" .. pair[1] .. ", \"" .. pair[2] .. "\"%)"), pair[1] .. " is not tagged " .. pair[2])
    end
    assert(bg:find('}, "colours")', 1, true), "Colors is not tagged")
    assert(bg:find("row.enabled_func = self:_themeCovered(row._part)", 1, true), "the tags grey nothing")
    local wm = body:match("function Settings:_wallpaperMenu%(%)(.-)\nend\n")
    local _a, nw = wm:gsub('_part = "wallpaper"', "")
    local _b, np = wm:gsub('_part = "page"', "")
    eq(nw, 3, "Wallpaper, Full screen wallpaper and Invert are the wallpaper part"); eq(np, 1)
end)

t.test("no row of the reader's own carries a per-row theme suffix any more", function()
    local body = src:gsub("%-%-[^\n]*", "")
    assert(not body:find("on this shelf)", 1, true), "a per-row suffix is back")
    local bg = body:match("function Settings:_backgroundSubItems%(%)(.-)\nend\n")
    assert(bg and bg:find("self:_thisShelfRow()", 1, true), "the This shelf row is not in the menu")
    assert(not src:find("covers this shelf", 1, true), "the info row is back")
end)

t.done()
