-- tests/_test_shelf_theme_menu.lua
-- Theme packs are chosen in the Shelf theme menu, as a second group under
-- Auto / Light / Dark (maintainer, 2026-10-02). The menu is built each time it
-- opens and rescans the packs first, so one copied in since start-up shows.
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
    grab("\n(function Settings:_themePackLabel%(%).-\nend)\n", "_themePackLabel"),
    grab("\n(function Settings:_shelfThemeSubItems%(%).-\nend)\n", "_shelfThemeSubItems"),
    grab("\n(function Settings:_shelfThemeText%(%).-\nend)\n", "_shelfThemeText"),
    grab("\n(function Settings:_setShelfThemeField%(id, field, value%).-\nend)\n", "_setShelfThemeField"),
    grab("\n(function Settings:_setShelfThemeFields%(id, fields%).-\nend)\n", "_setShelfThemeFields"),
    grab("\n(function Settings:_shelvesDiffer%(%).-\nend)\n", "_shelvesDiffer"),
    grab("\n(local function _lookLabel%(value%).-\nend)\n", "_lookLabel"),
    grab("\n(function Settings:_shelfThemeLabelFor%(tab%).-\nend)\n", "_shelfThemeLabelFor"),
    grab("\n(function Settings:_oneShelfThemeItems%(id%).-\nend)\n", "_oneShelfThemeItems"),
    grab("\n(function Settings:_perShelfThemesRow%(%).-\nend)\n", "_perShelfThemesRow"),
}, "\n")

-- build(packs, current) -> the menu's rows and what the stubs saw.
local function build(packs, current, tabs)
    local seen = { rescans = 0, chosen = {}, cleared = 0, toasts = {}, dirty = 0, full = 0, store = {} }
    tabs = tabs or { { id = "home", label = "Home" }, { id = "manga", label = "Manga" } }
    local tabs_by = {}
    for _i, tb in ipairs(tabs) do tabs_by[tb.id] = tb end
    local TP = {
        rescan = function() seen.rescans = seen.rescans + 1 end,
        themePacks = function() return packs end,
        currentTheme = function() return current end,
        chooseTheme = function(p) seen.chosen[#seen.chosen + 1] = p; current = p; return true end,
        clearTheme = function() seen.cleared = seen.cleared + 1; current = nil end,
        allThemes = function()
            local o = {}
            for _i, p in ipairs(packs) do
                o[#o + 1] = { pack = p.pack, name = p.name, description = p.description,
                              ornaments_only = p.ornaments_only or false }
            end
            return o
        end,
        displayName = function(p)
            for _i, x in ipairs(packs) do if x.pack == p then return x.name end end
            return p
        end,
        theme = function(p)
            for _i, x in ipairs(packs) do if x.pack == p then return { exists = true } end end
            return { exists = false }
        end,
        shelfChoiceFor = function(id) local tb = tabs_by[id] return tb and tb.theme end,
        shelfLookFor = function(id) local tb = tabs_by[id] return tb and tb.theme_look end,
        shelfLookOf = function(id)
            local tb = tabs_by[id]
            if tb and tb.theme_look then return tb.theme_look end
            if tb and tb.theme == "Halloween" then return "dark" end     -- HW's manifest
            return seen.store.shelf_theme or "auto"
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
                              save = function(k, v) seen.store[k] = v end, flush = function() end },
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
    return self, env.Settings, seen
end

local HW = { pack = "Halloween", name = "Halloween", description = "Bats and ghosts.", shelf = "dark" }
local UK = { pack = "Ukiyo-e", name = "Ukiyo-e" }

t.test("with no theme packs: Themes for each shelf, Auto, Light, Dark, then Add theme", function()
    local self, S, seen = build({}, nil)
    local rows = S._shelfThemeSubItems(self)
    eq(#rows, 5)
    eq(rows[1].text_func(), "Themes for each shelf (all default)", "a shelf cannot pick light/dark without packs")
    eq(rows[1].separator, true)
    eq(rows[4].separator, true)
    eq(rows[5].text, "Add theme\xE2\x80\xA6")
    eq(seen.rescans, 1, "opening the menu did not rescan the packs")
end)

t.test("theme packs follow a separator: No theme pack, then each by name, then Add theme", function()
    local self, S = build({ HW, UK }, "Halloween")
    local rows = S._shelfThemeSubItems(self)
    eq(#rows, 8)
    eq(rows[1].text_func(), "Themes for each shelf (all default)")
    eq(rows[4].separator, true)
    eq(rows[5].text, "No theme pack"); eq(rows[6].text, "Halloween"); eq(rows[7].text, "Ukiyo-e")
    eq(rows[6].help_text, "Bats and ghosts.")
    for i = 5, 7 do eq(rows[i].radio, true); eq(rows[i].keep_menu_open, true) end
    eq(rows[5].checked_func(), false); eq(rows[6].checked_func(), true); eq(rows[7].checked_func(), false)
    eq(rows[7].separator, true, "the packs are not set apart")
    eq(rows[8].text, "Add theme\xE2\x80\xA6")
end)

t.test("Add theme says where theme packs go, and where to get them", function()
    -- Like the collection's Add ornaments: a findable path, the shop link as a
    -- parameter (not part of the msgid, so a translation cannot break it).
    local self, S, seen = build({}, nil)
    local rows = S._shelfThemeSubItems(self)
    eq(rows[5].keep_menu_open, true)
    rows[5].callback(nil)
    local text = seen.toasts[1]
    assert(text, "no dialog")
    assert(text:find("/mnt/us/koreader/settings/bookshelf/ornaments", 1, true), "no findable folder: " .. text)
    assert(text:find("ko-fi.com/andyhazz/shop", 1, true), "no shop link")
    assert(src:find('"ko-fi.com/andyhazz/shop")', 1, true), "the link is not a parameter")
end)

t.test("choosing a theme pack applies it, rebuilds the whole screen and says so", function()
    local self, S, seen = build({ HW, UK }, nil)
    local rows = S._shelfThemeSubItems(self)
    local updated = 0
    rows[7].callback({ updateItems = function() updated = updated + 1 end })
    eq(seen.chosen[1], "Ukiyo-e")
    eq(seen.dirty, 1, "the shelf was not rebuilt"); eq(seen.full, 1, "no full refresh for a whole new look")
    eq(seen.toasts[1], "Ukiyo-e theme on")
    eq(updated, 1, "the menu's marks did not update")
end)

t.test("No theme pack clears a theme, and does nothing without one", function()
    local self, S, seen = build({ HW }, "Halloween")
    local rows = S._shelfThemeSubItems(self)
    rows[5].callback(nil)
    eq(seen.cleared, 1); eq(seen.toasts[1], "Theme pack off")
    rows[5].callback(nil)
    eq(seen.cleared, 1, "cleared again with no theme on"); eq(#seen.toasts, 1)
end)

t.test("the row names the light/dark choice and the theme", function()
    local self, S, seen = build({ HW, UK }, "Halloween")
    seen.store.shelf_theme = "dark"
    eq(S._shelfThemeText(self), "Shelf theme: Dark, Halloween")
    local self2, S2, seen2 = build({ HW }, nil)
    seen2.store.shelf_theme = "dark"
    eq(S2._shelfThemeText(self2), "Shelf theme: Dark")
end)

t.test("Wallpaper, ornaments and colors no longer holds the theme row", function()
    local bg = src:match("\nfunction Settings:_backgroundSubItems%(%)(.-)\nend\n")
    assert(bg, "_backgroundSubItems moved")
    assert(not bg:find("_shelfTheme", 1, true), "the theme row is still in the wallpaper menu")
end)

t.test("Themes for each shelf is the first row, set apart, and says when all follow the library", function()
    -- Maintainer, 2026-10-07: at the top of the menu, with "(all default)".
    local self, S = build({ HW, UK }, "Halloween")
    local rows = S._shelfThemeSubItems(self)
    eq(rows[1].text_func(), "Themes for each shelf (all default)")
    eq(rows[1].separator, true, "not set apart from the library's own rows")
    eq(rows[#rows].text, "Add theme\xE2\x80\xA6")
    assert(rows[1].sub_item_table_func, "the row has no submenu")
end)

t.test("ornament-only packs are themes too, after the theme packs", function()
    local GA = { pack = "Gallery", name = "Gallery", ornaments_only = true }
    local self, S = build({ HW, GA }, nil)
    local rows = S._shelfThemeSubItems(self)
    eq(rows[6].text, "Halloween"); eq(rows[7].text, "Gallery (ornaments only)")
end)

t.test("each shelf is listed with its theme, as the top-level row names it", function()
    local self, S, seen = build({ HW, UK }, "Halloween", {
        { id = "home", label = "Home" },
        { id = "manga", label = "Manga", theme = "Ukiyo-e", theme_look = "dark" },
        { id = "comics", label = "Comics", theme = "Gone" },
        { id = "art", label = "Art", theme = "none" },
    })
    seen.store.shelf_theme = "light"
    local list = S._perShelfThemesRow(self).sub_item_table_func()
    eq(list[1].text_func(), "Home: same as library")
    eq(list[2].text_func(), "Manga: Dark, Ukiyo-e")
    eq(list[3].text_func(), "Comics: Light, Gone (missing)")
    eq(list[4].text_func(), "Art: Light, No theme pack")
    assert(list[2].sub_item_table_func, "a shelf does not open its own menu")
end)

t.test("a shelf's label names the light/dark it shows, its pack's when the pack says", function()
    local self, S, seen = build({ HW }, nil, { { id = "latest", label = "Latest", theme = "Halloween" } })
    seen.store.shelf_theme = "light"
    eq(S._perShelfThemesRow(self).sub_item_table_func()[1].text_func(), "Latest: Dark, Halloween")
end)

t.test("a shelf's menu: a Same as library checkbox over the library's choices, greyed", function()
    local self, S, seen = build({ HW, UK }, "Halloween")
    seen.store.shelf_theme = "light"
    local rows = S._oneShelfThemeItems(self, "manga")
    local texts = {}
    for i, r in ipairs(rows) do texts[i] = r.text end
    eq(table.concat(texts, "|"), "Same as library|Auto (follow device)|Light|Dark|No theme pack|Halloween|Ukiyo-e")
    assert(rows[1].checked_func(), "an untouched shelf is not on Same as library")
    eq(rows[1].radio, nil, "Same as library is a radio button, not a checkbox")
    for i = 2, #rows do
        eq(rows[i].radio, true, texts[i] .. " is not a radio button")
        eq(rows[i].enabled_func(), false, texts[i] .. " can be chosen while following the library")
    end
    -- the greyed rows show what the library uses
    eq(rows[3].checked_func(), true, "the library's Light is not shown")
    eq(rows[6].checked_func(), true, "the library's Halloween is not shown")
    eq(rows[2].checked_func() or rows[4].checked_func() or rows[5].checked_func() or rows[7].checked_func(), false)
end)

t.test("unticking copies the library's choices; ticking drops the shelf's own", function()
    local self, S, seen = build({ HW, UK }, "Halloween")
    seen.store.shelf_theme = "light"
    local rows = S._oneShelfThemeItems(self, "manga")
    rows[1].callback(nil)                                   -- untick
    eq(seen.saved[2].theme, "Halloween"); eq(seen.saved[2].theme_look, "light")
    eq(rows[2].enabled_func(), true, "the choices did not come alive")
    eq(rows[1].checked_func(), false)
    rows[7].callback(nil)                                   -- Ukiyo-e
    eq(seen.saved[2].theme, "Ukiyo-e"); eq(seen.saved[2].theme_look, "light")
    rows[4].callback(nil)                                   -- Dark
    eq(seen.saved[2].theme_look, "dark")
    rows[5].callback(nil)                                   -- No theme pack
    eq(seen.saved[2].theme, "none")
    eq(#seen.chosen, 0, "the library theme changed")
    rows[1].callback(nil)                                   -- tick again
    eq(seen.saved[2].theme, nil); eq(seen.saved[2].theme_look, nil)
    assert(seen.full > 0, "a shelf's theme change did not refresh the whole screen")
    eq(seen.saved[1].theme, nil, "another shelf changed")
end)

t.test("unticking under no library theme copies No theme pack", function()
    local self, S, seen = build({ HW }, nil)
    local rows = S._oneShelfThemeItems(self, "manga")
    rows[1].callback(nil)
    eq(seen.saved[2].theme, "none"); eq(seen.saved[2].theme_look, "auto")
end)

t.test("a shelf's missing pack is listed, checked", function()
    local self, S = build({ HW }, nil, { { id = "manga", label = "Manga", theme = "Gone" } })
    local rows = S._oneShelfThemeItems(self, "manga")
    local hit
    for _i, r in ipairs(rows) do if r.text == "Gone (missing)" then hit = r end end
    assert(hit and hit.checked_func(), "the missing pack is not shown as the choice")
end)

t.test("the count of shelves with their own theme is on Themes for each shelf, not the top row", function()
    local self, S = build({ HW }, "Halloween", { { id = "home", label = "Home" },
                                                 { id = "manga", label = "Manga", theme = "none" },
                                                 { id = "off", label = "Off", enabled = false, theme = "Halloween" } })
    eq(S._shelfThemeText(self), "Shelf theme: Auto (follow device), Halloween", "the top row still carries the count")
    eq(S._perShelfThemesRow(self).text_func(), "Themes for each shelf (1 of 2)",
       "the count is not there, or counts a disabled shelf")
    eq(#S._perShelfThemesRow(self).sub_item_table_func(), 2, "a disabled shelf is listed")
    local self2, S2 = build({ HW }, "Halloween")
    eq(S2._perShelfThemesRow(self2).text_func(), "Themes for each shelf (all default)")
end)

t.test("opening another shelf's theme menu shows that shelf behind it", function()
    local self, S = build({ HW }, nil)
    local switched = {}
    self._bw = { chip = "home", _setActiveChip = function(w, id) switched[#switched + 1] = id; w.chip = id end }
    local list = S._perShelfThemesRow(self).sub_item_table_func()
    list[2].sub_item_table_func()                           -- Manga
    eq(table.concat(switched, ","), "manga", "the shelf behind the menu did not change")
    list[2].sub_item_table_func()                           -- Manga again: already there
    list[1].sub_item_table_func()                           -- Home
    eq(table.concat(switched, ","), "manga,home")
    self._bw = nil
    assert(list[1].sub_item_table_func(), "no shelf on screen broke the menu")
end)

t.done()
