-- tests/_test_empty_chip_panel.lua
-- A chip with nothing in it still gets the panel behind its hero (issue 423).
--
-- WHAT NEEDS PINNING. The shelf paints one panel behind the hero, the gap
-- under it and the chip bar, and it does that by wrapping the paintTo of the
-- group those live in. The empty-chip branch of _rebuild builds its own group
-- -- hero, chip bar, placeholder card -- and returned before the panel was
-- ever attached, on the reasoning that "an empty library has no hero to
-- band". An empty CHIP is not an empty library: the hero still shows what you
-- are reading, and the chip bar is still there to switch away with.
--
-- On a white page nobody noticed. Over a wallpaper (5.1) the hero's white
-- text landed straight on the picture, and because the panel is a scrim
-- rather than an opaque fill, whatever the previous frame had left in that
-- band showed through it -- the doubled cover and progress bar in the
-- reporter's screenshot. Rig, PW5 profile, switching to an empty chip:
-- before, the hero stood on bare wallpaper; after, the same panel the shelf
-- gets.
--
-- Usage (from plugin root): lua tests/_test_empty_chip_panel.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local src = io.open("lib/bookshelf_widget.lua"):read("*a")

local function extract(name, sig)
    local pat = "\nfunction " .. name:gsub("[%.%(%)%-]", "%%%0") .. sig .. "\n(.-)\nend\n"
    local body = src:match(pat)
    assert(body, name .. " moved or was renamed")
    return body
end

local function loadAttach(env)
    local fn = assert(load("return function(self, vgroup, opts)\n"
        .. extract("BookshelfWidget:_attachTopPanel", "%(vgroup, opts%)")
        .. "\nend", "_attachTopPanel", "t", env))
    return fn()
end

local function newEnv()
    local e = { painted = {} }
    e.Size = { radius = { window = 9 }, line = { medium = 2 } }
    e.Blitbuffer = { gray = function(v) return { grey = v } end }
    e.Wallpaper = {
        scrim = function(_bb, x, y, w, h, ground, strength, radius)
            e.painted[#e.painted + 1] =
                { "scrim", x = x, y = y, w = w, h = h,
                  ground = ground, strength = strength, radius = radius }
        end,
        setPanel = function(x, y, w, h)
            e.painted[#e.painted + 1] = { "setPanel", x = x, y = y, w = w, h = h }
        end,
    }
    e.pairs, e.ipairs, e.type, e.tostring, e.math = pairs, ipairs, type, tostring, math
    return e
end

-- A widget stub whose plan answers what the scenario wants.
local function newSelf(plan)
    return {
        -- four returns, spelled out: an and/or unpack truncates to one
        _topPanelPlan   = function() return plan[1], plan[2], plan[3], plan[4] end,
        footerPanelRect = function() return 10, 1500, 1000, 80 end,
        _isListMode     = function() return false end,
    }
end

local COLORS = { panel_bg = { grey = 0.9 } }

t.test("the panel is attached to the group, covering hero plus chip bar", function()
    local env = newEnv()
    local attach = loadAttach(env)
    local self_ = newSelf({ 0.5, COLORS, env.Wallpaper, 4 })
    local painted_child = false
    local vgroup = { paintTo = function() painted_child = true end }
    local ok = attach(self_, vgroup, { band_h = 600, content_w = 1200, PAD = 8 })
    eq(ok, true, "a wallpapered shelf must get a panel")
    vgroup.paintTo(vgroup, {}, 20, 30)
    eq(env.painted[1][1], "scrim", "the scrim goes down first")
    -- bleed 4: the band is drawn from PAD-bleed, out by bleed on each side.
    eq(env.painted[1].x, 16, "panel x = child x - bleed")
    eq(env.painted[1].y, 26, "panel y = child y - bleed")
    eq(env.painted[1].w, 1208, "panel w = content + bleed on both sides")
    eq(env.painted[1].h, 608, "panel h = band + bleed on both sides")
    eq(env.painted[2][1], "setPanel", "restore() has to be told where the tint is")
    eq(painted_child, true, "the group's own children still paint, over the panel")
end)

t.test("no panel wanted: paintTo is left exactly as it was", function()
    local env = newEnv()
    local attach = loadAttach(env)
    local self_ = newSelf({ 0, nil, nil, 0 })
    local original = function() end
    local vgroup = { paintTo = original }
    local ok = attach(self_, vgroup, { band_h = 600, content_w = 1200, PAD = 8 })
    eq(ok, false, "a shelf with no picture and no tint gets no panel")
    eq(vgroup.paintTo, original, "paintTo must not be wrapped for nothing")
    eq(#env.painted, 0)
end)

t.test("a negative origin is clamped, not handed to the blitter", function()
    local env = newEnv()
    local attach = loadAttach(env)
    local self_ = newSelf({ 0.5, COLORS, env.Wallpaper, 8 })
    local vgroup = { paintTo = function() end }
    attach(self_, vgroup, { band_h = 100, content_w = 200, PAD = 16 })
    vgroup.paintTo(vgroup, {}, 2, 2)   -- bleed 8 would put the panel at -6
    eq(env.painted[1].x, 0, "x clamped to the screen")
    eq(env.painted[1].y, 0, "y clamped to the screen")
    eq(env.painted[1].w, 216 - 6, "width absorbs the clamp")
    eq(env.painted[1].h, 116 - 6, "height absorbs the clamp")
end)

t.test("the empty-chip branch attaches it too", function()
    -- The bug was structural: that branch returns before the shelf's own
    -- panel code, so it has to ask for one itself.
    local empty = src:match("(self%._hero_parent = empty_vgroup.-\n    end\n)")
    assert(empty, "the empty-chip branch moved")
    assert(empty:find("_attachTopPanel(empty_vgroup", 1, true),
        "the empty-chip branch must attach the top panel")
end)

t.test("both tree builders go through the one painter", function()
    local n = select(2, src:gsub("self:_attachTopPanel%(", ""))
    eq(n, 2, "exactly two callers: the shelf and the empty chip")
    assert(not src:find("local inner_paint = inner_vgroup.paintTo", 1, true),
        "the inline copy in _rebuild should be gone")
end)

t.done()
