-- tests/_test_shelf_theme_menu.lua
-- The Theme menu (maintainer, 2026-10-07): Each shelf first, then the
-- library's theme -- the reader's own, Plain, each theme -- then Get more
-- themes. Choosing a theme writes ONE key and nothing of the reader's own
-- look; a shelf's menu is one radio list starting with Same as library. Built
-- each time it opens, after a rescan, so a pack copied in since start-up shows.
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
    grab("\n(Settings%.COVER_PARTS = {.-\n})\n", "COVER_PARTS"),
    grab("\n(function Settings:_themeCoverRow%(%).-\nend)\n", "_themeCoverRow"),
    grab("\n(function Settings:_lightDarkRow%(%).-\nend)\n", "_lightDarkRow"),
    grab("\n(function Settings:_shelfThemeSubItems%(%).-\nend)\n", "_shelfThemeSubItems"),
    grab("\n(function Settings:_shelfThemeText%(%).-\nend)\n", "_shelfThemeText"),
    grab("\n(function Settings:_shelfThemeHelp%(%).-\nend)\n", "_shelfThemeHelp"),
    grab("\n(function Settings:_setShelfThemeField%(id, field, value%).-\nend)\n", "_setShelfThemeField"),
    grab("\n(function Settings:_shelvesDiffer%(%).-\nend)\n", "_shelvesDiffer"),
    grab("\n(function Settings:_shelfThemeLabelFor%(tab%).-\nend)\n", "_shelfThemeLabelFor"),
    grab("\n(function Settings:_themeRadios%(checked, choose%).-\nend)\n", "_themeRadios"),
    grab("\n(function Settings:_oneShelfThemeItems%(id%).-\nend)\n", "_oneShelfThemeItems"),
    grab("\n(function Settings:_perShelfThemesRow%(%).-\nend)\n", "_perShelfThemesRow"),
}, "\n")

-- build(packs, library, tabs, opts) -> the menu's rows and what the stubs saw.
-- packs: { pack, name, description, ornaments_only, brings = { part = true } }
local function build(packs, library, tabs, opts)
    opts = opts or {}
    local seen = { rescans = 0, chosen = {}, toasts = {}, dirty = 0, full = 0, store = {}, saves = 0 }
    tabs = tabs or { { id = "home", label = "Home" }, { id = "manga", label = "Manga" } }
    local tabs_by = {}
    for _i, tb in ipairs(tabs) do tabs_by[tb.id] = tb end
    local by = {}
    for _i, p in ipairs(packs) do by[p.pack] = p end
    local TP = {
        MINE = "mine", PLAIN = "plain",
        rescan = function() seen.rescans = seen.rescans + 1 end,
        mineName = function() return "My theme" end,
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
                              label = p.ornaments_only and (p.name .. " (ornaments only)") or p.name }
            end
            return o
        end,
        libraryChoice = function() return library or "mine" end,
        setLibraryTheme = function(v)
            seen.chosen[#seen.chosen + 1] = v
            library = (v ~= "mine") and v or nil
        end,
        shelfTheme = function() return opts.on_screen or library or "mine" end,
        brings = function(th, part)
            if th == "mine" then return false end
            if th == "plain" then return part ~= "look" end
            return by[th] and by[th].brings and by[th].brings[part] or false
        end,
    }
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
                         getById = function(id) return tabs_by[id] end }
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
    local self = setmetatable({ _markDirty = function() seen.dirty = seen.dirty + 1 end },
                              { __index = env.Settings })
    return self, env.Settings, seen, tabs_by
end

local MAC = { pack = "Macabre", name = "Macabre", description = "Candles and skulls.",
              brings = { wallpaper = true, plank = true, look = true, ornaments = true } }
local UK  = { pack = "Ukiyo-e", name = "Ukiyo-e" }
local AUT = { pack = "Autumn", name = "Autumn", ornaments_only = true, brings = { ornaments = true } }

local function texts(rows)
    local o = {}
    for i, r in ipairs(rows) do o[i] = r.text or (r.text_func and r.text_func()) or "?" end
    return table.concat(o, " | ")
end

t.test("the menu: Each shelf (set apart), the reader's own, Plain, each theme, then Get more themes", function()
    local self, S, seen = build({ MAC, UK, AUT }, nil)
    local rows = S._shelfThemeSubItems(self)
    eq(texts(rows), "Each shelf: all the same | My theme | Plain | Macabre | Ukiyo-e | Autumn (ornaments only)"
        .. " | Get more themes\xE2\x80\xA6")
    eq(rows[1].separator, true, "Each shelf is set apart")
    eq(rows[#rows - 1].separator, true, "Get more themes is set apart")
    eq(seen.rescans, 1, "opening the menu did not rescan the packs")
    eq(rows[2].checked_func(), true, "no library theme: the reader's own is checked")
    eq(rows[4].help_text, "Candles and skulls.", "a theme's description is its help")
end)

t.test("with no packs: the reader's own and Plain are still there", function()
    local self, S = build({}, nil)
    eq(texts(S._shelfThemeSubItems(self)), "Each shelf: all the same | My theme | Plain | Get more themes\xE2\x80\xA6")
end)

t.test("choosing a theme writes the library's theme and nothing else; the whole screen refreshes", function()
    local self, S, seen = build({ MAC, UK }, nil)
    local rows = S._shelfThemeSubItems(self)
    rows[4].callback()
    eq(table.concat(seen.chosen, ","), "Macabre")
    eq(seen.saves, 0, "choosing a theme wrote a setting of the reader's own look")
    eq(seen.full, 1, "a theme is the whole look: full refresh")
    eq(seen.toasts[1], "Macabre theme on")
    eq(rows[4].checked_func(), true)
    rows[4].callback()
    eq(#seen.chosen, 1, "choosing the checked theme again did something")
    rows[2].callback()
    eq(seen.chosen[2], "mine")
    eq(seen.toasts[2], "Theme off")
    rows[3].callback()
    eq(seen.toasts[3], "Plain theme on")
end)

t.test("a library theme whose pack has gone is listed, checked", function()
    local self, S = build({ UK }, "Macabre")
    local rows = S._shelfThemeSubItems(self)
    eq(rows[2].text, "Macabre (missing)")
    eq(rows[2].checked_func(), true)
end)

t.test("Get more themes says where theme packs go, and where to get them", function()
    local self, S, seen = build({}, nil)
    local rows = S._shelfThemeSubItems(self)
    rows[#rows].callback()
    assert(seen.toasts[1]:find("/mnt/us/koreader/settings/bookshelf/ornaments", 1, true), "no folder")
    assert(seen.toasts[1]:find("ko-fi.com/andyhazz/shop", 1, true), "no shop link")
end)

t.test("the top-level row names the library's theme; the help names the reader's own", function()
    local self, S = build({ MAC }, "Macabre")
    eq(S._shelfThemeText(self), "Theme: Macabre")
    local self2, S2 = build({ MAC }, nil)
    eq(S2._shelfThemeText(self2), "Theme: My theme")
    assert(S2._shelfThemeHelp(self2):find("Choosing a theme never changes My theme", 1, true))
end)

t.test("Each shelf counts the shelves with a theme of their own, and lists each", function()
    local tabs = { { id = "home", label = "Home" }, { id = "manga", label = "Manga", theme = "Ukiyo-e" },
                   { id = "rec", label = "Recent", theme = "mine" }, { id = "x", label = "Off", enabled = false, theme = "plain" } }
    local self, S = build({ MAC, UK }, "Macabre", tabs)
    local rows = S._shelfThemeSubItems(self)
    eq(rows[1].text_func(), "Each shelf: own theme on 2 of 3")
    eq(texts(rows[1].sub_item_table_func()), "Home: same as library | Manga: Ukiyo-e | Recent: My theme")
end)

t.test("a shelf's menu is one radio list: Same as library, the reader's own, Plain, each theme", function()
    local tabs = { { id = "home", label = "Home" } }
    local self, S, seen, by = build({ MAC, UK }, "Macabre", tabs)
    local rows = S._oneShelfThemeItems(self, "home")
    eq(texts(rows), "Same as library | My theme | Plain | Macabre | Ukiyo-e")
    for _i, r in ipairs(rows) do
        eq(r.radio, true, "a checkbox again: " .. tostring(r.text))
        eq(r.enabled_func, nil, "greyed rows again: " .. tostring(r.text))
    end
    eq(rows[1].checked_func(), true, "a shelf with nothing of its own is Same as library")
    eq(rows[4].checked_func(), false, "following the library is not the same as choosing its theme")
    rows[3].callback()
    eq(by.home.theme, "plain", "Plain was not written to the shelf")
    eq(seen.saves, 0, "choosing a shelf's theme wrote the reader's own look")
    eq(seen.full, 1)
    rows[1].callback()
    eq(by.home.theme, nil, "Same as library did not clear the shelf's own")
end)

t.test("rc/5.4's 'none' reads as the reader's own; a missing pack is listed, checked", function()
    local tabs = { { id = "a", label = "A", theme = "none" }, { id = "b", label = "B", theme = "Gone" } }
    local self, S = build({ UK }, nil, tabs)
    local a = S._oneShelfThemeItems(self, "a")
    eq(a[2].text, "My theme"); eq(a[2].checked_func(), true)
    local b = S._oneShelfThemeItems(self, "b")
    eq(b[2].text, "Gone (missing)"); eq(b[2].checked_func(), true)
end)

t.test("opening another shelf's theme menu shows that shelf behind it", function()
    local self, S = build({ UK }, nil)
    local switched
    self._bw = { chip = "home", _setActiveChip = function(_bw, id) switched = id end }
    local rows = S._shelfThemeSubItems(self)[1].sub_item_table_func()
    rows[2].sub_item_table_func()
    eq(switched, "manga")
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

t.test("one row says when the shelf on screen's theme covers the reader's own; its help names the parts", function()
    local self, S = build({ MAC, AUT }, nil, nil, { on_screen = "Autumn" })
    local row = S._themeCoverRow(self)
    eq(row.text, "Autumn covers this shelf")
    eq(row.help_text, "On this shelf, Autumn shows its own: Ornaments.\n\nThe rows below are My theme: "
        .. "they show on shelves without a theme, and changing them does not change this shelf.")
    eq(row.separator, true)
    local self2, S2 = build({ MAC }, nil, nil, { on_screen = "Macabre" })
    assert(S2._themeCoverRow(self2).help_text:find(": Light or dark, Wallpaper, Plank, Ornaments.", 1, true))
    local self3, S3 = build({ MAC }, nil, nil, { on_screen = "mine" })
    eq(S3._themeCoverRow(self3), nil, "the reader's own on screen: no row")
    local UK2 = { pack = "Bare", name = "Bare" }                     -- brings nothing
    local self4, S4 = build({ UK2 }, nil, nil, { on_screen = "Bare" })
    eq(S4._themeCoverRow(self4), nil, "a theme that covers nothing: no row")
    local self5, S5 = build({}, nil, nil, { on_screen = "plain" })
    assert(S5._themeCoverRow(self5).text == "Plain covers this shelf")
end)

t.test("no row of the reader's own carries a per-row theme suffix any more", function()
    local body = src:gsub("%-%-[^\n]*", "")
    assert(not body:find("on this shelf)", 1, true), "a per-row suffix is back")
    local bg = body:match("function Settings:_backgroundSubItems%(%)(.-)\nend\n")
    assert(bg and bg:find("self:_themeCoverRow()", 1, true), "the cover row is not in the menu")
    assert(bg:find("_themeCoverRow", 1, true) < bg:find("_lightDarkRow", 1, true), "the cover row is not first")
end)

t.done()
