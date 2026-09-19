-- tests/_test_night_mode_source.lua
-- The shelf's palette follows the same night-mode state its pictures do.
--
-- WHAT NEEDS PINNING. There are two pieces of night-mode state in a running
-- KOReader, and they are written in different places:
--
--   * Screen.night_mode -- ffi/framebuffer.lua's own flag, flipped by
--     fb:toggleNightMode(), which also sets the panel's HW inversion. This is
--     what ImageWidget pre-inverts against, so it is what every PICTURE on the
--     shelf is drawn for: the wallpaper, the covers, the ornaments.
--   * G_reader_settings "night_mode" -- the persisted preference, written
--     separately by DeviceListener:onToggleNightMode AFTER it flips the screen.
--
-- Anything that flips the screen without going through that event handler --
-- a home-screen replacement with its own night-mode control, for one -- leaves
-- the two disagreeing. The palette read the SETTING while the pictures
-- followed the SCREEN, so the shelf painted its day colours behind a wallpaper
-- that had been pre-inverted for night, or the reverse: "it seems to set night
-- as day and vice versa" (issue 426, with the background removed it behaves,
-- because plain chrome inverted once still reads as night).
--
-- The screen flag is the one that decides what the frame will look like, so it
-- is the one the palette follows too. The setting stays as the fallback for
-- anything that cannot see a screen.
--
-- Usage (from plugin root): lua tests/_test_night_mode_source.lua
package.path = "./?.lua;" .. package.path

local function make_widget_base()
    local W = {}
    W.__index = W
    function W:extend(o) o = o or {}; setmetatable(o, self); self.__index = self; return o end
    function W:new(o) o = o or {}; setmetatable(o, self); self.__index = self; if self.init then self:init() end; return o end
    function W:init() end
    return W
end

for _, name in ipairs({
    "ui/widget/widget",
    "ui/widget/overlapgroup",
    "ui/widget/container/framecontainer",
    "ui/widget/container/centercontainer",
}) do
    package.preload[name] = function() return make_widget_base() end
end
package.preload["ui/widget/textwidget"] = function() return { new = function(_, t) return t end } end
package.preload["ui/font"] = function() return { getFace = function() return {} end } end
package.preload["ui/geometry"] = function()
    return { new = function(_, t) return setmetatable(t or {}, { __index = {} }) end }
end
package.preload["ffi/blitbuffer"] = function()
    return {
        Color8     = function(n) return { v = n } end,
        ColorRGB32 = function(r,g,b,a) return { r=r, g=g, b=b, a=a } end,
        COLOR_WHITE = {}, COLOR_BLACK = {},
    }
end
package.preload["ffi"] = function()
    return { typeof = function() return {} end, istype = function() return false end,
             metatype = function() end, cdef = function() end, new = function() return {} end }
end
-- The one screen table the module holds a reference to, so a test can move
-- the flag the way fb:toggleNightMode() does.
local screen = {
    isColorEnabled = function() return false end,
    scaleBySize    = function(_, n) return n end,
    night_mode     = false,
}
package.preload["device"] = function() return { screen = screen } end
package.preload["lib/bookshelf_color"] = function()
    return { parseColorValue = function(v) return v end }
end
local S = {}
package.preload["lib/bookshelf_settings_store"] = function()
    return {
        read       = function(k) return S[k] end,
        save       = function(k, v) S[k] = v end,
        isTrue     = function(k) return S[k] == true end,
        nilOrTrue  = function(k) return S[k] == nil or S[k] == true end,
        generation = function() return 1 end,
    }
end

local CP = require("lib/bookshelf_cover_progress")
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

-- setting: what G_reader_settings says. panel: what the framebuffer says.
local function state(setting, panel)
    _G.G_reader_settings = {
        isTrue      = function(_s, k) return k == "night_mode" and setting or false end,
        readSetting = function() return nil end,
    }
    screen.night_mode = panel
    S[CP.THEME_SETTING] = nil          -- "auto": follow the device
end

t.test("they agree, day: the shelf is light", function()
    state(false, false)
    local dark, inverting = CP.theme()
    eq(dark, false); eq(inverting, false)
end)

t.test("they agree, night: the shelf is dark", function()
    state(true, true)
    local dark, inverting = CP.theme()
    eq(dark, true); eq(inverting, true)
end)

t.test("panel inverting, setting not: follow the panel", function()
    -- Something flipped the screen without writing the setting. The frame WILL
    -- be inverted and the wallpaper has been pre-inverted to match, so the
    -- palette has to agree or the two fight.
    state(false, true)
    local dark, inverting = CP.theme()
    eq(dark, true, "the palette ignored the panel and painted day colours")
    eq(inverting, true)
end)

t.test("setting on, panel not: follow the panel", function()
    state(true, false)
    local dark, inverting = CP.theme()
    eq(dark, false, "the palette painted night colours into a frame nothing inverts")
    eq(inverting, false)
end)

t.test("an explicit choice still beats both", function()
    state(false, true)
    S[CP.THEME_SETTING] = "light"
    eq(select(1, CP.theme()), false, "an explicit light theme must win")
    S[CP.THEME_SETTING] = "dark"
    state(true, false)
    S[CP.THEME_SETTING] = "dark"
    eq(select(1, CP.theme()), true, "an explicit dark theme must win")
    S[CP.THEME_SETTING] = nil
end)

t.test("no screen flag to read: fall back to the setting", function()
    -- Anything that has no framebuffer of its own (a test, an odd platform)
    -- keeps the old behaviour rather than defaulting to day.
    state(true, nil)
    eq(select(1, CP.theme()), true, "with no panel flag the setting is all there is")
    state(false, nil)
    eq(select(1, CP.theme()), false)
end)

t.test("nothing paints from the setting behind the helper's back", function()
    -- The split is the bug (issue 426), so the rule is pinned here rather
    -- than left to reviewers: one module owns the question.
    local lfs_ok, lfs = pcall(require, "lfs")
    local files = {}
    if lfs_ok then
        for name in lfs.dir("lib") do
            if name:match("%.lua$") then files[#files + 1] = "lib/" .. name end
        end
    else
        local pipe = io.popen("ls lib/*.lua")
        for line in pipe:lines() do files[#files + 1] = line end
        pipe:close()
    end
    files[#files + 1] = "main.lua"
    -- The helper itself, and the %nightmode TOKEN, which deliberately reports
    -- the reader's persisted preference rather than what the panel is doing.
    local allowed = {
        ["lib/bookshelf_night_mode_sync.lua"] = true,
        ["lib/bookshelf_tokens.lua"]          = true,
    }
    local offenders = {}
    for _i = 1, #files do
        local f = files[_i]
        if not allowed[f] then
            local fh = io.open(f)
            if fh then
                local src = fh:read("a"); fh:close()
                if src:find('isTrue("night_mode")', 1, true) then
                    offenders[#offenders + 1] = f
                end
            end
        end
    end
    eq(table.concat(offenders, ", "), "",
        "these read the night-mode setting directly instead of NightModeSync.active()")
end)

t.done()
