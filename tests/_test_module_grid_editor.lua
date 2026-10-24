-- Headless tests for lib/bookshelf_module_grid_session.lua: the layout
-- editor's state and actions (the widget only draws it and routes input).
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }

local Session = dofile("lib/bookshelf_module_grid_session.lua")
local Grid    = dofile("lib/bookshelf_module_grid.lua")
local t = dofile("tests/_helpers.lua").runner()

local D = { cols = 4, rows = 5, cell_w = 100, cell_h = 100, gap = 10 }

local function at(page, col, row, w, h)
    return { page = page, col = col, row = row, w = w, h = h }
end

local function fakeHost(items)
    local h = { renders = 0, saves = 0, saved = nil, log = {} }
    h.stored = items
    function h:render(edit) self.renders = self.renders + 1; self.last_edit = edit end
    function h:model()
        local host = self
        return {
            load = function() return host.stored end,
            save = function(list)
                host.saves = host.saves + 1
                host.saved = list
                host.log[#host.log + 1] = "save"
            end,
            nextId = function() return "new1" end,
        }
    end
    return h
end

local function mockup() return {
    { id = "clock",  type = "module", module = "analogue_clock", at = at(1, 1, 1, 2, 2) },
    { id = "goal",   type = "module", module = "reading_goal",   at = at(1, 3, 1, 2, 1) },
    { id = "streak", type = "module", module = "streak",         at = at(1, 3, 2, 1, 1) },
    { id = "rings",  type = "module", module = "rings",          at = at(1, 1, 3, 4, 2) },
    { id = "quote",  type = "module", module = "quote_of_day",   at = at(1, 1, 5, 3, 1) },
} end

local function session(items, opts)
    opts = opts or {}
    local host = fakeHost(items)
    local notes = {}
    local s = Session.new{
        host = host, items = items, dims = D, key = "at",
        boxes = Grid.boxesFrom(items, "at"), page = opts.page or 1,
        selected_id = opts.selected_id,
        notify = function(text) notes[#notes + 1] = text end,
        add_picker = opts.add_picker,
        open_settings = opts.open_settings or function() host.log[#host.log + 1] = "settings" end,
        size_for = function() return 1, 1 end,
        min_for = opts.min_for,
        max_pages = opts.max_pages,
        title_for = function(entry) return entry.module end,
    }
    return s, host, notes
end

local function boxOf(s, id)
    for _i, b in ipairs(s.boxes) do if b.id == id then return b end end
end

t.test("a refused move says No room and does not render", function()
    local s, host, notes = session(mockup(), { selected_id = "clock" })
    local ok = s:moveBy(-1, 0)
    assert(ok == false)
    assert(notes[1] == "No room", tostring(notes[1]))
    assert(host.renders == 0, "rendered " .. host.renders)
end)

t.test("a move renders the working copy without saving", function()
    local s, host = session(mockup(), { selected_id = "goal" })
    assert(s:moveBy(0, 1))
    assert(host.renders == 1 and host.saves == 0)
    assert(boxOf(s, "streak").row == 1, "streak should swap up")
    assert(host.last_edit.selected_id == "goal" and host.last_edit.boxes == s.boxes)
end)

t.test("Done writes positions once", function()
    local s, host = session(mockup(), { selected_id = "goal" })
    s:moveBy(0, 1)
    s:resize("w", -1)
    s:commit()
    assert(host.saves == 1, "saves " .. host.saves)
    local goal
    for _i, it in ipairs(host.saved) do if it.id == "goal" then goal = it end end
    assert(goal.at.row == 2 and goal.at.w == 1, "saved goal " .. goal.at.row .. "," .. goal.at.w)
end)

t.test("editing never touches the stored list until commit", function()
    local items = mockup()
    local s = session(items, { selected_id = "goal" })
    s:moveBy(0, 1)
    assert(items[2].at.row == 1, "stored entry mutated before commit")
end)

t.test("settings commits first", function()
    local s, host = session(mockup(), { selected_id = "clock" })
    s:settings()
    assert(table.concat(host.log, ",") == "save,settings", table.concat(host.log, ","))
end)

t.test("resize honours the module's minimum", function()
    local s, _host, notes = session(mockup(), { selected_id = "clock",
        min_for = function() return 2, 2 end })
    assert(s:resize("w", -1) == false and notes[1] == "No room")
end)

t.test("Add places the new module on the current page and selects it", function()
    local s, host = session(mockup(), {
        add_picker = function(on_added) on_added({ id = "new1", type = "module", module = "x" }) end,
    })
    s:add()
    local b = boxOf(s, "new1")
    assert(b and b.page == 1 and b.col == 4 and b.row == 2, "new box not at the first free cell")
    assert(s.selected_id == "new1" and host.renders == 1)
end)

t.test("Add beyond four full pages says No room", function()
    local items = {}
    for p = 1, 4 do
        for r = 1, 5 do
            for c = 1, 4 do
                items[#items + 1] = { id = p .. "-" .. c .. "-" .. r, type = "module",
                    module = "x", at = at(p, c, r, 1, 1) }
            end
        end
    end
    local s, host, notes = session(items, {
        add_picker = function(on_added) on_added({ id = "new1", type = "module", module = "x" }) end,
    })
    local before = #s.items
    s:add()
    assert(notes[1] == "No room", tostring(notes[1]))
    assert(#s.items == before and host.renders == 0)
end)

t.test("removing the last module on page 2 moves the editor to page 1", function()
    local items = mockup()
    items[#items + 1] = { id = "lone", type = "module", module = "x", at = at(2, 1, 1, 1, 1) }
    local s = session(items, { page = 2, selected_id = "lone" })
    s:remove()
    assert(s.page == 1, "page " .. s.page)
    assert(s.selected_id == nil and boxOf(s, "lone") == nil)
    for _i, it in ipairs(s.items) do assert(it.id ~= "lone", "item kept") end
end)

t.test("moveToPage onto a new page within four", function()
    local s = session(mockup(), { selected_id = "quote" })
    assert(s:moveToPage(2))
    assert(boxOf(s, "quote").page == 2 and s.page == 2, "editor should follow the module")
end)

t.test("moveToPage past four pages refuses", function()
    local s, _host, notes = session(mockup(), { selected_id = "quote" })
    assert(s:moveToPage(5) == false and notes[1] == "No room")
end)

t.test("tapping an empty cell moves the selection there", function()
    local s = session(mockup(), { selected_id = "streak" })
    assert(s:moveToCell(4, 2))
    local b = boxOf(s, "streak")
    assert(b.col == 4 and b.row == 2)
end)

t.test("pageList includes the current page even when empty", function()
    local s = session(mockup(), { page = 2 })
    local p = s:pageList()
    assert(#p == 2 and p[2] == 2, table.concat(p, ","))
end)

t.test("tapping an empty cell near the edge moves a big module so it still fits", function()
    -- clock is 2x2; tapping the bottom row puts its bottom edge there.
    local items = mockup()
    table.remove(items, 5)                   -- no quote
    items[4].at = at(1, 1, 3, 4, 1)          -- rings one row tall
    local s = session(items, { selected_id = "clock" })
    assert(s:moveToCell(1, 5), "should move, not refuse")
    local b = boxOf(s, "clock")
    assert(b.row == 4 and b.col == 1, "clock at c" .. b.col .. " r" .. b.row)
end)

t.test("No room names the module in the way", function()
    local s, _host, notes = session(mockup(), { selected_id = "clock" })
    s:resize("w", 1)
    assert(notes[1] == "No room to move reading_goal", tostring(notes[1]))
end)

local function labels(rows)
    local out = {}
    for _i, row in ipairs(rows) do
        for _j, b in ipairs(row) do out[#out + 1] = b.text end
    end
    return "|" .. table.concat(out, "|") .. "|"
end

t.test("keys-only actions with a selection cover the whole toolbar and footer", function()
    local items = mockup()
    items[#items + 1] = { id = "p2", type = "module", module = "x", at = at(2, 1, 1, 1, 1) }
    local s = session(items, { selected_id = "clock" })
    local l = labels(s:keyActions{ has_settings = true, on_done = function() end })
    for _i, want in ipairs({ "Settings", "Remove", "Narrower", "Wider", "Shorter", "Taller",
                              "Page 2", "New page", "Add", "Done" }) do
        assert(l:find("|" .. want .. "|", 1, true), want .. " missing from " .. l)
    end
end)

t.test("keys-only actions without a selection offer Add, pages and Done", function()
    local items = mockup()
    items[#items + 1] = { id = "p2", type = "module", module = "x", at = at(2, 1, 1, 1, 1) }
    local s = session(items)
    local done = false
    local rows = s:keyActions{ on_done = function() done = true end }
    local l = labels(rows)
    assert(l:find("|Add|", 1, true) and l:find("|Page 2|", 1, true) and l:find("|Done|", 1, true), l)
    assert(not l:find("Remove", 1, true), "Remove offered with nothing selected")
    for _i, row in ipairs(rows) do
        for _j, b in ipairs(row) do if b.text == "Page 2" then b.callback() end end
    end
    assert(s.page == 2, "page " .. s.page)
end)

t.test("growing squeezes a neighbour only down to its own minimum", function()
    local items = {
        { id = "clock", type = "module", module = "analogue_clock", at = at(1, 1, 1, 2, 2) },
        { id = "quote", type = "module", module = "quote_of_day",   at = at(1, 3, 1, 2, 2) },
    }
    for r = 3, 5 do for c = 1, 4 do
        items[#items + 1] = { id = "f" .. c .. r, type = "module", module = "x", at = at(1, c, r, 1, 1) }
    end end
    local s, _host, notes = session(items, { selected_id = "clock",
        min_for = function(entry)
            if entry.module == "quote_of_day" then return 2, 1 end
            return 1, 1
        end })
    assert(s:resize("w", 1) == false, "quote squeezed below its minimum")
    assert(notes[1] and notes[1]:find("No room", 1, true))
end)

t.test("Add at a long-pressed empty cell lands there", function()
    local s = session(mockup(), {
        add_picker = function(on_added) on_added({ id = "new1", type = "module", module = "x" }) end,
    })
    s:add(4, 5)
    local b = boxOf(s, "new1")
    assert(b and b.col == 4 and b.row == 5, "new box at " .. (b and (b.col .. "," .. b.row) or "nil"))
end)

t.test("Add at a cell too small for the module falls back to the first free spot", function()
    local items = mockup()
    local s = session(items, {
        add_picker = function(on_added) on_added({ id = "new1", type = "module", module = "x" }) end,
    })
    s.size_for = function() return 2, 1 end
    s:add(4, 5)   -- only one free cell there; 2x1 doesn't fit
    local b = boxOf(s, "new1")
    assert(b == nil or not (b.col == 4 and b.row == 5), "placed over a neighbour")
end)

t.test("moveIdBy moves a module without selecting it", function()
    local s, host = session(mockup(), { selected_id = "clock" })
    assert(s:moveIdBy("goal", 0, 1))
    assert(boxOf(s, "goal").row == 2 and s.selected_id == "clock")
    assert(host.renders == 1)
end)

t.test("resizeId resizes a module without selecting it", function()
    local items = {
        { id = "a", type = "module", module = "x", at = at(1, 1, 1, 1, 1) },
    }
    local s = session(items)
    assert(s:resizeId("a", "w", 1))
    assert(boxOf(s, "a").w == 2 and s.selected_id == nil)
end)


-- The toolbar's page buttons and the shelf's hidden resize buttons ask the
-- session first: where "previous" / "next page" would put the selection, and
-- whether a resize would change anything at all.
t.test("adjacentPage: the pages either side, a new one next, never none", function()
    local items = mockup()
    items[#items + 1] = { id = "p3", type = "module", module = "x", at = at(3, 1, 1, 1, 1) }
    local s = session(items, { selected_id = "clock", page = 1 })
    assert(s:adjacentPage(-1) == nil, "a previous page before page 1")
    assert(s:adjacentPage(1) == 3, "next should be the next page in use, got " .. tostring(s:adjacentPage(1)))
    s.page = 3
    assert(s:adjacentPage(-1) == 1, "previous should skip the gap, got " .. tostring(s:adjacentPage(-1)))
    assert(s:adjacentPage(1) == nil, "a new page that would sort before this one was offered as next")
    local s2 = session(mockup(), { selected_id = "clock", page = 1 })
    assert(s2:adjacentPage(1) == 2, "no new page offered as next")
    local s3 = session(mockup(), { page = 1 })
    assert(s3:adjacentPage(1) == nil, "a page move with nothing selected")
end)

t.test("canResize: only when the size would actually change", function()
    local s = session(mockup(), { selected_id = "streak", min_for = function() return 1, 1 end })
    assert(s:canResize("w", -1) == false, "a 1-wide module can't be narrower")
    assert(s:canResize("h", -1) == false, "a 1-tall module can't be shorter")
    assert(s:canResize("h", 1) == true, "room below to grow")
    local before = boxOf(s, "streak")
    assert(before.w == 1 and before.h == 1, "asking changed the module")
    local s2 = session(mockup(), { selected_id = "goal", min_for = function() return 2, 1 end })
    assert(s2:canResize("w", -1) == false, "narrower than its minimum")
end)


t.test("on a host with its own page count every page is there to move to", function()
    local s = session(mockup(), { selected_id = "clock", page = 1, max_pages = 9 })
    assert(s:adjacentPage(-1) == nil)
    assert(s:adjacentPage(1) == 2)
    assert(s:moveToPage(5) == true, "a page with no modules on a shelf was refused")
    assert(s.page == 5 and s:adjacentPage(-1) == 4 and s:adjacentPage(1) == 6, "not page by page")
    s.page = 9
    assert(s:adjacentPage(1) == nil, "past the shelf's last page")
end)

t.test("the footer has + Add first and Done last", function()
    local src = io.open("lib/bookshelf_module_grid_editor.lua"):read("*a")
    local body = src:match("\nfunction Editor:_buildFooter%(rect_w%)\n(.-)\nend\n")
    local add = body:find('_("Add")', 1, true)
    local done = body:find('_("Done")', 1, true)
    assert(add and done and add < done, "Done comes before + Add")
    assert(body:find('local row = { button("+ " .. _("Add")', 1, true), "+ Add is not first")
end)

t.test("on a shelf the footer has no page dots or New page", function()
    -- A shelf's pages are its own, of books: the module grid's page dots and
    -- New page made no sense there (maintainer, PW5).
    local src = io.open("lib/bookshelf_module_grid_editor.lua"):read("*a")
    local body = src:match("\nfunction Editor:_buildFooter%(rect_w%)\n(.-)\nend\n")
    assert(body:find('local on_shelf = info and info.surface == "shelf"', 1, true), "the footer does not know it is on a shelf")
    assert(body:find("if #pages > 1 and not on_shelf then", 1, true), "page dots on a shelf")
    assert(body:find("local nxt = s.selected_id and not on_shelf and s:newPage()", 1, true), "New page on a shelf")
end)

t.done()
