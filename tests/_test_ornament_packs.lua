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

t.done()
