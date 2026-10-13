-- tests/_test_ornament_packs.lua
-- Ornament packs (subfolders), switching ornaments and packs off, deleting.
--
-- Usage (from plugin root): lua tests/_test_ornament_packs.lua
--
-- Maintainer: "support ornament packs, maybe sub folders of the bookshelf
-- ornaments folder, that lets you enable and disable a whole set of
-- ornaments at a time", browsed and managed from a modal.

package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["logger"] = { dbg = function() end, info = function() end,
                              warn = function() end, err = function() end }
package.loaded["ui/widget/widget"] = { extend = function(_, t) return t end }
package.loaded["ui/geometry"] = { new = function(_, t) return t end }
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

local mem = {}
local function fresh()
    package.loaded["lib/bookshelf_ornaments"] = nil
    local O = dofile("lib/bookshelf_ornaments.lua")
    O.SCAN_TTL = 0
    mem = {}
    O._store = { read = function(k) return mem[k] end, save = function(k, v) mem[k] = v end }
    return O
end
local tmp = os.getenv("TMPDIR") or "/tmp"
local function scratch()
    local d = string.format("%s/bookshelf_orn_packs_%d_%d", tmp, os.time(), math.random(1e6))
    os.execute("rm -rf '" .. d .. "' && mkdir -p '" .. d .. "'")
    return d
end
local function svg(path)
    local f = assert(io.open(path, "w")); f:write('<svg viewBox="0 0 10 10"></svg>'); f:close()
end
local function names(list)
    local out = {}
    for i, e in ipairs(list) do out[i] = e.name end
    return table.concat(out, ",")
end
local function setup()
    local O = fresh()
    local d = scratch()
    O._data_dir = d; O._lfs = lfs_shim
    O.ensureTemplate()                       -- template.svg + cactus.svg, loose
    os.execute("mkdir -p '" .. O.dir() .. "/Autumn' '" .. O.dir() .. "/Cats'")
    svg(O.dir() .. "/Autumn/leaf.svg"); svg(O.dir() .. "/Autumn/acorn.svg")
    svg(O.dir() .. "/Cats/leaf.svg")          -- same file name, other pack
    return O, d
end

t.test("a subfolder is a pack; its ornaments join the pool by relative path", function()
    local O, d = setup()
    local all, packs = O.listAll()
    eq(table.concat(packs, ","), "Autumn,Cats")
    eq(names(O.list()), "Autumn/acorn.svg,Autumn/leaf.svg,Cats/leaf.svg,cactus.svg,template.svg")
    local by = {}
    for _i, e in ipairs(all) do by[e.name] = e end
    eq(by["Autumn/leaf.svg"].pack, "Autumn"); eq(by["Autumn/leaf.svg"].file, "leaf.svg")
    eq(by["cactus.svg"].pack, nil, "a loose ornament belongs to no pack")
    os.execute("rm -rf '" .. d .. "'")
end)

t.test("an ornament switched off leaves the pool but not the browser", function()
    local O, d = setup()
    O.setOff("cactus.svg", true)
    assert(O.isOff("cactus.svg"))
    assert(not names(O.list()):find("cactus", 1, true), "a switched-off ornament was still placed")
    eq(#O.listAll(), 5, "the browser still lists it")
    O.setOff("cactus.svg", false)
    assert(names(O.list()):find("cactus", 1, true))
    eq(mem[O.OFF_KEY], nil, "an empty set is not stored")
    os.execute("rm -rf '" .. d .. "'")
end)

t.test("a pack switched off takes all its ornaments with it, and only its own", function()
    local O, d = setup()
    O.setPackOff("Autumn", true)
    eq(names(O.list()), "Cats/leaf.svg,cactus.svg,template.svg",
       "Cats/leaf.svg shares a file name and must stay")
    O.setPackOff("Autumn", false)
    eq(#O.list(), 5)
    os.execute("rm -rf '" .. d .. "'")
end)

t.test("delete removes the file and forgets its state", function()
    local O, d = setup()
    local victim
    for _i, e in ipairs(O.listAll()) do if e.name == "Autumn/acorn.svg" then victim = e end end
    O.setOff(victim.name, true)
    assert(O.delete(victim))
    local f = io.open(victim.path, "r"); assert(not f, "the file is still there")
    eq(mem[O.OFF_KEY], nil)
    eq(names(O.list()), "Autumn/leaf.svg,Cats/leaf.svg,cactus.svg,template.svg")
    os.execute("rm -rf '" .. d .. "'")
end)

t.test("the filtered list is the same table while nothing changes", function()
    local O, d = setup()
    local a = O.list()
    assert(O.list() == a)
    O.setOff("template.svg", true)
    assert(O.list() ~= a, "a change was served from the cache")
    os.execute("rm -rf '" .. d .. "'")
end)

t.test("the browser names an ornament without its extension", function()
    local O, d = setup()
    eq(O.displayName({ file = "Sleeping Cat.png" }), "Sleeping Cat")
    eq(O.displayName({ file = "Owl.invert.png" }), "Owl")
    eq(O.displayName({ file = "cactus.SVG" }), "cactus")
    eq(O.displayName({ file = "notes.txt" }), "notes.txt")
    os.execute("rm -rf '" .. d .. "'")
end)

-- The browser previews the picture, not the file: an ornament's transparent
-- room is there for the shelf, and wasted in a grid card (maintainer: "the
-- PNGs look like they could fill the grid a little better").
t.test("contentBox finds the opaque part of an ornament", function()
    local O, d = setup()
    local freed = 0
    O._render = function(_path, w, h)
        return {
            getWidth = function() return w end, getHeight = function() return h end,
            -- opaque only in the bottom half, middle half across
            getPixel = function(_, x, y)
                return { alpha = (y >= h / 2 and x >= w / 4 and x < 3 * w / 4) and 255 or 0 }
            end,
            free = function() freed = freed + 1 end,
        }
    end
    O.CONTENT_PROBE = 8
    local l, tp, r, b = O.contentBox({ path = d .. "/x.png", aspect = 1 })
    eq(l, 0.25); eq(tp, 0.5); eq(r, 0.75); eq(b, 1)
    eq(freed, 1)
    -- remembered: no second render
    O._render = function() error("rendered again") end
    eq(O.contentBox({ path = d .. "/x.png", aspect = 1 }), 0.25)
    -- nothing opaque, or no alpha: no crop
    O._render = function(_p, w, h) return { getWidth = function() return w end, getHeight = function() return h end,
        getPixel = function() return { alpha = 0 } end } end
    eq(O.contentBox({ path = d .. "/blank.png", aspect = 1 }), nil)
    O._render = nil
    os.execute("rm -rf '" .. d .. "'")
end)

-- Measured on a PW5, 2026-10-08: a Theme library hero seen for the first
-- time decoded its PNG twice (the probe, then the render), ~145ms each.
t.test("a preview decodes a PNG once: its probe and its render are scaled from one decode", function()
    local O, d = setup()
    local decodes, scales, renders, freed = 0, {}, 0, 0
    local function fake(w, h, on_free)
        return {
            getWidth = function() return w end, getHeight = function() return h end,
            getPixel = function(_, x, y)
                return { alpha = (y >= h / 2 and x >= w / 4 and x < 3 * w / 4) and 255 or 0 }
            end,
            free = on_free or function() end,
        }
    end
    O._decodeFull = function(_path) decodes = decodes + 1; return fake(400, 400, function() freed = freed + 1 end) end
    O._scale = function(bb, w, h) scales[#scales + 1] = bb:getWidth() .. ">" .. w .. "x" .. h; return fake(w, h) end
    O._render = function(_path, w, h) renders = renders + 1; return fake(w, h) end
    O.CONTENT_PROBE = 8
    local e = { path = d .. "/x.png", name = "x.png", aspect = 1 }
    local l, tp, r, b = O.contentBox(e, true)
    eq(l, 0.25); eq(tp, 0.5); eq(r, 0.75); eq(b, 1)
    eq(decodes, 1); eq(renders, 0, "the probe decoded the file itself")
    eq(scales[1], "400>8x8", "the probe is not scaled from the full-size decode")
    eq(O.holds(e), true, "the decode is not held for the render")
    local bb = O.render(e, 50, 50, false)
    assert(bb, "no render from the held decode")
    eq(renders, 0, "the render decoded the file a second time")
    eq(scales[2], "400>50x50")
    eq(O.holds(e), false, "the decode is held after its one render")
    eq(freed, 1, "the full-size decode was not freed")
    O.render(e, 60, 60, false)
    eq(renders, 1, "another size is not rendered as before")
    -- A second probe frees the first held decode; an SVG and a probe that
    -- holds nothing decode as before.
    O._content = {}
    O.contentBox({ path = d .. "/y.png", name = "y.png", aspect = 1 }, true)
    O.contentBox({ path = d .. "/z.png", name = "z.png", aspect = 1 }, true)
    eq(freed, 2, "a held decode was left behind")
    O.releaseHeld()
    eq(freed, 3)
    renders = 0
    O.contentBox({ path = d .. "/v.svg", name = "v.svg", aspect = 1 }, true)
    O.contentBox({ path = d .. "/w.png", name = "w.png", aspect = 1 })
    eq(renders, 2); eq(decodes, 3); eq(O._held, nil)
    O._decodeFull, O._scale, O._render = nil, nil, nil
    os.execute("rm -rf '" .. d .. "'")
end)

t.test("the collection's preview probes with a held decode and renders from it", function()
    local src = io.open("lib/bookshelf_ornament_browser.lua"):read("*a")
    local prev = src:match("\nfunction Browser%.preview%(e, box_w, box_h%)\n(.-)\nend\n")
    assert(prev, "Browser.preview moved")
    assert(prev:find("Orn.contentBox(e, true)", 1, true), "the probe does not hold its decode")
    local tail = prev:match("if Orn%.holds%(e%) then\n(.-)\n    end")
    assert(tail, "the preview does not render from the held decode")
    assert(tail:find("Orn.render(e, preview.placement.w, preview.placement.h, preview.night)", 1, true),
        "the render made from the held decode is not the one the paint asks for")
    assert(tail:find("Orn.releaseHeld()", 1, true), "the held decode is not let go")
    local crop = src:match("\nfunction Cropped:paintTo%(bb, x, y%)\n(.-)\nend\n")
    assert(crop and crop:find("O().render(p.entry, p.w, p.h, self.night)", 1, true),
        "the paint asks for another render than the preview made")
end)

t.test("while deferred, switches are kept in memory and written once at the end", function()
    local O = fresh()
    local deferred, flushed = 0, 0
    O._store.saveDeferred = function(k, v) deferred = deferred + 1; mem[k] = v end
    O._store.flush = function() flushed = flushed + 1 end
    local saved = 0
    local real_save = O._store.save
    O._store.save = function(k, v) saved = saved + 1; real_save(k, v) end
    O.beginDeferred()
    for i = 1, 5 do O.setOff("a" .. i .. ".svg", true) end
    O.setPackOff("Autumn", true)
    eq(saved, 0, "no flushing save while deferred")
    eq(deferred, 6)
    eq(flushed, 0)
    assert(O.isOff("a3.svg") and O.isPackOff("Autumn"), "the switches read back at once")
    O.endDeferred()
    eq(flushed, 1, "one flush at the end")
    O.setOff("b.svg", true)
    eq(saved, 1, "after the end, saves are ordinary again")
end)

t.test("a deferral with no setting changed writes nothing at the end", function()
    -- The Theme library defers while open; looked at and closed with no
    -- choice, it must not cost a write of the whole settings file.
    local O = fresh()
    local gen, flushed = 7, 0
    O._store.generation = function() return gen end
    O._store.saveDeferred = function(k, v) gen = gen + 1; mem[k] = v end
    O._store.flush = function() flushed = flushed + 1 end
    O.beginDeferred(); O.endDeferred()
    eq(flushed, 0, "nothing changed, yet the settings were written")
    O.beginDeferred(); O.setOff("c.svg", true); O.endDeferred()
    eq(flushed, 1, "a change was not written at the end")
    O._store.generation = nil
end)

-- ── The new-file poll watches the ornament folders too ───────────────────────
-- Maintainer: "piggyback on the background check for new books, to check for
-- new ornaments without having to go in/out or refresh anything". The poll
-- runs every few seconds, so this is stats only, never a listing.

local function touchAt(path, secs)
    os.execute(dofile("tests/_helpers.lua").touchAtCmd(secs, "'" .. path .. "'") .. " 2>/dev/null")
end

t.test("folderStamp: steady while nothing changes, moves when a pack or the folder does", function()
    local O = setup()
    O.listAll()                                   -- the scan records the pack folders
    local s1 = O.folderStamp()
    eq(O.stampChanged(s1, O.folderStamp()), false, "the stamp moved with nothing changed")
    svg(O.dir() .. "/Autumn/pumpkin.svg"); touchAt(O.dir() .. "/Autumn", os.time() + 10)
    local s2 = O.folderStamp()
    eq(O.stampChanged(s1, s2), true, "a piece added to a pack went unseen")
    os.execute("mkdir -p '" .. O.dir() .. "/Birds'"); touchAt(O.dir(), os.time() + 20)
    eq(O.stampChanged(s2, O.folderStamp()), true, "a new pack went unseen")
end)

t.test("a scan that only widens the watch list is not a change", function()
    -- On the rig the first baseline was taken before any scan (the roots
    -- alone), and the scan then added the pack folders: a false "change" and
    -- a needless rebuild at every start.
    local O = setup()
    local before = O.folderStamp()                -- no scan yet: roots only
    O.listAll()
    eq(O.stampChanged(before, O.folderStamp()), false, "the scan's own pack folders read as a change")
end)

t.test("folderStamp lists no folder", function()
    local O = setup()
    O.listAll()
    local lists = 0
    local real = lfs_shim.dir
    O._lfs = setmetatable({ dir = function(p) lists = lists + 1; return real(p) end }, { __index = lfs_shim })
    O.folderStamp()
    O._lfs = lfs_shim
    eq(lists, 0, "the poll's check lists a folder every tick")
end)

t.test("the shelf's file poll rescans ornaments when their folders change", function()
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    local tick = w:match("function BookshelfWidget:_filePollTick%(%)(.-)\nend\n")
    assert(tick and tick:find("Orn.folderStamp()", 1, true), "the poll does not look at the ornament folders")
    assert(tick:find("Orn.invalidate()", 1, true), "a change does not drop the cached ornament list")
    local start = w:match("function BookshelfWidget:_startFilePoll%(%)(.-)\nend\n")
    assert(start and start:find("if self._orn_stamp == nil then", 1, true),
        "re-arming re-baselines the ornament stamp, so pieces added during sleep are swallowed")
end)

-- ── Pack editor: adjustments made there go into the pack's own file ─────────

local function readFile(p) local f = io.open(p); if not f then return nil end local s = f:read("*a"); f:close(); return s end

t.test("commitPack moves a pack's records from the reader's file into the pack's", function()
    local O = setup()
    O._encode = function(t2)                      -- a stable stand-in for rapidjson
        local keys = {}
        for k in pairs(t2) do keys[#keys + 1] = k end
        table.sort(keys)
        local out = {}
        for _i, k in ipairs(keys) do
            local rec, fields = t2[k], {}
            local fk = {}
            for f in pairs(rec) do fk[#fk + 1] = f end
            table.sort(fk)
            for _j, f in ipairs(fk) do fields[#fields + 1] = f .. "=" .. tostring(rec[f]) end
            out[#out + 1] = k .. ":" .. table.concat(fields, ",")
        end
        return table.concat(out, ";")
    end
    O._decode = function(text)
        local t2 = {}
        for rec in text:gmatch("[^;]+") do
            local k, body = rec:match("^(.-):(.*)$")
            if k then
                t2[k] = {}
                for f, v in body:gmatch("([%w_]+)=([^,]*)") do t2[k][f] = tonumber(v) or v end
            end
        end
        return t2
    end
    -- What the pack already ships, and what the reader set.
    local pf = assert(io.open(O.dir() .. "/Autumn/ornaments.json", "w")); pf:write("leaf.svg:lift=0.5,scale=0.9"); pf:close()
    O._reader = { ["Autumn/leaf.svg"] = { scale = 1.4 }, ["Autumn/acorn.svg"] = { pad = 0.1 },
                  ["Cats/leaf.svg"] = { scale = 2 }, ["template.svg"] = { scale = 0.5 } }
    O._reader_dirty = true
    eq(O.commitPack("Autumn"), 2)
    local pj = O._decode(readFile(O.dir() .. "/Autumn/ornaments.json"))
    -- The reader's values are adjustments to the pack's: folded in, they
    -- become the pack's own, and the reader's 100% / 0% start from there.
    assert(math.abs(pj["leaf.svg"].scale - 1.26) < 1e-9, "the editor's size was not folded into the pack's: " .. tostring(pj["leaf.svg"].scale))
    eq(pj["leaf.svg"].lift, 0.5, "the pack's own value was lost")
    eq(pj["acorn.svg"].pad, 0.1)
    local rt = O.readerTable()
    eq(rt["Autumn/leaf.svg"], nil, "the record stayed in the reader's file, where it would go on winning")
    eq(rt["Cats/leaf.svg"].scale, 2, "another pack's record was moved")
    eq(rt["template.svg"].scale, 0.5, "a loose piece's record was moved")
    eq(O.commitPack("Autumn"), 0, "a second commit found more to move")
end)

t.test("the settings menu offers the pack editor under Developer updates", function()
    local st = io.open("lib/bookshelf_settings.lua"):read("*a")
    assert(st:find('_("Pack editor\\xE2\\x80\\xA6")', 1, true), "no Pack editor row")
    assert(st:find('require("lib/bookshelf_pack_editor").choose(', 1, true), "the row does not open the editor")
end)

t.done()
