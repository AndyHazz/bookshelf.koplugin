-- tests/_test_shelf_order.lua
-- The shelf editor's Shelf order page (maintainer): in place of the
-- Position nudges, a list of the shelves beside this one, each drawn as its
-- chip is on the menu bar, with up and down to move it.
--
-- Usage (from plugin root): lua tests/_test_shelf_order.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["logger"] = { dbg = function() end, info = function() end,
                             warn = function() end, err = function() end }
package.loaded["lib/bookshelf_settings_store"] = {
    read = function() end, save = function() end, delete = function() end,
    flush = function() end, isTrue = function() return false end,
    nilOrTrue = function() return true end,
}
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq
local TabModel = dofile("lib/bookshelf_tab_model.lua")

local function tabs()
    return {
        { id = "all" }, { id = "hidden", enabled = false }, { id = "recent" },
        { id = "card", card_only = true }, { id = "box" },
        { id = "in1", parent = "box" }, { id = "in2", parent = "box" },
        { id = "series" },
    }
end
local function ids(list)
    local o = {}
    for _i, x in ipairs(list) do o[#o + 1] = x.id end
    return table.concat(o, " ")
end

t.test("the list: the shelves beside this one, as the bar shows them", function()
    eq(ids(TabModel.orderSiblings(tabs(), "recent")), "all recent box series")
    eq(ids(TabModel.orderSiblings(tabs(), "in2")), "in1 in2")
    eq(#TabModel.orderSiblings(tabs(), "card"), 0, "a card's shelf is in no order")
    eq(#TabModel.orderSiblings(tabs(), "nope"), 0)
end)

t.test("a move steps past hidden shelves and others' children, and stops at the ends", function()
    local l = tabs()
    assert(TabModel.moveAmong(l, "recent", -1))
    eq(ids(l), "recent hidden all card box in1 in2 series")
    assert(not TabModel.moveAmong(l, "recent", -1), "already first")
    l = tabs()
    assert(TabModel.moveAmong(l, "box", 1))
    eq(ids(TabModel.orderSiblings(l, "box")), "all recent series box")
    assert(not TabModel.moveAmong(l, "box", 1), "already last")
    assert(not TabModel.moveAmong(l, "card", 1), "a card's shelf does not move")
end)

t.test("the editor offers Shelf order, not the Position nudges", function()
    local src = io.open("lib/bookshelf_chip_editor.lua"):read("*a")
    assert(not src:find('label_text = _("Position")', 1, true), "the Position nudges are still there")
    assert(src:find('_("Shelf order")', 1, true), "no Shelf order button")
    assert(src:find("function Editor:_openShelfOrder", 1, true), "no Shelf order page")
    -- The page draws labels as the bar does (icons, pictures, the bar's case).
    local body = src:sub((src:find("function Editor:_openShelfOrder", 1, true)))
    body = body:sub(1, (body:find("\nend\n", 1, true)))
    assert(body:find('type = "order"', 1, true), "the rows are not order blocks")
    local page = io.open("lib/bookshelf_editor_page.lua"):read("*a")
    local r = page:match("\n(function R%.order%(.-\nend)\n")
    assert(r, "no order block")
    assert(r:find("buildChipLabel", 1, true), "the label is not drawn as the bar draws it")
    assert(r:find("ctx:nudgeCard(CHEV_UP", 1, true), "up and down are not grey cards")
end)

t.test("with no editor up, an order row falls back to buttons", function()
    local Page = dofile("lib/bookshelf_editor_page.lua")
    local rows = Page.toButtons({ blocks = {
        { type = "order", label = "Home", selected = true, on_up = function() end,
          on_down = function() end, up_enabled = false, down_enabled = true },
    } })
    eq(#rows, 1)
    eq(#rows[1], 3)
    eq(rows[1][2].enabled, false)
end)

-- Maintainer: an Edit button on each row, into that shelf's editor. Then
-- (2026-10-31): the pill read as a button and did nothing; a tap on it is
-- the way in now, and the pencil that repeated it went.
t.test("a tap on a shelf's pill opens that shelf's editor", function()
    local src = io.open("lib/bookshelf_chip_editor.lua"):read("*a")
    local body = src:sub((src:find("function Editor:_openShelfOrder", 1, true)))
    body = body:sub(1, (body:find("\nend\n", 1, true)))
    assert(body:find("on_edit = ", 1, true), "the rows have no Edit")
    assert(src:find("local function editOther(id)", 1, true), "the editor cannot hand over to another shelf")
    local page = io.open("lib/bookshelf_editor_page.lua"):read("*a")
    local r = page:match("\n(function R%.order%(.-\nend)\n")
    assert(r:find("Kit.tapCell(pill, pill_w, h, b.on_edit)", 1, true), "the pill is not a way into its editor")
    assert(not r:find("PENCIL", 1, true), "a pencil repeats the pill")
    local Page = dofile("lib/bookshelf_editor_page.lua")
    local rows = Page.toButtons({ blocks = { { type = "order", label = "Home",
        on_up = function() end, on_down = function() end, on_edit = function() end } } })
    eq(#rows[1], 4)
end)

-- PW5, 2026-10-31: the page's frame went ~10 px wider on Shelf order and
-- back on the way out. Each arrow card is wider than its height (its
-- shadow), and the pill's width took the height: the row overflowed the
-- page by the two shadows.
t.test("an order row fits its page: the pill gets what the cards leave", function()
    local page = io.open("lib/bookshelf_editor_page.lua"):read("*a")
    local r = page:match("\n(function R%.order%(.-\nend)\n")
    assert(r:find("local pill_w = ctx.w - up:getSize().w - down:getSize().w - 2 * gap", 1, true),
        "the pill's width takes the arrows' nominal size")
end)

t.done()
