-- bookshelf_ornaments.lua
-- Ornaments: PNGs and SVGs that stand in the gaps of a spine shelf, the way a
-- shop dresses a half-empty shelf with a plant or a figurine.
--
-- WHERE (M.dir): koreader/settings/bookshelf/ornaments, beside the wallpapers,
-- since v5.3; koreader/icons/bookshelf.ornaments is still read (see THE
-- FOLDERS). Loose files and one level of pack folders; a pack may carry a
-- theme/ (lib/bookshelf_theme_pack) and an ornaments.json. The first render
-- seeds template.svg (a potted plant, its comments the SVG conventions) and
-- cactus.svg; a deleted seed stays deleted.
--
-- WHAT A PIECE IS (listAll -> entries). Measured from its file: aspect (SVG
-- viewBox, PNG IHDR) and the directives an artist can put in it: overhang
-- (the lowest N units/pixels hang over the plank's front), night=invert
-- (chalk in the dark look; also cat.invert.png). Then ornaments.json, per
-- field (see ornaments.json below): scale, lift, pad, night, mirror, tap. Rendering is KOReader's
-- RenderImage (nanosvg for SVG, MuPDF for PNG, unpremultiplied here), so for
-- SVG: bold solid shapes, no text, filters or masks.
--
-- WHERE A PIECE GOES (pick). The shelf asks at four kinds of slot: a row's
-- end and a section break (both planned, so the books make room for the
-- piece), a bare plank under a short page, and packing slack left at a row's
-- end (render only). Each asks with a seed that holds for that slot, so a
-- page keeps its pieces while it is looked at. The per-shelf frequency sets
-- the odds; THE DECK decides which piece; sizeFor how big.

local logger = require("logger")
local Widget = require("ui/widget/widget")

local M = {}

-- THE FOLDERS. Since v5.3 the ornaments live beside the wallpapers, in
-- koreader/settings/bookshelf/ornaments, so one folder backs up (or moves to
-- another device) everything Bookshelf (maintainer). Until then they lived in
-- koreader/icons/bookshelf.ornaments, which is still read and never moved or
-- created; where both hold the same file, the new folder's copy wins. The
-- help, the browser and the README name only the new one.
M.NEW_PARENT    = "bookshelf"
M.NEW_SUBDIR    = "ornaments"
-- The old one. KOReader does not create icons/ itself.
M.PARENT        = "icons"
M.SUBDIR        = "bookshelf.ornaments"
M.TEMPLATE_NAME = "template.svg"
-- The ornament collection's icon (U+F0F4): its settings row and the button
-- in a piece's long-press menu that opens it (maintainer).
M.COLLECTION_ICON = "\xEF\x83\xB4"
M.HEIGHT_FRAC   = 0.8    -- height as a fraction of the books' stand height
M.HANG_CLAMP    = true   -- keep hanging (anchor top) pieces inside their gap (sizeFor)
-- THE ROW END, where width is the scarce thing and height is not.
--
-- The slot used to be a stand-height SQUARE. Anything wider than that was
-- shrunk to fit and, past a floor, dropped -- so a broad ornament simply never appeared, and nothing on screen said why
-- (maintainer: "users will wonder why their ornament never appears if it's
-- just over some hidden limit"). The square is not a rule anybody chose; it
-- is just what falls out of using the height for the width too.
--
-- There is no ceiling here worth the name. An ornament that spans the shelf
-- is a decoration somebody drew that way, and the row it stands on carries no
-- books rather than squeezing one in beside it: "I have no issue with a png
-- taking a full shelf, we don't always need to have a book" (maintainer).
--
-- What the row does hold back is one book's width, measured on the widest
-- thing a row can hold -- a face-out cover. Without it a row is FORCED to
-- seat a book (SpineLayout.fillRows seats at least one), and with only a
-- sliver left that book gets painted past the end of the plank, which is what
-- the device showed. The slot itself is worked out in bookshelf_spine_shelf.
-- The widest a piece stands by default, anywhere: its stand height, in book
-- heights (ASIDE_STANDS). A wider piece is scaled down to it, never left out.
-- Measured against the BOOKS, not the row, so taller rows (fewer of them)
-- grow the ornaments with the books: it was a quarter of the row, which stayed
-- the same width while the books grew around it (maintainer). At the PW5's two
-- rows the two agree (280px against 284px). Only a reader's own size nudge
-- takes a piece past it, up to the whole row.
M.ASIDE_STANDS  = 1.0
function M.maxWidth(stand_h, row_w)
    return math.max(0, math.min(row_w or 0, math.floor((stand_h or 0) * M.ASIDE_STANDS)))
end
M.CACHE_MAX     = 12     -- rendered bitmaps kept (path x size x night)

-- ── Frequency ──────────────────────────────────────────────────────
--
-- The level names a PATTERN of slots (lib/bookshelf_ornament_deck):
-- Rarely, Often, Always. Off places nothing.
-- The PER-SHELF key: a chip carries its own number in its tab record. There
-- is deliberately no library-wide setting behind it. A default that every
-- shelf can override is a trap -- change the default later and nothing
-- happens, because by then every shelf has a value of its own (maintainer).
-- A shelf that has never been touched holds nothing and gets FREQ_DEFAULT.
M.FREQ_SETTING  = "ornament_frequency"
M.FREQ_DEFAULT  = 1

-- The shelf on screen may pin its own frequency, so the value is pushed in
-- rather than read from the library setting alone: a chip's pin is resolved
-- against the global by the widget (BookshelfWidget:_chipListValue) and handed
-- over before anything is built, the same way the spine renderer is told about
-- the ground. nil means nobody pinned anything and the library setting stands.
M._chip_frequency = nil
function M.setChipFrequency(v)
    M._chip_frequency = (type(v) == "number" and v >= 0) and v or nil
end

function M.frequency()
    local pinned = M._chip_frequency
    if type(pinned) ~= "number" or pinned < 0 then return M.FREQ_DEFAULT end
    if pinned > 4 then return 4 end
    return pinned
end



M.TEMPLATE_SVG = [==[<?xml version="1.0" encoding="UTF-8"?>
<!-- bookshelf:seed=4 -->
<!--
  Bookshelf ornaments.

  Drop SVG or PNG files in this folder and they turn up now and then in the
  gaps on the spine shelf, standing on the plank like the books. This file is
  one: a potted plant (cactus.svg beside it is another). Copy it under a new
  name as a starting point, or delete either if you'd rather not see it;
  they won't come back. These two files are Bookshelf's own: when a release
  improves them they are rewritten in place, so an edit to one of them under
  its own name will not survive that.

  A PNG is the quick way in: any picture with a transparent background will
  do, and it stands on the plank at whatever shape it already is. It cannot
  hang over the front of the plank the way the drawing below can, and it is
  scaled to the shelf's height, so start from something reasonably large or
  it will look soft. To have a PNG shown light on a grey screen in night
  mode, put .invert before the extension: cat.invert.png.

  The rest of this file is about SVGs, which can do more.

  The rules of the shelf:

  - The BOTTOM of the viewBox is the plank's front edge. The books stand a
    little way back from it, so the two pieces here leave the last six
    units empty: that space is what sets them back onto the plank beside
    the books rather than on its lip. Leave nothing else floating below
    your last shape.
  - To hang over the front of the plank (a tail, a paw, a trailing vine),
    set the overhang line below to the number of viewBox units that should
    hang below the surface, and draw that part at the bottom.
  - The shelf is seen from slightly above (about 12 degrees), so anything
    with a top (a pot, a box, a cup) shows its opening as a shallow
    ellipse about a fifth as tall as it is wide. Match that and it belongs.
  - Use colour. Colour screens show it as drawn; grey e-ink shows it as
    shades of grey, so keep the tones fairly dark and distinct from each
    other, or it turns to mush. Bold, solid shapes read best. No text, no
    filters, no masks: the renderer is small and they will not show.
    Transparent background, so the shelf shows through.
  - An .svg has to be a DRAWING, not a picture. Converters asked to turn a
    photo into an SVG usually just wrap the photo inside it, and the
    renderer draws no pictures, so the file looks right and comes out
    blank. If you started from a picture, save it as a .png and drop that
    in instead: there is nothing to convert.
  - Height follows the shelf; width follows your aspect ratio. Aim for
    something about as tall as a book and no wider than two or three.
  - Night mode: colour screens always show your colours as drawn, and so
    does a grey e-ink screen here: the shelf turns black and these two
    pieces keep their tones, which still read against it. A plain dark
    silhouette would sink into that black, so for one of those add a line
    above the svg tag in the form of the overhang line, with night=invert
    in place of overhang=0: it is then shown light, like the spine titles.
  - Something that HANGS (a bat, a spider on its thread): long-press it on
    the shelf and raise its height to 100%, which puts the top of the
    drawing against the shelf above, whatever the shelf size.
  - A .png can carry these too, as text chunks with the keyword bookshelf
    (overhang=N in the picture's own pixels, night=invert).
-->
<!-- bookshelf:overhang=0 -->
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 60 106">
  <!-- A slight dark outline on every shape: over a wallpaper a flat fill
       sinks into the picture; the line is what keeps the piece an object. -->
  <path d="M12 70 H48 L43 97 A13 2.8 0 0 1 17 97 Z" fill="#a4512c" stroke="#4a2a17" stroke-width="1.2" stroke-linejoin="round"/>
  <ellipse cx="30" cy="68" rx="19" ry="4" fill="#3a2114"/>
  <path d="M30 70 C22 54 8 50 6 36 C20 36 30 46 30 70 Z" fill="#3f8a45" stroke="#1f3a22" stroke-width="1.2" stroke-linejoin="round"/>
  <path d="M30 70 C38 52 52 48 54 32 C40 34 30 46 30 70 Z" fill="#2f7237" stroke="#1f3a22" stroke-width="1.2" stroke-linejoin="round"/>
  <path d="M30 70 C28 48 30 30 30 12 C34 30 34 50 30 70 Z" fill="#245a2b" stroke="#1f3a22" stroke-width="1.2" stroke-linejoin="round"/>
  <path d="M11 68 A19 4 0 0 0 49 68 V72 A19 4 0 0 1 11 72 Z" fill="#c8693d" stroke="#4a2a17" stroke-width="1.2" stroke-linejoin="round"/>
</svg>
]==]

M.CACTUS_NAME = "cactus.svg"
M.CACTUS_SVG = [==[<?xml version="1.0" encoding="UTF-8"?>
<!-- bookshelf:seed=4 -->
<!-- A cactus, in the same pot as the plant. See template.svg for the rules. -->
<!-- bookshelf:overhang=0 -->
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 60 106">
  <path d="M14 74 H46 L42 97 A12 2.6 0 0 1 18 97 Z" fill="#a4512c" stroke="#4a2a17" stroke-width="1.2" stroke-linejoin="round"/>
  <ellipse cx="30" cy="72" rx="17" ry="3.6" fill="#3a2114"/>
  <!-- The arms are thick round-capped strokes, so their outline is the same
       path drawn wider and darker underneath; the body is drawn over the
       joins so the outline does not cross it. -->
  <path d="M30 56 H19 A5 5 0 0 1 14 51 V36" stroke="#1f3a22" stroke-width="10.4" stroke-linecap="round" fill="none"/>
  <path d="M30 44 H41 A5 5 0 0 0 46 39 V28" stroke="#1f3a22" stroke-width="10.4" stroke-linecap="round" fill="none"/>
  <rect x="24" y="18" width="12" height="56" rx="6" fill="#3f8a45" stroke="#1f3a22" stroke-width="1.2"/>
  <path d="M30 56 H19 A5 5 0 0 1 14 51 V36" stroke="#3f8a45" stroke-width="8" stroke-linecap="round" fill="none"/>
  <path d="M30 44 H41 A5 5 0 0 0 46 39 V28" stroke="#3f8a45" stroke-width="8" stroke-linecap="round" fill="none"/>
  <path d="M27 26 l-3 -2 M33 26 l3 -2 M27 40 l-3 -2 M33 40 l3 -2 M27 64 l-3 -2 M33 64 l3 -2 M12 42 l-3 -1 M48 34 l3 -1" stroke="#f3e9b8" stroke-width="1.2" fill="none"/>
  <path d="M13 72 A17 3.6 0 0 0 47 72 V76 A17 3.6 0 0 1 13 76 Z" fill="#c8693d" stroke="#4a2a17" stroke-width="1.2" stroke-linejoin="round"/>
</svg>
]==]

-- Written when the folder is first created: the template (a plant) and a
-- cactus. Both are ordinary ornaments; deleting either sticks.
-- The seeds carry "bookshelf:seed=N". A seed file that exists with an older
-- marker (or none: the first release had none) is ours and out of date, and
-- ensureTemplate rewrites it in place; one at the current version is left
-- alone; a deleted one stays deleted, and no other file is looked at.
M.SEED_VERSION = 4
function M.seedVersionOf(text)
    local v = type(text) == "string" and text:match("bookshelf:seed=(%d+)")
    return tonumber(v) or 0
end

M.SEED_FILES = {
    { name = M.TEMPLATE_NAME, svg = M.TEMPLATE_SVG },
    { name = M.CACTUS_NAME,   svg = M.CACTUS_SVG },
}

-- ── Seams (tests replace these) ─────────────────────────────────────────────
M._data_dir = nil          -- override for the data dir
M._lfs      = nil          -- lazily required
M._render   = nil          -- function(path, w, h) -> bb, default RenderImage
M._size     = nil          -- function(path) -> w, h, default nanosvg getSize
M._has_color = nil         -- override for Device:hasColorScreen()

function M.hasColorScreen()
    if M._has_color ~= nil then return M._has_color end
    local ok, Device = pcall(require, "device")
    if ok and Device and Device.hasColorScreen then
        local ok2, v = pcall(Device.hasColorScreen, Device)
        return ok2 and v or false
    end
    return false
end

local function lfs()
    if not M._lfs then
        local ok, mod = pcall(require, "libs/libkoreader-lfs")
        M._lfs = ok and mod or false
    end
    return M._lfs or nil
end

function M.dataDir()
    if M._data_dir then return M._data_dir end
    local ok, DataStorage = pcall(require, "datastorage")
    if ok and DataStorage and DataStorage.getDataDir then
        local ok2, d = pcall(DataStorage.getDataDir, DataStorage)
        if ok2 and type(d) == "string" and d ~= "" then return d end
    end
    return nil
end

-- settingsDir(): KOReader's settings folder (koreader/settings). A test that
-- names a data folder gets the settings folder inside it, as KOReader has it.
function M.settingsDir()
    if M._settings_dir then return M._settings_dir end
    if M._data_dir then return M._data_dir .. "/settings" end
    local ok, DataStorage = pcall(require, "datastorage")
    if ok and DataStorage and DataStorage.getSettingsDir then
        local ok2, d = pcall(DataStorage.getSettingsDir, DataStorage)
        if ok2 and type(d) == "string" and d ~= "" then return d end
    end
    local d = M.dataDir()
    return d and (d .. "/settings") or nil
end

-- dir(): the ornaments folder, the one to tell people about.
function M.dir()
    local s = M.settingsDir()
    return s and (s .. "/" .. M.NEW_PARENT .. "/" .. M.NEW_SUBDIR) or nil
end

-- legacyDir(): where they lived before v5.3; read, never created.
function M.parentDir()
    local d = M.dataDir()
    return d and (d .. "/" .. M.PARENT) or nil
end
function M.legacyDir()
    local p = M.parentDir()
    return p and (p .. "/" .. M.SUBDIR) or nil
end

-- roots() -> the folders that exist, the new one first.
function M.roots()
    local fs = lfs()
    local out = {}
    if not fs then return out end
    for _i, d in ipairs({ M.dir(), M.legacyDir() }) do
        if d and fs.attributes(d, "mode") == "directory" then out[#out + 1] = d end
    end
    return out
end

-- packDir(pack) -> the folder a pack lives in (the new one if both have it).
function M.packDir(pack)
    local fs = lfs()
    if not (fs and pack) then return nil end
    for _i, r in ipairs(M.roots()) do
        local p = r .. "/" .. pack
        if fs.attributes(p, "mode") == "directory" then return p end
    end
    return nil
end

-- refreshSeeds(d, fs): rewrite OUR seed files where they exist at an older
-- version. Reads only the head of each; never creates, never touches a file
-- under another name.
local function refreshSeeds(d, fs)
    for _i, seed in ipairs(M.SEED_FILES) do
        local path = d .. "/" .. seed.name
        if fs.attributes(path, "mode") == "file" then
            local f = io.open(path, "rb")
            local head = f and f:read(8192) or nil   -- the template's doc comment is long
            if f then f:close() end
            if head and M.seedVersionOf(head) < M.SEED_VERSION then
                local w = io.open(path, "w")
                if w then
                    w:write(seed.svg); w:close()
                    logger.dbg("[bookshelf] ornament seed refreshed:", seed.name)
                end
            end
        end
    end
end

-- ensureTemplate(): create the folder with the seeds in it, ONCE, when the
-- folder does not exist yet. An existing folder is left as the reader has it
-- -- a deleted seed stays deleted, their own files are never read -- with one
-- exception: a seed of OURS still present at an older version is rewritten
-- (refreshSeeds), so improvements to the artwork reach existing installs.
--
-- The new folder is always made, so the path the browser and the help show
-- exists; the seeds go into it only on a fresh install. A reader with the old
-- folder already has theirs there, and a second template would be a stray.
M._ensured = false
function M.ensureTemplate()
    if M._ensured then return end
    M._ensured = true
    local d = M.dir()
    local fs = lfs()
    if not (d and fs) then return end
    local old = M.legacyDir()
    local has_old = old and fs.attributes(old, "mode") == "directory"
    if has_old then pcall(refreshSeeds, old, fs) end
    if fs.attributes(d, "mode") ~= nil then
        pcall(refreshSeeds, d, fs)
        return
    end
    -- settings/ exists wherever KOReader runs; bookshelf/ may not yet.
    -- mkdir is not recursive, so a level at a time.
    local settings = M.settingsDir()
    local parent = settings and (settings .. "/" .. M.NEW_PARENT)
    for _i, p in ipairs({ settings, parent }) do
        if p and fs.attributes(p, "mode") == nil then
            pcall(fs.mkdir, p)
            if fs.attributes(p, "mode") ~= "directory" then return end
        end
    end
    local ok_mk = pcall(fs.mkdir, d)
    if not ok_mk or fs.attributes(d, "mode") ~= "directory" then return end
    if has_old then
        logger.dbg("[bookshelf] ornaments folder created (the old one stays in use too):", d)
        return
    end
    for _i, seed in ipairs(M.SEED_FILES) do
        local f = io.open(d .. "/" .. seed.name, "w")
        if f then f:write(seed.svg); f:close() end
    end
    logger.dbg("[bookshelf] ornaments folder created:", d)
end

-- parseHeader(text) -> aspect (w/h) or nil, overhang fraction (0..1),
-- night_invert (bool). Reads the viewBox and the "bookshelf:..." comments
-- from the SVG text; no XML parser, the facts are plain patterns.
function M.parseHeader(text)
    if type(text) ~= "string" then return nil, 0 end
    -- Separator is [%s,]+, not %s+: the spec allows the four viewBox numbers to
    -- be split by whitespace AND/OR a comma, and plenty of exporters write
    -- "0,0,60,100". Insisting on spaces dropped those files from the pool with
    -- no warning, which reads to a user as "my ornaments don't show up".
    local NUM = "([%-%d%.]+)"
    local SEP = "[%s,]+"
    local vb_pat = 'viewBox%s*=%s*["\']%s*' .. NUM .. SEP .. NUM .. SEP .. NUM .. SEP .. NUM
    local w, h
    local _x, _y, sw, sh = text:match(vb_pat)
    if sw then w, h = tonumber(sw), tonumber(sh) end
    if not (w and h and w > 0 and h > 0) then
        -- No usable viewBox: fall back to the <svg> tag's own width/height.
        -- nanosvg rasterises those perfectly well, so refusing them cost us
        -- files that would have rendered. Scoped to the opening tag so a
        -- child's stroke-width cannot size an ornament off a line weight, and
        -- the numeric prefix is taken so units ("60mm") work -- aspect is a
        -- ratio, so a shared unit cancels.
        --
        -- The viewBox still wins when present: it is the coordinate system the
        -- bookshelf:overhang convention is measured in.
        local tag = text:match("<svg(.-)>")
        if tag then
            local tw = tonumber(tag:match('%swidth%s*=%s*["\']%s*([%d%.]+)'))
            local th = tonumber(tag:match('%sheight%s*=%s*["\']%s*([%d%.]+)'))
            if tw and th and tw > 0 and th > 0 then w, h = tw, th end
        end
    end
    if not (w and h and w > 0 and h > 0) then return nil, 0 end
    local over = tonumber(text:match("bookshelf:overhang%s*=%s*([%d%.]+)")) or 0
    if over < 0 then over = 0 end
    if over > h then over = h end
    -- "bookshelf:night=invert": a silhouette that should turn light in night
    -- mode, like the spine titles, instead of keeping its colours the way a
    -- cover does. Default is faithful (colour artwork stays the right colour).
    local night_invert = text:match("bookshelf:night%s*=%s*invert") ~= nil
    return w / h, over / h, night_invert
end

-- be32(s, i) -> the big-endian uint32 starting at byte i, or nil if short.
local function be32(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    if not d then return nil end
    return ((a * 256 + b) * 256 + c) * 256 + d
end

-- parsePngHeader(bytes) -> aspect (w/h) or nil, overhang fraction, night_invert
--
-- The same contract as parseHeader, for a raster. Everything comes out of the
-- IHDR chunk, which a valid PNG is required to put first: the 8-byte
-- signature, then the chunk length and the tag "IHDR", then width and height
-- as big-endian uint32. So 24 bytes settle it and nothing is decoded to list a
-- folder -- which matters, because list() runs on every folder mtime change
-- and a decode is orders of magnitude dearer than a read.
--
-- DIRECTIVES come from tEXt chunks before the image data: keyword "bookshelf",
-- text "overhang=N" or "night=invert" (one per chunk, or several in
-- one separated by spaces or semicolons). N is in the image's own pixels, the
-- raster's equivalent of an SVG's viewBox units. A PNG with none -- a picture
-- someone had -- stands on the plank as it always did: overhang 0. The
-- ornament packs write them (the leaves under an apple basket hanging over
-- the plank front, a contact shadow reaching onto it).
--
-- Only chunks inside `bytes` are seen (list() reads 8KB, and a tool that puts
-- its tEXt after the image data is not supported -- the pack builder writes
-- them straight after IHDR). The filename night flag (cat.invert.png) is
-- applied by the caller on top of whatever this returns.
function M.parsePngHeader(bytes)
    if type(bytes) ~= "string" or #bytes < 24 then return nil end
    if bytes:sub(1, 8) ~= "\137PNG\r\n\026\n" then return nil end
    -- Refuse a file whose first chunk is not IHDR rather than hunting for it:
    -- that file is malformed, and reading on would take whatever bytes came
    -- next as a size.
    if bytes:sub(13, 16) ~= "IHDR" then return nil end
    local w, h = be32(bytes, 17), be32(bytes, 21)
    if not (w and h) or w <= 0 or h <= 0 then return nil end
    local text = M.pngDirectives(bytes)
    local over = tonumber(text:match("bookshelf:overhang%s*=%s*([%d%.]+)")) or 0
    if over < 0 then over = 0 end
    if over > h then over = h end
    local night = text:match("bookshelf:night%s*=%s*invert") ~= nil
    return w / h, over / h, night
end

-- pngDirectives(bytes) -> "bookshelf:<directive>" lines from the "bookshelf"
-- tEXt chunks ahead of the image data, or "". Walks the chunk list from the
-- one after IHDR; stops at IDAT/IEND, at a chunk that runs past `bytes`, or at
-- a length no real header chunk has.
function M.pngDirectives(bytes)
    local out = {}
    local pos = 9                                   -- first chunk, 1-based
    while pos + 8 <= #bytes do
        local len, typ = be32(bytes, pos), bytes:sub(pos + 4, pos + 7)
        if not len or len > 65536 or typ == "IDAT" or typ == "IEND" then break end
        if pos + 11 + len > #bytes + 4 then break end
        if typ == "tEXt" then
            local data = bytes:sub(pos + 8, pos + 7 + len)
            local z = data:find("\0", 1, true)
            if z and data:sub(1, z - 1) == "bookshelf" then
                for d in data:sub(z + 1):gmatch("[^;%s]+") do
                    out[#out + 1] = "bookshelf:" .. d
                end
            end
        end
        pos = pos + 12 + len                        -- length, type, data, crc
    end
    return table.concat(out, "\n")
end

-- pngSize(bytes) -> width, height from the IHDR, or nil.
function M.pngSize(bytes)
    if type(bytes) ~= "string" or #bytes < 24 then return nil end
    if bytes:sub(1, 8) ~= "\137PNG\r\n\026\n" or bytes:sub(13, 16) ~= "IHDR" then return nil end
    local w, h = be32(bytes, 17), be32(bytes, 21)
    if not (w and h) or w <= 0 or h <= 0 then return nil end
    return w, h
end

-- The most pixels a PNG ornament may have. The decoder (MuPDF) builds the
-- whole picture at full size before scaling it down to the ~300px it stands
-- at, 4 bytes a pixel: a ~19.5 MP drawing asked for 78 MB and the failed
-- malloc took KOReader down with it (issue 471). 8 MP (about 2800 px square,
-- 32 MB) is far more than a shelf ornament needs.
M.MAX_PNG_PX = 8 * 1000 * 1000

-- The folder's cache key. Why it is not just an mtime -- a delete that does
-- not move the mtime on the Kindle's fuse.fsp mount, and whole-second
-- granularity swallowing a same-tick addition -- is written up in
-- lib/bookshelf_asset_folder.lua, which the wallpapers folder shares.
local AssetFolder = require("lib/bookshelf_asset_folder")
local ORNAMENT_EXTS = AssetFolder.extsFromList({ "svg", "png" })

-- list() -> { {path, name, aspect, overhang}, ... } sorted by name. Re-read
-- when the folder's contents or mtime change, else served from the session
-- cache (the same table, so callers may compare identity).
M._list_cache = nil
M._list_key   = nil
-- Seconds between folder scans. A scan is a directory listing plus a stat,
-- and list() is asked once per spine plan, which runs up to three times per
-- rebuild; on a tired Kindle's FUSE userstore a listing was measured at
-- 340ms. Within the TTL the last answer stands, so a file added or removed
-- shows up within this many seconds rather than on the very next paint.
-- Zero disables the limit (the tests set it so).
M.SCAN_TTL = 15
M._clock   = os.time

-- ── Packs, and switching ornaments off ──────────────────────────────────────
--
-- A PACK is a subfolder of the ornaments folder: a set someone made (autumn,
-- a cat collection) that is switched on and off as one. Files at the top
-- level are the reader's own loose ones and belong to no pack. One level
-- deep only: a pack is a folder of pictures, not a tree.
--
-- An ornament or a pack can be switched off without deleting it (the
-- ornaments browser, lib/bookshelf_ornament_browser). Both are remembered by
-- their path relative to the folder -- "cactus.svg", "Autumn/leaf.svg" -- so
-- a file of the same name in two packs is two ornaments.
M.OFF_KEY       = "ornaments_off"        -- { [relpath] = true }
M.PACKS_OFF_KEY = "ornament_packs_off"   -- { [pack]    = true }
M._store = nil   -- seam: { read = fn(k), save = fn(k, v), generation = fn() }

local function store()
    if M._store then return M._store end
    local ok, Store = pcall(require, "lib/bookshelf_settings_store")
    return ok and Store or nil
end

local function readSet(key)
    local st = store()
    local ok, v = pcall(function() return st and st.read(key) end)
    return (ok and type(v) == "table") and v or {}
end

-- While the ornaments browser is open (beginDeferred .. endDeferred), switches
-- are written in memory only and flushed once at the end: a save flushes the
-- whole settings file, and a reader tapping through a pack paid that per tap.
-- The Theme library defers the same way. Not flushed when no setting moved
-- (the store's generation), so a look with no change writes nothing.
M._defer = false
local function generation(st)
    if not (st and st.generation) then return nil end
    local ok, g = pcall(st.generation)
    return ok and g or nil
end
function M.beginDeferred()
    M._defer = true
    M._defer_gen = generation(store())
end
function M.endDeferred()
    M._defer = false
    local st = store()
    local g = generation(st)
    if g ~= nil and g == M._defer_gen then return end
    if st and st.flush then pcall(st.flush) end
end

local function saveSet(key, set)
    local st = store()
    if not st then return end
    local v = (next(set) ~= nil) and set or nil
    if M._defer and st.saveDeferred then
        pcall(function() st.saveDeferred(key, v) end)
    else
        pcall(function() st.save(key, v) end)
    end
    M._list_cache, M._list_key = nil, nil   -- the next list() re-filters
end

function M.isOff(relpath) return readSet(M.OFF_KEY)[relpath] == true end
function M.isPackOff(pack) return pack ~= nil and readSet(M.PACKS_OFF_KEY)[pack] == true end

function M.setOff(relpath, off)
    local set = readSet(M.OFF_KEY)
    set[relpath] = off and true or nil
    saveSet(M.OFF_KEY, set)
end

function M.setPackOff(pack, off)
    if not pack then return end
    local set = readSet(M.PACKS_OFF_KEY)
    set[pack] = off and true or nil
    saveSet(M.PACKS_OFF_KEY, set)
end

-- entryFor(path, relpath, file, pack) -> an ornament entry, or nil when the
-- file cannot be sized (logged, so "my ornament doesn't show" is answerable).
local function entryFor(path, relpath, file, pack)
    local lname = file:lower()
    local is_png = lname:match("%.png$") ~= nil
    if not (is_png or lname:match("%.svg$")) then return nil end
    -- "rb": a PNG's header is binary, and a text-mode read is only the same
    -- thing by POSIX's good grace.
    local f = io.open(path, "rb")
    if not f then return nil end
    local head = f:read(8192)
    f:close()
    local aspect, over, night_invert
    if is_png then
        local pw, ph = M.pngSize(head)
        if pw and pw * ph > M.MAX_PNG_PX then
            logger.warn(string.format(
                "[bookshelf] ornament skipped, too big to decode safely: %dx%d px "
                .. "(%.1f MP, the most is %.0f MP). Save it smaller, 1000-2000 px is plenty: %s",
                pw, ph, pw * ph / 1e6, M.MAX_PNG_PX / 1e6, tostring(relpath)))
            return nil
        end
        aspect, over, night_invert = M.parsePngHeader(head)
        -- The name can carry the night flag too: cat.invert.png, the one
        -- channel that needs no tooling.
        night_invert = night_invert or lname:match("%.invert%.png$") ~= nil
    else
        -- sizeOf rather than parseHeader: it falls back to the renderer's own
        -- natural size when the header carries no usable viewBox or size.
        aspect, over, night_invert = M.sizeOf(path, head)
    end
    if not aspect then
        -- warn, not dbg: a dropped file is invisible on the shelf and the
        -- reader has nothing to go on. Fires at most once per folder change.
        logger.warn(
            "[bookshelf] ornament skipped, could not be "
            .. "sized: no viewBox or width/height in the first "
            .. "8KB, and the renderer could not open it "
            .. "either -- likely corrupt or not really an "
            .. "SVG: " .. tostring(relpath))
        return nil
    end
    if not is_png and M.looksLikeWrappedBitmap(head) then
        -- Kept in the pool deliberately: a hint off the first 8KB, not a
        -- verdict. The line is what turns "it just doesn't appear" into
        -- something answerable.
        logger.warn(
            "[bookshelf] ornament looks like a picture "
            .. "wrapped in an SVG rather than a drawing; "
            .. "the renderer draws no <image>, so it will "
            .. "come out blank. Drop the picture in as a "
            .. ".png instead: " .. tostring(relpath))
    end
    -- name is the relative path: unique across packs, and what the deck, the
    -- on/off state and ornaments.json key on. file is the bare file name, for display.
    return { path = path, name = relpath, file = file, pack = pack,
             aspect = aspect, overhang = over or 0, night_invert = night_invert }
end

-- displayName(entry) -> the file name without its extension (or the
-- .invert flag before it), which is what a person called the ornament.
function M.displayName(entry)
    local f = entry.file or entry.name or ""
    local base = f:gsub("%.[Ii][Nn][Vv][Ee][Rr][Tt]%.[Pp][Nn][Gg]$", ""):gsub("%.[Pp][Nn][Gg]$", ""):gsub("%.[Ss][Vv][Gg]$", "")
    return base ~= "" and base or f
end

-- ── ornaments.json ──────────────────────────────────────────────────────────
-- Placement that belongs to an ornament FILE, so it follows the piece onto
-- every shelf: one file in each pack (what the pack ships) and one in the
-- ornaments folder (the reader's own changes, keyed "Pack/file.png" for a
-- pack's piece, and never written into a pack's file, so updating a pack does
-- not wipe them). Per field, the reader's file beats the old folder's, which
-- beats the pack's, which beats a PNG/SVG directive, which beats the default.
--
-- Units hold at any DPI and shelf size: scale against the default size, lift
-- in the piece's own height (+ up), pad in the books' stand height (each
-- side, - tightens it against the books), trim in the piece's own width.
M.JSON_NAME = "ornaments.json"
M.FIELDS = {
    -- 5%, not half: a reader may want a piece small (maintainer). Not zero,
    -- which would leave its slot empty while it still takes its turn.
    scale  = { kind = "number", min = 0.05, max = 4, default = 1 },
    -- What the piece is pinned to: "bottom" stands it on its own plank,
    -- "top" puts its drawing's top against the underside of the shelf above
    -- (a bat, a broomstick), whatever the piece's or the shelf's size.
    anchor = { kind = "enum", values = { bottom = true, top = true }, default = "bottom" },
    -- Height: how far from its anchor, in the shelf's stand height (+ up), so
    -- a step moves every piece the same distance (see SpineShelf.ornamentY).
    -- It used to be a share of the room left above the piece, which shrank
    -- to nothing for one filling the shelf (maintainer: "for a tall
    -- ornament ... the % height doesn't act usefully").
    lift   = { kind = "number", min = -1, max = 1.5, default = 0 },
    pad    = { kind = "number", min = -1,  max = 2, default = 0 },
    -- A pack's transparent side margin (a glow, a shadow) to tuck in behind
    -- the books each side, as a share of the piece's own width, so it shrinks
    -- and grows with the piece. Pad is in stand heights and does not: a pad
    -- that tucked a candle's glow in at the pack's size cut into the candle
    -- once the piece was made smaller. Pack makers only; no menu row.
    trim   = { kind = "number", min = 0,   max = 0.5, default = 0 },
    night  = { kind = "enum", values = { invert = true, off = true } },
    mirror = { kind = "enum", values = { off = true, always = true, alternate = true }, default = "off" },
    -- A stored action ({ action, plugin, internal, label }), or "zoom": the
    -- piece full screen with its info under it (lib/bookshelf_ornament_zoom).
    tap    = { kind = "tap" },
    -- Text for the zoom view: what the piece is (a print's title, artist,
    -- notes). Without it the zoom view shows the piece's name.
    info   = { kind = "string" },
}
M.INFO_MAX = 4000

-- cleanField(name, v) -> a usable value, or nil when v is not one.
function M.cleanField(name, v)
    local f = M.FIELDS[name]
    if not f then return nil end
    if f.kind == "number" then
        if type(v) ~= "number" or v ~= v then return nil end
        return math.max(f.min, math.min(f.max, v))
    elseif f.kind == "boolean" then
        if type(v) ~= "boolean" then return nil end
        return v
    elseif f.kind == "enum" then
        return (type(v) == "string" and f.values[v]) and v or nil
    elseif f.kind == "table" then
        return type(v) == "table" and v or nil
    elseif f.kind == "tap" then
        if v == "zoom" then return { zoom = true } end
        return type(v) == "table" and v or nil
    elseif f.kind == "string" then
        if type(v) ~= "string" or v == "" then return nil end
        return (#v > M.INFO_MAX) and v:sub(1, M.INFO_MAX) or v
    end
end

local function decodeJson(text)
    if M._decode then return M._decode(text) end
    local ok, rj = pcall(require, "rapidjson")
    if ok and rj and rj.decode then return rj.decode(text) end
    return require("json").decode(text)
end

-- readJson(path) -> the file's table, or {} (absent, unreadable, not JSON:
-- the last two logged, and the ornaments still stand on their defaults).
function M.readJson(path)
    local f = io.open(path, "r")
    if not f then return {} end
    local text = f:read("*a")
    f:close()
    local ok, t = pcall(decodeJson, text)
    if not ok or type(t) ~= "table" then
        logger.warn("[bookshelf] ornaments: could not read", path, tostring(t))
        return {}
    end
    return t
end

-- The reader's size, padding and height are ADJUSTMENTS to what the layers
-- under it say (a pack's own values): size multiplies, padding and height
-- add, so a pack maker's settings are the reader's 100% and 0%, and Reset goes
-- back to them (maintainer). The rest simply replace.
M.RELATIVE = { scale = "mul", pad = "add", lift = "add" }

-- applyLayers(e, layers): merge the settings layers (highest first) over the
-- directives already on e, and derive what the painters read.
local function applyLayers(e, layers)
    local function from(i, name)
        local layer = layers[i]
        local rec = layer and layer[e.lookup and e.lookup[i] or e.name]
        if type(rec) == "table" and rec[name] ~= nil then
            local v = M.cleanField(name, rec[name])
            if v ~= nil then return v end
            logger.warn("[bookshelf] ornaments: ignoring", name, "=", tostring(rec[name]), "for", e.name)
        end
        return nil
    end
    local function get(name)
        local rel = M.RELATIVE[name]
        for i = 1, #layers do
            if not (rel and i == e._reader_at) then
                local v = from(i, name)
                if v ~= nil then
                    if rel and e._reader_at then
                        local r = from(e._reader_at, name)
                        if r ~= nil then
                            v = (rel == "mul") and v * r or v + r
                            -- Thousandths: 1.5 x 0.8 is 1.2, not 1.2000000000000002.
                            v = M.cleanField(name, math.floor(v * 1000 + 0.5) / 1000)
                        end
                    end
                    return v
                end
            end
        end
        -- Nothing under the reader's: its own value, from the default.
        if rel and e._reader_at then return from(e._reader_at, name) end
        return nil
    end
    e.scale  = get("scale") or 1
    e.anchor = get("anchor") or "bottom"
    e.lift   = get("lift") or 0
    e.pad    = get("pad") or 0
    e.trim   = get("trim") or 0
    local night = get("night")
    if night ~= nil then e.night_invert = (night == "invert") end
    e.mirror = get("mirror") or "off"
    e.tap    = get("tap")
    e.info   = get("info")
end

M._applyLayers = applyLayers

-- The directive-only values, kept so a re-apply (a reader's nudge) starts
-- from what the file itself says rather than from the last merge.
local function keepDirectives(e)
    if e._dir then return end
    e._dir = { night_invert = e.night_invert }
end
local function reapply(e)
    if not (e and e._layers) then return end
    -- The reader's layer is looked up now, not kept from the scan: a reload
    -- (its mtime changed) replaces M._reader, and an entry scanned before it
    -- would otherwise go on reading the old table.
    if e._reader_at then e._layers[e._reader_at] = M.readerTable() end
    e.night_invert = e._dir.night_invert
    pcall(applyLayers, e, e._layers)
end

-- ── The reader's own file: <ornaments folder>/ornaments.json ────────────────
-- Held in memory while a long-press menu edits it (every nudge re-applies the
-- piece at once, no rescan), and written when the menu closes.
function M.readerPath()
    local d = M.dir()
    return d and (d .. "/" .. M.JSON_NAME) or nil
end
function M.readerTable()
    local path = M.readerPath()
    local fs = lfs()
    local mt = path and fs and fs.attributes(path, "modification")
    if M._reader and M._reader_mtime == mt then return M._reader end
    if M._reader and M._reader_dirty then return M._reader end
    M._reader = path and M.readJson(path) or {}
    M._reader_mtime = mt
    return M._reader
end

-- readerValue(entry, field) -> the reader's own value for a field, or its
-- default: for size, padding and height the reader's ADJUSTMENT (see
-- M.RELATIVE), 100% / 0% at the pack's own value, which the menu shows.
function M.readerValue(entry, field)
    local rec = entry and entry.name and M.readerTable()[entry.name]
    local v = type(rec) == "table" and M.cleanField(field, rec[field]) or nil
    if v == nil then v = M.FIELDS[field] and M.FIELDS[field].default end
    return v
end

-- readerGet(name) -> the reader's record for a piece (a copy), or {}.
function M.readerGet(name)
    local rec = M.readerTable()[name]
    local out = {}
    if type(rec) == "table" then for k, v in pairs(rec) do out[k] = v end end
    return out
end

-- readerSet(entry, field, value): one field of the reader's record (nil
-- removes it; an empty record is dropped), applied to the piece at once.
-- current(entry) -> the live entry for the same piece. A rescan (the reader's
-- own save changes the file's mtime, which is in the scan key) builds new
-- entries, and the shelf draws from those; a menu opened on a piece before it
-- holds the old one (device report: edits that did nothing, then "reverted").
function M.current(entry)
    if not (entry and entry.name) then return entry end
    local all = M.listAll()
    for _i, e in ipairs(all or {}) do
        if e.name == entry.name then return e end
    end
    return entry
end

-- reapplyAll(entry): the reader's record, applied to the given entry AND
-- every other held for the same piece: listAll()'s, and list()'s, which the
-- shelf draws from and which may still be the older set until SCAN_TTL runs
-- out (a save changes the file's mtime, and so the scan key).
local function reapplyAll(entry)
    reapply(entry)
    local done = { [entry] = true }
    for _c, cache in ipairs({ M._all_cache or {}, M._list_cache or {} }) do
        for _i, e in ipairs(cache) do
            if not done[e] and e.name == entry.name then done[e] = true; reapply(e) end
        end
    end
end

function M.readerSet(entry, field, value)
    if not (entry and entry.name and M.FIELDS[field]) then return end
    local t = M.readerTable()
    local rec = type(t[entry.name]) == "table" and t[entry.name] or {}
    rec[field] = value
    t[entry.name] = next(rec) and rec or nil
    M._reader_dirty = true
    reapplyAll(entry)
end

-- readerReset(entry): the reader's record for the piece goes; the pack's
-- values (or the defaults) show again.
function M.readerReset(entry)
    if not (entry and entry.name) then return end
    local t = M.readerTable()
    if t[entry.name] ~= nil then
        t[entry.name] = nil
        M._reader_dirty = true
    end
    reapplyAll(entry)
end

local function encodeJson(t)
    if M._encode then return M._encode(t) end
    local ok, rj = pcall(require, "rapidjson")
    if ok and rj and rj.encode then return rj.encode(t, { pretty = true, sort_keys = true }) end
    return require("json").encode(t)
end

-- saveReader() -> true when written (or nothing to write).
function M.saveReader()
    if not M._reader_dirty then return true end
    local path = M.readerPath()
    if not path then return false end
    local ok, text = pcall(encodeJson, M._reader or {})
    if not ok or type(text) ~= "string" then
        logger.warn("[bookshelf] ornaments: could not encode", path, tostring(text))
        return false
    end
    local f = io.open(path, "w")
    if not f then
        logger.warn("[bookshelf] ornaments: could not write", path)
        return false
    end
    f:write(text); f:write("\n"); f:close()
    M._reader_dirty = false
    local fs = lfs()
    M._reader_mtime = fs and fs.attributes(path, "modification") or nil
    return true
end

-- commitPack(pack) -> how many pieces' records moved. The pack editor's
-- save (lib/bookshelf_pack_editor): the reader's records for the pack's
-- pieces ("Pack/file.png") move into the pack's own ornaments.json (keyed by
-- file name), field by field over what the pack had, so the pack ships with
-- them; they leave the reader's file, where they would go on winning.
function M.commitPack(pack)
    local pdir = pack and M.packDir(pack)
    if not pdir then return 0 end
    local t = M.readerTable()
    local prefix = pack .. "/"
    local path = pdir .. "/" .. M.JSON_NAME
    local pj = M.readJson(path)
    local moved = {}
    for key, rec in pairs(t) do
        if type(key) == "string" and key:sub(1, #prefix) == prefix and type(rec) == "table" then
            local file = key:sub(#prefix + 1)
            local out = type(pj[file]) == "table" and pj[file] or {}
            -- Adjustments fold into the pack's values (M.RELATIVE); the rest
            -- replace them.
            for k, v in pairs(rec) do
                local rel = M.RELATIVE[k]
                local base = M.cleanField(k, out[k])
                if rel and base ~= nil and type(v) == "number" then
                    v = M.cleanField(k, (rel == "mul") and base * v or base + v)
                    v = math.floor(v * 1000 + 0.5) / 1000
                end
                out[k] = v
            end
            pj[file] = out
            moved[#moved + 1] = key
        end
    end
    if #moved == 0 then return 0 end
    -- The pack's file first: the reader's records go only once it is written.
    local ok, text = pcall(encodeJson, pj)
    local f = ok and type(text) == "string" and io.open(path, "w")
    if not f then
        logger.warn("[bookshelf] ornaments: could not write", path)
        return 0
    end
    f:write(text); f:write("\n"); f:close()
    for _i, key in ipairs(moved) do t[key] = nil end
    local n = #moved
    M._reader_dirty = true
    M.saveReader()
    M.invalidate()
    return n
end

-- listAll() -> every ornament in the folders and their packs, switched off
-- or not, sorted by pack (loose ones first) then name; and the pack names.
-- Both folders are read (see M.dir); a relative path present in both is the
-- new folder's. Cached on the folders' own scan keys.
function M.listAll()
    local fs = lfs()
    local roots = M.roots()
    if not fs or #roots == 0 then return {}, {} end
    -- ONE listing of each folder for its files and its packs together: a FUSE
    -- directory listing was measured at 340ms on a tired Kindle, and this runs
    -- once per scan TTL. Same key as AssetFolder.scan: the folder's mtime and
    -- its sorted names.
    local key_parts = {}
    local watch = {}                        -- every folder scanned, for folderStamp
    local loose, loose_root = {}, {}        -- name -> true, name -> root
    local pack_set, pack_files = {}, {}     -- pack -> true; pack -> { file -> root }
    for _r, d in ipairs(roots) do
        local mtime = fs.attributes(d, "modification")
        local names, packs = {}, {}
        local ok_l = mtime and pcall(function()
            for name in fs.dir(d) do
                if name:sub(1, 1) ~= "." then
                    local ext = name:match("%.([^%.]+)$")
                    if ext and ORNAMENT_EXTS[ext:lower()] then
                        names[#names + 1] = name
                    elseif fs.attributes(d .. "/" .. name, "mode") == "directory" then
                        packs[#packs + 1] = name
                    end
                end
            end
        end)
        if ok_l then
            watch[#watch + 1] = d
            table.sort(names)
            table.sort(packs)
            key_parts[#key_parts + 1] = d .. "\3" .. tostring(mtime) .. "|" .. table.concat(names, "\0")
                .. "\5" .. tostring(fs.attributes(d .. "/" .. M.JSON_NAME, "modification"))
            for _i, n in ipairs(names) do
                if not loose[n] then loose[n], loose_root[n] = true, d end
            end
            for _i, pack in ipairs(packs) do
                watch[#watch + 1] = d .. "/" .. pack
                local pn, pk = AssetFolder.scan(fs, d .. "/" .. pack, ORNAMENT_EXTS)
                key_parts[#key_parts + 1] = "\1" .. pack .. "\2" .. tostring(pk) .. "\5"
                    .. tostring(fs.attributes(d .. "/" .. pack .. "/" .. M.JSON_NAME, "modification"))
                pack_set[pack] = true
                pack_files[pack] = pack_files[pack] or {}
                for _j, file in ipairs(pn or {}) do
                    if not pack_files[pack][file] then pack_files[pack][file] = d end
                end
            end
        end
    end
    local key = table.concat(key_parts, "\4")
    M._watch = watch
    if M._all_cache and M._all_key == key then return M._all_cache, M._all_packs end
    local names = {}
    for n in pairs(loose) do names[#names + 1] = n end
    table.sort(names)
    local packs = {}
    for p in pairs(pack_set) do packs[#packs + 1] = p end
    table.sort(packs)
    local out = {}
    local ok = pcall(function()
        for _i = 1, #names do
            local n = names[_i]
            local e = entryFor(loose_root[n] .. "/" .. n, n, n, nil)
            if e then out[#out + 1] = e end
        end
        for _i, pack in ipairs(packs) do
            local files = {}
            for f in pairs(pack_files[pack]) do files[#files + 1] = f end
            table.sort(files)
            for _j, file in ipairs(files) do
                local rel = pack .. "/" .. file
                local e = entryFor(pack_files[pack][file] .. "/" .. rel, rel, file, pack)
                if e then out[#out + 1] = e end
            end
        end
    end)
    if not ok then out = {} end
    -- The settings layers. The root files of both folders, then each pack's
    -- own file, read from the folder its piece came from.
    local root_json, reader_at = {}, nil
    for _r, d in ipairs(roots) do
        if d == M.dir() then reader_at = _r end
        root_json[_r] = (d == M.dir()) and M.readerTable() or M.readJson(d .. "/" .. M.JSON_NAME)
    end
    local pack_json = {}
    for _i, e in ipairs(out) do
        local layers = {}
        for _r = 1, #roots do layers[#layers + 1] = root_json[_r] end
        local lookup = {}
        for _r = 1, #roots do lookup[_r] = e.name end
        if e.pack then
            local pdir = e.path:match("^(.*)/[^/]+$")
            if pack_json[pdir] == nil then pack_json[pdir] = M.readJson(pdir .. "/" .. M.JSON_NAME) end
            layers[#layers + 1] = pack_json[pdir]
            lookup[#layers] = e.file
        end
        e.lookup, e._layers, e._reader_at = lookup, layers, reader_at
        keepDirectives(e)
        pcall(applyLayers, e, layers)
    end
    M._all_cache, M._all_key, M._all_packs = out, key, packs
    return out, packs
end

-- list() -> the ornaments the shelf may place: every one in listAll() that is
-- not switched off and whose pack is not. Sorted by name (relative path),
-- which the deck's pool key relies on.
function M.list()
    local now = M._clock()
    if M._list_cache and M._list_at and M.SCAN_TTL > 0
            and (now - M._list_at) < M.SCAN_TTL then
        return M._list_cache
    end
    local all = M.listAll()
    M._list_at = now
    local off, packs_off = readSet(M.OFF_KEY), readSet(M.PACKS_OFF_KEY)
    -- The same table while nothing changed: the deck and the plan key on
    -- it, and re-filtering every render would hand out a new one each time.
    local sig = {}
    for k in pairs(off) do sig[#sig + 1] = k end
    for k in pairs(packs_off) do sig[#sig + 1] = "\1" .. k end
    table.sort(sig)
    local key = tostring(all) .. "|" .. table.concat(sig, "\0")
    if M._list_cache and M._list_key == key then return M._list_cache end
    local out = {}
    for _i, e in ipairs(all) do
        if not off[e.name] and not (e.pack and packs_off[e.pack]) then out[#out + 1] = e end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    M._list_cache, M._list_key = out, key
    return out
end

-- listFor(sp) -> the pieces a shelf deals from. sp is what
-- bookshelf_theme_pack.ornamentsFor answers for the shelf: "mine" (or nil)
-- deals what the collection has on (M.list, loose pieces included); "plain"
-- deals nothing; a pack deals its OWN pieces only, every one -- even when
-- that pack or piece is off in the collection, whose switches shape the
-- reader's own ornaments only. Themes do not mix: no loose pieces on a
-- themed shelf (maintainer, 2026-10-07), unless the reader edits the
-- theme's set (a table, below). The same table while nothing changed: the
-- deck and the plan key on it.
M._list_for = {}
M._none = {}
function M.listFor(sp)
    if sp == nil or sp == "mine" then return M.list() end
    if sp == "plain" then return M._none end
    -- A theme whose ornaments the reader has edited
    -- (bookshelf_theme_pack.editPoolOf): its switched-on set, from any pack
    -- or loose (spec, 2026-10-08). Its own switches only. The key changes
    -- with the set, so an edit is a new list.
    if type(sp) == "table" then
        local all = M.listAll()
        local key = tostring(all) .. "|" .. tostring(sp.key)
        -- One slot per theme, not per edit: an edit replaces the list.
        local slot = "\1" .. tostring(sp.slot or sp.key)
        local hit = M._list_for[slot]
        if hit and hit.key == key and hit.on == sp.on then return hit.v end
        local on = type(sp.on) == "table" and sp.on or {}
        local out = {}
        for _i, e in ipairs(all) do
            if on[e.name] then out[#out + 1] = e end
        end
        table.sort(out, function(a, b) return a.name < b.name end)
        M._list_for[slot] = { key = key, on = sp.on, v = out }
        return out
    end
    -- The collection's off switches no longer reach a pack's shelf: 5.3's
    -- were moved into the packs' edits (bookshelf_theme_pack migration 5).
    local all = M.listAll()
    local key = tostring(all)
    local hit = M._list_for[sp]
    if hit and hit.key == key then return hit.v end
    local out = {}
    for _i, e in ipairs(all) do
        if e.pack == sp then out[#out + 1] = e end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    M._list_for[sp] = { key = key, v = out }
    return out
end

-- delete(entry) -> true on success. Removes the file and forgets its state.
function M.delete(entry)
    if not (entry and entry.path) then return false end
    local ok = os.remove(entry.path)
    if not ok then return false end
    local set = readSet(M.OFF_KEY)
    if set[entry.name] then set[entry.name] = nil; saveSet(M.OFF_KEY, set) end
    M._all_cache, M._all_key, M._list_cache, M._list_key = nil, nil, nil, nil
    M._list_for = {}
    return true
end

-- folderStamp() -> { [folder] = mtime } for each folder the last scan walked
-- (the roots and every pack); before any scan, the roots alone. Stats only,
-- never a listing, so the shelf's new-file poll can ask every few seconds.
M._watch = nil
function M.folderStamp()
    local fs = lfs()
    if not fs then return {} end
    local out = {}
    for _i, d in ipairs(M._watch or M.roots()) do
        out[d] = fs.attributes(d, "modification") or false
    end
    return out
end

-- stampChanged(prev, now) -> whether an ornament folder changed between two
-- stamps. Only folders in both count: a folder that is new to the watch list
-- arrived because a scan found it, and a new pack ALSO changes its root's
-- mtime, which is in both. A folder that went missing is a change.
function M.stampChanged(prev, now)
    if type(prev) ~= "table" or type(now) ~= "table" then return false end
    for d, m in pairs(prev) do
        if now[d] == nil or now[d] ~= m then return true end
    end
    return false
end

-- invalidate(): forget the cached lists (the browser, after a change).
function M.invalidate()
    M._all_cache, M._all_key, M._list_cache, M._list_key, M._list_at = nil, nil, nil, nil, nil
end

-- looksLikeWrappedBitmap(head) -> bool
--
-- A photo "converted" to SVG by wrapping it in an <image> element rather than
-- tracing it. The file parses and carries a correct viewBox, so it joins the
-- pool and is given a gap -- and then nothing is drawn, because nanosvg has no
-- <image> handler. Its element table in the shipped library is exactly:
--
--   circle defs ellipse linearGradient path polygon polyline radialGradient rect
--
-- so the element is skipped outright. Resizing the file cannot help, which is
-- what makes this so confusing to hit (issue 404).
--
-- A hint, not a verdict: we see only the first 8KB, and a part-traced drawing
-- could carry its shapes further in. So an <image> ALONGSIDE any drawable
-- element is left alone, and the caller warns rather than rejecting.
local DRAWABLE = { "<path", "<rect", "<circle", "<ellipse", "<polygon",
                   "<polyline", "<line" }
function M.looksLikeWrappedBitmap(head)
    if type(head) ~= "string" then return false end
    if not head:find("<image", 1, true) then return false end
    for i = 1, #DRAWABLE do
        if head:find(DRAWABLE[i], 1, true) then return false end
    end
    return true
end

-- sizeOf(path, head) -> aspect, overhang_share, night_invert  (or nil)
--
-- parseHeader first: a regex over the first 8KB, cheap, and right for every
-- ornament anyone has actually written. When it comes back empty the file is
-- not necessarily unusable -- it may carry percentage sizes, or neither a
-- viewBox nor width/height, both of which nanosvg handles by applying its own
-- defaults. So ask the renderer, which parses the file properly and reports
-- the natural size it will actually draw at.
--
-- Last resort ONLY. A normal folder never reaches it, so no one pays a full
-- SVG parse per file on a folder change; a folder of awkward files pays it
-- once, since M.list is cached until the folder changes.
--
-- The bookshelf:overhang share still works off whatever height won: it is
-- declared in the file's own coordinate units, and nanosvg measures in those
-- same units (the viewBox when there is one, width/height otherwise).
local function defaultSize(path)
    local NnSVG = require("libs/libkoreader-nnsvg")
    local img = NnSVG.new(path)
    if not img then return nil end
    local w, h = img:getSize()
    if img.free then pcall(function() img:free() end) end
    return w, h
end

function M.sizeOf(path, head)
    local aspect, over, night_invert = M.parseHeader(head)
    if aspect then return aspect, over, night_invert end
    local ok, w, h = pcall(M._size or defaultSize, path)
    if not ok or not (w and h) or w <= 0 or h <= 0 then return nil end
    -- Re-read the conventions from the header: only the SIZE was missing.
    local o = tonumber(type(head) == "string"
        and head:match("bookshelf:overhang%s*=%s*([%d%.]+)") or nil) or 0
    if o < 0 then o = 0 end
    if o > h then o = h end
    local inv = type(head) == "string"
        and head:match("bookshelf:night%s*=%s*invert") ~= nil or false
    return w / h, o / h, inv
end

-- hash(s) -> non-negative integer, djb2 (LuaJIT-safe arithmetic).
-- Bitwise xor that works on both interpreters: LuaJIT is Lua 5.1, where the
-- binary `~` operator does not exist, and the tests run under 5.4.
local bxor
do
    local ok_bit, bit = pcall(require, "bit")
    if ok_bit and bit and bit.bxor then
        bxor = function(a, b) return bit.bxor(a, b) % 4294967296 end
    else
        bxor = function(a, b)
            local r, m = 0, 1
            for _i = 1, 32 do
                local x, y = a % 2, b % 2
                if x ~= y then r = r + m end
                a, b, m = (a - x) / 2, (b - y) / 2, m * 2
            end
            return r
        end
    end
end

-- djb2, then an avalanche so neighbouring seeds do not give neighbouring
-- answers.
--
-- WHY THE MIX MATTERS. Every seeded decision here is taken modulo something
-- small: the odds are `h % 100`, the per-page promise is `h % period`. Plain
-- djb2 over strings that differ only in their last byte moves the result by
-- exactly that byte's difference, so "page2|rowend|1" and "page2|rowend|2"
-- came out one apart. An on-device probe caught the consequence: `h % 100`
-- ran 23, 24, 25 ... straight up the rows of a page, so whether a row got an
-- ornament was not a per-row coin toss at all -- it was a contiguous run, and
-- a two-row page therefore gave BOTH its rows a piece or neither. Pages
-- arrived in clumps with long deserts between them, which reads as the same
-- few ornaments over and over rather than as "often".
--
-- The finisher is the 32-bit xorshift-multiply from MurmurHash3; two inputs a
-- byte apart now differ across the whole word. Same function of the same
-- seed, so both planning passes still agree -- only the spread changes.
function M.hash(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
    h = bxor(h, math.floor(h / 65536))          -- h ^ (h >> 16)
    h = (h * 2246822507) % 4294967296
    h = bxor(h, math.floor(h / 8192))           -- h ^ (h >> 13)
    h = (h * 3266489909) % 4294967296
    return bxor(h, math.floor(h / 65536))
end


-- Which slots hold a piece, and which piece: lib/bookshelf_ornament_deck.

-- sizeFor(entry, cap_px, stand_h, o) -> w, h of a dealt piece. 80% of the
-- books' stand height, times the piece's scale; no wider than the cap
-- (grown with the scale, up to o.max_room); the file's own overhang kept on
-- the plank. Never refuses: space is always made (maintainer), so a slot
-- whose turn it is always shows its piece, however small that comes out.
function M.sizeFor(entry, cap_px, stand_h, o)
    o = o or {}
    local scale = entry.scale or 1
    local aspect = entry.aspect or 1
    local cap = math.floor((cap_px or 0) * scale)
    if o.max_room then cap = math.min(cap, o.max_room) end
    cap = math.max(1, cap)
    local height = math.floor((stand_h or 0) * M.HEIGHT_FRAC * scale)
    -- A hanging piece (anchor top) keeps the size its pack gave it, but its
    -- DRAWING (the file's top room skipped, as ornamentY does) must fit in
    -- o.hang_room, the clear gap from the shelf above as drawn to the plank
    -- below, less however far its lift lowers it: art hangs on the wall and
    -- never overlaps either shelf (maintainer, 2026-10-05). Filling the gap
    -- times the pack's scale instead made a 1.32 pack's pieces 132% of it.
    if M.HANG_CLAMP and o.hang_room and entry.anchor == "top" then
        local frac = 1
        if entry.path then
            local _l, t, _r, b = M.contentBox(entry)
            if t and b and b > t then frac = b - t end
        end
        local down = math.max(0, -(entry.lift or 0)) * (stand_h or 0)
        local room = math.max(1, o.hang_room - down)
        if height * frac > room then height = math.floor(room / frac) end
    end
    local width  = math.floor(height * aspect)
    if width > cap then
        width  = cap
        height = math.floor(width / aspect)
    end
    -- The FILE's overhang sizes the piece; a reader's height nudge only moves
    -- it (the sink, in place), or nudging the height would resize it.
    local over = entry.overhang or 0
    if over > 0 and o.max_below then
        if height * over > o.max_below then
            height = math.floor(o.max_below / over)
            width  = math.floor(height * aspect)
        end
    end
    return math.max(1, width), math.max(1, height)
end

-- place(entry, cap_px, stand_h, o, deal_no) -> where a dealt piece stands.
-- o.max_room : the widest a scaled-up piece may go (the whole row);
-- o.max_below : how far below the feet an overhang may reach (the plank's
-- surface strip + front face). deal_no counts this piece's deals on the
-- chip, for "mirror every other time".
function M.place(entry, cap_px, stand_h, o, deal_no)
    o = o or {}
    if not entry then return nil end
    local width, height = M.sizeFor(entry, cap_px, stand_h, o)
    -- Below the plank's surface: the file's own overhang, sized by sizeFor
    -- to stay on the plank. The anchor and height (entry.anchor, entry.lift)
    -- are placed by the shelf, which knows where the shelf above is
    -- (SpineShelf.ornamentY).
    local below = math.floor(height * (entry.overhang or 0))
    if o.max_below and below > o.max_below then below = o.max_below end
    local anchor = (entry.anchor == "top") and "top" or "bottom"
    local offset = entry.lift or 0
    -- Where the drawing's top is inside the picture: the top anchor meets the
    -- shelf above with the DRAWING, not the file's transparent top room.
    local content_top = 0
    if anchor == "top" and entry.path then
        local _l, ct = M.contentBox(entry)
        if ct then content_top = math.floor(ct * height + 0.5) end
    end
    -- Mirror from the piece's CURRENT setting, so a change in its menu
    -- reaches pieces already standing.
    local mirror = entry.mirror == "always"
                   or (entry.mirror == "alternate" and (deal_no or 1) % 2 == 0)
    return {
        entry = entry, w = width, h = height, anchor = anchor, offset = offset,
        content_top = content_top,
        above = height - below, below = below,
        mirror = mirror,
        -- Extra room each side, in px (negative: tighter, even behind the
        -- books beside it); the shelf adds it to its own pad (SpineShelf.ornPad).
        -- The trim is a share of the width as placed (pack scale, the
        -- reader's size and any cap already in it), so it follows the drawing.
        pad_px = math.floor((entry.pad or 0) * (stand_h or 0) - (entry.trim or 0) * width + 0.5),
    }
end

-- render(entry, w, h, night) -> bb or nil. Cached; the cache owns its bbs
-- (widgets blit from it at paint and never keep the reference), so eviction
-- frees for real.
M._cache = {}
M._cache_order = {}
-- unpremultiply(bb) -- straight alpha from premultiplied, in place.
--
-- MuPDF decodes a PNG with every pixel's colour already multiplied by its
-- alpha; KOReader's own ImageWidget knows and blits those with
-- pmulalphablitFrom. Everything here blends as STRAIGHT alpha (alphablitFrom,
-- and the night pre-invert), so a premultiplied bitmap darkened each
-- half-transparent pixel twice: soft edges and baked shadows came out darker
-- than drawn (measured: a white ramp at 50% alpha on grey rendered 127, not
-- 192). Converting once, at render, fixes every blit of the cached bitmap.
--
-- Fast path: walk the bytes of an unrotated RGB32 or grey+alpha (BB8A)
-- bitmap directly, which is what a PNG decodes to. Per-pixel getPixelP calls
-- measured 29 ms for a 250x460 ornament on a PW5, paid on every first render.
function M.unpremultiply(bb)
    local done = pcall(function()
        local ffi = require("ffi")
        local t = bb.getType and bb:getType()
        if not (bb.data and bb.stride and bb.getRotation and bb:getRotation() == 0
                and not (bb.getInverse and bb:getInverse() == 1)) then
            error("slow path")
        end
        local bpp = (t == 5) and 4 or ((t == 2) and 2 or nil)   -- RGB32, BB8A
        if not bpp then error("slow path") end
        local p = ffi.cast("uint8_t*", bb.data)
        local w, h, stride = bb:getWidth(), bb:getHeight(), tonumber(bb.stride)
        local floor = math.floor
        for y = 0, h - 1 do
            local row = p + y * stride
            for x = 0, w - 1 do
                local o = x * bpp
                local a = row[o + bpp - 1]
                if a > 0 and a < 255 then
                    local k = 255 / a
                    for c = 0, bpp - 2 do
                        local v = floor(row[o + c] * k + 0.5)
                        row[o + c] = v > 255 and 255 or v
                    end
                end
            end
        end
    end)
    if done then return end
    pcall(function()
        for yy = 0, bb:getHeight() - 1 do
            for xx = 0, bb:getWidth() - 1 do
                local p = bb:getPixelP(xx, yy)
                local a = p.alpha
                if a and a > 0 and a < 255 then
                    p.r = math.min(255, math.floor(p.r * 255 / a + 0.5))
                    p.g = math.min(255, math.floor(p.g * 255 / a + 0.5))
                    p.b = math.min(255, math.floor(p.b * 255 / a + 0.5))
                end
            end
        end
    end)
end

local function defaultRender(path, w, h)
    local RenderImage = require("ui/renderimage")
    if path:lower():match("%.svg$") then
        -- NanoSVG hands back straight alpha (is_straight true); MuPDF, when it
        -- renders the SVG instead, premultiplied.
        local bb, is_straight = RenderImage:renderSVGImageFile(path, w, h)
        if bb and not is_straight then M.unpremultiply(bb) end
        return bb
    end
    -- A raster. want_frames FALSE: asking for frames hands back a list of
    -- functions instead of a blitbuffer, which is an animation's shape, not an
    -- ornament's. The renderer scales to the size we ask for, so a small PNG
    -- is upscaled to the shelf's standard ornament height exactly as an SVG
    -- would be (maintainer's call: every file a reader drops in shows up).
    local bb = RenderImage:renderImageFile(path, false, w, h)
    if bb then M.unpremultiply(bb) end
    return bb
end
-- ONE DECODE PER PREVIEW. A preview (bookshelf_ornament_browser.preview,
-- the collection's cards and the Theme library's heroes) needs the piece's
-- content box before it knows the size to render at, and both came from
-- decoding the file: the 96px probe, then the render, ~145ms each for a PNG
-- on a PW5 (measured 2026-10-08), since MuPDF decodes a PNG at its own size
-- whatever size is asked and scales after. contentBox(entry, true) decodes a
-- PNG once at its own size and holds it; the probe and the next render of
-- that piece are scaled from it with the scaler the decoder's own scaling
-- uses (mupdf.renderImage is fz_scale_pixmap over the full-size pixmap, as
-- mupdf.scaleBlitBuffer is), so both come out as they did. Held for that
-- one render only: a full-size decode is big (up to the 8 MP cap).
M._held = nil          -- { path, bb }: premultiplied, as MuPDF decodes
M._decodeFull = nil    -- seam: function(path) -> bb at the file's own size
M._scale = nil         -- seam: function(bb, w, h) -> a new bb at w x h

-- canHold(path): a PNG, through the default decoder (a test's M._render
-- stands for both decodes, so it keeps them apart). An SVG is rasterised at
-- the size asked, so it has no full-size decode to share.
local function canHold(path)
    if not (type(path) == "string" and path:lower():match("%.png$")) then return false end
    return M._decodeFull ~= nil or M._render == nil
end

local function decodeFull(path)
    if M._decodeFull then return M._decodeFull(path) end
    return require("ui/renderimage"):renderImageFile(path, false)
end

local function scaledCopy(bb, w, h)
    if M._scale then return M._scale(bb, w, h) end
    if bb:getWidth() == w and bb:getHeight() == h then return bb:copy() end
    return require("ffi/mupdf").scaleBlitBuffer(bb, w, h)
end

-- releaseHeld(): free the held decode (preview, once its render is made).
function M.releaseHeld()
    local held = M._held
    M._held = nil
    if held and held.bb and held.bb.free then pcall(function() held.bb:free() end) end
end

-- holds(entry) -> a full-size decode of that piece is held for its render.
function M.holds(entry)
    return M._held ~= nil and type(entry) == "table" and M._held.path == entry.path
end

-- fromHeld(path, w, h) -> the render scaled from the held decode, which goes
-- (one render each), or nil when none is held for that path.
local function fromHeld(path, w, h)
    local held = M._held
    if not (held and held.path == path) then return nil end
    M._held = nil
    local ok, bb = pcall(function()
        local out = scaledCopy(held.bb, w, h)
        if out then M.unpremultiply(out) end
        return out
    end)
    if held.bb.free then pcall(function() held.bb:free() end) end
    return ok and bb or nil
end

-- render(entry, w, h, inverting) -> a bitmap ready to blit, or nil.
--
-- Two axes, as everywhere else on the shelf. `inverting` is the FRAME: the
-- device's night mode, which flips every pixel after we paint. The LOOK is
-- the theme (CoverProgress.theme), which can be dark with the frame not
-- inverting at all. The pieces:
--   chalk          - should this ornament DISPLAY inverted? Only an
--                    .invert-flagged one, on a grey panel, with no picture
--                    behind it, and only when the look is dark. A colour
--                    panel always gets the colours as drawn (an inverted
--                    green plant is magenta), and over a picture nothing
--                    inverts: the picture is pre-inverted and displays the
--                    same in both modes, so a plant flipping to its negative
--                    in front of it would be the only thing that changed
--                    (maintainer).
--   paint inverted - what has to be in the BUFFER for that to display: the
--                    wanted look, flipped again if the frame will flip it.
-- Reading only the frame here meant that under the shelf's own dark theme
-- by day a chalk ornament painted its authored dark silhouette onto a black
-- plank. The cache is keyed on what was painted, the one thing that
-- distinguishes two renders of one file at one size. RGB32 invert keeps the
-- alpha, so the shelf still shows through.
function M.render(entry, w, h, inverting, mirror)
    inverting = inverting and true or false
    local dark = inverting
    pcall(function()
        local CP = require("lib/bookshelf_cover_progress")
        if CP and CP.theme then
            local d = CP.theme()
            if type(d) == "boolean" then dark = d end
        end
    end)
    local picture = false
    pcall(function()
        local W = require("lib/bookshelf_wallpaper")
        picture = W.isShowing and W.isShowing() or false
        -- A picture shown as its negative at night is a dark ground like any
        -- other, so a chalk ornament goes light on it as it would on the page.
        if picture and W.showsNegative then
            local ok_s, Screen = pcall(function() return require("device").screen end)
            local frame = ok_s and Screen and Screen.night_mode and true or false
            if W.showsNegative(frame) then picture = false end
        end
    end)
    local chalk = entry.night_invert and not M.hasColorScreen()
                  and not picture and dark
    local paint_inverted = (chalk and true or false) ~= inverting
    local key = entry.path .. "|" .. w .. "x" .. h .. (paint_inverted and "|i" or "")
                .. (mirror and "|m" or "")
    local bb = M._cache[key]
    if bb then return bb end
    local ok, res = true, fromHeld(entry.path, w, h)
    if not res then ok, res = pcall(M._render or defaultRender, entry.path, w, h) end
    if not ok or not res then
        logger.dbg("[bookshelf] ornament render failed:", entry.path)
        return nil
    end
    bb = res
    if paint_inverted and bb.invertRect then
        pcall(function() bb:invertRect(0, 0, bb:getWidth(), bb:getHeight()) end)
    end
    if mirror then bb = M.flipped(bb) or bb end
    M._cache[key] = bb
    M._cache_order[#M._cache_order + 1] = key
    while #M._cache_order > M.CACHE_MAX do
        local old = table.remove(M._cache_order, 1)
        local ob = M._cache[old]
        M._cache[old] = nil
        if ob and ob.free then pcall(function() ob:free() end) end
    end
    return bb
end

-- flipped(bb) -> a left-to-right mirror of bb (bb itself is freed), or nil.
-- Blitbuffer has no flip; a column at a time through blitFrom is a plain
-- copy (alpha included) and runs once per size, before the cache keeps it.
function M.flipped(bb)
    local ok, out = pcall(function()
        local BB = require("ffi/blitbuffer")
        local w, h = bb:getWidth(), bb:getHeight()
        local dst = BB.new(w, h, bb:getType())
        for x = 0, w - 1 do dst:blitFrom(bb, w - 1 - x, 0, x, 0, 1, h) end
        return dst
    end)
    if not ok or not out then return nil end
    if bb.free then pcall(function() bb:free() end) end
    return out
end

-- contentBox(entry) -> l, t, r, b as fractions (0..1) of the image, the part
-- that is not transparent; nil when it cannot tell (no alpha, render failed).
-- An ornament's file carries transparent room on purpose (top padding sets
-- its height against the books, side padding keeps it off them), which is
-- right on the shelf and wasted space in the browser's preview. Found from a
-- small render, so it is cheap, and remembered per file for the session.
-- hold: a PNG is decoded once at its own size and the probe scaled from it,
-- the decode held for the render that follows (ONE DECODE PER PREVIEW).
M.CONTENT_PROBE = 96
M._content = {}
function M.contentBox(entry, hold)
    local key = entry.path .. "|" .. tostring(entry.aspect)
    local hit = M._content[key]
    if hit ~= nil then
        if hit == false then return nil end
        return hit[1], hit[2], hit[3], hit[4]
    end
    local box = false
    local aspect = (entry.aspect and entry.aspect > 0) and entry.aspect or 1
    local h = M.CONTENT_PROBE
    local w = math.max(1, math.floor(h * aspect + 0.5))
    local ok, bb
    if hold and canHold(entry.path) then
        M.releaseHeld()
        local okf, full = pcall(decodeFull, entry.path)
        if okf and full then
            M._held = { path = entry.path, bb = full }
            -- Premultiplied, as the probe never was: only its alpha is read.
            ok, bb = pcall(scaledCopy, full, w, h)
        end
    end
    if not (ok and bb) then ok, bb = pcall(M._render or defaultRender, entry.path, w, h) end
    if ok and bb then
        pcall(function()
            local bw, bh = bb:getWidth(), bb:getHeight()
            if bb:getPixel(0, 0).alpha == nil then return end
            local l, t, r, b = bw, bh, -1, -1
            for y = 0, bh - 1 do
                for x = 0, bw - 1 do
                    if bb:getPixel(x, y).alpha > 24 then
                        if x < l then l = x end
                        if x > r then r = x end
                        if y < t then t = y end
                        if y > b then b = y end
                    end
                end
            end
            if r >= l and b >= t then
                box = { l / bw, t / bh, (r + 1) / bw, (b + 1) / bh }
            end
        end)
        if bb.free then pcall(function() bb:free() end) end
    end
    M._content[key] = box
    if not box then return nil end
    return box[1], box[2], box[3], box[4]
end

-- The widget: blits the cached render at paint time. Inert to gestures.
-- The piece on the shelf. It takes a long-press (its menu) and, when it has
-- a tap action, a tap; anything else falls through to the shelf. The shelf
-- hands the handlers in once (M.handlers = { hold = fn(entry), tap =
-- fn(entry) }), since a piece knows nothing of the widget it stands in.
local ok_ic, InputContainer = pcall(require, "ui/widget/container/inputcontainer")
M.handlers = {}
M.Ornament = ((ok_ic and InputContainer) or Widget):extend{
    placement = nil,
    night     = false,
}

function M.Ornament:init()
    local p = self.placement
    self.dimen = require("ui/geometry"):new{ w = p.w, h = p.h }
    local ok_g, GestureRange = pcall(require, "ui/gesturerange")
    if ok_g and GestureRange then
        self.ges_events = {
            HoldOrnament = { GestureRange:new{ ges = "hold", range = self.dimen } },
            TapOrnament  = { GestureRange:new{ ges = "tap",  range = self.dimen } },
        }
    end
end

-- hits(p, dimen, pos, blocked) -> does a gesture at pos land on the piece?
-- Only on its DRAWING (contentBox: the file's transparent room and soft glow
-- don't count), and never where the shelf says a control lives (blocked(pos):
-- the footer). Before this a piece's whole box took gestures, so one in the
-- bottom-left slot ate taps on the start-menu button (maintainer, PW5).
function M.hits(p, dimen, pos, blocked)
    if not (pos and dimen and dimen.x and dimen.y) then return true end
    if blocked and blocked(pos) then return false end
    local l, t, r, b = M.contentBox(p.entry)
    if not (l and t and r and b) then return true end
    if p.mirror then l, r = 1 - r, 1 - l end
    local w, h = dimen.w or p.w, dimen.h or p.h
    local fx, fy = (pos.x - dimen.x) / math.max(1, w), (pos.y - dimen.y) / math.max(1, h)
    return fx >= l and fx <= r and fy >= t and fy <= b
end

function M.Ornament:onHoldOrnament(_arg, ges)
    local h = M.handlers.hold
    if not h then return false end
    if not M.hits(self.placement, self.dimen, ges and ges.pos, M.handlers.blocked) then return false end
    return h(self.placement.entry, self.placement, self.dimen) and true or false
end

function M.Ornament:onTapOrnament(_arg, ges)
    local h = M.handlers.tap
    if not (h and self.placement.entry.tap) then return false end
    if not M.hits(self.placement, self.dimen, ges and ges.pos, M.handlers.blocked) then return false end
    return h(self.placement.entry) and true or false
end

function M.Ornament:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    M.paintPlacement(bb, x, y, self.placement, self.night)
end

-- paintPlacement(bb, x, y, p, night): a placement's picture at x, y. The
-- shelf's pieces and the long-press menu's preview both paint through here.
-- A placement with a crop (the menu's picture) paints only the drawing.
function M.paintPlacement(bb, x, y, p, night)
    local img = M.render(p.entry, p.w, p.h, night, p.mirror)
    if not img then return end
    local c = p.crop
    pcall(function()
        if c then bb:alphablitFrom(img, x, y, c.x, c.y, c.w, c.h)
        else bb:alphablitFrom(img, x, y, 0, 0, p.w, p.h) end
    end)
end

-- silhouette(src, v, frac, BB) -> a copy of src in one flat grey v, at frac
-- of its alpha: the drawing's shape as a shadow (the long-press menu's
-- picture casts one). Pre-inverted like everything painted: v = 255 at night
-- shows dark on an inverting panel. Per pixel, so the caller caches it.
function M.silhouette(src, v, frac, BB)
    BB = BB or require("ffi/blitbuffer")
    local w, h = src:getWidth(), src:getHeight()
    local dst = BB.new(w, h, BB.TYPE_BBRGB32)
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local c = src:getPixel(x, y):getColorRGB32()
            local a = math.floor((c.alpha or 255) * frac)
            if a > 0 then dst:setPixel(x, y, BB.ColorRGB32(v, v, v, a)) end
        end
    end
    return dst
end

-- shadowFor(pl, night) -> the silhouette of a placement's picture, cached per
-- file, size, flip and night (a nudge redraws the menu; the picture's size
-- does not change with it). The long-press menu's picture and the Theme
-- library's heroes cast one: SHADOW_CACHE holds a page of heroes (four) and
-- the menu's with room to spare, so neither evicts the other on a repaint.
M.SHADOW_ALPHA = 0.35
M.SHADOW_CACHE = 8
M._shadows, M._shadow_order = {}, {}
function M.shadowFor(pl, night)
    local key = table.concat({ pl.entry.path or pl.entry.name, pl.w, pl.h,
                               tostring(pl.mirror), tostring(night) }, "|")
    if M._shadows[key] then return M._shadows[key] end
    local img = M.render(pl.entry, pl.w, pl.h, night, pl.mirror)
    if not img then return nil end
    local ok, sh = pcall(M.silhouette, img, night and 255 or 0, M.SHADOW_ALPHA)
    if not ok or not sh then return nil end
    M._shadows[key] = sh
    M._shadow_order[#M._shadow_order + 1] = key
    while #M._shadow_order > M.SHADOW_CACHE do
        local old = table.remove(M._shadow_order, 1)
        local ob = M._shadows[old]
        M._shadows[old] = nil
        if ob and ob.free then pcall(function() ob:free() end) end
    end
    return sh
end

-- previewPlacement(entry, h, max_w) -> the piece at a fixed height, as its
-- long-press menu shows it: its own shape and mirroring, not its size, lift
-- or hang on the shelf (those are what the menu is changing), and no wider
-- than the dialog.
-- Sized by the DRAWING (contentBox), not by the file: a PNG's transparent
-- room is right on the shelf and wasted here, as in the browser. pl.crop is
-- the drawn part, in the rendered picture's px.
function M.previewPlacement(entry, h, max_w)
    local proxy = setmetatable({ scale = 1, pad = 0, lift = 0, anchor = "bottom" },
                               { __index = entry })
    local l, t, r, b
    if entry.path then l, t, r, b = M.contentBox(entry) end
    local fw = (l and r) and math.max(0.05, r - l) or 1
    local fh = (t and b) and math.max(0.05, b - t) or 1
    -- Render big enough that the drawn part comes out h tall, no wider than
    -- max_w.
    local H = h / fh
    local aspect = entry.aspect or 1
    if H * aspect * fw > max_w then H = max_w / (aspect * fw) end
    local pl = M.place(proxy, math.floor(H * aspect + 0.5), H / M.HEIGHT_FRAC, {}, 1)
    pl.entry = entry
    if l then
        local cx, cy = math.floor(l * pl.w + 0.5), math.floor(t * pl.h + 0.5)
        pl.crop = { x = cx, y = cy,
                    w = math.max(1, math.floor(r * pl.w + 0.5) - cx),
                    h = math.max(1, math.floor(b * pl.h + 0.5) - cy) }
    end
    return pl
end

return M
