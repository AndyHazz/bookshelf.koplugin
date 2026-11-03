-- tests/_test_published.lua
-- %published: which source wins, and the background read that fills a book
-- the first time a template asks (lib/bookshelf_published).
-- Usage (from plugin root): lua tests/_test_published.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

-- Facts: an in-memory stand-in with put's merge rule (false clears).
local rows = {}
local flushes = 0
local prefetched = {}
package.loaded["lib/bookshelf_book_facts_db"] = {
    get = function(fp) return rows[fp] end,
    put = function(fp, f)
        local e = rows[fp] or {}
        for k, v in pairs(f) do if v == false then e[k] = nil else e[k] = v end end
        rows[fp] = e
    end,
    flushSoon = function() flushes = flushes + 1 end,
    prefetch = function(fps) prefetched[#prefetched + 1] = fps end,
}
local scheduled = {}
package.loaded["ui/uimanager"] = {
    scheduleIn = function(_s, _d, fn) scheduled[#scheduled + 1] = fn end,
}
local mtimes = {}
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(fp, what) return what == "modification" and mtimes[fp] or nil end,
}
package.loaded["lib/bookshelf_pubdate"] = dofile("lib/bookshelf_pubdate.lua")
local Published = dofile("lib/bookshelf_published.lua")
package.loaded["lib/bookshelf_published"] = Published

local spawned
local function reset()
    rows, scheduled, spawned, flushes, mtimes = {}, {}, {}, 0, {}
    Published._reset()
    Published._spawn = function(batch, done) spawned[#spawned + 1] = { batch = batch, done = done } end
end
local function tick()
    local s = scheduled; scheduled = {}
    for _i, fn in ipairs(s) do fn() end
end

t.test("calibre's pubdate wins over everything", function()
    reset()
    rows["/b/a.epub"] = { pd = "1999" }
    eq(Published.forRecord({ filepath = "/b/a.epub", calibre = { pubdate = "1850" }, published = "1900" }), "1850")
end)

t.test("an OPDS catalog record's date, without touching the disk", function()
    reset()
    eq(Published.forRecord({ filepath = "OPDS://srv/id", published = "1923" }), "1923")
    tick()
    eq(#spawned, 0)
end)

t.test("a stored date shows its year; a stored empty shows nothing and is not re-read", function()
    reset()
    rows["/b/a.epub"] = { pd = "1869-03-01" }
    rows["/b/b.epub"] = { pd = "" }
    eq(Published.forRecord({ filepath = "/b/a.epub" }), "1869")
    eq(Published.forRecord({ filepath = "/b/b.epub" }), "")
    tick()
    eq(#spawned, 0)
end)

t.test("an unread book shows nothing, is queued once, and fills in the background", function()
    reset()
    local filled
    Published.on_filled = function(fps) filled = fps end
    local b1, b2 = { filepath = "/b/1.epub" }, { filepath = "/b/2.pdf" }
    eq(Published.forRecord(b1), "")
    eq(Published.forRecord(b2), "")
    eq(Published.forRecord(b1), "")          -- painted again before the read
    eq(#spawned, 0, "read during the paint")
    tick()
    eq(#spawned, 1)
    eq(#spawned[1].batch, 2, "one child for the page")
    spawned[1].done({ ["/b/1.epub"] = { date = "1901-02-03", mtime = 5 },
                      ["/b/2.pdf"]  = { date = "", mtime = 6 } })
    eq(rows["/b/1.epub"].pd, "1901-02-03"); eq(rows["/b/1.epub"].pdm, 5)
    eq(rows["/b/2.pdf"].pd, "")
    eq(flushes, 1)
    eq(#filled, 1); eq(filled[1], "/b/1.epub")
    eq(Published.forRecord(b1), "1901")
end)

t.test("a batch's results read their rows in one query before they are written", function()
    reset()
    prefetched = {}
    Published.forRecord({ filepath = "/b/1.epub" }); Published.forRecord({ filepath = "/b/2.epub" })
    tick()
    spawned[1].done({ ["/b/1.epub"] = { date = "1901", mtime = 1 }, ["/b/2.epub"] = { date = "", mtime = 2 } })
    eq(#prefetched, 1, "one prefetch for the batch")
    eq(#prefetched[1], 2)
end)

t.test("formats with no reader are never queued", function()
    reset()
    eq(Published.forRecord({ filepath = "/b/notes.txt" }), "")
    tick()
    eq(#spawned, 0)
end)

t.test("a long queue goes in batches, one child at a time", function()
    reset()
    for i = 1, 45 do Published.forRecord({ filepath = "/b/" .. i .. ".epub" }) end
    tick()
    eq(#spawned, 1); eq(#spawned[1].batch, 40)
    spawned[1].done({})
    eq(#spawned, 2); eq(#spawned[2].batch, 5)
end)

t.test("a fork that fails stops asking for the session", function()
    reset()
    Published.forRecord({ filepath = "/b/1.epub" })
    tick()
    spawned[1].done(nil)
    Published.forRecord({ filepath = "/b/2.epub" })
    tick()
    eq(#spawned, 1)
end)

t.test("an OPDS download's date is kept as if read from the file", function()
    reset()
    Published.remember("/b/dl.epub", "2015", 77)
    eq(rows["/b/dl.epub"].pd, "2015"); eq(rows["/b/dl.epub"].pdm, 77)
    eq(Published.forRecord({ filepath = "/b/dl.epub" }), "2015")
end)

t.test("forget: an unchanged file keeps its date, a changed one is read again", function()
    reset()
    rows["/b/same.epub"] = { pd = "2015", pdm = 77 }
    mtimes["/b/same.epub"] = 77
    Published.forget("/b/same.epub")
    eq(rows["/b/same.epub"].pd, "2015", "Refresh metadata lost an OPDS date")
    rows["/b/new.epub"] = { pd = "2015", pdm = 77 }
    mtimes["/b/new.epub"] = 90
    Published.forget("/b/new.epub")
    eq(rows["/b/new.epub"].pd, nil)
    Published.forRecord({ filepath = "/b/new.epub" })
    tick()
    eq(#spawned, 1)
end)

t.test("with the facts store's map, a lookup never queries per book", function()
    reset()
    local gets = 0
    local F = package.loaded["lib/bookshelf_book_facts_db"]
    local orig_get = F.get
    F.get = function(fp) gets = gets + 1; return orig_get(fp) end
    F.publishedMap = function() return { ["/b/known.epub"] = { pd = "1850" }, ["/b/none.epub"] = { pd = "" } } end
    eq(Published.forRecord({ filepath = "/b/known.epub" }), "1850")
    eq(Published.forRecord({ filepath = "/b/none.epub" }), "")
    eq(Published.forRecord({ filepath = "/b/unread.epub" }), "")
    eq(gets, 0, "asked the database book by book")
    tick()
    eq(#spawned, 1); eq(#spawned[1].batch, 1, "only the unread book is read")
    F.get, F.publishedMap = orig_get, nil
end)

-- ── the reader's own date (corrections) and Hardcover's ─────────────────────
t.test("a date the reader set wins over every source", function()
    reset()
    Published.setUserDate("/b/a.epub", "1850")
    eq(Published.forRecord({ filepath = "/b/a.epub", calibre = { pubdate = "1999" },
        published = "2001", hardcover_published = "1700" }), "1850")
    eq(Published.userDate("/b/a.epub"), "1850")
end)

t.test("Hardcover's year (Use Hardcover metadata) beats calibre, OPDS and the file", function()
    reset()
    rows["/b/a.epub"] = { pd = "2015", pdm = 3 }
    eq(Published.forRecord({ filepath = "/b/a.epub", calibre = { pubdate = "1999" },
        published = "2001", hardcover_published = "1897" }), "1897")
end)

t.test("the reader's date survives Refresh metadata, a changed file and an OPDS download", function()
    reset()
    Published.setUserDate("/b/a.epub", "1850-06-01")
    mtimes["/b/a.epub"] = 999
    Published.forget("/b/a.epub")
    Published.remember("/b/a.epub", "2015", 5)
    eq(Published.forRecord({ filepath = "/b/a.epub" }), "1850")
end)

t.test("clearing the reader's date goes back to reading the file", function()
    reset()
    Published.setUserDate("/b/a.epub", "1850")
    Published.setUserDate("/b/a.epub", nil)
    eq(Published.userDate("/b/a.epub"), nil)
    eq(Published.forRecord({ filepath = "/b/a.epub" }), "")
    tick()
    eq(#spawned, 1, "the file is read again")
end)

t.test("a date the reader types must parse", function()
    reset()
    eq(Published.setUserDate("/b/a.epub", "sometime"), false)
    eq(Published.setUserDate("/b/a.epub", "1869-03"), true)
    eq(Published.userDate("/b/a.epub"), "1869-03")
end)

t.test("Hardcover: the book's first year is fetched and applied with the metadata switch", function()
    local hc = io.open("lib/bookshelf_hardcover.lua"):read("*a")
    local _n, books_with_year = hc:gsub("book_series { position series { name } }%s+pages%s+release_year", "")
    assert(books_with_year == 2, "both enrichment queries must ask for release_year, got " .. books_with_year)
    assert(hc:find("published_year = tonumber(data.book.release_year)", 1, true), "not in the payload")
    local apply = hc:match("\nfunction Hardcover.applyMetadata%(book%)\n(.-)\nend\n")
    assert(apply and apply:find("book.hardcover_published", 1, true), "applyMetadata does not set it")
end)

t.test("wiring: the book menu's Publication date card sets the reader's date", function()
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    assert(w:find('{ id = "pubdate", text = pubdate_btn.text', 1, true), "no Publication date card")
    local del_at = w:find('{ id = "delete", text = _("Delete")', 1, true)
    local pub_at = w:find('{ id = "pubdate", text = pubdate_btn.text', 1, true)
    assert(del_at and pub_at > del_at, "the new card should come after Delete")
    assert(w:find("Published.setUserDate(book.filepath, text)", 1, true), "the card does not store the date")
    assert(w:find('require("lib/bookshelf_sort_engine").clearPublishedMemo()', 1, true),
        "a corrected date would not re-sort")
end)

t.test("wiring: the book menu header shows the year next to the file's details", function()
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    assert(w:find('T(_("Published %1"), pub_year)', 1, true), "the header does not show the year")
end)

t.test("wiring: the token, the OPDS feed, the download, Refresh metadata, the shelf", function()
    local tokens = io.open("lib/bookshelf_tokens.lua"):read("*a")
    assert(tokens:find('token = "%published"', 1, true))
    assert(tokens:find("Tokens.expanders.published", 1, true))
    assert(io.open("lib/bookshelf_opds_feed.lua"):read("*a"):find("rec.published = year", 1, true))
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    assert(w:find("Published.remember(path, book.published", 1, true))
    assert(w:find('require("lib/bookshelf_published").on_filled', 1, true))
    assert(io.open("lib/bookshelf_book_repository.lua"):read("*a")
        :find('require("lib/bookshelf_published").forget(fp)', 1, true))
end)

t.done()
