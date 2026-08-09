-- tests/_live_opds_catalogues.lua
-- LIVE sweep of the six stock OPDS catalogues: root maps, one nav drill maps,
-- a book feed carries titles, and the pagination chain walks to a clean end.
-- Hits the network - run MANUALLY (never from run.sh):
--   luajit tests/_live_opds_catalogues.lua            (all six)
--   luajit tests/_live_opds_catalogues.lua gutenberg  (one, by key)
-- Needs a KOReader tree for luxl/ffi/socket: KOREADER_DIR or /usr/lib/koreader.
-- On a packaged/binary install, run it with that tree's OWN luajit (its
-- RPATH resolves libssl/libkoreader-lfs; a plain system luajit will not):
--   /usr/lib/koreader/luajit tests/_live_opds_catalogues.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["logger"] = { dbg=function() end, info=function() end,
                             warn=function() end, err=function() end }
-- socketutil (pulled in by Feed.fetch) only reads Device.model to build its
-- User-Agent string; stub it so a standalone run never probes real hardware
-- (Kindle/Kobo/SDL) via the full device.lua chain.
package.loaded["device"] = { model = "Linux" }

local koreader_dir = os.getenv("KOREADER_DIR") or "/usr/lib/koreader"
local have_ffi = pcall(require, "ffi")
local f = io.open(koreader_dir .. "/frontend/luxl.lua", "r")
if not (have_ffi and f) then
    print("SKIP: no KOReader tree at " .. koreader_dir .. " (set KOREADER_DIR)")
    os.exit(0)
end
f:close()
-- Packaged KOReader trees keep some modules ("ffi/util" etc.) directly under
-- koreader_dir rather than frontend/ or common/, so koreader_dir itself must
-- be on the path too.
package.path  = koreader_dir .. "/frontend/?.lua;"
             .. koreader_dir .. "/common/?.lua;"
             .. koreader_dir .. "/common/?/init.lua;"
             .. koreader_dir .. "/?.lua;" .. package.path
-- Likewise native FFI helpers (libkoreader-lfs.so etc.) live directly under
-- libs/ rather than common/; require() calls them as "libs/<name>", so
-- koreader_dir itself must be on the cpath too.
package.cpath = koreader_dir .. "/common/?.so;"
             .. koreader_dir .. "/?.so;" .. package.cpath

local Feed = dofile("lib/bookshelf_opds_feed.lua")

local CATALOGUES = {
    { key = "gutenberg", title = "Project Gutenberg",
      url = "https://m.gutenberg.org/ebooks.opds/?format=opds" },
    { key = "standard",  title = "Standard Ebooks",
      url = "https://standardebooks.org/feeds/opds" },
    { key = "manybooks", title = "ManyBooks",
      url = "http://manybooks.net/opds/index.php" },
    { key = "ia",        title = "Internet Archive",
      url = "https://bookserver.archive.org/" },
    { key = "textos",    title = "textos.info",
      url = "https://www.textos.info/catalogo.atom" },
    { key = "gallica",   title = "Gallica",
      url = "https://gallica.bnf.fr/opds" },
}

local MAX_PAGES = 20  -- pagination walk bound per feed

local function fetchMap(url, key)
    local body, err = Feed.fetch(url)
    if not body then return nil, "fetch: " .. tostring(err) end
    local cat = Feed.parse(body)
    if not cat then return nil, "parse failed (non-XML/JSON body?)" end
    return Feed.mapEntries(cat, url, key)
end

-- Walk a feed's chain up to MAX_PAGES; returns a result row table.
local function walkChain(url, key)
    local pages, records, books, navs = 0, 0, 0, 0
    local total_promised, ended = nil, "bound"
    while url and pages < MAX_PAGES do
        local mapped, err = fetchMap(url, key)
        if not mapped then ended = "error: " .. err; break end
        pages = pages + 1
        total_promised = total_promised or mapped.total
        records = records + #mapped.records
        for _i, r in ipairs(mapped.records) do
            if r.is_opds_nav or r.kind == "opds_nav" then navs = navs + 1
            else books = books + 1 end
        end
        if not mapped.next_url then ended = "clean"; break end
        url = mapped.next_url
    end
    return { pages = pages, records = records, books = books, navs = navs,
             promised = total_promised, ended = ended }
end

local only = arg and arg[1]
local rows = {}
for _i, c in ipairs(CATALOGUES) do
    if not only or c.key == only then
        io.write(("== %s (%s)\n"):format(c.title, c.url)); io.flush()
        local row = { title = c.title }
        -- 1. root
        local root, rerr = fetchMap(c.url, c.key)
        if not root then
            row.status = "ROOT FAILED: " .. rerr
        else
            row.root_records = #root.records
            -- 2. first nav drill (when the root has one)
            local nav
            for _j, r in ipairs(root.records) do
                if (r.is_opds_nav or r.kind == "opds_nav")
                        and r.opds and r.opds.feed_url then nav = r; break end
            end
            local walk_url = c.url
            if nav then
                row.drill = nav.label or nav.title
                local child, cerr = fetchMap(nav.opds.feed_url, c.key)
                row.drill_records = child and #child.records
                    or ("FAILED: " .. tostring(cerr))
                if child and #child.records > 0 then
                    walk_url = nav.opds.feed_url
                end
            end
            -- 3+4. book fields + pagination walk on the chosen feed
            local w = walkChain(walk_url, c.key)
            row.walk = w
            -- title/author presence on the FIRST book found
            local first_books, _ = fetchMap(walk_url, c.key)
            if first_books then
                for _j, r in ipairs(first_books.records) do
                    if not (r.is_opds_nav or r.kind == "opds_nav") then
                        row.book_title  = r.title ~= nil and r.title ~= ""
                        row.book_author = r.author ~= nil and r.author ~= ""
                        break
                    end
                end
            end
            row.status = "OK"
        end
        rows[#rows + 1] = row
    end
end

print("\n== RESULTS ==")
for _i, r in ipairs(rows) do
    if r.status ~= "OK" then
        print(("%-20s %s"):format(r.title, r.status))
    else
        local w = r.walk or {}
        print(("%-20s root=%s drill=%s(%s) walk: pages=%s records=%s (books=%s navs=%s) promised=%s ended=%s title=%s author=%s")
            :format(r.title,
                tostring(r.root_records), tostring(r.drill),
                tostring(r.drill_records),
                tostring(w.pages), tostring(w.records), tostring(w.books),
                tostring(w.navs), tostring(w.promised), tostring(w.ended),
                tostring(r.book_title), tostring(r.book_author)))
    end
end
