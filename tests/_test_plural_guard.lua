-- tests/_test_plural_guard.lua
-- issue 516: KOReader's scanner calls ngettext with no count; a comparing
-- plural rule (French "n > 1") throws on nil. The guard reads nil as many
-- for the scan and puts the original back after.
--
-- Usage (from plugin root): lua tests/_test_plural_guard.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t, eq = helpers.runner(), helpers.eq
local Guard = require("lib/bookshelf_plural_guard")

local function french() return function(n) if n > 1 then return 1 else return 0 end end end

t.test("a nil count reads as plural while guarded, and the rule is restored", function()
    local rule = french()
    local G = { getPlural = rule }
    assert(not pcall(G.getPlural, nil), "the French rule throws on nil")
    local restore = Guard.guard(G)
    eq(G.getPlural(nil), 1)
    eq(G.getPlural(1), 0)
    eq(G.getPlural(5), 1)
    restore()
    eq(rawget(G, "getPlural"), rule)
end)

t.test("a rule inherited from the metatable is not left as an own field", function()
    local G = setmetatable({}, { __index = { getPlural = french() } })
    local restore = Guard.guard(G)
    eq(G.getPlural(nil), 1)
    restore()
    eq(rawget(G, "getPlural"), nil)
    assert(G.getPlural ~= nil)
end)

t.test("no gettext, or no rule, is left alone", function()
    Guard.guard(nil)()
    local G = {}
    Guard.guard(G)()
    eq(rawget(G, "getPlural"), nil)
end)

t.done()
