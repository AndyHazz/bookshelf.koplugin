-- tests/_test_module_palette_hosts.lua
-- The module palette (card colour + ink) is process-global. Each host must set
-- the palette that matches the ground IT paints, every time it renders cards,
-- not once per hero build (maintainer, PW5, a dark-themed shelf):
--   * the start menu's panel is always white: after the dark shelf's grid had
--     been built, its cards came up dark on the white panel;
--   * the full-screen view opened from the READER has no shelf behind it and
--     paints white: its cards took the last shelf's dark palette;
--   * a single card re-render (clock tick, reload) after another host had
--     changed the palette drew in that host's colours.
package.path = "./?.lua;" .. package.path
local t  = dofile("tests/_helpers.lua").runner()
local hm = io.open("lib/bookshelf_hero_modules.lua"):read("*a")
local sm = io.open("lib/bookshelf_start_menu.lua"):read("*a")

local function fn(src, name)
    return src:match("\nfunction " .. name:gsub("[%.%:]", "%%%0") .. "%(.-\nend\n")
end

t.test("every start menu build uses the light palette its white panel needs", function()
    local b = fn(sm, "StartMenu:_build")
    assert(b, "StartMenu:_build not found")
    assert(b:find("Modules.resetTheme", 1, true), "_build does not reset the palette")
end)

local apply = hm:match("\nfunction HeroModules%._applyPalette%(bw%)\n(.-)\nend\n")

local function runApply(bw)
    assert(apply, "HeroModules._applyPalette not found")
    local log = {}
    local env = {
        pcall = pcall, require = function() return {} end, type = type, math = math,
        Modules = {
            resetTheme = function() log[#log + 1] = "reset" end,
            setCardBg = function() log[#log + 1] = "card" end,
            setInk = function() log[#log + 1] = "ink" end,
        },
        _moduleCardBg = function() return "shelfcard" end,
        Blitbuffer = { Color8 = function(v) return v end },
    }
    assert(load("local bw = ...\n" .. apply, "apply", "t", env))(bw)
    return table.concat(log, ",")
end

t.test("under the reader the grid uses the light palette", function()
    assert(runApply({ _reader_context = true }) == "reset", runApply({ _reader_context = true }))
end)

t.test("on the shelf the grid uses the shelf's palette", function()
    local got = runApply({})
    assert(got:find("card") and got:find("ink") and not got:find("reset"), got)
end)

t.test("the grid build and every single-card re-render set the palette first", function()
    local build = fn(hm, "HeroModules.build")
    assert(build and build:find("HeroModules._applyPalette(bw)", 1, true), "build")
    local swap = fn(hm, "HeroModules._swapCell")
    assert(swap and swap:find("HeroModules._applyPalette(bw)", 1, true), "_swapCell")
    assert(swap:find("_applyPalette", 1, true) < swap:find("_makeCell", 1, true),
        "the palette must be set before the cell renders")
end)

t.done()
