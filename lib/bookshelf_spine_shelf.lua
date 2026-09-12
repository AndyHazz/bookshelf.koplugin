-- bookshelf_spine_shelf.lua
-- The "spines" shelf style: books stood edge-on along a shelf line, the way
-- a real bookcase presents them. Width from page count, height from the
-- cover's true aspect, colour from the cover's average tone, the title
-- running up the spine, the series number printed level at the foot the way
-- an encyclopedia set numbers its volumes. Favourites can face outwards
-- (front cover shown), bookstore style.
--
-- NOT lib/bookshelf_spine_widget.lua: that file, despite its name, is the
-- COVER TILE of the cover-grid shelf and predates this view. The pure
-- geometry for this view lives in lib/bookshelf_spine_layout.lua.
--
-- ── Night mode ──────────────────────────────────────────────────────────────
-- Night mode inverts the framebuffer at refresh, so every colour derived
-- from a cover is painted PRE-INVERTED (fill and text together) to display
-- as itself -- the same constantInNight treatment stack_display's ribbon
-- uses. The shelf line is UI chrome and inverts with the rest of the UI.

local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local Screen         = Device.screen
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget     = require("ui/widget/textwidget")
local Widget         = require("ui/widget/widget")
local logger         = require("logger")
local BFont          = require("lib/bookshelf_fonts")
local CoverProgress  = require("lib/bookshelf_cover_progress")
local SpineLayout    = require("lib/bookshelf_spine_layout")

local SpineShelf = {}

local _gettime
do
    local ok, TimeVal = pcall(require, "ui/timeval")
    if ok and TimeVal and TimeVal.now then
        _gettime = function()
            local tv = TimeVal:now()
            return tv.sec + tv.usec / 1e6
        end
    else
        _gettime = os.clock
    end
end

-- Gap between neighbouring spines, dp. Books on a real shelf touch; a hair
-- of daylight keeps the hairline borders from doubling up.
SpineShelf.BOOK_GAP_DP = 2
-- Gap either side of a flattened group's run of spines, dp -- the visual
-- seam that keeps a series reading as a series once its stack is flattened.
SpineShelf.GROUP_GAP_DP = 12
-- ── The opening tilt's 2.5D model ───────────────────────────────────────────
-- One pair of angles drives every scale, so the face and the top move like
-- one rigid book instead of two tuned constants (user report: the fudged
-- 0.80 squash + arbitrary top growth didn't convince). Orthographic camera
-- pitched down by ALPHA (the same slightly-above viewpoint the standing
-- shelf implies: a spine of thickness D shows a top edge of D*sin(ALPHA),
-- which matches the standing page blocks at ALPHA ~= 12 deg). The book tips
-- forward by THETA about its bottom-front edge, so:
--   face height  scales by cos(ALPHA+THETA)/cos(ALPHA)
--   top depth    scales by sin(ALPHA+THETA)/sin(ALPHA)
--   and the tipped top edge is directly D*sin(ALPHA+THETA), where D is the
--   book's on-screen thickness -- the spine's WIDTH -- so fat books tip to
--   show broad tops and novellas barely any, with no separate rule.
-- ALPHA = 12 deg, THETA = 26 deg (face scale ~0.81, close to the 0.80 the
-- user calibrated by eye):
SpineShelf.TILT_FACE_SCALE = 0.806   -- cos(38 deg) / cos(12 deg)
SpineShelf.TILT_TOP_SCALE  = 2.96    -- sin(38 deg) / sin(12 deg)
SpineShelf.TILT_TOP_SIN    = 0.616   -- sin(38 deg): tipped top = thickness * this
-- The STANDING books' visible tops, from the same camera: a horizontal depth
-- d projects to d * sin(ALPHA) of screen height. What that depth IS differs
-- by how the book stands (user ruling): a face-out shows its THICKNESS above
-- the cover (page count), a spine-out shows its COVER WIDTH above the spine
-- (the book is turned 90 degrees, so its depth into the shelf is the cover).
-- Before this the face-out used an arbitrary 0.3 x thickness and the spine a
-- flat 5% of its height, so face-outs read as thick as spines were wide.
-- Single-sourced in lib/bookshelf_spine_layout.lua so the planner (which
-- sizes a face-out) and the painter (which carves a spine's top edge) cannot
-- drift apart. Kept as a field here because callers already read it.
SpineShelf.VIEW_SIN        = SpineLayout.VIEW_SIN   -- sin(12 deg)

-- The gap a FACE-OUT needs against anything it isn't serially attached to:
-- covers standing 2dp apart read as one slab (obvious once "All books"
-- face out). Between the book gap and the group gap on purpose -- group
-- boundaries must still read as the wider break. A face-out followed by
-- its own series' SPINES keeps the tight book gap: that adjacency is what
-- shows the run belongs to it (user ruling).
SpineShelf.FACE_GAP_DP = 8

-- Rotation for the title run. 90 = reads bottom-to-top ("running up the
-- spine"); if a build's rotatedCopy turns the other way, this is the one
-- constant to flip to 270.
local TITLE_ROTATION = 90

-- White text needs to stay legible on the cover-derived fill, so the fill's
-- Rec.601 luminance is capped here; anything brighter is scaled down
-- preserving hue. 110/255 keeps roughly a 4.5:1 contrast against white.
local MAX_FILL_LUMA = 110

local SAMPLE_STEPS = 8

-- ── Night helpers ───────────────────────────────────────────────────────────

local function _nightMode()
    local ok, night = pcall(function()
        return G_reader_settings and G_reader_settings:isTrue("night_mode")
    end)
    return ok and night or false
end

-- ── Book look: colour + aspect, cached per filepath ─────────────────────────

local _look_cache, _look_count = {}, 0
local LOOK_CACHE_MAX = 600

-- Hydrated stub answers (title / series number / pages / author), session
-- lifetime, keyed by filepath: group-member stubs are rebuilt on every
-- fetch, so per-record flags cannot carry this across page turns.
local _hydrate_cache = {}

-- Rendered-slot pixel cache, MODULE level: every page turn builds fresh
-- slot widgets, so a per-instance cache re-rendered the whole page (a
-- rotated-title TextWidget per book) on every turn. Keyed by book +
-- geometry + state; FIFO-evicted at ~3 pages' worth. The cache owns the
-- buffers; slots look up per paint and never free them.
local _render_cache, _render_order = {}, {}
local _render_bytes = 0
-- Byte budget, not a count: a count cap that fits a greyscale device
-- would balloon 4x on an RGB32 screen. ~5MB holds roughly three pages of
-- slots on a PW5.
local RENDER_CACHE_MAX_BYTES = 5 * 1024 * 1024

local function _bbBytes(bbuf)
    local ok, n = pcall(function()
        local bpp = 1
        local t = bbuf.getType and bbuf:getType()
        if t == Blitbuffer.TYPE_BBRGB32 then bpp = 4
        elseif t == Blitbuffer.TYPE_BBRGB24 then bpp = 3
        elseif t == Blitbuffer.TYPE_BBRGB16 or t == Blitbuffer.TYPE_BB8A then bpp = 2
        end
        return bbuf:getWidth() * bbuf:getHeight() * bpp
    end)
    return ok and n or 0
end

local function _renderCacheDrop(key)
    local old_bb = _render_cache[key]
    if not old_bb then return end
    _render_cache[key] = nil
    _render_bytes = _render_bytes - _bbBytes(old_bb)
    pcall(function() old_bb:free() end)
end

local function _renderCachePut(key, bbuf)
    if _render_cache[key] then
        _renderCacheDrop(key)
        _render_order[#_render_order + 1] = key
    else
        _render_order[#_render_order + 1] = key
    end
    _render_cache[key] = bbuf
    _render_bytes = _render_bytes + _bbBytes(bbuf)
    while _render_bytes > RENDER_CACHE_MAX_BYTES and #_render_order > 1 do
        local old_key = table.remove(_render_order, 1)
        _renderCacheDrop(old_key)
    end
end

-- invalidateRender(fp) — drop every cached render of one book (record
-- refresh, cover landing). fp is embedded at the front of each key.
function SpineShelf.invalidateRender(fp)
    if not fp then return end
    local prefix = fp .. "|"
    for i = #_render_order, 1, -1 do
        local key = _render_order[i]
        if key:sub(1, #prefix) == prefix then
            table.remove(_render_order, i)
            _renderCacheDrop(key)
        end
    end
end

-- Sampled looks, scanned page counts and cached read status persist across
-- launches in lib/bookshelf_book_facts_db (SQLite). They used to be one Lua
-- table in the settings file, rewritten in full on every flush -- see that
-- module's header for the measurements, and for why the 1200-book cap that
-- lived here had to go rather than be raised.
local PERSIST_KEY = "spine_looks"   -- the legacy settings key, migrated once
local FactsDB, _migrated

-- _facts() -> the store, or nil when it will not open (a shelf must still
-- paint without it; everything here degrades to "we know nothing yet").
local function _facts()
    if FactsDB == nil then
        local ok, m = pcall(require, "lib/bookshelf_book_facts_db")
        FactsDB = (ok and m) or false
    end
    if FactsDB and not _migrated then
        _migrated = true
        -- Lift whatever the settings file still holds, ONCE. The new store is
        -- written and committed before the old key is dropped, so a migration
        -- interrupted half way costs nothing and simply runs again next
        -- launch -- the worst case is doing it twice, which is idempotent.
        pcall(function()
            local BookshelfSettings = require("lib/bookshelf_settings_store")
            local legacy = BookshelfSettings.read(PERSIST_KEY)
            if type(legacy) ~= "table" or next(legacy) == nil then return end
            local n = FactsDB.migrateFrom(legacy)
            FactsDB.flush()
            BookshelfSettings.save(PERSIST_KEY, nil)
            if BookshelfSettings.flush then BookshelfSettings.flush() end
            logger.dbg(string.format(
                "[bookshelf] migrated %d books of shelf facts out of the settings file", n))
        end)
    end
    return FactsDB or nil
end

local function _flushLooks()
    local F = _facts()
    if F then F.flush() end
end

-- Public flush for bulk writers (the page-count scanner persists hundreds of
-- entries in one pass and must not lose them to a mid-scan crash). One
-- transaction, not one commit per book.
function SpineShelf.flushPersist()
    _flushLooks()
end

-- prefetchFacts(fps) -- one read for a whole page of books, so the per-book
-- lookups below are table hits. The plan calls this before it walks its
-- entries.
function SpineShelf.prefetchFacts(fps)
    local F = _facts()
    if F then pcall(F.prefetch, fps) end
end


-- cachedProgress / persistProgress: page count and read status ride the
-- same persisted table as the looks, so a page of spines costs its sidecar
-- reads ONCE ever rather than once per page turn (DocSettings:open is a
-- flash read + parse per book on device). sk marks 'status known', so a
-- never-opened book (status legitimately nil) doesn't re-read its sidecar
-- forever. Invalidation: dropLook (book closed / record refreshed) clears
-- the whole entry, so the next plan re-reads once and re-persists.
-- The persisted status is only as good as the sidecar it came from, and
-- sidecars change behind our back: an edit made before the invalidation
-- hook existed, or a sidecar synced in from another device. Each book's
-- entry stores the sidecar's mtime and is validated against it once per
-- session; a mismatch clears the entry so the next plan re-reads the truth.
local _progress_validated = {}

local function _sidecarMtime(fp)
    local ok, m = pcall(function()
        local DocSettings = require("docsettings")
        local sf = DocSettings:findSidecarFile(fp)
        if not sf then return 0 end
        local lfs = require("libs/libkoreader-lfs")
        return lfs.attributes(sf, "modification") or 0
    end)
    return ok and (m or 0) or 0
end

function SpineShelf.cachedProgress(fp)
    local F = fp and _facts()
    local e = F and F.get(fp)
    if not e then return nil, nil, false end
    if e.sk and not _progress_validated[fp] then
        _progress_validated[fp] = true
        if _sidecarMtime(fp) ~= (e.m or 0) then
            -- The sidecar moved under us: forget what we cached about its
            -- READ STATE. The scanned page count is not the sidecar's to
            -- invalidate, so it stays.
            F.put(fp, { s = false, sk = false, m = false })
            return nil, nil, false
        end
    end
    return e.p, e.s, e.sk == true
end

function SpineShelf.persistProgress(fp, pages, status)
    if not fp then return end
    local F = _facts()
    if not F then return end
    F.put(fp, {
        p  = pages or nil,
        s  = status or false,
        sk = true,
        m  = _sidecarMtime(fp),
    })
    _progress_validated[fp] = true
end

local function _sampleAverage(bb)
    local n, r, g, b = 0, 0, 0, 0
    local w, h = bb:getWidth(), bb:getHeight()
    if not (w and h and w > 1 and h > 1) then return nil end
    for sy = 0, SAMPLE_STEPS - 1 do
        for sx = 0, SAMPLE_STEPS - 1 do
            local px = math.floor((sx + 0.5) * w / SAMPLE_STEPS)
            local py = math.floor((sy + 0.5) * h / SAMPLE_STEPS)
            local p = bb:getPixel(px, py)
            local c = p and p.getColorRGB32 and p:getColorRGB32() or nil
            if c then
                n = n + 1
                r = r + c.r; g = g + c.g; b = b + c.b
            end
        end
    end
    if n == 0 then return nil end
    return r / n, g / n, b / n
end

local function _contrastClamp(r, g, b)
    local luma = 0.299 * r + 0.587 * g + 0.114 * b
    if luma > MAX_FILL_LUMA and luma > 0 then
        local f = MAX_FILL_LUMA / luma
        r, g, b = r * f, g * f, b * f
    end
    return math.floor(r + 0.5), math.floor(g + 0.5), math.floor(b + 0.5)
end

-- A coverless book still gets a stable, slightly varied cloth-binding tone
-- (hash of its label) rather than one uniform slab of grey.
local function _fallbackLook(label)
    local h = 5381
    for i = 1, #label do h = (h * 33 + label:byte(i)) % 16777213 end
    local base = 58 + (h % 40)
    local r = base + (h % 23)
    local g = base + (math.floor(h / 23) % 23)
    local b = base + (math.floor(h / 529) % 23)
    return { r = r, g = g, b = b, aspect = nil, sampled = false }
end

local function _aspectFromSizetag(tag)
    if type(tag) ~= "string" then return nil end
    local w, h = tag:match("^(%d+)x(%d+)$")
    w, h = tonumber(w), tonumber(h)
    if w and h and w > 0 then return h / w end
    return nil
end

-- bookLook(book) -> { r, g, b, aspect|nil, sampled }
-- Day-mode colour values; painters apply the night pre-invert.
function SpineShelf.bookLook(book)
    local fp = book and book.filepath
    local label = (book and (book.display_title or book.title)) or "?"
    if not fp then return _fallbackLook(label) end
    local hit = _look_cache[fp]
    if hit then return hit end

    -- A look sampled in a previous session skips the cover decode entirely.
    local F = _facts()
    local kept = F and F.get(fp)
    if type(kept) == "table" and kept.r then
        local look = { r = kept.r, g = kept.g, b = kept.b,
                       aspect = kept.a, sampled = true }
        look.aspect = look.aspect or _aspectFromSizetag(book.cover_sizetag)
        if _look_count >= LOOK_CACHE_MAX then
            _look_cache, _look_count = {}, 0
        end
        _look_cache[fp] = look
        _look_count = _look_count + 1
        return look
    end

    local look
    local ok = pcall(function()
        local bb, owned = nil, false
        if book.cover_bb then
            bb = book.cover_bb
        else
            local ok_repo, Repo = pcall(require, "lib/bookshelf_book_repository")
            if ok_repo and Repo and Repo.getCoverBB then
                bb = Repo.getCoverBB(fp)
                owned = bb ~= nil
            end
        end
        if bb then
            SpineShelf._samples = (SpineShelf._samples or 0) + 1
            local r, g, b = _sampleAverage(bb)
            local aspect
            local w, h = bb:getWidth(), bb:getHeight()
            if w and h and w > 0 then aspect = h / w end
            if owned and bb.free then bb:free() end
            if r then
                r, g, b = _contrastClamp(r, g, b)
                look = { r = r, g = g, b = b, aspect = aspect, sampled = true }
            elseif aspect then
                look = _fallbackLook(label)
                look.aspect = aspect
            end
        end
    end)
    if not ok or not look then
        look = _fallbackLook(label)
    end
    look.aspect = look.aspect or _aspectFromSizetag(book.cover_sizetag)

    -- Only a real sample is worth keeping. A fallback usually means the
    -- cover just isn't EXTRACTED yet (first run, BIM still working) --
    -- caching it would pin the placeholder tone past the repaint that
    -- follows extraction.
    if look.sampled then
        if _look_count >= LOOK_CACHE_MAX then
            _look_cache, _look_count = {}, 0
        end
        _look_cache[fp] = look
        _look_count = _look_count + 1
        local F = _facts()
        if F then
            F.put(fp, { r = look.r, g = look.g, b = look.b, a = look.aspect })
        end
    end
    return look
end

-- invalidateBook(fp) — one entry point for 'this book's metadata changed':
-- drops the persisted look/progress, the hydration answers, and every
-- cached render, so the next plan and paint rebuild it all fresh.
function SpineShelf.invalidateBook(fp)
    if not fp then return end
    SpineShelf.dropLook(fp)
    _hydrate_cache[fp] = nil
    _progress_validated[fp] = nil
    SpineShelf.invalidateRender(fp)
end

-- clearScannedPageCounts() -> number of books cleared
-- Drops the counts the "Extract page counts" scan produced, and only those:
-- the sampled colours and cached status stay, so the shelf does not go cold.
-- Counts already written into a book's own sidecar are KOReader's to keep
-- (maintainer's ruling) and are untouched.
function SpineShelf.clearScannedPageCounts()
    local F = _facts()
    if not F then return 0 end
    local n = 0
    pcall(function() n = F.clearPageCounts() or 0 end)
    _look_cache, _look_count = {}, 0
    _progress_validated = {}
    return n
end

-- scannedPageCountTotal() -> how many books carry a scanned count.
function SpineShelf.scannedPageCountTotal()
    local F = _facts()
    if not F then return 0 end
    local n = 0
    pcall(function() n = F.countPageCounts() or 0 end)
    return n
end

function SpineShelf.dropLook(fp)
    if fp and _look_cache[fp] then
        _look_cache[fp] = nil
        _look_count = math.max(0, _look_count - 1)
    end
    if fp then
        local F = _facts()
        if F then F.drop(fp) end
    end
end

-- ── Favourites ──────────────────────────────────────────────────────────────

local function _isFavourite(fp)
    if not fp then return false end
    local ok, rc = pcall(require, "readcollection")
    return ok and rc and rc.coll and rc.coll.favorites
           and rc.coll.favorites[fp] ~= nil or false
end

-- ── Paint helpers ───────────────────────────────────────────────────────────

local function _fillColor(look, night)
    local r, g, b = look.r, look.g, look.b
    if night then r, g, b = 255 - r, 255 - g, 255 - b end
    return Blitbuffer.ColorRGB32(r, g, b, 0xFF)
end

local function _textColor(night)
    -- Painted pre-inverted in night mode so it always DISPLAYS white.
    return night and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
end

-- The spine gradient: darker tint at the left edge to lighter at the right,
-- a very slight rounding light (user request). D is the half-range; the
-- centre column is the base colour, so the contrast clamp still holds where
-- the text sits.
local GRAD_D = 0.13
-- The rotated title band's prefill must carry the same ramp; rotation maps
-- scratch rows to screen columns, and this flag picks the direction (flip
-- if a seam shows mirrored against the body).
local GRAD_BAND_FLIP = false

local function _rampF(col, w)
    local t = (w and w > 1) and (col / (w - 1)) or 0.5
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    return (1 - GRAD_D) + 2 * GRAD_D * t
end

-- The plank's base colour: the user's "Shelf plank" pick from the Colors
-- menu, light oak when unset -- a shelf should look like wood (user ruling;
-- on a grey panel this oak lands at about the same mid grey the old default
-- painted, so nothing changes there). Returned as plain rgb so the shading
-- tints can be computed from it. Used by the plank AND by the slots' foot
-- chamfers, which reveal the plank surface behind the book.
local function _plankRGB()
    local r, g, b = 0xB0, 0x80, 0x50
    pcall(function()
        local c = CoverProgress.resolvedColors().plank
        local rgb = c and c.getColorRGB32 and c:getColorRGB32()
        if rgb then r, g, b = rgb.r, rgb.g, rgb.b end
    end)
    return r, g, b
end

-- plankBandT(y_rel, surf_h) -> the lit fraction of the plank's top surface
-- at y_rel px below its far edge. ONE quantisation, shared by ShelfPlank and
-- by the slots' lift shadows, so the patch under a lifted book matches the
-- plank around it exactly.
function SpineShelf.plankBandT(y_rel, surf_h)
    local bands = 5
    local i = math.floor(y_rel * bands / math.max(1, surf_h))
    if i < 0 then i = 0 elseif i > bands - 1 then i = bands - 1 end
    return i / (bands - 1)
end

-- Plank colours are computed in DISPLAY space and pre-inverted for night
-- (constantInNight): painted literally, the frame invert flipped every
-- relationship - the lift shadow displayed LIGHTER than the surface and the
-- front face glowed. The resolved night plank colour (darker by default)
-- now displays exactly as designed.
local function _plankFinish(r, g, b)
    if _nightMode() then r, g, b = 255 - r, 255 - g, 255 - b end
    return Blitbuffer.ColorRGB32(
        math.floor(r + 0.5), math.floor(g + 0.5), math.floor(b + 0.5), 0xFF)
end

local function _plankShade(f)
    local r, g, b = _plankRGB()
    return _plankFinish(r * f, g * f, b * f)
end

-- The surface palette the user picked out of dark mode and asked to keep:
-- DARK bands, darkest at the BACK and lightening toward the front edge
-- (base x0.38 far, x0.62 near), then the bright edge line and the mid-light
-- front face -- lit from the front, receding into shade. mul darkens a band
-- further for the lift shadows.
local function _plankBandColor(y_rel, surf_h, mul)
    local t = SpineShelf.plankBandT(y_rel, surf_h)
    -- x0.50 back to x0.95 front: the narrower span read flat on e-ink's 16
    -- greys (user report), so the front stretches nearly to the base tone
    -- while the back stays where it was; the bright edge line and the
    -- lit front face still top it.
    local f = (0.50 + 0.45 * t) * (mul or 1)
    return _plankShade(f)
end

-- ── The chamfer where a book meets the shelf ────────────────────────────────
--
-- A real book's corners are never square against a shelf, and taking the
-- corner pixel off lets the shelf show through -- which is what stops a row of
-- spines reading as a bar chart.
--
-- The corner is REMOVED: the pixel is replaced by what would be there if the
-- book were not. Two earlier attempts painted a shadowed plank tone into it,
-- which read as nothing at all against the book's own dark border, and then a
-- bigger version of the same, which read as a notch cut into a square foot
-- (maintainer, both times).
--
-- It cannot be done by copying what is underneath, which was the obvious
-- answer: a spine renders into its OWN offscreen buffer (see the render
-- cache), filled with the page ground and blitted opaquely, so nothing behind
-- it is visible to this code at all. Reading a pixel there returns the page
-- ground or uninitialised memory, not the plank. The colour is therefore
-- computed the same way the lifted book's under-strip reproduces the plank --
-- _plankBandColor with the same quantisation -- so the cut matches the shelf
-- it exposes instead of approximating it.
--
-- behind(yy) -> the colour the shelf shows at that row: the plank's own band
-- where the surface reaches, the page ground above it (a lifted book's corner
-- shows the page, which is the point of keeping the cut when it lifts).
local function _behindAt(plank, slot_bottom, lifted)
    return function(yy)
        if plank and not lifted then
            local surf_h   = 3 * plank.b
            local surf_top = slot_bottom + plank.inset - surf_h
            if yy >= surf_top then
                -- The SHADOWED band, not the lit one. The plank a pixel below
                -- the book is in full light; the pixel the corner exposes is
                -- under the book, in its own contact shadow, and taking the
                -- lit tone read as a bright speck on the corner (maintainer).
                -- 0.72 is the same darkening the lifted book's contact patch
                -- uses, so a book's foot shadow is one value wherever it is
                -- drawn.
                return _plankBandColor(yy - surf_top, surf_h, 0.72)
            end
        end
        -- Page ground in PRE-INVERT space, matching the buffer the slot is
        -- filled with, so night mode inverts it with everything else.
        return Blitbuffer.ColorRGB32(0xFF, 0xFF, 0xFF, 0xFF)
    end
end

-- _cutFootCorners(bb, x, bottom, w, n, behind) -- n px square off each BOTTOM
-- corner. `bottom` is one past the book's last row.
local function _cutFootCorners(bb, x, bottom, w, n, behind)
    for dy = 0, n - 1 do
        local yy = bottom - 1 - dy
        local c = behind(yy)
        bb:paintRectRGB32(x, yy, n, 1, c)
        bb:paintRectRGB32(x + w - n, yy, n, 1, c)
    end
end

local function _plankLit(t, mul)
    local r, g, b = _plankRGB()
    r = r + (255 - r) * t
    g = g + (255 - g) * t
    b = b + (255 - b) * t
    if mul then r, g, b = r * mul, g * mul, b * mul end
    return _plankFinish(r, g, b)
end

-- Boards and the spine's outer border share ONE colour: the darkest shade
-- of the sampled cover colour (user ruling -- the black border clashed with
-- the look-coloured boards). paintBorder flattens colour to luminance, so
-- borders paint as four colour-safe rects.
local BOARD_SHADE = 0.45
-- How far the cover boards rise above the page block at the head -- the
-- binding's "square" -- as a fraction of the visible top edge. A real
-- hardback's is small; too much of one and the boards read as ears rather
-- than as the cover standing slightly proud of the paper.
local BOARD_LIP_FRAC = 0.10

local function _boardColor(look, night)
    local r = look.r * BOARD_SHADE
    local g = look.g * BOARD_SHADE
    local b = look.b * BOARD_SHADE
    if night then r, g, b = 255 - r, 255 - g, 255 - b end
    return Blitbuffer.ColorRGB32(
        math.floor(r + 0.5), math.floor(g + 0.5), math.floor(b + 0.5), 0xFF)
end

local function _paintBorderRGB32(bb, x, y, w, h, bw, c)
    bb:paintRectRGB32(x, y, w, bw, c)
    bb:paintRectRGB32(x, y + h - bw, w, bw, c)
    if h > 2 * bw then
        bb:paintRectRGB32(x, y + bw, bw, h - 2 * bw, c)
        bb:paintRectRGB32(x + w - bw, y + bw, bw, h - 2 * bw, c)
    end
end

local function _tintColor(look, f, night)
    local r = math.floor(math.min(255, look.r * f) + 0.5)
    local g = math.floor(math.min(255, look.g * f) + 0.5)
    local b = math.floor(math.min(255, look.b * f) + 0.5)
    if night then r, g, b = 255 - r, 255 - g, 255 - b end
    return Blitbuffer.ColorRGB32(r, g, b, 0xFF)
end

-- Rotated title: render horizontally into a scratch RGB32 buffer prefilled
-- with the spine colour (so glyph anti-aliasing blends into the right
-- ground), rotate the buffer, blit. Rotation cost is one copy of a
-- text-sized buffer.
local function _paintRotatedTitle(bb, x, y, run_len, band_w, text, face_size, look, night, author)
    if run_len < Screen:scaleBySize(14) or band_w < 8 then return end
    local ok, err = pcall(function()
        -- Shrink to fit: a narrow spine can't take the nominal size, so step
        -- the face down (never below 6dp) until the rendered line's height
        -- fits across the spine, rather than silently dropping the title.
        local face_name = BFont.getUIFontFace() or "cfont"
        local tw, sz
        local size = face_size
        while size >= 6 do
            tw = TextWidget:new{
                text      = text,
                face      = BFont:getFace(face_name, size),
                fgcolor   = _textColor(night),
                max_width = run_len,
                padding   = 0,
            }
            sz = tw:getSize()
            if sz.h <= band_w then break end
            tw:free()
            tw = nil
            size = size - 2
        end
        if not tw then return end
        local title_w = math.min(sz.w, run_len)
        local sh = sz.h
        if title_w < 1 or sh < 1 then tw:free() return end
        -- The author rides the same band in a smaller face, above the title
        -- the way a printed spine sets it -- only when the title left it a
        -- worthwhile stretch of spine to sit on.
        local atw, asz, author_w = nil, nil, 0
        local seg_gap = Screen:scaleBySize(10)
        if author and author ~= "" then
            local avail = run_len - title_w - seg_gap
            if avail >= Screen:scaleBySize(28) then
                local asize = math.max(6, size - 3)
                atw = TextWidget:new{
                    text      = author,
                    face      = BFont:getFace(face_name, asize),
                    fgcolor   = _textColor(night),
                    max_width = avail,
                    padding   = 0,
                }
                asz = atw:getSize()
                if asz.w < 1 or asz.h > band_w then
                    atw:free()
                    atw = nil
                else
                    author_w = math.min(asz.w, avail)
                end
            end
        end
        local sw = title_w + (atw and (seg_gap + author_w) or 0)
        local scratch = Blitbuffer.new(sw, sh, Blitbuffer.TYPE_BBRGB32)
        -- NOT scratch:fill() -- fill flattens its colour argument to
        -- luminance via getColor8. Each scratch ROW becomes a screen COLUMN
        -- after rotation, so the prefill carries the body's gradient ramp
        -- row-by-row -- a flat band would sit as a stripe on the gradient.
        local band_off = math.floor((band_w - sh) / 2)
        for ry = 0, sh - 1 do
            local jx = GRAD_BAND_FLIP and (sh - 1 - ry) or ry
            scratch:paintRectRGB32(0, ry, sw, 1,
                _tintColor(look, _rampF(band_off + jx, band_w), night))
        end
        tw:paintTo(scratch, 0, 0)
        tw:free()
        if atw then
            atw:paintTo(scratch, title_w + seg_gap,
                        math.floor((sh - asz.h) / 2))
            atw:free()
        end
        local rot = scratch:rotatedCopy(TITLE_ROTATION)
        scratch:free()
        local rw, rh = rot:getWidth(), rot:getHeight()
        -- Centre across the spine, centre along the run.
        local dx = x + math.floor((band_w - rw) / 2)
        local dy = y + math.floor((run_len - rh) / 2)
        bb:blitFrom(rot, dx, dy, 0, 0, rw, rh)
        rot:free()
    end)
    if not ok then
        logger.dbg("[bookshelf perf] spineshelf: title paint failed: " .. tostring(err))
    end
end

-- Level (unrotated) single line centred in the given box; returns height used.
local function _paintLevelText(bb, x, y, box_w, text, face, night)
    local used = 0
    pcall(function()
        local tw = TextWidget:new{
            text      = text,
            face      = face,
            fgcolor   = _textColor(night),
            max_width = box_w,
            padding   = 0,
        }
        local sz = tw:getSize()
        if sz.w >= 1 and sz.h >= 1 then
            tw:paintTo(bb, x + math.floor((box_w - sz.w) / 2), y)
            used = sz.h
        end
        tw:free()
    end)
    return used
end

local function _statusGlyph(book)
    if book and book._spine_status_checked and book.status == nil then
        -- Checked at plan time and genuinely never opened: nothing for
        -- decide() to say, and its lazy fallback would re-open the sidecar.
        return nil
    end
    local d
    local ok = pcall(function() d = CoverProgress.decide(book) end)
    if not ok or type(d) ~= "table" then return nil end
    if d.glyph == "in_progress" then return CoverProgress.GLYPH_BOOKMARK end
    if d.glyph == "complete_bookmark" or d.glyph == "complete_tickbox" then
        return CoverProgress.GLYPH_BOOKMARK_CHECK
    end
    if d.on_hold then return CoverProgress.GLYPH_PAUSE_CIRCLE end
    return nil
end

-- ── The slot widget ─────────────────────────────────────────────────────────
-- One book, spine-on (or face-out). Fully custom paint; the InputContainer
-- shell supplies tap/hold/double-tap over the slot's footprint.

local SpineBookSlot = InputContainer:extend{
    book       = nil,   -- the item: a book record OR a group (folder/stack)
    entry      = nil,   -- plan entry: { w, h, w_dp, look, face_out, label }
    width      = nil,   -- slot width px
    height     = nil,   -- row height px (spine stands on the bottom edge)
    callbacks  = nil,   -- the _shelfCallbacks table (on_book_tap, on_series_tap, ...)
    show_series = true,
    lift_headroom = 0, -- px of empty strip above the row a selected
                       -- book may rise into before it has to shrink
}

-- Route a gesture to the callback the item's kind wants -- the same
-- dispatch ShelfRow does across its per-kind branches, folded into one
-- lookup because every spine paints the same either way.
local function _itemCallback(cbs, item, gesture)
    if not (cbs and item) then return nil end
    if item.filepath then return cbs["on_book_" .. gesture] end
    local kind = item.kind
    if kind == "folder"   then return cbs["on_folder_" .. gesture] end
    if kind == "author"   then return cbs["on_author_" .. gesture] end
    if kind == "genre"    then return cbs["on_genre_" .. gesture] end
    if kind == "tag"      then return cbs["on_tag_" .. gesture] end
    if kind == "language" then return cbs["on_language_" .. gesture] end
    if kind == "opds_nav" then return cbs["on_opds_nav_" .. gesture] end
    if item.books or item.first_book then return cbs["on_series_" .. gesture] end
    return nil
end

function SpineBookSlot:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events = {
        Tap       = { GestureRange:new{ ges = "tap",        range = self.dimen } },
        Hold      = { GestureRange:new{ ges = "hold",       range = self.dimen } },
        DoubleTap = { GestureRange:new{ ges = "double_tap", range = self.dimen } },
    }
end

function SpineBookSlot:getSize() return self.dimen end

function SpineBookSlot:onTap()
    local cb = _itemCallback(self.callbacks, self.book, "tap")
    if cb then cb(self.book) return true end
end

function SpineBookSlot:onHold()
    local cb = _itemCallback(self.callbacks, self.book, "hold")
    if cb then cb(self.book) return true end
end

function SpineBookSlot:onDoubleTap()
    -- Books only: double tap opens directly (#271); groups have no "open".
    if self.book and self.book.filepath and self.callbacks
            and self.callbacks.on_book_open then
        self.callbacks.on_book_open(self.book)
        return true
    end
end

-- paintTo blits a cached offscreen render. Every setDirty on the shelf
-- repaints the WHOLE widget tree (the refresh region only limits the e-ink
-- update), and a spine render is expensive (a rotated-title TextWidget per
-- book) -- selection taps felt slow because ~30 titles re-rendered per tap.
-- The cache re-renders only when the slot's state key changes; book/look
-- refreshes go through invalidate().
function SpineBookSlot:_renderKey(night)
    local e = self.entry
    local fp = (self.book and self.book.filepath) or self.entry.label or "?"
    return table.concat({
        fp, self.width, self.height, e.w, e.h,
        self.is_selected and "s" or "-",
        self.is_bulk_selected and "B" or "-",
        night and "n" or "d",
        self.show_author == false and "A" or "a",
    }, "|")
end

function SpineBookSlot:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local night = _nightMode()
    local key = self:_renderKey(night)
    local cached = _render_cache[key]
    if not cached then
        local _tr = _gettime()
        local ok = pcall(function()
            -- Match the screen's buffer type: greyscale devices cache at
            -- 1 byte/px and flatten colour exactly once, colour screens
            -- keep RGB32.
            local btype = (Screen.bb and Screen.bb.getType and Screen.bb:getType())
                          or Blitbuffer.TYPE_BBRGB32
            local c = Blitbuffer.new(self.width, self.height, btype)
            -- Page ground, pre-invert space (white displays black in night
            -- via the frame invert, same as the shelf's own background).
            c:paintRectRGB32(0, 0, self.width, self.height,
                             Blitbuffer.ColorRGB32(0xFF, 0xFF, 0xFF, 0xFF))
            self:_renderInto(c, night)
            _renderCachePut(key, c)
            cached = c
        end)
        if not ok or not cached then
            -- Render straight to the target rather than showing nothing.
            self:_renderIntoAt(bb, x, y, night)
            return
        end
        SpineShelf._renders = (SpineShelf._renders or 0) + 1
        SpineShelf._render_ms = (SpineShelf._render_ms or 0)
                                + (_gettime() - _tr) * 1000
    end
    bb:blitFrom(cached, x, y, 0, 0, self.width, self.height)
end

function SpineBookSlot:invalidate()
    -- The pixel cache is module-level and keyed by book; drop every render
    -- of this one (state variants included).
    SpineShelf.invalidateRender(self.book and self.book.filepath)
end

function SpineBookSlot:free()
    -- Nothing owned per instance: renders belong to the module cache and
    -- outlive the widget precisely so page turns can reuse them.
end

function SpineBookSlot:_renderInto(bb, night)
    self:_renderIntoAt(bb, 0, 0, night)
end

function SpineBookSlot:_renderIntoAt(bb, x, y, night)
    local e = self.entry
    local spine_w = e.w
    local spine_h = math.min(e.h, self.height)
    -- Opening tilt (paintOpeningTilt's one-shot render, never cached): the
    -- book tips forward off the shelf. Face and top edge scale together
    -- from the module's one 2.5D model (see TILT_FACE_SCALE) -- the face
    -- foreshortens while the top edge opens up to thickness * sin of the
    -- tipped angle, its breadth coming from the spine's own width.
    local tilt = self._tilt
    local tilt_edge
    if tilt then
        local e0 = 0
        if spine_h >= Screen:scaleBySize(60) then
            e0 = math.floor(spine_h * 0.05)
            local e_min, e_max = Screen:scaleBySize(5), Screen:scaleBySize(14)
            if e0 < e_min then e0 = e_min end
            if e0 > e_max then e0 = e_max end
        end
        tilt_edge = math.max(Screen:scaleBySize(3),
                             math.floor(spine_w * SpineShelf.TILT_TOP_SIN))
        tilt_edge = math.min(tilt_edge, math.floor(spine_h * 0.35))
        local face = math.floor((spine_h - e0) * SpineShelf.TILT_FACE_SCALE)
        spine_h = math.max(Screen:scaleBySize(30), face + tilt_edge)
    end
    local top = y + self.height - spine_h

    -- Selected: the book is pulled up off the plank, the way a hand lifts
    -- it clear of the row -- with DAYLIGHT between its foot and the shelf
    -- (user ruling: the old fixed lift still overlapped the plank's top
    -- surface). The lift is the surface's height above the feet plus an
    -- air gap; a book too tall to have that headroom shrinks a few percent
    -- while held instead of staying overlapped.
    local lifted = false
    if self.is_selected or tilt then
        local pk = self.plank
        local clear = (pk and (3 * pk.b - pk.inset) or Screen:scaleBySize(18))
                      + Screen:scaleBySize(6)
        if tilt then
            -- The opening tilt CONTINUES the selection lift (user ruling):
            -- an unselected book jumps to the lifted height as it tips, a
            -- selected one rises a little further.
            clear = clear + Screen:scaleBySize(4)
        end
        -- The empty strip above this row -- the gap between shelves, or the
        -- pad under the chip bar for the first one. A book as tall as the
        -- shelf allows has no headroom inside its own slot, so it used to
        -- shrink while held; it rises into that strip instead, which is
        -- empty by construction and which the selection repaint already
        -- dirties (user ruling: "we can go into/overlap the padding for this
        -- selection effect"). Only a lift that STILL does not fit squashes.
        local head = self.lift_headroom or 0
        if spine_h > self.height + head - clear then
            spine_h = math.max(Screen:scaleBySize(40), self.height + head - clear)
        end
        top = y + self.height - spine_h - clear
        if top < y - head then top = y - head end
        lifted = true
    end

    -- ── The spine proper ────────────────────────────────────────────────
    local hairline = Screen:scaleBySize(1)
    if hairline < 1 then hairline = 1 end
    -- Top edge: the sliver of page block you see looking at a real shelf.
    -- Cover boards (spine colour) run up the sides and past the paper by a
    -- lip; between them, fine vertical stripes alternate paper tones. Lives
    -- INSIDE the book's allotted height, so layout is untouched; tiny
    -- spines skip it.
    local edge_h = 0
    if tilt then
        -- Sized above with the face, from the same tip angles.
        edge_h = tilt_edge
    elseif spine_h >= Screen:scaleBySize(60) then
        -- The spine-out book's depth into the shelf is its COVER WIDTH
        -- (height over aspect), foreshortened by the camera's pitch (see
        -- VIEW_SIN) -- not a fraction of its height, which made every spine
        -- show the same thin sliver regardless of the book behind it.
        local aspect = (e.look and e.look.aspect) or SpineLayout.DEFAULT_ASPECT
        edge_h = SpineLayout.topEdgeHeight(spine_h, aspect, Screen:scaleBySize(5))
    end
    -- Where the book landed in this render, for the tilt painter's shading
    -- pass (the face below the page block darkens as it tips away from the
    -- light; the block itself faces up and stays lit).
    self._render_spine_rect = { x = x, y = top, w = spine_w, h = spine_h,
                                edge = edge_h }
    local body_top = top + edge_h
    local body_h = spine_h - edge_h
    for i = 0, spine_w - 1 do
        bb:paintRectRGB32(x + i, body_top, 1, body_h,
                          _tintColor(e.look, _rampF(i, spine_w), night))
    end
    _paintBorderRGB32(bb, x, body_top, spine_w, spine_h - edge_h, hairline,
                      _boardColor(e.look, night))
    -- Soften the meeting with the plank: the bottom corner pixels come off,
    -- the hint of a chamfer where the book stands. Only while it STANDS --
    -- a lifted book floats in front of the page, and the plank-toned nicks
    -- read as white specks cut into its corners there.
    -- Kept when LIFTED too (maintainer request): the pixel is replaced by
    -- whatever is actually beneath the book, so a lifted book's corners show
    -- the page rather than a plank-toned speck -- which is what made the
    -- earlier painted version look wrong off the shelf.
    _cutFootCorners(bb, x, body_top + body_h, spine_w, hairline,
                    _behindAt(self.plank, y + self.height, lifted))
    -- A lifted book leaves its shadow on the plank where it stood. The
    -- under-strip REPRODUCES the plank's banded surface (same quantisation,
    -- via plankBandT) and darkens those same bands for the shadow, so the
    -- patch is indistinguishable from the shelf around it; above the
    -- surface's far edge the page ground stays. Row-by-row, but the render
    -- is cached per slot.
    if lifted and self.plank then
        local foot = body_top + body_h
        local slot_bottom = y + self.height
        local surf_h = 3 * self.plank.b
        local surf_top = slot_bottom + self.plank.inset - surf_h
        local start = math.max(foot, surf_top)
        local air_end = math.min(foot + math.max(2, hairline), slot_bottom)
        local ins = hairline * 2
        for yy = start, slot_bottom - 1 do
            if yy < air_end or spine_w <= 2 * ins then
                bb:paintRectRGB32(x, yy, spine_w, 1,
                                  _plankBandColor(yy - surf_top, surf_h))
            else
                local band = _plankBandColor(yy - surf_top, surf_h)
                bb:paintRectRGB32(x, yy, ins, 1, band)
                bb:paintRectRGB32(x + ins, yy, spine_w - 2 * ins, 1,
                                  _plankBandColor(yy - surf_top, surf_h, 0.72))
                bb:paintRectRGB32(x + spine_w - ins, yy, ins, 1, band)
            end
        end
    end
    if edge_h > 0 then
        local lip     = math.max(1, math.floor(edge_h * BOARD_LIP_FRAC))
        local board_w = math.max(2, math.min(Screen:scaleBySize(3),
                                             math.floor(spine_w * 0.1)))
        local function tone(v)
            if night then v = 255 - v end
            return Blitbuffer.ColorRGB32(v, v, v, 0xFF)
        end
        local sx0 = x + board_w
        local sw_edge = spine_w - 2 * board_w
        local sy0 = top + lip
        local sh_edge = edge_h - lip
        if sw_edge > 2 and sh_edge > 1 then
            -- Stripe pitch and tones sized for e-ink: 1px alternation at
            -- 300dpi dithers into a wash (user report), so the stripes are
            -- DPI-scaled and the tones far enough apart to survive 16 greys.
            -- Fine page LINES on paper. Tighter than the comb-fix pass, with
            -- widths that VARY per line (1px up to the pitch) so the block
            -- reads as pressed paper rather than a printed pattern.
            local sp = math.max(2, math.floor(Screen:scaleBySize(1.4)))
            bb:paintRectRGB32(sx0, sy0, sw_edge, sh_edge, tone(0xF0))
            for cx = sx0 + 1, sx0 + sw_edge - 1, sp + 1 do
                local lw = 1 + ((cx * 73 + 41) % sp)
                lw = math.min(lw, sx0 + sw_edge - cx)
                bb:paintRectRGB32(cx, sy0, lw, sh_edge, tone(0xA8))
            end
        end
        -- The boards, rising the lip above the paper, in the board shade.
        local bc = _boardColor(e.look, night)
        bb:paintRectRGB32(x, top, board_w, edge_h, bc)
        bb:paintRectRGB32(x + spine_w - board_w, top, board_w, edge_h, bc)
        -- The joint: where the boards meet the spine they are thicker than
        -- along their length, so the page block's bottom inside corners take
        -- a pixel of board. One pixel each side is enough to read as the
        -- binding turning in rather than as paper meeting a clean edge.
        if sw_edge > 2 and sh_edge > 1 then
            local jy = sy0 + sh_edge - hairline
            bb:paintRectRGB32(sx0, jy, hairline, hairline, bc)
            bb:paintRectRGB32(sx0 + sw_edge - hairline, jy, hairline, hairline, bc)
        end
    end
    -- The top corners come off too, matching the chamfered feet (user
    -- ruling) -- in page ground rather than plank shade, since that is
    -- what sits behind the book's head. Works for both silhouettes:
    -- board tops when the page block shows, the body's own corners on a
    -- spine too short for one.
    do
        -- Page ground, pre-invert space: white displays as the theme
        -- background in both modes, same as the slot's own ground fill.
        local g = Blitbuffer.ColorRGB32(0xFF, 0xFF, 0xFF, 0xFF)
        bb:paintRectRGB32(x, top, hairline, hairline, g)
        bb:paintRectRGB32(x + spine_w - hairline, top, hairline, hairline, g)
    end

    local pad = Screen:scaleBySize(3)
    local cur_top = body_top + pad
    local bottom = top + spine_h - pad

    -- Status glyph (reading / finished / on hold), level, at the head.
    local glyph = _statusGlyph(self.book)
    local w_dp = e.w_dp or 20
    if glyph then
        local gsize = math.max(9, math.min(17, math.floor(w_dp * 0.6)))
        local face = BFont:getFace("symbols", gsize)
        local used = _paintLevelText(bb, x, cur_top, spine_w, glyph, face, night)
        if used > 0 then cur_top = cur_top + used + math.floor(pad / 2) end
    end
    -- Favourite star under it (face-out favourites show the cover instead).
    if e.favourite and not e.face_out then
        local gsize = math.max(8, math.min(14, math.floor(w_dp * 0.5)))
        local face = BFont:getFace("symbols", gsize)
        local used = _paintLevelText(bb, x, cur_top, spine_w,
                                     CoverProgress.FAV_GLYPH_STAR, face, night)
        if used > 0 then cur_top = cur_top + used + math.floor(pad / 2) end
    end

    -- Series number at the foot, level, encyclopedia style: measured, then
    -- anchored so the text BOTTOM sits one pad above the spine's foot --
    -- the reserve arithmetic this replaces drifted with font size and let
    -- the number float above the base.
    if self.show_series and e.series_num then
        local ssize = math.max(7, math.min(13, math.floor(w_dp * 0.45)))
        local face = BFont:getFace(BFont.getUIFontFace() or "cfont", ssize)
        pcall(function()
            local tw = TextWidget:new{
                text = e.series_num, face = face,
                fgcolor = _textColor(night),
                max_width = spine_w, padding = 0,
            }
            local sz = tw:getSize()
            if sz.w >= 1 and sz.h >= 1 and sz.h < spine_h / 2 then
                local sy = top + spine_h - pad - sz.h
                tw:paintTo(bb, x + math.floor((spine_w - sz.w) / 2), sy)
                bottom = sy - math.floor(pad / 2)
            end
            tw:free()
        end)
    end

    -- Title, rotated, in whatever run is left. The face scales with spine
    -- width but caps at the size an AVERAGE book (unknown page count) gets
    -- on this shelf: a 1000-page spine grew its title far past its
    -- neighbours and truncated harder for it (bigger glyphs, same run).
    -- Thin spines still shrink below the cap as before.
    local run = bottom - cur_top
    if run > 0 and e.label and e.label ~= "" then
        local tcap  = math.max(8, math.min(18,
                          math.floor((e.ref_w_dp or 22) * 0.5)))
        local tsize = math.max(8, math.min(tcap, math.floor(w_dp * 0.5)))
        local author = (self.show_author ~= false) and e.author or nil
        _paintRotatedTitle(bb, x, cur_top, run, spine_w, e.label, tsize,
                           e.look, night, author)
    end

    -- Bulk selection: the cover grid's corner flag at FULL spine width,
    -- anchored to the FACE -- the top of the spine proper, below the page
    -- block and board tips (user rulings, two rounds). No invert: a
    -- negative colour always looks wrong on a colour panel (green flips
    -- to a plausible mauve), and at full width the flag alone is
    -- unmissable on any spine.
    if self.is_bulk_selected then
        pcall(function()
            -- Sized from an AVERAGE book (e.ref_w_dp, the reference the title
            -- face caps at too), so every spine wears the same badge: the
            -- circle sits centred on the spine, and the triangle behind it
            -- is cut off at the spine's edges on thin books, as if it wrapped
            -- round the side (user ruling). Sizing from the spine's own width
            -- shrank the badge to a speck on a novella and hugged the corner
            -- on everything else -- a cover-grid look, where a frame around
            -- the cover keeps the circle off the edges.
            local fy    = body_top
            local ref_w = Screen:scaleBySize(e.ref_w_dp or 22)
            local pad   = math.max(1, Screen:scaleBySize(1))
            local r     = math.max(2, math.floor(ref_w * 0.28))
            r = math.min(r, math.max(2, math.floor((spine_w - 2) / 2)))
            local cx, cy = x + math.floor(spine_w / 2), fy + pad + r
            -- Leg long enough that the centred circle clears the diagonal
            -- (distance to it >= r), then cropped to the spine's width and
            -- the face's height.
            local leg   = math.max(ref_w,
                              math.floor(spine_w / 2 + pad + 2.414 * r) + 2)
            local max_h = (top + spine_h) - fy
            for i = 0, math.min(leg, max_h) - 1 do
                local run = math.min(leg - i, spine_w)
                if run > 0 then
                    bb:paintRect(x, fy + i, run, 1, Blitbuffer.COLOR_BLACK)
                end
            end
            bb:paintCircle(cx, cy, r, Blitbuffer.COLOR_WHITE)
            bb:paintCircle(cx, cy, math.max(1, math.floor(r * 0.5)),
                           Blitbuffer.COLOR_BLACK)
        end)
    end
end

-- A lifted face-out's shadow on the plank: transparent except for the
-- darker patch, so the plank's own shading shows around it. The patch
-- darkens the SAME banded tones the plank paints at those rows (via the
-- shared plankBandT), so it matches the shadow under a lifted spine.
local LiftShadow = Widget:extend{}

function LiftShadow:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local w, h = self.dimen.w, self.dimen.h
    local ins = Screen:scaleBySize(2)
    local pk = self.plank
    if pk then
        -- The shadow lies ON the plank's top surface, never in the air the
        -- book lifted through: painting the whole drop made it stick up
        -- past the shelf's back edge (user report). Clamp to the surface
        -- band, darkening the same tones the plank paints there.
        local surf_h = 3 * pk.b
        local surf_top = y + h + pk.inset - surf_h
        local y0 = math.max(y, surf_top)
        for yy = y0, y + h - 1 do
            bb:paintRectRGB32(x + ins, yy, math.max(1, w - 2 * ins), 1,
                              _plankBandColor(yy - surf_top, surf_h, 0.72))
        end
        return
    end
    local air = math.max(2, Screen:scaleBySize(1))
    local sh = math.min(self.shadow_h or 0, h - air)
    if sh < 1 then return end
    bb:paintRectRGB32(x + ins, y + air, math.max(1, w - 2 * ins), sh,
                      _plankShade(0.35))
end

-- ── Face-out page block ─────────────────────────────────────────────────────
-- The book's top edge above a face-out cover: fine vertical page stripes,
-- with the cover board as a border on the LEFT edge and across the TOP (the
-- back board seen edge-on). Its height is the book's thickness -- the same
-- page-count width its spine would have had. Replaces the cover tile's drop
-- shadow, which read as floating rather than shelved.
local FaceOutTopBlock = Widget:extend{}

function FaceOutTopBlock:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local w, h = self.dimen.w, self.dimen.h
    if w < 6 or h < 3 then return end
    local night = _nightMode()
    local board = math.max(2, math.min(Screen:scaleBySize(3),
                                       math.floor(h * 0.3)))
    local function tone(v)
        if night then v = 255 - v end
        return Blitbuffer.ColorRGB32(v, v, v, 0xFF)
    end
    -- Pages first, boards left / top / a thin sliver right, so the block
    -- reads as pages BETWEEN the cover boards like a spine top does. The
    -- stripes run HORIZONTALLY here: a face-out book's pages stack front to
    -- back, so their edges read as lines parallel to the cover's top.
    local rb = math.max(1, math.floor(board / 2))
    local sx0, sy0 = x + board, y + board
    local sw, sh = w - board - rb, h - board
    if sw > 2 and sh > 1 then
        local sp = math.max(2, math.floor(Screen:scaleBySize(1.4)))
        bb:paintRectRGB32(sx0, sy0, sw, sh, tone(0xF0))
        for cy = sy0 + 1, sy0 + sh - 1, sp + 1 do
            local lh = 1 + ((cy * 73 + 41) % sp)
            lh = math.min(lh, sy0 + sh - cy)
            bb:paintRectRGB32(sx0, cy, sw, lh, tone(0xA8))
        end
    end
    local fill = _boardColor(self.look, night)
    -- The TOP-LEFT corner pixel comes off, the same chamfer the spine feet get
    -- where they meet the plank. The left only: this block was briefly notched
    -- at both ends, and the right one read wrong, because the right side is
    -- the board standing slightly PROUD of the page edges it wraps -- a cut
    -- there takes the corner off the wrong thing (user ruling, reversing the
    -- earlier both-ends one).
    local ch = math.max(2, Screen:scaleBySize(1))
    bb:paintRectRGB32(x, y + ch, board, h - ch, fill)     -- left board, below the chamfer
    bb:paintRectRGB32(x + ch, y, w - ch, board, fill)     -- top board, notched at the left
    bb:paintRectRGB32(x + w - rb, y + board, rb, h - board, fill)  -- right sliver
end

-- ── Face-out foot nicks ─────────────────────────────────────────────────────
-- The standing cover's bottom corners come off in plank shade, the same
-- softening the spine feet get where they meet the plank. Overlaid on the
-- cover tile (it owns its own paint); rowWidget skips it for a LIFTED
-- book, whose feet float in front of the page -- the same rule the spines
-- follow.
local FaceOutFeet = Widget:extend{}

function FaceOutFeet:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local w, h = self.dimen.w, self.dimen.h
    local hl = Screen:scaleBySize(1)
    if hl < 1 then hl = 1 end
    _cutFootCorners(bb, x, y + h, w, hl,
                    _behindAt(self.plank, y + h, self.lifted))
end

-- ── Shelf-edge section badges ───────────────────────────────────────────────
-- The bookshop cue for a flattened group's run: an acrylic-style badge --
-- dark, white text, the ribbon folder style's own colours so one setting
-- drives both -- hooked over the front of the plank under the run (user
-- spec). Full label, never truncated, unless it would outgrow the run of
-- spines above it; centred under the run. One badge per run PER ROW, so a
-- run that wraps keeps its name in view on every shelf it crosses.
local ShelfBadges = Widget:extend{}

-- A badge hangs BELOW its plank by design, and by more than the inter-row
-- gap once the label is large (a high DPI, a tall UI font). Painted in row
-- order it loses: the next row's books paint over it, and on the last row the
-- footer does. So in deferred mode the badge only RECORDS where it would
-- draw, and SpineShelf.badgeOverlay -- which the shelf paints last of all --
-- does the drawing. The space it hangs into is empty in every case that
-- matters: books never descend below their own plank, not even lifted.
function ShelfBadges:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    if self.deferred then return end
    self:drawAt(bb, x, y)
end

-- Paint at the position the last paintTo recorded. No-op until the row has
-- been painted once and the position is known.
function ShelfBadges:paintDeferred(bb)
    if not (self.dimen and self.dimen.x and self.dimen.y) then return end
    self:drawAt(bb, self.dimen.x, self.dimen.y)
end

function ShelfBadges:drawAt(bb, x, y)
    local h = self.dimen.h
    local ok_sd, StackDisplay = pcall(require, "lib/bookshelf_stack_display")
    if not (ok_sd and StackDisplay and StackDisplay.ribbonColors) then return end
    local fill, fg = StackDisplay.ribbonColors()
    local pad_x = Screen:scaleBySize(5)
    local pad_y = Screen:scaleBySize(2)
    -- Sized from the TEXT, not the plank: the plank zone alone is too
    -- shallow for a legible label on dense shelves, and a real acrylic
    -- badge covers the books' feet anyway -- it hangs in FRONT of them.
    -- 14pt base, scaled by the same "Stack and folder labels" size
    -- setting the folder cards use -- the badge names sections the way
    -- their labels name stacks (user ruling).
    local scale = 100
    pcall(function()
        local BookshelfSettings = require("lib/bookshelf_settings_store")
        scale = BookshelfSettings.read("stack_label_font_scale", 100) or 100
    end)
    local face = BFont:getFace(BFont.getUIFontFace() or "cfont",
                               math.max(8, math.floor(14 * scale / 100 + 0.5)))
    local spans = self.spans or {}
    for _i, s in ipairs(spans) do
        if s.label and s.label ~= "" then
            pcall(function()
                -- A thin section's badge may stick out past its spines --
                -- real shelf badges do -- by up to 30dp, but never into
                -- the NEXT section's badge (left-aligned, so the next
                -- span's x is the wall).
                local nxt = spans[_i + 1]
                local wall = (nxt and nxt.x or (self.dimen.w
                              - SpineShelf.endMargin(h))) - s.x
                              - Screen:scaleBySize(2)
                local allow = math.max(s.w,
                    math.min(wall, s.w + Screen:scaleBySize(30)))
                -- Below ~9 characters of room the badge is pure noise
                -- ("T…"): skip it. Back-to-back single-book sections on a
                -- dense authors shelf fall out naturally; anything with a
                -- run, a face-out or breathing room keeps its name.
                if allow < Screen:scaleBySize(55) then return end
                local tw = TextWidget:new{
                    text      = s.label,
                    face      = face,
                    fgcolor   = fg,
                    max_width = math.max(8, allow - 2 * pad_x),
                    padding   = 0,
                }
                local sz = tw:getSize()
                if sz.w > 0 and sz.h > 0 then
                    local badge_h = sz.h + 2 * pad_y
                    local bw = math.min(allow, sz.w + 2 * pad_x)
                    -- Left edge flush with the run's first spine (user
                    -- ruling) -- the way a shop's badge marks where the
                    -- section STARTS, not its middle.
                    local bx = x + s.x
                    -- Hooked over the shelf lip: the top edge sits a couple
                    -- of pixels above the plank's FRONT FACE (user ruling),
                    -- the body hanging down over it -- overhanging the row
                    -- bottom into the inter-row gap when the face is
                    -- shallower than the label.
                    local fh = SpineShelf.plankFace(h)
                    local by = y + h - fh - 2
                    bb:paintRoundedRect(bx, by, bw, badge_h, fill,
                                        Screen:scaleBySize(2))
                    tw:paintTo(bb, bx + math.floor((bw - sz.w) / 2),
                               by + pad_y)
                end
                tw:free()
            end)
        end
    end
end

-- badgeOverlay(get_badges, w, h) -> a full-screen widget that paints every
-- row's section badges after everything else. `get_badges` is called at paint
-- time rather than a list being captured, so an in-place shelf swap (which
-- replaces the row widgets without rebuilding the window) cannot leave the
-- overlay painting badges that belong to rows that are gone.
local BadgeOverlay = Widget:extend{}

function BadgeOverlay:paintTo(bb, _x, _y)
    local list = self.get_badges and self.get_badges() or nil
    if not list then return end
    for i = 1, #list do
        local b = list[i]
        if b and b.paintDeferred then b:paintDeferred(bb) end
    end
end

function SpineShelf.badgeOverlay(get_badges, w, h)
    return BadgeOverlay:new{
        dimen      = Geom:new{ w = w, h = h },
        get_badges = get_badges,
    }
end

-- ── The shelf plank ─────────────────────────────────────────────────────────

local ShelfPlank = Widget:extend{}

-- endMargin(row_h) -> exposed plank at EACH end of a row, px. Books never
-- reach the shelf's ends; the visible margins are what make the plank read
-- as a piece of furniture rather than a stripe (user ruling, promoted from
-- a happy accident on partial rows).
function SpineShelf.endMargin(row_h)
    return SpineShelf.plankUnit(row_h)
end

-- plankUnit(row_h) -> the plank's edge unit in px: roughly one page-block
-- height, derived from the row like the slots derive theirs.
function SpineShelf.plankUnit(row_h)
    local b = math.floor((row_h or 0) * 0.02)
    local bmin, bmax = Screen:scaleBySize(4), Screen:scaleBySize(9)
    if b < bmin then b = bmin end
    if b > bmax then b = bmax end
    return b
end

-- plankFace(row_h) -> the plank's FRONT FACE height in px. 1.4 units: under
-- the shelf's 12-degree view a vertical face barely foreshortens, so this is
-- the plank's thickness against the books -- and at one unit it read as a
-- thin board (~13mm on a 130mm-deep book, where a real shelf is 18-20mm).
-- Books stand on the surface above it, so the stand height, the badges'
-- hang point and the shading bands all derive from this one number.
function SpineShelf.plankFace(row_h)
    return math.max(1, math.floor(SpineShelf.plankUnit(row_h) * 1.4))
end

-- The plank in 3D (user spec): the upward-facing top surface rises TWO edge
-- units behind the books, the front-top edge is a thin dark line, and below
-- it the plank's front face drops (see plankFace), darker. Shading is
-- derived from the one plank colour: surface lit, face in shade, edge darkest.
function ShelfPlank:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local w, h = self.dimen.w, self.dimen.h
    local b = SpineShelf.plankUnit(h)
    local fh = SpineShelf.plankFace(h)
    local pr, pg, pb = _plankRGB()
    local function shade(f)
        return Blitbuffer.ColorRGB32(
            math.floor(math.min(255, pr * f) + 0.5),
            math.floor(math.min(255, pg * f) + 0.5),
            math.floor(math.min(255, pb * f) + 0.5), 0xFF)
    end
    local front_y = y + h - fh
    -- Top surface, receding: darker at the far (top) edge, lighter as it
    -- reaches the front. Three units deep, so the books stand back from
    -- the lip with surface showing in front of their feet.
    local surf_h = 3 * b
    local bands = 5
    for i = 0, bands - 1 do
        local by0 = front_y - surf_h + math.floor(surf_h * i / bands)
        local by1 = front_y - surf_h + math.floor(surf_h * (i + 1) / bands)
        bb:paintRectRGB32(x, by0, w, by1 - by0,
                          _plankBandColor(by0 - (front_y - surf_h), surf_h))
    end
    -- The front-top edge line: the brightest element, a lit highlight along
    -- the shelf's leading edge, with the front face clearly lighter than the
    -- top surface below it -- the look the user picked out of dark mode and
    -- asked to keep in both ('the inverted colours look best').
    local line = math.max(1, Screen:scaleBySize(1))
    bb:paintRectRGB32(x, front_y - line, w, line, _plankLit(0.55))
    bb:paintRectRGB32(x, front_y, w, fh, _plankLit(0.12))
    -- Chamfered ends: a board's corners are eased, not sliced square at the
    -- screen's edge (user report: the ends looked harshly cut off). A 45deg
    -- bevel the height of the face at each corner of the band -- far edge
    -- and front-bottom, both ends -- painted back to the row's ground
    -- (paper white in pre-invert space, which is what night displays as the
    -- shelf's black background).
    local c = math.max(2, fh)
    local band_top = front_y - surf_h
    local ground = Blitbuffer.ColorRGB32(0xFF, 0xFF, 0xFF, 0xFF)
    for i = 0, c - 1 do
        local run = c - i
        bb:paintRectRGB32(x, band_top + i, run, 1, ground)
        bb:paintRectRGB32(x + w - run, band_top + i, run, 1, ground)
        bb:paintRectRGB32(x, y + h - 1 - i, run, 1, ground)
        bb:paintRectRGB32(x + w - run, y + h - 1 - i, run, 1, ground)
    end
end

-- _folderIsSingleBook(path) -> true when the folder holds exactly ONE book
-- file and no subfolders -- a wrapper folder (one Calibre-style directory
-- per book), whose spine should read as its book, not as its directory
-- name. Shallow scan, early exit on the second book or any subfolder.
local _folder_single_cache = {}
local function _folderIsSingleBook(path)
    local hit = _folder_single_cache[path]
    if hit ~= nil then return hit end
    local ok, result = pcall(function()
        local lfs = require("libs/libkoreader-lfs")
        local ok_repo, Repo = pcall(require, "lib/bookshelf_book_repository")
        if not (ok_repo and Repo and Repo.isBookFile) then return false end
        local count = 0
        for entry in lfs.dir(path) do
            if entry ~= "." and entry ~= ".." and entry:sub(1, 1) ~= "." then
                local mode = lfs.attributes(path .. "/" .. entry, "mode")
                if mode == "directory" then
                    -- KOReader sidecars ride beside their book; only a real
                    -- subfolder makes this a collection.
                    if not entry:match("%.sdr$") then return false end
                elseif mode == "file" and Repo.isBookFile(entry) then
                    count = count + 1
                    if count > 1 then return false end
                end
            end
        end
        return count == 1
    end)
    local single = ok and result == true
    _folder_single_cache[path] = single
    return single
end

-- ── Plan: which books fit which rows, and how wide each stands ──────────────
--
-- plan(items, opts) -> {
--   entries = { {book, w, h, w_dp, look, face_out, favourite, label,
--                series_num}, ... },   -- one per (non-nil) item, in order
--   rows    = { {first,last}, ... },   -- capped at opts.n_rows
--   shown   = <count of books that made it onto this page>,
-- }
-- opts: content_w, row_h (px), gap (px), n_rows, face_out (bool),
--       height_pct (50..100, scales the spine height budget).
-- _flattenItems(items) -> flat
--
-- One entry per spine the page will stand, in order. Pulled out of plan() so
-- the run bookkeeping can be tested on its own: it decides three things that
-- are easy to get subtly wrong, and a shelf full of spines is a poor place to
-- notice.
--
--   item_idx   what the CURSOR counts -- one per item the fetch returned.
--   run_idx    the VISUAL run: what gets a wider gap either side and a name
--              badge under it. The same thing as item_idx for a group (one
--              item, one run), but NOT for a shelf whose items are the books
--              themselves and whose runs are a tag they share -- the
--              Home-folders source, where a folder with more books than fit a
--              page could never be paged through if the folder were the item.
--   first_of_group  the head of a run of more than one, which the "first in
--              series" face-out mode stands cover-forward.
function SpineShelf._flattenItems(items)
    local flat, n_items = {}, 0
    local run_n, prev_key = 0, nil
    for i = 1, #items do
        local it = items[i]
        if it then
            n_items = n_items + 1
            local members = it.books
            if members and #members > 0 then
                run_n = run_n + 1
                -- A group is its own run whatever stands next to it.
                prev_key = nil
                for m = 1, #members do
                    flat[#flat + 1] = { item = it, book = members[m],
                                        item_idx = n_items, run_idx = run_n,
                                        in_group = #members > 1,
                                        -- The "first in series/stack"
                                        -- face-out mode stands this one
                                        -- cover-forward at the head of
                                        -- its run.
                                        first_of_group = m == 1
                                            and #members > 1 or nil }
                end
            else
                -- A plain book. Consecutive books sharing a section tag are
                -- one run; untagged ones each stand alone, exactly as every
                -- book-list chip has always done.
                local key = it.shelf_section
                if not (key and key == prev_key) then
                    run_n = run_n + 1
                    prev_key = key
                end
                flat[#flat + 1] = { item = it, book = it,
                                    item_idx = n_items, run_idx = run_n,
                                    section_label = key, in_group = false }
            end
        end
    end
    -- A tagged run of one is a lone book, not a section: it gets the badge
    -- (single-member groups do too) but not the wider boundary gap.
    do
        local run_len, run_head = {}, {}
        for i = 1, #flat do
            local r = flat[i].run_idx
            run_len[r] = (run_len[r] or 0) + 1
            if run_head[r] == nil then run_head[r] = i end
        end
        for i = 1, #flat do
            local f = flat[i]
            if f.section_label and run_len[f.run_idx] > 1 then
                f.in_group = true
                -- The head of the run, which the "first in series" face-out
                -- mode stands cover-forward -- the same thing a group's first
                -- member gets above. A Home-folders shelf had no heads at all
                -- without this: its books are their own items, so the group
                -- branch never sees them and nothing ever faced out.
                if run_head[f.run_idx] == i then f.first_of_group = true end
            end
        end
    end
    return flat
end

function SpineShelf.plan(items, opts)
    local entries = {}
    local budget = opts.row_h
    -- Auto thickness: base widths scale with the shelf height, so one tall
    -- row doesn't stand needle-thin books (calibrated on device: two rows =
    -- 1.0, one row wants ~1.5). The chip's thickness % multiplies on top.
    local px_per_dp = Screen:scaleBySize(100) / 100
    local auto_thick = SpineLayout.autoThickness(
        px_per_dp > 0 and (budget / px_per_dp) or nil)
    local book_gap  = opts.gap or 0
    local group_gap = opts.group_gap or book_gap
    -- Title-size reference: the width an AVERAGE book (unknown page count)
    -- gets under this shelf's thickness modifiers. The title face scales
    -- with spine width, so long books grew their font far past the rest of
    -- the shelf and truncated harder (user report); the paint site caps the
    -- face at this book's size while thin spines still shrink below it.
    local ref_w_dp = SpineLayout.spineWidthDp(nil) * auto_thick
    do
        local t = tonumber(opts.thickness_pct)
        if t and t >= 40 and t <= 300 and t ~= 100 then
            ref_w_dp = ref_w_dp * t / 100
        end
    end
    -- Face-out policy: which books stand cover-forward. Mode string from
    -- the chip editor's picker; the old boolean pins normalise onto it
    -- (true/nil were "favourites face out: yes", false was "no").
    local face_mode = opts.face_out
    if face_mode == nil or face_mode == true then face_mode = "favorites" end
    if face_mode == false then face_mode = "none" end
    -- Ornaments BETWEEN sections, on a grouping chip. Decided here rather
    -- than at paint time because the space has to be RESERVED: fillRows packs
    -- the row out of these gaps, so an ornament conjured later would stand on
    -- top of a book. The geometry is derived from the row height exactly as
    -- rowWidget derives it, so the width booked here is the width painted.
    local orn = nil
    if opts.row_h and opts.row_h > 0 then
        local ok_o, Orn = pcall(require, "lib/bookshelf_ornaments")
        if ok_o and Orn then
            local b     = SpineShelf.plankUnit(opts.row_h)
            local fh    = SpineShelf.plankFace(opts.row_h)
            local inset = math.floor(b * 0.8)
            orn = {
                mod       = Orn,
                stand_h   = math.max(1, opts.row_h - fh - inset),
                pad       = math.max(book_gap, b),
                max_below = inset + fh,
                -- Never more than a quarter of the row: a section break is
                -- an aside, not an exhibit.
                budget    = math.floor((opts.content_w or 0) * 0.25),
            }
            pcall(Orn.ensureTemplate)
        end
    end

    -- ── Flatten ─────────────────────────────────────────────────────────
    -- A group that carries its member records (series stack, author /
    -- genre / tag pile) is flattened: every member stands as its own
    -- spine, and the run gets a wider gap on each side so the grouping
    -- still reads on the shelf. Groups that only know their first book
    -- (folders) stay as one drillable spine.
    local _t0 = _gettime()
    local _t_hydrate, _t_look, _t_pages, _t_fav, _n_hydrated = 0, 0, 0, 0, 0
    --
    -- run_idx is the VISUAL run -- what gets a wider gap either side and a
    -- name badge under it. item_idx is what the CURSOR counts. They are the
    -- same thing for a group (one item, one run), but not for a shelf where
    -- the books themselves are the items and the run is a tag they share:
    -- the Home-folders source hands over books carrying the folder they live
    -- in, because a folder with more books than fit a page could never be
    -- paged through if the folder were the item (see Repo.getFolderSections).
    local flat = SpineShelf._flattenItems(items)

    -- One read for the whole page's facts (look, count, cached status), so
    -- the per-book lookups below are table hits rather than a query each.
    do
        local fps = {}
        for j = 1, #flat do
            local bk = flat[j] and flat[j].book
            local fp = bk and bk.filepath
            if fp then fps[#fps + 1] = fp end
        end
        SpineShelf.prefetchFacts(fps)
    end

    local ok_repo, Repo = pcall(require, "lib/bookshelf_book_repository")
    for j = 1, #flat do
        local f = flat[j]
        local bk = f.book
        local rep = bk
        if not bk.filepath then
            rep = bk.first_book or bk
        end
        -- A wrapper folder (exactly one book inside) stands on the shelf AS
        -- its book: title, author, number and thickness all come from the
        -- book record; only the tap stays a folder drill. Checked once per
        -- record, cached on it.
        local src = bk
        if bk.kind == "folder" and bk.first_book and bk.path then
            if bk._spine_single == nil then
                bk._spine_single = _folderIsSingleBook(bk.path)
            end
            if bk._spine_single then src = bk.first_book end
        end
        -- A stack member is a LIGHT stub, built from whatever the light-meta
        -- cache held when the group was assembled -- on a cold start that
        -- can predate the Calibre load, so its title can be the filename and
        -- its series number missing while the hero (full record) shows both
        -- cleanly. Hydrate once per stub from the same resolver the hero
        -- uses; the answers are written back onto the stub, which lives in
        -- the group cache, so this costs one metadata read per book ever.
        if f.in_group and bk.filepath and not bk._spine_meta_checked then
            bk._spine_meta_checked = true
            local _th = _gettime()
            -- The stubs are REBUILT on every fetch (the group cache holds
            -- shapes, not records), so a flag on the stub only dedupes
            -- within one plan. The resolver's answers live in a module map
            -- keyed by filepath -- measured before it existed: 76 full
            -- metadata builds per page turn, every page turn.
            local hyd = _hydrate_cache[bk.filepath]
            -- Only PAY the full build when the stub actually shows the
            -- stale-cache tell: a filename-shaped (or missing) title, or no
            -- author anywhere. A complete light record already carries the
            -- Calibre/Hardcover folds, its own series_num, and authors[1]
            -- serves the spine's author segment -- hydrating it changes
            -- nothing. Measured before this gate: a cold series-chip open
            -- in spine mode paid 155 unconditional builds, 3.9s of a 4.3s
            -- open on device flash.
            local stem = type(bk.filename) == "string"
                         and bk.filename:gsub("%.%w+$", "") or nil
            local complete = type(bk.title) == "string" and bk.title ~= ""
                             and bk.title ~= stem and bk.title ~= bk.filename
                             and (bk.author ~= nil
                                  or (type(bk.authors) == "table"
                                      and bk.authors[1] ~= nil)
                                  or type(bk.authors) == "string")
            if not hyd and not complete then
                _n_hydrated = _n_hydrated + 1
                pcall(function()
                    if not (ok_repo and Repo) then return end
                    -- Light record first: the series stubs are BARE (only a
                    -- filepath -- the group cache holds shapes), and the
                    -- fields this needs are all on the memoised light
                    -- record, an O(1) map hit. The full build is the
                    -- fallback for books the batch doesn't know. Measured
                    -- before: a cold series-chip open in spine mode paid
                    -- 155 unconditional FULL builds, 3.9s of a 4.3s open.
                    local full = Repo.lightMetaFor
                                 and Repo.lightMetaFor(bk.filepath) or nil
                    if not (full and full.title) and Repo.buildBookMeta then
                        full = Repo.buildBookMeta(bk.filepath,
                                                  { want_cover = false })
                    end
                    if not full then return end
                    hyd = {
                        display_title = full.display_title,
                        title         = full.title,
                        series_num    = full.series_num
                                        and tostring(full.series_num) or nil,
                        page_count    = full.page_count,
                        cover_sizetag = full.cover_sizetag,
                        author        = full.author
                                        or (type(full.authors) == "table"
                                            and full.authors[1]) or nil,
                    }
                    _hydrate_cache[bk.filepath] = hyd
                end)
            end
            if hyd then
                if hyd.display_title and hyd.display_title ~= "" then
                    bk.display_title = hyd.display_title
                end
                if hyd.title and hyd.title ~= "" then
                    bk.title = hyd.title
                end
                if (not bk.series_num or tostring(bk.series_num) == "")
                        and hyd.series_num and hyd.series_num ~= "" then
                    bk.series_num = hyd.series_num
                end
                if not bk.page_count and hyd.page_count then
                    bk.page_count = hyd.page_count
                end
                if not bk.cover_sizetag and hyd.cover_sizetag then
                    bk.cover_sizetag = hyd.cover_sizetag
                end
                if (not bk.author or bk.author == "") and hyd.author then
                    bk.author = hyd.author
                end
            end
            _t_hydrate = _t_hydrate + (_gettime() - _th)
        end
        local label = src.display_title or src.title or src.label
                      or bk.label or src.series_name or src.text or src.name
        if (not label or label == "") and src.filename then
            label = src.filename:gsub("%.%w+$", "")
        end
        if (not label or label == "") and type(src.filepath) == "string" then
            label = src.filepath:match("([^/]+)%.%w+$")
                    or src.filepath:match("([^/]+)$") or ""
        end
        label = label or ""
        local _tl = _gettime()
        local look = SpineShelf.bookLook(rep)
        _t_look = _t_look + (_gettime() - _tl)
        local aspect = look.aspect
        local h = SpineLayout.spineHeight(budget, aspect)
        local _tf = _gettime()
        local fav = bk.filepath ~= nil and _isFavourite(bk.filepath)
        _t_fav = _t_fav + (_gettime() - _tf)
        -- The light record path leaves page_count nil for reflowables;
        -- the sidecar knows better and CoverProgress.decide reads it at
        -- paint time anyway for the glyphs, through the same TTL cache,
        -- so this backfill costs the page ONE sidecar read per book.
        local pages = src.page_count
        do
            local pp, ps, known = SpineShelf.cachedProgress(src.filepath)
            pages = pages or pp
            if src.status == nil and ps then src.status = ps end
            if (not pages or not known) and src.filepath
                    and ok_repo and Repo and Repo.readProgress then
                local _tp = _gettime()
                pcall(function()
                    local _pct, st, _rating, pc = Repo.readProgress(src.filepath)
                    -- Only when nothing better is in hand. BIM's count (the
                    -- record's own, set for fixed-layout formats) is what the
                    -- hero and the rows show, and a spine whose width came
                    -- from the sidecar's last-render figure instead read a few
                    -- pixels narrower than the same book everywhere else.
                    if pc and not src.page_count then
                        pages = pc
                        src.page_count = pc
                    end
                    if src.status == nil then src.status = st end
                    SpineShelf.persistProgress(src.filepath, pc, st)
                end)
                _t_pages = _t_pages + (_gettime() - _tp)
            end
            -- The tail of the ladder, owned by the repository, and the result
            -- written back onto the RECORD. The width used to take a count
            -- from the persisted store into a local and leave the record
            -- empty, so anything reading entry.page_count later saw nothing.
            if ok_repo and Repo and Repo.pageCountFor then
                pages = Repo.pageCountFor(src.filepath, pages)
            end
            if pages and not src.page_count then src.page_count = pages end
            -- The glyph resolver's lazy fallback opens the sidecar whenever
            -- status is nil; a checked record with no status is a book that
            -- has genuinely never been opened.
            src._spine_status_checked = true
        end
        -- Decided AFTER the status block: the "reading" mode needs
        -- src.status. Books only -- a plain folder keeps its spine.
        local face_out = false
        if src.filepath then
            if face_mode == "favorites"   then face_out = fav
            elseif face_mode == "first"   then face_out = f.first_of_group == true
            elseif face_mode == "reading" then face_out = src.status == "reading"
            elseif face_mode == "all"     then face_out = true
            end
        end
        if face_out and src.has_cover == nil and src.filepath
                and ok_repo and Repo and Repo.buildBookMeta then
            -- Light page records carry no has_cover, and the cover tile
            -- gates its whole cover ladder on it (the face-out rendered as
            -- the text placeholder). Enrich the record with the full
            -- metadata build, missing fields only, cover pixels still
            -- lazy-loaded by the tile.
            pcall(function()
                local full = Repo.buildBookMeta(src.filepath, { want_cover = false })
                if full then
                    for k, v in pairs(full) do
                        if src[k] == nil then src[k] = v end
                    end
                end
            end)
        end
        local w_dp, w, depth, face_h
        if face_out then
            -- The page block above a face-out cover is the book's THICKNESS:
            -- the same page-count width its spine would have had (auto scale
            -- and the chip's thickness % included), capped so the cover
            -- stays the point.
            local depth_dp = SpineLayout.spineWidthDp(pages) * auto_thick
            local t = tonumber(opts.thickness_pct)
            if t and t >= 40 and t <= 300 and t ~= 100 then
                depth_dp = depth_dp * t / 100
            end
            -- The visible top is the thickness foreshortened by the camera's
            -- pitch (see VIEW_SIN): a fat book shows a broad page block above
            -- its cover, a novella a sliver. Only the cover's own height caps
            -- it, so the cover stays the point.
            depth = math.floor(Screen:scaleBySize(depth_dp) * SpineShelf.VIEW_SIN)
            local d_max = math.floor(h * 0.15)
            if depth > d_max then depth = d_max end
            if depth < Screen:scaleBySize(3) then depth = Screen:scaleBySize(3) end
            -- The COVER's height, which is the book's front face, and so is
            -- exactly what this book's spine would show if it were turned the
            -- other way: the allotted height less the top edge a spine-out
            -- carves (see SpineLayout.topEdgeHeight). NOT `h - depth`: that
            -- left the cover a whole spine's top edge taller than its
            -- neighbours, because a book's thickness is far smaller than its
            -- cover width.
            face_h = h - SpineLayout.topEdgeHeight(h, aspect, Screen:scaleBySize(5))
            if face_h < Screen:scaleBySize(24) then face_h = Screen:scaleBySize(24) end
            -- Width from the COVER height, so the cover stays aspect-true.
            w = SpineLayout.faceOutWidth(face_h, aspect)
            w_dp = math.floor(w / (Screen:scaleBySize(100) / 100) + 0.5)
        else
            w_dp = SpineLayout.spineWidthDp(pages) * auto_thick
            -- Per-chip thickness: a straight multiplier on top of the
            -- height-scaled width. Face-out covers are aspect-true and
            -- stay out of both.
            local t = tonumber(opts.thickness_pct)
            if t and t >= 40 and t <= 300 and t ~= 100 then
                w_dp = w_dp * t / 100
            end
            w_dp = math.max(8, w_dp)
            w = Screen:scaleBySize(w_dp)
        end
        local series_num = nil
        if src.series_num and tostring(src.series_num) ~= "" then
            series_num = tostring(src.series_num)
        end
        -- Filename-style leading index ("2 - Player of Games", "3. Morning
        -- Star"): the last-resort number when metadata has none, and a
        -- duplicate to strip from the spine text when it matches the number
        -- already going to the foot. Guarded to plausible series indices so
        -- "2001: A Space Odyssey" keeps its title.
        if f.in_group then
            local pre, rest = label:match("^%s*(%d+%.?%d*)%s*[%-%.:]%s+(.+)$")
            local n = tonumber(pre)
            if n and n < 100 and rest and #rest > 2 then
                if not series_num then
                    series_num = pre
                end
                -- Strip the prefix even when it DISAGREES with the metadata
                -- number (Culture numbering is contested territory): the
                -- foot is authoritative, and a conflicting index inside the
                -- title reads as two different numbers on one spine.
                label = rest
            end
        end
        -- The gap this spine carries on its left: none at the very start,
        -- the small gap inside a run or between loose books, the wide one
        -- whenever the item boundary being crossed involves a group -- and
        -- a face-out lifts anything smaller to FACE_GAP (see the constant),
        -- except against its own run's spines.
        local gap_before = 0
        local ornament_here = nil
        if j > 1 then
            local prev   = flat[j - 1]
            local prev_e = entries[#entries]
            local prev_face = prev_e and prev_e.face_out
            local face_gap  = Screen:scaleBySize(SpineShelf.FACE_GAP_DP)
            if prev.run_idx == f.run_idx then
                -- Same run: tight, unless BOTH neighbours are covers
                -- (the "All books" wall) -- covers need air.
                gap_before = (face_out and prev_face) and face_gap or book_gap
            else
                if prev.in_group or f.in_group then
                    gap_before = group_gap
                    -- Now and then the break between two sections widens
                    -- enough for something to stand in it.
                    if orn then
                        local seed = "grp|"
                            .. tostring(prev_e and prev_e.book
                                        and prev_e.book.filepath or prev.item_idx)
                            .. "|" .. tostring(src.filepath or label or f.item_idx)
                        local pl = orn.mod.pick(seed, orn.budget, orn.stand_h, nil, {
                            min_gap   = Screen:scaleBySize(orn.mod.MIN_GAP_DP),
                            min_h     = Screen:scaleBySize(orn.mod.MIN_H_DP),
                            max_below = orn.max_below,
                            chance    = orn.mod.GROUP_CHANCE,
                        })
                        if pl then
                            ornament_here = pl
                            gap_before = gap_before + 2 * orn.pad + pl.w
                        end
                    end
                else
                    gap_before = book_gap
                end
                if (face_out or prev_face) and gap_before < face_gap then
                    gap_before = face_gap
                end
            end
        end
        entries[#entries + 1] = {
            book = bk, item = f.item, item_idx = f.item_idx,
            run_idx = f.run_idx, section_label = f.section_label,
            w = w, h = h, w_dp = w_dp, ref_w_dp = ref_w_dp,
            look = look, depth = depth, face_h = face_h,
            face_out = face_out, favourite = fav, label = label,
            author = src.author or (src.authors and src.authors[1]) or nil,
            series_num = series_num, gap_before = gap_before,
            in_group = f.in_group or nil,
            -- An ornament standing in the gap this spine carries (see the
            -- reservation above); rowWidget paints it.
            ornament = ornament_here,
        }
        logger.dbg(string.format(
            "[bookshelf perf] spine plan: %-24s w_dp=%.1f pages=%s aspect=%s rgb=%d,%d,%d sampled=%s fav=%s face_out=%s item=%d",
            label:sub(1, 24), w_dp, tostring(pages),
            tostring(aspect and string.format("%.2f", aspect)),
            look.r, look.g, look.b, tostring(look.sampled),
            tostring(fav), tostring(face_out), f.item_idx))
    end

    local widths, gaps = {}, {}
    for i = 1, #entries do
        widths[i] = entries[i].w
        gaps[i]   = entries[i].gap_before
    end
    local rows = SpineLayout.fillRows(widths, opts.content_w, gaps)
    while #rows > (opts.n_rows or 1) do table.remove(rows) end
    -- Even the shelves out. The fill has decided WHICH books are on this page
    -- -- greedy packs the most it can, and the cursor step, the page map and
    -- the footer range are all built on that -- so this re-breaks the SAME
    -- run of books across the SAME rows, purely to share the slack out. Rows
    -- are painted centred, so without it sixteen books on a two-row shelf
    -- read as fifteen books and one marooned mid-plank. run_idx tells the
    -- balancer where the sections are, so a series or a folder resists being
    -- cut in half; on a chip with no grouping every book is its own run and
    -- the preference costs nothing.
    if #rows > 1 then
        local runs = {}
        for i = 1, #entries do runs[i] = entries[i].run_idx end
        local even = SpineLayout.balanceRows(widths, opts.content_w, gaps,
                                             rows[#rows].last, #rows,
                                             { runs = runs })
        if even then rows = even end
    end

    -- shown is in ITEM units (what the cursor counts): the last item whose
    -- spines ALL made it onto the page. A group cut off mid-run repeats
    -- from its start on the next page -- with the floor of one so a group
    -- larger than a whole page can still be advanced past.
    local shown = 0
    if #rows > 0 then
        local last_entry = rows[#rows].last
        local last_item = entries[last_entry].item_idx
        local fully = last_entry == #entries
                      or entries[last_entry + 1].item_idx ~= last_item
        shown = fully and last_item or (last_item - 1)
        if shown < 1 then shown = 1 end
    end
    _flushLooks()
    SpineShelf._last_plan = {
        total_ms   = (_gettime() - _t0) * 1000,
        entries    = #entries,
        hydrate_ms = _t_hydrate * 1000,
        hydrated   = _n_hydrated,
        look_ms    = _t_look * 1000,
        pages_ms   = _t_pages * 1000,
    }
    logger.dbg(string.format(
        "[bookshelf perf] spine plan TOTAL=%.0fms entries=%d hydrate=%.0fms/%d look=%.0fms pages=%.0fms fav=%.0fms",
        (_gettime() - _t0) * 1000, #entries, _t_hydrate * 1000, _n_hydrated,
        _t_look * 1000, _t_pages * 1000, _t_fav * 1000))
    return { entries = entries, rows = rows, shown = shown }
end

-- ── Row widget ──────────────────────────────────────────────────────────────
--
-- rowWidget(opts) -> a width × height widget: shelf plank across the base,
-- spines stood on it. opts: plan, row (a {first,last} slice or nil for an
-- empty row), width, height, gap, on_book_tap/on_book_hold/on_book_open.
function SpineShelf.rowWidget(opts)
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan  = require("ui/widget/horizontalspan")
    local OverlapGroup    = require("ui/widget/overlapgroup")

    local dimen = Geom:new{ w = opts.width, h = opts.height }
    local plank = ShelfPlank:new{ dimen = Geom:new{ w = opts.width, h = opts.height } }
    if not opts.row then
        -- A bare plank under a half-filled page sometimes takes an ornament
        -- too (user ask: an empty shelf looked unfinished). Same pool, same
        -- odds, standing at a seeded spot along the plank; the seed is the
        -- page's first book plus the row index, so it holds still on the
        -- page and moves between pages.
        local ornament
        pcall(function()
            local Orn = require("lib/bookshelf_ornaments")
            Orn.ensureTemplate()
            local b       = SpineShelf.plankUnit(opts.height)
            local fh      = SpineShelf.plankFace(opts.height)
            local inset   = math.floor(b * 0.8)
            local stand_h = math.max(1, opts.height - fh - inset)
            local margin  = SpineShelf.endMargin(opts.height)
            local seed    = tostring(opts.page_key or "") .. "|empty|"
                            .. tostring(opts.row_index or 0)
            local pl = Orn.pick(seed, opts.width - 2 * margin, stand_h, nil, {
                min_gap   = Screen:scaleBySize(Orn.MIN_GAP_DP),
                min_h     = Screen:scaleBySize(Orn.MIN_H_DP),
                max_below = inset + fh,
            })
            if not pl then return end
            local span = math.max(0, opts.width - 2 * margin - pl.w)
            local x = margin + math.floor(span * ((Orn.hash(seed .. "|x") % 1000) / 1000))
            local w_ = Orn.Ornament:new{ placement = pl, night = _nightMode() }
            w_.overlap_offset = { x, stand_h - pl.above }
            ornament = w_
        end)
        if ornament then
            return OverlapGroup:new{ dimen = dimen, plank, ornament }
        end
        return OverlapGroup:new{ dimen = dimen, plank }
    end

    -- Books stand ON the plank's top surface, a step back from the lip:
    -- their feet sit one inset above the front-top edge, so a strip of
    -- surface shows in FRONT of them, the front face drops below that,
    -- and the rest of the surface rises behind (all painted by ShelfPlank
    -- underneath this group).
    local b = SpineShelf.plankUnit(opts.height)
    local fh = SpineShelf.plankFace(opts.height)
    local inset = math.floor(b * 0.8)
    local stand_h = math.max(1, opts.height - fh - inset)
    local group = HorizontalGroup:new{ align = "top" }
    -- Books stand CENTRED on their plank (user ruling, made obvious by the
    -- all-face-out wall: left-aligned rows left all the slack ragged on the
    -- right). The lead span absorbs half the row's leftover, floored at the
    -- end margin so books never reach the shelf's ends -- an overwide
    -- single book keeps the old left anchor and clips right as before.
    local content_w = 0
    for i = opts.row.first, opts.row.last do
        local e = opts.plan.entries[i]
        if e then
            content_w = content_w + e.w
            if i > opts.row.first then
                content_w = content_w + (e.gap_before or opts.gap)
            end
        end
    end
    local lead = math.max(SpineShelf.endMargin(opts.height),
                          math.floor((opts.width - content_w) / 2))
    group[#group + 1] = HorizontalSpan:new{ width = lead }
    -- Section badges: collect each flattened group's run in THIS row (x
    -- extent in row coordinates) so ShelfBadges can hang its name off the
    -- plank beneath it.
    local cursor, badge_spans = lead, {}
    local gap_ornaments = {}
    for i = opts.row.first, opts.row.last do
        local e = opts.plan.entries[i]
        if e then
            if #group > 1 then
                -- Each spine carries its own leading gap: hairline inside a
                -- run, wider across a group boundary. The row's first spine
                -- carries none (fillRows dropped it from the arithmetic too;
                -- the end margin span is group[1]).
                local gap_w = e.gap_before or opts.gap
                -- The section break's ornament, standing centred in the gap
                -- the plan widened for it. Only here, where the gap is real:
                -- a boundary that landed at a row's start carries no gap, and
                -- fillRows dropped the reservation with it.
                if e.ornament then
                    pcall(function()
                        local Orn = require("lib/bookshelf_ornaments")
                        local pl  = e.ornament
                        local w_  = Orn.Ornament:new{ placement = pl,
                                                      night = _nightMode() }
                        w_.overlap_offset = { cursor + math.floor((gap_w - pl.w) / 2),
                                              stand_h - pl.above }
                        gap_ornaments[#gap_ornaments + 1] = w_
                    end)
                end
                group[#group + 1] = HorizontalSpan:new{ width = gap_w }
                cursor = cursor + gap_w
            end
            if (e.item and e.item.books) or e.section_label then
                -- Every GROUP gets a badge, single-member ones included --
                -- on a grouping chip each item is a section, and an
                -- unbadged lone book reads as a stray (user report: the
                -- narrator-split singles looked like anonymous duplicates).
                -- e.in_group stays the >1 flatten/gap semantics.
                local seg = badge_spans[#badge_spans]
                if seg and seg.run == e.run_idx then
                    seg.w = (cursor + e.w) - seg.x
                else
                    local it = e.item or {}
                    -- A section tag names its own run (the folder it came
                    -- from); a group's name comes off the group.
                    local label = e.section_label
                                  or it.series_name or it.label or it.name
                    -- Author sections sort by SURNAME, and the surname is
                    -- what a shopper scans the shelf edge for -- so the
                    -- badge always reads "Last, First", whatever the
                    -- author-name display setting says (user ruling: with
                    -- first_last the sort order looked arbitrary).
                    if it.kind == "author" and label then
                        pcall(function()
                            local AuthorName =
                                require("lib/bookshelf_author_name")
                            label = AuthorName.formatted(label, "last_first")
                        end)
                    end
                    badge_spans[#badge_spans + 1] = {
                        item  = e.item,
                        run   = e.run_idx,
                        x     = cursor,
                        w     = e.w,
                        label = label,
                    }
                end
            end
            local is_sel = opts.selected_filepath ~= nil
                           and e.book.filepath == opts.selected_filepath
            -- Bulk selection: mark this book when selection mode is live
            -- and holds it (books only -- the bulk actions operate on
            -- files).
            local is_bulk = false
            if opts.selection and e.book.filepath then
                local ok_b, hit = pcall(function()
                    return opts.selection:isActive()
                           and opts.selection:contains(e.book.filepath)
                end)
                is_bulk = ok_b and hit or false
            end
            local tile
            local _tile_t0 = e.face_out and _gettime() or nil
            if e.face_out then
                -- A face-out favourite IS a cover-grid book: reuse the cover
                -- tile wholesale (user ruling) so it carries every glyph,
                -- badge and pill the grid gives it -- bottom-aligned so it
                -- stands on the plank with its neighbours.
                local ok_sw, CoverTile = pcall(require, "lib/bookshelf_spine_widget")
                if ok_sw and CoverTile then
                    local VerticalGroup = require("ui/widget/verticalgroup")
                    local VerticalSpan  = require("ui/widget/verticalspan")
                    -- Face-outs sit a step FURTHER back on the shelf than the
                    -- spines (user ruling), and selection lifts them like any
                    -- other book -- never the cover grid's ring.
                    local push = inset
                    local lift = 0
                    if is_sel then
                        -- Clear the plank's top surface plus an air gap,
                        -- accounting for the extra push face-outs sit at.
                        lift = math.max(0, 3 * b - inset - push)
                               + Screen:scaleBySize(6)
                    end
                    local fo_stand = stand_h - push
                    local avail = math.min(e.h, fo_stand)
                    local depth = math.min(e.depth or 0, math.max(0, avail - 10))
                    -- The cover is its own height (the planner's face_h: the
                    -- front face this book shows either way round), NOT
                    -- "everything left after the page block". The difference
                    -- is what made a face-out overtop the spine beside it.
                    -- The slack this leaves at the top of the row is correct:
                    -- a face-out shows only its THICKNESS up there where a
                    -- spine-out shows its cover width, so its whole
                    -- silhouette really is shorter.
                    local cover_h = math.min(e.face_h or (avail - depth), avail - depth)
                    -- A tall cover shrinks to make room for the lift rather
                    -- than losing the gap.
                    if lift > 0 and cover_h + depth + lift > fo_stand then
                        cover_h = math.max(Screen:scaleBySize(40),
                                           fo_stand - depth - lift)
                    end
                    local cover = CoverTile:new{
                        book          = e.book,
                        width         = e.w,
                        height        = cover_h,
                        on_tap        = opts.callbacks and opts.callbacks.on_book_tap,
                        on_hold       = opts.callbacks and opts.callbacks.on_book_hold,
                        on_double_tap = opts.callbacks and opts.callbacks.on_book_open,
                        show_progress = true,
                        -- The page block replaces the drop shadow: a shelved
                        -- book doesn't float. flat_thumb drops the shadow AND
                        -- its pixel reservation; badges and glyphs stay.
                        flat_thumb    = true,
                        -- Facing out IS the favourite marker on this shelf;
                        -- the heart badge on top of it doubles the message
                        -- and breaks the skeuomorphism (user ruling).
                        suppress_favorite_badge = true,
                        -- Same argument for the "#N" and "<n>p" pills: the
                        -- spines beside it already number their series on the
                        -- foot, and a book's length is its width here (user
                        -- ruling). The progress bar and status glyphs stay.
                        suppress_number_badges  = true,
                        is_bulk_selected = is_bulk,
                        -- No frame around a face-out on this shelf, so the
                        -- bulk flag keeps its circle off the card's edges.
                        bulk_flag_inset  = Screen:scaleBySize(4),
                        -- The status glyphs' below-card dangle vanished
                        -- behind the lift shadow / plank here; they move to
                        -- the corner the heart vacated (user ruling).
                        glyphs_top_left = true,
                        -- flat_thumb normally means "list thumbnail" to the
                        -- opening effect and gets the flat squash; a shelf
                        -- face-out opens with the tilt instead (below).
                        spine_face_out = true,
                    }
                    -- Geometry the opening tilt needs (paintFaceOutTilt):
                    -- the page block sits directly above the cover card and
                    -- gets redrawn taller as the book tips forward; `below`
                    -- is the plank the cast shadow falls on -- push span +
                    -- surface strip + front face, cover foot to row bottom.
                    -- `lift` continues the selection lift while opening: a
                    -- standing book rises the full clearance, an already
                    -- lifted one stays put (the capture is at the lifted
                    -- position and the vacated strip below it -- lift
                    -- shadow, not plank -- can't be reproduced from here).
                    -- plank_b lets the painter refill the strip the rising
                    -- foot vacates with the plank's own banded surface.
                    local tilt_lift = 0
                    if lift == 0 then
                        tilt_lift = math.max(0, 3 * b - inset - push)
                                    + Screen:scaleBySize(6)
                    end
                    cover.faceout_fx = { depth = depth, look = e.look,
                                         below = push + inset + b,
                                         plank_b = b, plank_face = fh,
                                         lift = tilt_lift }
                    local stack = VerticalGroup:new{ align = "center" }
                    local head = fo_stand - cover_h - depth - lift
                    if head > 0 then
                        stack[#stack + 1] = VerticalSpan:new{ width = head }
                    end
                    if depth > 0 then
                        stack[#stack + 1] = FaceOutTopBlock:new{
                            dimen = Geom:new{ w = e.w, h = depth },
                            look  = e.look,
                        }
                    end
                    -- The cover's corners come off the same way a spine's
                    -- do, standing OR lifted: the cut copies what is behind,
                    -- so it is the plank on the shelf and the page off it.
                    stack[#stack + 1] = OverlapGroup:new{
                        dimen = Geom:new{ w = e.w, h = cover_h },
                        cover,
                        FaceOutFeet:new{
                            dimen  = Geom:new{ w = e.w, h = cover_h },
                            plank  = { b = b, inset = inset },
                            lifted = lift > 0 or nil,
                        },
                    }
                    if push + lift > 0 then
                        if lift > 0 then
                            -- The lifted book's shadow where it stood.
                            stack[#stack + 1] = LiftShadow:new{
                                dimen    = Geom:new{ w = e.w, h = push + lift },
                                shadow_h = lift,
                                plank    = { b = b, inset = inset },
                            }
                        else
                            stack[#stack + 1] = VerticalSpan:new{
                                width = push + lift,
                            }
                        end
                    end
                    -- Mark the wrapper so the selection repaint can find it
                    -- (it has no .entry; flips fall back to a full swap).
                    stack.book = e.book
                    tile = stack
                end
            end
            if _tile_t0 then
                -- Face-out tile construction is where the cover pixels get
                -- loaded; accounted separately in the turn summary.
                SpineShelf._tile_ms = (SpineShelf._tile_ms or 0)
                                      + (_gettime() - _tile_t0) * 1000
                SpineShelf._tile_n = (SpineShelf._tile_n or 0) + 1
            end
            if not tile then
                tile = SpineBookSlot:new{
                    book        = e.book,
                    entry       = e,
                    width       = e.w,
                    height      = stand_h,
                    -- How far a selected book may rise above the shelf
                    -- before it has to shrink (see the lift in paintTo).
                    lift_headroom = opts.lift_headroom,
                    callbacks   = opts.callbacks,
                    show_author = opts.show_author,
                    is_selected = is_sel,
                    is_bulk_selected = is_bulk,
                    plank       = { b = b, inset = inset, face = fh },
                }
            end
            group[#group + 1] = tile
            cursor = cursor + e.w
        end
    end
    -- Ornaments: the slack at a row's end (books stand centred, so half of
    -- it sits each side) can take one of the user's SVGs, standing on the
    -- plank at the books' feet line. Deterministic per page composition;
    -- never on a full row. See bookshelf_ornaments.lua -- deliberately
    -- undocumented, the folder it creates is the whole hint.
    local ornament
    pcall(function()
        local Orn = require("lib/bookshelf_ornaments")
        Orn.ensureTemplate()
        local margin = SpineShelf.endMargin(opts.height)
        local pad    = math.max(opts.gap or 0, b)
        local slack  = opts.width - (lead + content_w)
        local gap    = math.max(0, math.min(slack, lead) - margin - pad)
        local first  = opts.plan.entries[opts.row.first]
        local seed   = tostring(first and first.book and first.book.filepath or "")
                       .. "|" .. tostring(opts.row.first) .. "|" .. tostring(opts.row.last)
        local pl = Orn.pick(seed, gap, stand_h, nil, {
            min_gap   = Screen:scaleBySize(Orn.MIN_GAP_DP),
            min_h     = Screen:scaleBySize(Orn.MIN_H_DP),
            max_below = inset + fh,
        })
        if not pl then return end
        local x
        if pl.side == "left" then
            x = lead - pad - pl.w
        else
            x = lead + content_w + pad
        end
        if x < margin or x + pl.w > opts.width - margin then return end
        local w_ = Orn.Ornament:new{ placement = pl, night = _nightMode() }
        w_.overlap_offset = { x, stand_h - pl.above }
        ornament = w_
    end)
    local children = { dimen = dimen, plank, group }
    for _i = 1, #gap_ornaments do
        children[#children + 1] = gap_ornaments[_i]
    end
    if ornament then children[#children + 1] = ornament end
    local badges
    if #badge_spans > 0 then
        badges = ShelfBadges:new{
            dimen    = Geom:new{ w = opts.width, h = opts.height },
            spans    = badge_spans,
            deferred = opts.defer_badges or nil,
        }
        children[#children + 1] = badges
    end
    local row_group = OverlapGroup:new(children)
    -- The shelf collects these for its overlay; it still paints as a child
    -- here, which is how it learns where it sits.
    row_group._shelf_badges = badges
    return row_group
end

-- The tilt's lighting, matched to the PLANK's: the plank paints as if lit
-- from the camera -- its front face and front-top edge are the bright
-- parts -- so a book tipping forward turns its TOP toward that light (the
-- pages LIGHTEN) while its face turns away and down (darkens, most at the
-- foot, where the plank's shadow zone eats the global light too). And a
-- leaning book shades the shelf it leans over: a cast band grows down
-- from its feet across the plank's surface strip and front face. The
-- first two attempts -- a flat wash, then a head-dark gradient -- both
-- read wrong against this light (user reports). Banded blends: a handful
-- of rects cost nothing on a one-shot frame and e-ink's 16 greys can't
-- show finer steps anyway. Every blend flips black/white in night
-- (pre-invert space reverses which paint direction displays darker).
local TILT_FACE_HEAD   = 0.08   -- face darken at the head...
local TILT_FACE_FOOT   = 0.40   -- ...growing toward the shelf
local TILT_TOP_LIGHT   = 0.18   -- pages lighten, tipped into the light
local TILT_CAST_NEAR   = 0.35   -- cast shadow right under the feet...
local TILT_CAST_FAR    = 0.10   -- ...fading down the plank's front
local TILT_SHADE_BANDS = 12

local function _shadeRect(bb, x, y, w, h, by, night)
    if night then bb:lightenRect(x, y, w, h, by)
    else bb:darkenRect(x, y, w, h, by) end
end

local function _lightRect(bb, x, y, w, h, by, night)
    if night then bb:darkenRect(x, y, w, h, by)
    else bb:lightenRect(x, y, w, h, by) end
end

local function _gradeRect(bb, x, y, w, h, from, to, night)
    if not (w and h and w > 0 and h > 0) then return end
    local bands = math.min(TILT_SHADE_BANDS, h)
    for i = 0, bands - 1 do
        local y0 = y + math.floor(h * i / bands)
        local y1 = y + math.floor(h * (i + 1) / bands)
        if y1 > y0 then
            local t = (i + 0.5) / bands
            _shadeRect(bb, x, y0, w, y1 - y0, from + (to - from) * t, night)
        end
    end
end

local function _shadeTiltFace(bb, x, y, w, h, night)
    _gradeRect(bb, x, y, w, h, TILT_FACE_HEAD, TILT_FACE_FOOT, night)
end

local function _shadeTiltCast(bb, x, y, w, h, night)
    _gradeRect(bb, x, y, w, h, TILT_CAST_NEAR, TILT_CAST_FAR, night)
end

-- paintOpeningTilt(slot) — one-frame "book coming off the shelf" feedback,
-- painted straight onto the framebuffer like the cover grid's flex (e-ink
-- cannot animate through the blocking document open). The slot re-renders
-- itself with the tilt overrides -- foreshortened toward its feet, top
-- edge grown -- into a scratch buffer that is blitted over its on-screen
-- rect; the render cache is bypassed so the frame is never served later.
-- Returns the affected region (x, y, w, h) for the caller's refresh union,
-- or nothing when the slot has no usable geometry.
function SpineShelf.paintOpeningTilt(slot)
    local d = slot and slot.dimen
    if not (d and d.x and d.w and d.w > 4 and d.h > 8) then return end
    local bb = Screen.bb
    if not bb then return end
    local night = _nightMode()
    local ok = pcall(function()
        local c = Blitbuffer.new(slot.width, slot.height, bb:getType())
        -- Same page ground the cached render starts from, so the strip the
        -- shrinking spine vacates reads as the shelf background behind it.
        c:paintRectRGB32(0, 0, slot.width, slot.height,
                         Blitbuffer.ColorRGB32(0xFF, 0xFF, 0xFF, 0xFF))
        slot._tilt = true
        slot:_renderInto(c, night)
        slot._tilt = nil
        -- The lighting split (see the constants above): pages tip INTO the
        -- front light, the face away from it, foot-dark.
        local r = slot._render_spine_rect
        if r then
            local edge = r.edge or 0
            if edge > 0 then
                _lightRect(c, r.x, r.y, r.w, edge, TILT_TOP_LIGHT, night)
            end
            _shadeTiltFace(c, r.x, r.y + edge, r.w, r.h - edge, night)
        end
        bb:blitFrom(c, d.x, d.y, 0, 0, slot.width, slot.height)
        c:free()
    end)
    slot._tilt = nil
    if not ok then
        logger.dbg("[bookshelf] spine opening tilt failed; skipping")
        return
    end
    -- The leaning book shades the plank in front of it: a cast band from
    -- its feet down over the surface strip and the front face (the slot
    -- ends one inset above the front-top edge; plank geometry from the
    -- descriptor the row hands every slot).
    local pk = slot.plank
    local band = pk and ((pk.face or pk.b) + pk.inset) or Screen:scaleBySize(8)
    pcall(function()
        _shadeTiltCast(bb, d.x, d.y + d.h, d.w, band, _nightMode())
    end)
    return d.x, d.y, d.w, d.h + band
end

-- paintFaceOutTilt(tile) — the face-out cover's opening feedback, matching
-- the spine tilt's perspective rather than the cover grid's straight-on
-- flex (user report: the flex reads wrong on this shelf, where the viewer
-- is slightly ABOVE the books -- the page block on top says so). The
-- cover foreshortens toward its feet and the page block grows down into
-- the freed strip: the book tipping forward off the shelf. The squashed
-- pixels come from the framebuffer capture; the block is REDRAWN taller
-- through FaceOutTopBlock's own painter, so tipping shows more page
-- lines rather than stretched ones. tile is the face-out CoverTile
-- (carries faceout_fx from rowWidget and _cover_card from its render).
-- Returns the affected region for the caller's refresh, or nothing.
function SpineShelf.paintFaceOutTilt(tile)
    local fx = tile and tile.faceout_fx
    local card = tile and tile._cover_card
    local rect = card and card.dimen
    if not (fx and rect and rect.x and rect.w and rect.w > 8 and rect.h > 16) then
        return
    end
    local bb = Screen.bb
    if not bb then return end
    local depth = fx.depth or 0
    local freed = rect.h - math.floor(rect.h * SpineShelf.TILT_FACE_SCALE)
    if freed < 2 then return end
    -- Face and top from the module's one 2.5D model (see TILT_FACE_SCALE):
    -- the standing block is the book's thickness at the resting view
    -- angle, so tipping scales it by TILT_TOP_SCALE -- a doorstop tips to
    -- show a broad top, a novella barely any. Capped by `freed` so the
    -- block can never rise above its standing top edge (and the refresh
    -- rect).
    local grow = math.min(math.floor(depth * (SpineShelf.TILT_TOP_SCALE - 1)),
                          freed)
    -- The opening tilt continues the selection lift (user ruling): the
    -- standing book rises the same clearance a selection would give it as
    -- it tips (fx.lift; zero when the wrapper was built already lifted --
    -- the capture is at the lifted position and what sits under it is the
    -- lift shadow, which this painter cannot reproduce).
    local lift  = fx.lift or 0
    local ny    = rect.y + freed - lift             -- squashed cover top
    local block_y = ny - (depth + grow)             -- tipped block top
    local top0  = rect.y - depth                    -- standing silhouette top
    local ok = pcall(function()
        -- Squash the cover toward its (raised) feet.
        local src = Blitbuffer.new(rect.w, rect.h, bb:getType())
        src:blitFrom(bb, 0, 0, rect.x, rect.y, rect.w, rect.h)
        local scaled = src:scale(rect.w, rect.h - freed)
        local dy, sy, hh = ny, 0, rect.h - freed
        if dy < 0 then sy = -dy; hh = hh + dy; dy = 0 end
        if hh > 0 then
            bb:blitFrom(scaled, rect.x, dy, 0, sy, rect.w, hh)
        end
        src:free()
        scaled:free()
        -- Page ground over whatever the rising silhouette no longer
        -- covers above the block (pre-invert space, same as the slot
        -- renders paint), then the block, dropped/risen to meet the
        -- squashed cover's top.
        if block_y > top0 then
            bb:paintRectRGB32(rect.x, top0, rect.w, block_y - top0,
                              Blitbuffer.ColorRGB32(0xFF, 0xFF, 0xFF, 0xFF))
        end
        local block = FaceOutTopBlock:new{
            dimen = Geom:new{ w = rect.w, h = depth + grow },
            look  = fx.look,
        }
        block:paintTo(bb, rect.x, block_y)
        -- The strip the rising foot vacates: the plank's own banded
        -- surface, reproduced the way the spine's lifted under-strip
        -- does it (fx tells us where the surface starts).
        if lift > 0 then
            local pb = fx.plank_b or Screen:scaleBySize(6)
            local pf = fx.plank_face or pb
            local surf_top = rect.y + rect.h + (fx.below or 0) - (3 * pb + pf)
            for yy = rect.y + rect.h - lift, rect.y + rect.h - 1 do
                if yy >= surf_top then
                    bb:paintRectRGB32(rect.x, yy, rect.w, 1,
                                      _plankBandColor(yy - surf_top, 3 * pb))
                else
                    bb:paintRectRGB32(rect.x, yy, rect.w, 1,
                                      Blitbuffer.ColorRGB32(0xFF, 0xFF, 0xFF, 0xFF))
                end
            end
        end
    end)
    if not ok then
        logger.dbg("[bookshelf] face-out opening tilt failed; skipping")
        return
    end
    -- Re-crisp the corner status glyphs at the squashed cover's new top:
    -- the capture carries their squashed ghosts, and the block redraw
    -- erased their above-card overhang; a full repaint shifted with the
    -- cover rides them along.
    if tile._overhang_glyph_widgets then
        for _i, gw in ipairs(tile._overhang_glyph_widgets) do
            local gd = gw.dimen
            if gd and gd.x and gd.w and gd.w > 0 then
                pcall(function() gw:paintTo(bb, gd.x, gd.y + freed - lift) end)
            end
        end
    end
    -- The lighting split (see the constants above): the page block tips
    -- INTO the front light and brightens; the cover face -- glyphs
    -- included, they sit on it -- darkens toward the shelf; and the
    -- hovering book casts down from its raised feet, over the strip it
    -- vacated and the plank in front.
    local band = fx.below or Screen:scaleBySize(10)
    pcall(function()
        local night = _nightMode()
        _lightRect(bb, rect.x, block_y, rect.w, depth + grow,
                   TILT_TOP_LIGHT, night)
        _shadeTiltFace(bb, rect.x, ny, rect.w, rect.h - freed, night)
        _shadeTiltCast(bb, rect.x, rect.y + rect.h - lift, rect.w,
                       lift + band, night)
    end)
    local top_all = math.min(top0, block_y)
    return rect.x, top_all, rect.w,
           (rect.y + rect.h + band) - top_all
end

-- drainTileStats() -> ms, n since the last drain: face-out tile build cost
-- (cover load included). Logged by the widget's spine turn summary.
function SpineShelf.drainTileStats()
    local ms, n = SpineShelf._tile_ms or 0, SpineShelf._tile_n or 0
    SpineShelf._tile_ms, SpineShelf._tile_n = 0, 0
    return ms, n
end

-- drainRenderStats() -> n, ms since the last drain: how many slot renders
-- (cache misses) a paint pass cost. Logged by the widget's perf lines.
function SpineShelf.drainRenderStats()
    local n, ms = SpineShelf._renders or 0, SpineShelf._render_ms or 0
    local samples = SpineShelf._samples or 0
    SpineShelf._renders, SpineShelf._render_ms, SpineShelf._samples = 0, 0, 0
    return n, ms, samples
end

SpineShelf._SpineBookSlot = SpineBookSlot  -- for tests

return SpineShelf
