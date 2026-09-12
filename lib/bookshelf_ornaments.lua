-- bookshelf_ornaments.lua
-- Ornaments: user-supplied SVGs that stand in the gaps of a spine shelf, the
-- way a shop dresses a half-empty shelf with a plant or a figurine.
--
-- Deliberately undocumented -- a thing to find. The first spine render creates
-- <KOReader data dir>/icons/bookshelf.ornaments/ holding template.svg (a
-- potted plant, carrying the conventions in its comments) and cactus.svg; both
-- are ordinary ornaments, and any *.svg or *.png dropped beside them joins the
-- pool. The template's comment block is the whole documentation, so anything
-- a reader needs to know has to end up in there.
-- The template is written only when the folder is first created -- a user who
-- deletes the plant keeps it deleted.
--
-- INSIDE icons/ on purpose. That is KOReader's own user-asset directory (see
-- iconwidget.lua, which prepends <data dir>/icons to its search path), so it
-- is where a reader already goes to manage SVGs of their own. A
-- bookshelf.ornaments/ folder in the root of KOReader's storage would be one
-- plugin helping itself to the top level (maintainer ruling). Still namespaced
-- by the folder name, so it cannot collide with an icon a reader drops in, and
-- still outside plugins/, so a plugin update never touches it.
--
-- Conventions the SVG follows (also in the template): the bottom of the
-- viewBox is the plank surface the ornament stands on; a comment
-- "bookshelf:overhang=N" declares that the lowest N viewBox units hang below
-- the surface, over the plank's front (a paw, a trailing vine). Rendering is
-- KOReader's own RenderImage (nanosvg), so: bold solid shapes, no text, no
-- filters, no masks. Night mode pre-inverts the bitmap, alpha kept.
--
-- A PNG has none of those channels, so it gets the defaults: aspect from the
-- IHDR chunk, overhang always 0, and the night flag from the filename
-- (cat.invert.png). See parsePngHeader. Nothing else about the pipeline
-- differs -- same pick(), same cache, same widget -- because the only thing
-- that actually varies is how an entry is measured and which RenderImage call
-- draws it.
--
-- Placement is deterministic per page composition (seeded by the row's first
-- book and its index range), so an ornament stays put while a page is looked
-- at and changes across pages; about half the eligible gaps stay empty.

local logger = require("logger")
local Widget = require("ui/widget/widget")

local M = {}

-- KOReader does not create icons/ itself (it is absent from datastorage's
-- initDataDir list and iconwidget only reads it if it happens to exist), so
-- the parent is created alongside the ornaments folder.
M.PARENT        = "icons"
M.SUBDIR        = "bookshelf.ornaments"
M.TEMPLATE_NAME = "template.svg"
M.MIN_GAP_DP    = 48     -- a gap narrower than this stays empty
M.MIN_H_DP      = 28     -- and an ornament that would come out smaller isn't placed
M.MIN_H_FRAC    = 0.45   -- ...nor one shrunk (to fit a narrow gap) below this share
                         -- of the books' height: ornaments scale with the shelf,
                         -- a speck beside tall books looked wrong (user report)
M.HEIGHT_FRAC   = 0.8    -- height as a fraction of the books' stand height
M.CHANCE        = 0.5    -- fraction of eligible gaps that get an ornament
M.GROUP_CHANCE  = 0.08   -- ...and of the gaps BETWEEN sections on a grouping
                         -- chip, which are far more numerous: the same odds
                         -- there would put a plant between every other series
M.CACHE_MAX     = 12     -- rendered bitmaps kept (path x size x night)

M.TEMPLATE_SVG = [==[<?xml version="1.0" encoding="UTF-8"?>
<!--
  Bookshelf ornaments.

  Drop SVG or PNG files in this folder and they turn up now and then in the
  gaps on the spine shelf, standing on the plank like the books. This file is
  one: a potted plant (cactus.svg beside it is another). Copy it as a starting
  point, or delete either if you'd rather not see it; they won't come back.

  A PNG is the quick way in: any picture with a transparent background will
  do, and it stands on the plank at whatever shape it already is. It cannot
  hang over the front of the plank the way the drawing below can, and it is
  scaled to the shelf's height, so start from something reasonably large or
  it will look soft. To have a PNG shown light on a grey screen in night
  mode, put .invert before the extension: cat.invert.png.

  The rest of this file is about SVGs, which can do more.

  The rules of the shelf:

  - The BOTTOM of the viewBox is the plank surface. Your ornament stands on
    it, so leave nothing floating below the last shape.
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
  - Height follows the shelf; width follows your aspect ratio. Aim for
    something about as tall as a book and no wider than two or three.
  - Night mode: colour screens always show your colours as drawn. On a grey
    e-ink screen a dark shape would sit dark on the black night shelf, so
    the night line below asks for it to be shown light instead, like the
    spine titles. Keep it unless your ornament relies on being dark.
-->
<!-- bookshelf:overhang=0 -->
<!-- bookshelf:night=invert -->
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 60 100">
  <path d="M12 70 H48 L43 97 A13 2.8 0 0 1 17 97 Z" fill="#a4512c"/>
  <ellipse cx="30" cy="68" rx="19" ry="4" fill="#3a2114"/>
  <path d="M30 70 C22 54 8 50 6 36 C20 36 30 46 30 70 Z" fill="#3f8a45"/>
  <path d="M30 70 C38 52 52 48 54 32 C40 34 30 46 30 70 Z" fill="#2f7237"/>
  <path d="M30 70 C28 48 30 30 30 12 C34 30 34 50 30 70 Z" fill="#245a2b"/>
  <path d="M11 68 A19 4 0 0 0 49 68 V72 A19 4 0 0 1 11 72 Z" fill="#c8693d"/>
</svg>
]==]

M.CACTUS_NAME = "cactus.svg"
M.CACTUS_SVG = [==[<?xml version="1.0" encoding="UTF-8"?>
<!-- A cactus, in the same pot as the plant. See template.svg for the rules. -->
<!-- bookshelf:overhang=0 -->
<!-- bookshelf:night=invert -->
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 60 100">
  <path d="M14 74 H46 L42 97 A12 2.6 0 0 1 18 97 Z" fill="#a4512c"/>
  <ellipse cx="30" cy="72" rx="17" ry="3.6" fill="#3a2114"/>
  <rect x="24" y="18" width="12" height="56" rx="6" fill="#3f8a45"/>
  <path d="M30 56 H19 A5 5 0 0 1 14 51 V36" stroke="#3f8a45" stroke-width="8" stroke-linecap="round" fill="none"/>
  <path d="M30 44 H41 A5 5 0 0 0 46 39 V28" stroke="#3f8a45" stroke-width="8" stroke-linecap="round" fill="none"/>
  <path d="M27 26 l-3 -2 M33 26 l3 -2 M27 40 l-3 -2 M33 40 l3 -2 M27 64 l-3 -2 M33 64 l3 -2 M12 42 l-3 -1 M48 34 l3 -1" stroke="#f3e9b8" stroke-width="1.2" fill="none"/>
  <path d="M13 72 A17 3.6 0 0 0 47 72 V76 A17 3.6 0 0 1 13 76 Z" fill="#c8693d"/>
</svg>
]==]

-- Written when the folder is first created: the template (a plant) and a
-- cactus. Both are ordinary ornaments; deleting either sticks.
M.SEED_FILES = {
    { name = M.TEMPLATE_NAME, svg = M.TEMPLATE_SVG },
    { name = M.CACTUS_NAME,   svg = M.CACTUS_SVG },
}

-- ── Seams (tests replace these) ─────────────────────────────────────────────
M._data_dir = nil          -- override for the data dir
M._lfs      = nil          -- lazily required
M._render   = nil          -- function(path, w, h) -> bb, default RenderImage
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

function M.parentDir()
    local d = M.dataDir()
    return d and (d .. "/" .. M.PARENT) or nil
end

function M.dir()
    local p = M.parentDir()
    return p and (p .. "/" .. M.SUBDIR) or nil
end

-- ensureTemplate(): create the folder with the template in it, ONCE, and only
-- when the folder does not exist yet. An existing folder is never touched,
-- so a deleted template stays deleted.
M._ensured = false
function M.ensureTemplate()
    if M._ensured then return end
    M._ensured = true
    local d = M.dir()
    local fs = lfs()
    if not (d and fs) then return end
    if fs.attributes(d, "mode") ~= nil then return end
    -- The parent may not exist: KOReader only creates icons/ if a reader has
    -- made it themselves. mkdir is not recursive, so do it a level at a time,
    -- and tolerate an existing parent.
    local parent = M.parentDir()
    if parent and fs.attributes(parent, "mode") == nil then
        pcall(fs.mkdir, parent)
        if fs.attributes(parent, "mode") ~= "directory" then return end
    end
    local ok_mk = pcall(fs.mkdir, d)
    if not ok_mk or fs.attributes(d, "mode") ~= "directory" then return end
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
    local vb = text:match('viewBox%s*=%s*["\']%s*([%-%d%.]+)%s+([%-%d%.]+)%s+([%-%d%.]+)%s+([%-%d%.]+)')
    local w, h
    if vb then
        local _x, _y, sw, sh = text:match('viewBox%s*=%s*["\']%s*([%-%d%.]+)%s+([%-%d%.]+)%s+([%-%d%.]+)%s+([%-%d%.]+)')
        w, h = tonumber(sw), tonumber(sh)
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
-- OVERHANG IS ALWAYS 0. An SVG can declare that its lowest N units hang over
-- the plank's front, because it was drawn for this shelf. A PNG is a picture
-- someone had; it stands on the plank. That also leaves the full stand height
-- available to the artwork, and a transparent margin inside the image sets an
-- ornament back if it wants to be set back -- which is the maintainer's
-- reasoning for leaving the placement alone rather than pushing rasters to the
-- face-out plane.
--
-- The night flag is not in the bytes either; list() takes it from the
-- filename. It is returned false here so the shape matches parseHeader.
function M.parsePngHeader(bytes)
    if type(bytes) ~= "string" or #bytes < 24 then return nil end
    if bytes:sub(1, 8) ~= "\137PNG\r\n\026\n" then return nil end
    -- Refuse a file whose first chunk is not IHDR rather than hunting for it:
    -- that file is malformed, and reading on would take whatever bytes came
    -- next as a size.
    if bytes:sub(13, 16) ~= "IHDR" then return nil end
    local w, h = be32(bytes, 17), be32(bytes, 21)
    if not (w and h) or w <= 0 or h <= 0 then return nil end
    return w / h, 0, false
end

-- list() -> { {path, name, aspect, overhang}, ... } sorted by name. Re-read
-- when the folder's mtime changes (a file added or removed), else served
-- from the session cache.
M._list_cache = nil
M._list_mtime = nil
function M.list()
    local d = M.dir()
    local fs = lfs()
    if not (d and fs) then return {} end
    local mtime = fs.attributes(d, "modification")
    if not mtime then return {} end
    if M._list_cache and M._list_mtime == mtime then return M._list_cache end
    local out = {}
    local ok = pcall(function()
        for name in fs.dir(d) do
            local lname = name:lower()
            local is_png = lname:match("%.png$") ~= nil
            if is_png or lname:match("%.svg$") then
                local path = d .. "/" .. name
                -- "rb": a PNG's header is binary, and a text-mode read is only
                -- the same thing by POSIX's good grace.
                local f = io.open(path, "rb")
                if f then
                    local head = f:read(8192)
                    f:close()
                    local aspect, over, night_invert
                    if is_png then
                        aspect, over, night_invert = M.parsePngHeader(head)
                        -- A PNG has nowhere to write "bookshelf:night=invert",
                        -- so the name carries it: cat.invert.png. The only
                        -- channel that needs no tooling to use.
                        night_invert = lname:match("%.invert%.png$") ~= nil
                    else
                        aspect, over, night_invert = M.parseHeader(head)
                    end
                    if aspect then
                        out[#out + 1] = { path = path, name = name,
                                          aspect = aspect, overhang = over,
                                          night_invert = night_invert }
                    end
                end
            end
        end
    end)
    if not ok then out = {} end
    table.sort(out, function(a, b) return a.name < b.name end)
    M._list_cache, M._list_mtime = out, mtime
    return out
end

-- hash(s) -> non-negative integer, djb2 (LuaJIT-safe arithmetic).
function M.hash(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
    return h
end

-- pick(seed, gap_px, stand_h, entries, o) -> placement or nil.
--   gap_px  : free width at the row's end, already net of margins/padding
--   stand_h : the books' stand height (feet at y = stand_h in row coords)
--   entries : pool (default M.list())
--   o.min_gap, o.min_h : px floors; o.min_h_frac : floor as a share of
--   stand_h (default M.MIN_H_FRAC); o.max_below : how far below the feet the
--   overhang may reach (the plank's surface strip + front face)
-- rotationFor(seed, count) -> which ornament this seed gets.
--
-- A ROTATION rather than a hash of the seed. With two or three files in the
-- folder a hashed choice clusters badly -- the same one turns up several
-- times running while another goes unseen for pages (user report: "I've not
-- seen the cacti for a while") -- because the hash is spread over gaps, not
-- over the handful of ornaments it indexes. Handing them out in turn gives
-- every file an equal share by construction.
--
-- Stable per seed, because pick() runs again on every repaint of the same row
-- and an ornament that changed between repaints would flicker: a seed keeps
-- the place it was given, and only a seed never seen before advances the
-- rotation. Bounded, because page turns mint new seeds forever; on overflow
-- the map is dropped, which at worst re-rolls ornaments the reader has
-- paged away from.
M._rot   = {}
M._rot_n = 0
M.ROT_MAX = 512
function M.rotationFor(seed, count)
    if not count or count <= 1 then return 1 end
    local key = tostring(seed)
    local had = M._rot[key]
    if had then return ((had - 1) % count) + 1 end
    if M._rot_n >= M.ROT_MAX then M._rot, M._rot_n = {}, 0 end
    local idx = (M._rot_n % count) + 1
    M._rot[key] = idx
    M._rot_n = M._rot_n + 1
    return idx
end

-- Deterministic for a seed. placement = { entry, w, h, above, below, side }.
-- o.chance overrides M.CHANCE (the between-sections gaps use lower odds).
function M.pick(seed, gap_px, stand_h, entries, o)
    o = o or {}
    entries = entries or M.list()
    if #entries == 0 then return nil end
    if (gap_px or 0) < (o.min_gap or 0) then return nil end
    local h = M.hash(tostring(seed))
    local chance = o.chance or M.CHANCE
    if (h % 100) >= math.floor(chance * 100) then return nil end
    local entry = entries[M.rotationFor(seed, #entries)]
    local height = math.floor((stand_h or 0) * M.HEIGHT_FRAC)
    local width  = math.floor(height * entry.aspect)
    if width > gap_px then
        width  = gap_px
        height = math.floor(width / entry.aspect)
    end
    if entry.overhang > 0 and o.max_below then
        -- Shrink so the overhang never reaches past the plank's front.
        local below = height * entry.overhang
        if below > o.max_below then
            height = math.floor(o.max_below / entry.overhang)
            width  = math.floor(height * entry.aspect)
        end
    end
    local frac  = o.min_h_frac or M.MIN_H_FRAC
    local min_h = math.max(o.min_h or 1, math.floor((stand_h or 0) * frac))
    if height < min_h or width < 1 then return nil end
    local below = math.floor(height * entry.overhang)
    return {
        entry = entry, w = width, h = height,
        above = height - below, below = below,
        side  = (math.floor(h / 10000) % 2 == 0) and "right" or "left",
    }
end

-- render(entry, w, h, night) -> bb or nil. Cached; the cache owns its bbs
-- (widgets blit from it at paint and never keep the reference), so eviction
-- frees for real.
M._cache = {}
M._cache_order = {}
local function defaultRender(path, w, h)
    local RenderImage = require("ui/renderimage")
    if path:lower():match("%.svg$") then
        return RenderImage:renderSVGImageFile(path, w, h)
    end
    -- A raster. want_frames FALSE: asking for frames hands back a list of
    -- functions instead of a blitbuffer, which is an animation's shape, not an
    -- ornament's. The renderer scales to the size we ask for, so a small PNG
    -- is upscaled to the shelf's standard ornament height exactly as an SVG
    -- would be (maintainer's call: every file a reader drops in shows up).
    return RenderImage:renderImageFile(path, false, w, h)
end
function M.render(entry, w, h, night)
    local key = entry.path .. "|" .. w .. "x" .. h .. (night and "|n" or "")
    local bb = M._cache[key]
    if bb then return bb end
    local ok, res = pcall(M._render or defaultRender, entry.path, w, h)
    if not ok or not res then
        logger.dbg("[bookshelf] ornament render failed:", entry.path)
        return nil
    end
    bb = res
    -- Night mode inverts the whole display. Pre-inverting here keeps the
    -- artwork's colours faithful on screen (what covers do); an ornament
    -- flagged night=invert skips that on a GRAYSCALE panel and so DISPLAYS
    -- inverted -- a dark silhouette becomes chalk on the black shelf, like
    -- the spine titles. RGB32 invert keeps the alpha: the shelf shows through.
    -- Colour panels always get the colours as drawn: an inverted green plant
    -- would be magenta. The chalk look is a grayscale-panel affair.
    local chalk = entry.night_invert and not M.hasColorScreen()
    if night and not chalk and bb.invertRect then
        pcall(function() bb:invertRect(0, 0, bb:getWidth(), bb:getHeight()) end)
    end
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

function M.clearCache()
    for _k, bb in pairs(M._cache) do
        if bb and bb.free then pcall(function() bb:free() end) end
    end
    M._cache, M._cache_order = {}, {}
end

-- The widget: blits the cached render at paint time. Inert to gestures.
M.Ornament = Widget:extend{
    placement = nil,
    night     = false,
}

function M.Ornament:init()
    local p = self.placement
    self.dimen = require("ui/geometry"):new{ w = p.w, h = p.h }
end

function M.Ornament:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local p = self.placement
    local img = M.render(p.entry, p.w, p.h, self.night)
    if not img then return end
    pcall(function()
        bb:alphablitFrom(img, x, y, 0, 0, p.w, p.h)
    end)
end

return M
