-- tests/_test_list_bar_finished.lua
-- #487: a book marked finished without ever being opened has a sidecar with
-- summary.status but no percent_finished, so the list row's %bar drew empty.
-- Usage (from plugin root): lua tests/_test_list_bar_finished.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local SIDECAR = {
    ["/b/finished_unopened.epub"] = { status = "finished" },
    ["/b/finished_at_97.epub"]    = { status = "finished", pct = 0.97 },
    ["/b/reading.epub"]           = { status = "reading",  pct = 0.42 },
    ["/b/opened_at_zero.epub"]    = { status = "reading",  pct = 0 },
}
package.loaded["lib/bookshelf_book_repository"] = {
    progressFor = function(fp)
        local s = SIDECAR[fp]
        if not s then return nil, nil, nil, nil, false end
        return s.pct, s.status, nil, nil, true
    end,
}

local helpers     = dofile("tests/_helpers.lua")
local t           = helpers.runner()
local ListGeom    = require("lib/bookshelf_list_geom")
local TokenRecord = require("lib/bookshelf_token_record")

local function barFor(fp)
    local r = TokenRecord.wrap({ filepath = fp })
    return ListGeom.barFraction(r.book_pct, r.status)
end

t.test("finished but never opened draws a full bar", function()
    assert(barFor("/b/finished_unopened.epub") == 1,
        "a finished book with no percent_finished must fill the bar")
end)

t.test("books with a real position keep it", function()
    assert(barFor("/b/reading.epub") == 0.42)
    assert(barFor("/b/opened_at_zero.epub") == 0)
    assert(barFor("/b/finished_at_97.epub") == 0.97)
end)

t.test("never opened, no status: empty bar as before", function()
    assert(barFor("/b/new.epub") == 0)
end)

t.test("the list row asks barFraction for its %bar", function()
    local src = io.open("lib/bookshelf_list_row.lua"):read("*a")
    assert(src:find("ListRow.bar(line, bar_w, ListGeom.barFraction(", 1, true),
        "ListRow's %bar no longer goes through ListGeom.barFraction")
end)

t.done()
