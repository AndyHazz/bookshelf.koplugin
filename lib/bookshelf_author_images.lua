-- bookshelf_author_images.lua
-- Finds a photo of an author online and saves it into the image library
-- (<library>/authors/<name>.jpg), where ImageSource.resolveStackImage already
-- looks. Nothing new is stored and nothing new is drawn: the author's stack
-- simply finds a file there next time it paints, exactly as if the reader had
-- put it there by hand, and "Clear author image" or deleting the file undoes it.
--
-- Only ever user-initiated (an author's long-press menu, or the settings
-- menu's bulk pass): no request leaves the device on its own.
--
-- Sources, in order:
--
--   1. Open Library. /search/authors.json finds the author; among the results
--      whose name matches, the one with the MOST works is taken, which picks
--      the novelist over the namesake with one pamphlet (measured on 28 real
--      authors, no wrong picks). Its photo is covers.openlibrary.org's
--      /a/olid/<id>-L.jpg, asked for with default=false so a missing photo is
--      a 404 rather than a placeholder image. These are mostly publicity
--      portraits, framed for exactly this use.
--   2. Wikipedia, when Open Library has the author but no photo, or does not
--      have them. The lead image of the page titled with the name (or "<name>
--      (writer)" and so on), and only when the page's short description says
--      the person writes: "British writer (1870-1916)", never a footballer of
--      the same name. Filled in Saki, Lovecraft, Nghi Vo and Mick Herron in
--      the same sample.
--
-- Placeholder names (Anonymous, Various, Unknown) are never looked up: both
-- sources have records for them, and none of those is a person.

local M = {}

-- Open Library and Wikimedia both ask API users for a User-Agent that names
-- the app and how to reach whoever runs it.
M.USER_AGENT = "KOReader-Bookshelf (https://github.com/AndyHazz/bookshelf.koplugin)"

local OL_SEARCH = "https://openlibrary.org/search/authors.json?limit=10"
    .. "&fields=key,name,alternate_names,work_count&q="
local OL_PHOTO  = "https://covers.openlibrary.org/a/olid/%s-L.jpg?default=false"
local WP_API    = "https://en.wikipedia.org/w/api.php?action=query&format=json"
    .. "&formatversion=2&redirects=1&prop=pageimages%7Cdescription%7Cpageprops"
    .. "&ppprop=disambiguation&piprop=thumbnail&pithumbsize=500&titles="

-- One lookup is a handful of small requests. Tighter than socketutil's LARGE
-- pair, because the bulk pass runs them back to back on the main loop.
local TIMEOUTS = { block_timeout = 10, total_timeout = 20 }

-- A photo smaller than this is an error page or a 1px placeholder.
local MIN_BYTES = 2000

-- ---------------------------------------------------------------------
-- Names
-- ---------------------------------------------------------------------

-- Latin letters with diacritics, folded to their base letter so that a
-- library's "Stanislaw Lem" matches Open Library's "Stanisław Lem" (and the
-- other way round). UTF-8 byte sequences; lower case only, since fold()
-- lower-cases first and these are what is left after it.
local FOLD = {
    ["à"]="a", ["á"]="a", ["â"]="a", ["ã"]="a", ["ä"]="a", ["å"]="a", ["ā"]="a", ["ă"]="a", ["ą"]="a",
    ["ç"]="c", ["ć"]="c", ["č"]="c",
    ["ď"]="d", ["đ"]="d",
    ["è"]="e", ["é"]="e", ["ê"]="e", ["ë"]="e", ["ē"]="e", ["ė"]="e", ["ę"]="e", ["ě"]="e",
    ["ğ"]="g",
    ["ì"]="i", ["í"]="i", ["î"]="i", ["ï"]="i", ["ī"]="i", ["ı"]="i",
    ["ł"]="l", ["ľ"]="l",
    ["ñ"]="n", ["ń"]="n", ["ň"]="n",
    ["ò"]="o", ["ó"]="o", ["ô"]="o", ["õ"]="o", ["ö"]="o", ["ø"]="o", ["ō"]="o", ["ő"]="o",
    ["ř"]="r",
    ["ś"]="s", ["š"]="s", ["ş"]="s", ["ß"]="ss",
    ["ť"]="t", ["ţ"]="t",
    ["ù"]="u", ["ú"]="u", ["û"]="u", ["ü"]="u", ["ū"]="u", ["ů"]="u", ["ű"]="u",
    ["ý"]="y", ["ÿ"]="y",
    ["ź"]="z", ["ż"]="z", ["ž"]="z",
    ["æ"]="ae", ["œ"]="oe",
}
-- Upper-case forms Lua's lower() leaves alone (it only knows ASCII).
local UPPER = {
    ["À"]="à", ["Á"]="á", ["Â"]="â", ["Ã"]="ã", ["Ä"]="ä", ["Å"]="å", ["Ā"]="ā", ["Ą"]="ą",
    ["Ç"]="ç", ["Ć"]="ć", ["Č"]="č", ["Ď"]="ď", ["Đ"]="đ",
    ["È"]="è", ["É"]="é", ["Ê"]="ê", ["Ë"]="ë", ["Ę"]="ę", ["Ě"]="ě",
    ["Ì"]="ì", ["Í"]="í", ["Î"]="î", ["Ï"]="ï", ["İ"]="i",
    ["Ł"]="ł", ["Ñ"]="ñ", ["Ń"]="ń", ["Ň"]="ň",
    ["Ò"]="ò", ["Ó"]="ó", ["Ô"]="ô", ["Õ"]="õ", ["Ö"]="ö", ["Ø"]="ø", ["Ő"]="ő",
    ["Ř"]="ř", ["Ś"]="ś", ["Š"]="š", ["Ş"]="ş", ["Ť"]="ť",
    ["Ù"]="ù", ["Ú"]="ú", ["Û"]="û", ["Ü"]="ü", ["Ů"]="ů", ["Ű"]="ű",
    ["Ý"]="ý", ["Ź"]="ź", ["Ż"]="ż", ["Ž"]="ž", ["Æ"]="æ", ["Œ"]="œ",
}

-- fold(s) -> a comparison key: lower case, diacritics folded, every run of
-- anything that is not a letter or digit turned into one space. "Le Guin,
-- Ursula K." and "le guin ursula k" compare equal; so do "H. P. Lovecraft"
-- and "H.P. Lovecraft" once the spaces are dropped by the caller.
function M.fold(s)
    if type(s) ~= "string" then return "" end
    s = s:gsub("[\xC3-\xC5][\x80-\xBF]", function(c) return UPPER[c] or c end)
    s = s:lower()
    s = s:gsub("[\xC3-\xC5][\x80-\xBF]", function(c) return FOLD[c] or c end)
    -- Anything that is still not ASCII stays (Cyrillic, CJK): it compares as
    -- itself, which is all a name in another script needs.
    s = s:gsub("[%c%p%s]+", " ")
    return (s:gsub("^ +", ""):gsub(" +$", ""))
end

-- The comparison used for matching: fold() with the spaces removed too, so
-- initials match however they are spaced ("H. P." / "H.P." / "HP").
local function key(s) return (M.fold(s):gsub(" ", "")) end
M.matchKey = key

local PLACEHOLDERS = {
    anonymous = true, anon = true, various = true, ["various authors"] = true,
    unknown = true, ["unknown author"] = true, ["author unknown"] = true,
    ["n a"] = true, none = true, ["no author"] = true,
}

-- isPlaceholder(name) -> true for the names a library uses when there is no
-- author: there is no one to photograph.
function M.isPlaceholder(name)
    local f = M.fold(name)
    return f == "" or PLACEHOLDERS[f] == true
end

-- queryName(name) -> how to search for it. A shelf can show "Osman, Richard"
-- (Author name formatting > Last, First, or a Calibre author sort); both
-- sources index "Richard Osman". One comma only: "Smith, Jr., John" is left
-- as it is rather than guessed at.
function M.queryName(name)
    if type(name) ~= "string" then return "" end
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    local last, first = name:match("^([^,]+),%s*([^,]+)$")
    if last and first then return first .. " " .. last end
    return name
end

-- ---------------------------------------------------------------------
-- Picking from what the sources return
-- ---------------------------------------------------------------------

-- pickOpenLibrary(docs, name) -> the doc for this author, or nil. A doc
-- matches when its name, or one of its alternate names, is the author's; of
-- those, the one with the most works.
function M.pickOpenLibrary(docs, name)
    if type(docs) ~= "table" then return nil end
    local want = key(M.queryName(name))
    if want == "" then return nil end
    local best, best_n
    for _i, d in ipairs(docs) do
        if type(d) == "table" and type(d.key) == "string" then
            local hit = key(d.name) == want
            if not hit and type(d.alternate_names) == "table" then
                for _j, a in ipairs(d.alternate_names) do
                    if key(a) == want then hit = true; break end
                end
            end
            local n = tonumber(d.work_count) or 0
            if hit and n > 0 and (not best_n or n > best_n) then
                best, best_n = d, n
            end
        end
    end
    return best
end

-- Words in a Wikipedia short description that mean the person writes. A
-- page that matches the name but not these (a footballer, a politician) is
-- someone else.
local WRITER_WORDS = {
    "writer", "novelist", "author", "poet", "playwright", "dramatist",
    "essayist", "journalist", "historian", "philosopher", "screenwriter",
    "illustrator", "cartoonist", "humorist", "humourist", "satirist",
    "critic", "scholar", "storyteller", "fabulist", "diarist", "memoirist",
    "biographer", "lyricist", "librettist", "translator", "comics",
}

local function _isWriter(desc)
    if type(desc) ~= "string" or desc == "" then return false end
    local d = " " .. desc:lower():gsub("[^%a]+", " ") .. " "
    for _i, w in ipairs(WRITER_WORDS) do
        if d:find(" " .. w .. "s? ") then return true end
    end
    return false
end
M.isWriterDescription = _isWriter

-- pickWikipedia(response) -> thumbnail url, page title | nil. The response is
-- one query for one title; the page must exist, not be a disambiguation page,
-- describe a writer, and have a lead image.
function M.pickWikipedia(resp)
    local pages = type(resp) == "table" and type(resp.query) == "table"
        and resp.query.pages
    if type(pages) ~= "table" then return nil end
    for _i, p in ipairs(pages) do
        if type(p) == "table" and not p.missing and not p.invalid
                and not (type(p.pageprops) == "table" and p.pageprops.disambiguation ~= nil)
                and _isWriter(p.description)
                and type(p.thumbnail) == "table" and type(p.thumbnail.source) == "string" then
            return p.thumbnail.source, p.title
        end
    end
    return nil
end

-- ---------------------------------------------------------------------
-- Where it goes
-- ---------------------------------------------------------------------

-- Characters FAT and exFAT refuse in a file name; most readers' storage is
-- one or the other.
local function _safeStem(s)
    if type(s) ~= "string" or s == "" then return nil end
    if s:find('[%c/\\:%*%?"<>|]') then return nil end
    if s:match("^%.") or s:match("[%. ]$") then return nil end
    return s
end

-- fileStem(name) -> the name the file is saved under, or nil. The author's
-- name exactly as the shelf shows it, which is the first thing the image
-- library looks for; when that cannot be a file name, the slug it also looks
-- for (lower case, separators as dashes), made safe the same way.
function M.fileStem(name)
    local exact = _safeStem(name)
    if exact then return exact end
    if type(name) ~= "string" then return nil end
    local slug = name:lower():gsub("[,;:./%s_\\]+", "-")
    slug = slug:gsub('[%c%*%?"<>|]', "")
    slug = slug:gsub("^%-+", ""):gsub("%-+$", "")
    return _safeStem(slug)
end

-- authorsDir() -> <image library>/authors, or nil when there is no library.
function M.authorsDir()
    local lib = require("lib/bookshelf_image_source").getImageLibraryPath()
    if type(lib) ~= "string" or lib == "" then return nil end
    return lib:gsub("/+$", "") .. "/authors"
end

-- ---------------------------------------------------------------------
-- Network
-- ---------------------------------------------------------------------

local function _getJSON(url)
    local Http = require("lib/bookshelf_http")
    return Http.getJSON(url, {
        user_agent = M.USER_AGENT, accept = "application/json",
        block_timeout = TIMEOUTS.block_timeout,
        total_timeout = TIMEOUTS.total_timeout,
    })
end

local function _escape(s)
    return (s:gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

-- findOpenLibrary(name) -> url | nil, answered
-- The photo url of the matching author, which may still 404: Open Library
-- knows many authors it has no photo of, and only the download finds out.
function M.findOpenLibrary(name)
    local ol = _getJSON(OL_SEARCH .. _escape(M.queryName(name)))
    if type(ol) ~= "table" then return nil, false end
    local doc = M.pickOpenLibrary(ol.docs, name)
    local olid = doc and doc.key:match("([^/]+)$")
    if olid and olid:match("^OL%d+A$") then
        return string.format(OL_PHOTO, olid), true
    end
    return nil, true
end

-- findWikipedia(name) -> url | nil, answered
-- Titles tried in order, and each only when the one before found nothing that
-- describes a writer: most authors are the plain title.
function M.findWikipedia(name)
    local q = M.queryName(name)
    local answered = false
    for _i, title in ipairs({ q, q .. " (writer)", q .. " (author)", q .. " (novelist)" }) do
        local wp = _getJSON(WP_API .. _escape(title))
        if type(wp) == "table" then
            answered = true
            local url = M.pickWikipedia(wp)
            if url then return url, true end
            -- The page exists and is this writer, just without a picture:
            -- the suffixed titles would only find someone else.
            local p = type(wp.query) == "table" and type(wp.query.pages) == "table"
                and wp.query.pages[1]
            if type(p) == "table" and not p.missing and _isWriter(p.description) then
                break
            end
        end
    end
    return nil, answered
end

-- What the bytes are, whatever the URL said. Only the formats the image
-- library resolves; anything else is not kept.
local function _sniff(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local head = f:read(12) or ""
    f:close()
    if head:sub(1, 3) == "\xFF\xD8\xFF" then return "jpg" end
    if head:sub(1, 8) == "\x89PNG\r\n\x1A\n" then return "png" end
    if head:sub(1, 4) == "RIFF" and head:sub(9, 12) == "WEBP" then return "webp" end
    if head:sub(1, 3) == "GIF" then return "gif" end
    return nil
end

local function _size(path)
    local lfs = require("libs/libkoreader-lfs")
    return lfs.attributes(path, "size") or 0
end

-- Every other extension the image library would find before or instead of the
-- new file, so a replaced photo is not shadowed by the old one.
local OTHER_EXTS = { "jpg", "jpeg", "png", "gif", "bmp", "webp", "tiff", "tif" }

-- A JPEG this size or smaller is kept as it came. Open Library's are 15-90 KB.
M.KEEP_JPEG_BYTES = 150 * 1024
M.JPEG_QUALITY = 85

-- maxSide() -> the longest side worth keeping. The biggest an author tile is
-- drawn is a two-column grid, about half the screen wide and (at 2:3) as tall
-- as half the screen's long side; never below 600, for a reader whose library
-- travels to a bigger screen. Both sources top out near 500 px, so this is a
-- ceiling for an unusually large photo rather than something most hit.
function M.maxSide()
    local ok, Device = pcall(require, "device")
    local screen = ok and Device and Device.screen
    local w = screen and screen.getWidth and screen:getWidth() or 0
    local h = screen and screen.getHeight and screen:getHeight() or 0
    return math.max(600, math.ceil(math.max(w, h) / 2))
end

-- _compact(path, ext) -> path's new ext, rewriting the file in place as a
-- JPEG when that is worth it: any PNG, WebP or GIF (a 500 px Wikipedia PNG
-- portrait is 445 KB, the same picture as a JPEG 48 KB), a JPEG over
-- KEEP_JPEG_BYTES, or anything larger than maxSide(). Keeps what it was given
-- whenever decoding or encoding fails, or the JPEG would not be smaller.
local function _compact(path, ext)
    local bytes = _size(path)
    local cap = M.maxSide()
    local ok_r, RenderImage = pcall(require, "ui/renderimage")
    if not (ok_r and RenderImage) then return ext end
    local bb = RenderImage:renderImageFile(path, false)
    if not bb then return ext end
    local w, h = bb:getWidth(), bb:getHeight()
    if ext == "jpg" and bytes <= M.KEEP_JPEG_BYTES and math.max(w, h) <= cap then
        bb:free()
        return ext
    end
    if math.max(w, h) > cap then
        local f = cap / math.max(w, h)
        bb = RenderImage:scaleBlitBuffer(bb, math.max(1, math.floor(w * f + 0.5)),
                                         math.max(1, math.floor(h * f + 0.5)), true)
        w, h = bb:getWidth(), bb:getHeight()
    end
    -- Onto white first. A JPEG has no alpha, and the encoder takes a 32-bit
    -- buffer's fourth byte as padding: a transparent PNG would come out with
    -- whatever the decoder left in the clear pixels (MuPDF premultiplies, so
    -- black). Premultiplied blit where the build has one, to match.
    --
    -- The blend goes onto RGB32, never RGB24: KOReader's C blitter has no
    -- alpha blit into RGB24 and ABORTS the process on one ("incompatible bb
    -- (dst: BBRGB24, src: BBRGB32)"), which no pcall catches. That killed
    -- KOReader on the PW5 at the first transparent Wikipedia PNG of a bulk
    -- pass. A plain blit then makes the RGB24 copy the encoder is given.
    local ok_b, Blitbuffer = pcall(require, "ffi/blitbuffer")
    local out = bb
    if ok_b and Blitbuffer and bb.getType and bb:getType() == Blitbuffer.TYPE_BBRGB32 then
        local flat = Blitbuffer.new(w, h, Blitbuffer.TYPE_BBRGB32)
        flat:fill(Blitbuffer.COLOR_WHITE)
        if flat.pmulalphablitFrom then flat:pmulalphablitFrom(bb, 0, 0, 0, 0, w, h)
        else flat:alphablitFrom(bb, 0, 0, 0, 0, w, h) end
        bb:free()
        out = Blitbuffer.new(w, h, Blitbuffer.TYPE_BBRGB24)
        out:blitFrom(flat, 0, 0, 0, 0, w, h)
        flat:free()
    end
    local tmp = path .. ".jpg"
    local ok_w = out:writeToFile(tmp, "jpg", M.JPEG_QUALITY)
    out:free()
    if ok_w and _sniff(tmp) == "jpg" and _size(tmp) >= MIN_BYTES and _size(tmp) < bytes then
        if os.rename(tmp, path) then return "jpg" end
    end
    pcall(os.remove, tmp)
    return ext
end

-- For tests and the rig: the flattening above is the one step a device has
-- crashed in (see its RGB32 note).
M._compact = _compact

-- _save(url, dir, stem) -> path | nil. Downloads beside the destination,
-- checks what arrived, makes it compact (_compact), and only then replaces
-- whatever was saved under the stem before (in any extension, so the old one
-- cannot shadow the new).
local function _save(url, dir, stem)
    local tmp = dir .. "/." .. stem .. ".download"
    local CoverFetch = require("lib/bookshelf_cover_fetch")
    local got = CoverFetch.download(url, tmp, nil, nil, {
        block_timeout = TIMEOUTS.block_timeout,
        total_timeout = TIMEOUTS.total_timeout,
        user_agent = M.USER_AGENT,
    })
    local ext = got and _sniff(tmp)
    if not got or not ext or _size(tmp) < MIN_BYTES then
        pcall(os.remove, tmp)
        return nil
    end
    -- Only what a tile needs, in the format that holds it smallest.
    local ok_c, new_ext = pcall(_compact, tmp, ext)
    if ok_c and new_ext then ext = new_ext end
    for _i, e in ipairs(OTHER_EXTS) do
        pcall(os.remove, dir .. "/" .. stem .. "." .. e)
    end
    local dest = dir .. "/" .. stem .. "." .. ext
    if not os.rename(tmp, dest) then
        pcall(os.remove, tmp)
        return nil
    end
    return dest
end

-- fetch(name, opts) -> path, source | nil, reason
-- Finds a photo and saves it as <authors dir>/<stem>.<ext>, replacing any
-- image already saved under that stem. opts.dir overrides the folder (tests).
--   source: "openlibrary" | "wikipedia"
--   reason: "placeholder", "no library", "bad name", "none" (asked, and there
--           is no photo), or "unreachable" (no source answered at all, so the
--           bulk pass can stop instead of spending a request per author on a
--           dead connection)
function M.fetch(name, opts)
    opts = opts or {}
    if M.isPlaceholder(name) then return nil, "placeholder" end
    local dir = opts.dir or M.authorsDir()
    if not dir then return nil, "no library" end
    local stem = M.fileStem(name)
    if not stem then return nil, "bad name" end
    if not require("lib/bookshelf_fs").ensureDir(dir) then return nil, "no library" end

    local url, ol_answered = M.findOpenLibrary(name)
    if url then
        local path = _save(url, dir, stem)
        if path then return path, "openlibrary" end
    end
    local wurl, wp_answered = M.findWikipedia(name)
    if wurl then
        local path = _save(wurl, dir, stem)
        if path then return path, "wikipedia" end
    end
    return nil, (ol_answered or wp_answered) and "none" or "unreachable"
end

-- missing(names) -> the names worth looking up: not a placeholder, and with
-- no image yet, whether set by hand or already in the library.
function M.missing(names)
    local ImageSource = require("lib/bookshelf_image_source")
    local out = {}
    for _i, n in ipairs(names or {}) do
        if type(n) == "string" and not M.isPlaceholder(n)
                and not ImageSource.resolveStackImage("author", n) then
            out[#out + 1] = n
        end
    end
    return out
end

return M
