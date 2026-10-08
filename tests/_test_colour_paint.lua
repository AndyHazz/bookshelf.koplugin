-- tests/_test_colour_paint.lua
-- Picked colours came out grey on colour screens (reported on Reddit: "the
-- background colors I selected for the progress bar and shelf menu are all in
-- grayscale"). Blitbuffer's paintRect and TextWidget's glyph blit both flatten
-- a colour to one grey; these pin the colour-safe routes Bookshelf uses instead.
package.path = "./?.lua;./?/init.lua;" .. package.path

local t  = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq

-- A Blitbuffer stand-in: a colour is a table with .r, a grey one has only .a.
local calls
local BB = {
    isColor8 = function(c) return c.r == nil end,
    TYPE_BB8 = 1, TYPE_BBRGB32 = 5,
}
package.loaded["ffi/blitbuffer"] = BB
local function fakeBB(bbtype, with_rgb)
    local bb = {
        paintRect = function(_s, x, y, w, h, c) calls[#calls + 1] = { "paintRect", c } end,
        getType = function() return bbtype end,
    }
    if with_rgb ~= false then
        bb.paintRectRGB32 = function(_s, x, y, w, h, c) calls[#calls + 1] = { "paintRectRGB32", c } end
    end
    return bb
end
package.loaded["lib/bookshelf_color"] = nil
local Color = require("lib/bookshelf_color")

t.test("a picked colour is filled with paintRectRGB32", function()
    calls = {}
    Color.paintRect(fakeBB(5), 0, 0, 10, 10, { r = 32, g = 96, b = 208 })
    eq(calls[1][1], "paintRectRGB32")
end)

t.test("a grey is filled exactly as before", function()
    calls = {}
    Color.paintRect(fakeBB(5), 0, 0, 10, 10, { a = 0x80 })
    eq(calls[1][1], "paintRect")
end)

t.test("a KOReader without paintRectRGB32 falls back to paintRect", function()
    calls = {}
    Color.paintRect(fakeBB(5, false), 0, 0, 10, 10, { r = 1, g = 2, b = 3 })
    eq(calls[1][1], "paintRect")
end)

t.test("no colour, no paint", function()
    calls = {}
    Color.paintRect(fakeBB(5), 0, 0, 10, 10, nil)
    eq(#calls, 0)
end)

t.test("the colour text module hands back a stubbed TextWidget untouched", function()
    local stub = { name = "stub" }
    package.loaded["ui/widget/textwidget"] = stub
    package.loaded["lib/bookshelf_colour_text"] = nil
    eq(require("lib/bookshelf_colour_text"), stub, "a stub without extend must pass straight through")
    package.loaded["lib/bookshelf_colour_text"] = nil
    package.loaded["ui/widget/textwidget"] = nil
end)

-- The swap is one line per file; a file that goes back to KOReader's own
-- TextWidget would quietly draw its picked colours grey again.
t.test("nothing requires KOReader's TextWidget directly", function()
    local p = io.popen("grep -rln 'require(\"ui/widget/textwidget\")' lib micromodules main.lua 2>/dev/null")
    local out = p:read("*a"); p:close()
    local offenders = {}
    for f in out:gmatch("[^\n]+") do
        if f ~= "lib/bookshelf_colour_text.lua" then offenders[#offenders + 1] = f end
    end
    assert(#offenders == 0, "use lib/bookshelf_colour_text instead in: " .. table.concat(offenders, ", "))
end)

t.test("the shelf menu strip and the hero fallback bar paint colour-safely", function()
    local chip = io.open("lib/bookshelf_chip_bar.lua"):read("*a")
    assert(chip:find('require("lib/bookshelf_color").paintRect(bb, x, y, w or 0, h or 0, colors.chrome_bg)', 1, true),
        "the strip ground must go through Color.paintRect")
    local bar = io.open("lib/bookshelf_hero_bar.lua"):read("*a")
    assert(bar:find("ColourBar", 1, true) and bar:find("Color.paintRect(bb, x + bw, y + bw, fw", 1, true),
        "without bookends, a picked bar colour must be painted by ColourBar")
    local card = io.open("lib/bookshelf_hero_card.lua"):read("*a")
    assert(card:find("keeps_colour", 1, true),
        "a coloured hero bar must stay out of the one-colour wallpaper mask")
end)

-- Night mode: the night slot is stored pre-inverted for a frame that flips it.
-- The colour picker stored what the reader SAW, so a night pick displayed as
-- its opposite (red as cyan) once colours stopped being flattened to grey.
t.test("the colour picker inverts the night slot on the way in and out", function()
    local src = io.open("lib/bookshelf_settings.lua"):read("*a")
    local body = src:match("function Settings:_pickColor%(.-\nend\n")
    assert(body, "could not find _pickColor")
    assert(body:find("local night = _isNight()", 1, true), "the picker must ask which slot it edits")
    assert(body:find("_shownHex(raw, raw_key)", 1, true), "the shown colour must be the displayed one")
    local shown = src:match("local function _shownHex%(raw, raw_key%)(.-)\nend\n")
    assert(shown and shown:find('invertValue(raw)', 1, true) and shown:find("_isNight()", 1, true),
        "the shown colour must be the displayed one")
    assert(body:find("if night then stored = Color.invertValue(stored) end", 1, true),
        "a night pick must be stored pre-inverted")
end)

t.test("the hero and list bars take the current mode's picked colours", function()
    for _i, f in ipairs({ "lib/bookshelf_hero_card.lua", "lib/bookshelf_list_row.lua" }) do
        local src = io.open(f):read("*a")
        assert(src:find("pickedBarColors()", 1, true), f .. " must use CoverProgress.pickedBarColors")
        assert(not src:find('BookshelfSettings.read("progress_fill")', 1, true),
            f .. " reads the day key directly again")
    end
end)

-- The conversion between what the reader sees and what is stored depends on
-- the SLOT being edited, not on whether KOReader is inverting: pinned Dark
-- with KOReader in day mode, and pinned Light with it in night mode, showed a
-- picked pink as green when the picker asked the frame.
t.test("the picker converts by slot, and the plank is left as it displays", function()
    local src = io.open("lib/bookshelf_settings.lua"):read("*a")
    local isnight = src:match("local function _isNight%(%)(.-)\nend\n")
    assert(isnight and isnight:find("editSuffix", 1, true) and not isnight:find("night_mode_sync", 1, true),
        "_isNight must answer for the slot the menu edits (editSuffix), not the frame")
    assert(src:find('raw_key ~= "spine_plank_color"', 1, true), "the plank is stored as it displays")
    local chip = io.open("lib/bookshelf_chip_bar.lua"):read("*a")
    assert(chip:find("CP.resolvePicked(raw_bg)", 1, true),
        "the selected shelf button's colours need the palette's frame correction")
end)

-- Colors for: Light | Dark switches the slot the MENU shows and edits, never
-- what the shelf paints and never KOReader's night mode (maintainer,
-- 2026-10-07: the old row broadcast ToggleNightMode).
t.test("the colour menu's slot is the menu's own: rawColors reads it, the palette does not", function()
    local src = io.open("lib/bookshelf_cover_progress.lua"):read("*a"):gsub("%-%-[^\n]*", "")
    local raw = src:match("function M%.rawColors%(%)(.-)\nend\n")
    assert(raw and raw:find("M.editSuffix()", 1, true), "the menu's labels do not read the slot it edits")
    assert(raw:find("is_night = tostring(is_night) .. sfx", 1, true), "switching the slot is served a stale label cache")
    local mode = src:match("local function _modeSuffix%(%)(.-)\nend\n")
    assert(mode and not mode:find("_edit_slot", 1, true), "the palette paints from the menu's slot")
end)

-- The slot "Colors for:" switches is the Colors menu's alone: it is reset
-- each time Colors opens, and the reader's own look rows outside it (Color
-- behind wallpaper, the plank colour) always read and write the slot the
-- shelf on screen paints from.
t.test("the Colors slot is reset on opening Colors, and never leaks to the rows outside it", function()
    local src = io.open("lib/bookshelf_settings.lua"):read("*a")
    local function body(name)
        local b = src:match("\nfunction Settings:" .. name .. "%((.-)\nend\n")
        assert(b, name .. " moved"); return (b:gsub("%-%-[^\n]*", ""))
    end
    local colors = body("_colorsSubItems")
    local first = colors:find("setEditSlot(nil)", 1, true)
    assert(first and first < colors:find("local items", 1, true), "Colors does not reset the slot when it opens")
    -- Behaviour: _colorValueLabel under a slot left on Dark reads the day key.
    local slot = "dark"
    local CP = { setEditSlot = function(v) slot = v end,
                 editSuffix = function() return slot == "dark" and "_night" or "" end }
    local store = { wallpaper_bg = { grey = 0 }, wallpaper_bg_night = { grey = 255 } }
    local env = setmetatable({
        _ = function(x) return x end,
        BookshelfSettings = { read = function(k) return store[k] end },
        _rawToScreenPct = function(raw) return raw.grey end,
        _valueText = function(raw) return raw.grey .. "%" end,
        require = function(m)
            if m == "lib/bookshelf_cover_progress" then return CP end
            if m == "device" then return { screen = { isColorEnabled = function() return false end } } end
            -- The editing seam: the reader's own keys (a My theme shelf).
            if m == "lib/bookshelf_theme_pack" then return { partRead = function(k) return store[k] end } end
            error(m)
        end,
    }, { __index = _G })
    local code = "local Settings = {}\nfunction Settings:_shelfSlot(" .. body("_shelfSlot") .. "\nend\n"
        .. "function Settings:_colorValueLabel(" .. body("_colorValueLabel") .. "\nend\nreturn Settings"
    local chunk = assert((loadstring or load)(code, "=s", "t", env))
    if setfenv then setfenv(chunk, env) end
    local S = chunk()
    eq(S:_colorValueLabel("wallpaper_bg"), "0%", "a row outside Colors read the slot Colors was left on")
    eq(slot, nil)
    local bg = body("_wallpaperMenu")
    local _a, n = bg:gsub("self:_shelfSlot%(%)", "")
    assert(n >= 2, "Color behind wallpaper's pick or reset does not use the shelf's slot")
end)

t.done()
