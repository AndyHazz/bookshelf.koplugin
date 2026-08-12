-- tests/_test_opds_search_target.lua
-- Where an OPDS search actually points (issue #322).
--
-- A search link can arrive two ways. A templated link is captured by
-- mapEntries, which absolutises it against the feed it was found in, so by the
-- time _opdsSearch sees it the work is done. An OpenSearch description is
-- fetched at search time and its template is read straight out of that
-- document -- and a template is relative to the DOCUMENT, not to anything the
-- shelf already resolved. bookorbit advertises "/api/v1/opds/catalog?q=
-- {searchTerms}"; substituting into that yields a path, not a url, so the
-- drill failed before a single request left the device and the toast blamed
-- the server. Catalogs whose template is already absolute (Standard Ebooks)
-- never showed it, which is what made the bug look server-specific.
--
-- Two halves: the call site really does resolve (a structural check, so
-- deleting the resolve fails here rather than silently in the field), and the
-- resolution itself produces the right url.
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

-- 1. The call site. Extracted by name so a rename fails the test instead of
-- quietly skipping it.
local src  = io.open("lib/bookshelf_widget.lua"):read("*a")
local body = src:match("\nfunction BookshelfWidget:_opdsSearch%(tab, server, src, query%)\n(.-)\nend\n")
ok(body ~= nil, "_opdsSearch(tab, server, src, query) found in the widget")

if body then
    -- The osd branch is everything up to the `else` that handles an already
    -- absolute templated link.
    local osd_branch = body:match('if src%.type == "osd" then(.-)\n%s*else')
    ok(osd_branch ~= nil, "osd branch located inside _opdsSearch")
    if osd_branch then
        ok(osd_branch:find("OpdsFeed%.absolute%(src%.href, template%)") ~= nil,
            "osd template is resolved against the osd document's url before use")
        -- Ordering matters: absolutise the template, THEN substitute. The
        -- other way round hands a percent-encoded query to the url resolver.
        local resolve_at   = osd_branch:find("OpdsFeed%.absolute%(src%.href, template%)")
        local substitute_at = osd_branch:find("substituteQuery")
        ok(resolve_at ~= nil and substitute_at ~= nil and substitute_at < resolve_at,
            "substituteQuery wraps the resolved template (resolve happens first)")
    end
end

-- 2. The resolution itself, against the document bookorbit really serves
-- (server/src/modules/opds/opds.service.ts, generateOpenSearchDescription).
local BOOKORBIT_OSD = [[<?xml version="1.0" encoding="UTF-8"?>
<OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
  <ShortName>bookorbit OPDS</ShortName>
  <Description>Search the bookorbit book catalog</Description>
  <Url type="application/atom+xml;profile=opds-catalog;kind=acquisition" template="/api/v1/opds/catalog?q={searchTerms}"/>
  <InputEncoding>UTF-8</InputEncoding>
  <OutputEncoding>UTF-8</OutputEncoding>
</OpenSearchDescription>]]

-- Resolution is pure string work and needs no parser, so these run everywhere.
local OSD_URL = "https://books.example.com/api/v1/opds/search.opds"
eq(Feed.substituteQuery(Feed.absolute(OSD_URL, "/api/v1/opds/catalog?q={searchTerms}"), "dune"),
    "https://books.example.com/api/v1/opds/catalog?q=dune",
    "root-relative osd template resolves against the osd document")
eq(Feed.substituteQuery(Feed.absolute(OSD_URL, "catalog?q={searchTerms}"), "dune"),
    "https://books.example.com/api/v1/opds/catalog?q=dune",
    "path-relative osd template resolves against the osd document")
eq(Feed.substituteQuery(Feed.absolute(OSD_URL, "https://standardebooks.org/feeds/opds/all?query={searchTerms}"), "dune"),
    "https://standardebooks.org/feeds/opds/all?query=dune",
    "absolute osd template is untouched by the resolve (no regression)")
-- The query is encoded after resolution, so reserved characters in the search
-- text can never be read as url structure.
eq(Feed.substituteQuery(Feed.absolute(OSD_URL, "/api/v1/opds/catalog?q={searchTerms}"), "a b&c"),
    "https://books.example.com/api/v1/opds/catalog?q=a%20b%26c",
    "query still percent-encoded after the resolve")

-- parseOsd() needs luxl, which needs luajit's ffi and a KOReader tree.
local koreader_dir = os.getenv("KOREADER_DIR") or "/usr/lib/koreader"
local have_ffi = pcall(require, "ffi")
local f = io.open(koreader_dir .. "/frontend/luxl.lua", "r")
if f then f:close() end
if have_ffi and f then
    package.path = koreader_dir .. "/frontend/?.lua;" .. package.path
    local template = Feed.parseOsd(BOOKORBIT_OSD)
    eq(template, "/api/v1/opds/catalog?q={searchTerms}",
        "bookorbit's osd yields its (relative) template")
    eq(Feed.substituteQuery(Feed.absolute(OSD_URL, template), "dune"),
        "https://books.example.com/api/v1/opds/catalog?q=dune",
        "end to end: bookorbit's osd document produces a fetchable search url")
else
    print("note: parseOsd() fixture skipped (no luajit ffi or no KOReader tree)")
end

print(string.format("%s: %d passed, %d failed",
    "opds search target", pass, fail))
os.exit(fail == 0 and 0 or 1)
