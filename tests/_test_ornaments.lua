-- tests/_test_ornaments.lua
-- Ornaments: user SVGs standing in spine-shelf gaps. Pins the pure parts --
-- header parsing, deterministic placement, sizing against the gap and the
-- plank's front, and the create-once template. Rendering is the rig's job.
--
-- Run from the plugin root: lua tests/_test_ornaments.lua

package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["logger"] = { dbg = function() end, info = function() end,
                             warn = function() end, err = function() end }
package.loaded["ui/widget/widget"] = { extend = function(_, t) return t end }
package.loaded["ui/geometry"] = { new = function(_, t) return t end }

-- Minimal lfs over shell + io, so the suite needs no lfs binding (same
-- approach as _test_cover_disk_cache.lua). Only what the module touches.
local function sh(cmd)
    local f = io.popen(cmd .. " 2>/dev/null"); local out = f:read("*a"); f:close(); return out
end
local lfs_shim = {
    attributes = function(path, attr)
        local q = "'" .. path .. "'"
        if attr == "mode" then
            if sh("test -d " .. q .. " && echo d"):match("d") then return "directory" end
            if sh("test -e " .. q .. " && echo f"):match("f") then return "file" end
            return nil
        elseif attr == "modification" then
            local m = sh("stat -c %Y " .. q)
            return tonumber(m)
        end
        return nil
    end,
    mkdir = function(path) return os.execute("mkdir -p '" .. path .. "'") end,
    dir = function(path)
        local list = {}
        for name in sh("ls -a '" .. path .. "'"):gmatch("[^\n]+") do list[#list + 1] = name end
        local i = 0
        return function() i = i + 1; return list[i] end
    end,
}

local t  = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq

local function fresh()
    package.loaded["lib/bookshelf_ornaments"] = nil
    local O = dofile("lib/bookshelf_ornaments.lua")
    O.SCAN_TTL = 0   -- the folder-cache tests below want every list() to look
    return O
end

-- A scratch data dir under the system temp dir (never the repo).
local tmp = os.getenv("TMPDIR") or "/tmp"
local function scratch()
    local d = string.format("%s/bookshelf_orn_test_%d_%d", tmp, os.time(), math.random(1e6))
    os.execute("rm -rf '" .. d .. "' && mkdir -p '" .. d .. "'")
    return d
end
local function exists(p) local f = io.open(p, "r"); if f then f:close() return true end return false end

t.test("parseHeader reads aspect and overhang", function()
    local O = fresh()
    local a, over = O.parseHeader('<svg viewBox="0 0 60 100"><!-- bookshelf:overhang=20 -->')
    eq(a, 0.6); eq(over, 0.2)
    a, over = O.parseHeader("<svg viewBox='0 0 100 50'>")
    eq(a, 2); eq(over, 0)
    a = O.parseHeader("<svg>")
    eq(a, nil, "no viewBox, no aspect")
    local _a, _o, ni = O.parseHeader('<svg viewBox="0 0 1 1"><!-- bookshelf:night=invert -->')
    eq(ni, true, "night flag read")
    _a, _o, ni = O.parseHeader('<svg viewBox="0 0 1 1">')
    eq(ni, false, "night flag defaults off")
end)

t.test("the seeded files' own headers parse", function()
    local O = fresh()
    for _i, seed in ipairs(O.SEED_FILES) do
        local a, over = O.parseHeader(seed.svg)
        eq(a, 60 / 106, seed.name); eq(over, 0, seed.name)
    end
end)

local POOL = {
    { path = "/o/a.svg", name = "a.svg", aspect = 0.6, overhang = 0 },
    { path = "/o/b.svg", name = "b.svg", aspect = 1.5, overhang = 0.25 },
}

t.test("pick is deterministic for a seed and varies across seeds", function()
    local O = fresh()
    local p1 = O.pick("book|1|8", 400, 300, POOL, { min_gap = 10, min_h = 10 })
    local p2 = O.pick("book|1|8", 400, 300, POOL, { min_gap = 10, min_h = 10 })
    assert((p1 == nil) == (p2 == nil), "same seed must agree on placing")
    if p1 then eq(p1.entry.path, p2.entry.path); eq(p1.w, p2.w) end
    local placed = 0
    for i = 1, 200 do
        if O.pick("seed" .. i, 400, 300, POOL, { min_gap = 10, min_h = 10 }) then
            placed = placed + 1
        end
    end
    assert(placed > 60 and placed < 140,
        "about half of eligible gaps should get one, got " .. placed .. "/200")
end)

t.test("a narrow gap stays empty; a fitting one sizes to the stand height", function()
    local O = fresh()
    O.CHANCE = 1.0
    assert(O.pick("s", 30, 300, POOL, { min_gap = 48, min_h = 10 }) == nil, "gap below the floor")
    local p = O.pick("s", 400, 300, { POOL[1] }, { min_gap = 48, min_h = 10 })
    assert(p, "expected a placement")
    eq(p.h, 240, "80% of the stand height")
    eq(p.w, 144, "width follows the aspect")
    eq(p.below, 0); eq(p.above, 240)
end)

t.test("a wide ornament shrinks to the gap", function()
    local O = fresh()
    O.CHANCE = 1.0
    local p = O.pick("s", 120, 300, { POOL[2] }, { min_gap = 48, min_h = 10, min_h_frac = 0 })
    assert(p, "expected a placement")
    eq(p.w, 120, "capped at the gap")
    eq(p.h, 80,  "height follows the cap through the aspect")
end)

t.test("a gap that would shrink the ornament to a speck stays bare", function()
    -- Ornaments scale with the shelf: shrunk to fit a narrow gap, an 80px
    -- plant beside 300px books read as a toy (device report). Below 45% of
    -- the stand height the shelf stays empty instead.
    local O = fresh()
    O.CHANCE = 1.0
    assert(O.pick("s", 120, 300, { POOL[2] }, { min_gap = 48, min_h = 10 }) == nil,
        "80px against a 300px stand is under the 45% floor")
    -- A gap that holds it at 45% or more is fine.
    local p = O.pick("s", 210, 300, { POOL[2] }, { min_gap = 48, min_h = 10 })
    assert(p and p.h >= 135, "210px wide at aspect 1.5 is 140px tall: placed")
end)

t.test("the overhang never reaches past the plank's front", function()
    local O = fresh()
    O.CHANCE = 1.0
    -- 25% overhang on a 240px ornament would be 60px; only 20px allowed.
    local p = O.pick("s", 1000, 300, { POOL[2] }, { min_gap = 48, min_h = 10, max_below = 20, min_h_frac = 0 })
    assert(p, "expected a placement")
    eq(p.below, 20)
    eq(p.h, 80, "shrunk so 25% of it is the allowed overhang")
    eq(p.above + p.below, p.h)
end)

t.test("too small after shrinking is not placed", function()
    local O = fresh()
    O.CHANCE = 1.0
    assert(O.pick("s", 1000, 300, { POOL[2] }, { min_gap = 48, min_h = 100, max_below = 20, min_h_frac = 0 }) == nil)
end)

t.test("ensureTemplate creates the folder with the template, once", function()
    local O = fresh()
    local d = scratch()
    O._data_dir = d
    O._lfs = lfs_shim
    O.ensureTemplate()
    assert(exists(O.dir() .. "/template.svg"), "template should be written")
    assert(exists(O.dir() .. "/cactus.svg"), "cactus should be written")
    -- The folder lives inside KOReader's own user-icons directory, not at
    -- the root of its storage.
    eq(O.dir(), d .. "/icons/bookshelf.ornaments")
    -- A user deletes the plant: a later session must not bring it back.
    os.remove(O.dir() .. "/template.svg")
    local O2 = fresh()
    O2._data_dir = d
    O2._lfs = lfs_shim
    O2.ensureTemplate()
    assert(not exists(O2.dir() .. "/template.svg"),
        "an existing folder must never be re-seeded")
    os.execute("rm -rf '" .. d .. "'")
end)

t.test("an icons folder a reader already has is reused, not disturbed", function()
    -- KOReader only creates icons/ if the reader made it themselves, so both
    -- branches are real: we may be creating it, or joining one that already
    -- holds their own SVGs. Joining must not touch what is in it.
    local O = fresh()
    local d = scratch()
    O._data_dir = d
    O._lfs = lfs_shim
    assert(os.execute("mkdir -p '" .. d .. "/icons'"))
    local mine = io.open(d .. "/icons/my-own-icon.svg", "w")
    mine:write("<svg/>"); mine:close()
    O.ensureTemplate()
    assert(exists(O.dir() .. "/template.svg"), "ornaments folder not created inside icons/")
    assert(exists(d .. "/icons/my-own-icon.svg"), "a reader's own icon was disturbed")
    os.execute("rm -rf '" .. d .. "'")
end)

t.test("list finds SVGs and reads their headers", function()
    local O = fresh()
    local d = scratch()
    O._data_dir = d
    O._lfs = lfs_shim
    O.ensureTemplate()
    local f = io.open(O.dir() .. "/cat.SVG", "w")
    f:write('<svg viewBox="0 0 120 80"><!-- bookshelf:overhang=16 --></svg>'); f:close()
    local f2 = io.open(O.dir() .. "/notes.txt", "w"); f2:write("x"); f2:close()
    local list = O.list()
    eq(#list, 3, "cat + the two seeded svgs, the txt ignored")
    eq(list[1].name, "cactus.svg")
    eq(list[2].name, "cat.SVG"); eq(list[2].aspect, 1.5); eq(list[2].overhang, 0.2)
    eq(list[3].name, "template.svg")
    os.execute("rm -rf '" .. d .. "'")
end)

t.test("render caches, inverts for night, and evicts with a real free", function()
    local O = fresh()
    O.CACHE_MAX = 4
    local made, freed = 0, 0
    O._render = function(path, w, h)
        made = made + 1
        local o = { inverted = false }
        o.getWidth = function() return w end
        o.getHeight = function() return h end
        o.invertRect = function() o.inverted = true end
        o.free = function() freed = freed + 1 end
        return o
    end
    local e = POOL[1]
    local a = O.render(e, 10, 10, false)
    assert(O.render(e, 10, 10, false) == a, "second render must hit the cache")
    eq(made, 1)
    local n = O.render(e, 10, 10, true)
    assert(n.inverted, "night render of colour artwork is pre-inverted (faithful)")
    local chalk = { path = "/o/c.svg", name = "c.svg", aspect = 1, overhang = 0, night_invert = true }
    O._has_color = false
    local c = O.render(chalk, 10, 10, true)
    assert(not c.inverted, "on grayscale a night=invert ornament is left alone so it displays inverted")
    O._has_color = true
    local c2 = O.render(chalk, 11, 11, true)
    assert(c2.inverted, "on a colour panel the flag is ignored: colours stay faithful")
    O.render(e, 20, 20, false)     -- fifth key: evicts the oldest
    eq(freed, 1, "eviction frees the bb the cache owned")
end)

t.test("chalk follows the look, pre-inversion follows the frame, and the key knows", function()
    -- Two axes, as everywhere else on the shelf: the LOOK the reader asked
    -- for (theme) and whether the panel INVERTS the frame (device night
    -- mode). render() used to read only the frame, so under the shelf's own
    -- dark theme by day an invert-flagged ornament painted its authored dark
    -- silhouette straight onto a black plank.
    local O = fresh()
    O.CACHE_MAX = 16
    O._has_color = false
    local made = 0
    O._render = function(path, w, h)
        made = made + 1
        local o = { inverted = false }
        o.getWidth = function() return w end
        o.getHeight = function() return h end
        o.invertRect = function() o.inverted = true end
        o.free = function() end
        return o
    end
    local look, pic = false, false
    package.loaded["lib/bookshelf_cover_progress"] = {
        theme = function() return look, nil end }
    package.loaded["lib/bookshelf_wallpaper"] = {
        isShowing = function() return pic end }
    local chalk = { path = "/o/c.svg", name = "c.svg", aspect = 1, overhang = 0,
                    night_invert = true }
    -- light look, day frame: authored artwork.
    look = false
    assert(not O.render(chalk, 10, 10, false).inverted, "light/day must be faithful")
    -- DARK look, DAY frame (the pinned theme): nothing inverts the frame, so
    -- the chalk has to be painted inverted by hand. This was the broken case.
    look = true
    local m0 = made
    local dd = O.render(chalk, 10, 10, false)
    assert(dd.inverted, "dark look by day must paint the chalk inverted itself")
    assert(made == m0 + 1, "a different painted result must not share the cache entry")
    -- dark look, NIGHT frame (auto following the device): leave it, the panel
    -- inverts it into chalk. Same painted bytes as light/day: may share.
    assert(not O.render(chalk, 10, 10, true).inverted, "dark/night is left for the panel")
    -- light look pinned, night frame: pre-invert so the panel shows it faithful.
    look = false
    assert(O.render(chalk, 10, 10, true).inverted, "light/night pre-inverts to stay faithful")
    -- a picture behind: never chalk, whatever the look (maintainer ruling).
    look, pic = true, true
    assert(not O.render(chalk, 12, 12, false).inverted, "over a picture, no chalk by day")
    assert(O.render(chalk, 12, 12, true).inverted, "over a picture at night, faithful")
    package.loaded["lib/bookshelf_cover_progress"] = nil
    package.loaded["lib/bookshelf_wallpaper"] = nil
end)

-- ── the folder cache: a restart must not be the way to refresh it ──────────
--
-- list() reads every file's header, so it caches. The question is what it
-- keys that cache on, and mtime alone turned out to be wrong on the hardware:
-- measured on a Kindle's fuse.fsp mount, ADDING a file bumps the directory's
-- mtime but DELETING one does not (1789238485 before the rm and after it,
-- with a real gap between). So a removed ornament stayed in the pool for the
-- rest of the session -- still picked for gaps, then failing to open, so the
-- gap simply stayed empty and only a restart cleared it.
--
-- A second, quieter case the same key got wrong: two files added inside one
-- second. Directory mtimes are whole seconds, so the second file was invisible
-- until something else touched the folder.

t.test("cache: a new ornament is picked up with no restart", function()
    local O = fresh()
    local d = scratch()
    O._data_dir = d; O._lfs = lfs_shim
    O.ensureTemplate()
    eq(#O.list(), 2, "the two seeded svgs")
    local f = io.open(O.dir() .. "/newcomer.svg", "w")
    f:write('<svg viewBox="0 0 10 10"></svg>'); f:close()
    eq(#O.list(), 3, "the new file joins the pool on the next render")
    os.execute("rm -rf '" .. d .. "'")
end)

t.test("cache: within the scan TTL the folder is not listed again", function()
    -- list() runs once per spine plan, up to three times a rebuild, and a
    -- FUSE directory listing was measured at 340ms on a tired Kindle.
    local O = fresh()
    local d = scratch()
    O._data_dir = d
    local listings = 0
    O._lfs = setmetatable({
        dir = function(...) listings = listings + 1; return lfs_shim.dir(...) end,
    }, { __index = lfs_shim })
    O.ensureTemplate()
    local t = 1000
    O._clock = function() return t end
    O.SCAN_TTL = 15
    eq(#O.list(), 2)
    local n1 = listings
    O.list(); O.list()
    eq(listings, n1, "two calls inside the TTL must not touch the folder")
    t = t + 15
    O.list()
    eq(listings, n1 + 1, "once the TTL has passed, the folder is looked at again")
    os.execute("rm -rf '" .. d .. "'")
end)

t.test("cache: a removal is noticed even when the mtime does not move", function()
    local O = fresh()
    local d = scratch()
    O._data_dir = d; O._lfs = lfs_shim
    O.ensureTemplate()
    local f = io.open(O.dir() .. "/doomed.svg", "w")
    f:write('<svg viewBox="0 0 10 10"></svg>'); f:close()
    eq(#O.list(), 3, "three to start")
    local mt = lfs_shim.attributes(O.dir(), "modification")
    os.remove(O.dir() .. "/doomed.svg")
    -- Pin the directory mtime back where it was: this is what that filesystem
    -- leaves behind, and the whole point of the test.
    os.execute(string.format("touch -d @%d '%s'", mt, O.dir()))
    eq(lfs_shim.attributes(O.dir(), "modification"), mt,
       "the test's own premise: the mtime must be unchanged")
    eq(#O.list(), 2, "the removed ornament has to leave the pool")
    os.execute("rm -rf '" .. d .. "'")
end)

t.test("cache: two files added within one second are both seen", function()
    local O = fresh()
    local d = scratch()
    O._data_dir = d; O._lfs = lfs_shim
    O.ensureTemplate()
    O.list()
    local mt = lfs_shim.attributes(O.dir(), "modification")
    for _, n in ipairs({ "one.svg", "two.svg" }) do
        local f = io.open(O.dir() .. "/" .. n, "w")
        f:write('<svg viewBox="0 0 10 10"></svg>'); f:close()
    end
    -- Whole-second mtimes: both writes can land in the same tick as the read.
    os.execute(string.format("touch -d @%d '%s'", mt, O.dir()))
    eq(#O.list(), 4, "both newcomers must be seen")
    os.execute("rm -rf '" .. d .. "'")
end)

t.test("cache: an unchanged folder is served from the cache, not re-read", function()
    -- The cache still has to earn its keep: the point of the key is to avoid
    -- re-opening and re-parsing every file on every render.
    local O = fresh()
    local d = scratch()
    O._data_dir = d; O._lfs = lfs_shim
    O.ensureTemplate()
    local first = O.list()
    assert(O.list() == first,
        "an untouched folder must hand back the very same table")
    os.execute("rm -rf '" .. d .. "'")
end)

-- ── PNG ornaments ──────────────────────────────────────────────────────────
--
-- An SVG carries its own conventions in XML comments: the viewBox gives the
-- aspect, "bookshelf:overhang=N" says how far it hangs over the plank's front,
-- "bookshelf:night=invert" asks to turn chalk on a grey panel. A PNG has
-- nowhere to write any of that, so:
--
--   aspect   comes from the IHDR chunk -- 8-byte signature, then a length and
--            the tag, then width and height as big-endian u32. Read from the
--            first 32 bytes; nothing is decoded to list a folder.
--   overhang is always 0. A raster is a flat picture; it stands ON the plank.
--            (The maintainer's call, and the reason stand_h is left alone: a
--            transparent margin inside the image sets an ornament back if it
--            wants to be set back, and the full depth stays available for
--            artwork that wants to use it.)
--   night    comes from the FILENAME: cat.invert.png. The only channel a PNG
--            has that a reader can use without tooling.

local function be32(n)
    return string.char(math.floor(n / 16777216) % 256,
                       math.floor(n / 65536) % 256,
                       math.floor(n / 256) % 256,
                       n % 256)
end
-- Just the header. list() never decodes, so this is a complete input for it.
local function png_header(w, h)
    return "\137PNG\r\n\026\n" .. be32(13) .. "IHDR" .. be32(w) .. be32(h)
        .. string.char(8, 6, 0, 0, 0)   -- 8-bit, RGBA
end

t.test("png: aspect comes from the IHDR width and height", function()
    local O = fresh()
    local aspect, over, invert = O.parsePngHeader(png_header(120, 80))
    eq(aspect, 1.5)
    eq(over, 0, "a raster never overhangs the plank")
    eq(invert, false, "the night flag is not in the bytes")
end)

t.test("png: a large image parses without overflowing", function()
    local O = fresh()
    -- Four bytes of big-endian is easy to get wrong one byte at a time.
    eq(O.parsePngHeader(png_header(4096, 2048)), 2)
    eq(O.parsePngHeader(png_header(1, 1)), 1)
end)

t.test("png: anything that is not a PNG header is refused", function()
    local O = fresh()
    assert(not O.parsePngHeader(""), "empty")
    assert(not O.parsePngHeader("not a png at all, really"), "wrong magic")
    assert(not O.parsePngHeader(png_header(10, 10):sub(1, 18)),
        "a truncated header must not yield half a number")
    -- Right magic, wrong chunk: a PNG whose first chunk is not IHDR is
    -- malformed, and guessing past it would read whatever came next as a size.
    local bad = "\137PNG\r\n\026\n" .. be32(13) .. "IDAT" .. be32(10) .. be32(10)
    assert(not O.parsePngHeader(bad), "first chunk must be IHDR")
    assert(not O.parsePngHeader(png_header(0, 10)), "zero width")
    assert(not O.parsePngHeader(png_header(10, 0)), "zero height")
end)

t.test("png: list picks PNGs up beside the SVGs, with no overhang", function()
    local O = fresh()
    local d = scratch()
    O._data_dir = d
    O._lfs = lfs_shim
    O.ensureTemplate()
    local f = io.open(O.dir() .. "/plant.png", "wb")
    f:write(png_header(200, 400)); f:close()
    local list = O.list()
    eq(#list, 3, "plant.png + the two seeded svgs")
    eq(list[1].name, "cactus.svg")
    eq(list[2].name, "plant.png")
    eq(list[2].aspect, 0.5)
    eq(list[2].overhang, 0, "a PNG stands on the plank, it does not hang over it")
    os.execute("rm -rf '" .. d .. "'")
end)

t.test("png: .invert.png asks for the chalk look, a plain .png does not", function()
    local O = fresh()
    local d = scratch()
    O._data_dir = d
    O._lfs = lfs_shim
    O.ensureTemplate()
    for _, n in ipairs({ "plain.png", "cat.invert.png", "UPPER.INVERT.PNG" }) do
        local f = io.open(O.dir() .. "/" .. n, "wb")
        f:write(png_header(100, 100)); f:close()
    end
    local by = {}
    for _, e in ipairs(O.list()) do by[e.name] = e end
    eq(by["plain.png"].night_invert, false, "no suffix, faithful colours")
    assert(by["cat.invert.png"].night_invert, "the suffix asks for chalk")
    assert(by["UPPER.INVERT.PNG"].night_invert, "and it is case-insensitive")
    os.execute("rm -rf '" .. d .. "'")
end)

t.test("png: a file that is not really a PNG is skipped, not fatal", function()
    local O = fresh()
    local d = scratch()
    O._data_dir = d
    O._lfs = lfs_shim
    O.ensureTemplate()
    local f = io.open(O.dir() .. "/lies.png", "wb")
    f:write("this is a text file wearing a hat"); f:close()
    local list = O.list()
    eq(#list, 2, "only the two seeded svgs; the impostor is dropped")
    os.execute("rm -rf '" .. d .. "'")
end)

t.test("png: rendering routes to the raster path, SVG keeps the vector one", function()
    -- The dispatch itself, through the real defaultRender. A fake
    -- ui/renderimage records which of the two calls it received.
    local O = fresh()
    local calls = {}
    local function fakeBB(w, h)
        return { getWidth = function() return w end,
                 getHeight = function() return h end,
                 invertRect = function() end,
                 free = function() end }
    end
    package.loaded["ui/renderimage"] = {
        renderSVGImageFile = function(_self, path, w, h)
            calls[#calls + 1] = { how = "svg", path = path }
            return fakeBB(w, h)
        end,
        renderImageFile = function(_self, path, want_frames, w, h)
            calls[#calls + 1] = { how = "raster", path = path,
                                  frames = want_frames }
            return fakeBB(w, h)
        end,
    }
    O.render({ path = "/o/a.svg", aspect = 1, overhang = 0 }, 10, 10, false)
    O.render({ path = "/o/b.png", aspect = 1, overhang = 0 }, 10, 10, false)
    O.render({ path = "/o/c.PNG", aspect = 1, overhang = 0 }, 10, 10, false)
    package.loaded["ui/renderimage"] = nil
    eq(#calls, 3)
    eq(calls[1].how, "svg", "an .svg must keep nanosvg")
    eq(calls[2].how, "raster", "a .png must go to the image renderer")
    eq(calls[3].how, "raster", "and the extension test is case-insensitive")
    assert(calls[2].frames == false or calls[2].frames == nil,
        "an ornament is one frame; asking for an animation list would hand"
        .. " back functions instead of a blitbuffer")
end)

-- ── which ornament: a rotation, not a hash ─────────────────────────────────

t.test("the rotation hands every ornament an equal share", function()
    -- A hashed choice clusters over a handful of files -- the same one turns
    -- up several times running while another goes unseen for pages (device
    -- report: "I've not seen the cacti for a while"). Turn-taking makes the
    -- share equal by construction.
    local O = fresh()
    O._rot, O._rot_n = {}, 0
    local seen = {}
    for i = 1, 12 do
        local idx = O.rotationFor("seed" .. i, 3)
        seen[idx] = (seen[idx] or 0) + 1
    end
    eq(seen[1], 4, "first ornament")
    eq(seen[2], 4, "second")
    eq(seen[3], 4, "third")
end)

t.test("a seed keeps the ornament it was given", function()
    -- pick() runs again on every repaint of the same row; an ornament that
    -- changed between repaints would flicker.
    local O = fresh()
    O._rot, O._rot_n = {}, 0
    local first = O.rotationFor("a", 2)
    O.rotationFor("b", 2)
    O.rotationFor("c", 2)
    eq(O.rotationFor("a", 2), first, "same seed, same ornament")
end)

t.test("the rotation map is bounded", function()
    -- Page turns mint new seeds forever.
    local O = fresh()
    O._rot, O._rot_n = {}, 0
    local was = O.ROT_MAX
    O.ROT_MAX = 4
    for i = 1, 6 do O.rotationFor("s" .. i, 2) end
    assert(O._rot_n <= 4, "the map was dropped rather than growing without end")
    O.ROT_MAX = was
end)

t.test("one ornament in the folder needs no rotation", function()
    local O = fresh()
    eq(O.rotationFor("anything", 1), 1)
    eq(O.rotationFor("anything", 0), 1, "and an empty folder does not divide by zero")
end)

t.test("pick takes a per-call chance", function()
    local O = fresh()
    -- The gaps BETWEEN sections are far more numerous than the one at a row's
    -- end, so they run at lower odds.
    local always = { chance = 1, min_gap = 0, min_h = 0 }
    local never  = { chance = 0, min_gap = 0, min_h = 0 }
    assert(O.pick("s", 1000, 400, POOL, always), "chance 1 always places")
    assert(not O.pick("s", 1000, 400, POOL, never), "chance 0 never does")
end)

-- ── the seeded files must be valid SVG ───────────────────────────────────
--
-- template.svg shipped in v5.0.0 NOT well-formed: "--" is illegal inside an
-- XML comment, and its own comment block used it as a dash three times.
-- KOReader's renderer (nanosvg) is lenient enough to draw it anyway, so the
-- shelf looked right and nothing failed -- but this is the file a reader is
-- invited to copy as a starting point, and any real SVG editor rejects it.
-- Caught by the maintainer opening it, not by any test.

local function seedBodies()
    local src = assert(io.open("lib/bookshelf_ornaments.lua")):read("*a")
    local out = {}
    for name, body in src:gmatch("M%.([A-Z]+)_SVG%s*=%s*%[==%[(.-)%]==%]") do
        out[#out + 1] = { name = name:lower() .. ".svg", body = body }
    end
    return out
end

t.test("every seeded ornament is shipped, and there are at least two", function()
    local seeds = seedBodies()
    assert(#seeds >= 2, "expected the template and the cactus, found " .. #seeds)
end)

t.test("no seeded SVG has '--' inside an XML comment", function()
    -- The whole bug, stated as the rule it broke.
    for _i, s in ipairs(seedBodies()) do
        for comment in s.body:gmatch("<!%-%-(.-)%-%->") do
            assert(not comment:find("%-%-"),
                s.name .. ": '--' inside an XML comment makes the file invalid; "
                .. "use a single hyphen or restructure")
        end
    end
end)

t.test("every seeded SVG has balanced comment delimiters and one svg root", function()
    for _i, s in ipairs(seedBodies()) do
        local opens = select(2, s.body:gsub("<!%-%-", ""))
        local closes = select(2, s.body:gsub("%-%->", ""))
        eq(opens, closes, s.name .. ": unbalanced comment delimiters")
        eq(select(2, s.body:gsub("<svg", "")), 1, s.name .. ": expected one <svg")
        eq(select(2, s.body:gsub("</svg>", "")), 1, s.name .. ": expected one </svg>")
        assert(s.body:find('viewBox="'), s.name .. ": no viewBox, so it cannot be placed")
    end
end)

-- ── viewBox forms the SVG spec allows ──────────────────────────────────────
--
-- A file parseHeader cannot size is dropped from the pool silently, so a user
-- sees nothing and has nothing to go on. Reported as "I added .svg files to
-- the ornament folder but they don't show up" -- and the files were fine; the
-- pattern was too strict.
--
-- The spec allows the four viewBox numbers to be separated by whitespace AND /
-- OR a comma, and plenty of exporters emit commas.

t.test("parseHeader accepts a comma-separated viewBox", function()
    local O = fresh()
    local a = O.parseHeader('<svg viewBox="0,0,60,100">')
    assert(a, "a comma-separated viewBox was rejected; it is valid SVG")
    assert(math.abs(a - 0.6) < 1e-9, "wrong aspect: " .. tostring(a))
end)

t.test("parseHeader accepts comma-and-space", function()
    local O = fresh()
    local a = O.parseHeader('<svg viewBox="0, 0, 60, 100">')
    assert(a and math.abs(a - 0.6) < 1e-9, "got: " .. tostring(a))
end)

t.test("parseHeader falls back to width and height", function()
    local O = fresh()
    -- No viewBox at all. nanosvg can still rasterise these, so refusing them
    -- cost us files that would have rendered perfectly well.
    local a = O.parseHeader('<svg width="60" height="100" xmlns="...">')
    assert(a and math.abs(a - 0.6) < 1e-9, "got: " .. tostring(a))
end)

t.test("the width/height fallback tolerates units", function()
    local O = fresh()
    -- Aspect is a ratio, so as long as both carry the same unit it cancels.
    local a = O.parseHeader('<svg width="60mm" height="100mm">')
    assert(a and math.abs(a - 0.6) < 1e-9, "got: " .. tostring(a))
end)

t.test("the fallback does not read stroke-width", function()
    local O = fresh()
    -- The obvious way to write this pattern matches `stroke-width` too, which
    -- would size an ornament off a line weight.
    local a = O.parseHeader('<svg><path stroke-width="4" height="9"/></svg>')
    assert(not a, "matched an attribute outside the <svg> tag: " .. tostring(a))
end)

t.test("a viewBox still wins over width and height", function()
    local O = fresh()
    -- The viewBox is the coordinate system the overhang convention is measured
    -- in, so it has to stay authoritative.
    local a = O.parseHeader('<svg width="999" height="1" viewBox="0 0 60 100">')
    assert(a and math.abs(a - 0.6) < 1e-9, "width/height overrode viewBox: " .. tostring(a))
end)

t.test("something with no dimensions at all is still refused", function()
    local O = fresh()
    assert(not O.parseHeader("<svg xmlns='http://www.w3.org/2000/svg'>"))
    assert(not O.parseHeader("not an svg"))
end)

-- ── last resort: ask the renderer ──────────────────────────────────────────
--
-- parseHeader is a regex over the first 8KB, so it only knows the forms it was
-- taught. nanosvg parses the file properly and will report a natural size for
-- anything it can open -- including percentage sizes and files carrying
-- neither a viewBox nor width/height, where it applies its own defaults.
--
-- Used ONLY when the header yields nothing, so the common path stays a cheap
-- read and no ornament folder pays a full parse it did not need. Behind a seam
-- (M._size) because these suites run without KOReader.

t.test("sizeOf falls back to the renderer when the header cannot size it", function()
    local O = fresh()
    local asked
    O._size = function(path) asked = path; return 40, 80 end
    local aspect = O.sizeOf("/orn/mystery.svg", "<svg>no dimensions here</svg>")
    assert(aspect, "no size came back")
    assert(math.abs(aspect - 0.5) < 1e-9, "wrong aspect: " .. tostring(aspect))
    eq(asked, "/orn/mystery.svg", "the renderer was not consulted")
end)

t.test("sizeOf does NOT consult the renderer when the header sufficed", function()
    -- The whole point of keeping it a last resort: a normal folder should not
    -- pay a full SVG parse per file on every folder change.
    local O = fresh()
    local asked = false
    O._size = function() asked = true; return 1, 1 end
    local aspect = O.sizeOf("/orn/plant.svg", '<svg viewBox="0 0 60 100">')
    assert(math.abs(aspect - 0.6) < 1e-9, "header aspect lost: " .. tostring(aspect))
    assert(not asked, "the renderer was consulted despite a usable viewBox")
end)

t.test("sizeOf survives a renderer that throws or returns nothing", function()
    -- A corrupt file must drop out of the pool, not take the scan down with it.
    local O = fresh()
    O._size = function() error("nanosvg said no") end
    assert(not O.sizeOf("/orn/bad.svg", "<svg>"), "an error became a size")
    O._size = function() return nil, nil end
    assert(not O.sizeOf("/orn/bad.svg", "<svg>"), "nil became a size")
    O._size = function() return 0, 10 end
    assert(not O.sizeOf("/orn/bad.svg", "<svg>"), "a zero width became a size")
end)

t.test("an overhang comment still works off the renderer's height", function()
    -- bookshelf:overhang is in the file's own coordinate units, and nanosvg
    -- reports its size in those same units, so the share is still meaningful.
    local O = fresh()
    O._size = function() return 60, 100 end
    local aspect, over = O.sizeOf("/orn/x.svg",
        "<svg><!-- bookshelf:overhang=20 --></svg>")
    assert(math.abs(aspect - 0.6) < 1e-9, "aspect: " .. tostring(aspect))
    assert(math.abs(over - 0.2) < 1e-9, "overhang share: " .. tostring(over))
end)

-- ── a bitmap wrapped in an SVG envelope ────────────────────────────────────
--
-- Reported (issue 404) with six files attached, every one of them a single
-- <image> element holding base64 PNG data -- what you get when a converter
-- "makes an SVG" out of a photo instead of tracing it. They parse, they carry
-- a correct viewBox, so they join the pool and are given a gap; then nothing
-- is drawn in it.
--
-- nanosvg has no <image> handler at all. The element table in the shipped
-- library is exactly:
--
--   circle defs ellipse linearGradient path polygon polyline radialGradient rect
--
-- so the element is skipped and the file renders empty. Resizing it, which the
-- reporter tried, cannot help.
--
-- Detected from the header we already read, and only WARNED about, never
-- rejected: a legitimate drawing could carry an <image> alongside real shapes
-- further into the file than the 8KB we look at, and dropping that would be a
-- worse failure than the one being diagnosed.

t.test("a bitmap wrapped in SVG is flagged", function()
    local O = fresh()
    local head = '<svg viewBox="0 0 100 105"><image href="data:image/png;base64,iVBORw0KGgo'
    assert(O.looksLikeWrappedBitmap(head),
        "an <image>-only SVG was not recognised as a wrapped bitmap")
end)

t.test("a real drawing is not flagged", function()
    local O = fresh()
    local head = '<svg viewBox="0 0 60 100"><path d="M12 70 H48"/><ellipse cx="30"/></svg>'
    assert(not O.looksLikeWrappedBitmap(head), "a path drawing was flagged")
end)

t.test("an image ALONGSIDE real shapes is not flagged", function()
    -- The false positive that matters: something partly traced, partly not,
    -- still draws its traced half and must not be written off.
    local O = fresh()
    local head = '<svg viewBox="0 0 60 100"><image href="data:..."/><path d="M1 2"/></svg>'
    assert(not O.looksLikeWrappedBitmap(head),
        "a mixed file was flagged; it still has shapes to draw")
end)

t.test("flagging never removes the file from the pool", function()
    -- Warn, do not reject. We only see the first 8KB, so this is a hint.
    local O = fresh()
    local aspect = O.sizeOf("/orn/wrapped.svg",
        '<svg viewBox="0 0 100 105"><image href="data:image/png;base64,AAAA"/>')
    assert(aspect and math.abs(aspect - (100/105)) < 1e-9,
        "a wrapped bitmap was refused a size: " .. tostring(aspect))
end)

t.test("the folder's own instructions mention it", function()
    -- The log line is for us; the template is what a reader actually opens.
    local src = assert(io.open("lib/bookshelf_ornaments.lua")):read("*a")
    local tpl = src:match("M.TEMPLATE_BODY%s*=%s*%[%[(.-)%]%]")
             or src:match("bookshelf:overhang=0")
    assert(src:find("photo", 1, true) or src:find("bitmap", 1, true),
        "the template never warns that a photo saved as SVG will not draw")
end)

-- ── Frequency ──────────────────────────────────────────────────────

local function withFreq(v, fn)
    package.loaded["lib/bookshelf_settings_store"] = {
        read = function(k)
            if k == "ornament_frequency" then return v end
        end,
    }
    local W = fresh()
    local ok, err = pcall(fn, W)
    package.loaded["lib/bookshelf_settings_store"] = nil
    if not ok then error(err, 0) end
end

t.test("frequency scales BOTH chances, keeping them apart", function()
    -- The two base odds are deliberately far apart: a grouping chip's section
    -- breaks are far more numerous than a plain shelf's gaps, so identical
    -- odds there would put a plant between every other series. A setting that
    -- replaced the numbers instead of scaling them would collapse that.
    local W = fresh()
    assert(W.CHANCE > W.GROUP_CHANCE * 2,
        "the two base chances are no longer meaningfully apart")
    local body = (io.open("lib/bookshelf_ornaments.lua"):read("a"))
        :match("function M%.pick%(seed.-\nend")
    assert(body:match("M%.frequency%(%)"),
        "pick no longer scales by the frequency setting")
end)

t.test("None places nothing, whatever the gap", function()
    withFreq(0, function(W)
        W._entries = nil
        local entries = { { name = "a.svg", aspect = 1, overhang = 0 } }
        for i = 1, 40 do
            eq(W.pick("seed" .. i, 10000, 400, entries, { min_gap = 0, min_h = 1 }),
               nil, "an ornament appeared at frequency 0")
        end
    end)
end)

t.test("a higher frequency places strictly more often", function()
    -- Counted over the same seeds, so the comparison is the setting and
    -- nothing else.
    local entries = { { name = "a.svg", aspect = 1, overhang = 0 } }
    local function hits(freq)
        local n = 0
        withFreq(freq, function(W)
            for i = 1, 200 do
                if W.pick("s" .. i, 10000, 400, entries, { min_gap = 0, min_h = 1 }) then
                    n = n + 1
                end
            end
        end)
        return n
    end
    local low, high = hits(0.5), hits(2)
    assert(high > low, string.format(
        "frequency 2 placed %d and frequency 0.5 placed %d", high, low))
end)

t.test("only the higher frequencies reserve a row end", function()
    -- Reserving takes width off every shelf before the books are packed, so
    -- it must not happen at the settings that mean "occasionally".
    withFreq(1,   function(W) eq(W.reservesRowEnds(), false) end)
    withFreq(2,   function(W) eq(W.reservesRowEnds(), true) end)
    withFreq(0,   function(W) eq(W.reservesRowEnds(), false) end)
end)

t.test("the reservation is taken off BOTH packers", function()
    -- fillRows decides which books are on the page; balanceRows re-breaks the
    -- same books across the same rows. Give one the full width and it packs a
    -- book into the strip the other stands an ornament in.
    -- The width is now a per-row function (a row with a piece at its end
    -- gives up that piece's width, no other row gives up anything); the rule
    -- that matters is unchanged: BOTH packers must be handed the same one.
    local src = io.open("lib/bookshelf_spine_shelf.lua"):read("a")
    assert(src:match("SpineLayout%.fillRows%(widths, availAt"),
        "fillRows does not pack into the per-row width")
    assert(src:match("SpineLayout%.balanceRows%(widths, availAt"),
        "balanceRows does not balance into the per-row width")
end)

t.test("there is ONE row-end ornament painter, and it knows rows are centred", function()
    -- A second painter was added here and overlapped the first. The existing
    -- one is correct and subtle: books stand CENTRED, so the row's leftover is
    -- split between both ends (`lead`), and it derives its slack from
    -- lead + content_w and places on whichever side the seed picked. A painter
    -- that assumes the leftover is all at the right edge stands its ornament
    -- on the last book.
    local src = io.open("lib/bookshelf_spine_shelf.lua"):read("a")
    local body = src:match("function SpineShelf%.rowWidget.-\nend\n")
    assert(body, "rowWidget could not be located")
    local n = select(2, body:gsub("Orn%.pick", ""))
    assert(n == 2, string.format(
        "expected 2 Orn.pick calls in rowWidget (bare plank, row end); found %d", n))
    assert(body:match("local slack  = opts%.width %- %(lead %+ content_w%)"),
        "the row-end ornament no longer accounts for the centring lead")
end)

t.test("a reserved row end is actually used, not left to a dice roll", function()
    -- plan() takes the width off before the books are packed. Leaving the
    -- strip empty on a dice roll would cost a book's width for nothing.
    local src = io.open("lib/bookshelf_spine_shelf.lua"):read("a")
    assert(src:match("chance    = reserved and 1 or nil"),
        "the reserved row end still places on the default odds")
end)

t.test("no ornament stands twice on one screen", function()
    -- Placements are seeded independently -- a section break knows the books
    -- either side, a row end knows its row -- so nothing stopped two landing
    -- on the same file. With a folder of three that is not unlikely, and it
    -- reads as a mistake rather than as decoration.
    local W = fresh()
    local entries = {}
    for i = 1, 3 do
        entries[i] = { name = "o" .. i .. ".svg", aspect = 1, overhang = 0 }
    end
    W.beginScreen()
    local seen = {}
    for i = 1, 3 do
        local pl = W.pick("gap" .. i, 10000, 400, entries,
                          { min_gap = 0, min_h = 1, chance = 1 })
        assert(pl, "placement " .. i .. " was refused")
        assert(not seen[pl.entry.name],
            pl.entry.name .. " stood twice on the same screen")
        seen[pl.entry.name] = true
    end
end)

t.test("a repeat beats a blank once every ornament is up", function()
    -- Exhausting a small folder must not start refusing placements: the gap
    -- is there either way, and an empty one looks like a bug.
    local W = fresh()
    local entries = { { name = "only.svg", aspect = 1, overhang = 0 } }
    W.beginScreen()
    assert(W.pick("a", 10000, 400, entries, { min_gap = 0, min_h = 1, chance = 1 }))
    assert(W.pick("b", 10000, 400, entries, { min_gap = 0, min_h = 1, chance = 1 }),
        "the second gap was left empty rather than repeating the only ornament")
end)

t.test("a refused placement does not consume an ornament", function()
    -- pick bails on several paths (too short, too narrow, the odds). Counting
    -- one that never stood would push the next gap onto a different file for
    -- no reason, and exhaust a small folder early.
    local W = fresh()
    local entries = {}
    for i = 1, 3 do
        entries[i] = { name = "o" .. i .. ".svg", aspect = 1, overhang = 0 }
    end
    W.beginScreen()
    -- min_h far above anything this stand height can produce: always refused.
    for i = 1, 5 do
        eq(W.pick("x" .. i, 10000, 40, entries, { min_gap = 0, min_h = 9999, chance = 1 }),
           nil)
    end
    local used = 0
    for _k in pairs(W._used) do used = used + 1 end
    eq(used, 0, "refused placements were counted as standing")
end)

t.test("the screen is reset where the page is planned", function()
    local src = io.open("lib/bookshelf_spine_shelf.lua"):read("a")
    local plan = src:match("function SpineShelf%.plan%(items, opts%).-\n    local flat")
    assert(plan, "the plan preamble could not be located")
    assert(plan:match("beginScreen"),
        "nothing clears the used set when a page is planned")
end)


t.test("a reserved row end is decided per row, in the plan, at the piece's own width", function()
    -- At the higher frequencies plan() used to take one stand-height square
    -- off EVERY row before packing, and the row widget then rolled for a
    -- piece; a row that got none kept the hole, and one that did still had
    -- the difference between the square and the piece. Now the plan picks
    -- per row and reserves exactly that width; rows without a piece keep the
    -- whole shelf (maintainer).
    local src = io.open("lib/bookshelf_spine_shelf.lua"):read("a")
    local plan = src:match("\nfunction SpineShelf%.plan%(items, opts%)\n.-\nend\n")
    assert(plan, "plan not found")
    local code = plan:gsub("%-%-[^\n]*", "")
    assert(not code:find("content_w_books = content_w_books %- orn%.row_end"),
        "plan still takes the nominal square off every row")
    assert(code:find("row_orn", 1, true) and code:find("SpineLayout%.fillRows%(widths, availAt"),
        "plan does not hand fillRows a per-row width")
    assert(code:find("%.ornament = row_orn"), "plan does not tell the row which piece stands on it")
    local rw = src:match("\nfunction SpineShelf%.rowWidget%(opts%)\n.-\nend\n")
    assert(rw and rw:gsub("%-%-[^\n]*", ""):find("opts%.row%.ornament"),
        "rowWidget ignores the plan's row-end ornament")
end)


-- ── seed refresh ───────────────────────────────────────────────────────────
-- The two seeds carry a "bookshelf:seed=N" marker. A seed file that exists
-- with an older (or no) marker is OURS and out of date, and is rewritten; one
-- at the current version is left byte for byte; a deleted one stays deleted;
-- nothing else in the folder is looked at. (Maintainer: the seeds blended
-- into the wallpaper, so the artwork gained outlines, and existing installs
-- have to receive them.)
t.test("seeds: an outdated seed file is rewritten, a current one is left alone", function()
    local O = fresh()
    local d = scratch()
    O._data_dir = d; O._lfs = lfs_shim
    O.ensureTemplate()
    local path = O.dir() .. "/template.svg"
    local f = io.open(path, "w"); f:write("<!-- bookshelf:overhang=0 -->\n<svg viewBox=\"0 0 60 100\"></svg>"); f:close()
    local O2 = fresh(); O2._data_dir = d; O2._lfs = lfs_shim
    O2.ensureTemplate()
    local now = io.open(path):read("a")
    eq(now, O2.TEMPLATE_SVG, "an unmarked (v1) seed must be refreshed to the shipped text")
    -- and a current one is not touched
    local before = lfs_shim.attributes(path, "modification")
    os.execute(string.format("touch -d @%d '%s'", before - 100, path))
    local O3 = fresh(); O3._data_dir = d; O3._lfs = lfs_shim
    O3.ensureTemplate()
    eq(lfs_shim.attributes(path, "modification"), before - 100, "a current seed was rewritten for nothing")
    os.execute("rm -rf '" .. d .. "'")
end)

t.test("seeds: the refresh never recreates a deleted seed or touches another file", function()
    local O = fresh()
    local d = scratch()
    O._data_dir = d; O._lfs = lfs_shim
    O.ensureTemplate()
    os.remove(O.dir() .. "/cactus.svg")
    local mine = O.dir() .. "/template-copy.svg"
    local f = io.open(mine, "w"); f:write("<!-- bookshelf:overhang=0 -->\n<svg viewBox=\"0 0 60 100\"></svg>"); f:close()
    local O2 = fresh(); O2._data_dir = d; O2._lfs = lfs_shim
    O2.ensureTemplate()
    assert(not exists(O2.dir() .. "/cactus.svg"), "a deleted seed came back")
    eq(io.open(mine):read("a"), "<!-- bookshelf:overhang=0 -->\n<svg viewBox=\"0 0 60 100\"></svg>",
        "a reader's own file was rewritten")
    os.execute("rm -rf '" .. d .. "'")
end)

t.test("seeds: both carry the current marker and an outline", function()
    local O = fresh()
    for _, seed in ipairs(O.SEED_FILES) do
        eq(O.seedVersionOf(seed.svg), O.SEED_VERSION, seed.name .. " does not carry the current seed marker")
        assert(seed.svg:find('stroke="#', 1, true), seed.name .. " has no outline")
        local aspect, over, night = O.parseHeader(seed.svg)
        assert(aspect and aspect > 0, seed.name .. " header no longer parses")
        eq(night, true, seed.name .. " lost its night=invert line")
    end
    eq(O.seedVersionOf("<svg/>"), 0, "no marker reads as version 0")
end)


t.test("seeds: the pot stands a little back from the plank's edge", function()
    -- Six empty units below the last shape in a 106-unit box, so the piece
    -- is set back beside the books rather than on the lip (maintainer).
    local O = fresh()
    for _, seed in ipairs(O.SEED_FILES) do
        assert(seed.svg:find('viewBox="0 0 60 106"', 1, true), seed.name .. " lost its room below")
        local aspect = O.parseHeader(seed.svg)
        assert(math.abs(aspect - 60 / 106) < 1e-6, seed.name .. " aspect does not follow the box")
        local lowest = 0
        for y in seed.svg:gmatch(" 97") do lowest = 97 end
        assert(lowest > 0 and lowest <= 100, seed.name .. " draws below the pot")
    end
end)

t.test("row-end ornaments alternate sides down a screen", function()
    local src = io.open("lib/bookshelf_spine_shelf.lua"):read("a")
    local body = src:match("\nfunction SpineShelf%.rowEndSide%(base, k%)\n.-\nend\n")
    assert(body, "rowEndSide not found")
    local SpineShelf = {}
    assert(load(body, "rowEndSide", "t", { SpineShelf = SpineShelf, tonumber = tonumber }))()
    eq(SpineShelf.rowEndSide("left", 1), "left")
    eq(SpineShelf.rowEndSide("left", 2), "right")
    eq(SpineShelf.rowEndSide("left", 3), "left")
    eq(SpineShelf.rowEndSide("right", 2), "left")
    eq(SpineShelf.rowEndSide(nil, 1), "right", "an unknown side reads as right, as pick does")
    -- and plan uses the FIRST row's side as the base for the rest
    local plan = src:match("\nfunction SpineShelf%.plan%(items, opts%)\n.-\nend\n"):gsub("%-%-[^\n]*", "")
    assert(plan:find("SpineShelf%.rowEndSide%(base, placed%)"),
        "plan does not alternate the pieces from the page's base side")
end)


-- ── Pages differ from their neighbours; Lots leaves the odd row to the books ─
t.test("the first row's side comes from the page's parity, so neighbouring pages mirror", function()
    -- Maintainer: with Lots, the pieces stayed put while the spines changed,
    -- "it ruins the effect of looking at a different shelf". The first row's
    -- side used to hash the page's first book, so neighbours matched half the
    -- time. Odd pages start one side, even pages the other; a page still
    -- composes the same way every time it is shown.
    local src = io.open("lib/bookshelf_spine_shelf.lua"):read("a")
    local body = src:match("\nfunction SpineShelf%.rowEndBase%(page_index%)\n.-\nend\n")
    assert(body, "rowEndBase not found")
    local SpineShelf = {}
    assert(load(body, "rowEndBase", "t", { SpineShelf = SpineShelf, tonumber = tonumber }))()
    eq(SpineShelf.rowEndBase(1), "right")
    eq(SpineShelf.rowEndBase(2), "left")
    eq(SpineShelf.rowEndBase(3), "right")
    eq(SpineShelf.rowEndBase("2"), "left", "a page number as a string still counts")
    eq(SpineShelf.rowEndBase(nil), "right", "no page (the pagination plan) reads as the first")
    assert(SpineShelf.rowEndBase(7) ~= SpineShelf.rowEndBase(8), "neighbours must differ")
    local plan = src:match("\nfunction SpineShelf%.plan%(items, opts%)\n(.-)\nfunction SpineShelf%.")
    assert(plan, "plan not found")
    assert(plan:find("SpineShelf.rowEndBase(opts.page_index)", 1, true),
        "plan does not take the base side from the page's parity")
    assert(not plan:find("row_orn[1] and row_orn[1].side or pl.side", 1, true),
        "plan still hashes the first row's side")
end)

t.test("rows that get a piece alternate by PIECE, so a bookless row does not pair two on one side", function()
    local src = io.open("lib/bookshelf_spine_shelf.lua"):read("a")
    local plan = src:match("\nfunction SpineShelf%.plan%(items, opts%)\n(.-)\nfunction SpineShelf%.")
    assert(plan:find("SpineShelf.rowEndSide(base, placed)", 1, true),
        "the side must alternate over the pieces placed, not the row index")
end)

t.test("a reserved row end is usually, not always, taken: Lots leaves about one row in six to the books", function()
    -- Maintainer: "allow some rows even on 'lots' setting to be occasionally
    -- filled with books". pick() scales its odds by the frequency level, so
    -- one constant gives Often about half its row ends and Lots most of them.
    local src = io.open("lib/bookshelf_spine_shelf.lua"):read("a")
    local plan = src:match("\nfunction SpineShelf%.plan%(items, opts%)\n(.-)\nfunction SpineShelf%.")
    assert(plan:find("chance    = Orn.ROW_END_CHANCE", 1, true), "the row-end pick still uses chance 1")
    package.loaded["lib/bookshelf_settings_store"] = {
        read = function(k) if k == "ornament_frequency" then return 3 end end,
    }
    local O = fresh()
    assert(type(O.ROW_END_CHANCE) == "number", "no ROW_END_CHANCE constant")
    assert(O.ROW_END_CHANCE * 3 < 1, "at Lots every row end is still taken")
    assert(O.ROW_END_CHANCE * 3 >= 0.75, "at Lots too many row ends go to the books")
    assert(O.ROW_END_CHANCE * 2 >= 0.5, "at Often fewer than half the row ends are taken")
    local pool = { { name = "a", aspect = 0.6, overhang = 0 }, { name = "b", aspect = 0.6, overhang = 0 } }
    local none = 0
    for page = 1, 100 do
        O.beginScreen()
        for r = 1, 3 do
            local pl = O.pick("/lib/book" .. page .. ".epub|rowend|" .. r, 400, 100, pool,
                { min_gap = 0, min_h = 1, chance = O.ROW_END_CHANCE })
            if not pl then none = none + 1 end
        end
    end
    assert(none >= 15 and none <= 75, "expected roughly 1 in 6 of 300 row ends bookless at Lots, got " .. none)
    package.loaded["lib/bookshelf_settings_store"] = nil
end)

t.test("the page plan tells plan() which page it is", function()
    local src = io.open("lib/bookshelf_widget.lua"):read("a")
    assert(src:find("page_index = self.page,", 1, true), "the page plan does not pass page_index")
end)

t.done()
