-- tests/_test_auto_ink.lua
-- Auto text (Panel text unset, a module card's own background) is black or
-- white, whichever has the more contrast with the colour behind it. It used
-- to switch at half way (128), so a mid grey panel (127) got white text that
-- read worse than black (maintainer, PW5). By WCAG's ratio the switch is at
-- about 118.
--
-- Usage (from plugin root): lua tests/_test_auto_ink.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local src = io.open("lib/bookshelf_module_card.lua"):read("*a")
local body = assert(src:match("\nlocal function whiteReads%(l%)\n(.-)\nend\n"), "whiteReads moved")
local whiteReads = assert(load("local l = ...\n" .. body))

t.test("mid grey takes black text, as the PW5 showed it should", function()
    eq(whiteReads(127), false); eq(whiteReads(128), false)
end)

t.test("black down to about 118, white below", function()
    eq(whiteReads(118), false); eq(whiteReads(117), true)
    eq(whiteReads(0), true); eq(whiteReads(255), false)
end)

t.test("Auto and isDark share the one rule", function()
    assert(src:find("local ink = whiteReads(l) and 0xFF or 0x00", 1, true), "autoInk has its own threshold")
    assert(src:find("return l ~= nil and whiteReads(l)", 1, true), "isDark has its own threshold")
    assert(not src:find("l < 128", 1, true), "a half-way threshold is left")
end)

t.done()
