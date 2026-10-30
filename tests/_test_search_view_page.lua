-- tests/_test_search_view_page.lua
-- Long-press the Search results pill: how results are shown, as a page
-- (STYLE.md) with Show as a segmented choice and a sentence saying what it
-- does, not a stock list of checkmarked rows.
--
-- Usage (from plugin root): lua tests/_test_search_view_page.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

local src = io.open("lib/bookshelf_widget.lua"):read("*a")
local body = src:match("\n(function BookshelfWidget:_showSearchViewModePicker%(.-\nend)\n")
assert(body, "_showSearchViewModePicker moved")

local function open(stored)
    local saved, state = { search_view_mode = stored }, { rebuilds = 0, refreshes = 0 }
    local env = setmetatable({
        BookshelfWidget = {},
        _ = function(s) return s end,
        T = function(s, a, b) return (s:gsub("%%1", tostring(a)):gsub("%%2", tostring(b))) end,
        ViewMode = require("lib/bookshelf_view_mode"),
        BookshelfSettings = { read = function(k) return saved[k] end,
            save = function(k, v) saved[k] = v end, flush = function() end },
        UIManager = { setDirty = function() end, close = function() end },
        require = function(name)
            if name == "lib/bookshelf_page_dialog" then
                return { show = function(spec)
                    state.spec = spec
                    return { refresh = function() state.refreshes = state.refreshes + 1 end }
                end }
            end
            if name == "ui/widget/buttondialog" then error("still a ButtonDialog") end
            return require(name)
        end,
    }, { __index = _G })
    assert(load(body, "sv", "t", env))()
    local bw = setmetatable({ _rebuild = function() state.rebuilds = state.rebuilds + 1 end },
        { __index = env.BookshelfWidget })
    bw:_showSearchViewModePicker()
    return state, saved
end

local function seg(state)
    for _i, b in ipairs(state.spec.page().blocks) do
        if b.type == "segmented" then return b end
    end
end

t.test("Show as: Auto, Covers, List, Spines, on the stored one", function()
    local state = open("list")
    local s = seg(state)
    local keys = {}
    for i, it in ipairs(s.items) do keys[i] = it.key end
    eq(table.concat(keys, " "), "auto covers list spines")
    eq(#state.spec.page().blocks, 1, "levels shown though not Auto")
    eq(s.active, "list")
    eq(open(nil).spec.page().blocks[1] ~= nil, true)
    eq(seg(open(nil)).active, "covers")
end)

t.test("a pick saves (Covers as absence), redraws the shelf and the page", function()
    local state, saved = open(nil)
    seg(state).on_pick("spines")
    eq(saved.search_view_mode, "spines")
    eq(state.rebuilds, 1); eq(state.refreshes, 1)
    eq(seg(state).active, "spines")
    seg(state).on_pick("covers")
    eq(saved.search_view_mode, nil)
end)

t.test("no summary line over the choices (maintainer)", function()
    eq(open("list").spec.page().strip, nil)
    eq(open("auto").spec.page().strip, nil)
end)

t.test("Auto: a style for the results and for what is opened from them", function()
    local state, saved = open("auto")
    local m = state.spec.page()
    local levels = {}
    for _i, b in ipairs(m.blocks) do
        if b.type == "segmented" and b.label ~= "Show as" then levels[#levels + 1] = b end
    end
    eq(#levels, 2)
    eq(levels[1].active, "list"); eq(levels[2].active, "list")
    levels[1].on_pick("covers")
    eq(saved.search_view_level1, "covers")
    levels[1].on_pick("list")
    eq(saved.search_view_level1, nil, "the default is stored as absence")
end)

t.done()
