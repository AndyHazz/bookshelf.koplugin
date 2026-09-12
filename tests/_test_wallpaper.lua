-- tests/_test_wallpaper.lua
-- The wallpaper model: which image a shelf shows, and what is on offer.
--
-- The rendering half (a scaled, night-aware ImageWidget) needs KOReader and is
-- exercised on device; everything here is the part that decides WHAT to draw,
-- which is where the rules live.
--
-- ── THE RESOLUTION RULE ─────────────────────────────────────────────────────
--
-- A wallpaper is per SHELF, not per library -- the point of the feature is
-- that a shelf can look like itself rather than every screen looking alike.
-- So there are two settings and three states, and they use the convention
-- this plugin already uses for per-book facts and per-chip pins:
--
--   a string   this shelf shows that file
--   false      this shelf shows NOTHING, even if the library has a default
--   absent     this shelf follows the library default
--
-- "false clears, absent inherits" is the same shape as the facts store's put()
-- and as the chip pins' unset-means-follow, so there is one rule to remember
-- rather than three.
--
-- Usage (from plugin root): lua tests/_test_wallpaper.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["logger"] = { dbg = function() end, info = function() end,
                             warn = function() end, err = function() end }
-- KOReader's Widget, in the two methods that matter: extend() makes a
-- subclass whose __index is the parent, new() instances it and calls init.
-- A stub that just handed the table back would have no :new at all.
do
    local W = {}
    W.extend = function(self, subclass)
        subclass = subclass or {}
        setmetatable(subclass, { __index = self })
        return subclass
    end
    W.new = function(self, o)
        o = o or {}
        setmetatable(o, { __index = self })
        if o.init then o:init() end
        return o
    end
    package.loaded["ui/widget/widget"] = W
end
-- Geom, in the one method these widgets use.
package.loaded["ui/geometry"] = {
    new = function(_self, o) return o or {} end,
}

local H = dofile("tests/_helpers.lua")
local t = H.runner()
local eq = H.eq

local function fresh()
    package.loaded["lib/bookshelf_wallpaper"] = nil
    return dofile("lib/bookshelf_wallpaper.lua")
end

-- Minimal lfs over shell + io, same approach as the ornaments suite.
local function sh(cmd)
    local f = io.popen(cmd .. " 2>/dev/null"); local o = f:read("*a"); f:close(); return o
end
local lfs_shim = {
    attributes = function(path, attr)
        local q = "'" .. path .. "'"
        if attr == "mode" then
            if sh("test -d " .. q .. " && echo d"):match("d") then return "directory" end
            if sh("test -e " .. q .. " && echo f"):match("f") then return "file" end
            return nil
        elseif attr == "modification" then
            return tonumber(sh("stat -c %Y " .. q))
        end
    end,
    mkdir = function(path) return os.execute("mkdir -p '" .. path .. "'") end,
    dir = function(path)
        local list = {}
        for name in sh("ls -a '" .. path .. "'"):gmatch("[^\n]+") do list[#list + 1] = name end
        local i = 0
        return function() i = i + 1; return list[i] end
    end,
}

local tmp = os.getenv("TMPDIR") or "/tmp"
local function scratch()
    local d = string.format("%s/bookshelf_wp_test_%d_%d", tmp, os.time(), math.random(1e6))
    os.execute("rm -rf '" .. d .. "' && mkdir -p '" .. d .. "'")
    return d
end
local function touch(dir, name)
    local f = io.open(dir .. "/" .. name, "w"); f:write("x"); f:close()
end

-- Shared stubs: a fake blitbuffer, and a fake inner widget for the mask.
local function fakeBB(w, h)
    local bb = { w = w, h = h, filled = nil, inverted = false, ops = {} }
    function bb:getWidth() return self.w end
    function bb:getHeight() return self.h end
    function bb:fill(c) self.filled = c; self.ops[#self.ops+1] = "fill" end
    function bb:invertRect() self.inverted = true; self.ops[#self.ops+1] = "invert" end
    function bb:free() self.freed = true end
    return bb
end

local function installBlitbufferStub(made)
    package.loaded["ffi/blitbuffer"] = {
        TYPE_BB8 = 1,
        COLOR_WHITE = "WHITE",
        COLOR_BLACK = "BLACK",
        new = function(w, h)
            local bb = fakeBB(w, h)
            made[#made + 1] = bb
            return bb
        end,
    }
end

local function fakeInner(w, h, log)
    return {
        getSize = function() return { w = w, h = h } end,
        paintTo = function(_self, target, x, y)
            log[#log + 1] = { target = target, x = x, y = y }
            if target.ops then target.ops[#target.ops+1] = "inner" end
        end,
    }
end


-- ── resolve: shelf over library, with an explicit "none" ───────────────────

t.test("resolve: a shelf's own choice wins", function()
    local W = fresh()
    eq(W.resolve("dunes.jpg", "default.png"), "dunes.jpg")
end)

t.test("resolve: a shelf with no opinion follows the library default", function()
    local W = fresh()
    eq(W.resolve(nil, "default.png"), "default.png")
end)

t.test("resolve: FALSE is a shelf saying none, and outranks the default", function()
    -- Without this there is no way to have a plain shelf in a library that
    -- has a default -- you would have to clear the default and set every
    -- other shelf individually.
    local W = fresh()
    assert(W.resolve(false, "default.png") == nil,
        "an explicit none must beat the library default")
end)

t.test("resolve: nothing set anywhere is no wallpaper", function()
    local W = fresh()
    assert(W.resolve(nil, nil) == nil)
    assert(W.resolve(false, nil) == nil)
end)

t.test("resolve: an empty string counts as absent, not as a filename", function()
    -- A cleared text field writes "" rather than nil in more than one place
    -- in this plugin; treating it as a filename would look for a file called
    -- "" and quietly show nothing with no way to tell why.
    local W = fresh()
    eq(W.resolve("", "default.png"), "default.png")
    assert(W.resolve("", "") == nil)
end)

t.test("resolve: a non-string shelf value is ignored, not stringified", function()
    -- A hand-edited settings file, or a value written by a later release.
    local W = fresh()
    eq(W.resolve({ name = "x" }, "default.png"), "default.png")
    eq(W.resolve(42, "default.png"), "default.png")
end)

-- ── list: what the picker offers ───────────────────────────────────────────

t.test("list: picks up the image formats and ignores everything else", function()
    local W = fresh()
    local d = scratch()
    W._data_dir = d; W._lfs = lfs_shim
    W.ensureDir()
    for _, n in ipairs({ "beach.jpg", "wood.PNG", "tile.webp", "notes.txt",
                         "cover.svg" }) do
        touch(W.dir(), n)
    end
    local items = W.list()
    eq(#items, 3, "jpg + png + webp; the txt and the svg are not wallpapers")
    os.execute("rm -rf '" .. d .. "'")
end)

t.test("list: sorted, with the extension stripped for the label", function()
    local W = fresh()
    local d = scratch()
    W._data_dir = d; W._lfs = lfs_shim
    W.ensureDir()
    touch(W.dir(), "zebra.jpg"); touch(W.dir(), "apple.png")
    local items = W.list()
    eq(items[1].name, "apple.png")
    eq(items[1].label, "apple", "the picker shows a name, not a filename")
    eq(items[2].label, "zebra")
    assert(items[1].path:match("apple%.png$"), "path should be absolute-ish")
    os.execute("rm -rf '" .. d .. "'")
end)

t.test("list: a new file appears without a restart", function()
    -- The lesson from the ornaments folder, which shares the scan helper:
    -- an mtime-only cache misses a same-second addition and every deletion.
    local W = fresh()
    local d = scratch()
    W._data_dir = d; W._lfs = lfs_shim
    W.ensureDir()
    touch(W.dir(), "one.png")
    eq(#W.list(), 1)
    touch(W.dir(), "two.png")
    eq(#W.list(), 2, "the newcomer must show up on the next look")
    os.remove(W.dir() .. "/one.png")
    eq(#W.list(), 1, "and a removal must drop out")
    os.execute("rm -rf '" .. d .. "'")
end)

t.test("list: an empty folder is empty, not an error", function()
    local W = fresh()
    local d = scratch()
    W._data_dir = d; W._lfs = lfs_shim
    W.ensureDir()
    eq(#W.list(), 0)
    os.execute("rm -rf '" .. d .. "'")
end)

-- ── the background widget owns the whole screen ───────────────────────────
--
-- The page frame above it is screen-sized and cannot do partial coverage: let
-- it fill and it paints over the bands; stop it filling and the excluded bands
-- are never painted at all, so the previous frame survives there. Both were
-- shipped, in that order. The widget therefore lays the ground down itself and
-- puts the picture on top.

local function paintTarget()
    local t = { ops = {} }
    function t:getWidth() return 100 end
    function t:getHeight() return 100 end
    function t:blitFrom(_src, dx, dy, ox, oy, w, h)
        self.ops[#self.ops + 1] = { op = "blit", dy = dy, oy = oy, h = h }
    end
    function t:paintRect(x, y, w, h, c)
        self.ops[#self.ops + 1] = { op = "fill", w = w, h = h, c = c }
    end
    function t:paintRectRGB32(x, y, w, h, c)
        self.ops[#self.ops + 1] = { op = "fill32", w = w, h = h, c = c }
    end
    return t
end

t.test("background: all regions on is ONE blit and no fill", function()
    local W = fresh()
    local made = {}
    installBlitbufferStub(made)
    W._lfs = lfs_shim
    local d = scratch()
    W._data_dir = d; W.ensureDir(); touch(W.dir(), "a.png")
    W._render = function(_p, w, h) return fakeBB(w, h) end
    local wg = W.bg("a.png", 100, 100, false)
    assert(wg, "should have built a background")
    local t = paintTarget()
    wg:paintTo(t, 0, 0)
    eq(#t.ops, 1, "one operation")
    eq(t.ops[1].op, "blit", "and it is the picture, not a fill")
    os.execute("rm -rf '" .. d .. "'")
    package.loaded["ffi/blitbuffer"] = nil
end)

t.test("background: a banded picture fills the ground FIRST, then blits", function()
    local W = fresh()
    local made = {}
    installBlitbufferStub(made)
    package.loaded["ffi/blitbuffer"].isColor8 = function() return true end
    W._lfs = lfs_shim
    local d = scratch()
    W._data_dir = d; W.ensureDir(); touch(W.dir(), "a.png")
    W._render = function(_p, w, h) return fakeBB(w, h) end
    local wg = W.bg("a.png", 100, 100, false)
    wg.bands  = { { y = 0, h = 30 }, { y = 70, h = 30 } }
    wg.ground = "GREY"
    local t = paintTarget()
    wg:paintTo(t, 0, 0)
    eq(t.ops[1].op, "fill", "the excluded bands must be PAINTED, not skipped")
    eq(t.ops[1].h, 100, "the ground covers the whole widget")
    eq(t.ops[1].c, "GREY")
    eq(#t.ops, 3, "ground plus the two bands")
    eq(t.ops[2].dy, 0);  eq(t.ops[2].oy, 0);  eq(t.ops[2].h, 30)
    eq(t.ops[3].dy, 70); eq(t.ops[3].oy, 70, "a band shows ITS part of the picture")
    os.execute("rm -rf '" .. d .. "'")
    package.loaded["ffi/blitbuffer"] = nil
end)

t.test("background: every region off still paints the ground", function()
    -- Otherwise turning them all off leaves the last frame on screen.
    local W = fresh()
    local made = {}
    installBlitbufferStub(made)
    package.loaded["ffi/blitbuffer"].isColor8 = function() return true end
    W._lfs = lfs_shim
    local d = scratch()
    W._data_dir = d; W.ensureDir(); touch(W.dir(), "a.png")
    W._render = function(_p, w, h) return fakeBB(w, h) end
    local wg = W.bg("a.png", 100, 100, false)
    wg.bands, wg.ground = {}, "GREY"
    local t = paintTarget()
    wg:paintTo(t, 0, 0)
    eq(#t.ops, 1); eq(t.ops[1].op, "fill")
    os.execute("rm -rf '" .. d .. "'")
    package.loaded["ffi/blitbuffer"] = nil
end)

-- ── bandsFor: which stripes of the picture are allowed ────────────────────
--
-- Bands follow the shelf's own seams (hero across the top, shelves in the
-- middle, footer pinned to the bottom) because a region that did not would
-- cut through a row.

local GEOM = { hero_h = 300, footer_y = 900, height = 1000 }

t.test("bands: everything on comes back as nil, so it stays one blit", function()
    local W = fresh()
    assert(W.bandsFor({ hero = true, shelf = true, footer = true }, GEOM) == nil,
        "the common case must not pay for banding")
end)

t.test("bands: one region off leaves the others", function()
    local W = fresh()
    local b = W.bandsFor({ hero = false, shelf = true, footer = true }, GEOM)
    eq(#b, 1, "shelf and footer are adjacent, so they merge")
    eq(b[1].y, 300); eq(b[1].h, 700)
end)

t.test("bands: a gap in the middle gives two separate stripes", function()
    local W = fresh()
    local b = W.bandsFor({ hero = true, shelf = false, footer = true }, GEOM)
    eq(#b, 2, "hero and footer do not touch, so they cannot merge")
    eq(b[1].y, 0);   eq(b[1].h, 300)
    eq(b[2].y, 900); eq(b[2].h, 100)
end)

t.test("bands: adjacent bands merge into one blit", function()
    local W = fresh()
    local b = W.bandsFor({ hero = true, shelf = true, footer = false }, GEOM)
    eq(#b, 1)
    eq(b[1].y, 0); eq(b[1].h, 900)
end)

t.test("bands: everything off paints nothing at all", function()
    local W = fresh()
    local b = W.bandsFor({ hero = false, shelf = false, footer = false }, GEOM)
    eq(#b, 0, "an empty list, NOT nil -- nil means paint it all")
end)

t.test("bands: a zero-height region is dropped rather than blitted empty", function()
    -- The hero is absent when the shelf is expanded, so hero_h is 0.
    local W = fresh()
    local b = W.bandsFor({ hero = true, shelf = true, footer = false },
                         { hero_h = 0, footer_y = 900, height = 1000 })
    eq(#b, 1); eq(b[1].y, 0); eq(b[1].h, 900)
end)

t.test("bands: nonsense geometry is refused, not clamped into a wrong answer", function()
    local W = fresh()
    assert(W.bandsFor(nil, GEOM) == nil)
    assert(W.bandsFor({ hero = false }, nil) == nil)
    assert(W.bandsFor({ hero = false }, { height = 0 }) == nil)
end)

t.test("bands: a footer_y past the screen is clamped, not trusted", function()
    local W = fresh()
    local b = W.bandsFor({ hero = true, shelf = true, footer = false },
                         { hero_h = 300, footer_y = 5000, height = 1000 })
    eq(#b, 1); eq(b[1].h, 1000, "the shelf simply reaches the bottom")
end)

-- ── regions and transparent buttons: the defaults are the contract ─────────

t.test("regionOn: unset means ON, which is the whole-screen behaviour", function()
    local W = fresh()
    local read = function() return nil end
    for _, r in ipairs(W.REGIONS) do
        assert(W.regionOn(read, r.key), r.key .. " should default on")
    end
end)

t.test("regionOn: false turns a band off, true keeps it", function()
    local W = fresh()
    local store = { wallpaper_region_hero = false, wallpaper_region_shelf = true }
    local read = function(k) return store[k] end
    assert(W.regionOn(read, "wallpaper_region_hero") == false)
    assert(W.regionOn(read, "wallpaper_region_shelf") == true)
    assert(W.regionOn(read, "wallpaper_region_footer") == true, "still unset, still on")
end)

t.test("regionOn: no reader at all answers ON rather than blank", function()
    -- Called from paint paths; a missing settings store must not silently
    -- turn the whole feature off.
    local W = fresh()
    assert(W.regionOn(nil, "wallpaper_region_hero") == true)
end)

t.test("transparentButtons: OFF unless asked for", function()
    local W = fresh()
    assert(W.transparentButtons(function() return nil end) == false,
        "legibility is the safe default")
    assert(W.transparentButtons(function() return true end) == true)
    assert(W.transparentButtons(nil) == false)
end)

t.test("REGIONS: three bands, each with a key and a label", function()
    local W = fresh()
    eq(#W.REGIONS, 3)
    for _, r in ipairs(W.REGIONS) do
        assert(type(r.key) == "string" and r.key ~= "")
        assert(type(r.label) == "string" and r.label ~= "")
    end
end)

-- ── unfill: chrome that must stop painting its own page ────────────────────
--
-- KOReader's Button has no transparent mode. It builds a FrameContainer with
-- background = COLOR_WHITE unless you give it a colour, in which case it
-- drops the border and rounds the corners -- so "make it see-through" is not
-- something the constructor can express. Clearing frame.background afterwards
-- is the way, and it is what Button itself does internally when it wants a
-- borderless state (button.lua stashes orig_background and nils the field).
-- FrameContainer then skips the fill entirely: `if self.background then`.

t.test("unfill: clears the frame fill when a wallpaper is up", function()
    local W = fresh()
    local btn = { frame = { background = "white" } }
    W.unfill(true, btn)
    assert(btn.frame.background == nil, "the fill should be gone")
end)

t.test("unfill: leaves the chrome alone when there is no wallpaper", function()
    -- On a plain page the white fill is CORRECT -- it is what makes a button
    -- read as a button against the page. This only applies when something is
    -- behind it.
    local W = fresh()
    local btn = { frame = { background = "white" } }
    W.unfill(false, btn)
    eq(btn.frame.background, "white", "an unbacked page keeps its buttons opaque")
end)

t.test("unfill: takes several widgets at once and hands them back", function()
    local W = fresh()
    local a = { frame = { background = "white" } }
    local b = { frame = { background = "white" } }
    local ra, rb = W.unfill(true, a, b)
    assert(ra == a and rb == b, "returns its arguments so it can wrap a build")
    assert(a.frame.background == nil and b.frame.background == nil)
end)

t.test("unfill: turns an icon's alpha on, which is the other half of the box", function()
    -- ImageWidget defaults alpha = false and Button never sets it, so the
    -- icon SVG is flattened onto white and blitted opaquely. Clearing only
    -- the frame leaves a white square exactly icon-sized -- which is what the
    -- chevrons showed on device while the text-only page counter came out
    -- clean.
    local W = fresh()
    local freed = false
    local btn = {
        frame = { background = "white" },
        label_widget = { alpha = false, _bb = { free = function() freed = true end },
                         _bb_disposable = true },
    }
    W.unfill(true, btn)
    assert(btn.label_widget.alpha == true, "the icon must blend, not blit")
    assert(btn.label_widget._bb == nil, "a flat render must not be reused")
    assert(freed, "and it should be freed, not leaked")
end)

t.test("unfill: an icon that already blends is left alone", function()
    local W = fresh()
    local bb = {}
    local btn = { label_widget = { alpha = true, _bb = bb, _bb_disposable = true } }
    W.unfill(true, btn)
    assert(btn.label_widget._bb == bb, "no reason to throw away a good render")
end)

t.test("unfill: a DISABLED icon dims by mask, not by washing its rect", function()
    -- ImageWidget dims with `bb:lightenRect(x, y, size.w, size.h)`, which on
    -- paper greys a black glyph and over a wallpaper bleaches a pale square
    -- out of the image. KOReader's own comment above that line proposes the
    -- alpha-mask fix and never took it; this is that fix.
    local W = fresh()
    local made = {}
    installBlitbufferStub(made)
    package.loaded["ffi/blitbuffer"].COLOR_DARK_GRAY = "DARKGRAY"
    local icon = { alpha = false, dim = true,
                   getSize = function() return { w = 8, h = 8 } end,
                   paintTo = function() end }
    local btn = { enabled = false, frame = { background = "white" },
                  label_widget = icon, label_container = { icon } }
    W.unfill(true, btn)
    assert(icon.dim == false, "the rect wash has to stop")
    assert(btn.label_container[1] ~= icon,
        "the container should now hold a masked stand-in")
    package.loaded["ffi/blitbuffer"] = nil
end)

t.test("unfill: an ENABLED icon is not masked, only made to blend", function()
    local W = fresh()
    local made = {}
    installBlitbufferStub(made)
    local icon = { alpha = false, dim = false }
    local btn = { enabled = true, label_widget = icon, label_container = { icon } }
    W.unfill(true, btn)
    assert(btn.label_container[1] == icon, "no mask needed when it is not dimmed")
    assert(icon.alpha == true, "but it still has to blend")
    package.loaded["ffi/blitbuffer"] = nil
end)

-- ── eraser: opaque-on-purpose chrome ───────────────────────────────────────

t.test("eraser: nothing to erase with when there is no wallpaper", function()
    local W = fresh()
    assert(W.eraser(false, 10, 10) == nil,
        "the caller should keep its opaque fill, which is correct on paper")
    assert(W.eraser(true, 0, 10) == nil, "and a zero rect is not a widget")
end)

t.test("eraser: paints the wallpaper back over exactly its own rect", function()
    local W = fresh()
    local made = {}
    installBlitbufferStub(made)
    -- A cached background the eraser can restore from, screen-sized.
    W._bg = { bb = fakeBB(100, 100), w = 100, h = 100 }
    local e = W.eraser(true, 12, 9)
    local target = { blits = {} }
    function target:getWidth() return 100 end
    function target:getHeight() return 100 end
    function target:blitFrom(src, dx, dy, ox, oy, w, h)
        self.blits[#self.blits + 1] = { dx = dx, dy = dy, ox = ox, oy = oy, w = w, h = h }
    end
    e:paintTo(target, 20, 30)
    eq(#target.blits, 1)
    local b = target.blits[1]
    eq(b.dx, 20); eq(b.dy, 30); eq(b.w, 12); eq(b.h, 9)
    eq(b.ox, 20, "source offset must equal the screen position")
    eq(b.oy, 30, "the wallpaper is painted at 0,0, so screen x,y IS image x,y")
    package.loaded["ffi/blitbuffer"] = nil
end)

t.test("restore: refuses an offscreen target rather than pasting the wrong pixels", function()
    -- A widget rendering into its own buffer passes buffer-relative
    -- coordinates; blitting a screen-indexed image into it would paste some
    -- other part of the picture.
    local W = fresh()
    W._bg = { bb = {}, w = 100, h = 100 }
    local small = { getWidth = function() return 40 end,
                    getHeight = function() return 40 end,
                    blitFrom = function() error("must not be reached") end }
    assert(W.restore(small, 0, 0, 4, 4) == false, "an offscreen target is refused")
end)

t.test("unfill: survives nils, non-tables and widgets with no frame", function()
    -- Callers pass whatever a build produced, and a build can legitimately
    -- produce nil (a button that is not shown in this state).
    local W = fresh()
    local ok = pcall(function()
        W.unfill(true, nil, 42, "x", {}, { frame = false })
    end)
    assert(ok, "unfill must not care what it is handed")
end)

-- ── mask: making opaque text see-through ───────────────────────────────────
--
-- Verified against REAL blitbuffers before the code was written (the
-- arithmetic came out exact), so these pin the wiring rather than the maths:
-- that it paints the widget onto white, inverts, and colorblits -- in that
-- order -- and that it gets out of the way entirely when there is no
-- wallpaper.

t.test("mask: returns the widget untouched when no wallpaper is up", function()
    local W = fresh()
    local inner = fakeInner(10, 10, {})
    assert(W.mask(false, inner) == inner,
        "with nothing behind it, opaque text is correct and cheaper")
end)

t.test("mask: paints onto white, inverts, THEN colorblits", function()
    local W = fresh()
    local made, painted = {}, {}
    installBlitbufferStub(made)
    local inner = fakeInner(40, 20, painted)
    local m = W.mask(true, inner)
    local out = { blits = {} }
    function out:colorblitFrom(src, x, y, ox, oy, w, h, colour)
        self.blits[#self.blits + 1] = { w = w, h = h, colour = colour, x = x, y = y }
    end
    m:paintTo(out, 7, 9)
    local scratch = made[1]
    assert(scratch, "a scratch buffer should have been made")
    eq(table.concat(scratch.ops, ","), "fill,inner,invert",
       "order matters: a white ground, the widget on it, then the inversion")
    eq(scratch.filled, "WHITE", "the ground must be white or the mask is wrong")
    eq(#out.blits, 1, "one colorblit")
    eq(out.blits[1].colour, "BLACK", "pre-invert space: black displays white at night")
    eq(out.blits[1].x, 7); eq(out.blits[1].y, 9)
    eq(out.blits[1].w, 40); eq(out.blits[1].h, 20)
    package.loaded["ffi/blitbuffer"] = nil
end)

t.test("mask: the inner widget paints at the scratch's origin, not the screen's", function()
    -- The scratch is widget-sized, so the widget must land at 0,0 in it --
    -- painting at the screen offset would push the text off the mask.
    local W = fresh()
    local made, painted = {}, {}
    installBlitbufferStub(made)
    local m = W.mask(true, fakeInner(40, 20, painted))
    local out = { colorblitFrom = function() end }
    m:paintTo(out, 100, 200)
    eq(painted[1].x, 0); eq(painted[1].y, 0)
    package.loaded["ffi/blitbuffer"] = nil
end)

t.test("mask: builds once and reuses, not once per frame", function()
    local W = fresh()
    local made, painted = {}, {}
    installBlitbufferStub(made)
    local m = W.mask(true, fakeInner(40, 20, painted))
    local out = { colorblitFrom = function() end }
    m:paintTo(out, 0, 0); m:paintTo(out, 0, 0); m:paintTo(out, 0, 0)
    eq(#made, 1, "three paints, one mask")
    eq(#painted, 1, "and the inner widget rendered once")
    package.loaded["ffi/blitbuffer"] = nil
end)

t.test("mask: a failed build falls back to painting the widget as it is", function()
    -- Unreadable text would be a worse outcome than an opaque block of it.
    local W = fresh()
    package.loaded["ffi/blitbuffer"] = {
        TYPE_BB8 = 1, COLOR_WHITE = "WHITE", COLOR_BLACK = "BLACK",
        new = function() error("out of memory") end,
    }
    local painted = {}
    local m = W.mask(true, fakeInner(40, 20, painted))
    local out = { colorblitFrom = function() error("should not reach here") end }
    local ok = pcall(function() m:paintTo(out, 3, 4) end)
    assert(ok, "a failed mask must not take the paint down")
    eq(#painted, 1, "the widget itself should have been painted instead")
    eq(painted[1].x, 3, "and at the real screen position")
    package.loaded["ffi/blitbuffer"] = nil
end)

t.test("mask: reports the inner widget's size, so layout is unchanged", function()
    local W = fresh()
    local made = {}
    installBlitbufferStub(made)
    local m = W.mask(true, fakeInner(123, 45, {}))
    eq(m:getSize().w, 123); eq(m:getSize().h, 45)
    package.loaded["ffi/blitbuffer"] = nil
end)

-- ── pathFor: a name only means anything if the file is still there ─────────

t.test("pathFor: a present file resolves to its path", function()
    local W = fresh()
    local d = scratch()
    W._data_dir = d; W._lfs = lfs_shim
    W.ensureDir()
    touch(W.dir(), "beach.jpg")
    assert(W.pathFor("beach.jpg"):match("beach%.jpg$"), "got " .. tostring(W.pathFor("beach.jpg")))
    os.execute("rm -rf '" .. d .. "'")
end)

t.test("pathFor: a name whose file has gone resolves to nothing", function()
    -- A shelf pinned to a wallpaper the user later deleted must fall back to
    -- a plain background, not to a broken paint or an error every frame.
    local W = fresh()
    local d = scratch()
    W._data_dir = d; W._lfs = lfs_shim
    W.ensureDir()
    assert(W.pathFor("vanished.jpg") == nil)
    assert(W.pathFor(nil) == nil)
    assert(W.pathFor("") == nil)
    os.execute("rm -rf '" .. d .. "'")
end)

t.test("pathFor: a name with a path separator is refused", function()
    -- Wallpaper names come from settings, which a user can hand-edit. The
    -- folder is the whole namespace; "../../etc/passwd" is not a wallpaper.
    -- Same reasoning as the updater's traversal fix.
    local W = fresh()
    local d = scratch()
    W._data_dir = d; W._lfs = lfs_shim
    W.ensureDir()
    touch(W.dir(), "ok.png")
    assert(W.pathFor("../ok.png") == nil, "no climbing out of the folder")
    assert(W.pathFor("sub/ok.png") == nil, "no reaching into subfolders")
    assert(W.pathFor("ok.png") ~= nil, "a plain name still works")
    os.execute("rm -rf '" .. d .. "'")
end)

t.done()
