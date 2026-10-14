-- tests/_test_opds_pse.lua
-- OPDS page streaming (PR 496): a PSE stream link becomes opds.stream on the
-- record, a stream-only entry (a Suwayomi chapter) is still a book, and other
-- plugins can add buttons to an OPDS book's details (registerRecordActions).
--
-- Usage (from plugin root): lua tests/_test_opds_pse.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["logger"] = { dbg=function() end, info=function() end,
                             warn=function() end, err=function() end }
local helpers = dofile("tests/_helpers.lua")
local t, eq = helpers.runner(), helpers.eq

local Feed = dofile("lib/bookshelf_opds_feed.lua")
local STREAM = "http://vaemendis.net/opds-pse/stream"

local function entry(id, title, links)
    return { id = id, title = title, author = { name = "A. Writer" }, link = links }
end

t.test("a Komga entry keeps its download and gains a stream", function()
    local res = Feed.mapEntries({ entry = { entry("urn:1", "Vol 1", {
        { rel = "http://opds-spec.org/acquisition", type = "application/zip", href = "/opds/v1.2/books/1/file" },
        { rel = STREAM, type = "image/jpeg", href = "/api/v1/books/1/pages/{pageNumber}?zero_based=true",
          ["pse:count"] = "42", ["pse:lastRead"] = "7" },
    }) } }, "http://h:25600/opds/v1.2/catalog", "k")
    local rec = res.records[1]
    eq(#rec.opds.acquisitions, 1)
    eq(rec.opds.stream.count, 42)
    eq(rec.opds.stream.last_read, 7)
    eq(rec.opds.stream.href, "http://h:25600/api/v1/books/1/pages/{pageNumber}?zero_based=true")
end)

t.test("a stream-only chapter is a book, not dropped", function()
    local res = Feed.mapEntries({ entry = { entry("urn:2", "Chapter 3", {
        { rel = STREAM, type = "image/jpeg", href = "/stream/3/{pageNumber}", ["p:count"] = "18" },
    }) } }, "http://s/opds", "k")
    eq(#res.records, 1)
    eq(#res.records[1].opds.acquisitions, 0)
    eq(res.records[1].opds.stream.count, 18)
    eq(res.records[1].opds.stream.last_read, nil, "no lastRead, none recorded")
end)

t.test("a stream link without a page count is ignored", function()
    local res = Feed.mapEntries({ entry = { entry("urn:3", "Broken", {
        { rel = STREAM, type = "image/jpeg", href = "/s/{pageNumber}" },
    }) } }, "http://s/opds", "k")
    eq(#res.records, 0)
end)

t.test("a lastRead of 0 or 1 is not a place to resume from", function()
    eq(Feed._streamOf({ ["pse:count"] = "5", ["pse:lastRead"] = "0" }, "x").last_read, nil)
    eq(Feed._streamOf({ ["pse:count"] = "5", ["pse:lastRead"] = "1" }, "x").last_read, nil)
    eq(Feed._streamOf({ ["pse:count"] = "5", ["pse:lastRead"] = "2" }, "x").last_read, 2)
end)

t.test("editions merged into one record keep the first stream", function()
    local res = Feed.mapEntries({ entry = {
        entry("urn:a", "Same", { { rel = STREAM, href = "/s/a/{pageNumber}", ["pse:count"] = "10" } }),
        entry("urn:b", "Same", { { rel = STREAM, href = "/s/b/{pageNumber}", ["pse:count"] = "20" },
            { rel = "http://opds-spec.org/acquisition", type = "application/epub+zip", href = "/b.epub" } }),
    } }, "http://s/opds", "k")
    eq(#res.records, 1)
    eq(res.records[1].opds.stream.count, 10)
    eq(#res.records[1].opds.acquisitions, 1)
end)

-- ── registerRecordActions ──────────────────────────────────────────────────

local RA = require("lib/bookshelf_record_actions")

t.test("providers' buttons come back in id order, bad ones dropped", function()
    RA.register("b", function(book) return { { text = "B " .. book.title, callback = function() end } } end)
    RA.register("a", function() return { { text = "A", callback = function() end },
                                         { text = "", callback = function() end },
                                         { text = "no callback" } } end)
    RA.register("c", function() error("boom") end)
    local got = RA.buttonsFor({ title = "T" }, {})
    eq(#got, 2); eq(got[1].text, "A"); eq(got[2].text, "B T")
    for _i, id in ipairs({ "a", "b", "c" }) do RA.register(id, nil) end
    eq(#RA.buttonsFor({ title = "T" }, {}), 0)
end)

t.test("a button whose callback errors does not throw", function()
    RA.register("x", function() return { { text = "X", callback = function() error("bad") end } } end)
    local got = RA.buttonsFor({}, {})
    assert(pcall(got[1].callback))
    RA.register("x", nil)
end)

t.test("bad registrations are refused", function()
    eq(RA.register(nil, function() end), false)
    eq(RA.register("y", 5), false)
end)

t.test("the details window offers streaming and plugin buttons before giving up", function()
    local src = io.open("lib/bookshelf_widget.lua"):read("*a")
    local body = src:match("\nfunction BookshelfWidget:_showRemoteBookInfo%(book, opts%)\n(.-)\nend\n")
    assert(body, "could not find _showRemoteBookInfo")
    assert(body:find('_("Page stream")', 1, true), "no Page stream button")
    assert(body:find("RecordActions.buttonsFor(", 1, true), "plugin buttons not asked for")
    assert(body:find("if #usable == 0 and not stream and #plugin_buttons == 0 then", 1, true),
        "the no-formats note must give way to a stream or a plugin button")
end)

t.done()
