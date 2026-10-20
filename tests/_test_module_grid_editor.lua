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

t.done()
