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

-- Best embedded ISBN for the book (digits, ISBN-13 preferred) or nil. Reuses the
-- Hardcover module's pure OPF identifier reader -- works even when the external
-- Hardcover plugin is absent. ISBN-first querying hits the exact edition, which
-- gives a more accurate and usually higher-resolution cover than title+author.
local function _isbn(book)
    local ok, HC = pcall(require, "lib/bookshelf_hardcover")
    if ok and HC and HC.getEmbeddedIsbn then
        local ok2, isbn = pcall(HC.getEmbeddedIsbn, book)
        if ok2 and type(isbn) == "string" and isbn ~= "" then return isbn end
    end
    return nil
end

-- Full-content MD5 of a file, for byte-identical dedup. Lazy-required + pcall'd
-- so the standalone tests (no ffi/sha2) fall back to the size heuristic.
local _md5
local function _md5fn()
    if _md5 == nil then
        local ok, sha2 = pcall(require, "ffi/sha2")
        _md5 = (ok and sha2 and sha2.md5) or false
    end
    return _md5 or nil
end
local function _fileHash(path)
    local fn = _md5fn()
    if not fn then return nil end
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    if not data then return nil end
    local ok, h = pcall(fn, data)
    return ok and h or nil
end

-- Read pixel dimensions from a JPEG/PNG header WITHOUT decoding the whole image,
-- so a big search doesn't hold N full bitmaps in RAM just to caption them (only
-- the visible grid page is fully decoded later, by the cells). Returns w,h or nil
-- (unknown format -> caller falls back to a full decode).
local function _u16(s, o) return s:byte(o) * 256 + s:byte(o + 1) end
local function _fastDims(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local w, h
    local sig = f:read(8)
    if sig and sig:sub(1, 3) == "\xFF\xD8\xFF" then
        -- JPEG: walk segment markers to the frame header (SOF0-SOF15).
        f:seek("set", 2)
        while true do
            local m = f:read(2)
            if not m or #m < 2 or m:byte(1) ~= 0xFF then break end
            local marker = m:byte(2)
            local lenb = f:read(2)
            if not lenb or #lenb < 2 then break end
            local len = _u16(lenb, 1)
            if marker >= 0xC0 and marker <= 0xCF
                    and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
                local seg = f:read(5)  -- precision(1), height(2), width(2)
                if seg and #seg >= 5 then w, h = _u16(seg, 4), _u16(seg, 2) end
                break
            end
            if len < 2 then break end
            f:seek("cur", len - 2)
        end
    elseif sig and sig:sub(1, 4) == "\x89PNG" then
        -- PNG: IHDR width/height are the 8 bytes at offset 16.
        f:seek("set", 16)
        local b = f:read(8)
        if b and #b >= 8 then
            w = b:byte(1) * 16777216 + b:byte(2) * 65536 + b:byte(3) * 256 + b:byte(4)
            h = b:byte(5) * 16777216 + b:byte(6) * 65536 + b:byte(7) * 256 + b:byte(8)
        end
    end
    f:close()
    if w and h and w > 0 and h > 0 then return w, h end
    return nil
end

-- Download `url` into the per-book ONLINE cache dir (wiped each search), read
-- dimensions from the header (no full decode), stat for size, hash the bytes.
-- Returns a partial candidate {local_path,width,height,filesize,hash} or nil.
local function _materialise(url, book_fp, label, seq)
    if type(url) ~= "string" or url == "" then return nil end
    local ext = url:match("%.([pP][nN][gG])[%?%#]?$") and "png" or "jpg"
    local dir = CoverFetch.onlineDir(book_fp)
    local dest = dir .. "/" .. CoverApply.safeKey(label) .. "_" .. tostring(seq) .. "." .. ext
    local ok = CoverFetch.download(url, dest)
    if not ok then return nil end
    local w, h = _fastDims(dest)
    if not (w and h) then w, h = CoverApply.imageDims(dest) end  -- webp / odd files
    if not w or not h then
        logger.warn("[bookshelf cover] undecodable online cover", url)
        return nil
    end
    return {
        local_path = dest, width = w, height = h,
        filesize = CoverApply.fileSize(dest), hash = _fileHash(dest),
    }
end

-- Pick the highest-resolution URL from a Google imageLinks object. A real large
-- key wins; otherwise take the thumbnail's content URL, drop the zoom cap +
-- page-curl overlay, and request a large width via the content server's `fife`
-- param (~1200px) -- markedly higher resolution without a detail round-trip.
local function _googlePick(il)
    local best = il.extraLarge or il.large or il.medium
    if best then
        return (best:gsub("^http:", "https:"):gsub("&edge=curl", ""))
    end
    best = il.small or il.thumbnail or il.smallThumbnail
    if best then
        best = best:gsub("^http:", "https:"):gsub("&edge=curl", ""):gsub("&zoom=%d", "")
        if best:find("books%.google") or best:find("googleusercontent") then
            best = best .. (best:find("%?") and "&" or "?") .. "fife=w1200"
        end
        return best
    end
    return nil
end

-- Google Books, ISBN-first (exact edition) then title+author.
local function _google(book, out)
    local urls = {}
    local isbn = _isbn(book)
    if isbn then
        urls[#urls + 1] = "https://www.googleapis.com/books/v1/volumes?q=isbn:"
            .. _enc(isbn) .. "&country=US"
    end
    local q = _query(book)
    if q ~= "" then
        urls[#urls + 1] = "https://www.googleapis.com/books/v1/volumes?q=" .. _enc(q)
            .. "&maxResults=8&country=US"
    end
    local n = 0
    for u, url in ipairs(urls) do
        if n >= MAX_PER_SOURCE then break end
        local data = CoverFetch.getJson(url)
        if data and type(data.items) == "table" then
            for i, item in ipairs(data.items) do
                if n >= MAX_PER_SOURCE then break end
                local il = item.volumeInfo and item.volumeInfo.imageLinks
                local best = type(il) == "table" and _googlePick(il) or nil
                if best then
                    local m = _materialise(best, book.filepath, "google", u .. "_" .. i)
                    if m then
                        m.kind = "google_books"; m.source_label = _("Google Books")
                        m.url = best; m.is_active = false
                        out[#out + 1] = m; n = n + 1
                    end
                end
            end
        end
    end
end

-- Open Library, ISBN-first (direct exact-edition cover) then a title search
-- resolving cover IDs (the ID path is not rate-limited unlike ISBN/OLID).
local function _openLibrary(book, out)
    local n = 0
    local isbn = _isbn(book)
    if isbn then
        -- default=false so a missing cover 404s instead of returning a blank.
        local cu = "https://covers.openlibrary.org/b/isbn/" .. _enc(isbn) .. "-L.jpg?default=false"
        local m = _materialise(cu, book.filepath, "openlib_isbn", isbn)
        if m then
            m.kind = "open_library"; m.source_label = _("Open Library")
            m.url = cu; m.is_active = false
            out[#out + 1] = m; n = n + 1
        end
    end
    local q = _query(book)
    if q ~= "" and n < MAX_PER_SOURCE then
        local url = "https://openlibrary.org/search.json?q=" .. _enc(q)
            .. "&limit=8&fields=cover_i,title"
        local data = CoverFetch.getJson(url)
        if data and type(data.docs) == "table" then
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
    end
end

-- Apple Books via the iTunes Search API, ISBN term first then title+author.
-- artworkUrl100's size segment rewrites to a large edge; Apple caps to the
-- source's true size, so this yields the highest available. NOTE: Apple's terms
-- restrict caching/redistribution of artwork; this fetch is interactive,
-- user-initiated and per-device (the user picks one cover), not bulk harvesting.
local function _apple(book, out)
    local terms = {}
    local isbn = _isbn(book)
    if isbn then terms[#terms + 1] = isbn end
    local q = _query(book)
    if q ~= "" then terms[#terms + 1] = q end
    local n = 0
    for u, term in ipairs(terms) do
        if n >= MAX_PER_SOURCE then break end
        local url = "https://itunes.apple.com/search?media=ebook&term=" .. _enc(term) .. "&limit=8"
        local data = CoverFetch.getJson(url)
        if data and type(data.results) == "table" then
            for i, r in ipairs(data.results) do
                if n >= MAX_PER_SOURCE then break end
                local art = r.artworkUrl100
                if type(art) == "string" then
                    local hi = art:gsub("/%d+x%d+bb", "/1200x1200bb")
                    local m = _materialise(hi, book.filepath, "apple", u .. "_" .. i)
                    if m then
                        m.kind = "apple"; m.source_label = _("Apple Books")
                        m.url = hi; m.is_active = false
                        out[#out + 1] = m; n = n + 1
                    end
                end
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

-- Hardcover, when the optional plugin is present and configured. Two passes,
-- merged and deduped: the linked book's editions (exact work, many editions),
-- then a broader title/author search that also works for UNLINKED books and
-- surfaces other editions/works Hardcover has. Allowed a larger budget than the
-- other sources since broadening it is the whole point here.
local HARDCOVER_MAX = 6
local function _hardcover(book, out)
    local ok_hc, HC = pcall(require, "lib/bookshelf_hardcover")
    if not (ok_hc and HC and HC.isAvailable and HC.isAvailable()) then return end
    local n, seen = 0, {}
    local function tryAdd(url, seq, edition_id)
        if n >= HARDCOVER_MAX then return end
        if type(url) ~= "string" or url == "" or seen[url] then return end
        seen[url] = true
        local m = _materialise(url, book.filepath, "hc", seq)
        if m then
            m.kind = "hardcover_edition"; m.source_label = _("Hardcover")
            m.url = url; m.edition_id = edition_id; m.is_active = false
            out[#out + 1] = m; n = n + 1
        end
    end
    -- Editions of the linked book.
    local book_id = _hardcoverBookId(book)
    if book_id and HC.getEditionCandidates then
        local eds = HC.getEditionCandidates(book_id)
        if type(eds) == "table" then
            for i, ed in ipairs(eds) do
                if n >= HARDCOVER_MAX then break end
                tryAdd(ed.cover_url, "ed_" .. tostring(ed.edition_id or i), ed.edition_id)
            end
        end
    end
    -- Broader title/author search.
    if n < HARDCOVER_MAX and HC.searchCoverCandidates then
        local cands = HC.searchCoverCandidates(book.title, book.author)
        if type(cands) == "table" then
            for i, c in ipairs(cands) do
                if n >= HARDCOVER_MAX then break end
                tryAdd(c.cover_url, "bk_" .. tostring(c.book_id or i))
            end
        end
    end
end

-- Wikidata "instance of" ids that count as a book/work (so an unrelated entity
-- with the same title -- a film, a place -- is rejected). literary work, book,
-- written work, novel, poem, novella, version/edition/translation.
local WIKI_BOOK_TYPES = {
    Q7725634 = true, Q571 = true, Q47461344 = true, Q8261 = true,
    Q5185279 = true, Q149989 = true, Q3331189 = true,
}

local function _wdClaimId(claim)
    local v = claim and claim.mainsnak and claim.mainsnak.datavalue
        and claim.mainsnak.datavalue.value
    return type(v) == "table" and v.id or nil
end
local function _wdClaimStr(claim)
    local v = claim and claim.mainsnak and claim.mainsnak.datavalue
        and claim.mainsnak.datavalue.value
    return type(v) == "string" and v or nil
end

-- Encode a Commons filename for a Special:FilePath URL path: only the few
-- characters that would break the URL (space, ?, #, &, +, %). Dots, hyphens,
-- parentheses and the like are left literal, which Commons handles.
local function _filePathEnc(s)
    return (tostring(s):gsub("[ %?#&+%%]", function(ch)
        return string.format("%%%02X", ch:byte())
    end))
end

-- Wikidata via the MediaWiki API (fast, unlike WDQS which times out): search by
-- title, batch-fetch claims, take the first entity that is a book AND has an
-- image (P18), download its Commons file scaled to ~1200px. Best for
-- classics/public-domain works, where covers are often absent from the retail
-- APIs. A portrait guard rejects a stray non-cover image on a mismatched entity.
local function _wikidata(book, out)
    -- Title ONLY: wbsearchentities matches entity labels, so appending the author
    -- (as the retail full-text searches want) finds nothing. Disambiguation is
    -- handled by the book-type filter + search rank below.
    local title = (type(book.title) == "string" and book.title ~= "")
        and book.title or _query(book)
    if title == "" then return end
    local s = CoverFetch.getJson("https://www.wikidata.org/w/api.php?action=wbsearchentities&search="
        .. _enc(title) .. "&language=en&type=item&limit=7&format=json")
    if not s or type(s.search) ~= "table" or #s.search == 0 then return end
    local ids = {}
    for i, cand in ipairs(s.search) do
        if i > 5 then break end
        ids[#ids + 1] = cand.id
    end
    if #ids == 0 then return end
    local ent = CoverFetch.getJson("https://www.wikidata.org/w/api.php?action=wbgetentities&ids="
        .. _enc(table.concat(ids, "|")) .. "&props=claims&format=json")
    if not ent or type(ent.entities) ~= "table" then return end
    for _i, id in ipairs(ids) do  -- preserve search-rank order
        local e = ent.entities[id]
        local claims = e and e.claims
        if type(claims) == "table" and type(claims.P18) == "table" and claims.P18[1] then
            local is_book = false
            for _j, c in ipairs(claims.P31 or {}) do
                if WIKI_BOOK_TYPES[_wdClaimId(c)] then is_book = true; break end
            end
            local file = is_book and _wdClaimStr(claims.P18[1]) or nil
            if file then
                local url = "https://commons.wikimedia.org/wiki/Special:FilePath/"
                    .. _filePathEnc(file) .. "?width=1200"
                local m = _materialise(url, book.filepath, "wikidata", id)
                -- Covers are portrait; reject a clearly-landscape image.
                if m and m.width and m.height and m.height >= m.width then
                    m.kind = "wikidata"; m.source_label = _("Wikidata")
                    m.url = url; m.is_active = false
                    out[#out + 1] = m
                    return  -- one good Wikidata cover is enough
                end
            end
        end
    end
end

-- Drop byte-identical duplicates: the same cover surfaced by two sources (or by
-- Hardcover's book + edition passes) shows once. Keyed on the content hash when
-- available, falling back to the (width,height,filesize) triple.
function CoverSources.dedup(list)
    local seen, out = {}, {}
    for _i, c in ipairs(list) do
        local key = c.hash
            or table.concat({ c.width or "?", c.height or "?", c.filesize or "?" }, "\1")
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

    -- Wipe prior downloads (all books) before fetching -- these are transient
    -- (an applied cover is copied into the .sdr), so this bounds disk use to one
    -- search's worth instead of letting them accumulate.
    pcall(CoverFetch.resetOnlineCache)

    local Trapper
    local ok_t, T = pcall(require, "ui/trapper")
    if ok_t then Trapper = T end
    local function info(msg)
        if Trapper and Trapper.info then pcall(function() Trapper:info(msg) end) end
    end

    -- Apple + Google are the reliable high-resolution sources; run them first.
    -- (Google's anonymous API is also frequently rate-limited, so it may return
    -- nothing on a given day -- Apple then carries the high-res case.)
    info(_("Searching Apple Books\xE2\x80\xA6"));   pcall(_apple, book, out)
    info(_("Searching Google Books\xE2\x80\xA6"));  pcall(_google, book, out)
    info(_("Searching Open Library\xE2\x80\xA6"));  pcall(_openLibrary, book, out)
    info(_("Searching Wikidata\xE2\x80\xA6"));      pcall(_wikidata, book, out)
    info(_("Searching Hardcover\xE2\x80\xA6"));     pcall(_hardcover, book, out)

    if Trapper and Trapper.clear then pcall(function() Trapper:clear() end) end
    -- Covers are portrait: drop clearly-landscape results (banner art, result-
    -- page screenshots, wrong-entity images). Square allowed -- some legit
    -- covers are near-square. Wikidata applies this at source too; this is the
    -- net for every other source.
    local upright = {}
    for _i, c in ipairs(out) do
        if not (c.width and c.height) or c.height >= c.width then
            upright[#upright + 1] = c
        end
    end
    -- Rank by resolution (pixel area) so the highest-res covers lead the grid;
    -- low-res results (small Open Library / Hardcover images) fall to the back
    -- rather than dominating the first page.
    local ranked = CoverSources.dedup(upright)
    table.sort(ranked, function(a, b)
        return ((a.width or 0) * (a.height or 0)) > ((b.width or 0) * (b.height or 0))
    end)
    return ranked
end

return CoverSources
