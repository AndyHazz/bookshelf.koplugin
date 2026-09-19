-- tests/_test_label_plate_dangle.lua
-- The bookmark glyphs that hang below a cover paint OVER the label plate.
--
-- WHAT NEEDS PINNING. The in-progress ribbon and the finished tick hang half
-- their height below the cover on purpose (the progress bar hides the on-card
-- part). The label under a cover was a transparent TextWidget, so the dangle
-- showed through its top. Over a wallpaper the label got a filled plate,
-- painted after the cover, and the plate cropped the glyphs. The maintainer
-- chose the overlap: the glyph appears over the plate. So the titled slot
-- paints its stack, then paints the cover's overhanging glyphs once more, at
-- the positions they were just painted at, the way the open-cover effect
-- already does.
--
-- Usage (from plugin root): lua tests/_test_label_plate_dangle.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq
local function read(p) local f = assert(io.open(p)); local s = f:read("*a"); f:close(); return s end
local spine_src = read("lib/bookshelf_spine_widget.lua")
local row_src   = read("lib/bookshelf_shelf_row.lua")

local function compile(code, env, name)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, name)); _G.setfenv(f, env); return f
    end
    return assert(load(code, name, "t", env))
end
local params, body = spine_src:match("\nfunction SpineWidget%.repaintOverhangGlyphs%((.-)%)\n(.-)\nend\n")
assert(body, "SpineWidget.repaintOverhangGlyphs is missing")
local repaint = compile("return function(" .. params .. ")\n" .. body .. "\nend",
    { ipairs = ipairs, pcall = pcall, type = type, math = math }, "repaintOverhangGlyphs")()

local function frame(x, y, w, h, log, name)
    return { dimen = { x = x, y = y, w = w, h = h },
             paintTo = function(_s, bb, px, py) log[#log + 1] = name .. "@" .. px .. "," .. py end }
end

t.test("every overhanging glyph is painted again where it already sits", function()
    local log = {}
    local spine = { _overhang_glyph_widgets = { frame(10, 300, 30, 40, log, "ribbon"), frame(12, 290, 34, 44, log, "tick") } }
    repaint(spine, {})
    eq(#log, 2)
    eq(log[1], "ribbon@10,300"); eq(log[2], "tick@12,290")
end)

t.test("a glyph that has not been painted yet (no position) is skipped, and so is a spine with none", function()
    local log = {}
    local unpainted = { dimen = { w = 30, h = 40 }, paintTo = function() log[#log + 1] = "bad" end }
    repaint({ _overhang_glyph_widgets = { unpainted, frame(1, 2, 3, 4, log, "ok") } }, {})
    eq(#log, 1); eq(log[1], "ok@1,2")
    repaint({}, {})          -- nothing recorded: nothing to do, no error
    repaint(nil, {})
end)

t.test("a glyph whose paint throws does not take the others down", function()
    local log = {}
    local boom = { dimen = { x = 0, y = 0, w = 1, h = 1 }, paintTo = function() error("boom") end }
    repaint({ _overhang_glyph_widgets = { boom, frame(5, 6, 7, 8, log, "ok") } }, {})
    eq(#log, 1)
end)

t.test("the titled slot repaints the cover's glyphs after its plate, only when there is a plate", function()
    -- The book branch of ShelfRow.new with titles: the slot is an
    -- InputContainer over the stack (cover, gap, plated label). Its paint
    -- must end with the glyph repaint, gated on plate_fill: with no plate the
    -- label is transparent and the dangle already shows through it.
    local slot_at = row_src:find("local slot = InputContainer:new{ dimen = slot_dimen, stack }", 1, true)
    assert(slot_at, "the titled slot construction moved")
    local after = row_src:sub(slot_at, slot_at + 2500)
    local gate = after:find("if plate_fill", 1, true)
    local hook = after:find("SpineWidget.repaintOverhangGlyphs(spine, bb)", 1, true)
    assert(gate and hook and gate < hook, "the slot does not repaint the overhanging glyphs over its plate")
    assert(after:find("slot.paintTo = function", 1, true), "the repaint is not hung on the slot's own paint")
end)


t.test("labels get a plate over a background colour too, not only over a picture", function()
    -- Bare text on a coloured page loses contrast, which is what the plate
    -- is for; it used to appear only when a picture was showing. _rebuild
    -- hands Wallpaper the painted ground colour when there is no picture
    -- (Wallpaper.setGround), so the row can ask for either.
    -- the declaration carries the Wallpaper handle and the shading strength
    -- alongside the fill now, so match the line loosely
    local block = row_src:match("\n    local plate_fill[^\n]*\n    do\n(.-)\n    end\n")
    assert(block, "the plate_fill block moved")
    assert(block:find("Wallpaper.isShowing()", 1, true), "a picture no longer gives a plate")
    assert(block:find("Wallpaper.ground()", 1, true), "a background colour gives no plate")
    -- The ground is a Blitbuffer colour: cdata with an __eq metamethod that
    -- LuaJIT also runs for a comparison against nil, indexing the nil. Seen
    -- on the rig as blitbuffer.lua:601 "attempt to index local 'color'".
    assert(not block:find("ground() ~= nil", 1, true), "a colour is compared with nil; use type()")
    assert(block:find('type(Wallpaper.ground()) ~= "nil"', 1, true), "the ground check must go through type()")
end)

t.done()
