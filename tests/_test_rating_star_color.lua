-- tests/_test_rating_star_color.lua
-- Issue 594: the rating stars in the top panel can take a colour of their own.
--
-- Usage (from plugin root): lua tests/_test_rating_star_color.lua
--
-- One colour in the theme's colour menu. It reaches the panel's star row (the
-- Hardcover stars, or the reader's own tappable ones) and the star rows the
-- %rating and %hardcover_stars tokens put into the panel's text, wherever they
-- land: a single line, a truncated one, or wrapped text. Filled and empty
-- stars both take it. Unset, nothing changes: the stars stay in the text ink.

package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local src = io.open("lib/bookshelf_hero_card.lua"):read("*a")
local function body(name, args)
    return assert(src:match("\nlocal function " .. name .. "%(" .. args .. "%)\n(.-)\nend\n"),
        name .. " moved")
end

local STAR, EMPTY = "\xE2\x98\x85", "\xE2\x98\x86"
local HC_FULL, HC_HALF, HC_EMPTY = "\xef\x80\x85", "\xef\x84\xa3", "\xef\x80\x86"

-- lib/bookshelf_star_runs.lua: which parts of a text are a book's star rows,
-- and the colour they take. Shared by the top panel and the list rows.
local resolved = {}
local colour_reads = 0
package.loaded["lib/bookshelf_cover_progress"] = {
    resolvedColors = function() colour_reads = colour_reads + 1; return resolved end,
}
package.loaded["lib/bookshelf_tokens"] = { expanders = {
    rating = function(b) return b.rating and (STAR:rep(b.rating) .. EMPTY:rep(5 - b.rating)) or "" end,
    hardcover_stars = function(b) return b.hc or "" end,
} }
package.loaded["lib/bookshelf_colour_runs"] = dofile("lib/bookshelf_colour_runs.lua")
local StarRuns = dofile("lib/bookshelf_star_runs.lua")
local function with(colour, fn) resolved = { rating_star = colour }; fn(); resolved = {} end

t.test("unset, there is no star colour", function()
    eq(StarRuns.ink(), nil)
end)

t.test("the reader's pick is the star colour", function()
    with("gold", function() eq(StarRuns.ink(), "gold") end)
end)

t.test("with a colour set, the book's own star row in a text is a run", function()
    with("gold", function()
        local runs = StarRuns.inText({ rating = 3 }, "My rating: " .. STAR:rep(3) .. EMPTY:rep(2) .. " done")
        eq(#runs, 1)
        eq(runs[1].s, 12); eq(runs[1].e, 16); eq(runs[1].colour, "gold")
    end)
end)

t.test("filled and empty stars are one run, so both take the colour", function()
    with("gold", function()
        local runs = StarRuns.inText({ rating = 1 }, STAR .. EMPTY:rep(4))
        eq(runs[1].s, 1); eq(runs[1].e, 5)
    end)
end)

t.test("the Hardcover star row is a run too", function()
    with("gold", function()
        local row = HC_FULL:rep(3) .. HC_HALF .. HC_EMPTY
        local runs = StarRuns.inText({ hc = row }, "x " .. row .. " y")
        eq(#runs, 1); eq(runs[1].s, 3); eq(runs[1].e, 7)
    end)
end)

t.test("with no colour set there are no runs, whatever the text", function()
    eq(StarRuns.inText({ rating = 3 }, STAR:rep(3) .. EMPTY:rep(2)), nil)
end)

t.test("an unrated book has no runs", function()
    with("gold", function() eq(StarRuns.inText({}, STAR:rep(3) .. EMPTY:rep(2)), nil) end)
end)

t.test("a different rating's stars, typed by hand, are left alone", function()
    with("gold", function() eq(StarRuns.inText({ rating = 2 }, STAR:rep(3) .. EMPTY:rep(2)), nil) end)
end)

t.test("a text with no star in it costs no colour lookup at all", function()
    with("gold", function()
        colour_reads = 0
        eq(StarRuns.inText({ rating = 3 }, "just words, and an accent: é"), nil)
        eq(colour_reads, 0, "list rows ask this for every piece of every row")
    end)
end)

t.test("no book, or no text: no runs", function()
    with("gold", function()
        eq(StarRuns.inText(nil, STAR:rep(5)), nil)
        eq(StarRuns.inText({ rating = 5 }, nil), nil)
    end)
end)

t.test("both ways into the panel set the stars up for their book", function()
    local col = assert(src:match("\nfunction HeroCard:_buildRightColumn%(book, regions, state, dimen%)\n(.-)\nend\n"))
    assert(col:find("_setStarRuns(book)", 1, true), "the panel's column")
    local row = body("_buildStatusRow", "book, state, width, with_hairline, allow_job")
    assert(row:find("_setStarRuns(book)", 1, true), "the full-width status row")
end)

t.test("the star row is drawn in the star colour, falling back to the ink", function()
    local col = assert(src:match("\nfunction HeroCard:_buildRightColumn%(book, regions, state, dimen%)\n(.-)\nend\n"))
    assert(col:find("local star_ink = StarRuns.ink()", 1, true))
    assert(col:find("fgcolor = star_ink,", 1, true), "the stars")
end)

t.test("the panel's texts ask for the stars of the book being built", function()
    assert(body("_runsIn", "text"):find("return StarRuns.inText(_star_book, text)", 1, true))
    assert(body("_setStarRuns", "book"):find("_star_book = book", 1, true))
end)

-- List view (the default first line ends "%rating %favourite").
t.test("list rows: single-line pieces and wrapped lines hand their runs over", function()
    local lr = io.open("lib/bookshelf_list_row.lua"):read("*a")
    local wb = assert(lr:match("\nlocal function wrapBox%(line, flat, inner_w, height%)\n(.-)\nend\n"), "wrapBox moved")
    assert(wb:find("local runs = StarRuns.inText(ListRow._star_record, flat)", 1, true))
    assert(wb:find("if runs then", 1, true) and wb:find("return RunTextBox:new{", 1, true))
    local tl = assert(lr:match("\nfunction ListRow.textLine%(record, line, width, pad, template, opts%)\n(.-)\nend\n"), "textLine moved")
    assert(tl:find("ListRow._star_record = record", 1, true))
    assert(tl:find("runs          = StarRuns.inText(record, s),", 1, true))
    local pr = assert(lr:match("\nfunction ListRow.packRow%(record, L, group_templates, text_w%)\n(.-)\nend\n"), "packRow moved")
    assert(pr:find("ListRow._star_record = record", 1, true), "packRow builds the wrapped boxes")
end)

t.test("every text the panel builds from a template hands its runs to the widget", function()
    local seg = body("_buildSegmentedInline", "text, face, bold, max_width, truncate_left")
    local _, n = seg:gsub("runs = _runsIn%(", "")
    eq(n, 3, "single-line pieces")
    local bt = body("buildText", "text, region, width, max_height")
    assert(bt:find("runs    = _runsIn(seg.text)", 1, true), "bold pieces")
    assert(bt:find("local runs = _runsIn(rendered)", 1, true), "wrapped text")
    assert(bt:find("(runs and RunTextBox or textBoxClass()):new{", 1, true))
end)

t.test("the description's paragraphs hand their runs over too", function()
    local col = assert(src:match("\nfunction HeroCard:_buildRightColumn%(book, regions, state, dimen%)\n(.-)\nend\n"))
    assert(col:find("local pruns = _runsIn(ptext)", 1, true))
    assert(col:find("local pwid = (pruns and RunTextBox or textBoxClass()):new{", 1, true))
    assert(col:find("runs                          = pruns,", 1, true))
end)

t.test("the palette reads the key with no default, for day and night", function()
    local cp = io.open("lib/bookshelf_cover_progress.lua"):read("*a")
    assert(cp:find('_readModeColor("rating_star_color", nil)', 1, true))
    assert(cp:find("rating_star       = rating_star_raw and _paint(rating_star_raw) or nil", 1, true))
    assert(cp:find('rating_star       = _readOwnColor("rating_star_color", nil)', 1, true))
end)

t.test("it has a row in the colour menu, and Reset to default colors clears it", function()
    local st = io.open("lib/bookshelf_settings.lua"):read("*a")
    assert(st:find('"rating_star_color"', 1, true), "the reset list misses the new key")
    assert(st:find('pickColor("rating_star_color", "rating_star"', 1, true))
    assert(st:find('deleteModeKey("rating_star_color")', 1, true))
end)

t.test("a theme pack can set it, by name", function()
    local tp = io.open("lib/bookshelf_theme_pack.lua"):read("*a")
    assert(tp:find('%["rating stars"%]%s+= "rating_star_color"'))
end)

t.test("the picker has a default swatch for it", function()
    local c = io.open("lib/bookshelf_color.lua"):read("*a")
    assert(c:find('rating_star%s+= "#FFD700"'))
end)

t.done()
