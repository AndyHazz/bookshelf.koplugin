-- tests/_test_editor_page.lua
-- The shelf editor's page blocks: how they group for paging (a page break
-- never parts a heading from what it heads, nor a half-width pair), and the
-- ButtonDialog rows they fall back to with no editor to host them.
--
-- Usage (from plugin root): lua tests/_test_editor_page.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq
local Page = dofile("lib/bookshelf_editor_page.lua")

local function shape(blocks)
    local out = {}
    for _i, u in ipairs(Page._units(blocks)) do
        local names = {}
        for _j, b in ipairs(u) do names[#names + 1] = b.name end
        out[#out + 1] = table.concat(names, "+")
    end
    return table.concat(out, " | ")
end

t.test("a heading stays with the block it heads, and a hint under it too", function()
    eq(shape({
        { type = "row", name = "theme" },
        { type = "heading", name = "h" }, { type = "hint", name = "hint" }, { type = "chips", name = "c" },
        { type = "row", name = "r" },
    }), "theme | h+hint+c | r")
end)

t.test("half blocks page by the pair, the first pair with its heading", function()
    eq(shape({
        { type = "heading", name = "h" },
        { type = "option", half = true, name = "a" }, { type = "option", half = true, name = "b" },
        { type = "option", half = true, name = "c" }, { type = "option", half = true, name = "d" },
        { type = "option", half = true, name = "e" },
        { type = "chips", name = "f" },
    }), "h+a+b | c+d | e | f")
end)

t.test("a hint not under a heading stands alone", function()
    eq(shape({ { type = "row", name = "a" }, { type = "hint", name = "h" } }), "a | h")
end)

t.test("the fallback rows tick what is on and grey what only explains", function()
    local rows = Page.toButtons({
        strip = { { type = "summary", text = "By Title (A-Z)." } },
        blocks = {
            { type = "chips", items = { { text = "Title", on = true }, { text = "Author" } } },
            { type = "segmented", label = "Binding", active = "h",
              items = { { key = "h", label = "Hardback" }, { key = "p", label = "Paperback" } },
              on_pick = function() end },
        },
    })
    eq(rows[1][1].text, "By Title (A-Z)."); eq(rows[1][1].enabled, false)
    eq(rows[2][1].text, "\xE2\x9C\x93 Title"); eq(rows[2][2].text, "  Author")
    eq(rows[3][1].text, "Binding")
    eq(rows[4][1].text, "\xE2\x9C\x93 Hardback")
end)

-- A folder's path shortened in the middle, so where it starts and the
-- folder's own name both stay in sight, wherever on the device it is
-- (maintainer: folders outside the home folder can be picked too).
t.test("a long path drops the folders nearest its name first", function()
    local function fitsIn(n) return function(s) return #s <= n end end
    local p = "/mnt/us/ebooks/Fiction/Standard Ebooks"
    eq(Page._shortenPath(p, fitsIn(100)), p)
    eq(Page._shortenPath(p, fitsIn(35)), "/mnt/us/ebooks/\xE2\x80\xA6/Standard Ebooks")
    eq(Page._shortenPath(p, fitsIn(28)), "/mnt/us/\xE2\x80\xA6/Standard Ebooks")
    eq(Page._shortenPath(p, fitsIn(20)), "/\xE2\x80\xA6/Standard Ebooks")
    -- Too narrow even for that: the shortest, and the text itself cuts it.
    eq(Page._shortenPath(p, fitsIn(5)), "/\xE2\x80\xA6/Standard Ebooks")
end)

t.test("a short or one-folder path is left alone", function()
    local function never() return false end
    eq(Page._shortenPath("/books", never), "/books")
    eq(Page._shortenPath("/", never), "/")
end)

-- Buttons (STYLE.md): a grey card nudges a value in place or opens a thing;
-- an outline chooses or commits. A stepper's - and + nudge, so they are
-- cards with the symbols font's minus and plus, as the ornament menu's are
-- (maintainer: the view mode's outlined steppers did not match it).
t.test("a stepper's - and + are grey cards, as the ornament menu's", function()
    local src = io.open("lib/bookshelf_editor_page.lua"):read("*a")
    local body = src:match("\n(function R%.stepper%(.-\nend)\n")
    assert(body, "R.stepper moved")
    assert(not body:find("smallButton", 1, true), "the stepper is still outlined buttons")
    local card = src:match("\n(function Ctx:nudgeCard%(.-\nend)\n")
    assert(body:find("ctx:nudgeCard(", 1, true) and card and card:find("card = true", 1, true),
        "the stepper's buttons are not cards")
    assert(body:find("\\xEF\\x81\\xA8", 1, true) or body:find("MINUS", 1, true),
        "the minus is not the symbols font's")
    local style = io.open("STYLE.md"):read("*a")
    assert(style:find("an outline chooses or commits", 1, true), "STYLE.md does not give the rule")
end)

t.done()
