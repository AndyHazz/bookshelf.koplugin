-- tests/_test_box_titles_all_or_none.lua
-- A spine-out series box letters all of its books or none of them.
--
-- Usage (from plugin root): lua tests/_test_box_titles_all_or_none.lua
--
-- A spine too thin for the smallest lettering drops its title. In a box that
-- left one book lettered beside bare neighbours of nearly the same width
-- (maintainer, from a reader's screenshot), which reads as a fault. So one
-- function says whether a title fits across a spine, the painter and the box
-- both ask it, and a box with one book that fails letters none.

package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local src = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")
local function fn(name, args, env)
    local body = assert(src:match("\nfunction SpineShelf%." .. name .. "%(" .. args .. "%)\n(.-)\nend\n"),
        "SpineShelf." .. name .. " is missing")
    return assert(load("return function(" .. args .. ")\n" .. body .. "\nend", name, "t", env))()
end

local SpineShelf = { TITLE_MIN_SIZE = 6 }
-- A stand-in font: a line is twice its size tall.
local function tall(size) return size * 2 end
local fit = fn("titleFitSize", "band_w, face_size, inset, heightOf",
    { math = math, SpineShelf = SpineShelf })

t.test("a title that fits keeps its nominal size", function()
    eq(fit(30, 10, 1, tall), 10)
end)

t.test("a narrower spine steps the size down by two", function()
    eq(fit(18, 10, 1, tall), 8)
end)

t.test("an odd starting size still reaches the floor", function()
    -- 9, 7, then 6: the loop used to stop at 7 and drop a title that a
    -- slightly thinner spine, starting on 8, kept.
    eq(fit(14, 9, 1, tall), 6)
    eq(fit(14, 8, 1, tall), 6)
end)

t.test("nothing fits: no size", function()
    eq(fit(12, 9, 1, tall), nil)
end)

t.test("a spine under 8 px has no title whatever the font", function()
    eq(fit(7, 6, 0, function() return 1 end), nil)
end)

t.test("the border comes off both sides", function()
    eq(fit(16, 8, 0, tall), 8)
    eq(fit(16, 8, 2, tall), 6)
end)

t.test("the painter asks the same function", function()
    local painter = assert(src:match("\nlocal function _paintRotatedTitle%(.-%)\n(.-)\nend\n"))
    assert(painter:find("SpineShelf.titleFitSize(", 1, true), "the painter has its own fit loop again")
end)

-- The line heights the fit reads are remembered per size AND per font: the
-- reader can change the UI font mid-session, and a height kept from the old
-- one would pass a size the painter then finds too tall and drops.
t.test("a line's remembered height does not outlive a font change", function()
    local font, built = "one", 0
    local SS = {}
    local env = { SpineShelf = SS, math = math, pcall = pcall,
        BFont = { getUIFontFace = function() return font end,
                  getFace = function(_, name, size) return { name = name, size = size } end },
        TextWidget = { new = function(_, o)
            built = built + 1
            local h = (o.face.name == "one") and o.face.size or o.face.size * 3
            return { getSize = function() return { h = h } end, free = function() end }
        end } }
    local textHeight = fn("textHeight", "size", env)
    eq(textHeight(8), 8); eq(textHeight(8), 8); eq(built, 1, "measured once per font")
    font = "two"
    eq(textHeight(8), 24)
end)

-- ── the box ────────────────────────────────────────────────────────────────

local box = io.open("lib/bookshelf_series_box_widget.lua"):read("*a")
local body = assert(box:match("\nfunction Box%.titlesAllOrNone%(entries, fits%)\n(.-)\nend\n"),
    "Box.titlesAllOrNone is missing")
local allOrNone = assert(load("return function(entries, fits)\n" .. body .. "\nend",
    "titlesAllOrNone", "t", { ipairs = ipairs }))()

local function entries(...)
    local out = {}
    for i, w in ipairs({ ... }) do out[i] = { label = "Book " .. i, w = w } end
    return out
end
local function wide(e) return e.w >= 20 end

t.test("every book fits: every title stays", function()
    local es = entries(20, 24, 30)
    eq(allOrNone(es, wide), true)
    eq(es[1].label, "Book 1"); eq(es[3].label, "Book 3")
end)

t.test("one book too thin: no book is lettered", function()
    local es = entries(20, 12, 30)
    eq(allOrNone(es, wide), false)
    for _, e in ipairs(es) do eq(e.label, "") end
end)

t.test("a book with no title to draw does not count against the box", function()
    local es = entries(20, 12, 30)
    es[2].label = ""
    eq(allOrNone(es, wide), true)
    eq(es[1].label, "Book 1")
end)

t.test("the spine-out box applies it to its slots", function()
    local init = assert(box:match("\nfunction Box:_initSpines%(%)\n(.-)\nend\n"))
    assert(init:find("Box.titlesAllOrNone(", 1, true), "_initSpines does not apply the rule")
end)

t.done()
