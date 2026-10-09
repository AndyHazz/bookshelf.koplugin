-- tests/_test_shelf_theme_menu.lua
-- The Theme menu: ONE top-level menu named for the theme of the shelf on
-- screen, "Theme (Macabre)" (maintainer, 2026-10-09, after Bookends' "Preset
-- (Name)"). First This shelf (the Theme library for the shelf on screen) and
-- Default theme, then the rows that edit the theme on screen, Reset on a
-- pack or Plain, then every shelf with its theme, flat (maintainer,
-- 2026-10-07: no drill-down). Every theme is chosen in the Theme library
-- (bookshelf_theme_library, its own suite). Choosing writes ONE key and
-- nothing of the reader's own look. Built each time it opens, after a
-- rescan, and again when a Theme library opened from it closes.
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
    grab("\n(function Settings:_themeLibraryRow%(%).-\nend)\n", "_themeLibraryRow"),
    grab("\n(function Settings:_rebuildThemeMenu%(touchmenu_instance%).-\nend)\n", "_rebuildThemeMenu"),
    grab("\n(function Settings:_libraryThemeRow%(%).-\nend)\n", "_libraryThemeRow"),
    grab("\n(function Settings:_resetThemeRow%(%).-\nend)\n", "_resetThemeRow"),
    grab("\n(function Settings:_lightDarkRow%(%).-\nend)\n", "_lightDarkRow"),
    grab("\n(function Settings:_themeSubItems%(%).-\nend)\n", "_themeSubItems"),
    grab("\n(function Settings:_themeMenuText%(%).-\nend)\n", "_themeMenuText"),
    grab("\n(function Settings:_shelfThemeHelp%(%).-\nend)\n", "_shelfThemeHelp"),
    grab("\n(function Settings:_setShelfThemeField%(id, field, value%).-\nend)\n", "_setShelfThemeField"),
    grab("\n(function Settings:_shelfThemeLabelFor%(tab%).-\nend)\n", "_shelfThemeLabelFor"),
    grab("\n(function Settings:_openThemeLibrary%(id, touchmenu_instance, after%).-\nend)\n", "_openThemeLibrary"),
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
        -- The editing seam: the reader's own keys here (bookshelf_theme_pack
        -- has its own suite for the edits to a theme).
        partRead = function(k) return seen.store[k] end,
        partSave = function(k, v) seen.store[k] = v end,
        themeFor = function(id) return tabs_by[id] and tabs_by[id].theme or library or "mine" end,
        -- The edits to each theme (EDITABLE THEMES): opts.edited.
        hasEdits = function(th) return (opts.edited or {})[th] == true end,
        resetEdits = function(th)
            seen.reset = th
            if opts.edited then opts.edited[th] = nil end
        end,
        rescan = function() seen.rescans = seen.rescans + 1 end,
        mineName = function() return "Custom theme" end,
        addThemeLabel = function() return "Add theme pack\xE2\x80\xA6" end,
        showAddThemeInfo = function() seen.add_info = (seen.add_info or 0) + 1 end,
        packOf = function(v) if v == nil or v == "mine" or v == "plain" then return nil end return v end,
        theme = function(p) return { exists = by[p] ~= nil } end,
        themeName = function(v)
            if v == nil or v == "mine" or v == "none" then return "Custom theme" end
            if v == "plain" then return "Plain" end
            if not by[v] then return v .. " (missing)" end
            return by[v].name
        end,
        choices = function()
            local o = { { value = "mine", label = "Custom theme" }, { value = "plain", label = "Plain" } }
            for _i, p in ipairs(packs) do
                o[#o + 1] = { value = p.pack, help = p.description,
                              label = p.name }
            end
            return o
        end,
        libraryChoice = function() return library or "mine" end,
        setLibraryTheme = function(v)
            seen.chosen[#seen.chosen + 1] = v
            library = (v ~= "mine") and v or nil
        end,
        shelfTheme = function() return opts.on_screen or library or "mine" end,
        -- The question Reset asks (bookshelf_theme_pack's own suite pins it).
        confirmReset = function(th, after) seen.confirm = { theme = th, after = after } end,
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
    TP.editName = function() return TP.themeName(TP.shelfTheme()) end
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
        UIManager = { show = function(_u, w) seen.toasts[#seen.toasts + 1] = w.text; seen.shown = w end,
                      setDirty = function(_u, w, mode) if w == "all" and mode == "full" then seen.full = seen.full + 1 end end },
        require = function(m)
            if m == "lib/bookshelf_theme_pack" then return TP end
            if m == "lib/bookshelf_tab_model" then
                return { load = function() return tabs end, save = function(v) seen.saved = v end,
                         saveDeferred = function(v) seen.saved_deferred = v end,
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
            if m == "ui/widget/infomessage" or m == "ui/widget/confirmbox" then
                return { new = function(_s, o) return o end }
            end
            if m == "lib/bookshelf_wallpaper" then return { free = function() seen.freed = true end } end
            if m == "lib/bookshelf_ornaments" then return { dir = function() return "settings/bookshelf/ornaments" end } end
            if m == "ffi/util" then return { realpath = function(p) return "/mnt/us/koreader/" .. p end } end
            return require(m)
        end,
    }, { __index = _G })
    local chunk = assert((loadstring or load)(CODE, "=menu", "t", env))
    if setfenv then setfenv(chunk, env) end
    chunk()
    local self = setmetatable({ _markDirty = function() seen.dirty = seen.dirty + 1 end,
                                -- Rebuilt in place: the rows the build hands back.
                                _reopenSubMenu = function(_s, _tm, build)
                                    seen.reopened = (seen.reopened or 0) + 1
                                    seen.rebuilt = build()
                                end,
                                -- The editing rows, by name (their own suites).
                                _shelfSlot = function() seen.slot = true end,
                                _wallpaperMenu = function()
                                    return { { text = "Wallpaper" }, { text = "Full screen wallpaper" },
                                             { text = "Invert" }, { text = "Color behind wallpaper" } }
                                end,
                                _plankRow = function() return { text = "Plank" } end,
                                _ornamentsRow = function() return { text = "Ornaments" } end,
                                _newOrnamentsRow = function() return { text = "New ornaments go" } end,
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

local function onShelf(self, id) self._bw = { chip = id } return self end

-- rowOf(rows, prefix): the first row whose text starts so.
local function rowOf(rows, prefix)
    for _i, r in ipairs(rows) do
        local tx = r.text or (r.text_func and r.text_func()) or ""
        if tx:sub(1, #prefix) == prefix then return r end
    end
end

t.test("ONE Theme menu: This shelf, Default theme, the editing rows, Reset, then every shelf", function()
    -- Maintainer, 2026-10-09: the Theme menu and the My theme menu are one,
    -- as Bookends' "Preset (Name)" opens with "Preset library..." above the
    -- tweaks saved into the preset; the shelves stay flat (2026-10-07).
    local self, S, seen = build({ MAC, UK, AUT }, "Macabre", nil, { on_screen = "Macabre" })
    local rows = S._themeSubItems(onShelf(self, "home"))
    -- Maintainer, 2026-10-09: the two choosing rows named for what they
    -- set, and "Default theme" wherever a shelf follows it: "Theme library..."
    -- and "Library: My theme" opened the same picker, and "library" also
    -- named the picker itself.
    eq(texts(rows), "This shelf: Default theme | Default theme: Macabre | Light or dark: Auto (follow night mode)"
        .. " | Wallpaper | Full screen wallpaper | Invert | Color behind wallpaper | Plank | Ornaments | Colors"
        .. " | New ornaments go | Reset Macabre to original | Home: Default theme | Manga: Default theme")
    for _i, r in ipairs(rows) do
        local tx = r.text or (r.text_func and r.text_func()) or ""
        assert(not tx:lower():find("library", 1, true), "a row still says library: " .. tx)
    end
    local sep = {}
    for i, r in ipairs(rows) do if r.separator then sep[#sep + 1] = i end end
    eq(table.concat(sep, ","), "2,10,11,12", "the bands are not choosing | editing | preferences | Reset | shelves")
    eq(seen.rescans, 1, "opening the menu did not rescan the packs")
    eq(seen.slot, true, "the colour rows do not open on the slot of the shelf on screen")
    -- The choosing rows and the shelves open the Theme library, never a
    -- list to drill into.
    for _i, i in ipairs({ 1, 2, 13, 14 }) do
        eq(rows[i].radio, nil, "a radio list again")
        eq(rows[i].sub_item_table_func, nil, "a submenu to drill into again: " .. texts({ rows[i] }))
    end
end)

t.test("on a Custom theme shelf there is nothing to reset: no Reset row, the preferences end the editing", function()
    local self, S = build({ MAC }, nil, nil, { on_screen = "mine" })
    local rows = S._themeSubItems(onShelf(self, "home"))
    eq(rowOf(rows, "Reset "), nil, "Custom theme has a Reset to original row")
    local newat = rowOf(rows, "New ornaments go")
    eq(newat.separator, true, "the shelves are not set apart from the editing rows")
    eq(rows[#rows].text_func(), "Manga: Default theme")
end)

t.test("every editing row is on the first page of a PW5 menu (ten rows)", function()
    -- The rig's PW5-size TouchMenu shows ten rows a page (2026-10-09): the
    -- choosing rows and every row that edits a part of the theme fit on it.
    local self, S = build({ MAC }, "Macabre", nil, { on_screen = "Macabre" })
    local rows = S._themeSubItems(onShelf(self, "home"))
    local at
    for i, r in ipairs(rows) do if r.text == "Colors" then at = i end end
    assert(at and at <= 10, "the last editing row is row " .. tostring(at))
end)

t.test("This shelf opens the shelf on screen's picker, named for its own choice; rebuilt as it closes", function()
    local tabs = { { id = "home", label = "Home" }, { id = "rec", label = "Recent", theme = "plain" },
                   { id = "sub", label = "Sub", parent = "rec" } }
    local self, S, seen, by = build({ MAC, UK }, "Macabre", tabs)
    local row = S._themeLibraryRow(onShelf(self, "home"))
    eq(row.text_func(), "This shelf: Default theme"); eq(row.keep_menu_open, true)
    eq(S._themeLibraryRow(onShelf(self, "rec")).text_func(), "This shelf: Plain")
    eq(S._themeLibraryRow(onShelf(self, "sub")).text_func(), "This shelf: Plain",
        "a sub-shelf's row is not its shelf of shelves' choice")
    onShelf(self, "home")
    eq(row.sub_item_table_func, nil, "a radio submenu again")
    row.callback({})
    local o = seen.opened[1]
    assert(o, "the row did not open the Theme library"); eq(o.shelf, "Home")
    -- Its Default theme card is the one marked while the shelf follows.
    eq(o.current(), nil, "the shelf following the default is not Default theme in its picker")
    o.choose("mine")
    eq(by.home.theme, "mine"); eq(by.rec.theme, "plain", "another shelf changed")
    eq(seen.saves, 0, "the shelf's theme wrote the reader's own look")
    o.apply()
    eq(seen.dirty, 1, "the shelf was not rebuilt")
    o.on_closed(); eq(seen.restored, 1, "the menu did not come back")
    -- Its rows come back for the theme now on the shelf (they edit it, and
    -- only a pack or Plain has Reset to original).
    eq(seen.reopened, 1, "the Theme menu's rows were not rebuilt after the picker")
    assert(seen.rebuilt and rowOf(seen.rebuilt, "This shelf: "), "the rebuild is not the Theme menu")
    eq(rowOf(seen.rebuilt, "This shelf: ").text_func(), "This shelf: Custom theme", "the row does not follow the choice")
    S._themeLibraryRow(onShelf(self, "sub")).callback({})
    eq(seen.opened[2].shelf, "Recent", "a sub-shelf's row opened the sub-shelf's picker")
    self._bw = nil
    S._themeLibraryRow(self).callback({})
    eq(seen.opened[3].shelf, nil, "no shelf on screen: not the default's picker")
    eq(S._themeLibraryRow(self).text_func(), "This shelf: Default theme")
end)

t.test("Default theme opens the default's Theme library, and the menu follows as it closes", function()
    local self, S, seen = build({ MAC, UK, AUT }, "Macabre")
    local row = S._libraryThemeRow(self)
    eq(row.text_func(), "Default theme: Macabre"); eq(row.keep_menu_open, true); eq(row.radio, nil)
    row.callback({})
    local o = seen.opened[1]
    assert(o, "the Default theme row did not open the Theme library")
    eq(o.shelf, nil, "the default's picker opened as a shelf's")
    eq(o.current(), "Macabre")
    eq(seen.hidden, 1, "the menu stayed over the shelf"); o.on_closed(); eq(seen.restored, 1)
    eq(seen.reopened, 1, "a shelf following the default may show another theme: the rows were not rebuilt")
end)

t.test("choosing the default writes the default's theme and nothing else, and rebuilds the shelf", function()
    local self, S, seen = build({ MAC, UK }, nil)
    S._libraryThemeRow(self).callback({})
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

t.test("the top-level row is named for the theme on screen; the help says its rows edit it", function()
    local self, S = build({ MAC }, "Macabre", nil, { on_screen = "Macabre" })
    eq(S._themeMenuText(self), "Theme (Macabre)")
    local self2, S2 = build({ MAC }, nil, nil, { on_screen = "plain" })
    eq(S2._themeMenuText(self2), "Theme (Plain)")
    local self3, S3 = build({ MAC }, nil)
    eq(S3._themeMenuText(self3), "Theme (Custom theme)")
    local help = S3._shelfThemeHelp(self3)
    assert(help:find("Choosing a theme never changes Custom theme", 1, true))
    assert(help:find("The rows here edit the theme of the shelf on screen.", 1, true),
        "the help does not say what the editing rows edit")
end)

t.test("each enabled shelf is listed with its theme, a disabled one is not", function()
    local tabs = { { id = "home", label = "Home" }, { id = "manga", label = "Manga", theme = "Ukiyo-e" },
                   { id = "rec", label = "Recent", theme = "mine" }, { id = "x", label = "Off", enabled = false, theme = "plain" } }
    local self, S = build({ MAC, UK }, "Macabre", tabs)
    eq(texts(S._perShelfThemeRows(self)), "Home: Default theme | Manga: Ukiyo-e | Recent: Custom theme")
end)

t.test("a shelf's row opens that shelf's Theme library; a choice writes that shelf only", function()
    local tabs = { { id = "home", label = "Home" }, { id = "manga", label = "Manga", theme = "Ukiyo-e" } }
    local self, S, seen, by = build({ MAC, UK }, "Macabre", tabs)
    local rows = S._perShelfThemeRows(self)
    eq(rows[1].sub_item_table_func, nil, "a radio submenu again"); eq(rows[1].keep_menu_open, true)
    rows[1].callback({})
    local o = seen.opened[1]
    eq(o.shelf, "Home", "the picker is not titled for the shelf")
    eq(o.current(), nil, "a shelf with nothing of its own is Default theme")
    o.choose("plain")
    eq(by.home.theme, "plain", "Plain was not written to the shelf")
    eq(by.manga.theme, "Ukiyo-e", "another shelf changed")
    eq(seen.saves, 0, "choosing a shelf's theme wrote the reader's own look")
    o.apply()
    eq(seen.dirty, 1, "the shelf was not rebuilt")
    eq(o.current(), "plain")
    o.choose(nil)
    eq(by.home.theme, nil, "Default theme did not clear the shelf's own")
    o.on_closed()
    eq(seen.reopened, 1, "the rows above do not follow the shelf now on screen")
end)

t.test("while the Theme library is open a shelf's choice is kept in memory, written as it closes", function()
    -- Written per tap, the settings file cost ~60ms of every tap on a PW5
    -- (2026-10-08); the picker defers the ornaments' saves while open
    -- (Orn.beginDeferred) and flushes once on close.
    local self, S, seen, by = build({ MAC, UK }, "Macabre")
    S._perShelfThemeRows(self)[1].callback({})
    local o = seen.opened[1]
    local had = package.loaded["lib/bookshelf_ornaments"]
    package.loaded["lib/bookshelf_ornaments"] = { _defer = true }
    o.choose("plain")
    package.loaded["lib/bookshelf_ornaments"] = had
    eq(by.home.theme, "plain")
    eq(seen.saved, nil, "a tap wrote the settings file while the picker was open")
    assert(seen.saved_deferred, "the choice was not kept in memory")
    o.choose("Ukiyo-e")
    assert(seen.saved, "outside a picker the choice is not written at once")
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

t.test("Reset to original names the theme on screen, greyed while it has no edits, asks first", function()
    -- Maintainer, 2026-10-08: "Perhaps the reset button could be greyed out
    -- when the theme pack is already as original."
    local edited = {}
    local self, S, seen = build({ MAC }, nil, nil, { on_screen = "Macabre", edited = edited })
    local row = S._resetThemeRow(self)
    eq(row.text_func(), "Reset Macabre to original")
    eq(row.enabled_func(), false, "Reset is not greyed on a theme as original")
    edited.Macabre = true
    eq(row.enabled_func(), true, "Reset is greyed on an edited theme")
    local updated = 0
    row.callback({ updateItems = function() updated = updated + 1 end })
    -- The one question (TP.confirmReset), the one a card's long-press asks.
    eq(seen.confirm and seen.confirm.theme, "Macabre", "Reset did not ask about the theme on screen")
    eq(seen.dirty, 0, "the shelf was rebuilt before the question was answered")
    seen.confirm.after()
    eq(seen.dirty, 1, "the shelf was not rebuilt"); eq(updated, 1, "the menu's rows did not follow")
    eq(seen.full, 1, "no full refresh for the whole look changing")
    -- Plain resets the same way; Custom theme has nothing to reset to.
    local self2, S2 = build({ MAC }, nil, nil, { on_screen = "plain", edited = { plain = true } })
    eq(S2._resetThemeRow(self2).text_func(), "Reset Plain to original")
    eq(S2._resetThemeRow(self2).enabled_func(), true)
    local self3, S3, seen3 = build({ MAC }, nil, nil, { on_screen = "mine", edited = { mine = true } })
    eq(S3._resetThemeRow(self3).enabled_func(), false, "Custom theme can be reset to an original")
    S3._resetThemeRow(self3).callback({})
    eq(seen3.confirm, nil, "Custom theme was asked about a reset")
end)

t.test("the editing rows: no row greyed for a theme's part, Reset after them on a pack or Plain", function()
    local body = src:gsub("%-%-[^\n]*", "")
    local bg = body:match("function Settings:_themeSubItems%(%)(.-)\nend\n")
    assert(bg, "_themeSubItems moved")
    -- Every theme is editable: its rows are never greyed because the theme
    -- has that part (spec, 2026-10-08).
    assert(not bg:find("enabled_func", 1, true) and not body:find("_themeCovered", 1, true),
        "a row is greyed because the theme on screen has its part")
    local reset = bg:find("rows[#rows + 1] = self:_resetThemeRow()", 1, true)
    assert(reset and reset > bg:find("_newOrnamentsRow", 1, true), "Reset to original is not after the editing rows")
    assert(reset < bg:find("_perShelfThemeRows", 1, true), "Reset is not before the shelves")
    assert(bg:find("if TP.shelfTheme() ~= TP.MINE then", 1, true), "Custom theme has a Reset to original row")
end)

t.test("the two old menus are gone: no old This shelf row, no My theme menu, no second Theme menu", function()
    local body = src:gsub("%-%-[^\n]*", "")
    assert(not body:find("on this shelf)", 1, true), "a per-row suffix is back")
    assert(not src:find("covers this shelf", 1, true), "the info row is back")
    -- "This shelf: %1" is back, as the row that chooses the shelf on
    -- screen's theme (maintainer, 2026-10-09), not the old editing row.
    for _i, gone in ipairs({ "_thisShelfRow", "_backgroundSubItems", "_shelfThemeSubItems", "_shelfThemeText",
                             "shelfChoiceLabel", '"Same as library"', '"Library: %1"' }) do
        assert(not body:find(gone, 1, true), "settings still has " .. gone)
    end
    local tp = io.open("lib/bookshelf_theme_pack.lua"):read("*a"):gsub("%-%-[^\n]*", "")
    assert(not tp:find("shelfChoiceLabel", 1, true) and not tp:find("Same as library (%1)", 1, true),
        "the This shelf row's label is still in the theme packs")
end)

t.done()
