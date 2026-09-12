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
