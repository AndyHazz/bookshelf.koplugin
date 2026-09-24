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
    local W = dofile("lib/bookshelf_wallpaper.lua")
    -- Seeding OFF by default in this suite. ensureDir seeds a freshly created
    -- folder, and every scratch folder here is freshly created -- so left on,
    -- the shipped picture lands in all of them and skews the list counts. The
    -- seeding test points this back at the real folder for itself.
    W.SEED_SUBDIR = "tests/no-such-seed-dir"
    return W
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
    -- TWO return values, like the real thing, and an iterator that REFUSES to
    -- run without its state. lfs.dir returns (iterator, directory_object);
    -- code that keeps only the first and drops the second dies on "directory
    -- metatable expected, got nil". The old shim returned a single self-
    -- contained closure, so it could not tell correct code from that -- and
    -- did not: the bundled wallpaper was never copied on any device, for a
    -- month, with this suite green throughout.
    dir = function(path)
        local list = {}
        for name in sh("ls -a '" .. path .. "'"):gmatch("[^\n]+") do list[#list + 1] = name end
        local state = { i = 0, __isdir = true }
        local function iter(st)
            if type(st) ~= "table" or not st.__isdir then
                error("bad argument #1 to '(for generator)' (directory "
                      .. "metatable expected, got " .. type(st) .. ")", 2)
            end
            st.i = st.i + 1
            return list[st.i]
        end
        return iter, state
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

-- ── Other folders that hold wallpapers ───────────────────────────────
-- A reader who keeps pictures for another tool (a screensaver folder, a
-- home-screen plugin's folder) should not have to copy them.
t.test("other folders: their images join the list and resolve, ours untouched", function()
    local W = fresh()
    local d = scratch()
    W._data_dir = d; W._lfs = lfs_shim
    W.ensureDir()
    touch(W.dir(), "ours.jpg")
    os.execute("mkdir -p '" .. d .. "/screensaver' '" .. d .. "/missing_parent_is_fine'")
    touch(d .. "/screensaver", "sea.jpg")
    touch(d .. "/screensaver", "notes.txt")
    W.EXTRA_DIRS = { d .. "/screensaver", d .. "/does-not-exist" }
    local items = W.list()
    local found
    for _, it in ipairs(items) do if it.name == "screensaver:sea.jpg" then found = it end end
    assert(found, "the screensaver folder's sea.jpg is not offered")
    eq(found.label, "sea", "a unique label carries no folder suffix")
    eq(#items, 2, "ours plus theirs; the txt is not a wallpaper")
    eq(W.pathFor("screensaver:sea.jpg"), d .. "/screensaver/sea.jpg")
    eq(W.pathFor("screensaver:../ours.jpg"), nil, "no walking out of a folder")
    eq(W.pathFor("screensaver:gone.jpg"), nil)
    eq(W.pathFor("nosuch:sea.jpg"), nil, "an unknown folder token resolves to nothing")
    eq(lfs_shim.attributes(d .. "/does-not-exist", "mode"), nil, "a listed folder is never created")
    os.execute("rm -rf '" .. d .. "'")
end)

t.test("other folders: a name shared between folders is told apart by its folder", function()
    local W = fresh()
    local d = scratch()
    W._data_dir = d; W._lfs = lfs_shim
    W.ensureDir()
    touch(W.dir(), "sea.jpg")
    os.execute("mkdir -p '" .. d .. "/Wallpapers'")
    touch(d .. "/Wallpapers", "sea.jpg")
    W.EXTRA_DIRS = { d .. "/Wallpapers" }
    local labels = {}
    for _, it in ipairs(W.list()) do labels[#labels + 1] = it.label end
    table.sort(labels)
    eq(labels[1], "sea (Wallpapers)")
    eq(labels[2], "sea (wallpapers)")
    os.execute("rm -rf '" .. d .. "'")
end)

t.test("other folders: a file added there appears without a restart", function()
    local W = fresh()
    local d = scratch()
    W._data_dir = d; W._lfs = lfs_shim
    W.ensureDir()
    os.execute("mkdir -p '" .. d .. "/Wallpapers'")
    W.EXTRA_DIRS = { d .. "/Wallpapers" }
    eq(#W.list(), 0)
    touch(d .. "/Wallpapers", "new.png")
    eq(#W.list(), 1, "the other folder is part of the cache key")
    os.execute("rm -rf '" .. d .. "'")
end)

t.test("a wallpaper folder of the reader's own is listed and resolves (issue 419)", function()
    local W = fresh()
    local d = scratch()
    W._data_dir = d; W._lfs = lfs_shim
    local kv = {}
    package.loaded["lib/bookshelf_settings_store"] = {
        read = function(k) return kv[k] end,
        save = function(k, v) kv[k] = v end,
        delete = function(k) kv[k] = nil end,
        flush = function() end,
    }
    W.ensureDir()
    os.execute("mkdir -p '" .. d .. "/mine'")
    touch(d .. "/mine", "fern.jpg")
    eq(#W.list(), 0, "not read before it is chosen")
    W.setUserDir(d .. "/mine/")
    eq(W.userDir(), d .. "/mine", "stored without the trailing slash")
    local list = W.list()
    eq(#list, 1)
    eq(list[1].name, "mine:fern.jpg")
    eq(W.pathFor("mine:fern.jpg"), d .. "/mine/fern.jpg")
    W.setUserDir(nil)
    eq(kv[W.USER_DIR_SETTING], nil)
    eq(#W.list(), 0, "gone again once cleared")
    eq(W.pathFor("mine:fern.jpg"), nil, "and a selection from it reads as none")
    package.loaded["lib/bookshelf_settings_store"] = nil
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





t.test("backdrop: refuses a buffer that is not screen-sized", function()
    local W = fresh()
    W._bg = { bb = {}, w = 100, h = 100, paintTo = function() error("no") end }
    local small = { getWidth = function() return 40 end,
                    getHeight = function() return 40 end }
    assert(W.backdrop(small) == false)
    assert(W.backdrop(nil) == false)
end)

t.test("backdrop: answers false when there is no wallpaper to paint", function()
    -- The caller then fills the page ground itself rather than leaving black.
    local W = fresh()
    W._bg = nil
    local t = paintTarget()
    assert(W.backdrop(t) == false)
    eq(#t.ops, 0)
end)

-- ── bandsFor: which stripes of the picture are allowed ────────────────────
--
-- Bands follow the shelf's own seams (hero across the top, shelves in the
-- middle, footer pinned to the bottom) because a region that did not would
-- cut through a row.

local GEOM = { hero_h = 300, footer_y = 900, height = 1000 }












t.test("transparentButtons: OFF unless asked for", function()
    local W = fresh()
    assert(W.transparentButtons(function() return nil end) == false,
        "legibility is the safe default")
    assert(W.transparentButtons(function() return true end) == true)
    assert(W.transparentButtons(nil) == false)
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

-- ── recolourIcons: a custom icon that brought its own colour ───────────────
--
-- People swap KOReader's chevrons for their own SVGs (cat paws are a common
-- one). Those are user files, they can be any colour, and the mask has one:
-- run it over an orange paw and an orange paw is what you stop having.

-- pixels(x, y) -> r, g, b, alpha
local function fakeIconBB(w, h, pixels)
    return {
        getWidth  = function() return w end,
        getHeight = function() return h end,
        getPixel  = function(_self, x, y)
            local r, g, b, a = pixels(x, y)
            return { getColorRGB32 = function()
                return { r = r, g = g, b = b, alpha = a or 0xFF }
            end }
        end,
    }
end

local function fakeIcon(file, bb)
    return { alpha = true, dim = false, icon = file, file = file, _bb = bb,
             width = 32, height = 32,
             getSize = function() return { w = 32, h = 32 } end,
             paintTo = function() end }
end

t.test("iconHasColour: stock line art is grey, whatever the ink", function()
    local W = fresh()
    -- A black glyph on nothing: r == g == b at every sample.
    local bb = fakeIconBB(32, 32, function(x, y)
        local v = ((x + y) % 2 == 0) and 0 or 0xFF
        return v, v, v, 0xFF
    end)
    assert(W.iconHasColour(fakeIcon("chevron.left", bb)) == false,
        "greyscale art must not be mistaken for a colour icon")
end)

t.test("iconHasColour: one chromatic pixel is enough", function()
    local W = fresh()
    local bb = fakeIconBB(32, 32, function(x, y)
        if x == 16 and y == 16 then return 0xE8, 0x83, 0x3A, 0xFF end
        return 0x40, 0x40, 0x40, 0xFF
    end)
    assert(W.iconHasColour(fakeIcon("paw", bb)) == true,
        "a coloured icon has to be recognised as one")
end)

t.test("iconHasColour: samples on a stride, so it must not miss a whole limb", function()
    -- The scan steps rather than reading every pixel. A colour that fills a
    -- quarter of the icon has to be found however the stride lands.
    local W = fresh()
    local bb = fakeIconBB(64, 64, function(x, y)
        if x >= 32 and y >= 32 then return 0xE8, 0x83, 0x3A, 0xFF end
        return 0, 0, 0, 0xFF
    end)
    assert(W.iconHasColour(fakeIcon("paw-quarter", bb)) == true,
        "a stride that coarse would miss real artwork")
end)

t.test("iconHasColour: a transparent ground carries junk RGB and must not count", function()
    -- NanoSVG hands back straight alpha: the RGB behind alpha 0 is whatever
    -- the rasteriser left there, frequently not grey and never visible.
    local W = fresh()
    local bb = fakeIconBB(32, 32, function(x, y)
        if x == 16 and y == 16 then return 0, 0, 0, 0xFF end
        return 0xFF, 0x00, 0x00, 0x00
    end)
    assert(W.iconHasColour(fakeIcon("mono-on-junk", bb)) == false,
        "invisible pixels decided the answer")
end)

t.test("iconHasColour: the verdict is cached per file, not re-scanned per paint", function()
    local W = fresh()
    local reads = 0
    local bb = fakeIconBB(32, 32, function() reads = reads + 1; return 0, 0, 0, 0xFF end)
    W.iconHasColour(fakeIcon("chevron.left", bb))
    local first = reads
    assert(first > 0, "nothing was sampled at all")
    W.iconHasColour(fakeIcon("chevron.left", bb))
    eq(reads, first, "the second call rescanned the bitmap")
end)

t.test("recolourIcons: leaves a coloured icon exactly as the user drew it", function()
    local W = fresh()
    local made = {}
    installBlitbufferStub(made)
    local bb = fakeIconBB(32, 32, function() return 0xE8, 0x83, 0x3A, 0xFF end)
    local icon = fakeIcon("paw", bb)
    local btn = { enabled = true, label_widget = icon, label_container = { icon } }
    W.recolourIcons(true, "WHITE", btn)
    assert(btn.label_container[1] == icon,
        "a colour icon was flattened to a single-ink silhouette")
    package.loaded["ffi/blitbuffer"] = nil
end)

t.test("recolourIcons: still repaints stock monochrome art, which is the point", function()
    local W = fresh()
    local made = {}
    installBlitbufferStub(made)
    local bb = fakeIconBB(32, 32, function() return 0, 0, 0, 0xFF end)
    local icon = fakeIcon("chevron.left", bb)
    local btn = { enabled = true, label_widget = icon, label_container = { icon } }
    W.recolourIcons(true, "WHITE", btn)
    assert(btn.label_container[1] ~= icon,
        "black line art on a dark panel is invisible -- it must be masked")
    package.loaded["ffi/blitbuffer"] = nil
end)

t.test("iconHasColour: says no when there is nothing to look at", function()
    local W = fresh()
    assert(W.iconHasColour(nil) == false)
    assert(W.iconHasColour(42) == false)
    assert(W.iconHasColour({}) == false)
    assert(W.iconHasColour({ file = "x", _bb = false }) == false)
end)

-- ── nightProofIcons: a colour icon must never DISPLAY inverted ─────────────
--
-- ImageWidget skips its night pre-inversion for anything flagged is_icon, so
-- black line art paints black and DISPLAYS white once the panel inverts --
-- which is the point, and right. A colour icon takes the same exemption and
-- therefore displays as its own negative: an orange paw comes out blue.
-- Upstream says so itself right above that line ("we really *ought* to invert
-- them here ... we don't really trickle down a way to discriminate them").
-- iconHasColour IS that discrimination, so do what the note asks.

local function fakeColourBB(w, h, chromatic)
    local bb
    bb = {
        w = w, h = h, inverted = 0, freed = false,
        getWidth  = function(s) return s.w end,
        getHeight = function(s) return s.h end,
        getPixel  = function(_s, x, y)
            local r, g, b = 0x40, 0x40, 0x40
            if chromatic then r, g, b = 0xE8, 0x83, 0x3A end
            return { getColorRGB32 = function()
                return { r = r, g = g, b = b, alpha = 0xFF }
            end }
        end,
        invertRect = function(s) s.inverted = s.inverted + 1 end,
        free       = function(s) s.freed = true end,
    }
    bb.copy = function(s)
        local c = fakeColourBB(s.w, s.h, chromatic)
        c.is_copy_of = s
        return c
    end
    return bb
end

local function nightBtn(file, chromatic, alpha)
    local icon = { alpha = alpha, dim = false, icon = file, file = file,
                   _bb = fakeColourBB(24, 24, chromatic), _bb_disposable = false,
                   getSize = function() return { w = 24, h = 24 } end,
                   paintTo = function() end }
    return { enabled = true, label_widget = icon, label_container = { icon } }, icon
end

t.test("nightProofIcons: pre-inverts a colour icon so the panel restores it", function()
    local W = fresh()
    local btn, icon = nightBtn("paw", true, true)
    local orig = icon._bb
    W.nightProofIcons(true, btn)
    assert(icon._bb ~= orig, "the cached bitmap was mutated in place")
    assert(icon._bb.is_copy_of == orig, "it should be painting a private copy")
    eq(icon._bb.inverted, 1, "the copy was not colour-inverted")
    assert(icon._bb_disposable == true, "our copy has to be freed with the widget")
end)

t.test("nightProofIcons: does nothing in day, where nothing inverts the frame", function()
    local W = fresh()
    local btn, icon = nightBtn("paw", true, true)
    local orig = icon._bb
    W.nightProofIcons(false, btn)
    assert(icon._bb == orig, "a day-mode icon needs no correction at all")
end)

t.test("nightProofIcons: leaves black line art alone -- its exemption is correct", function()
    local W = fresh()
    local btn, icon = nightBtn("chevron.left", false, true)
    local orig = icon._bb
    W.nightProofIcons(true, btn)
    assert(icon._bb == orig,
        "inverting stock art would paint it white and display it black, gone")
end)

t.test("nightProofIcons: skips an opaque icon, whose white ground would go black", function()
    -- alpha = false is the no-wallpaper case: ImageWidget caches the icon
    -- already flattened onto white, so inverting the buffer gives a black card.
    local W = fresh()
    local btn, icon = nightBtn("paw", true, false)
    local orig = icon._bb
    W.nightProofIcons(true, btn)
    assert(icon._bb == orig, "a flattened icon must not be inverted")
end)

t.test("nightProofIcons: skips an icon already replaced by a mask", function()
    local W = fresh()
    local btn, icon = nightBtn("paw", true, true)
    btn.label_container[1] = { ["not"] = "the icon" }
    local orig = icon._bb
    W.nightProofIcons(true, btn)
    assert(icon._bb == orig, "the masked stand-in is what gets painted, not this")
end)

t.test("nightProofIcons: frees a bitmap the widget owned, rather than leaking it", function()
    local W = fresh()
    local btn, icon = nightBtn("paw", true, true)
    icon._bb_disposable = true
    local orig = icon._bb
    W.nightProofIcons(true, btn)
    assert(orig.freed == true, "the widget's own buffer was dropped on the floor")
end)

t.test("nightProofIcons: hands its arguments back and survives junk", function()
    local W = fresh()
    local btn = nightBtn("paw", true, true)
    local ok, a, b = pcall(W.nightProofIcons, true, btn, nil, 42, {}, { label_widget = 7 })
    assert(ok, "it must not care what it is handed")
    eq(a, btn, "the first widget should come back")
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

-- ── the background widget, now that regions are gone ───────────────────────
--
-- Regions let a reader keep the picture out of the hero, the shelf or the
-- footer. Dropped as part of simplifying this menu: three checkboxes to
-- describe something most readers either want everywhere or not at all, and
-- they carried the banded paint path, the geometry maths and their own
-- failure modes (a stale band left on the CACHED widget repainted the wrong
-- stripe) for that.
--
-- What is left is the simple thing: ground first, then the picture over it.
-- The ground still matters -- an image whose aspect ratio does not match the
-- screen leaves a margin, and the page frame above deliberately does not fill
-- when a wallpaper is present, so without the ground that margin would keep
-- whatever the last frame left there.

t.test("background: ground first, then the picture over it", function()
    local W = fresh()
    local made = {}
    installBlitbufferStub(made)
    W._lfs = lfs_shim
    local d = scratch()
    W._data_dir = d; W.ensureDir(); touch(W.dir(), "a.png")
    W._render = function(_p, w, h) return fakeBB(w, h) end
    local wg = W.bg("a.png", 100, 100, false)
    assert(wg, "should have built a background")
    wg.ground = { grey = 0x22 }
    local t2 = paintTarget()
    wg:paintTo(t2, 0, 0)
    -- A picture that covers every pixel of the widget: the ground would be
    -- painted only to be overwritten in full. That is a 2MB write per paint
    -- on a Kindle for nothing, so it is skipped.
    eq(#t2.ops, 1, "a full-cover picture is a blit and nothing else")
    eq(t2.ops[1].op, "blit")
    os.execute("rm -rf '" .. d .. "'")
    package.loaded["ffi/blitbuffer"] = nil
end)

t.test("background: a picture with a margin still gets the ground first", function()
    local W = fresh()
    local made = {}
    installBlitbufferStub(made)
    W._lfs = lfs_shim
    local d = scratch()
    W._data_dir = d; W.ensureDir(); touch(W.dir(), "a.png")
    W._render = function(_p, w, h) return fakeBB(60, h) end   -- narrower than asked
    local wg = W.bg("a.png", 100, 100, false)
    assert(wg, "should have built a background")
    wg.ground = { grey = 0x22 }
    local t2 = paintTarget()
    wg:paintTo(t2, 0, 0)
    eq(#t2.ops, 2, "expected a fill then a blit")
    eq(t2.ops[1].op, "fill", "the ground is painted first")
    eq(t2.ops[2].op, "blit", "the picture goes over it")
    os.execute("rm -rf '" .. d .. "'")
    package.loaded["ffi/blitbuffer"] = nil
end)

t.test("backdrop: asked for a region, it lays down only that region", function()
    -- The chip strip's page wipe needs the wallpaper under ITS band in a
    -- scratch buffer; laying the whole 2MB picture into it for a 60px strip
    -- was most of the wipe's cost.
    local W = fresh()
    local made = {}
    installBlitbufferStub(made)
    W._lfs = lfs_shim
    local d = scratch()
    W._data_dir = d; W.ensureDir(); touch(W.dir(), "a.png")
    W._render = function(_p, w, h) return fakeBB(w, h) end
    assert(W.bg("a.png", 100, 100, false), "should have built a background")
    local blits = {}
    local target = { getWidth = function() return 100 end, getHeight = function() return 100 end,
        blitFrom = function(_self, src, dx, dy, sx, sy, w, h)
            blits[#blits + 1] = { dx = dx, dy = dy, sx = sx, sy = sy, w = w, h = h } end,
        paintRect = function() error("no fill expected") end }
    eq(W.backdrop(target, { x = 10, y = 20, w = 30, h = 40 }), true)
    eq(#blits, 1)
    eq(blits[1].dx, 10); eq(blits[1].dy, 20); eq(blits[1].sx, 10); eq(blits[1].sy, 20)
    eq(blits[1].w, 30);  eq(blits[1].h, 40)
    os.execute("rm -rf '" .. d .. "'")
    package.loaded["ffi/blitbuffer"] = nil
end)

t.test("background: no ground set still blits the picture", function()
    local W = fresh()
    local made = {}
    installBlitbufferStub(made)
    W._lfs = lfs_shim
    local d = scratch()
    W._data_dir = d; W.ensureDir(); touch(W.dir(), "a.png")
    W._render = function(_p, w, h) return fakeBB(w, h) end
    local wg = W.bg("a.png", 100, 100, false)
    wg.ground = nil
    local t2 = paintTarget()
    wg:paintTo(t2, 0, 0)
    eq(#t2.ops, 1, "expected just the blit")
    eq(t2.ops[1].op, "blit")
    os.execute("rm -rf '" .. d .. "'")
    package.loaded["ffi/blitbuffer"] = nil
end)

-- ── a separate picture for full screen shelves ────────────────────────
--
-- The two views want different backdrops: the top panel is mostly text over
-- the picture, while full screen shelves are wall-to-wall covers and spines.
-- A backdrop that reads well behind one is often wrong behind the other.
--
-- TWO sources, and that is deliberate. There was a third, more specific one:
-- a picture picked per shelf in the chip editor. It was removed rather than
-- fixed -- changing the backdrop on a chip tap means the whole screen has to
-- repaint, the shelf's refreshes are regional by design, and moving between
-- two chips with different pictures left stale rectangles behind.
--
-- So the only thing that can change the picture now is expanding to full
-- screen shelves, which already goes through a full repaint.

t.test("resolveFor: full screen uses its own image when set", function()
    eq(fresh().resolveFor("wall.png", "paper.png", true), "wall.png")
end)

t.test("resolveFor: the normal view ignores the full screen image", function()
    eq(fresh().resolveFor("wall.png", "paper.png", false), "paper.png")
end)

t.test("resolveFor: unset full screen image falls back to the default", function()
    eq(fresh().resolveFor(nil, "paper.png", true), "paper.png")
end)

t.test("resolveFor: nothing set anywhere is nil, not an error", function()
    eq(fresh().resolveFor(nil, nil, true), nil)
    eq(fresh().resolveFor(nil, nil, false), nil)
end)

t.test("resolveFor: full screen set to NONE means bare, not the default", function()
    -- Three states, not two: unset means "same as the default image", false
    -- means "no picture in this view". Falling through to the default on
    -- false would make None unreachable for full screen shelves.
    eq(fresh().resolveFor(false, "paper.png", true), nil)
end)

t.test("resolveFor: full screen NONE does not affect the normal view", function()
    eq(fresh().resolveFor(false, "paper.png", false), "paper.png")
end)

t.test("resolveFor: an empty string counts as absent, not as a filename", function()
    -- A cleared text field writes "" rather than nil in more than one place
    -- in this plugin; treating it as a filename would look for a file called
    -- "" and quietly show nothing, with no way to tell why.
    eq(fresh().resolveFor("", "paper.png", true), "paper.png")
    eq(fresh().resolveFor(nil, "", false), nil)
end)

t.test("resolveFor: a non-string value is ignored, not stringified", function()
    -- A hand-edited settings file, or a value written by a later release.
    eq(fresh().resolveFor({ name = "x" }, "paper.png", true), "paper.png")
    eq(fresh().resolveFor(42, "paper.png", true), "paper.png")
    eq(fresh().resolveFor(nil, 42, false), nil)
end)

t.test("nothing reads a per-shelf wallpaper key any more", function()
    -- The removal has to reach the CONSUMERS, not just the picker: a shelf
    -- whose tab still carries a stale wallpaper value must be ignored, not
    -- quietly honoured by a call site that was left behind.
    local wp_src = io.open("lib/bookshelf_wallpaper.lua"):read("a")
    assert(not wp_src:match("CHIP_KEY"),
        "the wallpaper module still exposes a per-chip key")
    for _i, f in ipairs({ "lib/bookshelf_widget.lua",
                          "lib/bookshelf_chip_editor.lua" }) do
        local src = io.open(f):read("a")
        assert(not src:match("Wallpaper%.CHIP_KEY"),
            f .. " still resolves a per-shelf wallpaper")
    end
end)

-- ── The chrome scrim ───────────────────────────────────────────────
--
-- A semi-transparent tint over the top panel and the footer, so their buttons
-- stay legible over a picture. Two things here fail silently.
--
-- First, the ABSENCE of a day/night branch. It reads like an oversight and the
-- "fix" is a one-line conditional, so it is pinned with its reason: the panel
-- inverts the frame in night mode and M.bg pre-inverts the wallpaper to match,
-- so a painted 0xFF is the page ground in BOTH modes. Tinting toward chrome_bg
-- is already right either way, and a branch would invert one of them.
--
-- Second, Transparent has to be the ZERO of the same scale rather than a
-- parallel flag. Two controls for "how much picture shows" drift apart the
-- moment one is written without the other.

local scrim_src = io.open("lib/bookshelf_wallpaper.lua"):read("a")

local function reader(tbl)
    return function(k) return tbl[k] end
end

t.test("transparent buttons is the zero of the shading scale", function()
    -- Not merely "also returns 0": it must short-circuit, so a strength left
    -- behind by an earlier Medium cannot resurrect the tint.
    local W = fresh()
    eq(W.scrimStrength(reader{
        [W.BUTTONS_SETTING] = true,
        [W.SCRIM_SETTING]   = 0.85,
    }), 0)
end)

t.test("an unset strength falls back to the default, not to zero", function()
    -- Zero would leave every reader who never opens the row with untinted
    -- chrome over their photograph, which is the state this exists to fix.
    local W = fresh()
    eq(W.scrimStrength(reader{}), W.SCRIM_DEFAULT)
    assert(W.SCRIM_DEFAULT > 0 and W.SCRIM_DEFAULT < 1,
        "the default should be a scrim, not off and not opaque")
end)

t.test("out-of-range strengths clamp before reaching the blitter", function()
    local W = fresh()
    eq(W.scrimStrength(reader{ [W.SCRIM_SETTING] = 5 }), 1)
    eq(W.scrimStrength(reader{ [W.SCRIM_SETTING] = -2 }), 0)
    eq(W.scrimStrength(reader{ [W.SCRIM_SETTING] = "0.5" }), W.SCRIM_DEFAULT)
end)

t.test("a zero-strength scrim paints nothing at all", function()
    -- Cheaper than blending zero alpha, and it is what makes Transparent
    -- honest rather than approximately honest.
    local W = fresh()
    local painted = false
    local bb = {
        paintRect      = function() painted = true end,
        blendRectRGB32 = function() painted = true end,
    }
    eq(W.scrim(bb, 0, 0, 10, 10, {}, 0), false)
    eq(painted, false)
end)

t.test("a strength that rounds to zero alpha paints nothing either", function()
    -- 255 * 0.001 rounds to 0. Below the zero guard but above nothing: it
    -- reached blendRectRGB32 with a fully transparent colour, which is the
    -- exact paint a BB8A target turns solid.
    local W = fresh()
    local painted = false
    local bb = {
        paintRect      = function() painted = true end,
        blendRectRGB32 = function() painted = true end,
    }
    eq(W.scrim(bb, 0, 0, 10, 10, {}, 0.001), false)
    eq(painted, false)
end)

t.test("without the C blitter, a translucent scrim falls back to an opaque fill", function()
    -- blendRectRGB32 has two implementations: C, and a per-pixel Lua loop
    -- taken when canUseCbb() is false -- software-inverted night mode on a
    -- device without hardware inversion, and the desktop emulator. The top
    -- panel is ~588k pixels; that loop is seconds per paint. An opaque panel
    -- on those devices is the lesser evil.
    local W = fresh()
    package.loaded["ffi/blitbuffer"] = {
        ColorRGB32 = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end }
    local calls = {}
    local bb = {
        canUseCbb      = function() return false end,
        paintRect      = function() calls[#calls + 1] = "paint" end,
        blendRectRGB32 = function() calls[#calls + 1] = "blend" end,
    }
    local colour = { getColorRGB32 = function(self) return self end,
                     getR = function() return 0 end, getG = function() return 0 end,
                     getB = function() return 0 end }
    eq(W.scrim(bb, 0, 0, 10, 10, colour, 0.6), true)
    assert(#calls > 0, "nothing was painted at all")
    for _, c in ipairs(calls) do eq(c, "paint", "the Lua blend path was taken") end
    package.loaded["ffi/blitbuffer"] = nil
end)

-- ── shade, and the direct form the recess painter uses ──────────────────
t.test("shadeRect darkens by day and lightens at night, with no wrapping", function()
    -- The recess painter issues ~2000 of these per paint of a spine page,
    -- from inside ONE pcall of its own. shade()'s per-call pcall, closure
    -- and span table were the cost, not the blend.
    local W = fresh()
    local log = {}
    local bb = {
        canUseCbb   = function() return true end,
        darkenRect  = function(_s, x, y, w, h, by) log[#log + 1] = { "dark", x, y, w, h, by } end,
        lightenRect = function(_s, x, y, w, h, by) log[#log + 1] = { "light", x, y, w, h, by } end,
    }
    eq(W.shadeRect(bb, 1, 2, 3, 4, 0.5, false), true)
    eq(W.shadeRect(bb, 5, 6, 7, 8, 0.25, true), true)
    eq(#log, 2)
    eq(log[1][1], "dark");  eq(log[1][2], 1); eq(log[1][5], 4); eq(log[1][6], 0.5)
    eq(log[2][1], "light"); eq(log[2][2], 5); eq(log[2][6], 0.25)
    eq(W.shadeRect(bb, 0, 0, 0, 4, 0.5, false), false, "a degenerate rect is refused")
    eq(W.shadeRect(bb, 0, 0, 4, 4, 0, false), false, "zero strength paints nothing")
    eq(#log, 2)
end)

t.test("without the C blitter, shade and shadeRect paint nothing", function()
    -- darkenRect/lightenRect are C only while canUseCbb() holds; otherwise
    -- they are per-pixel Lua. A missing shadow beats a paint measured in
    -- seconds. Same rule as the scrim's opaque fallback.
    local W = fresh()
    local painted = 0
    local bb = {
        canUseCbb   = function() return false end,
        darkenRect  = function() painted = painted + 1 end,
        lightenRect = function() painted = painted + 1 end,
    }
    eq(W.shadeRect(bb, 0, 0, 4, 4, 0.5, false), false)
    eq(W.shade(bb, 0, 0, 4, 4, 0.5, false), false)
    eq(painted, 0)
end)

t.test("the recess painter takes the direct form", function()
    local src = io.open("lib/bookshelf_spine_shelf.lua"):read("a")
    local body = src:match("function recess:paintTo%(bb, x, y%).-\n%s*end%)\n")
    assert(body, "recess:paintTo could not be located")
    assert(not body:find("Wallpaper%.shade%("), "the recess still calls shade() per band")
    assert(body:find("Wallpaper%.shadeRect%("), "the recess does not use shadeRect")
end)

t.test("shadeClipped shades only where the clips allow, once", function()
    -- A cover's drop shadow is a full card-sized blend over the picture, and
    -- the card then covers all of it but an L-shaped margin. Blending the
    -- whole rect is a read-modify-write of ~84k framebuffer pixels per tile
    -- for ~4k that show. The clips are the margin; they must be disjoint, so
    -- no pixel is darkened twice.
    local W = fresh()
    local rects = {}
    local bb = { canUseCbb = function() return true end,
                 darkenRect = function(_s, x, y, w, h) rects[#rects + 1] = { x, y, w, h } end,
                 lightenRect = function() error("night op by day") end }
    local off = 8
    local x, y, w, h = 100, 200, 60, 90
    local clips = { { x = x + w - off, y = y,         w = off, h = h - off },
                    { x = x,           y = y + h - off, w = w,   h = off } }
    eq(W.shadeClipped(bb, x, y, w, h, 0.4, false, 0, clips), true)
    local area = 0
    for _, r in ipairs(rects) do
        area = area + r[3] * r[4]
        -- nothing inside the region the card covers
        assert(not (r[1] < x + w - off and r[2] < y + h - off),
            string.format("shaded under the card at %d,%d %dx%d", r[1], r[2], r[3], r[4]))
    end
    eq(area, off * (h - off) + w * off, "exactly the margin, each pixel once")
end)

t.test("shadeClipped with no clips is shade", function()
    local W = fresh()
    local n = 0
    local bb = { canUseCbb = function() return true end,
                 darkenRect = function() n = n + 1 end }
    eq(W.shadeClipped(bb, 0, 0, 10, 10, 0.4, false, 0, nil), true)
    eq(n, 1)
end)

t.test("a degenerate rect is refused before the blitter sees it", function()
    local W = fresh()
    local bb = {
        paintRect      = function() error("painted a zero rect") end,
        blendRectRGB32 = function() error("blended a zero rect") end,
    }
    eq(W.scrim(bb, 0, 0, 0, 40, {}, 0.6), false)
    eq(W.scrim(bb, 0, 0, 40, 0, {}, 0.6), false)
end)

t.test("the scrim has no day/night branch", function()
    -- See above. Anchored on the function body, because this file discusses
    -- night mode at length on purpose and prose would match.
    local body = scrim_src:match("function M%.scrim%(bb.-\nend")
    assert(body, "M.scrim could not be located")
    assert(not body:match("night"), "the scrim grew a night-mode branch")
    assert(not body:match("invert"), "the scrim grew an inversion")
end)

t.test("the scrim blends, except at full strength", function()
    -- The point is that the picture survives. A plain paintRect at any
    -- strength below 1 is the solid bar this replaced.
    local body = scrim_src:match("function M%.scrim%(bb.-\nend")
    assert(body:match("blendRectRGB32"),
        "the scrim no longer blends -- it is a solid fill again")
    assert(body:match("alpha >= 255"),
        "full strength should take the cheaper opaque path")
end)

t.test("a rounded scrim tiles every pixel exactly once", function()
    -- THE failure mode for a blended rounded rect. Blitbuffer has no blended
    -- paintRoundedRect, and the obvious build -- blend the body, then blend
    -- the corners -- overlaps. Overlap is invisible to a test that only
    -- checks the shape, and on screen it is four corners darker than the
    -- panel they belong to. Counted here rather than asserted about.
    local W = fresh()
    for _i, case in ipairs({ { 40, 24, 8 }, { 9, 9, 4 }, { 60, 12, 20 } }) do
        local w, h, r = case[1], case[2], case[3]
        local seen = {}
        local covered = 0
        for _j, sp in ipairs(W._roundedSpans(0, 0, w, h, r)) do
            for yy = sp.y, sp.y + sp.h - 1 do
                for xx = sp.x, sp.x + sp.w - 1 do
                    local k = yy * 1000 + xx
                    assert(not seen[k], string.format(
                        "pixel %d,%d blended twice at %dx%d r%d", xx, yy, w, h, r))
                    seen[k] = true
                    covered = covered + 1
                end
            end
        end
        -- A rounded rect loses corner area; it must not lose more than the
        -- four quarter-circles, which would mean a chunk missing from an edge.
        local lost = w * h - covered
        local rr = math.min(r, math.floor(w / 2), math.floor(h / 2))
        assert(lost >= 0 and lost <= 4 * rr * rr, string.format(
            "%dx%d r%d dropped %d pixels", w, h, r, lost))
    end
end)

t.test("a zero radius is still one span, not a stack of rows", function()
    -- The strips (shelf menu, footer) pass no radius and must stay a single
    -- blitter call; falling into the row loop would be one call per scanline.
    local W = fresh()
    eq(#W._roundedSpans(0, 0, 100, 40, 0), 1)
    eq(#W._roundedSpans(0, 0, 100, 40, nil), 1)
end)

t.test("a radius larger than the box degrades instead of inverting", function()
    -- w - inset*2 goes negative if the radius is not clamped, and a negative
    -- width span is either a no-op or a smear depending on the blitter.
    local W = fresh()
    for _i, sp in ipairs(W._roundedSpans(0, 0, 10, 10, 99)) do
        assert(sp.w > 0 and sp.h > 0,
            "degenerate span " .. sp.w .. "x" .. sp.h)
    end
end)

t.test("the top panel is one band, attached above the hero swap", function()
    -- THE decision to protect. The hero is replaced wholesale by
    -- _swapHeroInPlace and comes in three shapes, so a panel painted from the
    -- hero widget is dropped on the next swap -- the band would simply
    -- disappear the first time the reader changed books. Painting from
    -- inner_vgroup, which outlives every swap, is what makes it stick.
    local src = io.open("lib/bookshelf_widget.lua"):read("a")
    -- Painted by _attachTopPanel, which wraps whatever GROUP it is handed:
    -- the shelf's inner_vgroup, and the empty chip's own group (issue 423).
    assert(src:match("function BookshelfWidget:_attachTopPanel")
           and src:match("vgroup%.paintTo = function"),
        "the top panel is no longer painted from a group's own paintTo")
    assert(src:match("_attachTopPanel%(inner_vgroup"),
        "the shelf no longer hands the panel the group that outlives the "
        .. "hero swap")
    local hero_src = io.open("lib/bookshelf_hero_card.lua"):read("a")
    assert(not hero_src:match("function HeroCard:paintTo"),
        "the hero card paints its own panel again -- it will be lost on swap")
end)

t.test("the shelf menu fills, and must never tint", function()
    -- The strip DOES paint its own ground, and that is not a second panel: it
    -- sits wholly inside the top panel, square and inset, so there is no seam
    -- to show. It is opaque because a dense row of small labels cannot live on
    -- a semi-transparent tint over a dark picture.
    --
    -- What it must never do is scrim. The panel has already tinted these
    -- pixels; tinting them again would make the shelf menu a darker band
    -- inside the panel -- the same double-blend the rounded corners are tiled
    -- by row to avoid.
    local chip_src = io.open("lib/bookshelf_chip_bar.lua"):read("a")
    local body = chip_src:match("function ChipBar:_paintGround.-\nend")
    assert(body, "the shelf menu no longer grounds itself")
    assert(body:match("paintRect"), "the shelf menu's ground is not opaque")
    assert(not body:match("Wallpaper%.scrim"),
        "the shelf menu tints over the panel -- it will read as a dark band")
    assert(body:match("solid_ground"),
        "the shelf menu fills even at Transparent, which asked for the picture")
end)

t.test("the page wipe lays the shelf menu's ground too", function()
    -- The wipe composes into its OWN buffer and paints self[1] directly,
    -- never going through paintTo. A ground that lives only in paintTo is
    -- therefore missing for the length of every swipe, and the chips wipe
    -- across bare wallpaper -- which is exactly how this was found.
    local chip_src = io.open("lib/bookshelf_chip_bar.lua"):read("a")
    local at_wipe = chip_src:find("PageWipe%.run")
    assert(at_wipe, "the page wipe could not be located")
    local before = chip_src:sub(1, at_wipe)
    local compose = before:match("Wallpaper%.backdrop%(new_bb[^)]*%).*$")
    assert(compose, "the wipe no longer lays a backdrop")
    assert(compose:match("_paintGround"),
        "the wipe paints the chips over the backdrop without the strip's "
        .. "ground; the bar will lose its fill mid-swipe")
end)

t.test("both footers are drawn from one definition", function()
    -- The full-screen micro-module overlay repaints the shelf's footer buttons
    -- at their real positions, so it needs the shelf's panel under them. It
    -- had its own, and the two looked different. Neither may compute the rect
    -- for itself again.
    local src = io.open("lib/bookshelf_widget.lua"):read("a")
    assert(src:match("function BookshelfWidget:footerPanelRect"),
        "the shared footer panel definition is gone")
    local fs = io.open("lib/bookshelf_micro_fullscreen.lua"):read("a")
    assert(fs:match("footerPanelRect"),
        "the overlay works out its own footer panel again")
    assert(not fs:match("Size%.radius%.window"),
        "the overlay hard-codes the panel's radius instead of asking for it")
end)

t.test("micro-module cards are opaque, and settable", function()
    -- A semi-transparent card was tried and reverted: the widgets inside a
    -- module blit opaque white buffers of their own, so over a tint every line
    -- of text showed as a white box. The card cannot be less opaque than its
    -- contents -- which is why the knob is a COLOUR and not an alpha.
    local hm = io.open("lib/bookshelf_hero_modules.lua"):read("a")
    assert(not hm:match("Wallpaper%.scrim"),
        "micro-module cards tint again -- their text will show white boxes")
    assert(hm:match("colors%.module_bg"),
        "the card fill no longer follows the module_bg setting")
    local cp = io.open("lib/bookshelf_cover_progress.lua"):read("a")
    assert(cp:match('_readModeColor%("module_bg"'),
        "module_bg bypasses the day/night split")
end)

t.test("both new colours are cleared by Reset colours", function()
    -- A row Reset does not know about leaves a colour stuck until the reader
    -- finds the per-row long-press.
    local settings = io.open("lib/bookshelf_settings.lua"):read("a")
    local list = settings:match("local keys = {(.-)}")
    assert(list, "the reset list could not be located")
    assert(list:match('"chrome_bg"'), "Reset skips the shelf menu background")
    assert(list:match('"module_bg"'), "Reset skips the micro-module background")
end)

t.test("the overlay's launcher glyphs drop their white backing over a picture", function()
    -- These glyphs are repainted over the real launcher's spot, and their white
    -- fill existed only to match the overlay's own WHITE background. Once that
    -- ground became a wallpaper with the footer panel on it, the fill punched a
    -- hole in the panel AND squared off its rounded ends -- which read as one
    -- full-width bar and took five rounds to identify, because the panel and
    -- the two backings were all white and merged into one shape.
    local fs = io.open("lib/bookshelf_micro_fullscreen.lua"):read("a")
    assert(fs:match("local function _glyphBacking"),
        "the glyph backing is unconditional again")
    -- Anchored on the FrameContainer fields, not on prose: this file explains
    -- the white background at length in comments.
    assert(not fs:match("background = Blitbuffer%.COLOR_WHITE,\n        bordersize = focused"),
        "the close glyph paints an unconditional white box over the panel")
    local body = fs:match("local function _glyphBacking.-\nend")
    -- groundIsPainted, not hasWallpaper: a chosen page colour and the dark
    -- theme are grounds too, and a white box over either is the same bug this
    -- test was written for. hasWallpaper still exists and still means an
    -- image; it is just not the question this one is asking.
    assert(body:match("groundIsPainted"),
        "the backing no longer asks whether there is a ground behind it")
    assert(body:match("return nil"),
        "the backing must be nil, not false: FrameContainer tests `if self.background then`")
end)

t.test("a shipped picture is handed over once, and only once", function()
    -- An empty wallpaper folder documents nothing: the reader has to already
    -- know the feature exists, find the folder, and guess what belongs in it.
    -- One picture in place answers all three.
    --
    -- It must not come BACK, though: top the folder up every launch and a
    -- reader who deleted the example finds it again next time, which reads as
    -- the plugin ignoring them.
    --
    -- The first rule for that was "seed only when we create the folder", and
    -- it is the wrong proxy twice over. A folder that exists but is EMPTY can
    -- never be seeded -- which is every device that ran the build where the
    -- copy was silently broken -- and a picture added in a LATER release
    -- reaches only fresh installs, never an upgrade. So the record is per
    -- FILE, in a setting.
    local W = fresh()
    W.SEED_SUBDIR = "assets/wallpapers"          -- the real shipped folder
    local store = {}
    package.loaded["lib/bookshelf_settings_store"] = {
        read  = function(k) return store[k] end,
        save  = function(k, v) store[k] = v end,
        flush = function() end,
    }
    local names = {}
    for n in lfs_shim.dir("assets/wallpapers") do
        if n ~= "." and n ~= ".." then names[#names + 1] = n end
    end
    assert(#names > 0, "nothing is shipped to seed with")

    -- 1. A folder that does not exist yet: created and seeded.
    local d = scratch() .. "/settings"
    W._data_dir = d; W._lfs = lfs_shim; W._ensured = false
    W.ensureDir()
    local dir = d .. "/" .. W.SUBDIR
    eq(lfs_shim.attributes(dir, "mode"), "directory", "the folder was not created")
    for _i = 1, #names do
        eq(lfs_shim.attributes(dir .. "/" .. names[_i], "mode"), "file",
           names[_i] .. " was not seeded")
    end
    assert(store[W.SEEDED_SETTING], "the handover was not recorded")

    -- 2. The reader deletes it. It must NOT come back.
    os.execute("rm -f '" .. dir .. "/" .. names[1] .. "'")
    W._ensured = false
    W.ensureDir()
    eq(lfs_shim.attributes(dir .. "/" .. names[1], "mode"), nil,
       "a deleted picture came back; the reader's choice must stick")

    -- 3. An EXISTING EMPTY folder with no record -- the state every device
    --    was left in by the broken copy -- is seeded.
    local d2 = scratch() .. "/settings"
    local dir2 = d2 .. "/" .. W.SUBDIR
    lfs_shim.mkdir(dir2)
    eq(lfs_shim.attributes(dir2, "mode"), "directory", "setup failed")
    store = {}
    package.loaded["lib/bookshelf_settings_store"] = {
        read  = function(k) return store[k] end,
        save  = function(k, v) store[k] = v end,
        flush = function() end,
    }
    W._data_dir = d2; W._lfs = lfs_shim; W._ensured = false
    W.ensureDir()
    eq(lfs_shim.attributes(dir2 .. "/" .. names[1], "mode"), "file",
       "an existing empty folder was never seeded -- the folder-creation "
       .. "rule is back")
    package.loaded["lib/bookshelf_settings_store"] = nil
end)

t.test("seeding copies the shipped pictures byte for byte", function()
    -- The copy is block-wise rather than a single read, which is exactly the
    -- kind of loop that silently truncates. Compared by size AND by the last
    -- bytes, so a short write cannot pass.
    local W = fresh()
    W.SEED_SUBDIR = "assets/wallpapers"
    W._lfs = lfs_shim
    local d = scratch()
    W.seedDir(d)
    -- Whatever is shipped, by name read from the folder: the set has changed
    -- once already and a test that names a file just breaks the next time.
    local ls = io.popen("ls -1 assets/wallpapers 2>/dev/null")
    local name = ls and ls:read("*l") or nil
    if ls then ls:close() end
    assert(name, "nothing is shipped in assets/wallpapers")
    local src = io.open("assets/wallpapers/" .. name, "rb")
    local dst = io.open(d .. "/" .. name, "rb")
    assert(dst, "the seed picture was not copied: " .. name)
    local a, b = src:read("a"), dst:read("a")
    src:close(); dst:close()
    eq(#b, #a, "copied file is a different length")
    eq(b:sub(-64), a:sub(-64), "the tail of the copy differs")
    os.execute("rm -rf '" .. d .. "'")
end)

t.test("every shipped seed picture is 3:4 and a format the decoder reads", function()
    -- The decoder STRETCHES to the screen (scaleBlitBuffer / fz_scale_pixmap,
    -- neither preserves aspect), so a seed at the wrong ratio ships visible
    -- distortion to every device. Checked for whatever is in the folder
    -- rather than for a named file: the shipped set is a product decision and
    -- changes, the ratio rule does not.
    local names = {}
    local ls = io.popen("ls -1 assets/wallpapers 2>/dev/null")
    if ls then
        for line in ls:lines() do names[#names + 1] = line end
        ls:close()
    end
    assert(#names > 0, "nothing is shipped in assets/wallpapers")
    for _i, name in ipairs(names) do
    local f = io.open("assets/wallpapers/" .. name, "rb")
    assert(f, "the seed picture is missing: " .. name)
    local head = f:read(8)
    f:close()
    local is_jpeg = head:sub(1, 2) == "\255\216"
    local is_png  = head == "\137PNG\13\10\26\10"
    assert(is_jpeg or is_png, name .. " is neither a JPEG nor a PNG")
    -- Dimensions come from the file itself rather than being restated here.
    local pipe = io.popen("magick identify -format '%w %h' "
        .. "'assets/wallpapers/" .. name .. "' 2>/dev/null")
    local dims = pipe and pipe:read("*a") or ""
    if pipe then pipe:close() end
    if dims ~= "" then
        local w, h = dims:match("(%d+) (%d+)")
        w, h = tonumber(w), tonumber(h)
        assert(math.abs(w / h - 0.75) < 0.01, string.format(
            "%s is %dx%d (%.3f); the decoder stretches, so it must be 3:4",
            name, w, h, w / h))
    end
    end
end)

t.test("the shadow darkens what is behind it, and DOES branch on night", function()
    -- The mirror of the scrim's no-branch rule, and the pair is the point.
    --
    -- A panel tints toward the page ground, which is ONE painted value in both
    -- modes (0xFF), so scrim must not branch. A shadow has to come out darker
    -- than whatever is behind it ON SCREEN, and "darker on screen" is a lower
    -- painted value by day and a HIGHER one at night, because the panel
    -- inverts the frame. Opposite directions, so shade must branch.
    local W = fresh()
    local calls = {}
    local bb = {
        darkenRect  = function(_s, x, y, w, h, by) calls[#calls+1] = "dark:" .. by end,
        lightenRect = function(_s, x, y, w, h, by) calls[#calls+1] = "light:" .. by end,
    }
    W.shade(bb, 0, 0, 40, 40, 0.5, false)
    assert(calls[1] and calls[1]:match("^dark:"),
        "a day shadow must blend toward black")
    calls = {}
    W.shade(bb, 0, 0, 40, 40, 0.5, true)
    assert(calls[1] and calls[1]:match("^light:"),
        "a night shadow must blend toward white -- it displays as black")
end)

t.test("the shadow paints nothing rather than a colour it cannot blend", function()
    -- A buffer without the blend ops must fall through to the caller's own
    -- opaque paint, not silently skip the shadow.
    local W = fresh()
    eq(W.shade({}, 0, 0, 40, 40, 0.5, false), false)
    eq(W.shade({ darkenRect = function() end }, 0, 0, 40, 40, 0, false), false)
end)

t.test("list mode panels the whole shelf, and the footer stops doubling", function()
    -- A list row is text on a thin rule with none of a cover's own ground, so
    -- over a picture the shelf fades to unreadable. One panel behind all of
    -- it -- and then the footer MUST stop tinting, or the area it covers gets
    -- blended twice and reads as a darker band inside the panel.
    local src = io.open("lib/bookshelf_widget.lua"):read("a")
    assert(src:match("_panel_covers_footer"),
        "nothing tells the footer that the shelf panel already covered it")
    local footer = src:match("local strength = %(?self%._panel_covers_footer.-\n")
    assert(footer, "the footer no longer checks before tinting")
end)

t.test("a night flip inverts in place and moves the key with it", function()
    -- If the key does not follow, the next M.bg call reads this buffer as the
    -- wrong mode and throws it away for an identical decode -- and, worse,
    -- frees it while its widget may still be in the live tree.
    local W = fresh()
    local inverted = 0
    W._bg = { bb = { invertRect = function() inverted = inverted + 1 end,
                     getWidth = function() return 10 end,
                     getHeight = function() return 10 end } }
    W._bg_key = "/p/x.jpg|10x10"
    eq(W.flipNight(true), true)
    eq(inverted, 1)
    eq(W._bg_key, "/p/x.jpg|10x10|n", "the key must gain the night suffix")
    eq(W.flipNight(false), true)
    eq(W._bg_key, "/p/x.jpg|10x10", "and lose it again on the way back")
end)

t.test("a redundant SetNightMode must not invert the backdrop", function()
    -- KOReader's DeviceListener:onSetNightMode is IDEMPOTENT -- it compares
    -- the requested state to the stored one and returns without touching the
    -- panel when they already agree. Ours ignored the argument entirely, so a
    -- SetNightMode that changed nothing still inverted the cached wallpaper.
    --
    -- That event is not exotic. dispatcher.lua exposes it as `set_night_mode`
    -- with args={true,false}, which is how a gesture, a profile or a home-UI
    -- replacement turns night mode "on" rather than toggling it, and
    -- autowarmth fires it on a schedule. Every redundant one left the backdrop
    -- a negative until the deferred rebuild threw the buffer away and paid for
    -- a full decode of the same picture (issue 426).
    --
    -- The guard belongs on the TARGET MODE, not on the event: the buffer's own
    -- key says which mode it holds, so comparing against that is right whether
    -- our handler runs before or after DeviceListener.
    local W = fresh()
    local inverted = 0
    local function bg(key)
        W._bg = { bb = { invertRect = function() inverted = inverted + 1 end,
                         getWidth = function() return 10 end,
                         getHeight = function() return 10 end } }
        W._bg_key = key
    end

    bg("/p/x.jpg|10x10")                      -- a DAY buffer
    eq(W.flipNight(false), false, "asked for day, already day: nothing to do")
    eq(inverted, 0)
    eq(W._bg_key, "/p/x.jpg|10x10", "the key must not move")

    eq(W.flipNight(true), true, "asked for night: flip it")
    eq(inverted, 1)
    eq(W._bg_key, "/p/x.jpg|10x10|n")

    eq(W.flipNight(true), false, "asked for night again: already there")
    eq(inverted, 1)
    eq(W._bg_key, "/p/x.jpg|10x10|n", "a second request must not undo the first")
end)

t.test("the handler passes the target mode, and skips a no-op SetNightMode", function()
    local src = io.open("lib/bookshelf_widget.lua"):read("a")
    local fn = src:match("local function _scheduleNightModeRebuild.-\nend\n")
    assert(fn, "the night rebuild scheduler could not be located")
    assert(fn:find("flipNight(", 1, true) and not fn:find("flipNight()", 1, true),
        "flipNight must be given the target mode, not called as a blind toggle")
    -- and the two entry points have to compute that target
    assert(src:find("function BookshelfWidget:onSetNightMode(night_mode_on)", 1, true),
        "onSetNightMode must take the argument KOReader sends it")
end)

t.test("freeing detaches before it frees", function()
    -- Painting a freed blitbuffer is a SEGFAULT in the C blitter, with no Lua
    -- traceback -- which is what a night toggle produced. The widget may still
    -- be in the live tree when its buffer goes, so the buffer must be detached
    -- first: a stale paint then finds nil and draws nothing.
    local W = fresh()
    local freed = false
    local widget = { bb = { free = function() freed = true end } }
    W._bg, W._bg_key = widget, "k"
    W.free()
    eq(W._bg, nil)
    eq(W._bg_key, nil)
    -- No UIManager in this harness, so the fallback path runs synchronously:
    -- either way the widget must not be left holding a freed buffer.
    eq(widget.bb, nil, "the widget still points at the buffer that was freed")
    eq(freed, true)
end)

t.test("the night toggle flips the backdrop before it rebuilds", function()
    -- Ordering, not presence: doing this inside the rebuild leaves the
    -- backdrop showing as a negative for the two ticks the rebuild is away.
    local src = io.open("lib/bookshelf_widget.lua"):read("a")
    local fn = src:match("local function _scheduleNightModeRebuild.-\nend")
    assert(fn, "the night rebuild scheduler could not be located")
    local at_flip = fn:find("flipNight")
    local at_tick = fn:find("UIManager:nextTick")
    assert(at_flip and at_tick and at_flip < at_tick,
        "the backdrop flip must run on THIS tick, before the deferred work")
end)

t.test("spine titles still read top-to-bottom unless asked otherwise", function()
    -- 270 = top-to-bottom, how a British or American book is printed: stand
    -- one on a shelf and you tilt your head RIGHT to read it. At 90 every
    -- spine read upside down against a real shelf. It became a setting for
    -- issue 410 (Continental European printing runs the other way); what this
    -- suite cares about is that the DEFAULT did not move with it.
    --
    -- The rotation and the band gradient are one decision, and
    -- _test_spine_text_direction pins that they are also one expression.
    local src = io.open("lib/bookshelf_spine_shelf.lua"):read("a")
    local dflt = src:match('SpineShelf.TEXT_DIR_SETTING, "([%a_]+)"')
    assert(dflt, "the direction default could not be located")
    eq(dflt, "top_down", "spines must still read top-to-bottom out of the box")
    assert(src:find("if v == \"bottom_up\" then return 90 end", 1, true),
        "the other direction is no longer 90 degrees")
end)

t.test("CJK titles never go through the rotation", function()
    -- A 90-degree-rotated string is unreadable for CJK held normally, so those
    -- titles are painted glyph-by-glyph down the spine instead (the #392 PR).
    -- Flipping the rotation must not have quietly pulled them back in.
    local src = io.open("lib/bookshelf_spine_shelf.lua"):read("a")
    local at_rot = src:find("rotatedCopy%(rot_deg%)")
    assert(at_rot, "the rotation call could not be located")
    local vertical = src:match("local function _glyph.-\nend")
    assert(vertical and not vertical:match("titleRotation"),
        "the vertical CJK painter now depends on the title rotation")
end)

t.test("every opening tilt pours the picture back, none paints a page", function()
    -- BOTH tilts vacate space as the book leans forward, and both used to fill
    -- it with 0xFF -- the page colour in pre-invert space. Correct on paper; a
    -- white hole by day and a black one at night over a picture, exactly the
    -- size of the gap.
    --
    -- Checked as a pair because they were fixed a week apart: the spine tilt
    -- composes offscreen and needs patch(), the face-out paints straight to
    -- the framebuffer and needs restore(). Fixing one is easy to mistake for
    -- fixing the effect.
    local src = io.open("lib/bookshelf_spine_shelf.lua"):read("a")
    for _i, fn in ipairs({ "paintOpeningTilt", "paintFaceOutTilt" }) do
        local body = src:match("function SpineShelf%." .. fn .. "%(.-\nend")
        assert(body, fn .. " could not be located")
        assert(body:match("Wallpaper%.patch") or body:match("Wallpaper%.restore"),
            fn .. " fills its vacated strip with a flat colour over a picture")
    end
end)

t.test("the tilts keep their flat-colour fallback", function()
    -- On a plain page the page colour IS the right ground, and it must still
    -- be there when there is no wallpaper to put back.
    local src = io.open("lib/bookshelf_spine_shelf.lua"):read("a")
    for _i, fn in ipairs({ "paintOpeningTilt", "paintFaceOutTilt" }) do
        local body = src:match("function SpineShelf%." .. fn .. "%(.-\nend")
        assert(body:match("0xFF, 0xFF, 0xFF"),
            fn .. " lost its plain-page ground")
    end
end)

t.test("the close X lands exactly where the hamburger bars do", function()
    -- The X replaces the bars in the same slot, and bar_w == art, so the mask
    -- has no margin to absorb a rounding difference. The bars are placed by a
    -- CenterContainer -- floor((w - art) / 2) -- and the X used to be placed
    -- as centre-minus-half-art, which disagrees by a pixel whenever the strip
    -- width and the art size differ in parity. That pixel was the left edge of
    -- the first bar, showing through the close icon.
    local src = io.open("lib/bookshelf_start_menu.lua"):read("a")
    assert(src:match("local box_x = bd%.x %+ math%.floor%(%(bd%.w %- art%) / 2%)"),
        "the close X is not centred the way the bars are")
    assert(not src:match("cx %- math%.floor%(art / 2%)"),
        "the old centre-minus-half-art placement is back")
    -- And the property itself, so the reason survives the expression.
    local function bars(w, art) return math.floor((w - art) / 2) end
    local function mask(w, art) return math.floor(w / 2) - math.floor(art / 2) end
    local mismatches = 0
    for w = 90, 140 do
        for art = 28, 40 do
            if bars(w, art) ~= mask(w, art) then mismatches = mismatches + 1 end
        end
    end
    assert(mismatches > 0,
        "the two centrings agree everywhere -- this test has stopped meaning "
        .. "anything and the comment above is wrong")
end)

t.test("a screensaver folder is NOT read by default", function()
    -- It was, on the reasoning that readers commonly fill one and the same
    -- picture often suits both. Real ones refute it: most screensaver images
    -- shared for KOReader are PNGs with transparency, cut to sit alone on a
    -- blank screen, so behind a shelf they read as holes. A folder of them
    -- also floods the picker with entries that look exactly like wallpapers
    -- the reader put there.
    local src = io.open("lib/bookshelf_wallpaper.lua"):read("*a")
    local body = src:match("\nfunction M.extraDirs%(%)\n(.-)\nend\n")
    assert(body, "extraDirs moved or was renamed")
    assert(not body:find("screensaver", 1, true),
        "a screensaver folder is back in the default list")
    -- The MECHANISM stays: these two are genuine wallpaper folders.
    assert(body:find("sui_wallpapers", 1, true), "SimpleUI's folder should still be read")
    assert(body:find("/mnt/us/Wallpapers", 1, true), "the Wallpapers folder should still be read")
end)

t.test("a wallpaper name that no longer resolves reads as none", function()
    -- Removing a folder orphans any selection made from it, and so does
    -- deleting a file. Naming a picture the shelf is not painting sends the
    -- reader looking for a rendering bug.
    local set = io.open("lib/bookshelf_settings.lua"):read("*a")
    local body = set:match("local function wallpaperLabel%(setting, fallback%)\n(.-)\n    end\n")
    assert(body, "wallpaperLabel missing")
    assert(body:find("Wallpaper.pathFor(name)", 1, true),
        "the label must resolve through the same path the paint uses")
    local env = {
        BookshelfSettings = { read = function() return "screensavers:bg_ss27.png" end },
        Wallpaper = { pathFor = function() return nil end },
        type = type,
    }
    local fn = assert(load("return function(setting, fallback)\n" .. body .. "\nend",
        "label", "t", env))
    eq(fn()("wallpaper_default", "NONE"), "NONE",
        "an orphaned selection still named a file")
    env.Wallpaper.pathFor = function() return "/somewhere/bg_ss27.png" end
    eq(fn()("wallpaper_default", "NONE"), "screensavers:bg_ss27",
        "a resolvable name should still show, extension trimmed")
end)

t.done()
