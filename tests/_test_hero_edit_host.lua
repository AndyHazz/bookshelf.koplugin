-- tests/_test_hero_edit_host.lua
-- The top panel's layout-editor host. The editor fades the whole screen and
-- floats its bars over the shelf; the panel's in-place swap repaints only the
-- panel, so leaving edit mode must repaint the whole shelf or the fade and the
-- bars stay on screen (rig, 2026-10-24). Renders while editing stay in place.
package.path = "./?.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()

local src = io.open("lib/bookshelf_hero_modules.lua"):read("*a")
local body = src:match("\nfunction HeroModules%.heroEditHost%(bw%)\n(.-)\nend\n")
assert(body, "no heroEditHost")

local dirty
local UIManager = { setDirty = function(_self, w, how) dirty[#dirty + 1] = { w = w, how = how } end }
local function host(bw)
    local env = setmetatable({ UIManager = UIManager, HeroModel = {}, Geom = { new = function(_s, o) return o end } },
                             { __index = _G })
    return assert(load("local bw = ...\n" .. body, "host", "t", env))(bw)
end

t.test("leaving edit mode repaints the whole shelf", function()
    dirty = {}
    local bw = { _swapMicroHeroInPlace = function() return true end }
    host(bw).render(nil, nil)
    assert(#dirty == 1 and dirty[1].w == bw and dirty[1].how == "ui", "the fade and bars were left on screen")
end)

t.test("a render while editing stays in place", function()
    dirty = {}
    local bw = { _swapMicroHeroInPlace = function() return true end }
    host(bw).render(nil, { "working copy" })
    assert(#dirty == 0, "every edit repainted the whole shelf")
end)

t.done()
