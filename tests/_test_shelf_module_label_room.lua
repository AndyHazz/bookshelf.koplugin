-- tests/_test_shelf_module_label_room.lua
-- The Shelf module's heading hangs on its first plank like a section badge,
-- below the row by design. A shelf leaves that to the gap under the row; the
-- module's box ends at the row, so the label hung out of it and the layout
-- editor's selection border ran through it (maintainer, PW5). The module now
-- makes room for it inside its own box.
--
-- Usage (from plugin root): lua tests/_test_shelf_module_label_room.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()

local ss = assert(io.open("lib/bookshelf_spine_shelf.lua")):read("*a")
local shelf = assert(io.open("micromodules/shelf.lua")):read("*a")

t.test("the badge's overhang is measured where it is drawn", function()
    local f = ss:match("\nfunction SpineShelf%.badgeOverhang%(row_h%)\n(.-)\nend\n")
    assert(f, "no badgeOverhang")
    assert(f:find("SpineShelf.badgeFace()", 1, true), "measures another face than the badge")
    assert(f:find("SpineShelf.plankFace(row_h) - 2", 1, true), "not drawAt's hook point")
    local draw = ss:match("\nfunction ShelfBadges:drawAt%(bb, x, y%)\n(.-)\nend\n")
    assert(draw:find("local face = SpineShelf.badgeFace()", 1, true), "drawAt has its own face")
    assert(draw:find("local by = y + h - fh - 2", 1, true), "the hook point moved")
end)

t.test("a labelled Shelf module keeps the label inside its box", function()
    local body = shelf:match("\nlocal function spineBody%(ctx, tab, w, h, gap, label%)\n(.-)\nend\n")
    assert(body, "spineBody moved")
    assert(body:find("SpineShelf.badgeOverhang(row_h)", 1, true), "no room made for the label")
    -- One row: the room comes off the row. More: the gap under row 1 grows.
    assert(body:find("extra = (rows > 1) and math.max(0, hang - gap) or hang", 1, true),
        "the room is not sized to what the gap already gives")
    assert(body:find("VerticalSpan:new{ width = gap + ((r == 2) and extra or 0) }", 1, true),
        "the gap under the labelled row does not grow")
end)

t.done()
