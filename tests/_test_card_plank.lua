-- tests/_test_card_plank.lua
-- A card shelf's own plank (maintainer, 5.6: "plank style in the shelf style
-- menu", card shelves only). The plank a spine row stands on is looked up at
-- BUILD (its drop and rise size the row) and at PAINT (the contact shade
-- darkens the design), from whichever shelf is on the main screen. A card
-- drawing its own shelf holds an override for both.
package.path = "./?.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()
local src = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")
local card = io.open("micromodules/shelf.lua"):read("*a")
local tp = io.open("lib/bookshelf_theme_pack.lua"):read("*a")

local body = src:match("\nfunction SpineShelf%.activePlankDesign%(%)\n(.-)\nend\n")

t.test("an override, while held, is the plank (false: the plain colour)", function()
    assert(body, "activePlankDesign not found")
    assert(body:find("SpineShelf._design_override", 1, true), "no override")
    local i = body:find("SpineShelf._design_override", 1, true)
    assert(i < body:find("_design_gen == key", 1, true), "the override must come before the memo")
end)

t.test("withPlank holds it for a build and restores what was there", function()
    local f = src:match("\nfunction SpineShelf%.withPlank%(design, fn, %.%.%.%)\n(.-)\nend\n")
    assert(f, "SpineShelf.withPlank not found")
    local env = { pcall = pcall, error = error, select = select, unpack = table.unpack or unpack,
                  SpineShelf = { _design_override = "outer" } }
    local run = load("local design, fn = ...\n" .. f, "wp", "t", env)
    local seen
    run("mine", function() seen = env.SpineShelf._design_override end)
    assert(seen == "mine", "not held during fn")
    assert(env.SpineShelf._design_override == "outer", "not restored")
    pcall(run, "x", function() error("boom") end)
    assert(env.SpineShelf._design_override == "outer", "not restored after an error")
end)

t.test("a plank choice resolves as the theme's own does", function()
    local f = tp:match("\nfunction M%.plankForChoice%(choice%)\n(.-)\nend\n")
    assert(f, "ThemePack.plankForChoice not found")
    local env = { M = {
        designsOn = function() return true end,
        builtinPlank = function() return "OAK" end,
        _packPlank = function(id) return id == "p.walnut" and "WALNUT" or nil end,
    } }
    local pfc = load("local choice = ...\n" .. f, "pfc", "t", env)
    assert(pfc("colour") == false)
    assert(pfc("oak") == "OAK")
    assert(pfc("p.walnut") == "WALNUT")
    assert(pfc(nil) == nil, "unset follows the main shelf")
    assert(pfc("p.gone") == nil, "a missing pack follows the main shelf")
    env.M.designsOn = function() return false end
    assert(pfc("oak") == false, "designs off (Performance tweaks) draws the colour")
end)

t.test("a card holds its shelf's plank for its build and its paint", function()
    local sb = card:match("\nlocal function spineBody%(ctx, tab, w, h, gap, label%)\n(.-)\nend\n")
    assert(sb and sb:find("withPlank", 1, true), "the build does not hold it")
    assert(card:find("PlankScope", 1, true), "the paint does not hold it")
end)

t.done()
