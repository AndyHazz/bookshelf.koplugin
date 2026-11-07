-- tests/_test_spine_fetch_source.lua
-- Issue 588: a fetch-mode source that opts in to Spines. Its folder records
-- (navigation records, kind "opds_nav") stand face-out as folder tiles, not
-- as book spines; and a record's cover_image_path (a cover the source
-- downloaded) colours its spine, since Bookshelf does not look such books up
-- in KOReader's cover cache.
-- Run from the plugin root: lua tests/_test_spine_fetch_source.lua
package.path = "./?.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq
local F = dofile("tests/_binding_fixture.lua")

-- A downloaded cover: all dark green.
local loaded = {}
package.loaded["lib/bookshelf_image_source"] = {
    loadImage = function(path, w, h)
        loaded[#loaded + 1] = path
        local bb = F.surface(w or 40, h or 60)
        function bb:getPixel()
            return { getColorRGB32 = function() return { r = 20, g = 80, b = 30 } end }
        end
        return bb
    end,
    probeSize = function() return 400, 640 end,
}
package.loaded["lib/bookshelf_book_facts_db"] = { get = function() return nil end,
    put = function() end, drop = function() end, flush = function() end,
    migrateFrom = function() return 0 end }
local SS = require("lib/bookshelf_spine_shelf")
local realBookLook = SS.bookLook   -- before the fixture replaces it
local Shelf = F.configure(SS)

t.test("a folder record stands face-out, a book record as a spine", function()
    local items = {
        { kind = "opds_nav", is_opds_nav = true, source_nav = true, title = "Series: Saga",
          label = "Series: Saga", filepath = "demo://nav/1", source_kind = "demo" },
        { title = "A book", filepath = "demo://book/2", source_kind = "demo", has_cover = false },
    }
    local plan = Shelf.plan(items, { content_w = 800, row_h = 300, n_rows = 2, face_out = "none" })
    local by = {}
    for _, e in ipairs(plan.entries) do by[e.book and e.book.filepath or "?"] = e end
    eq(by["demo://nav/1"] and by["demo://nav/1"].face_out, true, "a folder stood as a book's spine")
    eq(by["demo://book/2"] and by["demo://book/2"].face_out, false)
end)

t.test("a record's downloaded cover colours its spine", function()
    loaded = {}
    local look = realBookLook({ filepath = "demo://book/7", title = "Seven",
                                cover_image_path = "/covers/7.jpg" })
    eq(loaded[1], "/covers/7.jpg", "the downloaded cover was not read")
    eq(look.sampled, true)
    eq(look.r, 20); eq(look.g, 80); eq(look.b, 30)
    eq(look.aspect, 1.6, "the shape came from the small decode, not the file")
end)

-- A folder record carries a pseudo-path (demo://nav/1) so the shelf can tell
-- records apart. The tap router checked "has a file path" first and sent a
-- tap on the folder tile to open it as a book (rig, a real tap).
t.test("a tap or hold on a folder tile goes to the folder, not to open a book", function()
    local tapped, held, opened
    local cbs = { on_book_tap = function() opened = true; return true end,
                  on_opds_nav_tap = function(n) tapped = n; return true end,
                  on_opds_nav_hold = function(n) held = n; return true end }
    local nav = { kind = "opds_nav", is_opds_nav = true, source_nav = true,
                  title = "Series: Saga", filepath = "demo://nav/1" }
    local slot = SS._SpineBookSlot:new{ book = nav, callbacks = cbs, width = 50, height = 100,
        entry = { w = 50, h = 100, look = F.look, face_out = true, label = "Series: Saga" } }
    slot:onTap()
    eq(tapped, nav, "a tap on the folder did not open it")
    eq(opened, nil, "a tap on the folder opened it as a book")
    slot:onHold()
    eq(held, nav)
    cbs.on_book_open = function() opened = true; return true end
    slot:onDoubleTap()
    eq(opened, nil, "a double tap on the folder opened it as a book")
end)

-- The same for a face-out tile, which is built apart from the slot (the
-- cover tile, wired in the row builder): proven by a real tap on the rig.
t.test("a face-out folder tile is wired to the folder's callbacks", function()
    local src = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")
    assert(src:find("on_tap        = nav and cbs_fo.on_opds_nav_tap or cbs_fo.on_book_tap,", 1, true),
        "a face-out folder tile opens as a book")
    assert(src:find("on_double_tap = (not nav) and cbs_fo.on_book_open or nil,", 1, true),
        "a double tap on a face-out folder tile opens it as a book")
end)

-- A folder record carrying its members in `books` (SOURCE_API.md, Spines)
-- stands as a run of their spines, the group being the run's item (whose
-- title names the run's badge), not as a folder tile. OrbitShelf builds its
-- Series, Authors and Genres levels on this.
t.test("a folder with books stands as a run of its members' spines", function()
    local m1 = { title = "Saga 1", filepath = "demo://book/1", source_kind = "demo", has_cover = false }
    local m2 = { title = "Saga 2", filepath = "demo://book/2", source_kind = "demo", has_cover = false }
    local folder = { kind = "opds_nav", is_opds_nav = true, source_nav = true, title = "Saga",
                     label = "Saga", filepath = "demo://nav/s", source_kind = "demo", books = { m1, m2 } }
    local plan = Shelf.plan({ folder }, { content_w = 800, row_h = 300, n_rows = 2, face_out = "none" })
    eq(#plan.entries, 2, "the folder did not stand as its members")
    for i, e in ipairs(plan.entries) do
        eq(e.book, ({ m1, m2 })[i])
        eq(e.face_out, false, "a member stood face-out as a folder tile")
        eq(e.item, folder, "the run lost its group, and so its name")
        eq(e.run_idx, plan.entries[1].run_idx, "the members are not one run")
    end
end)

t.done()
