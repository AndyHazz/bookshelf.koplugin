-- tests/_test_search_view_levels.lua
-- Reddit (maintainer verified): search for an author, the results show as
-- covers, but open the author found and the books show as spines. A drill
-- out of the results took the view settings of the shelf the search was
-- made from. Search now has a shelf's own: Show as covers the results AND
-- what is opened from them; Auto has two levels, the results and inside a
-- result. The shelf's own settings never reach a search.
--
-- Usage (from plugin root): lua tests/_test_search_view_levels.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq
local ViewMode = require("lib/bookshelf_view_mode")

local src = io.open("lib/bookshelf_widget.lua"):read("*a")
local function method(name)
    local b = src:match("\n(function BookshelfWidget:" .. name .. "%(.-\nend)\n")
    assert(b, name .. " moved")
    return b
end

local function widget(settings, path, chip_tab)
    local env = setmetatable({
        BookshelfWidget = {},
        ViewMode = ViewMode,
        _covers_pin = 0,
        BookshelfSettings = { read = function(k) return settings[k] end },
        require = function(n)
            if n == "lib/bookshelf_tab_model" then return { getById = function() return chip_tab end } end
            if n == "lib/bookshelf_sources" then return { isPaged = function() return false end } end
            return require(n)
        end,
    }, { __index = _G })
    for _i, name in ipairs({ "_viewMode", "_chipViewMode", "_isSearchResults", "_searchLevel" }) do
        assert(load(method(name), name, "t", env))()
    end
    return setmetatable({ chip = "home", _drilldown_path = path,
        _isDrilledIn = function(self) return #self._drilldown_path > 0 end },
        { __index = env.BookshelfWidget })
end

local SEARCH = { kind = "search" }
local AUTHOR = { kind = "author" }
-- The shelf searched from: Auto, spines inside (the reporter's).
local SPINY = { [ViewMode.CHIP_KEY] = ViewMode.AUTO, [ViewMode.LEVEL_KEYS[2]] = ViewMode.SPINES }

t.test("a drill out of the results never takes the shelf's settings", function()
    local bw = widget({}, { SEARCH, AUTHOR }, SPINY)
    eq(bw:_viewMode(), ViewMode.COVERS)
end)

t.test("Show as covers the results and what is opened from them", function()
    for _i, m in ipairs({ ViewMode.LIST, ViewMode.SPINES }) do
        eq(widget({ search_view_mode = m }, { SEARCH }, SPINY):_viewMode(), m)
        eq(widget({ search_view_mode = m }, { SEARCH, AUTHOR }, SPINY):_viewMode(), m)
    end
end)

t.test("Auto: the results' level, then inside a result's", function()
    -- Unset: both a list, as Auto search results always were.
    local s = { search_view_mode = ViewMode.AUTO }
    eq(widget(s, { SEARCH }, SPINY):_viewMode(), ViewMode.LIST)
    eq(widget(s, { SEARCH, AUTHOR }, SPINY):_viewMode(), ViewMode.LIST)
    s.search_view_level1, s.search_view_level2 = ViewMode.LIST, ViewMode.SPINES
    eq(widget(s, { SEARCH }, SPINY):_viewMode(), ViewMode.LIST)
    eq(widget(s, { SEARCH, AUTHOR, { kind = "series" } }, SPINY):_viewMode(), ViewMode.SPINES)
end)

t.test("outside a search the shelf's settings still apply", function()
    eq(widget({ search_view_mode = ViewMode.LIST }, { AUTHOR }, SPINY):_viewMode(), ViewMode.SPINES)
end)

t.test("a long-press on the search icon opens how results show", function()
    local s = src:sub(src:find('key        = "search",', 1, true), -1)
    assert(s:sub(1, 400):find("holdable", 1, true), "the search icon is not holdable")
    assert(src:find('if key == "search" then\n                self:_showSearchViewModePicker()', 1, true),
        "its long-press does not open the page")
end)

t.done()
