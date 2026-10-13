-- tests/_test_color_pct_parity.lua
-- A colour row and the picker it opens must say the same number.
--
-- WHAT WENT WRONG. "Shelf plank colour shows 46% in the top menu, and 45% in
-- the modal menu." Two derivations of one idea, which is how it always goes:
--
--   * the ROW converted whatever was stored. For a hex it took the Rec.601
--     luminance and turned that into "% black on screen". The plank ships as
--     #B08050, luminance 137, which reads 46% by day.
--   * the PICKER only understood a stored `grey`. Handed a hex it found
--     nothing and fell back to the row's hardcoded default_pct, which for the
--     plank is 45.
--
-- So the two numbers were never related. They happened to sit a point apart,
-- which is worse than a wild disagreement: it reads as a rounding bug and
-- sends you looking at the arithmetic rather than at the missing branch.
--
-- Usage (from plugin root): lua tests/_test_color_pct_parity.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq
local src = io.open("lib/bookshelf_settings.lua"):read("*a")

local body = src:match("\nlocal function _rawToScreenPct%(raw%)\n(.-)\nend\n")
assert(body, "_rawToScreenPct missing: the one derivation both sides must share")

local function pct(raw, night)
    local env = {
        type = type, tonumber = tonumber, math = math,
        _byteToScreenPct = function(b)
            if night then return math.floor(b * 100 / 0xFF + 0.5) end
            return math.floor((0xFF - b) * 100 / 0xFF + 0.5)
        end,
    }
    local fn = assert(load("return function(raw)\n" .. body .. "\nend", "pct", "t", env))
    return fn()(raw)
end

t.test("the plank's own hex reads 46%, which is what the row showed", function()
    eq(pct({ hex = "#B08050" }, false), 46)
end)

t.test("a stored grey reads the same as it always did", function()
    eq(pct({ grey = 0x00 }, false), 100, "black is 100% black by day")
    eq(pct({ grey = 0xFF }, false), 0)
end)

t.test("night mode flips it, because the panel inverts at display time", function()
    eq(pct({ grey = 0x00 }, true), 0)
    eq(pct({ hex = "#B08050" }, true), 54)
end)

t.test("nothing stored yields nothing, so the caller can fall back", function()
    eq(pct(nil, false), nil)
    eq(pct({}, false), nil)
    eq(pct("not a table", false), nil)
end)

t.test("the picker starts from the stored value, not from the row's default", function()
    local picker = src:match("function Settings:_pickColor%(raw_key, field, default_pct, title,(.-)\nend\n")
    assert(picker, "_pickColor moved or was renamed")
    assert(picker:find("_rawToScreenPct(raw)", 1, true),
        "the picker still derives its own starting value, so a hex-stored "
        .. "colour opens on the row's default instead of on what is stored")
    assert(not picker:find("byte and _byteToScreenPct(byte) or default_pct", 1, true),
        "the grey-only branch is back")
end)

t.test("both labels go through it too, so all three agree", function()
    local n = select(2, src:gsub("_rawToScreenPct%(", ""))
    assert(n >= 3,
        "expected the definition plus the labels' one helper and the picker, found " .. n)
    local cvl = src:match("function Settings:_colorValueLabel%(raw_key, _default_pct%)(.-)\nend\n")
    assert(cvl and cvl:find("_valueText(", 1, true), "the look rows' label has its own derivation again")
    local vl = src:match("local function valueLabel%(field%)(.-)\n    end\n")
    assert(vl and vl:find("_valueText(", 1, true), "the Colors rows' label has its own derivation again")
    -- The Rec.601 constants should now live in exactly one place.
    local lum = select(2, src:gsub("0%.587", ""))
    eq(lum, 1, "the luminance conversion is written " .. lum .. " times; it was three")
end)

-- ── One form per screen (maintainer, 2026-10-08) ─────────────────────────
-- Colors listed "Text ink: 100%" beside "Progress bar: #228B22": a grey was a
-- percentage and a picked colour a hex on the same screen, and the palette
-- came up under a "(% black)" title. The form now follows the picker: hex on
-- a colour screen, "% black" on greyscale, and the title with it.
local function grab(name)
    local b = src:match("\nlocal function " .. name .. "%((.-)\nend\n")
    assert(b, name .. " missing")
    return "local function " .. name .. "(" .. b .. "\nend\n"
end
local function helpers_env(colour, night)
    local env = setmetatable({
        _ = function(x) return x end,
        require = function(m)
            if m == "device" then return { screen = { isColorEnabled = function() return colour end } } end
            if m == "lib/bookshelf_color" then
                return { invertValue = function(v)
                    if v.grey then return { grey = 255 - v.grey } end
                    local r, g, b = tonumber(v.hex:sub(2, 3), 16), tonumber(v.hex:sub(4, 5), 16), tonumber(v.hex:sub(6, 7), 16)
                    return { hex = string.format("#%02X%02X%02X", 255 - r, 255 - g, 255 - b) }
                end }
            end
            error("unexpected require " .. m)
        end,
    }, { __index = _G })
    local code = "local function _isNight() return " .. tostring(night) .. " end\n"
        .. grab("_byteToScreenPct") .. grab("_rawToScreenPct") .. grab("_colorScreen")
        .. grab("_shownHex") .. grab("_valueText")
        .. "return _valueText, _colorScreen"
    return assert(load(code, "vt", "t", env))()
end

t.test("a colour screen shows every value as the palette's hex, a grey too", function()
    local vt = helpers_env(true, false)
    eq(vt({ grey = 0xFF }), "#FFFFFF"); eq(vt({ grey = 0x40 }), "#404040")
    eq(vt({ hex = "#228b22" }), "#228B22"); eq(vt(nil), "default")
end)

t.test("a greyscale screen shows every value as % black, a hex too", function()
    local vt = helpers_env(false, false)
    eq(vt({ grey = 0x00 }), "100%"); eq(vt({ hex = "#B08050" }), "46%")
end)

t.test("the night slot shows what the picker shows: the stored colour turned back", function()
    local vt = helpers_env(true, true)
    eq(vt({ hex = "#000000" }), "#FFFFFF", "a pre-inverted night colour shown as stored")
    eq(vt({ hex = "#000000" }, "spine_plank_color"), "#000000", "the plank is stored as it displays")
end)

t.test("the picker's title, its palette and the rows ask one question of the screen", function()
    local picker = src:match("function Settings:_pickColor%(raw_key, field, default_pct, title,(.-)\nend\n")
    assert(picker:find("local colour = _colorScreen()", 1, true), "the picker asks the screen its own way")
    assert(picker:find("if type(title) == \"table\" then title = colour and title[1] or title[2] end", 1, true),
        "the title does not follow the palette")
    assert(picker:find("if colour then", 1, true), "the palette branch does not use the same answer")
    assert(not src:find('_pickColor%([^\n]*\n[^\n]*_%("[^"]+ %(%% black%)"%), touchmenu'),
        "a colour row still passes only a (% black) title")
    for t_ in src:gmatch('_%("([^"]+) %(%% black%)"%)') do
        assert(src:find('{ _("' .. t_ .. '"), _("' .. t_ .. ' (% black)") }', 1, true),
            "no palette title for " .. t_)
    end
end)

t.test("an untouched colour's hex field opens on the colour its row shows", function()
    -- The row read "Progress bar: #404040" and the field opened empty: the
    -- picker was only handed what was STORED, and a default is not stored.
    local picker = src:match("function Settings:_pickColor%(raw_key, field, default_pct, title,(.-)\nend\n")
    assert(picker:find("hex_text = _shownHex(CoverProgress.rawColors()[field], raw_key)", 1, true),
        "the field is not seeded from the row's own value")
    assert(picker:find("wood and wood.special_tile or nil, hex_text)", 1, true),
        "the seed is not passed to the palette")
    local pal = io.open("lib/bookshelf_color_palette.lua"):read("*a")
    assert(pal:find("local initial_text = self.selected_hex or self.hex_text or \"\"", 1, true),
        "the palette does not start its hex field from hex_text")
    assert(pal:find("special_tile, hex_text)\n        showColorPicker(self, title, current_hex, default_hex, on_apply, on_default, on_revert, touchmenu_instance, null_tile_label, white_hex, special_tile, hex_text)", 1, true),
        "the installed method drops hex_text")
    -- Seeding the field must not mark a swatch: only selected_hex does.
    assert(pal:find("local is_selected = (hex == self.selected_hex)", 1, true))
end)

t.done()
