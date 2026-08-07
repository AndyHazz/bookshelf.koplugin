-- tests/_test_opds_feed.lua
-- Pure halves of the OPDS feed layer: URL absolutisation and the
-- catalog-table -> shelf-record mapping. The luxl-backed parse() is exercised
-- only when a KOReader tree is present (it needs ffi); see the tail.
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["logger"] = { dbg=function() end, info=function() end,
                             warn=function() end, err=function() end }

local Feed = dofile("lib/bookshelf_opds_feed.lua")

local pass, fail = 0, 0
local function eq(got, want, label)
    if got == want then pass = pass + 1
    else fail = fail + 1; print("FAIL " .. label .. ": got " .. tostring(got) .. " want " .. tostring(want)) end
end
local function ok(cond, label)
    if cond then pass = pass + 1 else fail = fail + 1; print("FAIL " .. label) end
end

-- absolute(): the four href shapes feeds actually use
eq(Feed.absolute("http://h/opds/root", "http://x/a"), "http://x/a", "absolute href untouched")
eq(Feed.absolute("http://h/opds/root", "/covers/1.jpg"), "http://h/covers/1.jpg", "host-root href")
eq(Feed.absolute("http://h/opds/root", "page2"), "http://h/opds/page2", "relative href")
eq(Feed.absolute("http://h/opds/root/", "page2"), "http://h/opds/root/page2", "relative href, dir base")
eq(Feed.absolute("https://h/a", "//cdn/x.jpg"), "https://cdn/x.jpg", "scheme-relative href")

-- mapEntries(): one acquisition entry, one nav entry, feed-level links
local catalog = {
    feed = {
        link = {
            { rel = "next", type = "application/atom+xml;profile=opds-catalog",
              href = "/opds/all?page=2" },
        },
        ["opensearch:totalResults"] = "142",
        entry = {
            {   -- a book
                title = "A Book",
                author = { name = "An Author" },
                content = "A summary.",
                link = {
                    { rel = "http://opds-spec.org/acquisition",
                      type = "application/epub+zip", href = "/dl/1.epub" },
                    { rel = "http://opds-spec.org/image/thumbnail",
                      type = "image/jpeg", href = "/thumb/1.jpg" },
                    { rel = "http://opds-spec.org/image",
                      type = "image/jpeg", href = "/img/1.jpg" },
                },
                id = "urn:uuid:0001",
            },
            {   -- a navigation entry
                title = "Fiction",
                link = {
                    { rel = "subsection",
                      type = "application/atom+xml;profile=opds-catalog",
                      href = "/opds/fiction" },
                },
                id = "urn:nav:fiction",
            },
            {   -- borrow-only entry: no supported acquisitions -> dropped
                title = "Library Book",
                link = {
                    { rel = "http://opds-spec.org/acquisition/borrow",
                      type = "application/epub+zip", href = "/borrow/9" },
                },
                id = "urn:uuid:0009",
            },
        },
    },
}
local res = Feed.mapEntries(catalog, "http://h/opds/all", "abcd1234")
eq(res.total, 142, "totalResults parsed")
eq(res.next_url, "http://h/opds/all?page=2", "next link absolutised")
eq(#res.records, 1, "one book record (borrow-only dropped)")
eq(#res.nav, 1, "one nav entry")

local b = res.records[1]
ok(b.is_remote == true, "book is_remote")
eq(b.filepath, "OPDS://abcd1234/urn:uuid:0001", "virtual filepath from entry id")
eq(b.title, "A Book", "title")
eq(b.author, "An Author", "author")
eq(b.status, "unread", "status unread")
eq(b.opds.thumbnail_url, "http://h/thumb/1.jpg", "thumbnail absolutised")
eq(b.opds.image_url, "http://h/img/1.jpg", "image absolutised")
eq(b.opds.summary, "A summary.", "summary carried")
eq(#b.opds.acquisitions, 1, "one acquisition")
eq(b.opds.acquisitions[1].href, "http://h/dl/1.epub", "acquisition absolutised")

local n = res.nav[1]
ok(n.is_opds_nav == true, "nav flagged")
eq(n.label, "Fiction", "nav label")
eq(n.feed_url, "http://h/opds/fiction", "nav url absolutised")

-- author as array (multiple <author> tags), title precedence, missing id
local cat2 = { feed = { entry = { {
    title = "T", id = nil,
    author = { name = { "A", "B" } },
    link = { { rel = "http://opds-spec.org/acquisition",
               type = "application/epub+zip", href = "x.epub" } },
} } } }
local res2 = Feed.mapEntries(cat2, "http://h/f", "k")
eq(res2.records[1].author, "A, B", "authors joined")
ok(res2.records[1].filepath:match("^OPDS://k/"), "fallback id still yields a filepath")

-- parse(): only when a KOReader tree provides luxl (needs luajit's ffi)
local koreader_dir = os.getenv("KOREADER_DIR") or "/usr/lib/koreader"
local have_ffi = pcall(require, "ffi")
local f = io.open(koreader_dir .. "/frontend/luxl.lua", "r")
if have_ffi and f then
    f:close()
    package.path = koreader_dir .. "/frontend/?.lua;" .. package.path
    local xml = [[<?xml version="1.0"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <entry><title>X</title><id>i1</id>
    <link rel="http://opds-spec.org/acquisition" type="application/epub+zip" href="/x.epub"/>
  </entry>
</feed>]]
    local cat = Feed.parse(xml)
    ok(type(cat) == "table" and cat.feed and cat.feed.entry, "parse yields a feed table")
    local r3 = Feed.mapEntries(cat, "http://h/", "k")
    eq(#r3.records, 1, "parsed entry maps to a record")
else
    if f then f:close() end
    print("note: parse() fixture skipped (no luajit ffi or no KOReader tree)")
end

print(string.format("%d pass, %d fail", pass, fail))
if fail > 0 then os.exit(1) end
