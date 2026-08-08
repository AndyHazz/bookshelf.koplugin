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
    local root = base:match("^(%a[%w+.-]*://[^/]+)") or base
    if href:sub(1, 1) == "/" then return root .. href end        -- host-root
    local dir = base:match("^(.*/)") or (base .. "/")             -- relative
    return dir .. href
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

local ACQUISITION_REL = "^http://opds%-spec%.org/acquisition"
local BORROW_REL      = "http://opds-spec.org/acquisition/borrow"
local CATALOG_TYPE    = "application/atom%+xml"
local OSD_TYPE        = "application/opensearchdescription%+xml"
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
-- Formats KOReader opens; slice 1 only needs "is there at least one".
--
-- Exported (M.SUPPORTED_TYPE, aliased to the file-local below) because
-- bookshelf_opds_download's EXT_BY_TYPE has to stay in step with it: a type
-- kept here but missing there downloads as ".bin", which no provider opens.
-- The test that guards that pairing iterates THIS table, so adding a type here
-- and forgetting the extension map fails the suite rather than shipping.
local SUPPORTED_TYPE = {
    ["application/epub+zip"] = true,
    ["application/pdf"]      = true,
    ["application/fb2"]      = true,
    ["application/x-fictionbook+xml"] = true,
    ["application/x-mobipocket-ebook"] = true,
    ["application/x-cbz"]    = true,
    ["image/vnd.djvu"]       = true,
    ["text/plain"]           = true,
    ["text/html"]            = true,
}
M.SUPPORTED_TYPE = SUPPORTED_TYPE

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

-- catalog: OPDSParser-shaped table. feed_url: the URL it was fetched from
-- (base for relative hrefs). server_key: OpdsSource.serverKey of the server.
-- Returns { records, next_url, total }. Nav entries are folded into records,
-- PRECEDING the page's book records (spec 6.2 nav-first): see nav_records
-- below.
--
-- Edition collapse: book entries sharing an exact (title, author) - both
-- non-nil - merge into one record within this single mapEntries call (one
-- feed page). The first entry wins id/filepath/summary/cover urls; every
-- entry's acquisitions concatenate in feed order, so Gutenberg's separate
-- with-images/no-images entries for one work become one book offering both
-- formats. This is deliberately page-scoped: merging across pages would need
-- the whole feed in memory at once, so cross-page duplicates are left to
-- OpdsWindow's existing filepath dedupe instead (see appendPage).
function M.mapEntries(catalog, feed_url, server_key)
    local out = { records = {}, next_url = nil, total = nil }
    local feed = catalog and (catalog.feed or catalog)
    if type(feed) ~= "table" then return out end

    out.total = tonumber(feed["opensearch:totalResults"])

    -- Search link classification (stock precedence: OSD beats a Calibre
    -- template regardless of which appears first in the feed). Only the
    -- link is captured here - resolving an OSD document into its template
    -- is parseOsd's job, kept separate because it needs a second fetch.
    local search_osd, search_template
    for _i, link in ipairs(feed.link or {}) do
        if link.rel == "next" and link.href then
            out.next_url = M.absolute(feed_url, link.href)
        end
        local rel, ltype, href = link.rel, link.type, link.href
        if rel and href then
            if not search_osd and rel == "search" and ltype and ltype:find(OSD_TYPE) then
                search_osd = { href = M.absolute(feed_url, href), type = "osd" }
            elseif not search_template and rel:find("search", 1, true) and ltype
                    and ltype:find(CATALOG_TYPE) and href:find("{searchTerms}", 1, true) then
                search_template = { href = M.absolute(feed_url, href), type = "template" }
            end
        end
    end
    out.search = search_osd or search_template

    -- Nav entries collect separately so they can precede book entries
    -- regardless of feed order; OpdsSource is dependency-free and only
    -- needed here, so require it lazily rather than at module load.
    local OpdsSource = require("lib/bookshelf_opds_source")
    local nav_records, book_records = {}, {}
    -- Keyed on "title\0author" (both non-nil) so a later entry sharing that
    -- key can find the record it merges into; see the edition-collapse note
    -- above.
    local book_by_key = {}
    for idx, entry in ipairs(feed.entry or {}) do
        local title = entryTitle(entry)
        local acquisitions, thumb, image, nav_url = {}, nil, nil, nil
        for _j, link in ipairs(entry.link or {}) do
            local rel, ltype, href = link.rel, link.type, link.href
            if href then
                if rel and rel ~= BORROW_REL and rel:match(ACQUISITION_REL)
                        and SUPPORTED_TYPE[ltype] then
                    acquisitions[#acquisitions + 1] = {
                        type = ltype, href = M.absolute(feed_url, href),
                        title = type(link.title) == "string" and link.title or nil,
                    }
                elseif rel and THUMB_REL[rel] then
                    thumb = M.absolute(feed_url, href)
                elseif rel and IMAGE_REL[rel] then
                    image = M.absolute(feed_url, href)
                elseif ltype and ltype:find(CATALOG_TYPE)
                        and (not rel or NAV_REL[rel]) then
                    nav_url = M.absolute(feed_url, href)
                end
            end
        end

        if #acquisitions > 0 then
            local author = entryAuthor(entry)
            local merge_key = (title and author) and (title .. "\0" .. author) or nil
            local existing = merge_key and book_by_key[merge_key]
            if existing then
                local acq = existing.opds.acquisitions
                for _k, a in ipairs(acquisitions) do acq[#acq + 1] = a end
            else
                local id = (type(entry.id) == "string" and entry.id ~= "" and entry.id)
                    or (feed_url .. "#" .. idx)
                local summary = entry.content or entry.summary
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
                        summary       = type(summary) == "string" and summary or nil,
                        feed_url      = feed_url,
                    },
                }
                book_records[#book_records + 1] = rec
                if merge_key then book_by_key[merge_key] = rec end
            end
        elseif nav_url and title then
            nav_records[#nav_records + 1] = {
                kind          = "opds_nav",
                is_remote     = true,
                is_opds_nav   = true,
                filepath      = "OPDS://" .. server_key .. "/nav/" .. OpdsSource.serverKey(nav_url),
                label         = title,
                title         = title,
                display_title = title,
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
                opds = { feed_url = nav_url, thumbnail_url = thumb, image_url = image },
            }
        end
    end
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
function M.substituteQuery(template_or_href, q)
    local encoded = percentEncode(q or "")
    local url_str = template_or_href:gsub("{searchTerms}", function() return encoded end)
    url_str = url_str:gsub("{%a+%?}", "")
    return url_str
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
            headers = { ["Accept-Encoding"] = "identity" },
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
    if code == 401 or code == 403 then
        return nil, "auth"
    end
    return nil, tostring(status or code or "network unreachable")
end

return M
