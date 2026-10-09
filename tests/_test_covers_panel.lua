-- tests/_test_covers_panel.lua
-- Theme > Wallpaper > "Panel behind Covers shelves" (issue 483): the
-- one continuous panel list mode draws behind the top panel, the shelf and
-- the footer, for Covers shelves too, and without the label plates under
-- cover titles, which the panel makes redundant.
-- Usage (from plugin root): lua tests/_test_covers_panel.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

local function compile(code, env, name)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, name)); _G.setfenv(f, env); return f
    end
    return assert(load(code, name, "t", env))
end

local settings_src = io.open("lib/bookshelf_settings.lua"):read("*a")
local widget_src   = io.open("lib/bookshelf_widget.lua"):read("*a")
local row_src      = io.open("lib/bookshelf_shelf_row.lua"):read("*a")
local wp_src       = io.open("lib/bookshelf_wallpaper.lua"):read("*a")

t.test("the setting has one key, beside the shading keys", function()
    assert(wp_src:find('M.COVERS_PANEL_SETTING = "covers_full_panel"', 1, true), "no COVERS_PANEL_SETTING")
end)

-- _panelRows and _scrimSubItems, run for real, over a stub seam: the rows
-- read and write the theme on screen's parts (TP.partRead / partSave), never
-- the reader's keys directly (part of the theme since 2026-10-09).
local function panelMenu(store)
    local levels = assert(settings_src:match("\n(Settings%.SCRIM_LEVELS = {.-\n})\n"), "SCRIM_LEVELS moved")
    local fn = assert(settings_src:match("\n(function Settings:_panelRows%(%).-\nend)\n"), "_panelRows moved")
    local sub = assert(settings_src:match("\n(function Settings:_scrimSubItems%(%).-\nend)\n"), "_scrimSubItems moved")
    local seen = { dirty = 0, part_saves = 0 }
    local TP = { partRead = function(k) return store[k] end,
                 partSave = function(k, v) seen.part_saves = seen.part_saves + 1; store[k] = v end }
    local env = setmetatable({
        Settings = {}, _ = function(s) return s end,
        T = function(f, a) return (f:gsub("%%1", tostring(a))) end,
        -- The reader's own keys: a row that wrote here bypassed the seam.
        BookshelfSettings = { read = function() error("read the reader's key, not the theme's part") end,
                              save = function() error("saved the reader's key, not the theme's part") end,
                              flush = function() end },
        require = function(m)
            if m == "lib/bookshelf_wallpaper" then
                return { BUTTONS_SETTING = "b", SCRIM_SETTING = "s", COVERS_PANEL_SETTING = "covers_full_panel",
                         BLUR_SETTING = "wallpaper_panel_blur" }
            end
            if m == "lib/bookshelf_theme_pack" then return TP end
            return require(m)
        end,
    }, { __index = _G })
    compile(levels .. "\n" .. fn .. "\n" .. sub, env, "scrim")()
    local self = setmetatable({ _scrimStrength = function() return 0.85 end,
                                _scrimLabel = function() return "Heavy" end,
                                _markDirty = function() seen.dirty = seen.dirty + 1 end },
                              { __index = env.Settings })
    return env.Settings._panelRows(self), seen, self
end

t.test("three panel rows: Panel shading (its levels), then Blur, then the Covers checkbox", function()
    local store = {}
    local rows = panelMenu(store)
    eq(#rows, 3)
    eq(rows[1].text_func(), "Panel shading: Heavy")
    local levels = rows[1].sub_item_table_func()
    eq(#levels, 5, "the submenu is not the five levels alone")
    for _i, r in ipairs(levels) do eq(r.radio, true, "a level is not a radio button") end
    eq(rows[2].text, "Blur wallpaper behind panels", "the blur row moved")
    eq(rows[3].text, "Panel behind Covers shelves")
    eq(rows[3].radio, nil, "it is a radio button, not a checkbox")
    eq(rows[3].checked_func(), false, "on by default")
    for i = 1, 3 do
        local h = rows[i].help_text or ""
        assert(h:find("Part of the theme", 1, true), "row " .. i .. "'s help does not say it is part of the theme")
    end
end)

t.test("a level writes the shading and the buttons flag as parts, and rebuilds", function()
    local store = {}
    local rows, seen = panelMenu(store)
    local levels = rows[1].sub_item_table_func()
    levels[1].callback(nil)                     -- Transparent
    eq(store.s, 0); eq(store.b, true); eq(seen.dirty, 1)
    levels[2].callback(nil)                     -- Low
    eq(store.s, 0.35); eq(store.b, false, "the buttons flag stuck on from Transparent")
end)

t.test("ticking Covers saves the part and rebuilds the shelf; unticking clears it", function()
    local store = {}
    local rows, seen = panelMenu(store)
    local last = rows[3]
    last.callback(nil)
    eq(store.covers_full_panel, true); eq(last.checked_func(), true); eq(seen.dirty, 1)
    last.callback(nil)
    eq(store.covers_full_panel, nil, "unticking left the part behind")
end)

-- Blur wallpaper behind panels: off by default, a toggle that rebuilds,
-- and greyed where it has nothing to act on.
t.test("the blur row: off by default, ticking saves and rebuilds, unticking clears", function()
    local store = {}
    local rows, seen = panelMenu(store)        -- its self answers Heavy, 0.85
    local row = rows[2]
    eq(row.radio, nil, "a checkbox, not one of the levels")
    eq(row.checked_func(), false, "on by default")
    eq(row.enabled_func(), true, "greyed at Heavy, where the picture still shows through")
    row.callback(nil)
    eq(store.wallpaper_panel_blur, true); eq(seen.dirty, 1)
    row.callback(nil)
    eq(store.wallpaper_panel_blur, nil, "unticking left the part behind")
end)

t.test("the blur row is greyed at Transparent (no panel) and Solid (no picture)", function()
    local fn = assert(settings_src:match("text = _%(\"Blur wallpaper behind panels\"%),(.-)checked_func"),
        "the blur row moved")
    assert(fn:find("cur > 0 and cur < 1", 1, true), "enabled outside the translucent levels")
end)

-- _fullPanel, run for real.
local function fullPanel(mode, on)
    local body = assert(widget_src:match("\nfunction BookshelfWidget:_fullPanel%(%)\n(.-)\nend\n"), "_fullPanel missing")
    local env = {
        ViewMode = { COVERS = "covers", LIST = "list", SPINES = "spines",
                     isList = function(m) return m == "list" end },
        -- The reader's own key says the opposite: _fullPanel must ask the
        -- theme on screen (Wallpaper.coversPanel, the seam).
        BookshelfSettings = { read = function(k) return k == "covers_full_panel" and not on or nil end },
        require = function(m)
            return { COVERS_PANEL_SETTING = "covers_full_panel", coversPanel = function() return on == true end }
        end,
        pcall = pcall,
    }
    local self = { _viewMode = function() return mode end,
                   _isListMode = function() return mode == "list" end }
    return compile("local self = ...\n" .. body, env, "_fullPanel")(self)
end

t.test("the full panel: always in list mode, in Covers only with the option, never on spines", function()
    eq(fullPanel("list", nil), true)
    eq(fullPanel("covers", nil), false, "Covers got the panel without the option")
    eq(fullPanel("covers", true), true, "the option did nothing on Covers")
    eq(fullPanel("spines", true), false, "spines got the panel")
end)

t.test("the shelf build asks _fullPanel for the top panel", function()
    assert(widget_src:find("list_full = self:_fullPanel(),", 1, true), "the build still decides list_full itself")
end)

t.test("with the option on, cover labels get no plate", function()
    local code = row_src:gsub("%-%-[^\n]*", "")
    assert(code:find("plate_wp.coversPanel()", 1, true), "the label plate ignores the option")
    assert(code:match("plate_wp%.coversPanel%(%)[^\n]*\n[^\n]*plate_fill = nil"), "the option does not drop the plate")
    -- The theme's part, not the reader's key (Wallpaper.coversPanel).
    assert(not code:find("COVERS_PANEL_SETTING", 1, true), "the plate reads the reader's key directly")
end)

t.done()
