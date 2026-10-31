-- tests/_test_add_shelf_page.lua
-- The "+" tile on a shelf of shelves: one page (STYLE.md), not a menu that
-- opens a second menu. New shelf as a card that says what it does, then the
-- shelves that could move in, each row saying where it is now.
--
-- Usage (from plugin root): lua tests/_test_add_shelf_page.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

local src = io.open("lib/bookshelf_widget.lua"):read("*a")
local body = src:match("\n(function BookshelfWidget:_addOrMoveSubShelf%(.-\nend)\n")
assert(body, "_addOrMoveSubShelf moved")

local function open(tabs)
    local state = { moved = {} }
    local TM = {
        load = function() return tabs end,
        save = function() end,
        isCardOnly = function() return false end,
        moveTargets = function(_tabs, id) return { { id = "here" } } end,
        moveTree = function(_t, id, dest) state.moved[#state.moved + 1] = id .. ">" .. dest; return true end,
        getById = function(id) for _i, x in ipairs(tabs) do if x.id == id then return x end end end,
    }
    local env = setmetatable({
        BookshelfWidget = {},
        _ = function(s) return s end,
        T = function(s, a) return (s:gsub("%%1", tostring(a))) end,
        UIManager = { close = function() state.closed = (state.closed or 0) + 1 end, show = function() end },
        require = function(n)
            if n == "lib/bookshelf_tab_model" then return TM end
            if n == "lib/bookshelf_page_dialog" then
                return { show = function(spec) state.spec = spec; return {} end }
            end
            if n == "ui/widget/buttondialog" then error("still a ButtonDialog") end
            return require(n)
        end,
    }, { __index = _G })
    assert(load(body, "add", "t", env))()
    local bw = setmetatable({ chip = "here",
        _addSubShelf = function() state.added = true end,
        _afterChipEdit = function() state.after = true end }, { __index = env.BookshelfWidget })
    bw:_addOrMoveSubShelf()
    return state
end

local tabs = {
    { id = "here", label = "Reading" },
    { id = "a", label = "Classics" },
    { id = "b", label = "Poetry", parent = "a" },
    { id = "kid", label = "Inside", parent = "here" },
}

t.test("one page: New shelf, then each shelf that could move in, with where it is", function()
    local st = open(tabs)
    local m = st.spec.page()
    eq(m.blocks[1].type, "option")
    assert(m.blocks[1].desc, "New shelf does not say what it does")
    local rows = {}
    for _i, b in ipairs(m.blocks) do
        if b.type == "row" then rows[#rows + 1] = b.label .. "=" .. b.value end
    end
    eq(table.concat(rows, " | "), "Classics=In the shelf menu | Poetry=In Classics")
end)

t.test("a row moves that shelf here", function()
    local st = open(tabs)
    for _i, b in ipairs(st.spec.page().blocks) do
        if b.type == "row" and b.label == "Poetry" then b.callback() end
    end
    eq(st.moved[1], "b>here"); eq(st.after, true)
end)

t.test("nothing could move in: straight to a new shelf", function()
    local st = open({ { id = "here", label = "Reading" } })
    eq(st.added, true); eq(st.spec, nil)
end)

t.done()
