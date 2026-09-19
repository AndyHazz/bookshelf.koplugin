-- tests/_test_plank_theme_flip.lua
-- The shelf's wood is the same oak whatever the theme and the frame are doing.
--
-- THE REPORT. "Shelf Theme colours, when Dark is selected (when not in Day
-- mode) displays a blue bookshelf instead of the brown as intended. The same
-- goes for Shelf Theme Light when viewed in Night Mode. In Shelf Mode Auto
-- there is no issue."
--
-- WHY. Every colour resolvedColors hands out is written in PAINT space -- for
-- a frame that inverts. A night chrome_bg of 0xFF is a BLACK bar because the
-- frame flips it. So when the shelf's theme and the frame disagree (dark
-- theme on a day frame, or the reverse) every value has to be flipped to
-- survive, which is what `flip` does, and why Auto -- where they always agree
-- -- was the one setting that looked right.
--
-- The plank is the exception: "#B08050" in BOTH palettes, the same oak day
-- and night, because the spine shelf pre-inverts it ITSELF against the
-- screen's own flag. Flipped here as well it came out inverted once too
-- often, and brown inverted is blue.
--
-- Usage (from plugin root): lua tests/_test_plank_theme_flip.lua
package.path = "./?.lua;" .. package.path

local function widget_base()
    local W = {}
    W.__index = W
    function W:extend(o) o = o or {}; setmetatable(o, self); self.__index = self; return o end
    function W:new(o) o = o or {}; setmetatable(o, self); self.__index = self; if self.init then self:init() end; return o end
    function W:init() end
    return W
end
for _, name in ipairs({ "ui/widget/widget", "ui/widget/overlapgroup",
                        "ui/widget/container/framecontainer",
                        "ui/widget/container/centercontainer" }) do
    package.preload[name] = function() return widget_base() end
end
package.preload["ui/widget/textwidget"] = function() return { new = function(_, t) return t end } end
package.preload["ui/font"] = function() return { getFace = function() return {} end } end
package.preload["ui/geometry"] = function()
    return { new = function(_, t) return setmetatable(t or {}, { __index = {} }) end }
end
package.preload["ffi/blitbuffer"] = function()
    return { Color8 = function(n) return { v = n } end,
             ColorRGB32 = function(r,g,b,a) return { r=r,g=g,b=b,a=a } end,
             COLOR_WHITE = {}, COLOR_BLACK = {} }
end
package.preload["ffi"] = function()
    return { typeof = function() return {} end, istype = function() return false end,
             metatype = function() end, cdef = function() end, new = function() return {} end }
end
local screen = { isColorEnabled = function() return true end,
                 scaleBySize = function(_, n) return n end, night_mode = false }
package.preload["device"] = function() return { screen = screen } end
-- Pass the raw value straight through so the test can read what was stored,
-- and MARK an inversion rather than performing one.
package.preload["lib/bookshelf_color"] = function()
    return {
        parseColorValue = function(v) return v end,
        invertValue = function(v)
            return { hex = "FLIPPED", was = type(v) == "table" and v.hex or v }
        end,
    }
end
local S = {}
package.preload["lib/bookshelf_settings_store"] = function()
    return { read = function(k) return S[k] end, save = function(k, v) S[k] = v end,
             isTrue = function(k) return S[k] == true end,
             nilOrTrue = function(k) return S[k] == nil or S[k] == true end,
             generation = function() return S.__gen or 1 end }
end

local CP = require("lib/bookshelf_cover_progress")
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local gen = 0
local function state(theme, frame_inverting)
    gen = gen + 1
    S.__gen = gen                      -- the resolved palette is cached per generation
    S[CP.THEME_SETTING] = theme        -- nil = auto
    screen.night_mode = frame_inverting
    _G.G_reader_settings = {
        isTrue = function(_s, k) return k == "night_mode" and frame_inverting or false end,
        readSetting = function() return nil end,
    }
    return CP.resolvedColors()
end

local COMBOS = {
    { "dark",  false, "the reported one: pinned dark, frame not inverting" },
    { "dark",  true,  "pinned dark, frame inverting" },
    { "light", false, "pinned light, frame not inverting" },
    { "light", true,  "the other reported one: pinned light, frame inverting" },
    { nil,     false, "auto by day" },
    { nil,     true,  "auto at night" },
}

t.test("the wood is the same oak in all four corners", function()
    for _i, c in ipairs(COMBOS) do
        local colors = state(c[1], c[2])
        eq(colors.plank and colors.plank.hex, "#B08050", c[3])
    end
end)

t.test("...while everything else still flips when the two disagree", function()
    -- Proving the exemption is the plank's alone: the flip machinery has to
    -- keep working, or the fix would have been "stop flipping" and every
    -- other colour would come out inverted.
    local mismatched = state("dark", false)
    eq(mismatched.chrome_bg and mismatched.chrome_bg.hex, "FLIPPED",
       "a dark theme on a day frame must still flip its chrome")
    local agreed = state(nil, false)
    assert((agreed.chrome_bg and agreed.chrome_bg.hex) ~= "FLIPPED",
       "auto never disagrees with the frame, so nothing should flip")
end)

t.test("a reader's own plank colour is left alone too", function()
    -- Day and night are independent palettes, so a dark shelf reads the
    -- _night key -- that part is deliberate and unchanged. What matters here
    -- is that whichever one answers comes through unflipped.
    S["spine_plank_color"]       = { hex = "#123456" }
    S["spine_plank_color_night"] = { hex = "#654321" }
    eq(state("light", true).plank.hex, "#123456",
       "the day wood came out inverted on an inverting frame")
    eq(state("dark", false).plank.hex, "#654321",
       "the night wood came out inverted on a day frame")
    S["spine_plank_color"], S["spine_plank_color_night"] = nil, nil
end)

t.test("the source says why, so it is not tidied back into _paint", function()
    local src = io.open("lib/bookshelf_cover_progress.lua"):read("*a")
    local line = src:match("(plank%s+= [^\n]+)")
    assert(line and not line:find("_paint", 1, true),
        "the plank went back through _paint: " .. tostring(line))
    assert(src:find("constantInNight", 1, true),
        "the reason the plank is different should stay written down")
end)

t.done()
