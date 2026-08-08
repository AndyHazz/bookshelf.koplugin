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

-- sameOrigin(): the credential gate. True only when scheme, host
-- (case-insensitive) and port (explicit or scheme default) all match.
ok(Feed.sameOrigin("http://h/a", "http://h/b") == true, "same host+scheme -> true")
ok(Feed.sameOrigin("http://Host/a", "http://host/b") == true, "differing host case -> true")
ok(Feed.sameOrigin("http://h/a", "https://h/a") == false, "http vs https -> false")
ok(Feed.sameOrigin("http://h:8080/a", "http://h/a") == false, "different port -> false")
ok(Feed.sameOrigin("http://h:80/a", "http://h/a") == true, "explicit-80 vs implicit http -> true")
ok(Feed.sameOrigin("https://h:443/a", "https://h/a") == true, "explicit-443 vs implicit https -> true")
ok(Feed.sameOrigin("http://h/a", "http://other/a") == false, "cross host -> false")
ok(Feed.sameOrigin("http://h/a", "/relative/path") == false, "relative input -> false")
ok(Feed.sameOrigin("http://h/a", "not a url") == false, "garbage input -> false")
ok(Feed.sameOrigin("http://h/a", nil) == false, "nil input -> false")
ok(Feed.sameOrigin(nil, nil) == false, "both nil -> false")

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
            {   -- a navigation entry, also carrying its own cover links
                -- (a category tile with its own artwork)
                title = "Fiction",
                link = {
                    { rel = "subsection",
                      type = "application/atom+xml;profile=opds-catalog",
                      href = "/opds/fiction" },
                    { rel = "http://opds-spec.org/image/thumbnail",
                      type = "image/jpeg", href = "/thumb/fiction.jpg" },
                    { rel = "http://opds-spec.org/image",
                      type = "image/jpeg", href = "/img/fiction.jpg" },
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
            {   -- nav entry missing a title -> dropped (existing behaviour)
                link = {
                    { rel = "subsection",
                      type = "application/atom+xml;profile=opds-catalog",
                      href = "/opds/untitled" },
                },
                id = "urn:nav:untitled",
            },
        },
    },
}
local res = Feed.mapEntries(catalog, "http://h/opds/all", "abcd1234")
eq(res.total, 142, "totalResults parsed")
eq(res.next_url, "http://h/opds/all?page=2", "next link absolutised")
eq(#res.records, 2, "one nav record + one book record (borrow-only, untitled nav dropped)")
eq(res.nav, nil, "separate nav list retired")

local n = res.records[1]
eq(n.kind, "opds_nav", "nav record kind")
ok(n.is_remote == true, "nav is_remote")
ok(n.is_opds_nav == true, "nav flagged")
eq(n.label, "Fiction", "nav label")
eq(n.title, "Fiction", "nav title")
eq(n.display_title, "Fiction", "nav display_title")
ok(n.filepath:match("^OPDS://abcd1234/nav/") ~= nil, "nav filepath namespaced under server")
eq(n.opds.feed_url, "http://h/opds/fiction", "nav feed_url absolutised")
eq(n.opds.thumbnail_url, "http://h/thumb/fiction.jpg", "nav thumbnail absolutised")
eq(n.opds.image_url, "http://h/img/fiction.jpg", "nav image absolutised")
eq(n.status, "unread", "nav status unread (so CoverProgress never probes DocSettings for it)")
eq(n.read_status, "unread", "nav read_status unread")

local b = res.records[2]
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

-- dedupe: two nav entries pointing at the same feed_url get the same filepath
local cat_dupe = { feed = { entry = { {
    title = "Fiction", id = "n1",
    link = { { rel = "subsection", type = "application/atom+xml;profile=opds-catalog",
               href = "/opds/fiction" } },
}, {
    title = "Fiction (again)", id = "n2",
    link = { { rel = "subsection", type = "application/atom+xml;profile=opds-catalog",
               href = "/opds/fiction" } },
} } } }
local res_dupe = Feed.mapEntries(cat_dupe, "http://h/opds/all", "abcd1234")
eq(#res_dupe.records, 2, "both nav entries mapped")
eq(res_dupe.records[1].filepath, res_dupe.records[2].filepath,
    "same feed_url -> same nav filepath (dedupe key stability)")

-- a nav-only feed (no acquisitions anywhere) still yields records
local cat_nav_only = { feed = { entry = { {
    title = "Nonfiction",
    link = { { rel = "subsection", type = "application/atom+xml;profile=opds-catalog",
               href = "/opds/nonfiction" } },
} } } }
local res_nav_only = Feed.mapEntries(cat_nav_only, "http://h/opds/all", "abcd1234")
eq(#res_nav_only.records, 1, "nav-only feed still yields a record")
eq(res_nav_only.records[1].kind, "opds_nav", "nav-only record is nav kind")
eq(res_nav_only.records[1].opds.thumbnail_url, nil, "no cover link -> nav thumbnail_url nil")
eq(res_nav_only.records[1].opds.image_url, nil, "no cover link -> nav image_url nil")

-- edition collapse: two entries, same title+author, different acquisitions
-- (Gutenberg's shape: a with-images and a no-images edition of one work)
local cat_edition = { feed = { entry = { {
    title = "Same Title", author = { name = "Same Author" },
    content = "First summary.",
    id = "urn:uuid:e1",
    link = {
        { rel = "http://opds-spec.org/acquisition", type = "application/epub+zip",
          title = "EPUB (with images)", href = "/dl/e1.epub" },
        { rel = "http://opds-spec.org/image/thumbnail", type = "image/jpeg", href = "/thumb/e1.jpg" },
    },
}, {
    title = "Same Title", author = { name = "Same Author" },
    content = "Second summary.",
    id = "urn:uuid:e2",
    link = {
        { rel = "http://opds-spec.org/acquisition", type = "application/epub+zip",
          title = "EPUB (no images, older E-readers)", href = "/dl/e2.epub" },
    },
} } } }
local res_edition = Feed.mapEntries(cat_edition, "http://h/opds/all", "abcd1234")
eq(#res_edition.records, 1, "same title+author editions collapse to one record")
local e = res_edition.records[1]
eq(e.filepath, "OPDS://abcd1234/urn:uuid:e1", "merged record keeps first entry's filepath")
eq(e.opds.summary, "First summary.", "merged record keeps first entry's summary")
eq(e.opds.thumbnail_url, "http://h/thumb/e1.jpg", "merged record keeps first entry's thumbnail")
eq(#e.opds.acquisitions, 2, "acquisitions concatenate across merged editions")
eq(e.opds.acquisitions[1].title, "EPUB (with images)", "first edition acquisition kept in order")
eq(e.opds.acquisitions[2].title, "EPUB (no images, older E-readers)", "second edition acquisition appended in order")

-- summary: the FULLEST edition wins. Gutenberg's stripped edition ("all images
-- removed") is often first in the feed, so first-entry-wins showed a warning
-- about a limitation the merged record no longer has. Most acquisitions wins;
-- the two entries above tie at one each, so that case keeps the first.
local cat_fuller = { feed = { entry = { {
    title = "Fuller", author = { name = "An Author" }, id = "urn:uuid:f1",
    content = "This edition had all images removed.",
    link = {
        { rel = "http://opds-spec.org/acquisition", type = "application/epub+zip",
          title = "EPUB (no images)", href = "/dl/f1.epub" },
        { rel = "http://opds-spec.org/image/thumbnail", type = "image/jpeg", href = "/thumb/f1.jpg" },
    },
}, {
    title = "Fuller", author = { name = "An Author" }, id = "urn:uuid:f2",
    content = "The complete edition, with illustrations.",
    link = {
        { rel = "http://opds-spec.org/acquisition", type = "application/epub+zip",
          title = "EPUB (with images)", href = "/dl/f2.epub" },
        { rel = "http://opds-spec.org/acquisition", type = "application/x-mobipocket-ebook",
          title = "Kindle (with images)", href = "/dl/f2.mobi" },
        { rel = "http://opds-spec.org/image/thumbnail", type = "image/jpeg", href = "/thumb/f2.jpg" },
    },
} } } }
local res_fuller = Feed.mapEntries(cat_fuller, "http://h/opds/all", "abcd1234")
eq(#res_fuller.records, 1, "fuller: the two editions still collapse to one record")
local f = res_fuller.records[1]
eq(f.opds.summary, "The complete edition, with illustrations.",
   "summary comes from the entry with the most acquisitions")
eq(f.filepath, "OPDS://abcd1234/urn:uuid:f1",
   "filepath stays the first entry's, unchanged by the summary rule")
eq(f.opds.thumbnail_url, "http://h/thumb/f1.jpg",
   "first entry's cover kept when both entries have one")
eq(#f.opds.acquisitions, 3, "fuller: acquisitions still concatenate in feed order")

-- ...and a later entry only FILLS a cover the first entry lacks, never replaces
-- one (the cover-borrow philosophy).
local cat_fill_cover = { feed = { entry = { {
    title = "Fill", author = { name = "An Author" }, id = "urn:uuid:g1",
    link = { { rel = "http://opds-spec.org/acquisition", type = "application/epub+zip",
               href = "/dl/g1.epub" } },
}, {
    title = "Fill", author = { name = "An Author" }, id = "urn:uuid:g2",
    link = {
        { rel = "http://opds-spec.org/acquisition", type = "application/epub+zip", href = "/dl/g2.epub" },
        { rel = "http://opds-spec.org/image/thumbnail", type = "image/jpeg", href = "/thumb/g2.jpg" },
        { rel = "http://opds-spec.org/image", type = "image/jpeg", href = "/img/g2.jpg" },
    },
} } } }
local res_fill = Feed.mapEntries(cat_fill_cover, "http://h/opds/all", "abcd1234")
local g = res_fill.records[1]
eq(g.opds.thumbnail_url, "http://h/thumb/g2.jpg", "a later entry fills a nil thumbnail")
eq(g.opds.image_url, "http://h/img/g2.jpg", "a later entry fills a nil image url")
eq(g.filepath, "OPDS://abcd1234/urn:uuid:g1", "filling a cover does not move the filepath")

-- a fuller entry with no summary of its own never blanks the one already held
local cat_no_summary = { feed = { entry = { {
    title = "Keep", author = { name = "An Author" }, id = "urn:uuid:h1",
    content = "The only summary in the feed.",
    link = { { rel = "http://opds-spec.org/acquisition", type = "application/epub+zip",
               href = "/dl/h1.epub" } },
}, {
    title = "Keep", author = { name = "An Author" }, id = "urn:uuid:h2",
    link = {
        { rel = "http://opds-spec.org/acquisition", type = "application/epub+zip", href = "/dl/h2.epub" },
        { rel = "http://opds-spec.org/acquisition", type = "application/x-mobipocket-ebook", href = "/dl/h2.mobi" },
    },
} } } }
local res_no_summary = Feed.mapEntries(cat_no_summary, "http://h/opds/all", "abcd1234")
eq(res_no_summary.records[1].opds.summary, "The only summary in the feed.",
   "a fuller edition with no summary leaves the existing one alone")

-- ...and the mirror: a first entry with no summary is filled by a later one
local cat_late_summary = { feed = { entry = { {
    title = "Late", author = { name = "An Author" }, id = "urn:uuid:i1",
    link = {
        { rel = "http://opds-spec.org/acquisition", type = "application/epub+zip", href = "/dl/i1.epub" },
        { rel = "http://opds-spec.org/acquisition", type = "application/x-mobipocket-ebook", href = "/dl/i1.mobi" },
    },
}, {
    title = "Late", author = { name = "An Author" }, id = "urn:uuid:i2",
    content = "Described only on the smaller edition.",
    link = { { rel = "http://opds-spec.org/acquisition", type = "application/epub+zip",
               href = "/dl/i2.epub" } },
} } } }
local res_late = Feed.mapEntries(cat_late_summary, "http://h/opds/all", "abcd1234")
eq(res_late.records[1].opds.summary, "Described only on the smaller edition.",
   "a summary-less first entry is filled by a later one even though it has fewer acquisitions")

-- interleaved regression: A's editions are not adjacent in the feed (a
-- distinct work B sits between them). An append-vs-replace bug (e.g.
-- overwriting book_records[idx] instead of appending to the existing
-- record's acquisitions) only shows up with a record in between.
local cat_interleaved = { feed = { entry = { {
    title = "Work A", author = { name = "Author A" }, id = "urn:uuid:a1",
    link = { { rel = "http://opds-spec.org/acquisition", type = "application/epub+zip",
               title = "EPUB (with images)", href = "/dl/a1.epub" } },
}, {
    title = "Work B", author = { name = "Author B" }, id = "urn:uuid:b1",
    link = { { rel = "http://opds-spec.org/acquisition", type = "application/epub+zip",
               title = "EPUB B", href = "/dl/b1.epub" } },
}, {
    title = "Work A", author = { name = "Author A" }, id = "urn:uuid:a2",
    link = { { rel = "http://opds-spec.org/acquisition", type = "application/epub+zip",
               title = "EPUB (no images, older E-readers)", href = "/dl/a2.epub" } },
} } } }
local res_interleaved = Feed.mapEntries(cat_interleaved, "http://h/opds/all", "abcd1234")
eq(#res_interleaved.records, 2, "interleaved: A's two editions collapse, B stays separate")
local ia = res_interleaved.records[1]
eq(ia.filepath, "OPDS://abcd1234/urn:uuid:a1", "interleaved: A stays at its original (first) position")
eq(#ia.opds.acquisitions, 2, "interleaved: A's acquisitions from both editions")
eq(ia.opds.acquisitions[1].title, "EPUB (with images)", "interleaved: A's first-edition acquisition in feed order")
eq(ia.opds.acquisitions[2].title, "EPUB (no images, older E-readers)", "interleaved: A's second-edition acquisition appended in feed order")
local ib = res_interleaved.records[2]
eq(ib.filepath, "OPDS://abcd1234/urn:uuid:b1", "interleaved: B unaffected, in its original position")
eq(#ib.opds.acquisitions, 1, "interleaved: B's acquisitions untouched")

-- differing authors with the same title never merge
local cat_diff_author = { feed = { entry = { {
    title = "Same Title", author = { name = "Author One" }, id = "urn:uuid:d1",
    link = { { rel = "http://opds-spec.org/acquisition", type = "application/epub+zip", href = "/dl/d1.epub" } },
}, {
    title = "Same Title", author = { name = "Author Two" }, id = "urn:uuid:d2",
    link = { { rel = "http://opds-spec.org/acquisition", type = "application/epub+zip", href = "/dl/d2.epub" } },
} } } }
local res_diff_author = Feed.mapEntries(cat_diff_author, "http://h/opds/all", "abcd1234")
eq(#res_diff_author.records, 2, "differing authors, same title -> never merge")

-- a nil author, same title, never merges (too risky)
local cat_nil_author = { feed = { entry = { {
    title = "Same Title", id = "urn:uuid:n1",
    link = { { rel = "http://opds-spec.org/acquisition", type = "application/epub+zip", href = "/dl/n1.epub" } },
}, {
    title = "Same Title", id = "urn:uuid:n2",
    link = { { rel = "http://opds-spec.org/acquisition", type = "application/epub+zip", href = "/dl/n2.epub" } },
} } } }
local res_nil_author = Feed.mapEntries(cat_nil_author, "http://h/opds/all", "abcd1234")
eq(#res_nil_author.records, 2, "nil author, same title -> never merge")

-- nav records are never routed through edition-collapse, even with identical titles
local cat_nav_same_title = { feed = { entry = { {
    title = "Fiction", id = "n1",
    link = { { rel = "subsection", type = "application/atom+xml;profile=opds-catalog",
               href = "/opds/fiction" } },
}, {
    title = "Fiction", id = "n2",
    link = { { rel = "subsection", type = "application/atom+xml;profile=opds-catalog",
               href = "/opds/fiction2" } },
} } } }
local res_nav_same_title = Feed.mapEntries(cat_nav_same_title, "http://h/opds/all", "abcd1234")
eq(#res_nav_same_title.records, 2, "nav records with identical titles are unaffected by edition-collapse")

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

-- mapEntries(): feed-level search link capture + classification.
-- OSD (OpenSearch description) link: rel=search, type=opensearchdescription.
local cat_search_osd = { feed = { link = {
    { rel = "search", type = "application/opensearchdescription+xml",
      href = "/opensearch.xml" },
} } }
local res_search_osd = Feed.mapEntries(cat_search_osd, "http://h/opds/all", "k")
eq(res_search_osd.search.href, "http://h/opensearch.xml", "OSD search link absolutised")
eq(res_search_osd.search.type, "osd", "OSD search link classified as osd")

-- Calibre-style template link: rel contains "search", href carries the
-- {searchTerms} placeholder directly (no separate OSD document to fetch).
local cat_search_tmpl = { feed = { link = {
    { rel = "search", type = "application/atom+xml",
      href = "/search?query={searchTerms}" },
} } }
local res_search_tmpl = Feed.mapEntries(cat_search_tmpl, "http://h/opds/all", "k")
eq(res_search_tmpl.search.href, "http://h/search?query={searchTerms}", "template search link absolutised")
eq(res_search_tmpl.search.type, "template", "template search link classified as template")

-- Both present: OSD wins regardless of feed order (stock precedence).
local cat_search_osd_first = { feed = { link = {
    { rel = "search", type = "application/opensearchdescription+xml", href = "/opensearch.xml" },
    { rel = "search", type = "application/atom+xml", href = "/search?query={searchTerms}" },
} } }
eq(Feed.mapEntries(cat_search_osd_first, "http://h/opds/all", "k").search.type,
    "osd", "OSD wins when it appears first")

local cat_search_tmpl_first = { feed = { link = {
    { rel = "search", type = "application/atom+xml", href = "/search?query={searchTerms}" },
    { rel = "search", type = "application/opensearchdescription+xml", href = "/opensearch.xml" },
} } }
eq(Feed.mapEntries(cat_search_tmpl_first, "http://h/opds/all", "k").search.type,
    "osd", "OSD wins even when the template link appears first in the feed")

-- Neither: no search-shaped link at all -> search stays nil.
local cat_search_none = { feed = { link = {
    { rel = "next", type = "application/atom+xml", href = "/opds/all?page=2" },
} } }
eq(Feed.mapEntries(cat_search_none, "http://h/opds/all", "k").search, nil,
    "no search link -> search nil")
eq(res.search, nil, "unrelated feed-level links (rel=next only) leave search nil")

-- An atom-typed link with rel=search but no {searchTerms} placeholder isn't
-- a usable template -> not classified.
local cat_search_no_placeholder = { feed = { link = {
    { rel = "search", type = "application/atom+xml", href = "/search?query=foo" },
} } }
eq(Feed.mapEntries(cat_search_no_placeholder, "http://h/opds/all", "k").search, nil,
    "atom search link without {searchTerms} isn't classified as template")

-- An OSD-typed link without rel=search isn't a search link either.
local cat_search_wrong_rel = { feed = { link = {
    { rel = "alternate", type = "application/opensearchdescription+xml", href = "/opensearch.xml" },
} } }
eq(Feed.mapEntries(cat_search_wrong_rel, "http://h/opds/all", "k").search, nil,
    "OSD-typed link without rel=search isn't classified")

-- substituteQuery(): percent-encode the query into the {searchTerms}
-- placeholder, byte-wise (koreader#13693: util.urlEncode's %w is
-- locale-dependent and can mishandle multi-byte UTF-8).
eq(Feed.substituteQuery("http://h/search?q={searchTerms}", "hello"),
    "http://h/search?q=hello", "substituteQuery: plain ASCII passes through")
eq(Feed.substituteQuery("http://h/search?q={searchTerms}", "a b"),
    "http://h/search?q=a%20b", "substituteQuery: space percent-encoded")
eq(Feed.substituteQuery("http://h/search?q={searchTerms}", "a&b=c?d"),
    "http://h/search?q=a%26b%3Dc%3Fd", "substituteQuery: reserved chars percent-encoded")
eq(Feed.substituteQuery("{searchTerms}", "a-b_c.d~e"),
    "a-b_c.d~e", "substituteQuery: unreserved chars (A-Za-z0-9_.~-) never encoded")
eq(Feed.substituteQuery("http://h/search?q={searchTerms}", "日本語"),
    "http://h/search?q=%E6%97%A5%E6%9C%AC%E8%AA%9E",
    "substituteQuery: multi-byte UTF-8 query percent-encoded byte-wise")
eq(Feed.substituteQuery("http://h/search?q={searchTerms}&start={startIndex?}&count={count?}", "x"),
    "http://h/search?q=x&start=&count=", "substituteQuery: optional OSD params stripped to empty")

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

    -- parseOsd(): a Gutenberg-shaped OpenSearch description with several Url
    -- types (html, atom, a bare OSD self-reference) - the atom one is picked
    -- regardless of position, and the placeholder is left intact for
    -- substituteQuery to fill in later.
    local osd_xml = [[<?xml version="1.0" encoding="UTF-8"?>
<OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
  <ShortName>Search Gutenberg</ShortName>
  <Description>Search Project Gutenberg</Description>
  <Url type="text/html" template="http://m.gutenberg.org/ebooks/search/?query={searchTerms}"/>
  <Url type="application/atom+xml" template="http://m.gutenberg.org/ebooks/search.opds/?query={searchTerms}"/>
  <Url type="application/opensearchdescription+xml" template="http://m.gutenberg.org/osd.xml"/>
</OpenSearchDescription>]]
    eq(Feed.parseOsd(osd_xml), "http://m.gutenberg.org/ebooks/search.opds/?query={searchTerms}",
        "parseOsd picks the atom Url template among several Url types")

    local osd_no_atom = [[<?xml version="1.0"?>
<OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
  <Url type="text/html" template="http://h/search?q={searchTerms}"/>
</OpenSearchDescription>]]
    eq(Feed.parseOsd(osd_no_atom), nil, "parseOsd returns nil when no atom Url is present")
else
    if f then f:close() end
    print("note: parse() fixture skipped (no luajit ffi or no KOReader tree)")
end

print(string.format("%d pass, %d fail", pass, fail))
if fail > 0 then os.exit(1) end
