-- tests/_test_covers_panel.lua
-- Panel shading > "Panel behind Covers shelves" (issue 483): the
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

-- _scrimSubItems, run for real.
local function scrimMenu(store)
    local levels = assert(settings_src:match("\n(Settings%.SCRIM_LEVELS = {.-\n})\n"), "SCRIM_LEVELS moved")
    local fn = assert(settings_src:match("\n(function Settings:_scrimSubItems%(%).-\nend)\n"), "_scrimSubItems moved")
    local seen = { dirty = 0 }
    local env = setmetatable({
        Settings = {}, _ = function(s) return s end,
        -- The reader's own keys: a row that wrote here bypassed the seam
        -- (the panels are part of the theme since 2026-10-09).
        BookshelfSettings = { read = function() error("read the reader's key, not the theme's part") end,
                              save = function() error("saved the reader's key, not the theme's part") end,
                              flush = function() end },
        require = function(m)
            if m == "lib/bookshelf_wallpaper" then
                return { BUTTONS_SETTING = "b", SCRIM_SETTING = "s", COVERS_PANEL_SETTING = "covers_full_panel",
                         BLUR_SETTING = "wallpaper_panel_blur" }
            end
            if m == "lib/bookshelf_theme_pack" then
                return { partRead = function(k) return store[k] end, partSave = function(k, v) store[k] = v end }
            end
            return require(m)
        end,
    }, { __index = _G })
    compile(levels .. "\n" .. fn, env, "scrim")()
    local self = setmetatable({ _scrimStrength = function() return 0.85 end,
                                _markDirty = function() seen.dirty = seen.dirty + 1 end },
                              { __index = env.Settings })
    return env.Settings._scrimSubItems(self), seen
end

t.test("Panel shading ends with the Covers checkbox, set apart, off by default", function()
    local store = {}
    local rows = scrimMenu(store)
    local last = rows[#rows]
    eq(last.text, "Panel behind Covers shelves")
    eq(last.radio, nil, "it is a radio button, not a checkbox")
    -- Set apart from the levels by the separator under the last of them;
    -- the blur row (also a checkbox) sits between, so it is not "the row above".
    local last_radio
    for i, r in ipairs(rows) do if r.radio then last_radio = i end end
    eq(rows[last_radio].separator, true, "not set apart from the shading levels")
    eq(rows[#rows - 1].text, "Blur wallpaper behind panels", "the blur row moved")
    eq(last.checked_func(), false, "on by default")
end)

t.test("ticking it saves the setting and rebuilds the shelf; unticking clears it", function()
    local store = {}
    local rows, seen = scrimMenu(store)
    local last = rows[#rows]
    last.callback(nil)
    eq(store.covers_full_panel, true); eq(last.checked_func(), true); eq(seen.dirty, 1)
    last.callback(nil)
    eq(store.covers_full_panel, nil, "unticking left the setting behind")
end)

-- Panel shading > Blur wallpaper behind panels: off by default, a toggle
-- that rebuilds, and greyed where it has nothing to act on.
local function blurRow(store)
    local rows, seen = scrimMenu(store)      -- its self answers Heavy, 0.85
    local row = rows[#rows - 1]
    eq(row.text, "Blur wallpaper behind panels")
    return row, seen
end

t.test("the blur row: off by default, ticking saves and rebuilds, unticking clears", function()
    local store = {}
    local row, seen = blurRow(store)
    eq(row.radio, nil, "a checkbox, not one of the levels")
    eq(row.checked_func(), false, "on by default")
    eq(row.enabled_func(), true, "greyed at Heavy, where the picture still shows through")
    row.callback(nil)
    eq(store.wallpaper_panel_blur, true); eq(seen.dirty, 1)
    row.callback(nil)
    eq(store.wallpaper_panel_blur, nil, "unticking left the setting behind")
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
