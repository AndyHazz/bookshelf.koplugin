-- tests/_test_tab_font_double_scale.lua
-- The modal's tab labels are sized ONCE.
--
-- WHAT WENT WRONG. "I see many screenshots like this where our tabs are huge
-- apparently by default."
--
-- Font:getFace scales its size argument itself:
--
--     function Font:getFace(font, size, faceindex)
--         ...
--         size = Screen:scaleBySize(size)
--
-- so handing it an already-scaled size scales twice. The tab strip did
-- exactly that, and the error grows with the screen, because scaleBySize is
-- a function of the panel's short edge (min(w,h)/600, averaged with the DPI
-- scale). On a 600px device the factor is 1 and nothing looks wrong; on a
-- 1236x1648 panel it is about 2, so the labels come out at roughly twice the
-- size everything around them uses. Hence "many screenshots" rather than one
-- device.
--
--     one scale of 13   27 px   what was intended
--     two scales        56 px   what shipped
--     the footer's 15   31 px   for comparison, scaled once
--
-- The file's own other face call already passes an unscaled size, which is
-- what makes this the odd one out rather than a house style.
--
-- Usage (from plugin root): lua tests/_test_tab_font_double_scale.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq
local src = io.open("lib/bookshelf_reviews_modal.lua"):read("*a")

t.test("the tab face takes an unscaled size", function()
    local line = src:match("(self%.face%s*=%s*Font:getFace%b())")
    assert(line, "the tab face assignment moved")
    assert(not line:find("scaleBySize", 1, true),
        "the size is pre-scaled and Font:getFace scales it again: " .. line)
end)

t.test("no face anywhere in this file is handed a scaled size", function()
    for call in src:gmatch("getFace%b()") do
        assert(not call:find("scaleBySize", 1, true),
            "a face is still double-scaled: " .. call)
    end
end)

t.test("KOReader still scales inside getFace, which is what makes this a bug", function()
    -- If upstream ever stops, this test is what says so rather than the tabs
    -- silently halving.
    local f = io.open("/usr/lib/koreader/frontend/ui/font.lua")
    if not f then return t.skip("no KOReader tree here") end
    local fsrc = f:read("*a"); f:close()
    local body = fsrc:match("function Font:getFace%(font, size, faceindex%)(.-)\nend")
    assert(body, "Font:getFace moved")
    assert(body:find("size = Screen:scaleBySize(size)", 1, true),
        "getFace no longer scales its argument; the tab size needs re-deriving")
end)

t.test("the base size and its scale setting are unchanged", function()
    -- The reader-facing knob still multiplies this, so the fix must not be
    -- mistaken for a size change: 13 was always the intent.
    eq(tonumber(src:match("TAB_LABEL_FONT_BASE%s*=%s*(%d+)")), 13)
    assert(src:find("TAB_LABEL_FONT_BASE * label_scale / 100", 1, true),
        "the Modal tabs font-scale setting no longer feeds the base size")
end)

t.done()
