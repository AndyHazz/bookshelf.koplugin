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
    grab("\n(function Settings:_themeShelfOnScreen%(%).-\nend)\n", "_themeShelfOnScreen"),
    grab("\n(function Settings:_themeLibraryRow%(%).-\nend)\n", "_themeLibraryRow"),
    grab("\n(function Settings:_rebuildThemeMenu%(touchmenu_instance%).-\nend)\n", "_rebuildThemeMenu"),
    grab("\n(function Settings:_libraryThemeRow%(%).-\nend)\n", "_libraryThemeRow"),
    grab("\n(function Settings:_lightDarkRow%(%).-\nend)\n", "_lightDarkRow"),
    grab("\n(function Settings:_themeSubItems%(%).-\nend)\n", "_themeSubItems"),
    grab("\n(function Settings:_themeMenuText%(%).-\nend)\n", "_themeMenuText"),
    grab("\n(function Settings:_shelfThemeHelp%(%).-\nend)\n", "_shelfThemeHelp"),
    grab("\n(function Settings:_setShelfThemeField%(id, field, value%).-\nend)\n", "_setShelfThemeField"),
    grab("\n(function Settings:_shelfThemeLabelFor%(tab%).-\nend)\n", "_shelfThemeLabelFor"),
    grab("\n(function Settings:_openThemeLibrary%(id, touchmenu_instance, after%).-\nend)\n", "_openThemeLibrary"),
    grab("\n(function Settings:_perShelfThemeRows%(skip%).-\nend)\n", "_perShelfThemeRows"),
    grab("\n(function Settings:_otherShelvesRow%(%).-\nend)\n", "_otherShelvesRow"),
}, "\n")

-- build(packs, library, tabs, opts) -> the menu's rows and what the stubs saw.
-- packs: { pack, name, description }
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
        libraryChoice = function() return library or "mine" end,
        setLibraryTheme = function(v)
            seen.chosen[#seen.chosen + 1] = v
            library = (v ~= "mine") and v or nil
        end,
        shelfTheme = function() return opts.on_screen or library or "mine" end,
        -- The question Reset asks (bookshelf_theme_pack's own suite pins it).
        confirmReset = function(th, after) seen.confirm = { theme = th, after = after } end,
        -- As bookshelf_theme_pack normalises: a reserved name that is not
        -- exactly a built-in's id is no theme.
        ownChoice = function(id)
            local v = tabs_by[id] and tabs_by[id].theme
            if v == "none" then v = "mine" end
            if type(v) == "string" and v ~= "mine" and v ~= "plain"
                and ({ mine = 1, plain = 1, none = 1, own = 1 })[v:lower()] then v = nil end
            return v
        end,
    }
    TP.editName = function() return TP.themeName(TP.shelfTheme()) end
    TP.choiceLabel = function(v) if v == nil then return "Default theme" end return TP.themeName(v) end
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
                             for _i, tb in ipairs(tabs) do if tb.enabled ~= false and not tb.parent then on[#on + 1] = tb end end
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
                                _wallpaperRow = function()
                                    return { text = "Wallpaper", sub_item_table_func = function() return {} end }
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

local MAC = { pack = "Macabre", name = "Macabre", description = "Candles and skulls." }
local UK  = { pack = "Ukiyo-e", name = "Ukiyo-e" }
local AUT = { pack = "Autumn", name = "Autumn" }

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

t.test("ONE Theme menu, one page: This shelf, Other shelves, Default theme, then the editing rows", function()
    -- Maintainer, 2026-10-09: the Theme menu and the My theme menu are one,
    -- as Bookends' "Preset (Name)" opens with "Preset library..." above the
    -- tweaks saved into the preset; the shelves stay flat (2026-10-07).
    local self, S, seen = build({ MAC, UK, AUT }, "Macabre", nil, { on_screen = "Macabre" })
    local rows = S._themeSubItems(onShelf(self, "home"))
    -- Maintainer, 2026-10-09: the two choosing rows named for what they
    -- set, and "Default theme" wherever a shelf follows it: "Theme library..."
    -- and "Library: My theme" opened the same picker, and "library" also
    -- named the picker itself.
    -- Maintainer, 2026-10-09: the other shelves a level down, below This
    -- shelf, so the menu fits one page.
    eq(texts(rows), "This shelf: Default theme | Other shelves: all default | Default theme: Macabre"
        .. " | Light or dark: Auto (follow night mode)"
        .. " | Wallpaper | Plank | Ornaments | Colors | New ornaments go")
    for _i, r in ipairs(rows) do
        local tx = r.text or (r.text_func and r.text_func()) or ""
        assert(not tx:lower():find("library", 1, true), "a row still says library: " .. tx)
    end
    local sep = {}
    for i, r in ipairs(rows) do if r.separator then sep[#sep + 1] = i end end
    eq(table.concat(sep, ","), "3,8", "the bands are not choosing | editing | preferences")
    eq(seen.rescans, 1, "opening the menu did not rescan the packs")
    eq(seen.slot, true, "the colour rows do not open on the slot of the shelf on screen")
    -- The choosing rows open the Theme library, never a list to drill
    -- into; Other shelves is the submenu of the shelves' rows.
    for _i, i in ipairs({ 1, 3 }) do
        eq(rows[i].radio, nil, "a radio list again")
        eq(rows[i].sub_item_table_func, nil, "a submenu to drill into again: " .. texts({ rows[i] }))
    end
    assert(rows[2].sub_item_table_func, "Other shelves is not a submenu")
    for _i, r in ipairs(rows) do
        local tx = r.text or (r.text_func and r.text_func()) or ""
        assert(not tx:find("^Home: ") and not tx:find("^Manga: "), "a shelf's row is flat in the menu again: " .. tx)
    end
end)

t.test("no Reset row on any shelf, an edited pack's included: Reset is in the Theme library", function()
    -- Maintainer, 2026-10-09: Reset moves to the Theme library's footer.
    for _i, th in ipairs({ "Macabre", "plain", "mine" }) do
        local self, S = build({ MAC }, nil, nil, { on_screen = th, edited = { [th] = true } })
        local rows = S._themeSubItems(onShelf(self, "home"))
        eq(rowOf(rows, "Reset "), nil, "a Reset row in the Theme menu on " .. th)
        eq(rows[#rows].text, "New ornaments go", "the menu does not end with the preferences")
    end
end)

t.test("the whole Theme menu is one page of a PW5 menu (ten rows), whatever the shelves", function()
    -- The rig's PW5-size TouchMenu shows ten rows a page (2026-10-09); the
    -- maintainer wants the whole menu on it (2026-10-09).
    local many = {}
    for i = 1, 12 do many[i] = { id = "s" .. i, label = "S" .. i, theme = (i % 2 == 0) and "plain" or nil } end
    local self, S = build({ MAC }, "Macabre", many, { on_screen = "Macabre" })
    local rows = S._themeSubItems(onShelf(self, "s1"))
    assert(#rows <= 10, "the Theme menu is " .. #rows .. " rows: " .. texts(rows))
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
    -- No shelf on screen: no This shelf row (it read "This shelf: Default
    -- theme" and opened the default's picker, review 2026-10-09).
    self._bw = nil
    local rows = S._themeSubItems(self)
    eq(rowOf(rows, "This shelf"), nil, "a This shelf row with no shelf on screen")
    assert(rowOf(rows, "Default theme: "), "the Default theme row went with it")
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
    assert(not ce:find("TP.choiceList", 1, true), "Shelf style builds its own theme list again")
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
    eq(texts(S._perShelfThemeRows(self, "manga")), "Home: Default theme | Recent: Custom theme",
        "the shelf skipped is listed")
    -- Named as the count and This shelf read the shelf (ownChoice), not
    -- from the raw stored value.
    local by_raw = { { id = "a", label = "A", theme = "OWN" } }
    local self2, S2 = build({ UK }, nil, by_raw)
    eq(texts(S2._perShelfThemeRows(self2)), "A: Default theme", "a shelf's row reads the raw stored theme")
end)

t.test("Other shelves: every shelf but the one on screen, counted by those with a theme of their own", function()
    -- Maintainer, 2026-10-09: "Other shelves: 2 with own themes", or "all
    -- default" when none, the shelves' rows a level down.
    local tabs = { { id = "home", label = "Home" }, { id = "manga", label = "Manga", theme = "Ukiyo-e" },
                   { id = "rec", label = "Recent", theme = "mine" }, { id = "x", label = "Off", enabled = false, theme = "plain" },
                   { id = "sub", label = "Sub", parent = "manga", theme = "plain" } }
    local self, S, _seen, by = build({ MAC, UK }, "Macabre", tabs)
    local row = S._otherShelvesRow(onShelf(self, "home"))
    eq(row.text_func(), "Other shelves: 2 with own themes")
    eq(row.enabled_func(), true)
    eq(texts(row.sub_item_table_func()), "Manga: Ukiyo-e | Recent: Custom theme")
    -- The shelf on screen is This shelf's, not counted or listed here; a
    -- sub-shelf on screen is its shelf of shelves.
    onShelf(self, "manga")
    eq(row.text_func(), "Other shelves: 1 with own theme")
    eq(texts(row.sub_item_table_func()), "Home: Default theme | Recent: Custom theme")
    onShelf(self, "sub")
    eq(texts(row.sub_item_table_func()), "Home: Default theme | Recent: Custom theme",
        "a sub-shelf on screen lists its shelf of shelves as another shelf")
    by.rec.theme = nil
    eq(row.text_func(), "Other shelves: all default")
    -- No shelf on screen: all of them.
    self._bw = nil
    eq(texts(row.sub_item_table_func()), "Home: Default theme | Manga: Ukiyo-e | Recent: Default theme")
    -- One shelf, on screen: nothing to list, greyed.
    local self2, S2 = build({ MAC }, nil, { { id = "home", label = "Home", theme = "plain" } })
    local row2 = S2._otherShelvesRow(onShelf(self2, "home"))
    eq(row2.enabled_func(), false, "Other shelves is not greyed with no other shelf")
    eq(row2.text_func(), "Other shelves: all default")
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
    -- The menu comes back (its rows' names refreshed by the restore) on
    -- the same shelves: not rebuilt as the Theme menu's top level.
    eq(seen.restored, 1, "the menu did not come back")
    eq(seen.reopened, nil, "Other shelves' rows were rebuilt as another level")
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

t.test("the editing rows: no row greyed for a theme's part; no Reset row of the menu's own", function()
    local body = src:gsub("%-%-[^\n]*", "")
    local bg = body:match("function Settings:_themeSubItems%(%)(.-)\nend\n")
    assert(bg, "_themeSubItems moved")
    -- Every theme is editable: its rows are never greyed because the theme
    -- has that part (spec, 2026-10-08).
    assert(not bg:find("enabled_func", 1, true) and not body:find("_themeCovered", 1, true),
        "a row is greyed because the theme on screen has its part")
    -- Reset is the Theme library's (maintainer, 2026-10-09).
    assert(not body:find("_resetThemeRow", 1, true) and not body:find('"Reset %1 to original"', 1, true),
        "the Theme menu has its Reset row again")
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
