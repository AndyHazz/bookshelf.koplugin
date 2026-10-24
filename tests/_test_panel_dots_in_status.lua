-- tests/_test_panel_dots_in_status.lua
-- The top panel's page dots sit in the middle of its status line, not in a
-- band under the grid: a Shelf module in the bottom row hangs its plank front
-- and heading into that band, and the dots were drawn across them
-- (maintainer, PW5). Without a status line the band stays.
--
-- Usage (from plugin root): lua tests/_test_panel_dots_in_status.lua
package.path = "./?.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()
local w = assert(io.open("lib/bookshelf_widget.lua")):read("*a")
local body = assert(w:match("\nfunction BookshelfWidget:_buildMicroHero%(content_w, hero_h, PAD%)\n(.-)\nend\n"))

t.test("with a status line, the dots share its row and the grid gets the band", function()
    assert(body:find("dots_h = 0", 1, true), "the band is still taken from the grid")
    assert(body:find("local grid_h  = math.max(1, hero_h - status_h - gap)", 1, true))
    -- On the status text, above the row's hairline.
    assert(body:find("local text_row = rawget(status_row, 1)", 1, true)
        and body:find("local dots    = dotsFor((ok_t and text_h and text_h > 0) and text_h or status_h)", 1, true),
        "dots centred on the whole row, over its hairline")
    local head = body:match("local head = OverlapGroup:new{(.-)}\n")
    assert(head and head:find("status_row,", 1, true) and head:find("dots,", 1, true))
end)

t.test("the minute's status swap replaces the status line, not the dots", function()
    assert(body:find("self._hero_status_strip = { group = head, idx = 1,", 1, true))
end)

t.test("without a status line the band under the grid stays", function()
    assert(body:find("return VerticalGroup:new{ align = \"left\", grid, dotsFor() }", 1, true))
end)

t.done()
