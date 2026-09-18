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
-- THE ROW END, where width is the scarce thing and height is not.
--
-- The slot used to be a stand-height SQUARE. Anything wider than that was
-- shrunk to fit and, once the shrinking took it under MIN_H_FRAC, dropped --
-- so a broad ornament simply never appeared, and nothing on screen said why
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
-- A section break stays an aside: it widens a gap BETWEEN two books, in the
-- middle of a row, where a big piece reads as a hole rather than as an end
-- piece. A quarter of the row is as much as that is allowed to take.
M.ASIDE_SHARE   = 0.25
-- ...and a piece that spreads across a row-end slot may stand shorter than
-- one wedged into a gap between books. There is nothing above a row end to
-- crowd, so a low wide piece reads as an ornament rather than as a mistake,
-- where the same piece squeezed between two spines would not.
M.ROW_END_MIN_H_FRAC = 0.3
M.CHANCE        = 0.5    -- fraction of eligible gaps that get an ornament
M.GROUP_CHANCE  = 0.08   -- ...and of the gaps BETWEEN sections on a grouping
                         -- chip, which are far more numerous: the same odds
                         -- there would put a plant between every other series
M.CACHE_MAX     = 12     -- rendered bitmaps kept (path x size x night)

-- ── Frequency ──────────────────────────────────────────────────────
--
-- A MULTIPLIER on the odds above, not a replacement for them. The two base
-- chances are deliberately far apart -- a grouping chip's section breaks are
-- far more numerous than the gaps on a plain shelf, so identical odds would
-- put a plant between every other series -- and that relationship should hold
-- at every setting. Scaling both keeps it.
-- The PER-SHELF key: a chip carries its own number in its tab record. There
-- is deliberately no library-wide setting behind it. A default that every
-- shelf can override is a trap -- change the default later and nothing
-- happens, because by then every shelf has a value of its own (maintainer).
-- A shelf that has never been touched holds nothing and gets FREQ_DEFAULT.
M.FREQ_SETTING  = "ornament_frequency"
M.FREQ_DEFAULT  = 1

-- Above this, ornaments stop waiting for a gap wide enough and have a place
-- RESERVED at the end of each shelf (see SpineShelf.plan). Below it they are
-- opportunistic, which is what "occasional" has always meant here.
M.FREQ_RESERVE_AT = 1.5
-- The odds a RESERVED row end (see SpineShelf.plan) actually takes a piece,
-- before pick() scales them by the level: Often (2) keeps about half its
-- row ends, Lots (3) about five in six. Maintainer: "allow some rows even on
-- 'lots' setting to be occasionally filled with books". A row that rolls
-- nothing gives nothing up, so the odd bookless row costs no shelf.
M.ROW_END_CHANCE = 0.28

-- Odds that survive pick()'s scaling by the level, for the one placement that
-- is a promise rather than a roll. A plain 1 would not do: pick multiplies by
-- the frequency, so at Rarely a "certainty" of 1 comes back out as 0.5.
M.CHANCE_CERTAIN = math.huge

-- ── The group channel has its own curve ───────────────────────────────────
--
-- One level scales every channel, but the channels do not offer the same
-- NUMBER of chances. A plain shelf offers a couple of row ends per page; a
-- grouping chip can offer thirty section breaks. Multiplying both by the same
-- number gives the two complaints that arrived one after the other: nothing
-- at all on a packed plain shelf, and "set ornaments to rarely appear and I
-- have 4 on screen right now" on a chip full of small groups.
--
-- So the section-break channel is damped at the lower levels rather than
-- following the level directly. Per gap, and across a page holding thirty of
-- them:
--
--     level        per gap    expected on such a page
--     Rarely        1.6%              0.5
--     Often         5.6%              1.7
--     Always       16.0%              4.8
--
-- Not a per-screen CAP, which is what this wanted to be: the section-break
-- placement widens the gap it stands in, so it changes how many books fit,
-- and a cap counted per screen would give plan()'s two callers different
-- answers and break page boundaries again (see pageGuaranteed). A curve is a
-- pure function of the level, so both passes still agree.
M.GROUP_LEVEL = { [0] = 0, [0.5] = 0, [1] = 0.7, [2] = 2 }

-- The row end gets a curve too, and for the same reason: it is the channel
-- that was actually doing the work on a grouped chip (instrumented: six
-- placements at 0.28 against one section break at 0.08), so damping the
-- section breaks alone left Rarely at "9 ornaments across 11 pages... often 2
-- on a page", which is not rare.
--
-- ZERO at Rarely. That setting is then exactly its promise -- one page in
-- four stands a piece, and no other channel adds to it -- which is both rare
-- and predictable. Everything above it keeps a roll on top of the promise.
M.ROW_END_LEVEL = { [0] = 0, [0.5] = 0, [1] = 0.7, [2] = 2 }

local function levelFrom(curve)
    local f = M.frequency()
    local best, dist = 0, math.huge
    for level, mul in pairs(curve) do
        local d = math.abs(level - f)
        if d < dist then best, dist = mul, d end
    end
    return best
end

function M.rowEndLevel() return levelFrom(M.ROW_END_LEVEL) end

-- ── A ceiling for the channels that can have one ──────────────────────────
--
-- The curve above thins the section breaks, but the other channels keep
-- adding: the promised row end, the odd row end that rolls one anyway, the
-- leftover slack beside a short row. Measured on a grouped chip at Rarely
-- that came to about two a page, which is not what "rarely" promises.
--
-- So the channels that do NOT affect packing take a hard per-screen ceiling,
-- counting everything already standing (a section-break piece is placed
-- earlier, in plan, and counts against it). Only those channels: the
-- section-break piece widens the gap it stands in, so capping it would give
-- plan()'s two callers different answers and break page boundaries -- the
-- constraint that also ruled out a cap for the group channel.
M.PAGE_BUDGET = { [0] = 0, [0.5] = 1, [1] = 2, [2] = 4 }

function M.pageBudget()
    local f = M.frequency()
    local best, dist = 0, math.huge
    for level, n in pairs(M.PAGE_BUDGET) do
        local d = math.abs(level - f)
        if d < dist then best, dist = n, d end
    end
    return best
end

-- budgetLeft() -> how many more a screen may take, for budgeted channels.
function M.budgetLeft()
    local n = 0
    for _k in pairs(M._used) do n = n + 1 end
    return M.pageBudget() - n
end

function M.groupLevel() return levelFrom(M.GROUP_LEVEL) end

-- ── The per-PAGE promise ──────────────────────────────────────────────────
--
-- Every other placement is opportunistic: a piece appears where a gap happens
-- to be wide enough. On a plain shelf that can mean almost never. A shelf with
-- no groups has no section breaks at all -- the default Home shelf, flattened
-- folders, is exactly that -- and a densely packed row leaves a few dozen
-- pixels at its end, under MIN_GAP_DP. Both channels empty, at every level
-- below the top one: "set to often, there was only one ornament in total on
-- the whole shelf" (maintainer).
--
-- So a level also says how often a PAGE is promised a piece, and a promised
-- page stands one at a row end whether or not a gap turned up. One page in N:
M.PAGE_PERIOD = { [0] = 0, [0.5] = 4, [1] = 2, [2] = 1 }

function M.pagePeriod()
    local f = M.frequency()
    local best, dist = 0, math.huge
    for level, period in pairs(M.PAGE_PERIOD) do
        local d = math.abs(level - f)
        if d < dist then best, dist = period, d end
    end
    return best
end

-- pageGuaranteed(page) -> is THIS page promised a piece?
--
-- Hashed from the page's ORDINAL, not from its books. The ordinal is the one
-- thing both of plan()'s callers agree on: the render knows it, and the
-- pagination pass derives it from the row index. Seeding on anything else --
-- the page's first book, say -- gives the two passes different answers, and
-- they then pack differently and disagree about where pages start.
function M.pageGuaranteed(page)
    local period = M.pagePeriod()
    if period <= 0 then return false end
    if period == 1 then return true end
    return (M.hash("page:" .. tostring(page)) % period) == 0
end

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

-- ── One of each, per screen ───────────────────────────────────────
--
-- Placements are seeded independently -- a section break knows the two books
-- either side of it, a row end knows its row -- so nothing stopped two of them
-- landing on the same file. With a folder of three that is not unlikely; it
-- reads as a mistake rather than as decoration, which is the maintainer's
-- report.
--
-- A set rather than a counter: the question is only "is this one already
-- standing on this screen", and when every entry is spoken for a repeat still
-- beats a blank gap.
M._used = {}

-- beginScreen() -- forget what is standing, for a screen about to be built.
-- Called from SpineShelf.plan, which runs once per page and before any row.
function M.beginScreen()
    M._used = {}
end

-- reservesRowEnds() -> should a shelf keep a slot free at its end?
function M.reservesRowEnds()
    return M.frequency() >= M.FREQ_RESERVE_AT
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

function M.parentDir()
    local d = M.dataDir()
    return d and (d .. "/" .. M.PARENT) or nil
end

function M.dir()
    local p = M.parentDir()
    return p and (p .. "/" .. M.SUBDIR) or nil
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
M._ensured = false
function M.ensureTemplate()
    if M._ensured then return end
    M._ensured = true
    local d = M.dir()
    local fs = lfs()
    if not (d and fs) then return end
    if fs.attributes(d, "mode") ~= nil then
        pcall(refreshSeeds, d, fs)
        return
    end
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

function M.list()
    local now = M._clock()
    if M._list_cache and M._list_at and M.SCAN_TTL > 0
            and (now - M._list_at) < M.SCAN_TTL then
        return M._list_cache
    end
    local d = M.dir()
    local fs = lfs()
    if not (d and fs) then return {} end
    local names, key = AssetFolder.scan(fs, d, ORNAMENT_EXTS)
    if not names then return {} end
    M._list_at = now
    if M._list_cache and M._list_key == key then return M._list_cache end
    local out = {}
    local ok = pcall(function()
        for _i = 1, #names do
            local name = names[_i]
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
                        -- sizeOf rather than parseHeader: it falls back to the
                        -- renderer's own natural size when the header carries
                        -- no usable viewBox or width/height.
                        aspect, over, night_invert = M.sizeOf(path, head)
                    end
                    if aspect then
                        if not is_png and M.looksLikeWrappedBitmap(head) then
                            -- Kept in the pool deliberately: a hint off the
                            -- first 8KB, not a verdict. The line is what turns
                            -- "it just doesn't appear" into something
                            -- answerable.
                            logger.warn(
                                "[bookshelf] ornament looks like a picture "
                                .. "wrapped in an SVG rather than a drawing; "
                                .. "the renderer draws no <image>, so it will "
                                .. "come out blank. Drop the picture in as a "
                                .. ".png instead: " .. tostring(name))
                        end
                        out[#out + 1] = { path = path, name = name,
                                          aspect = aspect, overhang = over,
                                          night_invert = night_invert }
                    else
                        -- warn, not dbg: a dropped file is invisible on the
                        -- shelf and the reader has nothing to go on. This is
                        -- the one line that turns "my ornaments don't show up"
                        -- into an answerable question, and it fires at most
                        -- once per folder change (the list is mtime-cached).
                        logger.warn(
                            "[bookshelf] ornament skipped, could not be "
                            .. "sized: no viewBox or width/height in the first "
                            .. "8KB, and the renderer could not open it "
                            .. "either -- likely corrupt or not really an "
                            .. "SVG: " .. tostring(name))
                    end
                end
            end
        end
    end)
    if not ok then out = {} end
    -- AssetFolder.scan already sorted, so this is a no-op in practice; kept
    -- because "sorted by name" is what callers and the rotation rely on.
    table.sort(out, function(a, b) return a.name < b.name end)
    M._list_cache, M._list_key = out, key
    return out
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
-- Where in the folder the rotation begins.
--
-- It used to begin at the first file every time, so the first piece a reader
-- saw after every restart was whichever name sorts first, and a folder of
-- many ornaments always introduced itself in the same order. The rotation
-- still hands them out in turn -- that is what gives every file an equal
-- share -- it just no longer starts from the same end (maintainer: "it should
-- cycle through them all, starting at a random position in the file list").
--
-- os.time() rather than math.random: no reseeding, so nothing else that draws
-- random numbers is disturbed by when ornaments happen to be first asked for.
M._rot_start = nil
-- How far the rotation JUMPS between one turn and the next.
--
-- Taking turns in file order gives every piece an equal share, which is the
-- point, but it also means two turns handed out together land side by side in
-- the folder -- so the two rows of one page showed neighbouring files, and the
-- next page carried on from there ("png's 2 and 3 appear on page 2 and on
-- page 3"). Stepping by a number COPRIME to the set size still visits every
-- piece exactly once per cycle; it just does not visit them in folder order.
-- The first candidate coprime to the count wins, so the step adapts to
-- however many pieces happen to fit.
M.ROT_STRIDES = { 7, 5, 3, 2 }
local function gcd(a, b) while b ~= 0 do a, b = b, a % b end return a end
function M.rotationStride(count)
    for _i = 1, #M.ROT_STRIDES do
        local st = M.ROT_STRIDES[_i]
        if st < count and gcd(st, count) == 1 then return st end
    end
    return 1
end

function M.rotationFor(seed, count)
    if not count or count <= 1 then return 1 end
    if not M._rot_start then M._rot_start = os.time() end
    local key = tostring(seed)
    local had = M._rot[key]
    if had then return ((had - 1) % count) + 1 end
    if M._rot_n >= M.ROT_MAX then M._rot, M._rot_n = {}, 0 end
    local idx = ((M._rot_n * M.rotationStride(count) + M._rot_start) % count) + 1
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
    -- Scaled here rather than at each call site, so every placement -- the
    -- gaps on a plain shelf, the breaks between sections, the bare plank under
    -- a half-filled page -- moves together with one setting.
    -- o.level lets a channel use its own curve instead of the raw level; see
    -- M.GROUP_LEVEL for why the section breaks need one.
    -- A budgeted channel stops once the screen has its fill. Checked before
    -- the odds so a full screen costs nothing.
    if o.budgeted and M.budgetLeft() <= 0 then return nil end
    local level = o.level or M.frequency()
    local chance = (o.chance or M.CHANCE) * level
    if chance <= 0 then return nil end
    if chance < 1 and (h % 100) >= math.floor(chance * 100) then return nil end
    -- SIZE IS PART OF THE CHOICE, not a test applied after it.
    --
    -- This used to pick one entry -- the next in the rotation that was not
    -- already standing on this screen -- work out its size, and give up if it
    -- came out too small. With a folder of similar pieces that is invisible.
    -- With a mixed folder it means the WIDE ones never appear and, worse, the
    -- gaps they were chosen for stay empty: a reader who adds a dozen
    -- ornaments sees the same two over and over, because those two are the
    -- ones that happen to fit a row end (reported with twelve test pieces in
    -- the folder: "I still have cacti and the template plant on the same ends
    -- of the shelfs on pages 2 and 3").
    --
    -- So the walk keeps going until it finds one that FITS. The rotation still
    -- decides where the walk starts, which is what gives every file its turn;
    -- what changed is that an entry which cannot fit this particular gap steps
    -- aside instead of taking the slot and leaving it empty.
    local function sizeFor(entry)
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
        return width, height
    end
    -- WHICH PIECES CAN STAND HERE, before the rotation gets a say.
    --
    -- The rotation used to index the WHOLE folder and the fit test came
    -- afterwards: a turn that landed on a piece too wide for this gap walked
    -- forward to the next one that fitted. That sounds harmless and is not.
    -- The walk always steps the same way, so a piece that never fits hands its
    -- turn to the same successor every time, for good. Measured on the
    -- device with a fourteen-file folder: the two widest files (8:1 and 9:1,
    -- which come out 121px against a 124px floor) donated every one of their
    -- turns to entries 1 and 2, so those two stood three times as often as
    -- anything else and turned up on page after page -- "I still have cacti
    -- and the template plant on the same ends of the shelfs on pages 2 and 3".
    --
    -- Sizing everything first and rotating through what FITS gives every
    -- eligible piece exactly one turn in the cycle and takes the walk
    -- direction out of it. The fit set is a function of gap_px and stand_h,
    -- both of which the two planning passes agree on for a given seed, so the
    -- count behind the rotation is stable and the passes still match.
    local fits = {}
    for _i = 1, #entries do
        local cand = entries[_i]
        local w, h = sizeFor(cand)
        if w then fits[#fits + 1] = { entry = cand, w = w, h = h } end
    end
    if #fits == 0 then return nil end
    -- Seeded choice first, then walk on within the fitting set. Walking
    -- (rather than re-hashing) keeps the seed's influence: the same screen
    -- composed the same way still lands the same way.
    local idx = M.rotationFor(seed, #fits)
    local entry, width, height
    for step = 0, #fits - 1 do
        local cand = fits[((idx - 1 + step) % #fits) + 1]
        if not M._used[cand.entry.name or cand.entry.path] then
            entry, width, height = cand.entry, cand.w, cand.h
            break
        end
    end
    if not entry then
        -- Every fitting piece is already standing on this screen. A repeat
        -- still reads better than a hole, so take the turn's own piece.
        local cand = fits[idx]
        entry, width, height = cand.entry, cand.w, cand.h
    end
    local below = math.floor(height * entry.overhang)
    -- Marked only now: pick bails out above on several paths (too short, too
    -- narrow, the odds), and an entry that never stood must not be counted as
    -- standing -- that would push the next gap onto a different file for no
    -- reason and, with a small folder, exhaust the pool.
    M._used[entry.name or entry.path] = true
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
function M.render(entry, w, h, inverting)
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
    end)
    local chalk = entry.night_invert and not M.hasColorScreen()
                  and not picture and dark
    local paint_inverted = (chalk and true or false) ~= inverting
    local key = entry.path .. "|" .. w .. "x" .. h .. (paint_inverted and "|i" or "")
    local bb = M._cache[key]
    if bb then return bb end
    local ok, res = pcall(M._render or defaultRender, entry.path, w, h)
    if not ok or not res then
        logger.dbg("[bookshelf] ornament render failed:", entry.path)
        return nil
    end
    bb = res
    if paint_inverted and bb.invertRect then
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
