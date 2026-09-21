-- tests/_test_tab_defaults.lua
-- What a fresh install ships as shelves, and what it does not.
--
-- TWO THINGS THE MAINTAINER ASKED FOR, both from their own device after a
-- "reset to defaults" did not produce the arrangement they meant:
--
--   * Recent opens as a LIST and Genres uses the RIBBON style. Those were
--     the intended defaults and had never been captured in code.
--   * A fresh install ships ONLY the shelves that are on. It used to ship
--     all nine with five switched off, which fills the shelf editor with
--     rows nobody asked for and pushes the help line and "+ Add new shelf"
--     off the bottom -- so the two things a new reader needs to see are the
--     two they cannot.
--
-- THE TRAP THIS GUARDS. DEFAULTS() has three consumers, and one of them is
-- migrate(), which rebuilds a v1 reader's tab list. v1 shipped every chip
-- ENABLED, so rebuilding from the trimmed set would silently delete five
-- shelves they were using. migrate() therefore reads BUILTINS() and only the
-- fresh-install path reads DEFAULTS().
--
-- Usage (from plugin root): lua tests/_test_tab_defaults.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq
local src = io.open("lib/bookshelf_tab_model.lua"):read("*a")

local env = { tr = function(s) return s end, ipairs = ipairs, pairs = pairs }
env.TabModel = {}
for _, name in ipairs({ "BUILTINS", "DEFAULTS" }) do
    local body = src:match("(function TabModel%." .. name .. "%(%).-\nend)")
    assert(body, name .. "() moved or was renamed")
    assert(load(body, name, "t", env))()
end
local BUILTINS, DEFAULTS = env.TabModel.BUILTINS(), env.TabModel.DEFAULTS()

local function byId(list, id)
    for _, x in ipairs(list) do if x.id == id then return x end end
end

t.test("a fresh install ships only the shelves that are on", function()
    eq(#DEFAULTS, 4, "four shelves, so the help line and Add new shelf stay visible")
    local got = {}
    for _, x in ipairs(DEFAULTS) do got[#got + 1] = x.id end
    eq(table.concat(got, ","), "all,recent,series,genres")
    for _, x in ipairs(DEFAULTS) do
        assert(x.enabled ~= false, x.id .. " ships disabled, which is the thing being removed")
    end
end)

t.test("the built-ins still carry the ones left out", function()
    eq(#BUILTINS, 9, "nothing was deleted, only left out of the shipped set")
    for _, id in ipairs({ "latest", "authors", "tags", "languages", "favorites" }) do
        assert(byId(BUILTINS, id), id .. " is gone from BUILTINS entirely")
        assert(not byId(DEFAULTS, id), id .. " should not ship enabled")
    end
end)

t.test("Recent opens as a list", function()
    local r = byId(DEFAULTS, "recent")
    eq(r.view_mode, "list", "the maintainer's intended default")
    -- Density deliberately unpinned: nil means the natural, screen-adaptive
    -- height, and a fixed count reads sparse on a larger panel.
    eq(r.list_rows, nil, "row density must stay unpinned")
end)

t.test("Genres uses the ribbon style", function()
    eq(byId(DEFAULTS, "genres").group_display, "ribbon")
end)

t.test("migrate rebuilds a v1 list from BUILTINS, not the shipped subset", function()
    -- The regression this prevents is silent and destructive: a reader
    -- upgrading straight from v1 loses five shelves they were using.
    local mig = src:match("local function migrate%(%).-\nend")
    assert(mig, "migrate() moved or was renamed")
    assert(mig:find("TabModel.BUILTINS()", 1, true),
        "migrate must use the full built-in set")
    assert(not mig:find("TabModel.DEFAULTS()", 1, true),
        "migrate must NOT rebuild a v1 list from the trimmed defaults")
end)

t.test("every shipped shelf is still a plain, editable pin", function()
    -- Nothing here may be a new kind of setting; they are all things the
    -- reader can change in the editor.
    for _, x in ipairs(DEFAULTS) do
        assert(type(x.id) == "string" and x.id ~= "", "a shelf with no id")
        assert(type(x.source) == "table" and x.source.kind, x.id .. " has no source")
        assert(type(x.filter) == "table", x.id .. " has no filter table")
    end
end)

t.done()
