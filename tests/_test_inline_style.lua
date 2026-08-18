-- tests/_test_inline_style.lua
-- Pure-Lua tests for lib/bookshelf_inline_style.lua: the [b] / [i] / [font=] /
-- [size=] runs inside one list line.
-- Usage (from plugin root): lua tests/_test_inline_style.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local IS = require("lib/bookshelf_inline_style")

local BASE = { font = nil, size = 16, bold = false, italic = false }

-- Compact rendering of a run list, so a failure says what it produced rather
-- than "expected table, got table".
local function shape(runs)
    if not runs then return "nil" end
    local out = {}
    for _i, r in ipairs(runs) do
        out[#out + 1] = string.format("%q:%s%s%s%s", r.text, tostring(r.size),
            r.bold and "+b" or "", r.italic and "+i" or "",
            r.font and ("+" .. r.font) or "")
    end
    return table.concat(out, " ")
end

-- ── The fast path ──────────────────────────────────────────────────────────

t.test("a line with no markup parses to nil", function()
    -- nil, NOT a one-run array: it is the renderer's signal to build the
    -- single TextWidget it has always built. Return a run list here and every
    -- ordinary line starts paying for a HorizontalGroup it does not need.
    eq(IS.parse("The Hobbit", BASE), nil)
    eq(IS.parse("", BASE), nil)
    eq(IS.parse(nil, BASE), nil)
    -- A bracket that is not one of ours is not markup either.
    eq(IS.parse("[if:series]%series[/if]", BASE), nil)
    eq(IS.parse("Title [draft]", BASE), nil)
end)

t.test("brackets that are not ours survive the strip", function()
    eq(IS.strip("[if:series]%series[/if]"), "[if:series]%series[/if]")
    eq(IS.strip("a [b]bold[/b] c"), "a bold c")
    eq(IS.strip("[size=12]small[/size]"), "small")
    eq(IS.strip("[u]x[/u]"), "x")
    eq(IS.strip("plain"), "plain")
end)

-- ── Runs ───────────────────────────────────────────────────────────────────

t.test("a bold span becomes its own run", function()
    eq(shape(IS.parse("a[b]B[/b]c", BASE)), '"a":16 "B":16+b "c":16')
end)

t.test("an absolute size applies to its span only", function()
    eq(shape(IS.parse("%title[size=12]#3[/size]", BASE)),
       '"%title":16 "#3":12')
end)

t.test("a relative size is read against the enclosing run", function()
    eq(shape(IS.parse("a[size=-4]b[/size]", BASE)), '"a":16 "b":12')
    eq(shape(IS.parse("a[size=+2]b[/size]", BASE)), '"a":16 "b":18')
    -- Nested, so the inner one is relative to the OUTER one, not to the line.
    eq(shape(IS.parse("[size=20]a[size=-4]b[/size][/size]", BASE)),
       '"a":20 "b":16')
end)

t.test("a size can never reach zero", function()
    eq(shape(IS.parse("[size=-99]x[/size]", BASE)), '"x":1')
    eq(shape(IS.parse("[size=0]x[/size]", BASE)), '"x":1')
end)

t.test("a garbled size leaves the run alone", function()
    eq(shape(IS.parse("[size=huge]x[/size]", BASE)), '"x":16')
    eq(shape(IS.parse("[size=]x[/size]", BASE)), '"x":16')
end)

t.test("a font tag names the run's face", function()
    eq(shape(IS.parse("a[font=Jost]b[/font]", BASE)), '"a":16 "b":16+Jost')
    -- Spaces in a font name are ordinary characters.
    eq(shape(IS.parse("[font=Noto Sans]x[/font]", BASE)), '"x":16+Noto Sans')
end)

t.test("tags nest and combine", function()
    eq(shape(IS.parse("[b][i]x[/i][/b]", BASE)), '"x":16+b+i')
    eq(shape(IS.parse("[b]a[i]b[/i]c[/b]", BASE)),
       '"a":16+b "b":16+b+i "c":16+b')
end)

t.test("an unclosed tag runs to the end of the line", function()
    eq(shape(IS.parse("a[b]b", BASE)), '"a":16 "b":16+b')
    -- Which is what makes wrapping the WHOLE line in one tag behave exactly
    -- like the line-level [font=] it replaces.
    eq(shape(IS.parse("[font=Jost]%title", BASE)), '"%title":16+Jost')
end)

t.test("a closer with no opener is dropped, not treated as an opener",
function()
    eq(shape(IS.parse("a[/b]b", BASE)), '"ab":16')
end)

t.test("mis-nested closers unwind to their own opener", function()
    -- "[b][i]x[/b]y": closing b throws away the i as well, which is the
    -- forgiving reading. The alternative -- ignoring the mismatch -- leaves a
    -- line bold to its end because of one typo.
    eq(shape(IS.parse("[b][i]x[/b]y", BASE)), '"x":16+b+i "y":16')
end)

t.test("adjacent runs in the same style are merged", function()
    -- [u] is consumed and applies nothing, so what is either side of it is one
    -- piece of text. Two TextWidgets would double the spacing at the seam.
    eq(shape(IS.parse("one [u]two[/u] three", BASE)), '"one two three":16')
end)

t.test("empty spans produce no run", function()
    eq(shape(IS.parse("[b][/b]", BASE)), "")
    eq(shape(IS.parse("a[b][/b]b", BASE)), '"ab":16')
end)

-- ── What the row-height budget asks ────────────────────────────────────────

t.test("styles always includes the line's own", function()
    local s = IS.styles("plain text", BASE)
    eq(#s, 1)
    eq(s[1].size, 16)
end)

t.test("styles reports every size the template can render at", function()
    local s = IS.styles("%title[size=22]!![/size][size=10]x[/size]", BASE)
    local sizes = {}
    for _i, v in ipairs(s) do sizes[#sizes + 1] = v.size end
    table.sort(sizes)
    eq(sizes, { 10, 16, 22 })
end)

t.test("styles sees inside a conditional branch", function()
    -- The height has to cover a branch that only some books take: the row is
    -- reserved before any book is expanded against it, so a template that CAN
    -- render at 24 makes every row on the page tall enough for 24.
    local s = IS.styles("[if:series][size=24]%series[/size][/if]%title", BASE)
    local biggest = 0
    for _i, v in ipairs(s) do if v.size > biggest then biggest = v.size end end
    eq(biggest, 24)
end)

t.test("styles does not repeat a style", function()
    local s = IS.styles("[b]a[/b] b [b]c[/b]", BASE)
    eq(#s, 2)   -- the line's own, and bold
end)

t.done()
