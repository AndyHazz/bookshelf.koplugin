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
    assert(src:find("bw:_spineFollowModule(id)", 1, true), "the nudge doesn't take the view along")
end)

-- ── Page breaks from the shelf as it now stands ───────────────────────────
-- The same fault as a book stepped over a page's end (maintainer: "we might
-- have always had similar oddities with pinned ornament moves"). Where the
-- page on screen ENDED before the move says nothing once the piece has left
-- it: a book flows back into its place, or does not, and the break moves.

t.test("nudged past the page's end, but the page now has room: the view stays", function()
    -- This page showed 10..18; the piece went to 19, and the fresh map has
    -- this page running to 19.
    local w = widget({ _cursor = 10, _spine_next_item = 10,
        _spinePageFirsts = function(_s, build) assert(build, "the kept map is of the old list"); return { 1, 10, 20 } end,
        _activeShelfModules = function() return { { id = "m", after = 18, w = 1 } } end })
    assert(not w:_spineFollowModule("m"), "turned to a page that starts mid-way through this one")
    eq(w.shown, nil)
end)

t.test("nudged past the page's end onto the next: that page's own start", function()
    -- The next page starts at 19 by the fresh map, not at 20 where the old
    -- page ended.
    local w = widget({ _cursor = 10, _spine_next_item = 11,
        _spinePageFirsts = function() return { 1, 10, 19 } end,
        _activeShelfModules = function() return { { id = "m", after = 19, w = 1 } } end })
    assert(w:_spineFollowModule("m"))
    eq(w.shown, 19)
end)

t.test("a nudge inside the page builds no page map", function()
    local asked = 0
    local w = widget({ _cursor = 10, _spine_next_item = 10,
        _spinePageFirsts = function() asked = asked + 1; return { 1, 10, 19 } end,
        _activeShelfModules = function() return { { id = "m", after = 13, w = 1 } } end })
    assert(not w:_spineFollowModule("m"))
    eq(asked, 0, "the whole shelf planned for a mid-page nudge")
end)

-- Next page: the piece goes first on the page after this one AS THE SHELF
-- WILL PAGE WITHOUT IT HERE. The old sum kept its place among the books and
-- started the view at it (rig: after=17 before and after, the view from 18,
-- the page map still breaking at 19).
local next_body = src:match("\n(function BookshelfWidget:_spineModuleNextPage%(.-\nend)\n")

local function nextPage(o)
    assert(next_body, "_spineModuleNextPage missing")
    local env = setmetatable({ BookshelfWidget = {} }, { __index = _G })
    assert(load(next_body, "next", "t", env))()
    return setmetatable(o, { __index = env.BookshelfWidget })
end
-- A list of n books with pieces standing after so many of them.
local function listOf(n, pieces)
    local out = {}
    for i = 0, n do
        for _j, p in ipairs(pieces) do
            if p.after == i then out[#out + 1] = { shelf_module = p } end
        end
        if i < n then out[#out + 1] = { filepath = "/b/" .. (i + 1) } end
    end
    return out
end

t.test("next page: first on the page after, by the page breaks without the piece here", function()
    -- 30 books, nine a page; the piece is last on page 2 (after book 17).
    -- Without it page 2 holds books 10..18, so page 3 starts at book 19.
    local m = { id = "m", after = 17, w = 1 }
    local seen
    local w = nextPage({ _cursor = 10, _spine_fetch_cache = { items = listOf(30, { m }) },
        _spineFirstsOf = function(_s, items)
            seen = #items
            return { 1, 10, 19, 28 }
        end })
    local after, from = w:_spineModuleNextPage("m")
    eq(seen, 30, "the breaks were worked out with the piece still on this page")
    eq(after, 18); eq(from, 19)
end)

t.test("next page: other pieces before the new place are counted", function()
    -- Another piece after book 3: positions run one ahead of books from there.
    local m, other = { id = "m", after = 12, w = 1 }, { id = "o", after = 3, w = 1 }
    local w = nextPage({ _cursor = 11, _spine_fetch_cache = { items = listOf(30, { m, other }) },
        _spineFirstsOf = function() return { 1, 11, 21 } end })
    local after, from = w:_spineModuleNextPage("m")
    eq(from, 21)        -- its position: where page 3 starts
    eq(after, 19)       -- 20 things before it, one of them the other piece
end)

t.test("next page: none after the last, and nothing to go on without the list", function()
    local m = { id = "m", after = 25, w = 1 }
    local w = nextPage({ _cursor = 19, _spine_fetch_cache = { items = listOf(30, { m }) },
        _spineFirstsOf = function() return { 1, 10, 19 } end })
    eq(w:_spineModuleNextPage("m"), false, "worked out, and there is none")
    eq(nextPage({ _cursor = 1 }):_spineModuleNextPage("m"), nil, "not worked out: the caller's estimate stands")
end)

t.test("the Page button asks for the real next page, the estimate only lights it", function()
    local menu = src:match("\nfunction BookshelfWidget:_spineModuleMenu%(entry%)\n(.-)\nend\n")
    local pm = menu:match("local function pageMove%(dir%)(.-)\n    end\n")
    assert(pm and pm:find("bw:_spineModuleNextPage(id)", 1, true), "Page next still keeps the piece where it is")
    -- Planning the whole shelf to decide whether a button is grey would run
    -- on every draw of the menu.
    assert(menu:find("enabled = bw:_spineModulePageMove(id, 1) ~= nil", 1, true))
end)

t.test("a pinned piece has Start and End too, as a book has the Page buttons", function()
    local menu = src:match("\nfunction BookshelfWidget:_spineModuleMenu%(entry%)\n(.-)\nend\n")
    local page = menu:match("local function page%(%)(.-)\n    end\n    d = require")
    -- One row, the shelf's start and end at its ends (maintainer).
    local rows = {}
    for row in page:gmatch('{ type = "chips", fill = true, items = {(.-)\n            } },') do
        local order = {}
        for label in row:gmatch('text = _%("(.-)"%)') do order[#order + 1] = label end
        rows[#rows + 1] = table.concat(order, " ")
    end
    eq(#rows, 1)
    eq(rows[1], "Start Page Left Right Page End")
    local edge = menu:match("local function toEdge%(dir%)(.-)\n    end\n")
    assert(edge, "no way to the shelf's start or end")
    assert(edge:find("m.after = 0", 1, true) and edge:find("table.insert(l, 1, m)", 1, true), "Start: before every book and piece")
    assert(edge:find("m.after = n_books", 1, true) and edge:find("l[#l + 1] = m", 1, true), "End: after every book and piece")
    assert(edge:find("bw:_spineFollowModule(id)", 1, true), "the view does not go with it")
end)

t.done()
