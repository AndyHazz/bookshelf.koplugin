-- tests/_test_tap_feedback_ornament.lua
-- A tap on an ornament module on a covers shelf (maintainer, PW5,
-- 2026-10-31): the pressed flash repainted the picture with the fast
-- waveform, 1-bit on the panel, and with no tap action set nothing repainted
-- it after, so it stayed a black-and-white smear. No flash for a tap that
-- does nothing; a bare module (a picture) flashes in greys.
--
-- Usage (from plugin root): lua tests/_test_tap_feedback_ornament.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()
local hm = io.open("lib/bookshelf_hero_modules.lua"):read("*a")
local orn = io.open("micromodules/ornament.lua"):read("*a")

t.test("an ornament flashes only with a tap action set", function()
    assert(orn:find('tap_feedback = function(ctx)', 1, true), "an ornament with no tap still flashes")
    assert(hm:find('if type(feedback) == "function" then', 1, true), "tap_feedback as a function is not asked")
end)

t.test("a picture's flash is in greys, not the fast waveform", function()
    assert(hm:find('local wave = (def and def.bare) and "ui" or "fast"', 1, true), "a bare module flashes 1-bit")
    assert(hm:find('UIManager:setDirty(bw, function() return wave, self.dimen end)', 1, true))
end)

t.done()
