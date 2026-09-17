-- tests/_test_first_run_defaults.lua
-- What a brand new install looks like before anyone touches a setting.
--
-- WHY THIS IS PINNED. Every value here is an ordinary setting the reader can
-- change, which is exactly why they drift: each one looks harmless on its own
-- and nothing else in the suite would notice. Together they are the first
-- impression, and they were chosen deliberately -- they are the maintainer's
-- own shelf settings, adopted so that a first launch shows what the plugin is
-- for rather than what it could do on day one.
--
-- Change any of them on purpose and update this file in the same commit. The
-- test exists to make that a decision rather than an accident.
--
-- Usage (from plugin root): lua tests/_test_first_run_defaults.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local tabs  = io.open("lib/bookshelf_tab_model.lua"):read("*a")
local wall  = io.open("lib/bookshelf_wallpaper.lua"):read("*a")
local hero  = io.open("lib/bookshelf_hero_modules_model.lua"):read("*a")
local widget = io.open("lib/bookshelf_widget.lua"):read("*a")
local set   = io.open("lib/bookshelf_settings.lua"):read("*a")

-- One default chip's declaration, from its id to the end of its entry.
local function chip(id)
    return tabs:match('({ id = "' .. id .. '".-enabled = %a+%s*},)')
end

t.test("Home opens as a spine shelf, newest first, with ornaments standing", function()
    local home = chip("all")
    assert(home, "the Home chip declaration moved")
    assert(home:find('view_mode = "spines"', 1, true),
        "Home no longer opens on spines, which is the view the shelf is for")
    assert(home:find('key = "date_added",  reverse = true', 1, true),
        "Home should lead with the newest book, not with a filename")
    assert(home:find("ornament_frequency = 2", 1, true),
        "ornaments should be Always on the shelf a new reader sees first: at "
        .. "the lower stops a one-row shelf can roll nothing for ever")
    assert(home:find("spine_face_out", 1, true),
        "some books should stand face out, or every spine looks the same")
end)

t.test("Series opens on collage cards, most recently read first", function()
    local series = chip("series")
    assert(series, "the Series chip declaration moved")
    assert(series:find('group_display = "collage"', 1, true),
        "collage shows the member covers, which is the reason to group by series")
    assert(series:find('key = "last_opened",  reverse = true', 1, true),
        "the series the reader is in belongs at the front, not the one "
        .. "starting with A")
    assert(series:find('key = "series_index", reverse = false', 1, true),
        "within a group the books belong in series order")
end)

t.test("the hero dashboard seeds two modules, not one", function()
    local body = hero:match("function M.DEFAULTS%(%)(.-)\nend\n")
    assert(body, "the hero defaults moved")
    assert(body:find('module = "analogue_clock"', 1, true), "the clock is gone")
    assert(body:find('module = "quote_of_day"', 1, true),
        "the quote is gone; one module alone reads as a placeholder")
    -- Both must be modules that work with no network and no statistics, which
    -- is what qualifies one to be seeded rather than chosen.
    local n = select(2, body:gsub('type = "module"', ""))
    eq(n, 2, "expected exactly two seeded modules, found " .. n)
end)

t.test("panel shading defaults to Heavy", function()
    local v = tonumber(wall:match("M.SCRIM_DEFAULT = ([%d%.]+)"))
    assert(v, "SCRIM_DEFAULT moved")
    -- The menu's own Heavy stop, so the two cannot drift apart.
    local heavy = tonumber(set:match('{ value = ([%d%.]+),%s*label = function%(%) return _%("Heavy"%)'))
    assert(heavy, "the Heavy stop moved")
    eq(v, heavy, "the default is no longer the Heavy stop")
    assert(v > 0.6, "shading went back down; legibility over a busy picture "
        .. "was the reason it was raised")
end)

t.test("the footer counts pages", function()
    assert(widget:find('BookshelfSettings.read("pagination_format", "pages")', 1, true),
        "the counter's own default changed")
    local row = set:match('key     = "pagination_format",\n%s*default = "(%a+)"')
    eq(row, "pages", "the menu row's default disagrees with the counter's")
end)

t.done()
