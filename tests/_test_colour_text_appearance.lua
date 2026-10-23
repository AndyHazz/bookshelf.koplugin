-- tests/_test_colour_text_appearance.lua
-- Issue 543: the Appearance plugin (Euphoriyy/appearance.koplugin) replaces
-- TextWidget:paintTo and paints every text in the reader's font colour, so
-- black titles landed on dark spines. Text Bookshelf colours on purpose --
-- anything but plain black ink -- asks it to keep that colour, through the
-- plugin's own exclusion colour; plain black ink still follows the reader's
-- font colour, and without the plugin nothing changes.
package.path = "./?.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()

local function color8(v) return { a = v, kind = "c8" } end
local BLACK, WHITE, EXCL = color8(0), color8(0xFF), { kind = "exclusion" }

local seen
local function load(with_appearance)
    seen = {}
    local TextWidget = {}
    TextWidget.__index = TextWidget
    function TextWidget:extend(o) o = o or {}; o.__index = o; return setmetatable(o, self) end
    function TextWidget:paintTo(_bb, _x, _y)
        seen[#seen + 1] = { fg = self.fgcolor, orig = self.original_fgcolor }
    end
    package.loaded["ui/widget/textwidget"] = TextWidget
    package.loaded["ffi/blitbuffer"] = {
        isColor8 = function(c) return type(c) == "table" and c.kind == "c8" end,
        COLOR_BLACK = BLACK,
    }
    package.loaded["ui/rendertext"] = {}
    if with_appearance then
        package.loaded["ui/font_color"] = { fgcolor = function() return BLACK end }
        package.loaded["lib/common"] = {
            EXCLUSION_COLOR = EXCL,
            is_excluded = function(c) return c == EXCL end,
        }
    else
        package.loaded["ui/font_color"] = nil
        package.loaded["lib/common"] = nil
    end
    package.loaded["lib/bookshelf_colour_text"] = nil
    return dofile("lib/bookshelf_colour_text.lua"), TextWidget
end

local grey_bb = { getType = function() return "bb8" end }

local function widget(CT, fg)
    return setmetatable({ fgcolor = fg }, { __index = CT })
end

t.test("with Appearance, a chosen colour asks to be kept", function()
    local CT = load(true)
    local w = widget(CT, WHITE)
    w:paintTo(grey_bb, 0, 0)
    assert(#seen == 1, "painted " .. #seen .. " times")
    assert(seen[1].fg == EXCL, "did not ask Appearance to keep it")
    assert(seen[1].orig == WHITE, "the colour to keep was not handed over")
    assert(w.fgcolor == WHITE and w.original_fgcolor == nil, "the widget was left changed")
end)

t.test("with Appearance, plain black ink still follows the reader's font colour", function()
    local CT = load(true)
    widget(CT, BLACK):paintTo(grey_bb, 0, 0)
    assert(seen[1].fg == BLACK and seen[1].orig == nil, "black ink was taken out of Appearance's hands")
    widget(CT, nil):paintTo(grey_bb, 0, 0)
    assert(seen[2].fg == nil and seen[2].orig == nil, "the default ink was taken out of Appearance's hands")
end)

t.test("without Appearance nothing changes", function()
    local CT = load(false)
    widget(CT, WHITE):paintTo(grey_bb, 0, 0)
    assert(seen[1].fg == WHITE and seen[1].orig == nil, "painted differently without the plugin")
end)

t.test("an unrelated lib/common is not mistaken for Appearance", function()
    local CT = load(false)
    package.loaded["ui/font_color"] = { fgcolor = function() end }
    package.loaded["lib/common"] = { something = true }
    widget(CT, WHITE):paintTo(grey_bb, 0, 0)
    assert(seen[1].fg == WHITE, "a lib/common without the exclusion colour was used")
end)

t.done()
