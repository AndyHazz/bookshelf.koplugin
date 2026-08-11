-- lib/bookshelf_opds_feed.lua
-- OPDS 1.x (Atom) feed layer for OPDS chips: fetch, parse, and map feed
-- entries to Bookshelf-shaped records. parse() vendors the normalisation
-- fixes from the stock plugin's opdsparser.lua (luxl is strict about
-- comments, CDATA, self-closing tags and embedded XHTML content) - keep the
-- gsub set in sync with upstream if feeds start failing. Everything network
-- is BLOCKING; callers wrap in Trapper.
--
-- mapEntries(), absolute() and sameOrigin() are pure so the standalone
-- harness covers them; parse() needs luxl (ffi) and is fixture-tested only
-- where a KOReader tree is available.

local M = {}

-- Minimal RFC3986-ish resolution covering the href shapes OPDS feeds use.
-- Not a general resolver: no dot-segment handling ("../"), which real feeds
-- do not emit (the stock plugin survives on socket.url the same way).
function M.absolute(base, href)
    if type(href) ~= "string" or href == "" then return nil end
    if href:match("^%a[%w+.-]*:") then return href end          -- has scheme
    local scheme, authority_rest = base:match("^(%a[%w+.-]*):(.*)$")
    if not scheme then return href end
    if href:sub(1, 2) == "//" then return scheme .. ":" .. href end -- scheme-relative
    local authority_root = base:match("^(%a[%w+.-]*://[^/]+)")
    local root = authority_root or base
    if href:sub(1, 1) == "/" then return root .. href end        -- host-root
    local dir = base:match("^(.*/)")                              -- relative
    if authority_root and (not dir or #dir <= #authority_root) then
        -- Host-only base ("http://example.net"): the greedy match above
        -- stops at the "//" of the scheme separator, which would rehome the
        -- href's first segment as the host. Resolve against the root instead.
        dir = authority_root .. "/"
    end
    return (dir or (base .. "/")) .. href
end

local DEFAULT_PORT = { http = "80", https = "443" }

-- scheme, lowercased host, and port (explicit, or the scheme default) for a
-- URL with an authority. nil on anything that doesn't parse (no scheme, no
-- authority) so sameOrigin below fails closed on malformed input.
local function originOf(url)
    if type(url) ~= "string" then return nil end
    local scheme, authority = url:match("^(%a[%w+.-]*)://([^/]+)")
    if not scheme then return nil end
    scheme = scheme:lower()
    local host, port = authority:match("^([^:]+):(%d+)$")
    host = host or authority
    if host == "" then return nil end
    return scheme, host:lower(), port or DEFAULT_PORT[scheme]
end

-- Credential gate: true only when scheme, host and port (explicit or
-- default) all match. Feeds are server-controlled XML - a nav link, a
-- rel=next link, or a thumbnail URL could point at a foreign host, and
-- Basic auth must never follow it there. Deliberately not socket.url (keeps
-- this module runnable under the standalone test harness).
function M.sameOrigin(url_a, url_b)
    local scheme_a, host_a, port_a = originOf(url_a)
    local scheme_b, host_b, port_b = originOf(url_b)
    if not scheme_a or not scheme_b then return false end
    return scheme_a == scheme_b and host_a == host_b and port_a == port_b
end

-- Same HOST only, ignoring scheme and port. The nav-visibility filter uses this
-- rather than sameOrigin: a catalog served over http routinely lists https nav
-- links to itself (ManyBooks' stock URL is http://manybooks.net/opds/index.php
-- while its entry hrefs are https://manybooks.net/...) -- that is the SAME
-- catalog, not a foreign host, and sameOrigin's scheme check wrongly dropped
-- every entry as cross-origin ("No books found"). Only a genuinely different
-- host (Gutenberg's facebook.com / bsky.app social links) should be dropped.
-- Credentials still gate on sameOrigin -- scheme matters for auth -- so this is
-- purely "is this tile part of the same catalog we're browsing".
function M.sameHost(url_a, url_b)
    local _sa, host_a = originOf(url_a)
    local _sb, host_b = originOf(url_b)
    if not host_a or not host_b then return false end
    return host_a == host_b
end

local ACQUISITION_REL = "^http://opds%-spec%.org/acquisition"
-- Acquisition rels that match ACQUISITION_REL but must never satisfy "this
-- publication is acquirable": a sample or preview is not the work, and
-- bookshelf's downloaded tick is a persistent claim about the user's
-- library that nothing but a file deletion ever clears -- ticking it for a
-- teaser page (archive.org attaches a text/html sample to every row) would
-- be a false record. Borrow is excluded for the same original reason (no
-- open-access download exists). A plain ".../acquisition" (no suffix) is
-- NOT in this set -- Gutenberg's HTML editions use that exact rel and must
-- stay acquirable.
local SKIP_ACQ_REL = {
    ["http://opds-spec.org/acquisition/borrow"]  = true,
    ["http://opds-spec.org/acquisition/sample"]  = true,
    ["http://opds-spec.org/acquisition/preview"] = true,
}
local CATALOG_TYPE    = "application/atom%+xml"
local OSD_TYPE        = "application/opensearchdescription%+xml"
-- OPDS 2.0's canonical MIME type: fetch()'s Accept-header preference, the
-- synthetic nav-link type in opds2NavigationToEntry below, AND (as the
-- pattern derived from it, so the two can never drift) the per-entry
-- navigation-link type check, checked alongside CATALOG_TYPE wherever a
-- link's type identifies it as "more catalog to fetch".
local OPDS2_TYPE         = "application/opds+json"
local OPDS2_TYPE_PATTERN = OPDS2_TYPE:gsub("%+", "%%+")
local THUMB_REL = {
    ["http://opds-spec.org/image/thumbnail"] = true,
    ["http://opds-spec.org/thumbnail"]       = true,   -- ManyBooks
    ["x-stanza-cover-image-thumbnail"]       = true,
}
local IMAGE_REL = {
    ["http://opds-spec.org/image"] = true,
    ["http://opds-spec.org/cover"] = true,             -- ManyBooks
    ["x-stanza-cover-image"]       = true,
}
local NAV_REL = {
    ["subsection"]                            = true,
    ["http://opds-spec.org/subsection"]       = true,
    ["http://opds-spec.org/crawlable"]        = true,
    ["http://opds-spec.org/sort/popular"]     = true,
    ["http://opds-spec.org/sort/new"]         = true,
}
-- Every MIME type KOReader can open, mapped to the file extension a download
-- should be saved with. Derived from KOReader's own DocumentRegistry
-- (frontend/document/*.lua addProvider calls), so a catalog offering anything
-- the reader handles is offered to the user rather than silently dropped -
-- Booklore serving AZW3 as application/vnd.amazon.ebook and CBZ as the
-- registered application/vnd.comicbook+zip were both dropped before (#318),
-- which renders a shelf of comics or Kindle files as an empty category.
--
-- ONE table, two jobs: the key set is the "can this be acquired" filter here,
-- and bookshelf_opds_download reads the values for its filename extension.
-- They used to be separate hand-maintained tables in the two modules, which
-- is a drift the pairing test could only catch after the fact.
--
-- Deliberately absent: application/octet-stream (Booklore's fallback when it
-- cannot identify a file - "some binary" is not a format, and the URL-suffix
-- guess in filenameFor covers the case where the href still names one) and
-- the image types KOReader registers for its picture viewer (a jpeg in a feed
-- is a cover, not a book).
local TYPE_EXT = {
    -- EPUB / FB2 / FB3
    ["application/epub+zip"]                  = "epub",
    ["application/epub"]                      = "epub",
    ["application/fb2"]                       = "fb2",
    ["application/x-fictionbook+xml"]         = "fb2",
    ["text/fb2+xml"]                          = "fb2",
    ["application/fb2+zip"]                   = "fb2.zip",
    ["application/fb3"]                       = "fb3",
    -- Kindle / Mobipocket / Palm
    ["application/x-mobipocket-ebook"]        = "mobi",
    ["application/vnd.amazon.ebook"]          = "azw3",
    ["application/vnd.amazon.mobi8-ebook"]    = "azw",
    ["application/x-mobi8-ebook"]             = "azw",
    ["application/vnd.palm"]                  = "pdb",
    -- PDF / XPS / DjVu
    ["application/pdf"]                       = "pdf",
    ["application/oxps"]                      = "xps",
    ["application/djvu"]                      = "djvu",
    ["image/vnd.djvu"]                        = "djvu",
    ["image/x-djvu"]                          = "djvu",
    -- Comics
    ["application/vnd.comicbook+zip"]         = "cbz",
    ["application/x-cbz"]                     = "cbz",
    ["application/vnd.comicbook-rar"]         = "cbr",
    ["application/vnd.rar"]                   = "cbr",
    ["application/vnd.comicbook+tar"]         = "cbt",
    -- Office / help formats crengine handles
    ["application/msword"]                    = "doc",
    ["application/vnd.openxmlformats-officedocument.wordprocessingml.document"] = "docx",
    ["application/vnd.oasis.opendocument.text"] = "odt",
    ["application/rtf"]                       = "rtf",
    ["application/rtf+zip"]                   = "rtf.zip",
    ["application/vnd.ms-htmlhelp"]           = "chm",
    -- Plain text / markup
    ["text/plain"]                            = "txt",
    ["text/html"]                             = "html",
    ["application/xhtml+xml"]                 = "xhtml",
    ["application/xml"]                       = "xml",
    ["application/html+zip"]                  = "htmlz",
    ["application/txt+zip"]                   = "txt.zip",
    -- Bare zip: KOReader registers it (fb2.zip / txt.zip / html.zip land here
    -- when a server does not use the more specific type), so a catalog that
    -- only labels its compressed books "application/zip" stays usable.
    ["application/zip"]                       = "zip",
}
M.TYPE_EXT = TYPE_EXT

-- Acquirability filter: the key set of TYPE_EXT. Kept as its own exported
-- table because that is the shape callers (and the pairing test) expect.
local SUPPORTED_TYPE = {}
for mtype in pairs(TYPE_EXT) do SUPPORTED_TYPE[mtype] = true end
M.SUPPORTED_TYPE = SUPPORTED_TYPE

-- OPDS 2.0 (Readium Web Publication Manifest) allows a link's "rel" to be
-- either a single string or an array of strings; the stock plugin
-- normalises this at every read via its own get_value() helper
-- (opdsbrowser.lua). Every raw link.rel read in this file goes through
-- relOf() first so the rel:match/rel:find/rel== comparisons below always
-- see a string or nil, never a table -- an unnormalised array-valued rel
-- throws there (mapEntries has no pcall at its widget call site, so that
-- throw would abort the fetch loop before Trapper:clear runs).
local function relOf(r)
    if type(r) == "table" then return r[1] end
    return r
end

local function entryTitle(entry)
    if type(entry.title) == "string" then return entry.title end
    if type(entry.title) == "table" and type(entry.title.div) == "string"
            and entry.title.div ~= "" then
        return entry.title.div
    end
    return nil
end

local function entryAuthor(entry)
    if type(entry.author) ~= "table" then return nil end
    local name = entry.author.name
    if type(name) == "string" and name ~= "" then return name end
    if type(name) == "table" and #name > 0 then return table.concat(name, ", ") end
    return nil
end

-- ---------------------------------------------------------------------
-- OPDS 2.0 (JSON): publications[]/navigation[] are reshaped into the same
-- entry table the loop in mapEntries below already reads (title/author/
-- content/id/link[]), so the entire acquisition-link, cover-link,
-- edition-collapse and nav-vs-book assembly logic runs UNCHANGED for both
-- feed generations. Only the reshaping below is generation-specific.
-- ---------------------------------------------------------------------

-- OPDS 2.0 metadata.author (Readium's Contributor object): a bare string, a
-- single {name=...} object, or an array mixing either shape. Reduced here to
-- one joined string so the synthetic entry can hand entryAuthor() above a
-- {name = <string>} table and be read back unchanged -- same joining
-- convention as the 1.x <author> array (", "-separated).
local function opds2AuthorName(author)
    if type(author) == "string" and author ~= "" then return author end
    if type(author) ~= "table" then return nil end
    if type(author.name) == "string" and author.name ~= "" then return author.name end
    if #author > 0 then
        local names = {}
        for _i, a in ipairs(author) do
            if type(a) == "string" and a ~= "" then
                names[#names + 1] = a
            elseif type(a) == "table" and type(a.name) == "string" and a.name ~= "" then
                names[#names + 1] = a.name
            end
        end
        if #names > 0 then return table.concat(names, ", ") end
    end
    return nil
end

-- OPDS 2.0 images[]: picks the largest (by width*height, when a candidate
-- carries both) as the cover image and the smallest as the thumbnail.
-- Candidates with no dimensions never win a comparison but are still the
-- fallback when NONE of the images carry dimensions, so an undimensioned
-- single-image array yields the same image for both sides -- the stock
-- plugin's "thumbnail-or-first" behaviour.
local function opds2Images(images)
    if type(images) ~= "table" or #images == 0 then return nil, nil end
    local function area(im)
        if type(im) == "table" and type(im.width) == "number"
                and type(im.height) == "number" then
            return im.width * im.height
        end
        return nil
    end
    local largest, largest_area = images[1], area(images[1])
    local smallest, smallest_area = images[1], area(images[1])
    for i = 2, #images do
        local im, a = images[i], area(images[i])
        if a then
            if not largest_area or a > largest_area then largest, largest_area = im, a end
            if not smallest_area or a < smallest_area then smallest, smallest_area = im, a end
        end
    end
    return largest, smallest
end

-- Canonical image/thumbnail rel strings (see IMAGE_REL/THUMB_REL above,
-- first entry in each) -- reused verbatim as synthetic <link> rels so a 2.0
-- publication's images[] is classified by the SAME per-entry loop that
-- already reads 1.x's <link rel="http://opds-spec.org/image[...]">.
local CANON_IMAGE_REL = "http://opds-spec.org/image"
local CANON_THUMB_REL = "http://opds-spec.org/image/thumbnail"

-- entry.link[] passes pub.links[] through verbatim: 2.0's acquisition rels
-- ("…/acquisition/open-access", "…/acquisition/borrow", …) already match
-- ACQUISITION_REL/SKIP_ACQ_REL, and its link.type/rel/href/title field names
-- are exactly what the per-entry loop reads. images[] has no 1.x
-- equivalent, so it becomes two synthetic links carrying the canonical rels
-- above instead.
local function opds2PublicationToEntry(pub)
    local title, author, summary, id
    if type(pub.metadata) == "table" then
        if type(pub.metadata.title) == "string" then title = pub.metadata.title end
        author = opds2AuthorName(pub.metadata.author)
        if type(pub.metadata.description) == "string" then summary = pub.metadata.description end
        if type(pub.metadata.identifier) == "string" and pub.metadata.identifier ~= "" then
            id = pub.metadata.identifier
        end
    end
    local link = {}
    if type(pub.links) == "table" then
        for _i, l in ipairs(pub.links) do link[#link + 1] = l end
    end
    -- "…or href fallback": an identifier-less publication still gets a
    -- stable id from its own first link rather than falling all the way
    -- through to mapEntries' generic feed_url#idx (positional) fallback.
    if not id and link[1] and type(link[1].href) == "string" then id = link[1].href end
    local largest, smallest = opds2Images(pub.images)
    if largest and type(largest.href) == "string" then
        link[#link + 1] = { rel = CANON_IMAGE_REL, type = largest.type, href = largest.href }
    end
    if smallest and type(smallest.href) == "string" then
        link[#link + 1] = { rel = CANON_THUMB_REL, type = smallest.type, href = smallest.href }
    end
    return {
        title = title,
        author = author and { name = author } or nil,
        content = summary,
        id = id,
        link = link,
    }
end

-- navigation[] items carry only a title and an href (no acquisitions, no
-- images), so the synthetic link just needs a type the per-entry loop's
-- nav_url check recognises (OPDS2_TYPE_PATTERN below).
local function opds2NavigationToEntry(nav)
    local link = {}
    if type(nav) == "table" and type(nav.href) == "string" then
        link[1] = { type = OPDS2_TYPE, href = nav.href }
    end
    return {
        title = (type(nav) == "table" and type(nav.title) == "string") and nav.title or nil,
        link = link,
    }
end

-- catalog: OPDSParser-shaped table. feed_url: the URL it was fetched from
-- (base for relative hrefs). server_key: OpdsSource.serverKey of the server.
-- Returns { records, next_url, total }. Nav entries are folded into records,
-- PRECEDING the page's book records (spec 6.2 nav-first): see nav_records
-- below.
--
-- Edition collapse: book entries sharing an exact (title, author) - both
-- non-nil - merge into one record within this single mapEntries call (one
-- feed page). The first entry wins id/filepath (stable keys: the record's
-- identity, and what the download mapping and the window's dedupe are keyed
-- on); every entry's acquisitions concatenate in feed order, so Gutenberg's
-- separate with-images/no-images entries for one work become one book
-- offering both formats. This is deliberately page-scoped: merging across
-- pages would need the whole feed in memory at once, so cross-page duplicates
-- are left to OpdsWindow's existing filepath dedupe instead (see appendPage).
--
-- Summary comes from the FULLEST edition - the merged entry with the most
-- acquisitions, ties going to the earlier one. Gutenberg lists the stripped
-- edition first, so first-entry-wins made the merged record say "This edition
-- had all images removed" while offering the with-images formats right below
-- it. Only entries that actually carry a summary compete, so a fuller edition
-- with none never blanks the text a smaller one supplied.
--
-- Cover urls stay first-entry-wins, except that a later entry FILLS one the
-- first entry lacks (fill nil, never replace) - the same philosophy as the
-- repo's nav-tile cover borrow: a cover from somewhere is better than a
-- placeholder, and a cover already chosen is never second-guessed.

-- Gutenberg (and lookalikes) pack the real blurb into a "Summary:" section of
-- an XHTML content block that also carries Title / Note / Credits / Reading
-- Level headings -- all of which we do NOT want as the book's description. Keep
-- only the text under the Summary heading (up to the end of its paragraph).
-- Anything without that shape -- a plain OPDS 2.0 description, a Calibre blurb
-- -- has no "Summary:…</p>" to match and is returned verbatim.
function M.summaryText(raw)
    if type(raw) ~= "string" then return raw end
    local s = raw:match("Summary:%s*(.-)%s*</p>")
    if s and s ~= "" then return s end
    return raw
end

-- A data: image URI whose payload is smaller than this is a placeholder glyph,
-- not a cover: Project Gutenberg's list feeds (latest / search / category)
-- attach an identical ~1.3KB "no cover" book icon to every per-book nav tile,
-- which rendered as the same glyph repeated down the page. Dropping it lets the
-- tile fall back to the clean title placeholder card instead. Real inline
-- covers are far larger and kept; http(s) links are never touched (only data:
-- URIs are inspected).
local TINY_INLINE_MAX = 4096  -- base64 chars, ~3KB decoded
local function tinyInlineImage(href)
    if type(href) ~= "string" then return false end
    local payload = href:match("^data:[^,]*,(.*)$")
    return payload ~= nil and #payload < TINY_INLINE_MAX
end

function M.mapEntries(catalog, feed_url, server_key)
    local out = { records = {}, next_url = nil, total = nil }
    local feed = catalog and (catalog.feed or catalog)
    if type(feed) ~= "table" then return out end
    local is_opds2 = feed.is_opds2 == true

    if is_opds2 then
        out.total = tonumber(feed.metadata and feed.metadata.numberOfItems)
    else
        out.total = tonumber(feed["opensearch:totalResults"])
    end

    -- Search link classification (stock precedence: OSD beats a Calibre
    -- template regardless of which appears first in the feed). Only the
    -- link is captured here - resolving an OSD document into its template
    -- is parseOsd's job, kept separate because it needs a second fetch.
    -- OPDS 2.0 catalogs signal a search link with rel=search and
    -- templated=true on a JSON links[] entry rather than the 1.x pairing of
    -- a distinct type and a "{searchTerms}" placeholder in the href (2.0's
    -- href commonly reads "{?query}" instead, an RFC 6570 form-style query
    -- expansion - substituteQuery below fills in either placeholder style).
    -- There is no 2.0 equivalent of the OSD indirection, so rel+templated is
    -- the only signal available; is_opds2 gates it so a 1.x feed can never
    -- take this branch by an accidental field match.
    local search_osd, search_template
    local top_links = is_opds2 and (feed.links or {}) or (feed.link or {})
    for _i, link in ipairs(top_links) do
        if relOf(link.rel) == "next" and link.href then
            out.next_url = M.absolute(feed_url, link.href)
        end
        local rel, ltype, href = relOf(link.rel), link.type, link.href
        if rel and href then
            if not search_osd and rel == "search" and ltype and ltype:find(OSD_TYPE) then
                search_osd = { href = M.absolute(feed_url, href), type = "osd" }
            elseif not search_template and is_opds2 and rel == "search" and link.templated == true then
                search_template = { href = M.absolute(feed_url, href), type = "template" }
            elseif not search_template and rel:find("search", 1, true) and ltype
                    and ltype:find(CATALOG_TYPE) and href:find("{searchTerms}", 1, true) then
                search_template = { href = M.absolute(feed_url, href), type = "template" }
            end
        end
    end
    out.search = search_osd or search_template

    -- Facets as drillable folder tiles. A feed advertises server-side filters
    -- over ITSELF -- OPDS 2.0 in feed.facets ([{metadata.title, links[]}]),
    -- 1.x as feed-level <link rel=...facet opds:facetGroup=<group> title=<opt>
    -- href=...>. Each option becomes an opds_nav tile (the option titled, its
    -- group as the subtitle) shown FIRST on the feed so the user narrows down
    -- before wading into the books -- how Internet Archive's 10000-item
    -- unsorted lists become browsable, by Language / Category. Tapping a tile
    -- drills into the filtered feed with NO special handling (an ordinary
    -- opds_nav frame), and that feed re-exposes its own remaining facets as
    -- tiles, so filters compose (English -> its Categories) for free.
    local OpdsSource = require("lib/bookshelf_opds_source")
    local facet_tiles = {}
    local function addFacet(group_title, opt_title, opt_href)
        if type(opt_href) ~= "string" or type(opt_title) ~= "string"
                or opt_title == "" then return end
        local href = M.absolute(feed_url, opt_href)
        local group = type(group_title) == "string"
            and (group_title:gsub("^[Bb]rowse by%s+", "")) or nil
        if group == "" then group = nil end
        facet_tiles[#facet_tiles + 1] = {
            kind          = "opds_nav",
            is_remote     = true,
            is_opds_nav   = true,
            is_facet      = true,
            filepath      = "OPDS://" .. server_key .. "/nav/" .. OpdsSource.serverKey(href),
            label         = opt_title,
            title         = opt_title,
            display_title = opt_title,
            author        = group,
            authors       = group and { group } or nil,
            status        = "unread",
            read_status   = "unread",
            opds          = { feed_url = href },
        }
    end
    if is_opds2 then
        for _i, g in ipairs(feed.facets or {}) do
            local gt = g.metadata and g.metadata.title
            for _j, l in ipairs(g.links or {}) do addFacet(gt, l.title, l.href) end
        end
    else
        for _i, link in ipairs(top_links) do
            local rel = relOf(link.rel)
            if rel and rel:find("facet", 1, true) then
                addFacet(link["opds:facetGroup"] or link.facetGroup or "Filter",
                    (type(link.title) == "string" and link.title) or link.href, link.href)
            end
        end
    end

    -- Nav entries collect separately so they can precede book entries
    -- regardless of feed order.
    local nav_records, book_records = {}, {}
    -- Keyed on "title\0author" (both non-nil) so a later entry sharing that
    -- key can find the record it merges into; see the edition-collapse note
    -- above.
    local book_by_key = {}
    -- Per merged record, the acquisition count of the entry whose summary it is
    -- currently showing. Only entries that HAD a summary are recorded here, so
    -- a fuller edition with none neither wins nor blocks a later one; absent
    -- (nil) reads as "no summary yet", which any entry beats.
    local summary_acq_n = {}
    -- OPDS 2.0: publications[]/navigation[] are reshaped into the same
    -- entry table the loop below reads, so everything from here down -
    -- acquisition/cover-link classification, edition collapse, nav-vs-book
    -- assembly, ordering - runs unchanged for both feed generations.
    local entry_list
    if is_opds2 then
        entry_list = {}
        for _i, nav in ipairs(feed.navigation or {}) do
            entry_list[#entry_list + 1] = opds2NavigationToEntry(nav)
        end
        for _i, pub in ipairs(feed.publications or {}) do
            entry_list[#entry_list + 1] = opds2PublicationToEntry(pub)
        end
    else
        entry_list = feed.entry or {}
    end
    for idx, entry in ipairs(entry_list) do
        local title = entryTitle(entry)
        local acquisitions, thumb, image, nav_url, tiny_icon = {}, nil, nil, nil, nil
        for _j, link in ipairs(entry.link or {}) do
            local rel, ltype, href = relOf(link.rel), link.type, link.href
            if href then
                if rel and not SKIP_ACQ_REL[rel] and rel:match(ACQUISITION_REL)
                        and SUPPORTED_TYPE[ltype] then
                    acquisitions[#acquisitions + 1] = {
                        type = ltype, href = M.absolute(feed_url, href),
                        title = type(link.title) == "string" and link.title or nil,
                    }
                elseif rel and THUMB_REL[rel] then
                    if not tinyInlineImage(href) then thumb = M.absolute(feed_url, href)
                    else tiny_icon = tiny_icon or href end
                elseif rel and IMAGE_REL[rel] then
                    if not tinyInlineImage(href) then image = M.absolute(feed_url, href)
                    else tiny_icon = tiny_icon or href end
                elseif ltype and (ltype:find(CATALOG_TYPE) or ltype:find(OPDS2_TYPE_PATTERN))
                        and (not rel or NAV_REL[rel]) then
                    nav_url = M.absolute(feed_url, href)
                end
            end
        end

        if #acquisitions > 0 then
            local author = entryAuthor(entry)
            local merge_key = (title and author) and (title .. "\0" .. author) or nil
            local existing = merge_key and book_by_key[merge_key]
            local summary = M.summaryText(entry.content or entry.summary)
            if type(summary) ~= "string" then summary = nil end
            if existing then
                local acq = existing.opds.acquisitions
                for _k, a in ipairs(acquisitions) do acq[#acq + 1] = a end
                -- Fullest edition wins the summary; strict > keeps the earlier
                -- entry on a tie. Compared against the count of the entry that
                -- SUPPLIED the current summary, not the running total.
                if summary and #acquisitions > (summary_acq_n[existing] or -1) then
                    existing.opds.summary = summary
                    summary_acq_n[existing] = #acquisitions
                end
                -- Cover: fill a nil, never replace what the first entry had.
                if not existing.opds.thumbnail_url and thumb then
                    existing.opds.thumbnail_url = thumb
                end
                if not existing.opds.image_url and image then
                    existing.opds.image_url = image
                end
            else
                local id = (type(entry.id) == "string" and entry.id ~= "" and entry.id)
                    or (feed_url .. "#" .. idx)
                local rec = {
                    is_remote     = true,
                    filepath      = "OPDS://" .. server_key .. "/" .. id,
                    filename      = title or id,
                    title         = title or "Unknown",
                    display_title = title or "Unknown",
                    author        = author,
                    authors       = author and { author } or nil,
                    status        = "unread",
                    read_status   = "unread",
                    added_time    = 0,
                    attr          = { mode = "file", size = 0, modification = 0 },
                    opds = {
                        acquisitions  = acquisitions,
                        thumbnail_url = thumb,
                        image_url     = image,
                        summary       = summary,
                        feed_url      = feed_url,
                    },
                }
                book_records[#book_records + 1] = rec
                if merge_key then
                    book_by_key[merge_key] = rec
                    -- Left nil when this entry had no summary, so the first
                    -- later edition that does carry one fills it.
                    if summary then summary_acq_n[rec] = #acquisitions end
                end
            end
        elseif nav_url and title and M.sameHost(feed_url, nav_url) then
            -- Cross-HOST "subsection" links are not browsable catalog nodes:
            -- Gutenberg's Latest feed opens with "Follow new books on Facebook
            -- / Bluesky / Mastodon" entries carrying an opds-catalog subsection
            -- link to the social host. A real subcatalog stays on the
            -- catalog's own origin (and only there can we send credentials), so
            -- a nav whose target leaves that origin is dropped rather than
            -- shown as a dead folder tile.
            -- Gutenberg's per-book nav tiles carry the author as the entry's
            -- plain-text content ("Jean-Henri Fabre"), so surface it on the
            -- placeholder -- the tile is then identifiable (title + author)
            -- with no child-feed fetch; the cover and full description are
            -- fetched only when the book is tapped. Guarded to a short,
            -- markup-free string so a rich XHTML content block (a real book
            -- entry's summary) is never mistaken for an author line.
            local nav_author = entry.content
            if type(nav_author) ~= "string" or nav_author == ""
                    or nav_author:find("<") or #nav_author > 80 then
                nav_author = nil
            end
            nav_records[#nav_records + 1] = {
                kind          = "opds_nav",
                is_remote     = true,
                is_opds_nav   = true,
                filepath      = "OPDS://" .. server_key .. "/nav/" .. OpdsSource.serverKey(nav_url),
                label         = title,
                title         = title,
                display_title = title,
                author        = nav_author,
                authors       = nav_author and { nav_author } or nil,
                status        = "unread",
                read_status   = "unread",
                -- thumbnail_url / image_url: some catalogues put a cover link
                -- directly on the nav entry itself (a category tile with its
                -- own artwork), not just on book entries. Carrying them here
                -- lets OpdsCovers.coverUrl/cachePath (which already reads
                -- rec.opds.image_url or .thumbnail_url) and the repo's
                -- existing per-slice cover-attach loop pick them up with no
                -- further change -- a nav record is a page record like any
                -- other.
                -- icon: a tiny inline data: image (a category glyph like
                -- Gutenberg's hearts/stars) is useless as a cover but ideal
                -- for the placeholder card's divider motif. Kept on NAV
                -- records only; books drop tiny inlines entirely.
                opds = { feed_url = nav_url, thumbnail_url = thumb,
                         image_url = image, icon = tiny_icon },
            }
        end
    end
    -- Facet tiles first (filters), then nav folders, then books.
    for _i, r in ipairs(facet_tiles) do out.records[#out.records + 1] = r end
    for _i, r in ipairs(nav_records) do out.records[#out.records + 1] = r end
    for _i, r in ipairs(book_records) do out.records[#out.records + 1] = r end
    return out
end

-- Vendored from the stock plugin's opdsparser.lua: luxl pre-normalisation.
local unescape_map = { lt = "<", gt = ">", amp = "&", quot = '"', apos = "'" }
local function unescape(str)
    return (str:gsub('(&(#?)([%d%a]+);)', function(orig, n, s)
        if unescape_map[s] then return unescape_map[s] end
        if n == "#" then
            local cp = (s:sub(1, 1) == "x") and tonumber(s:sub(2), 16) or tonumber(s)
            if cp then
                local ok_u, util = pcall(require, "util")
                if ok_u and util and util.unicodeCodepointToUtf8 then
                    return util.unicodeCodepointToUtf8(cp)
                end
            end
        end
        return orig
    end))
end

local function createFlatXTable(luxl_mod, xlex, curr_element)
    local ffi = require("ffi")
    curr_element = curr_element or {}
    local curr_attr_name
    for event, offset, size in xlex:Lexemes() do
        local txt = ffi.string(xlex.buf + offset, size)
        if event == luxl_mod.EVENT_START then
            if txt ~= "xml" then
                local tab = createFlatXTable(luxl_mod, xlex)
                -- "Url" arrays the same way: OpenSearch description documents
                -- (see parseOsd below) repeat it, one per result type
                -- (html, atom, ...). Dropped during vendoring; restored to
                -- match the stock parser's opdsparser.lua.
                if txt == "entry" or txt == "link" or txt == "Url" then
                    if curr_element[txt] == nil then curr_element[txt] = {} end
                    table.insert(curr_element[txt], tab)
                elseif type(curr_element) == "table" then
                    curr_element[txt] = tab
                end
            end
        elseif event == luxl_mod.EVENT_ATTR_NAME then
            curr_attr_name = unescape(txt)
        elseif event == luxl_mod.EVENT_ATTR_VAL then
            curr_element[curr_attr_name] = unescape(txt)
            curr_attr_name = nil
        elseif event == luxl_mod.EVENT_TEXT then
            curr_element = unescape(txt)
        elseif event == luxl_mod.EVENT_END then
            return curr_element
        end
    end
    return curr_element
end

function M.parse(text)
    if text:match("^%s*{") then
        local ok_json, json = pcall(require, "json")
        if not ok_json then return nil end
        local ok_decode, decoded = pcall(json.decode, text)
        if not ok_decode or type(decoded) ~= "table" then return nil end
        decoded.is_opds2 = true
        return decoded
    end
    local ok_luxl, luxl = pcall(require, "luxl")
    if not ok_luxl then return nil end
    text = text:gsub("<%?xml%-stylesheet.-%?>", "")
    text = text:gsub("<!%-%-.-%-%->", "")
    text = text:gsub("<([%l:]+)/>", "<%1 />")
    text = text:gsub("<([bh]r)>", "<%1 />")
    text = text:gsub("<!%[CDATA%[(.-)%]%]>", function(s)
        return s:gsub("%p", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;" })
    end)
    text = text:gsub("<content%s+[^<>]-/>", "<content />")
    text = text:gsub('<content type=".-">', "<content>")
    text = text:gsub("<content>(.-)</content>", function(s)
        return '<content type="text">'
            .. s:gsub("%p", { ["<"] = "&lt;", [">"] = "&gt;",
                              ['"'] = "&quot;", ["'"] = "&apos;" })
            .. "</content>"
    end)
    local xlex = luxl.new(text, #text)
    local ok_parse, result = pcall(createFlatXTable, luxl, xlex)
    if not ok_parse then return nil end
    return result
end

-- Parses an OpenSearch description document (the target of an "osd" search
-- link) and returns the Atom-typed Url element's template, placeholder left
-- intact as "{searchTerms}" for substituteQuery below. A document commonly
-- repeats Url once per result type (html, atom, a bare OSD self-reference);
-- the first Atom one wins, mirroring the stock plugin's getSearchTemplate.
-- Returns nil if the document doesn't parse or carries no such Url.
function M.parseOsd(xml)
    local ok, result = pcall(M.parse, xml)
    if not ok or type(result) ~= "table" then return nil end
    local osd = result.OpenSearchDescription
    if type(osd) ~= "table" or type(osd.Url) ~= "table" then return nil end
    for _i, candidate in ipairs(osd.Url) do
        if type(candidate) == "table" and type(candidate.type) == "string"
                and type(candidate.template) == "string"
                and candidate.type:find(CATALOG_TYPE) then
            return candidate.template
        end
    end
    return nil
end

-- Byte-wise percent-encoding of query text, RFC 3986 unreserved set only
-- (A-Za-z0-9 _ . ~ -). Deliberately not Lua's %w/%a pattern classes: those
-- test bytes via the C library's isalnum/isalpha under the runtime's current
-- locale, and under some locales a high-byte UTF-8 continuation byte tests
-- true, leaving multi-byte characters partly unescaped - the stock plugin's
-- util.urlEncode bug (koreader#13693). Explicit ASCII-range checks sidestep
-- locale entirely and are UTF-8 safe for free: a multi-byte sequence is just
-- consecutive bytes >= 0x80, none of which are ever unreserved, so each byte
-- is escaped on its own and the result is correct regardless of what the
-- bytes spell in UTF-8.
local function isUnreserved(b)
    return (b >= 48 and b <= 57)      -- 0-9
        or (b >= 65 and b <= 90)      -- A-Z
        or (b >= 97 and b <= 122)     -- a-z
        or b == 95 or b == 46 or b == 126 or b == 45 -- _ . ~ -
end

local function percentEncode(str)
    local out = {}
    for i = 1, #str do
        local b = str:byte(i)
        out[#out + 1] = isUnreserved(b) and string.char(b) or string.format("%%%02X", b)
    end
    return table.concat(out)
end

-- Substitutes a query into a search template or a Calibre-style templated
-- href (same placeholder, same rules either way). "{searchTerms}" becomes
-- the percent-encoded query; any other optional OSD parameter
-- ("{startIndex?}", "{count?}", ...) collapses to empty, since there is no
-- value to put there - stock-compatible (those feeds work fine without them).
-- OPDS 2.0 catalogs instead template with RFC 6570's form-style query
-- ("{?name}", e.g. archive.org's "…/catalog{?query}&type=search") or
-- continuation ("{&name}") expansions, sometimes listing more than one
-- variable ("{?query,page}"): the whole token collapses to "?name=<value>"
-- / "&name=<value>", the value going to the FIRST-named variable and any
-- others in the list dropped, since there is only one query value to place
-- anywhere. Handled alongside "{searchTerms}" rather than translated into
-- it - fewer surprises if a catalog's placeholder name ever isn't "query",
-- and no change needed to how the 2.0 search link is captured in
-- mapEntries. Anything left over after all of the above (an operator or
-- shape none of these patterns recognise) is dropped whole rather than
-- left in the URL as literal braces, mirroring the stock plugin's own
-- catch-all "{.*}" removal for templates it doesn't parse precisely.
function M.substituteQuery(template_or_href, q)
    local encoded = percentEncode(q or "")
    local url_str = template_or_href:gsub("{%?(%a[%w_]*)[^}]*}", function(name)
        return "?" .. name .. "=" .. encoded
    end)
    url_str = url_str:gsub("{&(%a[%w_]*)[^}]*}", function(name)
        return "&" .. name .. "=" .. encoded
    end)
    url_str = url_str:gsub("{searchTerms}", function() return encoded end)
    url_str = url_str:gsub("{%a+%?}", "")
    url_str = url_str:gsub("{[^{}]*}", "")
    return url_str
end

-- Accept header for feed requests: a real preference list, not a single type.
--
-- The stock plugin sends bare "application/opds+json" ("prefer OPDS 2.0"),
-- which asks a server for the ONE format it may answer with. Servers that
-- only produce Atom (OPDS 1.x) are entitled to refuse that outright, and
-- strict frameworks do: Booklore/Grimmory (Spring) answers 406 "No acceptable
-- representation", so the catalog appears unreachable (issue #318). Every
-- OPDS 1.x-only server is in that class.
--
-- q-values keep the existing 2.0 preference exactly - measured against the
-- stock catalogs, Standard Ebooks and Internet Archive both still hand back
-- the same JSON they did before - while letting Atom-only servers answer, and
-- the */* tail catches servers that label their feed something unexpected.
--
-- Deliberately NOT Atom-first, even though the Atom path is the older and
-- more heavily tested of the two: a server offering BOTH would then switch
-- format (verified: Standard Ebooks flips to Atom), which is an unforced
-- change to catalogs that work today. Parsing never depended on this header
-- anyway - M.parse sniffs the payload - so widening it cannot change how a
-- response is read.
M.ACCEPT_FEED = "application/opds+json;q=1.0, application/atom+xml;q=0.9, */*;q=0.8"

-- Map a non-200 status to the err string callers switch on. "auth" gets the
-- credentials notification; "format" means the server refused every type we
-- asked for (a 406 from a server whose Accept handling we cannot satisfy);
-- anything else falls through as the status line for the log.
function M.errorForCode(code, status)
    if code == 401 or code == 403 then return "auth" end
    if code == 406 then return "format" end
    return tostring(status or code or "network unreachable")
end

-- Blocking GET with the stock plugin's header discipline (identity encoding;
-- some servers 403 generic UAs, so socketutil's KOReader UA matters).
-- Returns body string or nil, err. Callers wrap in Trapper.
function M.fetch(url, username, password)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local sink = {}
    -- socketutil's timeouts are GLOBAL state. http.request can raise (a bad
    -- URL, an SSL failure) rather than return nil+err, and an unwound stack
    -- would leave every later request in the session - KOReader's own network
    -- code included - stuck on the LARGE pair. pcall + an unconditional reset,
    -- matching CoverFetch.download's discipline.
    local ok_req, code, status = pcall(function()
        socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
        local c, _headers, st = socket.skip(1, http.request{
            url = url,
            headers = { ["Accept-Encoding"] = "identity", ["Accept"] = M.ACCEPT_FEED },
            sink = ltn12.sink.table(sink),
            user = username,
            password = password,
        })
        return c, st
    end)
    pcall(function() socketutil:reset_timeout() end)
    if not ok_req then return nil, "network unreachable" end
    if code == 200 then
        local body = table.concat(sink)
        if body ~= "" then return body end
        return nil, "empty response"
    end
    return nil, M.errorForCode(code, status)
end

return M
