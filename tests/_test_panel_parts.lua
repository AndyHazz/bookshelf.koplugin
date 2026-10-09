-- tests/_test_panel_parts.lua
-- The panels over a wallpaper are part of the theme (5.4, maintainer
-- 2026-10-09: "macabre looks best with light transparency and blur off" >
-- "Yes make those part of the theme"): Panel shading (with the transparent
-- buttons flag it writes), Blur wallpaper behind panels and Panel behind
-- Covers shelves resolve through the seam like any part: Custom theme's are
-- the reader's own keys; Plain's are the defaults; a pack's theme.json may
-- set them ("panel_shading", "panel_blur", "covers_panel"), else it takes
-- Custom theme's; an edit on a pack or Plain shelf is saved with that theme
-- and Reset to original brings the theme's own back. Every reader of the
-- four keys asks the seam.
-- Run from the plugin root: lua tests/_test_panel_parts.lua
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

-- setup(): TP over a scratch ornaments folder, a settings table and the
-- tabs by id.
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
    local st = { gen = 0, saves = 0 }
    TP._store = { read = function(k) return settings[k] end,
                  save = function(k, v) settings[k] = v; st.saves = st.saves + 1; st.gen = st.gen + 1 end,
                  flush = function() end,
                  generation = function() return st.gen end,
                  bump = function() st.gen = st.gen + 1 end }
    local tabs = {}
    TP._tab = function(id) return tabs[id] end
    return TP, d, settings, tabs, st, off, packs_off
end

local function compile(code, env, name)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, name)); _G.setfenv(f, env); return f
    end
    return assert(load(code, name, "t", env))
end

-- Wallpaper over that TP (its readers ask the seam through require).
local function wallpaperOver(TP)
    package.loaded["lib/bookshelf_theme_pack"] = TP
    package.loaded["lib/bookshelf_wallpaper"] = nil
    return dofile("lib/bookshelf_wallpaper.lua")
end

local SH, BU, BL, CO = "wallpaper_chrome_scrim", "wallpaper_transparent_buttons",
                       "wallpaper_panel_blur", "covers_full_panel"

-- Macabre sets all three in its theme.json; Ukiyo-e has a theme.json
-- without them. The reader's own (Custom theme): Moderate, blur on, the
-- Covers panel on.
local function world(d, settings)
    touch(d .. "/Macabre/theme/theme.json",
        '{"shelf":"dark","panel_shading":"low","panel_blur":false,"covers_panel":false}')
    touch(d .. "/Macabre/theme/wallpaper.png"); touch(d .. "/Macabre/skull.png")
    touch(d .. "/Ukiyo-e/theme/theme.json", '{"name":"Ukiyo-e"}')
    touch(d .. "/Ukiyo-e/theme/wallpaper.jpg"); touch(d .. "/Ukiyo-e/wave.png")
    settings[SH] = 0.6; settings[BU] = false; settings[BL] = true; settings[CO] = true
end
local function on(TP, id) TP._store.bump(); TP.setShelf(id) end
local function W_shading(TP) return TP.partRead(SH) end

-- What the shelf on screen paints for the three parts, through the readers.
local function painted(W)
    return { shading = W.shading(), strength = W.scrimStrength(W.partRead),
             blur = W.blurOn(), covers = W.coversPanel() }
end

t.test("Custom / Plain / pack with keys / pack without, unedited and edited: shading, blur, Covers panel", function()
    -- { shelf's theme, unedited, edited }: the edit is Solid, blur and the
    -- Covers panel flipped from what that theme shows.
    local cases = {
        { theme = "mine",    before = { 0.6,  true,  true  }, after = { 1, false, false } },
        { theme = "plain",   before = { 0.85, false, false }, after = { 1, true,  true  } },
        { theme = "Macabre", before = { 0.35, false, false }, after = { 1, true,  true  } },
        { theme = "Ukiyo-e", before = { 0.6,  true,  true  }, after = { 1, false, false } },
    }
    for _i, c in ipairs(cases) do
        local TP, d, settings, tabs = setup()
        world(d, settings)
        local W = wallpaperOver(TP)
        tabs.home = { id = "home", theme = c.theme }
        tabs.other = { id = "other", theme = "mine" }
        on(TP, "home")
        local p = painted(W)
        local tag = c.theme .. " unedited: "
        eq(p.shading, c.before[1], tag .. "shading"); eq(p.strength, c.before[1], tag .. "strength")
        eq(p.blur, c.before[2], tag .. "blur"); eq(p.covers, c.before[3], tag .. "covers panel")
        -- The menu's writes: a level (both keys), then the two toggles.
        TP.partSave(BU, false); TP.partSave(SH, 1)
        TP.partSave(BL, (TP.partRead(BL) ~= true) or nil)
        TP.partSave(CO, (TP.partRead(CO) ~= true) or nil)
        on(TP, "home")
        p = painted(W)
        tag = c.theme .. " edited: "
        eq(p.shading, c.after[1], tag .. "shading"); eq(p.blur, c.after[2], tag .. "blur")
        eq(p.covers, c.after[3], tag .. "covers panel")
        if c.theme == "mine" then
            eq(settings[SH], 1, "Custom theme's edit is not the reader's key")
            eq(TP.hasEdits("mine"), false)
        else
            -- Saved with the theme; Custom theme untouched, and a Custom
            -- theme shelf still shows the reader's own.
            eq(settings[SH], 0.6, tag .. "wrote Custom theme's shading")
            eq(settings[BL], true, tag .. "wrote Custom theme's blur")
            eq(settings[CO], true, tag .. "wrote Custom theme's Covers panel")
            eq(TP.hasEdits(c.theme), true, tag .. "the card would not say Edited")
            on(TP, "other")
            eq(W.shading(), 0.6, tag .. "leaked onto a Custom theme shelf")
            eq(W.blurOn(), true)
            -- Reset to original: the theme's own back.
            on(TP, "home")
            TP.resetEdits(c.theme)
            on(TP, "home")
            p = painted(W)
            eq(p.shading, c.before[1], tag .. "Reset did not bring the shading back")
            eq(p.blur, c.before[2], tag .. "Reset did not bring the blur back")
            eq(p.covers, c.before[3], tag .. "Reset did not bring the Covers panel back")
        end
    end
end)

t.test("Transparent on a pack: its shading and buttons together, and Custom theme's Transparent does not cut a pack's", function()
    local TP, d, settings, tabs = setup()
    world(d, settings)
    settings[SH] = 0; settings[BU] = true          -- the reader's own: Transparent
    local W = wallpaperOver(TP)
    tabs.home = { id = "home", theme = "Macabre" }
    tabs.uk = { id = "uk", theme = "Ukiyo-e" }
    on(TP, "home")
    eq(W.scrimStrength(W.partRead), 0.35, "Custom theme's transparent buttons cut Macabre's Low to nothing")
    on(TP, "uk")
    eq(W.scrimStrength(W.partRead), 0, "a pack without shading does not follow Custom theme's")
    on(TP, "home")
    TP.partSave(BU, true); TP.partSave(SH, 0)
    on(TP, "home")
    eq(W.scrimStrength(W.partRead), 0)
    -- Back to Low: the edit equals the pack's own, so it is dropped and
    -- Reset to original greys.
    TP.partSave(BU, false); TP.partSave(SH, 0.35)
    eq(TP.hasEdits("Macabre"), false, "an edit back to the pack's own is still an edit")
end)

t.test("Reset to default colors leaves the panels alone", function()
    local TP, d, settings, tabs = setup()
    world(d, settings)
    tabs.home = { id = "home", theme = "Macabre" }
    on(TP, "home")
    TP.partSave(SH, 1); TP.partSave(BL, true)
    local src = io.open("lib/bookshelf_settings.lua"):read("*a")
    local list = assert(src:match('text = ICON_RESET %.%. _%("Reset to default colors"%).-local keys = (%b{})'),
        "the Reset key list moved")
    local keys = compile("return " .. list, {}, "keys")()
    for _i, k in ipairs(keys) do
        assert(k ~= SH and k ~= BU and k ~= BL and k ~= CO, "Reset to default colors clears " .. k)
    end
    TP.partClear(keys)
    eq(TP.partRead(SH), 1); eq(TP.partRead(BL), true)
end)

t.test("theme.json panel_shading: the menu's level names (any case) or a number 0..1; booleans for the two switches", function()
    local cases = {
        { '"transparent"', 0 }, { '"low"', 0.35 }, { '"Moderate"', 0.6 }, { '"HEAVY"', 0.85 }, { '"solid"', 1 },
        { "0.5", 0.5 }, { "0", 0 }, { "1.7", 1 }, { "-1", 0 },
        { '"light"', nil }, { '""', nil }, { "true", nil },
    }
    for _i, c in ipairs(cases) do
        local TP, d = setup()
        touch(d .. "/P/theme/theme.json", '{"panel_shading":' .. c[1] .. ',"panel_blur":"yes","covers_panel":true}')
        touch(d .. "/P/x.png")
        local m = TP.theme("P").manifest
        eq(m.panel_shading, c[2], "panel_shading " .. c[1])
        eq(m.panel_blur, nil, "a string is not a switch")
        eq(m.covers_panel, true)
    end
end)

t.test("the level names are the menu's levels, in lower case, at the same values", function()
    local src = io.open("lib/bookshelf_settings.lua"):read("*a")
    local levels = assert(src:match("\n(Settings%.SCRIM_LEVELS = {.-\n})\n"), "SCRIM_LEVELS moved")
    local env = { Settings = {}, _ = function(s) return s end }
    compile(levels, env, "levels")()
    local TP = setup()
    local n = 0
    for _i, lvl in ipairs(env.Settings.SCRIM_LEVELS) do
        n = n + 1
        eq(lvl.name, lvl.label():lower(), "a level's theme.json name is not its label")
        eq(TP.SHADING_LEVELS[lvl.name], lvl.value, "theme.json's " .. lvl.name .. " is not the menu's")
    end
    local m = 0
    for _k in pairs(TP.SHADING_LEVELS) do m = m + 1 end
    eq(m, n, "theme.json names a level the menu does not have")
end)

t.test("the panel parts are Wallpaper's keys", function()
    local TP = setup()
    local W = wallpaperOver(TP)
    eq(TP.PANEL_KEYS.shading, W.SCRIM_SETTING); eq(TP.PANEL_KEYS.buttons, W.BUTTONS_SETTING)
    eq(TP.PANEL_KEYS.blur, W.BLUR_SETTING); eq(TP.PANEL_KEYS.covers, W.COVERS_PANEL_SETTING)
    for _n, k in pairs(TP.PANEL_KEYS) do eq(TP.isPart(k), true, k .. " is not a part") end
end)

t.test("a shading edit on a pack's shelf is no full-screen refresh; a shelf that differs only there bumps the generation", function()
    local TP, d, settings, tabs, st = setup()
    world(d, settings)
    tabs.home = { id = "home", theme = "Macabre" }
    tabs.mine = { id = "mine", theme = "mine" }
    tabs.mine2 = { id = "mine2", theme = "Ukiyo-e" }
    on(TP, "home")
    TP.partSave(SH, 1)
    eq(TP.setShelf("home"), false, "a shading edit asked for a full-screen refresh")
    TP.partSave(BL, true)
    eq(TP.setShelf("home"), false, "a blur edit asked for a full-screen refresh")
    TP.partSave(CO, true)
    eq(TP.setShelf("home"), false, "a Covers panel edit asked for a full-screen refresh")
    -- Two shelves alike but for the panels (a pack of ornaments whose
    -- theme.json sets only its shading): the next one's paint must not
    -- serve the last one's memo (the ground memo keys on the generation).
    touch(d .. "/Shade/theme/theme.json", '{"panel_shading":"solid"}')
    touch(d .. "/Shade/bat.png")
    tabs.b = { id = "b", theme = "Shade" }
    on(TP, "mine")
    local g = st.gen
    TP.setShelf("b")
    eq(W_shading(TP), 1)
    assert(st.gen > g, "a shelf that differs only in its panels did not bump the generation")
    g = st.gen
    TP.setShelf("mine")
    assert(st.gen > g, "back to a shelf that differs only in its panels did not bump the generation")
end)

-- ── Every reader goes through the seam ────────────────────────────────────

local function src(path) return (io.open(path):read("*a")) end
local function code(path) return (src(path):gsub("%-%-[^\n]*", "")) end
local function body(s, name)
    return s:match("\nfunction " .. name:gsub("[%.%:%(%)]", "%%%0") .. "%(%)\n(.-)\nend\n")
end

t.test("Wallpaper's readers: blurOn, shading, coversPanel ask its partRead, which is the seam", function()
    local w = src("lib/bookshelf_wallpaper.lua")
    assert(body(w, "M.blurOn") == nil)   -- a one-liner
    assert(w:find("function M.blurOn() return M.partRead(M.BLUR_SETTING) == true end", 1, true),
        "blurOn reads the reader's key")
    assert(body(w, "M.shading"):find("M.partRead(M.SCRIM_SETTING)", 1, true), "shading reads the reader's key")
    assert(w:find("function M.coversPanel() return M.partRead(M.COVERS_PANEL_SETTING) == true end", 1, true),
        "coversPanel reads the reader's key")
end)

t.test("the widget: shading, transparent buttons and the full panel ask the seam", function()
    local w = src("lib/bookshelf_widget.lua")
    assert(body(w, "BookshelfWidget:_scrimStrengthRaw"):find("Wallpaper.scrimStrength(Wallpaper.partRead)", 1, true),
        "_scrimStrengthRaw reads the reader's keys")
    assert(body(w, "BookshelfWidget:wallpaperButtonsTransparent"):find("Wallpaper.transparentButtons(Wallpaper.partRead)", 1, true),
        "wallpaperButtonsTransparent reads the reader's key")
    assert(body(w, "BookshelfWidget:_fullPanel"):find("Wallpaper.coversPanel()", 1, true),
        "_fullPanel reads the reader's key")
end)

t.test("the plates, the add tile, the start menu, the ornament zoom and the menu ask the seam", function()
    local row = code("lib/bookshelf_shelf_row.lua")
    assert(row:find("plate_strength = plate_wp.shading()", 1, true), "the plates read the reader's shading")
    assert(row:find("plate_wp.coversPanel()", 1, true), "the plates read the reader's Covers panel")
    assert(code("lib/bookshelf_add_tile.lua"):find("local v = Wallpaper.shading()", 1, true),
        "the add tile reads the reader's shading")
    -- These two take the widget's answer (its ground memo, through the seam).
    assert(code("lib/bookshelf_start_menu.lua"):find("self.bw:wallpaperScrimStrength()", 1, true),
        "the start menu works out its own shading")
    assert(code("lib/bookshelf_ornament_zoom.lua"):find("bw:wallpaperScrimStrength()", 1, true),
        "the ornament zoom works out its own shading")
    local set = src("lib/bookshelf_settings.lua")
    assert(body(set, "Settings:_scrimStrength"):find("Wallpaper.scrimStrength(Wallpaper.partRead)", 1, true),
        "the menu's level reads the reader's keys")
end)

t.test("nothing in lib/ reads or writes the four keys past the seam", function()
    local consts = { "SCRIM_SETTING", "BUTTONS_SETTING", "BLUR_SETTING", "COVERS_PANEL_SETTING" }
    local raw = { SH, BU, BL, CO }
    local files = {}
    for f in io.popen("ls lib/*.lua"):lines() do files[#files + 1] = f end
    for _i, f in ipairs(files) do
        local c = code(f)
        for _j, k in ipairs(consts) do
            for line in c:gmatch("[^\n]+") do
                if line:find(k, 1, true) and (line:find("%.read%(") or line:find("%.save%(") or line:find("%.delete%(")) then
                    error(f .. " reads or writes " .. k .. " past the seam: " .. line)
                end
            end
        end
        for _j, k in ipairs(raw) do
            for line in c:gmatch("[^\n]+") do
                if line:find('"' .. k .. '"', 1, true) and (line:find("read%(") or line:find("save%(")) then
                    -- The v3 migration reads Custom theme's own shading on purpose.
                    if not (f == "lib/bookshelf_theme_pack.lua" and line:find('local shading = read("' .. SH .. '")', 1, true)) then
                        error(f .. " reads or writes " .. k .. " past the seam: " .. line)
                    end
                end
            end
        end
    end
end)

t.done()
