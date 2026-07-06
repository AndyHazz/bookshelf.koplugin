-- bookshelf_cover_sources.lua
-- The Cover picker's ONLINE half: query a handful of cover sources for a book,
-- download each candidate, decode it locally for exact width/height, stat it for
-- filesize, dedup, and return a candidate list the grid renders like any local
-- one. Only this module knows the per-source APIs; the network plumbing lives in
-- bookshelf_cover_fetch and the shared candidate/decode helpers in
-- bookshelf_cover_apply.
--
-- Every source is best-effort and fully pcall-guarded: a failing or empty source
-- (offline, rate-limited, no match, undecodable image) is silently skipped, so
-- one bad source never sinks the batch. Downloads are the images the grid shows
-- AND the exact files applied on tap -- no low-res-preview / high-res-apply
-- mismatch. Call inside Trapper:wrap so the per-source progress shows and the
-- user can cancel.

local CoverFetch  = require("lib/bookshelf_cover_fetch")
local CoverApply  = require("lib/bookshelf_cover_apply")
local logger      = require("logger")
local _           = require("lib/bookshelf_i18n").gettext

local CoverSources = {}

-- Keep each source modest: a book rarely needs more than a few candidates per
-- source, and every extra one is a download over (often slow) e-ink Wi-Fi.
local MAX_PER_SOURCE = 4

local function _enc(s)
    return (tostring(s):gsub("[^%w]", function(ch)
        return string.format("%%%02X", ch:byte())
    end))
end

local function _query(book)
    local parts = {}
    if type(book.title) == "string" and book.title ~= "" then
        parts[#parts + 1] = book.title
    end
    if type(book.author) == "string" and book.author ~= "" then
        parts[#parts + 1] = book.author
    end
    return table.concat(parts, " ")
end

-- Download `url` into the per-book cache dir, decode for dimensions, stat for
-- size. Returns a partial candidate {local_path,width,height,filesize} or nil
-- (download failed / undecodable -> dropped by the caller).
local function _materialise(url, book_fp, label, seq)
    if type(url) ~= "string" or url == "" then return nil end
    local ext = url:match("%.([pP][nN][gG])[%?%#]?$") and "png" or "jpg"
    local dir = CoverFetch.cacheDir() .. "/" .. CoverApply.safeKey(book_fp)
    local dest = dir .. "/" .. CoverApply.safeKey(label) .. "_" .. tostring(seq) .. "." .. ext
    local ok = CoverFetch.download(url, dest)
    if not ok then return nil end
    local w, h = CoverApply.imageDims(dest)
    if not w or not h then
        logger.warn("[bookshelf cover] undecodable online cover", url)
        return nil
    end
    return { local_path = dest, width = w, height = h, filesize = CoverApply.fileSize(dest) }
end

-- Google Books. The list endpoint usually only returns thumbnail/smallThumbnail
-- (~128px). Use a real larger key when present; otherwise take the thumbnail's
-- content URL, drop the zoom cap + page-curl overlay, and request a specific
-- large width via the content server's `fife` param (~1200px) -- markedly higher
-- resolution without a per-item detail round-trip.
local function _google(book, out)
    local q = _query(book)
    if q == "" then return end
    local url = "https://www.googleapis.com/books/v1/volumes?q=" .. _enc(q)
        .. "&maxResults=8&country=US"
    local data = CoverFetch.getJson(url)
    if not data or type(data.items) ~= "table" then return end
    local n = 0
    for i, item in ipairs(data.items) do
        if n >= MAX_PER_SOURCE then break end
        local vi = item.volumeInfo
        local il = vi and vi.imageLinks
        if type(il) == "table" then
            local best = il.extraLarge or il.large or il.medium
            if best then
                best = best:gsub("^http:", "https:"):gsub("&edge=curl", "")
            else
                best = il.small or il.thumbnail or il.smallThumbnail
                if best then
                    best = best:gsub("^http:", "https:"):gsub("&edge=curl", "")
                               :gsub("&zoom=%d", "")
                    if best:find("books%.google") or best:find("googleusercontent") then
                        best = best .. (best:find("%?") and "&" or "?") .. "fife=w1200"
                    end
                end
            end
            if best then
                local m = _materialise(best, book.filepath, "google", i)
                if m then
                    m.kind = "google_books"; m.source_label = _("Google Books")
                    m.url = best; m.is_active = false
                    out[#out + 1] = m; n = n + 1
                end
            end
        end
    end
end

-- Open Library. Search for cover IDs, then fetch by cover ID (the -L size, and
-- the ID path is not rate-limited unlike ISBN/OLID lookups).
local function _openLibrary(book, out)
    local q = _query(book)
    if q == "" then return end
    local url = "https://openlibrary.org/search.json?q=" .. _enc(q)
        .. "&limit=8&fields=cover_i,title"
    local data = CoverFetch.getJson(url)
    if not data or type(data.docs) ~= "table" then return end
    local n = 0
    for _i, doc in ipairs(data.docs) do
        if n >= MAX_PER_SOURCE then break end
        if doc.cover_i then
            local cu = "https://covers.openlibrary.org/b/id/" .. tostring(doc.cover_i) .. "-L.jpg"
            local m = _materialise(cu, book.filepath, "openlib", doc.cover_i)
            if m then
                m.kind = "open_library"; m.source_label = _("Open Library")
                m.url = cu; m.is_active = false
                out[#out + 1] = m; n = n + 1
            end
        end
    end
end

-- Apple Books via the iTunes Search API. artworkUrl100's "100x100bb" segment
-- rewrites to a much larger size. NOTE: Apple's iTunes Search API terms restrict
-- caching/redistribution of artwork; this fetch is interactive, user-initiated
-- and per-device only (the user picks one cover for their own book), not bulk
-- harvesting.
local function _apple(book, out)
    local q = _query(book)
    if q == "" then return end
    local url = "https://itunes.apple.com/search?media=ebook&term=" .. _enc(q) .. "&limit=8"
    local data = CoverFetch.getJson(url)
    if not data or type(data.results) ~= "table" then return end
    local n = 0
    for i, r in ipairs(data.results) do
        if n >= MAX_PER_SOURCE then break end
        local art = r.artworkUrl100
        if type(art) == "string" then
            -- Rewrite the size segment up to a large edge; Apple caps to the
            -- source image's true size, so this yields the highest available.
            local hi = art:gsub("/%d+x%d+bb", "/1200x1200bb")
            local m = _materialise(hi, book.filepath, "apple", i)
            if m then
                m.kind = "apple"; m.source_label = _("Apple Books")
                m.url = hi; m.is_active = false
                out[#out + 1] = m; n = n + 1
            end
        end
    end
end

local function _hardcoverBookId(book)
    if book.hardcover_book_id then return book.hardcover_book_id end
    local ok_hc, HC = pcall(require, "lib/bookshelf_hardcover")
    if ok_hc and HC and HC.getLink then
        local link = HC.getLink(book.filepath)
        return link and link.book_id
    end
end

-- Hardcover editions, each with its own cover art. Only when the optional plugin
-- is present and the book is linked.
local function _hardcover(book, out)
    local book_id = _hardcoverBookId(book)
    if not book_id then return end
    local ok_hc, HC = pcall(require, "lib/bookshelf_hardcover")
    if not (ok_hc and HC and HC.isAvailable and HC.isAvailable()
            and HC.getEditionCandidates) then
        return
    end
    local eds = HC.getEditionCandidates(book_id)
    if type(eds) ~= "table" then return end
    local n = 0
    for i, ed in ipairs(eds) do
        if n >= MAX_PER_SOURCE then break end
        if ed.cover_url then
            local m = _materialise(ed.cover_url, book.filepath, "hc_ed", ed.edition_id or i)
            if m then
                m.kind = "hardcover_edition"; m.source_label = _("Hardcover")
                m.url = ed.cover_url; m.edition_id = ed.edition_id; m.is_active = false
                out[#out + 1] = m; n = n + 1
            end
        end
    end
end

-- Drop candidates whose (width,height,filesize) already appeared: the same
-- cover surfaced by two sources shows once.
function CoverSources.dedup(list)
    local seen, out = {}, {}
    for _i, c in ipairs(list) do
        local key = table.concat({ c.width or "?", c.height or "?", c.filesize or "?" }, "\1")
        if not seen[key] then
            seen[key] = true
            out[#out + 1] = c
        end
    end
    return out
end

-- searchOnline(book) -> array<Candidate>
-- Sequential across sources with per-source Trapper progress. Call inside
-- Trapper:wrap(...).
function CoverSources.searchOnline(book)
    local out = {}
    if type(book) ~= "table" or not book.filepath then return out end

    local Trapper
    local ok_t, T = pcall(require, "ui/trapper")
    if ok_t then Trapper = T end
    local function info(msg)
        if Trapper and Trapper.info then pcall(function() Trapper:info(msg) end) end
    end

    info(_("Searching Google Books\xE2\x80\xA6"));  pcall(_google, book, out)
    info(_("Searching Open Library\xE2\x80\xA6"));  pcall(_openLibrary, book, out)
    info(_("Searching Apple Books\xE2\x80\xA6"));   pcall(_apple, book, out)
    info(_("Searching Hardcover\xE2\x80\xA6"));     pcall(_hardcover, book, out)

    if Trapper and Trapper.clear then pcall(function() Trapper:clear() end) end
    return CoverSources.dedup(out)
end

return CoverSources
