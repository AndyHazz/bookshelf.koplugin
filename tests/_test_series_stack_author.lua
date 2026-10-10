-- tests/_test_series_stack_author.lua
-- "Show text below covers: Author" applies to a SERIES stack too (issue 486).
--
-- WHAT NEEDS PINNING. With the label set to Author, a standalone book on a
-- Series shelf showed its author under the cover and the series stack beside
-- it showed nothing: the stack's one line was reserved for its NAME, which a
-- Divider card, a Ribbon or a Text tile already shows. Now that free line
-- carries the stack's author (StackDisplay.seriesLabel, unit-tested in
-- _test_stack_display; the author itself comes from Repo's hydrateSeriesShape,
-- tested in _test_book_repository). This file pins the WIRING in ShelfRow,
-- which needs a whole widget tree to build, so it is matched at source level.
--
-- Usage (from plugin root): lua tests/_test_series_stack_author.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()

local function read(p) local f = assert(io.open(p)); local s = f:read("*a"); f:close(); return s end
-- Comments stripped, so a commented-out call cannot satisfy a match.
local function code(p)
    local out = {}
    for line in read(p):gmatch("[^\n]*") do
        out[#out + 1] = (line:gsub("%s*%-%-.*$", ""))
    end
    return table.concat(out, "\n")
end
local row = code("lib/bookshelf_shelf_row.lua")

-- Each group branch, from its elseif to the next one.
local function branch(head)
    local s = row:find(head, 1, true)
    assert(s, "branch moved: " .. head)
    local e = row:find("\n        elseif item", s + #head, true)
    assert(e, "branch end not found: " .. head)
    return row:sub(s, e)
end

t.test("a series stack's label goes through seriesLabel, with the label mode", function()
    local b = branch("elseif item and item.books then")
    assert(b:find("StackDisplay.seriesLabel(group_mode, item, label_mode, _authorLabel)", 1, true),
        "the series stack does not offer its author to the label line")
    assert(not b:find("StackDisplay.externalLabel(", 1, true),
        "the series stack still prints only its name")
end)

t.test("author, genre, collection and language stacks are unchanged", function()
    -- An author stack is named after its author already; the others have no
    -- author of their own worth naming.
    for _i, kind in ipairs({ "author", "genre", "tag", "language" }) do
        local b = branch('elseif item and item.kind == "' .. kind .. '" then')
        assert(b:find("StackDisplay.externalLabel(group_mode, item.series_name)", 1, true),
            kind .. " stack's label changed")
        assert(not b:find("seriesLabel", 1, true), kind .. " stack now takes a series author")
    end
end)

t.test("the stack's author is formatted the way a book's is", function()
    -- One helper for both, declared above the slot loop that reads it (a local
    -- declared below its caller reads nil at paint time).
    local decl = row:find("local function _authorLabel(", 1, true)
    local loop = row:find("for i = 1, n_slots do", 1, true)
    assert(decl and loop and decl < loop, "_authorLabel must be declared before the slot loop")
    local labelFor = row:match("local function _labelFor%(item%)(.-)\n    end\n")
    assert(labelFor, "_labelFor moved")
    assert(labelFor:find("return _authorLabel(a)", 1, true),
        "the book label no longer shares the author formatting")
    local helper = row:match("local function _authorLabel%(a%)(.-)\n    end\n")
    assert(helper and helper:find("author_format", 1, true),
        "_authorLabel ignores Author name formatting")
end)

t.test("the strip is still gated on the reader's own preference", function()
    -- seriesLabel's text reaches the strip through wrap_for_title_alignment,
    -- which prints nothing unless "Show text below covers" is on.
    local w = row:match("local function wrap_for_title_alignment%(widget, group_name%)(.-)\n        end\n")
    assert(w, "wrap_for_title_alignment moved")
    assert(w:find("if draw_label and", 1, true), "group labels are no longer gated on draw_label")
end)

t.done()
