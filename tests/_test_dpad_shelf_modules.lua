-- tests/_test_dpad_shelf_modules.lua
-- The keys' cursor on the shelf reaches its modules and dealt ornaments, so
-- their menus open from the keys as a long-press opens them (maintainer,
-- 2026-10-31). Before: on a spine page the cursor stopped at the first
-- module (it has no row), so the books after it could not be reached; on a
-- covers page it stood on a module with no ring, and Press and the hold
-- chord did nothing there; dealt ornaments were no stop at all.
--
-- Usage (from plugin root): lua tests/_test_dpad_shelf_modules.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq
local src = io.open("lib/bookshelf_widget.lua"):read("*a")
local ss  = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")
local orn = io.open("lib/bookshelf_ornaments.lua"):read("*a")

local function static(name)
    local body = assert(src:match("\nfunction BookshelfWidget%." .. name .. "%((.-)\nend\n"), name)
    local chunk = "local BookshelfWidget = {}\nfunction BookshelfWidget." .. name .. "(" .. body
        .. "\nend\nreturn BookshelfWidget." .. name
    return assert(load(chunk))()
end

local function method(name)
    return assert(src:match("\nfunction BookshelfWidget:" .. name .. "%(.-%)\n(.-)\nend\n"), name)
end

-- ── ornaments between the books, left and right ──────────────────────────
t.test("Right from a book stops on an ornament standing after it, then goes on", function()
    local step = static("_keyStep")
    local afters = { 2, 2, 5 }
    local what, v = step(afters, 2, nil, 1)
    eq(what, "orn"); eq(v, 1)
    what, v = step(afters, 2, 1, 1)
    eq(what, "orn"); eq(v, 2)          -- two pieces in one gap
    what, v = step(afters, 2, 2, 1)
    eq(what, "item"); eq(v, 3)         -- on to the book after the gap
    eq(step(afters, 3, nil, 1), nil)   -- no piece after book 3: a book's move
end)

t.test("Left comes back through them the other way", function()
    local step = static("_keyStep")
    local afters = { 2, 2, 5 }
    local what, v = step(afters, 3, nil, -1)
    eq(what, "orn"); eq(v, 2)          -- the nearer of the two first
    what, v = step(afters, 2, 2, -1)
    eq(what, "orn"); eq(v, 1)
    what, v = step(afters, 2, 1, -1)
    eq(what, "item"); eq(v, 2)         -- the book it stands after
    -- One before the page's first book: Left from it goes off the page.
    what, v = step({ 0 }, 1, 1, -1)
    eq(what, "item"); eq(v, 0)
end)

-- ── a covers page's module slots ──────────────────────────────────────────
t.test("a module two slots wide is one stop, and blank slots are none", function()
    local land = static("_slotLand")
    local items = {
        { filepath = "a" },
        { shelf_slot = { module = { id = "m" }, part = 1, span = 2 } },
        { shelf_slot = { module = { id = "m" }, part = 2, span = 2 } },
        { shelf_slot = { blank = true } },
        { filepath = "b" },
    }
    eq(land(items, 2, 1), 2)           -- onto the module
    eq(land(items, 3, 1), 5)           -- its second slot and the blank skipped
    eq(land(items, 4, -1), 2)          -- back past the blank to the module's first slot
    eq(land(items, 3, -1), 2)
    eq(land(items, 3, 0), 2)           -- a step down onto its second slot lands on its first
    eq(land(items, 9, 1), 9)           -- off the page: left to the caller
end)

-- ── spine rows count modules ──────────────────────────────────────────────
t.test("a spine page's rows go past a module", function()
    local note = method("_noteSpineRows")
    assert(note:find("local key = b and (b.filepath or (b.shelf_module and b.id))", 1, true),
        "a module's row is not noted")
    local rows = method("_spineItemRows")
    assert(rows:find("local r = (it.filepath and sr.row_of[it.filepath])", 1, true)
        and rows:find("(it.shelf_module and it.id and sr.row_of[it.id])", 1, true),
        "the rows stop at the first module")
end)

-- ── Press and the hold chord ──────────────────────────────────────────────
t.test("Press and the hold chord reach a module and an ornament", function()
    local press = method("onBSKbPress")
    assert(press:find("if self:_keyTargetPress() then return true end", 1, true), "Press passes them by")
    local hold = method("onBSKbHold")
    assert(hold:find("if self:_keyTargetHold() then return true end", 1, true), "the hold chord passes them by")
    local sel = method("_selectedFilepath")
    assert(sel:find("if on_grid and (self:_keyOrnWidget() or self:_cursorModule()) then return nil end", 1, true),
        "a book keeps the ring while the cursor is on a module or a piece")
end)

-- ── the ring ──────────────────────────────────────────────────────────────
t.test("modules and pieces wear the keys' ring", function()
    assert(ss:find("SpineShelf._noteKeyOrn(opts, w_)", 1, true), "dealt pieces are not noted as stops")
    local n = select(2, ss:gsub("SpineShelf._noteKeyOrn%(opts, w_%)", ""))
    assert(n >= 4, "a place a piece is dealt is not noted (" .. n .. ")")
    assert(orn:find("if self.key_focus and self.key_focus(self) then M.paintKeyRing(bb, x, y, self.placement) end", 1, true),
        "a piece under the cursor shows no ring")
    assert(ss:find("bw:_paintKeyRing(bb, x, y, c:getSize())", 1, true), "a spine module shows no ring")
    local mr = method("_moduleRow")
    assert(mr:find("or (keyed and keyed.id == h.entry.id)", 1, true), "a covers module shows no ring")
end)

t.done()
