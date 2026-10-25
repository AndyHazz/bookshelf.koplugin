-- tests/_test_ornament_index.lua
-- The ornament index: each piece's size and flags kept between sessions, per
-- pack, so the first shelf of a session doesn't read the head of every file.
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
disk, saves = {}, 0
local function fresh()
    package.loaded["lib/bookshelf_ornaments"] = nil
    local O = dofile("lib/bookshelf_ornaments.lua")
    O.SCAN_TTL = 0
    mem = {}
    O._store = { read = function(k) return mem[k] end, save = function(k, v) mem[k] = v end }
    O._index_store = { read = function(k) return disk[k] end,
                       save = function(k, v) disk[k] = v; saves = saves + 1 end }
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


-- A "session": a fresh load of the module over the same disk.
local function session(d)
    local O = fresh()
    O._data_dir = d; O._lfs = lfs_shim
    return O
end

t.test("a second session reads no piece's file", function()
    disk, saves = {}, 0
    local O, d = setup()
    local first = O.listAll()
    assert(#first >= 5 and saves == 1, "#" .. #first .. " saves " .. saves)
    local O2 = session(d)
    local reads = 0
    local real_open = io.open
    io.open = function(p, m) if tostring(p):match("%.svg$") then reads = reads + 1 end return real_open(p, m) end
    local again = O2.listAll()
    io.open = real_open
    eq(reads, 0, "pieces read again")
    eq(names(again), names(first))
    for i, e in ipairs(again) do
        assert(e.aspect == first[i].aspect and e.path == first[i].path, e.name)
    end
    eq(saves, 1, "an unchanged index written again")
end)

t.test("a changed pack is read again, the others are not", function()
    disk, saves = {}, 0
    local O, d = setup()
    O.listAll()
    os.execute("sleep 1")
    svg(O.dir() .. "/Cats/whisker.svg")
    local O2 = session(d)
    local read = {}
    local real_open = io.open
    io.open = function(p, m) local n = tostring(p):match("([^/]+/[^/]+)%.svg$"); if n then read[#read + 1] = n end return real_open(p, m) end
    local all = O2.listAll()
    io.open = real_open
    table.sort(read)
    eq(table.concat(read, ","), "Cats/leaf,Cats/whisker")
    assert(names(all):find("Cats/whisker.svg", 1, true), names(all))
    -- A piece removed goes from the index too.
    os.execute("sleep 1")
    os.remove(O.dir() .. "/Autumn/acorn.svg")
    local O3 = session(d)
    O3.listAll()
    assert(disk.index.pieces["Autumn/acorn.svg"] == nil, "a deleted piece stays in the index")
end)

t.test("a rendered piece is kept on disk, before the night and mirror passes", function()
    disk, saves = {}, 0
    local O, d = setup()
    local kept, renders = {}, 0
    O._disk_cache = { load = function(k) return kept[k] end,
                      store = function(k, bb) kept[k] = bb; return true end }
    O._render = function(_p, w, h)
        renders = renders + 1
        return { w = w, h = h, getWidth = function() return w end, getHeight = function() return h end,
                 invertRect = function(self) self.inverted = true end, copy = function(self) return self end }
    end
    local e = O.listAll()[1]
    O.render(e, 10, 20)
    eq(renders, 1)
    O._cache, O._cache_order = {}, {}           -- a new session's memory
    O.render(e, 10, 20)
    eq(renders, 1, "rendered again with the piece on disk")
    local n = 0
    for k in pairs(kept) do n = n + 1; assert(k:find("|10x20", 1, true), k) end
    eq(n, 1)
end)

t.done()
