-- tests/_test_last_books_fit.lua
-- Recently read's (and the Shelf module's) "Fit" count: as many covers as the cell holds at full
-- height (2:3 covers, a gap between, room for the status marks above and
-- below), so a 1x1 shows one readable cover and a 6x1 a full row rather than
-- three of whatever size the width allowed.
package.path = "./?.lua;./?/init.lua;" .. package.path
local t   = dofile("tests/_helpers.lua").runner()
-- The count is Kit.coverFit, shared with the Shelf module.
package.loaded["lib/bookshelf_fonts"] = { getFace = function() return {} end }
package.loaded["lib/bookshelf_start_menu_modules"] = { COLOR_PRIMARY = 0, COLOR_MUTED = 1 }
local Kit = dofile("lib/bookshelf_module_kit.lua")
local function fit(w, h, gap, m) return Kit.coverFit(w, h, gap, m) end

t.test("a 1x1 cell holds one cover", function()
    assert(fit(160, 175, 10, 8) == 1, tostring(fit(160, 175, 10, 8)))
end)

t.test("a 6x1 strip holds a row of them", function()
    -- covers 159 tall -> 106 wide; (1160 + 10) / 116 = 10
    assert(fit(1160, 175, 10, 8) == 10, tostring(fit(1160, 175, 10, 8)))
end)

t.test("a 3x2 cell holds as many big covers as fit across", function()
    -- covers 371 tall -> 247 wide; (560 + 10) / 257 = 2
    assert(fit(560, 387, 10, 8) == 2, tostring(fit(560, 387, 10, 8)))
end)

t.test("never fewer than one, never more than twelve", function()
    assert(fit(20, 400, 10, 8) == 1)
    assert(fit(5000, 60, 10, 8) == 12)
end)

t.done()
