-- tests/_test_spine_module_follow.lua
-- A shelf module nudged off the page it is on takes the view with it: the
-- next page when it went past this page's end, the page that holds it when
-- it went before the start (maintainer, PW5).
--
-- Usage (from plugin root): lua tests/_test_spine_module_follow.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local t  = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq

local src = io.open("lib/bookshelf_widget.lua"):read("*a")
local body = src:match("\n(function BookshelfWidget:_spineFollowModule%(.-\nend)\n")
assert(body, "_spineFollowModule missing")

local function widget(o)
    local env = setmetatable({ BookshelfWidget = {}, require = function(n)
        if n == "lib/bookshelf_shelf_modules" then return dofile("lib/bookshelf_shelf_modules.lua") end
        return require(n)
    end }, { __index = _G })
    assert(load(body, "follow", "t", env))()
    local w = setmetatable(o, { __index = env.BookshelfWidget })
    w.shown = nil
    function w:_spineShowFrom(c) self.shown = c end
    return w
end

t.test("past this page's end: the next page", function()
    -- Positions 1..: this page shows 11..20 (cursor 11, next item 11 -> 21).
    local w = widget({ _cursor = 11, _spine_next_item = 11,
        _activeShelfModules = function() return { { id = "m", after = 20, w = 1 } } end })
    assert(w:_spineFollowModule("m"), "the view stayed")
    eq(w.shown, 21)
end)

t.test("still on the page: nothing moves", function()
    local w = widget({ _cursor = 11, _spine_next_item = 11,
        _activeShelfModules = function() return { { id = "m", after = 15, w = 1 } } end })
    assert(not w:_spineFollowModule("m"))
    eq(w.shown, nil)
end)

t.test("before this page's start: the page that holds it", function()
    local w = widget({ _cursor = 11, _spine_next_item = 11,
        _spinePageFirsts = function() return { 1, 6, 11, 21 } end,
        _activeShelfModules = function() return { { id = "m", after = 8, w = 1 } } end })
    assert(w:_spineFollowModule("m"))
    eq(w.shown, 6)
end)

t.test("a nudge follows its module", function()
    assert(src:find("change(function(l)\n            local moved = SM.step(l, id, dir)", 1, true), "nudge moved")
    assert(src:find("if bw:_spineFollowModule(id) and d and d.movable then d.movable._anchor_ensured = nil end", 1, true),
        "the nudge doesn't take the view along")
end)

t.done()
