-- tests/_test_list_row_wrapped_style.lua
-- What a WRAPPING list line does with the style tags inside it -- issue #379.
--
-- THE ASYMMETRY. A single line renders as inline runs, so "[b]%title[/b] x"
-- bolds the title and leaves the x alone. A {xN} line is one TextBoxWidget and
-- a paragraph takes exactly one face, so runs cannot survive the trip and the
-- tags are stripped instead. That much is by construction and is not in
-- question.
--
-- What the reader loses by it was not, though. A [font=] tag anywhere in such
-- a template already claims the WHOLE box -- first tag wins, deliberately, so
-- a wrapped line still renders in the font it asked for. [b] and [i] in the
-- same position were simply dropped, so a title that was bold at one width
-- stopped being bold at the width where it wrapped: "if i made the lines small
-- enough that it had to stay in one line, then it would be bold again".
--
-- The box's face is resolved in ListRow.lineStyles, which is extracted here
-- and run against a fake ListRow: the face resolver needs the widget stack,
-- but WHICH style it is asked for is the whole of the behaviour. InlineStyle
-- is the real module -- it is pure, and the tag parsing is the part worth
-- running for real.
--
-- Usage (from plugin root): lua tests/_test_list_row_wrapped_style.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local src  = io.open("lib/bookshelf_list_row.lua"):read("*a")
local body = src:match("\nfunction ListRow%.lineStyles%(lines, scale_pct%)\n(.-)\nend\n")
assert(body, "ListRow.lineStyles moved or was renamed")

-- Every style runFace was asked for, so a test can assert on the REQUEST
-- rather than on a face object it would have to fake anyway.
local asked

local function stylesOf(line)
    asked = {}
    local FakeRow = {}
    function FakeRow.lineFace(l)
        return "line-face", (type(l) == "table" and l.bold == true)
    end
    function FakeRow.lineHeight() return 10 end
    function FakeRow.templateFont(template)
        if type(template) ~= "string" then return nil end
        return template:match("%[font=([^%]]+)%]")
    end
    function FakeRow.baseStyle(l)
        if type(l) ~= "table" then return { bold = false, italic = false } end
        return { font = l.font_face, size = l.font_size,
                 bold = l.bold == true, italic = l.italic == true }
    end
    -- The face encodes what it was resolved FROM, italic included: the real
    -- runFace bakes slant into the face object rather than reporting it
    -- alongside, so the box carries no separate italic flag to assert on.
    function FakeRow.runFace(_l, style)
        asked[#asked + 1] = style
        return "face<" .. tostring(style.font)
               .. (style.italic and "+i" or "") .. ">", style.bold == true
    end
    local env = {
        ListRow     = FakeRow,
        InlineStyle = dofile("lib/bookshelf_inline_style.lua"),
        type = type, ipairs = ipairs, tostring = tostring,
    }
    local fn, err = load("return function(lines, scale_pct)\n" .. body .. "\nend",
        "lineStyles", "t", env)
    assert(fn, err)
    return fn()({ line }, 100)[1]
end

-- The box's style, i.e. what a WRAPPED line renders in. Falls back the way
-- the renderer does (wrapBox: `line.box_face or line.face`).
local function boxStyle(line)
    local s = stylesOf(line)
    return { face = s.box_face or s.face,
             bold = (s.box_bold ~= nil) and s.box_bold or s.bold }
end

t.test("a [font=] tag still takes the whole box, as it always has", function()
    -- The rule this issue extends, pinned first so extending it cannot
    -- quietly replace it.
    local s = boxStyle({ template = "[font=Jost]%title[/font]" })
    eq(s.face, "face<Jost>", "the font tag no longer reaches the wrapped box")
end)

t.test("a wrapped line keeps a [b] the way it keeps a [font=]", function()
    local s = boxStyle({ template = "[b]%title[/b]" })
    assert(s.bold == true,
        "a bold title stops being bold at the width where it wraps")
end)

t.test("a wrapped line keeps an [i] the way it keeps a [font=]", function()
    local s = boxStyle({ template = "[i]%title[/i]" })
    assert(s.face == "face<nil+i>",
        "an italic line renders upright as soon as it wraps: " .. tostring(s.face))
end)

t.test("a tag anywhere claims the box, not just one wrapping the line", function()
    -- Same rule as templateFont's, and for the same reason: a paragraph has
    -- one face, so the choice is the first tag or nothing.
    local s = boxStyle({ template = "%title [b]%series[/b]" })
    assert(s.bold == true, "a tag past the start of the line was dropped")
end)

t.test("an untagged line is untouched", function()
    local s = boxStyle({ template = "%title" })
    eq(s.face, "line-face", "a line with no tags should not be re-resolved")
    eq(s.bold, false)
end)

t.test("the line's own bold still wins when no tag contradicts it", function()
    local s = boxStyle({ template = "%title", bold = true })
    assert(s.bold == true, "the line's own bold control stopped reaching the box")
end)

t.test("bold and font together resolve as one style, not two passes", function()
    local s = boxStyle({ template = "[font=Jost][b]%title[/b][/font]" })
    eq(s.face, "face<Jost>")
    assert(s.bold == true, "the box took the font but dropped the weight")
end)

t.done()
