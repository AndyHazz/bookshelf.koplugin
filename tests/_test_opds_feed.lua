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
eq(Feed.absolute("http://example.net", "opds/new.xml"), "http://example.net/opds/new.xml", "relative href, host-only base")
eq(Feed.absolute("http://h:8080", "page2"), "http://h:8080/page2", "relative href, host-only base with port")
eq(Feed.absolute("http://example.net", "/covers/1.jpg"), "http://example.net/covers/1.jpg", "host-root href, host-only base")

-- Accept header (issue #318): a preference LIST, not one type. A bare
-- "application/opds+json" lets an Atom-only server refuse outright - Spring
-- answers 406 "No acceptable representation" (Booklore/Grimmory) and the
-- catalog looks unreachable. OPDS 2.0 stays first so servers offering both
-- keep handing back what they did before.
ok(Feed.ACCEPT_FEED:find("application/opds+json", 1, true) ~= nil, "accepts OPDS 2.0")
ok(Feed.ACCEPT_FEED:find("application/atom+xml", 1, true) ~= nil, "accepts Atom (OPDS 1.x)")
ok(Feed.ACCEPT_FEED:find("*/*", 1, true) ~= nil, "accepts anything as a last resort")
ok(Feed.ACCEPT_FEED:find("application/opds+json", 1, true)
   < Feed.ACCEPT_FEED:find("application/atom+xml", 1, true),
   "OPDS 2.0 is listed ahead of Atom")
ok(tonumber(Feed.ACCEPT_FEED:match("opds%+json;q=([%d.]+)"))
   > tonumber(Feed.ACCEPT_FEED:match("atom%+xml;q=([%d.]+)")),
   "the q-value weighting matches the listed order")

-- errorForCode: the status -> err mapping callers switch on.
eq(Feed.errorForCode(401), "auth", "401 is an auth failure")
eq(Feed.errorForCode(403), "auth", "403 is an auth failure")
eq(Feed.errorForCode(406), "format", "406 is a content-negotiation failure, not unreachable")
eq(Feed.errorForCode(500, "HTTP/1.1 500 Internal Server Error"),
   "HTTP/1.1 500 Internal Server Error", "anything else reports the status line")
eq(Feed.errorForCode(nil, nil), "network unreachable", "no status at all")

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

-- sameHost(): the nav-visibility gate. Host only, scheme/port ignored, so a
-- catalog served over http can list https nav links to itself (ManyBooks).
ok(Feed.sameHost("http://h/a", "https://h/b") == true, "same host, differing scheme -> true")
ok(Feed.sameHost("http://Host/a", "https://host/b") == true, "differing host case -> true")
ok(Feed.sameHost("http://h:8080/a", "http://h/a") == true, "differing port -> true")
ok(Feed.sameHost("http://h/a", "http://other/a") == false, "cross host -> false")
ok(Feed.sameHost("http://h/a", "/relative/path") == false, "relative input -> false")

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

-- cross-origin nav entries are dropped (Gutenberg's "Follow new books on
-- Facebook/Bluesky/Mastodon": a subsection link to a foreign host).
local cat_xorigin = { feed = { entry = {
    { title = "Follow new books on Facebook",
      link = { { rel = "subsection", type = "application/atom+xml;profile=opds-catalog",
                 href = "https://www.facebook.com/gutenberg.new" } } },
    { title = "Fiction",
      link = { { rel = "subsection", type = "application/atom+xml;profile=opds-catalog",
                 href = "/opds/fiction" } } },
} } }
local res_xorigin = Feed.mapEntries(cat_xorigin, "http://h/opds/all", "abcd1234")
eq(#res_xorigin.records, 1, "cross-origin nav dropped, same-origin nav kept")
eq(res_xorigin.records[1].label, "Fiction", "the surviving nav is the same-origin one")

-- ManyBooks: the stock catalog URL is http://manybooks.net/opds/index.php but
-- every nav href is an absolute https://manybooks.net/... . These are the SAME
-- host, so all four nav tiles must survive; the scheme mismatch alone must not
-- drop them (that produced "No books found").
local cat_scheme = { feed = { entry = {
    { title = "New Titles",
      link = { { type = "application/atom+xml", href = "https://h/opds/new_titles" } } },
    { title = "Titles",
      link = { { type = "application/atom+xml", href = "https://h/opds/titles" } } },
} } }
local res_scheme = Feed.mapEntries(cat_scheme, "http://h/opds/index.php", "abcd1234")
eq(#res_scheme.records, 2, "https nav from an http feed on the same host is kept")

-- a nav tile carries the author from its plain-text content (Gutenberg puts
-- it there), so the placeholder can show it without fetching the child feed;
-- a markup-y / long content (a real summary) is not mistaken for an author.
local function navWithContent(content)
    return { feed = { entry = { {
        title = "Some Book (French)",
        content = content,
        link = { { rel = "subsection", type = "application/atom+xml;profile=opds-catalog",
                   href = "/opds/book" } },
    } } } }
end
eq(Feed.mapEntries(navWithContent("Jean-Henri Fabre"), "http://h/opds/all", "k")
       .records[1].author, "Jean-Henri Fabre", "nav author from plain content")
eq(Feed.mapEntries(navWithContent("<div><p>Summary:\nLong blurb</p></div>"), "http://h/opds/all", "k")
       .records[1].author, nil, "markup content is not an author")
eq(Feed.mapEntries(navWithContent(""), "http://h/opds/all", "k")
       .records[1].author, nil, "empty content -> no author")

-- tiny inline data: thumbnails (Gutenberg's per-tile placeholder glyph) are
-- dropped so the tile shows a clean placeholder; large inline covers and http
-- links are kept.
local TINY = "data:image/png;base64," .. string.rep("A", 100)
local BIG  = "data:image/png;base64," .. string.rep("A", 5000)
local function navWithThumb(href)
    return { feed = { entry = { {
        title = "Cat",
        link = {
            { rel = "subsection", type = "application/atom+xml;profile=opds-catalog",
              href = "/opds/cat" },
            { rel = "http://opds-spec.org/image/thumbnail", type = "image/png", href = href },
        },
    } } } }
end
eq(Feed.mapEntries(navWithThumb(TINY), "http://h/opds/all", "k").records[1].opds.thumbnail_url,
   nil, "tiny inline data: thumbnail dropped")
eq(Feed.mapEntries(navWithThumb(BIG), "http://h/opds/all", "k").records[1].opds.thumbnail_url,
   BIG, "large inline data: thumbnail kept")
eq(Feed.mapEntries(navWithThumb("http://h/thumb.png"), "http://h/opds/all", "k")
       .records[1].opds.thumbnail_url,
   "http://h/thumb.png", "http thumbnail kept")

-- summaryText(): Gutenberg XHTML content -> just the Summary paragraph;
-- anything else untouched.
eq(Feed.summaryText("<div><p>This edition has images.</p><p>\nTitle:\nFoo\n</p>"
        .. "<p>\nSummary:\nThe real blurb here.\n</p><p>\nReading Level:\nx\n</p></div>"),
   "The real blurb here.", "summaryText extracts the Summary paragraph")
eq(Feed.summaryText("A plain description with no headings."),
   "A plain description with no headings.", "summaryText passes plain text through")
eq(Feed.summaryText(nil), nil, "summaryText tolerates nil")

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
-- A literal "%" in the query must itself be percent-encoded, not read back
-- as a gsub capture reference -- pins the function-replacement choice in
-- the substitution chain (a later "simplification" to string replacements
-- would silently break this).
eq(Feed.substituteQuery("http://h/s?q={searchTerms}", "100% pure"),
    "http://h/s?q=100%25%20pure", "substituteQuery: literal % percent-encoded, not a capture ref")
eq(Feed.substituteQuery("{searchTerms}", "a-b_c.d~e"),
    "a-b_c.d~e", "substituteQuery: unreserved chars (A-Za-z0-9_.~-) never encoded")
eq(Feed.substituteQuery("http://h/search?q={searchTerms}", "日本語"),
    "http://h/search?q=%E6%97%A5%E6%9C%AC%E8%AA%9E",
    "substituteQuery: multi-byte UTF-8 query percent-encoded byte-wise")
eq(Feed.substituteQuery("http://h/search?q={searchTerms}&start={startIndex?}&count={count?}", "x"),
    "http://h/search?q=x&start=&count=", "substituteQuery: optional OSD params stripped to empty")

-- substituteQuery(): OPDS 2.0's RFC 6570 form-style query template
-- ("{?query}"), as returned by real catalogs (archive.org's search link is
-- "…/catalog{?query}&type=search"). Distinct placeholder syntax from
-- OpenSearch's "{searchTerms}", handled alongside it rather than translated.
eq(Feed.substituteQuery("http://h/opds/catalog{?query}&type=search", "foo"),
    "http://h/opds/catalog?query=foo&type=search",
    "substituteQuery: RFC6570 {?query} form-style template")
eq(Feed.substituteQuery("http://h/opds/catalog{?query}&type=search", "a b"),
    "http://h/opds/catalog?query=a%20b&type=search",
    "substituteQuery: RFC6570 {?query} template still percent-encodes")

-- multi-variable form-style ("{?query,page}") -- the query goes to the
-- first-named variable, the rest of the list is dropped (only one value).
eq(Feed.substituteQuery("http://h/opds/catalog{?query,page}", "foo"),
    "http://h/opds/catalog?query=foo", "substituteQuery: multi-var {?query,page} keeps only the first name")

-- continuation form ("{&name}") -- used when the template already carries a
-- fixed query parameter ahead of the variable one.
eq(Feed.substituteQuery("http://h/opds/catalog?type=search{&query}", "foo"),
    "http://h/opds/catalog?type=search&query=foo", "substituteQuery: {&query} continuation form")
eq(Feed.substituteQuery("http://h/opds/catalog?type=search{&query,page}", "foo"),
    "http://h/opds/catalog?type=search&query=foo",
    "substituteQuery: multi-var {&query,page} continuation keeps only the first name")

-- catch-all: a template operator/shape none of the above patterns recognise
-- is dropped whole rather than left in the URL as literal braces.
eq(Feed.substituteQuery("http://h/opds/catalog{#frag}", "foo"),
    "http://h/opds/catalog", "substituteQuery: unrecognised template syntax is stripped, not left as literal braces")

-- ============================================================
-- OPDS 2.0 (JSON) catalogs: mapEntries() on an is_opds2-marked table,
-- shaped like a trimmed archive.org response (fetched once against the
-- real service to ground the shape; no network in this test -- the fixture
-- is a plain Lua table, same as the 1.x fixtures above).
-- ============================================================
local catalog2 = {
    is_opds2 = true,
    metadata = { title = "eBooks", numberOfItems = 3 },
    links = {
        { href = "/opds/catalog?page=2", type = "application/opds+json", rel = "next" },
        { href = "/opds/catalog{?query}&type=search", type = "application/opds+json",
          rel = "search", templated = true },
    },
    navigation = {
        { href = "/opds/fiction", title = "Fiction", type = "application/opds+json", rel = "collection" },
    },
    publications = {
        {   -- a book: two images (pick largest/smallest), one acquisition
            metadata = {
                title = "A Book", identifier = "https://archive.org/details/abook",
                author = { { name = "An Author" } },
                description = "A summary.",
            },
            links = {
                { href = "/services/opds/book/abook?fmt=pdf", type = "application/pdf",
                  rel = "http://opds-spec.org/acquisition/open-access" },
            },
            images = {
                { href = "/download/abook/thumb.jpg", type = "image/jpeg", width = 400, height = 700 },
                { href = "/download/abook/full.jpg", type = "image/jpeg", width = 800, height = 1400 },
            },
        },
        {   -- borrow-only: no supported acquisition -> dropped
            metadata = { title = "Library Book", identifier = "urn:x", author = "An Author" },
            links = {
                { href = "/borrow/9", type = "application/epub+zip",
                  rel = "http://opds-spec.org/acquisition/borrow" },
            },
        },
    },
}
local res20 = Feed.mapEntries(catalog2, "http://h/opds/all", "abcd1234")
eq(res20.total, 3, "2.0: metadata.numberOfItems -> total")
eq(res20.next_url, "http://h/opds/catalog?page=2", "2.0: rel=next link absolutised")
eq(res20.search.href, "http://h/opds/catalog{?query}&type=search", "2.0: templated search link absolutised")
eq(res20.search.type, "template", "2.0: search link classified as template")
eq(#res20.records, 2, "2.0: one nav record + one book record (borrow-only dropped)")

local n2 = res20.records[1]
eq(n2.kind, "opds_nav", "2.0: nav record kind")
eq(n2.title, "Fiction", "2.0: nav title from navigation[].title")
eq(n2.display_title, "Fiction", "2.0: nav display_title")
ok(n2.filepath:match("^OPDS://abcd1234/nav/") ~= nil, "2.0: nav filepath namespaced under server")
eq(n2.status, "unread", "2.0: nav status unread")

local b2 = res20.records[2]
ok(b2.is_remote == true, "2.0: book is_remote")
eq(b2.filepath, "OPDS://abcd1234/https://archive.org/details/abook",
    "2.0: virtual filepath from metadata.identifier")
eq(b2.title, "A Book", "2.0: title from metadata.title")
eq(b2.display_title, "A Book", "2.0: display_title from metadata.title")
eq(b2.author, "An Author", "2.0: author from metadata.author (array of {name=...})")
eq(b2.authors[1], "An Author", "2.0: authors array carries the same string")
eq(b2.status, "unread", "2.0: status unread")
eq(b2.read_status, "unread", "2.0: read_status unread")
eq(#b2.opds.acquisitions, 1, "2.0: one supported acquisition")
eq(b2.opds.acquisitions[1].href, "http://h/services/opds/book/abook?fmt=pdf",
    "2.0: acquisition href absolutised")
eq(b2.opds.image_url, "http://h/download/abook/full.jpg", "2.0: largest image (by area) -> image_url")
eq(b2.opds.thumbnail_url, "http://h/download/abook/thumb.jpg", "2.0: smallest image (by area) -> thumbnail_url")
eq(b2.opds.summary, "A summary.", "2.0: summary from metadata.description")
eq(b2.opds.feed_url, "http://h/opds/all", "2.0: feed_url carried")

-- SKIP_ACQ_REL (fix wave): a sample/preview acquisition is not the work,
-- and bookshelf's downloaded tick is a persistent claim nothing but a file
-- deletion clears -- so it must be dropped even when a real acquisition
-- sits right alongside it (archive.org attaches a text/html sample to
-- every publication, T5 leg 2), and it must not be the thing that keeps an
-- otherwise-unacquirable publication in the feed.

-- (a) a real PDF acquisition plus a sample HTML acquisition on the SAME
-- publication -> the sample is dropped, exactly one acquisition remains.
local cat2_sample_plus_real = { is_opds2 = true, publications = { {
    metadata = { title = "Sampled Book", identifier = "id-splus", author = "An Author" },
    links = {
        { href = "/dl/full.pdf", type = "application/pdf",
          rel = "http://opds-spec.org/acquisition/open-access" },
        { href = "/dl/sample.html", type = "text/html",
          rel = "http://opds-spec.org/acquisition/sample" },
    },
} } }
local res2_sample_plus_real = Feed.mapEntries(cat2_sample_plus_real, "http://h/f", "k")
eq(#res2_sample_plus_real.records[1].opds.acquisitions, 1,
    "sample acquisition alongside a real one is dropped -> exactly one acquisition")
eq(res2_sample_plus_real.records[1].opds.acquisitions[1].href, "http://h/dl/full.pdf",
    "the surviving acquisition is the real PDF, not the sample")

-- (b) sample-only publication: no supported acquisition remains, same as a
-- borrow-only one -> dropped entirely.
local cat2_sample_only = { is_opds2 = true, publications = { {
    metadata = { title = "Sample Only", identifier = "id-sonly", author = "An Author" },
    links = {
        { href = "/dl/sample.html", type = "text/html",
          rel = "http://opds-spec.org/acquisition/sample" },
    },
} } }
eq(#Feed.mapEntries(cat2_sample_only, "http://h/f", "k").records, 0,
    "sample-only publication is dropped entirely")

-- (c) the Gutenberg guard: a PLAIN acquisition rel (no /sample, /preview or
-- /borrow suffix) at text/html is still kept. Gutenberg's HTML editions use
-- exactly this rel, so SKIP_ACQ_REL must match the exact rel string, not
-- "acquisition + text/html".
local cat_plain_html_acq = { feed = { entry = { {
    title = "Plain Text HTML Book",
    author = { name = "An Author" },
    link = {
        { rel = "http://opds-spec.org/acquisition",
          type = "text/html", href = "/dl/plain.html" },
    },
    id = "urn:uuid:plain-html",
} } } }
local res_plain_html_acq = Feed.mapEntries(cat_plain_html_acq, "http://h/opds/all", "k")
eq(#res_plain_html_acq.records, 1, "plain acquisition-rel text/html publication is kept")
eq(#res_plain_html_acq.records[1].opds.acquisitions, 1,
    "Gutenberg guard: plain .../acquisition at text/html is still a kept acquisition")

-- Readium/OPDS 2.0 allows a link's "rel" to be a single string OR an array
-- of strings; an unnormalised array-valued rel calling :match/:find on a
-- table used to throw here (before Trapper:clear ran at the widget call
-- site), so this pins array-rel at both the per-entry and feed-level sites.
local cat2_array_rel = {
    is_opds2 = true,
    links = {
        { href = "/opds/catalog?page=2", type = "application/opds+json", rel = { "next" } },
    },
    publications = { {
        metadata = { title = "Array Rel", identifier = "id-ar", author = "An Author" },
        links = {
            { href = "/dl/ar.epub", type = "application/epub+zip",
              rel = { "http://opds-spec.org/acquisition/open-access" } },
        },
    } },
}
local res_array_rel = Feed.mapEntries(cat2_array_rel, "http://h/opds/all", "k")
eq(res_array_rel.next_url, "http://h/opds/catalog?page=2",
    "2.0: array-valued rel on a feed-level link still classifies as next (no throw)")
eq(#res_array_rel.records, 1, "2.0: array-valued rel publication still yields a record (no throw)")
eq(#res_array_rel.records[1].opds.acquisitions, 1,
    "2.0: array-valued rel on an acquisition link still classifies correctly")
eq(res_array_rel.records[1].opds.acquisitions[1].href, "http://h/dl/ar.epub",
    "2.0: array-valued rel acquisition href absolutised")

-- images[] with no width/height anywhere: falls back to the first image for
-- both image_url and thumbnail_url (matches the stock plugin's fallback).
local cat2_no_dims = { is_opds2 = true, publications = { {
    metadata = { title = "No Dims", identifier = "id-nd", author = "An Author" },
    links = { { href = "/dl", type = "application/epub+zip",
                rel = "http://opds-spec.org/acquisition/open-access" } },
    images = {
        { href = "/img/only1.jpg", type = "image/jpeg" },
        { href = "/img/only2.jpg", type = "image/jpeg" },
    },
} } }
local res2_no_dims = Feed.mapEntries(cat2_no_dims, "http://h/f", "k")
eq(res2_no_dims.records[1].opds.image_url, "http://h/img/only1.jpg",
    "2.0: no dimensions anywhere -> image_url falls back to first image")
eq(res2_no_dims.records[1].opds.thumbnail_url, "http://h/img/only1.jpg",
    "2.0: no dimensions anywhere -> thumbnail_url falls back to first image")

-- author variants: string | {name=...} | array of strings | array of {name=...}
local function pub2(author)
    return {
        metadata = { title = "T", identifier = "id1", author = author },
        links = { { href = "/dl", type = "application/epub+zip",
                    rel = "http://opds-spec.org/acquisition/open-access" } },
    }
end
eq(Feed.mapEntries({ is_opds2 = true, publications = { pub2("Plain Author") } }, "http://h/f", "k")
    .records[1].author, "Plain Author", "2.0 author: bare string")
eq(Feed.mapEntries({ is_opds2 = true, publications = { pub2({ name = "Obj Author" }) } }, "http://h/f", "k")
    .records[1].author, "Obj Author", "2.0 author: single {name=...} object")
eq(Feed.mapEntries({ is_opds2 = true, publications = { pub2({ "A", "B" }) } }, "http://h/f", "k")
    .records[1].author, "A, B", "2.0 author: array of bare strings")
eq(Feed.mapEntries({ is_opds2 = true, publications = { pub2({ { name = "A" }, { name = "B" } }) } },
    "http://h/f", "k").records[1].author, "A, B", "2.0 author: array of {name=...} objects")

-- nav entry without a title is dropped (mirrors the 1.x behaviour)
local res2_nav_no_title = Feed.mapEntries({ is_opds2 = true,
    navigation = { { href = "/opds/x", type = "application/opds+json" } } }, "http://h/f", "k")
eq(#res2_nav_no_title.records, 0, "2.0: nav entry without a title is dropped")

-- edition collapse applies to 2.0 records too: same title+author, different
-- acquisitions, merge into one record with concatenated acquisitions.
local cat2_edition = { is_opds2 = true, publications = {
    { metadata = { title = "Same Title", identifier = "id-e1", author = { name = "Same Author" } },
      links = { { href = "/dl/e1.epub", type = "application/epub+zip",
                  rel = "http://opds-spec.org/acquisition/open-access", title = "EPUB e1" } } },
    { metadata = { title = "Same Title", identifier = "id-e2", author = { name = "Same Author" } },
      links = { { href = "/dl/e2.epub", type = "application/epub+zip",
                  rel = "http://opds-spec.org/acquisition/open-access", title = "EPUB e2" } } },
} }
local res2_edition = Feed.mapEntries(cat2_edition, "http://h/f", "k")
eq(#res2_edition.records, 1, "2.0: same title+author editions collapse to one record")
eq(res2_edition.records[1].filepath, "OPDS://k/id-e1", "2.0: merged record keeps first entry's identifier")
eq(#res2_edition.records[1].opds.acquisitions, 2, "2.0: acquisitions concatenate across merged editions")

-- a rel=search link that isn't marked templated is not a usable query
-- template -> not classified (stays nil, no guessing at the href shape).
local cat2_search_untemplated = { is_opds2 = true, links = {
    { href = "/opds/catalog?type=search", type = "application/opds+json", rel = "search" },
} }
eq(Feed.mapEntries(cat2_search_untemplated, "http://h/f", "k").search, nil,
    "2.0: rel=search link without templated=true isn't classified")

-- fetch(): Accept header prefers OPDS 2.0, alongside the existing identity
-- Accept-Encoding (stub-visible: socket.http is stubbed, no real network).
local fetch_requests = {}
package.loaded["socket.http"] = {
    request = function(reqt)
        fetch_requests[#fetch_requests + 1] = { url = reqt.url, headers = reqt.headers }
        if reqt.sink then reqt.sink("body"); reqt.sink(nil) end
        return 1, 200, {}, "OK"
    end,
}
package.loaded["ltn12"] = {
    sink = { table = function(t)
        return function(chunk)
            if chunk then t[#t + 1] = chunk end
            return true
        end
    end },
}
package.loaded["socket"] = { skip = function(d, ...) return select(d + 1, ...) end }
package.loaded["socketutil"] = {
    LARGE_BLOCK_TIMEOUT = 10, LARGE_TOTAL_TIMEOUT = 30,
    set_timeout = function() end, reset_timeout = function() end,
}
local fetch_body = Feed.fetch("http://h/opds/all")
eq(fetch_body, "body", "fetch(): stubbed 200 response body returned")
eq(fetch_requests[1].headers["Accept"], Feed.ACCEPT_FEED,
   "fetch(): sends the Accept preference list (2.0 first, Atom + */* accepted)")
eq(fetch_requests[1].headers["Accept-Encoding"], "identity", "fetch(): Accept-Encoding stays identity")

-- facets become drillable opds_nav TILES at the front of the feed. 2.0:
local cat2_facets = { is_opds2 = true, publications = {},
    facets = {
        { metadata = { title = "Browse by Language" },
          links = { { title = "English", href = "/opds/lang/en" },
                    { title = "French",  href = "/opds/lang/fr" } } },
        { metadata = { title = "Empty" }, links = {} },
    } }
local rf2 = Feed.mapEntries(cat2_facets, "http://h/opds/all", "k").records
eq(#rf2, 2, "2.0 facets -> 2 tiles (empty group contributes none)")
eq(rf2[1].kind, "opds_nav", "facet tile is an opds_nav tile")
ok(rf2[1].is_facet == true, "facet tile flagged is_facet")
eq(rf2[1].title, "English", "facet tile title = option")
eq(rf2[1].author, "Language", "facet tile subtitle = group ('Browse by' stripped)")
eq(rf2[1].opds.feed_url, "http://h/opds/lang/en", "facet tile feed_url absolutised")

-- 1.x facet links become tiles too, group from facetGroup.
local cat1_facets = { feed = { entry = {}, link = {
    { rel = "http://opds-spec.org/facet", ["opds:facetGroup"] = "Language",
      title = "English", href = "/f/en" },
    { rel = "http://opds-spec.org/facet", ["opds:facetGroup"] = "Format",
      title = "EPUB", href = "/f/epub" },
} } }
local rf1 = Feed.mapEntries(cat1_facets, "http://h/opds/all", "k").records
eq(#rf1, 2, "1.x facets -> 2 tiles")
eq(rf1[1].title, "English", "1.x facet tile title")
eq(rf1[1].author, "Language", "1.x facet tile group subtitle")
eq(rf1[2].title, "EPUB", "1.x second facet tile")

-- facet tiles precede book records, and no facets -> no tiles.
local cat_mix = { is_opds2 = true,
    facets = { { metadata = { title = "Lang" }, links = { { title = "EN", href = "/en" } } } },
    publications = { pub2("Some Author") } }
local rmix = Feed.mapEntries(cat_mix, "http://h/f", "k").records
ok(rmix[1] and rmix[1].is_facet == true, "facet tile precedes books")
ok(rmix[2] and not rmix[2].is_facet, "book follows the facet tile")
eq(#Feed.mapEntries({ feed = { entry = {} } }, "http://h/f", "k").records, 0,
   "no facets, no entries -> no records")

-- Tiny inline data: URIs (category icons) are kept on NAV records as
-- opds.icon instead of being discarded; books still drop them entirely,
-- and a large data: URI still counts as a real cover.
local tiny_uri = "data:image/png;base64," .. string.rep("A", 100)
local big_uri  = "data:image/png;base64," .. string.rep("A", 5000)
local cat_icons = { feed = { entry = {
    { title = "Popular",
      link = {
        { rel = "http://opds-spec.org/image/thumbnail", type = "image/png",
          href = tiny_uri },
        { rel = "subsection", type = "application/atom+xml;profile=opds-catalog",
          href = "/opds/popular" },
      } },
    { title = "A Book", id = "b1",
      link = {
        { rel = "http://opds-spec.org/acquisition", type = "application/epub+zip",
          href = "/dl/b1.epub" },
        { rel = "http://opds-spec.org/image/thumbnail", type = "image/png",
          href = tiny_uri },
      } },
    { title = "Cover Nav",
      link = {
        { rel = "http://opds-spec.org/image/thumbnail", type = "image/png",
          href = big_uri },
        { rel = "subsection", type = "application/atom+xml;profile=opds-catalog",
          href = "/opds/covered" },
      } },
} } }
local res_icons = Feed.mapEntries(cat_icons, "http://h/opds/root", "abcd1234")
local nav_i, book_i, cov_i
for _i, r in ipairs(res_icons.records) do
    if r.label == "Popular" then nav_i = r
    elseif r.title == "A Book" then book_i = r
    elseif r.label == "Cover Nav" then cov_i = r end
end
ok(nav_i ~= nil, "icon nav record present")
eq(nav_i.opds.icon, tiny_uri, "nav keeps its tiny inline image as opds.icon")
eq(nav_i.opds.thumbnail_url, nil, "tiny inline never becomes a thumbnail url")
ok(book_i ~= nil, "book record present")
eq(book_i.opds.icon, nil, "book records never carry an icon")
eq(book_i.opds.thumbnail_url, nil, "book still drops the tiny inline")
ok(cov_i ~= nil, "covered nav record present")
eq(cov_i.opds.icon, nil, "big data uri is a cover, not an icon")
eq(cov_i.opds.thumbnail_url, big_uri, "big data uri kept as the thumbnail")

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

    -- parse(): OPDS 2.0 -- leading-whitespace-tolerant "{" detection routes
    -- to KOReader's own json module (lpeg-backed, so it needs the same
    -- KOReader tree as the XML fixture above, not just luajit's ffi).
    package.path = koreader_dir .. "/common/?.lua;" .. koreader_dir .. "/common/?/init.lua;" .. package.path
    package.cpath = koreader_dir .. "/common/?.so;" .. package.cpath
    local have_json = pcall(require, "json")
    if have_json then
        local json_text = '  \n {"metadata":{"title":"T"},"publications":[]}'
        local cat_json = Feed.parse(json_text)
        ok(type(cat_json) == "table" and cat_json.is_opds2 == true,
            "parse(): leading-whitespace-tolerant '{' detection marks is_opds2")
        eq(cat_json.metadata.title, "T", "parse(): JSON body decoded through")
    else
        print("note: OPDS 2.0 parse() fixture skipped (no KOReader json/lpeg module)")
    end
else
    if f then f:close() end
    print("note: parse() fixture skipped (no luajit ffi or no KOReader tree)")
end

print(string.format("%d pass, %d fail", pass, fail))
if fail > 0 then os.exit(1) end
