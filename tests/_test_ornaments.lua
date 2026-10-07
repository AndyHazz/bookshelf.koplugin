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
            local m = sh(dofile("tests/_helpers.lua").statCmd("mtime", q))
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

t.test("the overhang never reaches past the plank's front", function()
    local O = fresh()
    -- 25% overhang on a 240px ornament would be 60px; only 20px allowed.
    local p = O.place(POOL[2], 1000, 300, { max_below = 20 }, 1)
    assert(p, "expected a placement")
    eq(p.below, 20)
    eq(p.h, 80, "shrunk so 25% of it is the allowed overhang")
    eq(p.above + p.below, p.h)
end)

t.test("ensureTemplate creates the folder with the template, once", function()
    local O = fresh()
    local d = scratch()
    O._data_dir = d
    O._lfs = lfs_shim
    O.ensureTemplate()
    assert(exists(O.dir() .. "/template.svg"), "template should be written")
    assert(exists(O.dir() .. "/cactus.svg"), "cactus should be written")
    -- The folder lives beside the wallpapers (v5.3), not in icons/.
    eq(O.dir(), d .. "/settings/bookshelf/ornaments")
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

t.test("an icons folder a reader already has is left alone", function()
    -- The ornaments moved out of icons/ (v5.3): a reader's own icons folder
    -- is neither touched nor given an ornaments folder.
    local O = fresh()
    local d = scratch()
    O._data_dir = d
    O._lfs = lfs_shim
    assert(os.execute("mkdir -p '" .. d .. "/icons'"))
    local mine = io.open(d .. "/icons/my-own-icon.svg", "w")
    mine:write("<svg/>"); mine:close()
    O.ensureTemplate()
    assert(exists(O.dir() .. "/template.svg"), "the ornaments folder was not seeded")
    assert(exists(d .. "/icons/my-own-icon.svg"), "a reader's own icon was disturbed")
    assert(lfs_shim.attributes(d .. "/icons/bookshelf.ornaments", "mode") == nil,
        "an ornaments folder was made in icons/")
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
    os.execute(dofile("tests/_helpers.lua").touchAtCmd(mt, "'" .. O.dir() .. "'") .. " 2>/dev/null")
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
    os.execute(dofile("tests/_helpers.lua").touchAtCmd(mt, "'" .. O.dir() .. "'") .. " 2>/dev/null")
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
    eq(over, 0, "a raster with no directives stands on the plank")
    eq(invert, false, "no night directive, no night flag")
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

-- A tEXt chunk: length, "tEXt", keyword NUL text, crc (not checked, zeros).
local function png_text(keyword, text)
    local data = keyword .. "\0" .. text
    return be32(#data) .. "tEXt" .. data .. be32(0)
end
local function png_idat() return be32(4) .. "IDAT" .. "xxxx" .. be32(0) end

t.test("png: bookshelf tEXt directives -- overhang in pixels, night", function()
    local O = fresh()
    -- IHDR's own crc sits before the first tEXt in a real file.
    local base = png_header(100, 200) .. be32(0)
    local _a
    local a, over, night, extra = O.parsePngHeader(base .. png_text("bookshelf", "overhang=20") .. png_idat())
    eq(a, 0.5); eq(over, 0.1, "20px of a 200px image"); eq(night, false)
    eq(extra, nil, "a fourth value (the old hang) is still returned")
    a, over, night = O.parsePngHeader(base .. png_text("bookshelf", "overhang=10")
        .. png_text("bookshelf", "night=invert") .. png_idat())
    eq(over, 0.05); eq(night, true, "separate chunks each count")
    _a, over, night = O.parsePngHeader(base .. png_text("bookshelf", "overhang=10; night=invert") .. png_idat())
    eq(over, 0.05); eq(night, true, "several directives in one chunk")
    -- Other tools' text is not ours, and nothing after the image data is read.
    _a, over = O.parsePngHeader(base .. png_text("Software", "overhang=50")
        .. png_idat() .. png_text("bookshelf", "overhang=30"))
    eq(over, 0)
    -- A chunk cut off by the read limit is ignored rather than half-read.
    local cut = base .. png_text("bookshelf", "overhang=40")
    _a, over = O.parsePngHeader(cut:sub(1, #cut - 6))
    eq(over, 0)
    -- Overhang can never exceed the picture.
    _a, over = O.parsePngHeader(base .. png_text("bookshelf", "overhang=999") .. png_idat())
    eq(over, 1)
end)

t.test("svg: a bookshelf:hang line is not a directive any more", function()
    -- Hanging is a height of 100% now, set in the long-press menu.
    local O = fresh()
    local a, o, n, extra = O.parseHeader('<svg viewBox="0 0 1 2"><!-- bookshelf:hang -->')
    eq(a, 0.5); eq(o, 0); eq(n, false); eq(extra, nil)
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

t.test("png: a picture too big to decode is left out, not handed to the decoder", function()
    -- Issue 471: opening the ornaments browser killed KOReader. A ~19.5 MP
    -- PNG asked MuPDF for a 78 MB pixmap (it decodes at full size before
    -- scaling) and the malloc failed. The IHDR size is read anyway, so the
    -- file is refused before anything decodes it.
    local O = fresh()
    local d = scratch()
    O._data_dir = d
    O._lfs = lfs_shim
    O.ensureTemplate()
    local rendered = 0
    O._render = function() rendered = rendered + 1 end
    local f = io.open(O.dir() .. "/huge.png", "wb")
    f:write(png_header(4416, 4416)); f:close()
    f = io.open(O.dir() .. "/fine.png", "wb")
    f:write(png_header(2000, 2000)); f:close()
    local names = {}
    for _i, e in ipairs(O.list()) do names[#names + 1] = e.name end
    eq(table.concat(names, ","), "cactus.svg,fine.png,template.svg")
    eq(rendered, 0, "the huge picture was decoded")
    eq(O.pngSize(png_header(4416, 4416)), 4416)
    assert(4416 * 4416 > O.MAX_PNG_PX and 2000 * 2000 <= O.MAX_PNG_PX, "the cap is not between the two")
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

-- Which slots and which piece: tests/_test_ornament_deck.lua.

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

-- The frequency is a PER-SHELF pin now, pushed in by the widget, so that is
-- how a test sets it: there is no library-wide setting left to stub.
local function withFreq(v, fn)
    local W = fresh()
    W.setChipFrequency(v)
    local ok, err = pcall(fn, W)
    package.loaded["lib/bookshelf_settings_store"] = nil
    if not ok then error(err, 0) end
end

t.test("the reservation is taken off BOTH packers", function()
    -- fillRows decides which books are on the page; balanceRows re-breaks the
    -- same books across the same rows. Give one the full width and it packs a
    -- book into the strip the other stands an ornament in. Both are handed
    -- the deck hooks' per-row width (a row with a piece at its end gives up
    -- that piece's width, no other row gives up anything).
    local src = io.open("lib/bookshelf_spine_shelf.lua"):read("a")
    assert(src:find("SpineLayout.fillRows(widths, hk.avail", 1, true),
        "fillRows does not pack into the per-row width")
    assert(src:find("SpineLayout.balanceRows(widths, hk and hk.avail or content_w_books", 1, true),
        "balanceRows does not balance into the per-row width")
end)

t.test("there is ONE row-end ornament painter, and it knows rows are centred", function()
    -- Books stand CENTRED, so the row's leftover is split between both ends
    -- (`lead`): the row-end piece stands beside lead + content_w on its side.
    -- A painter that assumes the leftover is all at the right edge stands its
    -- ornament on the last book. It paints the plan's piece; it picks none.
    local src = io.open("lib/bookshelf_spine_shelf.lua"):read("a")
    local body = src:match("function SpineShelf%.rowWidget.-\nend\n")
    assert(body, "rowWidget could not be located")
    eq(select(2, body:gsub("Orn%.pick", "")), 0, "rowWidget picks pieces again")
    assert(body:find("x = lead + content_w + SpineShelf.ornPad(pad, pl)", 1, true),
        "the row-end ornament no longer accounts for the centring lead")
end)

t.test("a reserved row end is decided per row, in the plan, at the piece's own width", function()
    -- The plan deals each shelf's end piece (when its turn comes round) and
    -- reserves exactly that width; rows without a piece keep the whole shelf
    -- (maintainer).
    local src = io.open("lib/bookshelf_spine_shelf.lua"):read("a")
    local plan = src:match("\nfunction SpineShelf%.plan%(items, opts%)\n.-\nend\n")
    assert(plan, "plan not found")
    local code = plan:gsub("%-%-[^\n]*", "")
    assert(not code:find("content_w_books = content_w_books %- orn%.row_end"),
        "plan still takes the nominal square off every row")
    assert(code:find("SpineLayout.fillRows(widths, hk.avail", 1, true),
        "plan does not hand fillRows a per-row width")
    assert(code:find("rows[r].ornament = hk.row_orn[r]", 1, true), "plan does not tell the row which piece stands on it")
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
    os.execute(dofile("tests/_helpers.lua").touchAtCmd(before - 100, "'" .. path .. "'") .. " 2>/dev/null")
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

t.test("seeds: both carry the current marker and an outline, and display as drawn in night mode", function()
    local O = fresh()
    for _, seed in ipairs(O.SEED_FILES) do
        eq(O.seedVersionOf(seed.svg), O.SEED_VERSION, seed.name .. " does not carry the current seed marker")
        assert(seed.svg:find('stroke="#', 1, true), seed.name .. " has no outline")
        local aspect, over, night = O.parseHeader(seed.svg)
        assert(aspect and aspect > 0, seed.name .. " header no longer parses")
        -- The pot and plant keep their tones on the black night shelf like
        -- the rest of the shelf (maintainer, 2026-09-16); a night line would
        -- turn them chalk on grey panels. The template's doc comment still
        -- describes the option, so this also guards against the literal
        -- token creeping into that prose, which the header parser would read.
        eq(night, false, seed.name .. " asks to be inverted in night mode")
    end
    assert(O.SEED_VERSION >= 4, "the night line left the seeds at version 4; installs at 3 must be rewritten")
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

-- ── Pages differ from their neighbours; Lots leaves the odd row to the books ─
t.test("the page plan tells plan() which page it is", function()
    local src = io.open("lib/bookshelf_widget.lua"):read("a")
    -- Set on the options the render builds from _spinePlanBase, since the
    -- options both passes share moved there.
    assert(src:find("opts.page_index = self.page", 1, true), "the page plan does not pass page_index")
end)


-- A bitmap stand-in with the one accessor unpremultiply uses.
local function fake_bb(pixels)
    local rows = {}
    for y, row in ipairs(pixels) do
        rows[y - 1] = {}
        for x, px in ipairs(row) do rows[y - 1][x - 1] = { r = px[1], g = px[2], b = px[3], alpha = px[4] } end
    end
    return { getWidth = function() return #pixels[1] end, getHeight = function() return #pixels end,
             getPixelP = function(_, x, y) return rows[y][x] end, rows = rows }
end

t.test("unpremultiply: straight alpha from MuPDF's premultiplied decode", function()
    local O = fresh()
    local bb = fake_bb({ { { 128, 64, 0, 128 }, { 255, 255, 255, 255 }, { 0, 0, 0, 0 }, { 5, 5, 5, 5 } } })
    O.unpremultiply(bb)
    local p = bb.rows[0]
    eq(p[0].r, 255); eq(p[0].g, 128); eq(p[0].b, 0); eq(p[0].alpha, 128, "half white at half alpha is white")
    eq(p[1].r, 255, "opaque pixels untouched"); eq(p[2].r, 0, "clear pixels untouched")
    eq(p[3].r, 255, "a faint white edge is still white, not grey")
end)

t.test("PNG ornaments are unpremultiplied after decoding (not SVGs NanoSVG already gives straight)", function()
    local src = io.open("lib/bookshelf_ornaments.lua"):read("*a")
    local dr = src:match("local function defaultRender%(.-\nend\n")
    assert(dr and dr:find("unpremultiply(", 1, true), "decoded PNGs are blended premultiplied as straight alpha")
    assert(dr:find("is_straight", 1, true), "an SVG MuPDF rendered is premultiplied too")
end)

t.test("shuffle is a KOReader action the shelf answers", function()
    local main = io.open("main.lua"):read("*a")
    assert(main:find('registerAction("bookshelf_shuffle_ornaments"', 1, true), "no action registered")
    assert(main:find('event    = "BookshelfShuffleOrnaments"', 1, true), "the action sends no event")
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    local h = w:match("function BookshelfWidget:onBookshelfShuffleOrnaments%(%)(.-)\nend\n")
    assert(h and h:find('require("lib/bookshelf_ornament_deck").shuffle(self.chip)', 1, true), "the shelf does not shuffle its own deck")
    assert(h:find("self:_dropOrnPages(false)", 1, true), "the page map and page states survive a shuffle")
    assert(h:find("_rebuild()", 1, true), "the shelf is not rebuilt")
end)

t.test("the default width cap grows with the books, never past the row", function()
    -- "When your shelf size grows, we should also grow the ornaments in line
    -- with the books" (maintainer): a quarter of the row stayed the same
    -- width while taller rows made the books bigger around it.
    local O = fresh()
    eq(O.maxWidth(280, 1135), 280, "PW5, two rows: one stand height, as the quarter row was (284)")
    eq(O.maxWidth(560, 1135), 560, "twice the books, twice the room")
    eq(O.maxWidth(900, 800), 800, "never wider than the row itself")
    eq(O.maxWidth(0, 1135), 0)
end)

t.test("json: tap takes \"zoom\" as well as a stored action; info is text", function()
    -- The zoom tap shows a piece full screen with its info under it; a pack
    -- sets it for all its pieces (the Japan pack's prints).
    local O = fresh()
    local z = O.cleanField("tap", "zoom")
    assert(type(z) == "table" and z.zoom == true, "\"zoom\" is not a tap action")
    eq(O.cleanField("tap", "wobble"), nil, "an unknown word passes as a tap action")
    local a = O.cleanField("tap", { action = "x", label = "X" })
    eq(a and a.action, "x", "a stored action no longer passes")
    eq(O.cleanField("info", "A print by Hokusai."), "A print by Hokusai.")
    eq(O.cleanField("info", 12), nil, "a number passes as info")
    eq(#O.cleanField("info", string.rep("a", 20000)), O.INFO_MAX, "info is not capped")
end)

t.test("json: a piece's info and zoom tap reach the entry", function()
    local O = fresh()
    local e = { name = "Pack/p.png" }
    O._applyLayers(e, { { ["Pack/p.png"] = { tap = "zoom", info = "Notes" } } })
    assert(e.tap and e.tap.zoom, "the zoom tap did not reach the entry")
    eq(e.info, "Notes")
end)

t.test("json: scale sizes the piece and its cap together, up to the whole row", function()
    local O = fresh()
    local wide = { name = "w.svg", aspect = 3, overhang = 0, scale = 2 }
    -- stand 280: natural 224 tall; x2 = 448 tall, 1344 wide; cap 280 x2 = 560.
    eq(O.place(wide, 280, 280, { max_room = 1135 }, 1).w, 560, "the cap grows with the scale")
    eq(O.place({ name = "w2.svg", aspect = 3, overhang = 0, scale = 4 }, 280, 280, { max_room = 1000 }, 1).w,
       1000, "never past the whole row")
    eq(O.place({ name = "s.svg", aspect = 1, overhang = 0, scale = 0.5 }, 280, 280, { max_room = 1135 }, 1).h,
       112, "half of 224")
end)

t.test("json: padding reaches the placement in px", function()
    local O = fresh()
    local p = O.place({ name = "p.svg", aspect = 1, overhang = 0, pad = -0.05 }, 400, 300, {}, 1)
    eq(p.pad_px, -15, "5% of a 300px stand, tighter")
end)

t.test("json: mirror always flips every deal; alternate every other one", function()
    local O = fresh()
    local al = { name = "al.svg", aspect = 1, overhang = 0, mirror = "always" }
    for i = 1, 3 do assert(O.place(al, 1000, 300, {}, i).mirror, "always, deal " .. i) end
    local alt = { name = "alt.svg", aspect = 1, overhang = 0, mirror = "alternate" }
    local got = {}
    for i = 1, 4 do got[i] = tostring(O.place(alt, 1000, 300, {}, i).mirror) end
    eq(table.concat(got, ","), "false,true,false,true")
end)

t.test("json: the shelf honours padding everywhere it reserves or paints the gap", function()
    local sh = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")
    local n = select(2, sh:gsub("SpineShelf%.ornPad%(", ""))
    assert(n >= 4, "padding is applied in only " .. n .. " places (section gap, row-end reserve, both row-end sides)")
    assert(sh:find("return stand_h - pl.above - off", 1, true), "a piece does not stand on the plank")
    -- Two ceilings (row end and bare plank; section gap), and a third
    -- assignment that only ever LOWERS it: the deck's squeeze, for a one-row
    -- page whose book has to fit beside its end piece.
    eq(select(2, sh:gsub("o%.max_room = ", "")), 3, "every slot gives its whole-row ceiling (row end and bare plank; section gap), and the squeeze caps it")
    assert(sh:find("o.max_room = math.min(o.max_room, cap)", 1, true), "the squeeze cap no longer only lowers the ceiling")
end)

t.test("menu fix: a height nudge moves a piece, it never changes its size", function()
    -- Device report: "Height changes the size instead of lifting the ornament".
    -- Height is placed by the shelf (SpineShelf.ornamentY); the placement
    -- only carries it, with the size and the file's own overhang unchanged.
    local O = fresh()
    local function at(lift)
        return O.place({ name = "pot.png", aspect = 1, overhang = 0.05, lift = lift }, 1000, 300, { max_below = 20 }, 1)
    end
    local a, b, c = at(-0.25), at(0), at(0.6)
    eq(a.h, b.h, "lowering changed the size"); eq(b.h, c.h, "raising changed the size")
    eq(a.below, b.below, "lowering changed the file's overhang"); eq(c.below, b.below)
    eq(a.offset, -0.25); eq(c.offset, 0.6); eq(a.anchor, "bottom")
end)

t.test("a hanging piece keeps its pack size but never outgrows the gap it hangs in", function()
    -- Maintainer: hanging art hangs on the wall and never overlaps the shelf
    -- above or the plank below. The plan hands the clear gap in as
    -- o.hang_room; a piece that fits keeps the size its pack gave it.
    local O = fresh()
    local top = { name = "s.svg", aspect = 0.5, overhang = 0, anchor = "top" }
    local books = math.floor(300 * O.HEIGHT_FRAC)
    eq(O.place(top, 1000, 300, { hang_room = 400 }, 1).h, books, "a piece that fits was resized")
    eq(O.place(top, 1000, 300, { hang_room = 200 }, 1).h, 200, "a piece taller than the gap was not shrunk to it")
    top.scale = 1.32
    eq(O.place(top, 1000, 300, { hang_room = 200 }, 1).h, 200, "the pack's scale took it past the gap")
    top.lift = -0.1
    eq(O.place(top, 1000, 300, { hang_room = 200 }, 1).h, 170, "lowering it did not leave it room to the plank")
    top.scale, top.lift = 0.5, 0
    eq(O.place(top, 1000, 300, {}, 1).h, math.floor(300 * O.HEIGHT_FRAC * 0.5), "no gap given: the books' size")
    local stand = { name = "b.svg", aspect = 0.5, overhang = 0 }
    eq(O.place(stand, 1000, 300, { hang_room = 100 }, 1).h, books, "a standing piece was held to the gap")
end)

t.test("menu fix: a mirror change reaches a piece already dealt", function()
    -- Device report: "Mirror option does nothing".
    local O = fresh()
    local e = { name = "m.svg", aspect = 1, overhang = 0, mirror = "off" }
    eq(O.place(e, 1000, 300, {}, 1).mirror, false)
    e.mirror = "always"
    eq(O.place(e, 1000, 300, {}, 1).mirror, true, "the slot kept its old flip")
    e.mirror = "alternate"
    eq(O.place(e, 1000, 300, {}, 1).mirror, false, "first deal of the piece: unflipped")
end)

t.test("place: always a placement; a too-wide piece is scaled to the cap, never refused", function()
    local O = fresh()
    local wide = { name = "w.svg", aspect = 5, overhang = 0 }
    local pl = O.place(wide, 100, 400, {}, 1)
    assert(pl, "a piece was refused")
    eq(pl.w, 100)
    local tiny = O.place({ name = "t.svg", aspect = 0.01, overhang = 0 }, 100, 10, {}, 1)
    assert(tiny and tiny.w >= 1 and tiny.h >= 1, "a tiny piece was refused")
end)

t.test("the odds, budgets and deck are gone from the module", function()
    local src = io.open("lib/bookshelf_ornaments.lua"):read("*a")
    for _i, name in ipairs({ "M.pick", "PASS_LIMIT", "PAGE_PERIOD", "pageGuaranteed",
            "reservesRowEnds", "ROW_END_CHANCE", "GROUP_CHANCE", "budgetLeft", "_dealt" }) do
        assert(not src:find(name, 1, true), name .. " is still in the module")
    end
end)

t.test("hang is the top anchor: no directive, no hang field", function()
    local O = fresh()
    assert(O.FIELDS.hang == nil, "hang is still a field")
    eq(O.FIELDS.lift.default, 0, "height does not default to the anchor")
    eq(O.FIELDS.anchor.default, "bottom", "a piece does not stand by default")
    local src = io.open("lib/bookshelf_ornaments.lua"):read("*a")
    assert(not src:find("bookshelf:hang", 1, true), "the hang directive is still read")
    local e = { name = "bat.png", path = "/o/bat.png", aspect = 1, overhang = 0, lift = 0, anchor = "top" }
    local pl = O.place(e, 1000, 400, {}, 1)
    eq(pl.anchor, "top"); eq(pl.offset, 0); eq(pl.below, 0)
    -- Every shelf hangs a top-anchored piece now (a page's first row from
    -- the top panel), so nothing tells one to stand instead.
    local st = O.place(e, 1000, 400, { stand = true }, 1)
    eq(st.anchor, "top", "a top-anchored piece was stood on the plank")
    eq(pl.hang, nil, "placements still carry hang")
end)

t.test("the menu has the anchor between mirror and tap, and switching it starts from the anchor", function()
    local src = io.open("lib/bookshelf_ornament_menu.lua"):read("*a")
    local m = src:find('MIRROR_LABEL[entry.mirror or "off"]', 1, true)
    local a = src:find('_("Anchor: top")', 1, true)
    local tp = src:find('_("Tap: none")', 1, true)
    assert(m and a and tp and m < a and a < tp, "the anchor button is not between Mirror and Tap")
    assert(src:find('setAnchor(entry.anchor == "top" and "bottom" or "top")', 1, true), "the button does not switch the anchor")
    local sa = src:match("local function setAnchor%(v%)(.-)\n    end\n")
    -- Explicit values, not cleared ones: clearing would fall back to what the
    -- pack's own file says, so a pack's top piece could never be stood.
    assert(sa and sa:find('Orn.readerSet(entry, "anchor", v)', 1, true), "the anchor is not stored")
    assert(sa:find('Orn.readerSet(entry, "lift", 0)', 1, true), "the height offset is kept across a switch of anchor")
end)

t.test("a row-end piece's negative padding: flush at the shelf end, tucked behind the books", function()
    -- Device report (Death's-head Moth, padding -20% at a row end): "padding
    -- did the job on the right, but lots of space left on the left, and the
    -- book on the far end of the shelf is being pushed off". The plan gave the
    -- piece w + 2p (p < 0: less than its width, so more books), the row drew it
    -- with w + one positive pad, and pushed it inwards by p. One rule for both:
    -- the shelf-end side cannot go below zero, the books' side takes p.
    local src = io.open("lib/bookshelf_spine_shelf.lua"):read("a")
    local pad = src:match("(function SpineShelf%.ornPad%(base, pl%).-\nend\n)")
    local room = src:match("(function SpineShelf%.rowEndRoom%(base, pl%).-\nend\n)")
    assert(room, "no SpineShelf.rowEndRoom")
    local SS = {}
    assert(load("local SpineShelf = ...\n" .. pad .. room))(SS)
    eq(SS.rowEndRoom(10, { w = 100, pad_px = 0 }), 120, "no padding: a pad each side, as before")
    eq(SS.rowEndRoom(10, { w = 100, pad_px = 20 }), 160)
    eq(SS.rowEndRoom(10, { w = 100, pad_px = -30 }), 80, "negative: nothing at the shelf end, -20 into the books")
    local plan_space = src:match("local function space%(kind, pl%)(.-)\n    end\n")
    assert(plan_space and plan_space:find('kind == "rowend"', 1, true)
           and plan_space:find("SpineShelf.rowEndRoom(", 1, true), "the plan reserves a row end some other way")
    local body = src:match("function SpineShelf%.rowWidget.-\nend\n")
    assert(body:find("local reserve = SpineShelf.rowEndRoom(pad_o, rowo)", 1, true),
        "the row reserves a different room from the one the plan gave")
end)

t.test("the menu shows and nudges the reader's own adjustment, not the pack's value", function()
    local src = io.open("lib/bookshelf_ornament_menu.lua"):read("*a")
    local nud = src:match("function M%.nudged%(entry, field, delta%)(.-)\nend\n")
    assert(nud and nud:find("readerValue(entry, field)", 1, true), "a nudge starts from the pack's value")
    assert(src:find('readerValue(entry, "scale")', 1, true) and src:find('readerValue(entry, "pad")', 1, true)
           and src:find('readerValue(entry, "lift")', 1, true), "the labels show the pack's values")
end)

t.test("listFor: a theme deals its own pieces only, minus switched-off pieces; Plain none; mine the collection", function()
    local Orn = fresh()
    local mem = {}
    Orn._store = { read = function(k) return mem[k] end, save = function(k, v) mem[k] = v end,
                   generation = function() return 0 end, flush = function() end }
    local all = { { name = "H/bat.png", pack = "H" }, { name = "H/cat.png", pack = "H" },
                  { name = "G/frame.png", pack = "G" }, { name = "pot.svg" } }
    Orn.listAll = function() return all, { "G", "H" } end
    Orn.setOff("H/cat.png", true)
    Orn.setPackOff("H", true)                    -- off in the collection, worn as a theme
    local names = {}
    for i, e in ipairs(Orn.listFor("H")) do names[i] = e.name end
    -- No loose pot: themes do not mix (maintainer, 2026-10-07).
    eq(table.concat(names, ","), "H/bat.png")
    assert(Orn.listFor("H") == Orn.listFor("H"), "listFor handed out a new table")
    eq(#Orn.listFor("plain"), 0, "Plain deals nothing")
    assert(Orn.listFor(nil) == Orn.list() and Orn.listFor("mine") == Orn.list(), "the reader's pool changed")
    names = {}
    for i, e in ipairs(Orn.list()) do names[i] = e.name end
    eq(table.concat(names, ","), "G/frame.png,pot.svg", "the reader's own: collection switches, loose pieces")
end)

t.test("a piece takes gestures only on its drawing, and never in the footer (start-menu taps)", function()
    local O = fresh()
    O.contentBox = function() return 0.25, 0.5, 0.75, 1.0 end   -- drawing: middle half, lower half
    local p = { entry = { name = "c.png" }, w = 100, h = 200 }
    local dim = { x = 10, y = 400, w = 100, h = 200 }
    eq(O.hits(p, dim, { x = 60, y = 550 }), true, "a tap on the drawing missed")
    eq(O.hits(p, dim, { x = 15, y = 550 }), false, "the transparent margin took the tap")
    eq(O.hits(p, dim, { x = 60, y = 420 }), false, "the empty top took the tap")
    local blocked = function(pos) return pos.y >= 580 end
    eq(O.hits(p, dim, { x = 60, y = 590 }, blocked), false, "a tap in the footer band went to the piece")
    p.mirror = true
    O.contentBox = function() return 0.0, 0.0, 0.3, 1.0 end     -- drawing on the left, mirrored to the right
    eq(O.hits(p, dim, { x = 100, y = 500 }), true, "mirroring was ignored")
    eq(O.hits(p, dim, { x = 15, y = 500 }), false)
    eq(O.hits(p, dim, nil), true, "no position: keep the old behaviour")
    local src = io.open("lib/bookshelf_ornaments.lua"):read("*a")
    for _i, ev in ipairs({ "HoldOrnament", "TapOrnament" }) do
        local body = src:match("function M%.Ornament:on" .. ev .. "%(.-\nend")
        assert(body and body:find("M.hits(self.placement, self.dimen, ges and ges.pos, M.handlers.blocked)", 1, true),
            ev .. " still takes gestures on the piece's whole box")
    end
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    assert(w:find("pos.y >= shelf.height - _footerReserveH()", 1, true), "the shelf does not block the footer band")
end)

t.done()
