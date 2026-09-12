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
    return dofile("lib/bookshelf_ornaments.lua")
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
        eq(a, 0.6, seed.name); eq(over, 0, seed.name)
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

t.done()
