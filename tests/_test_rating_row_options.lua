-- tests/_test_rating_row_options.lua
-- Issue 484: the top panel's Rating row has options of its own.
--
-- Usage (from plugin root): lua tests/_test_rating_row_options.lua
--
-- The row used to be on or off: on, every book showed five stars, rated or
-- not. A reader who rates only what they have read wanted no empty stars on
-- the rest. The row opens a submenu now:
--   Show Hardcover rating when a book has one   (the Hardcover switch)
--   Show your stars on: All books | Rated and finished books | Rated books only
--   Tap a star to rate                          (the gesture switch)
-- Long-press still turns the row on or off.

package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local stored
package.loaded["lib/bookshelf_settings_store"] = {
    read = function(k) if k == "hero_regions" then return stored end end,
    save = function(k, v) if k == "hero_regions" then stored = v end end,
    delete = function(k) if k == "hero_regions" then stored = nil end end,
}
local Regions = dofile("lib/bookshelf_hero_regions.lua")

-- Regions.ratingShown(mode, book): does this book show the reader's own stars?
t.test("all books (and unset): every book shows its stars, as before", function()
    eq(Regions.ratingShown(nil, {}), true)
    eq(Regions.ratingShown("all", {}), true)
    eq(Regions.ratingShown("all", { status = "reading" }), true)
end)

t.test("rated and finished: a rated book, or a finished one waiting to be rated", function()
    eq(Regions.ratingShown("rated_finished", { rating = 4, status = "reading" }), true)
    eq(Regions.ratingShown("rated_finished", { status = "complete" }), true)
    eq(Regions.ratingShown("rated_finished", { status = "finished" }), true)
    eq(Regions.ratingShown("rated_finished", { status = "reading" }), false)
    eq(Regions.ratingShown("rated_finished", { status = "abandoned" }), false)
    eq(Regions.ratingShown("rated_finished", {}), false)
end)

t.test("rated only: nothing until a rating exists", function()
    eq(Regions.ratingShown("rated", { rating = 1 }), true)
    eq(Regions.ratingShown("rated", { status = "complete" }), false)
    eq(Regions.ratingShown("rated", { rating = 0 }), false)
    eq(Regions.ratingShown("rated", {}), false)
end)

t.test("a rating stored as text still counts; a mode nobody wrote means all books", function()
    eq(Regions.ratingShown("rated", { rating = "3" }), true)
    eq(Regions.ratingShown("something else", {}), true)
    eq(Regions.ratingShown("rated", nil), false)
end)

t.test("the choice is stored with the row and read back", function()
    stored = nil
    Regions.invalidateCache()
    Regions.write("rating", { disabled = false, show = "rated" })
    eq(Regions.read().rating.show, "rated")
    stored = nil
    Regions.invalidateCache()
    eq(Regions.read().rating.show, nil)
end)

t.test("the choices, in menu order", function()
    eq(table.concat(Regions.RATING_SHOW, ","), "all,rated_finished,rated")
end)

-- The top panel asks before it builds the reader's own stars.
t.test("the panel hides the reader's own stars on books the choice leaves out", function()
    local src = io.open("lib/bookshelf_hero_card.lua"):read("*a")
    local col = assert(src:match("\nfunction HeroCard:_buildRightColumn%(book, regions, state, dimen%)\n(.-)\nend\n"))
    assert(col:find("and Regions.ratingShown(regions.rating.show, book)", 1, true))
end)

-- Settings:_ratingRegionSubItems(), run against stubs.
local st = io.open("lib/bookshelf_settings.lua"):read("*a")
local body = assert(st:match("\nfunction Settings:_ratingRegionSubItems%(%)\n(.-)\nend\n"),
    "_ratingRegionSubItems missing")

local function submenu()
    local world = {
        store = {}, gestures = { rate = true }, hc_available = true,
        region = {}, swaps = 0, dirty = 0, updates = 0,
    }
    local env = {
        ipairs = ipairs, pairs = pairs, type = type, pcall = pcall,
        _ = function(s) return s end,
        BookshelfSettings = {
            isTrue = function(k) return world.store[k] == true end,
            save = function(k, v) world.store[k] = v end,
        },
        require = function(name)
            if name == "lib/bookshelf_hero_regions" then
                return {
                    RATING_SHOW = Regions.RATING_SHOW,
                    read = function() return { rating = world.region } end,
                    snapshot = function() return world.region end,
                    write = function(_k, v) world.region = v end,
                }
            elseif name == "lib/bookshelf_gestures" then
                return {
                    on = function(id) return world.gestures[id] ~= false end,
                    set = function(id, on) world.gestures[id] = on end,
                }
            elseif name == "lib/bookshelf_hardcover" then
                return { isAvailable = function() return world.hc_available end }
            end
            error("unexpected require " .. name)
        end,
    }
    local self = {
        _bw = { _swapHeroRightColumnInPlace = function() world.swaps = world.swaps + 1 end },
        _markDirty = function() world.dirty = world.dirty + 1 end,
    }
    local items = assert(load("return function(self)\n" .. body .. "\nend", "sub", "t", env))()(self)
    local menu = { updateItems = function() world.updates = world.updates + 1 end }
    return items, world, menu
end
local function label(it) return it.text or it.text_func() end

t.test("five rows: Hardcover, three choices of books, tap to rate", function()
    local items = submenu()
    eq(#items, 5)
    eq(label(items[1]), "Show Hardcover rating when a book has one")
    eq(label(items[2]), "Show your stars on all books")
    eq(label(items[3]), "Show your stars on rated and finished books")
    eq(label(items[4]), "Show your stars on rated books only")
    eq(label(items[5]), "Tap a star to rate")
    eq(items[1].separator, true); eq(items[4].separator, true)
    for i = 2, 4 do eq(items[i].radio, true) end
    for i = 1, 5 do eq(items[i].keep_menu_open, true) end
end)

t.test("all books is the choice until another is made; choosing one stores it and redraws the panel", function()
    local items, world, menu = submenu()
    eq(items[2].checked_func(), true); eq(items[3].checked_func(), false)
    items[3].callback(menu)
    eq(world.region.show, "rated_finished")
    eq(items[3].checked_func(), true); eq(items[2].checked_func(), false)
    eq(world.swaps, 1); eq(world.updates, 1)
    items[2].callback(menu)
    eq(world.region.show, nil, "all books is the default, so it stores nothing")
end)

t.test("the Hardcover row is the Hardcover menu's own switch, and needs the plugin", function()
    local items, world, menu = submenu()
    eq(items[1].checked_func(), false)
    eq(items[1].enabled_func(), true)
    items[1].callback(menu)
    eq(world.store.hardcover_hero_rating, true)
    eq(items[1].checked_func(), true)
    eq(world.dirty, 1, "the shelf is redrawn")
    world.hc_available = false
    eq(items[1].enabled_func(), false)
end)

t.test("tap to rate is the gesture switch", function()
    local items, world, menu = submenu()
    eq(items[5].checked_func(), true)
    items[5].callback(menu)
    eq(world.gestures.rate, false)
    eq(items[5].checked_func(), false)
    items[5].callback(menu)
    eq(world.gestures.rate, true)
end)

-- The row in the top panel content menu.
t.test("the Rating row opens the submenu on tap and still toggles on long-press", function()
    local rows = assert(st:match("\nfunction Settings:_heroSubItems%(keys%)\n(.-)\nend\n"))
    assert(rows:find("return self:_ratingRegionSubItems()", 1, true), "tap opens the submenu")
    assert(not rows:find('if key == "rating" then\n                    self:_toggleRegionEnabled', 1, true),
        "tap still toggles")
end)

t.test("the content menu opens with a line saying how its rows work", function()
    local row = assert(st:match('text = _%("Tap a line for its options, long%-press to turn it on or off%."%),\n(%s*enabled = false,)'),
        "the hint is missing, or is a row that can be tapped")
    assert(row)
end)

t.done()
