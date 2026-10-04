-- tests/_test_ornament_folders.lua
-- The ornaments folder moved (v5.3) from koreader/icons/bookshelf.ornaments
-- to koreader/settings/bookshelf/ornaments, beside the wallpapers, so one
-- folder backs up everything Bookshelf (maintainer). The old folder is still
-- read and nothing is moved; where both hold the same file, the new one wins.
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

t.test("the documented folder is beside the wallpapers", function()
    local O = fresh()
    local d = scratch()
    O._data_dir = d; O._lfs = lfs_shim
    eq(O.dir(), d .. "/settings/bookshelf/ornaments")
    eq(O.legacyDir(), d .. "/icons/bookshelf.ornaments")
end)

t.test("a fresh install gets the new folder with the seeds; the old one is not created", function()
    local O = fresh()
    local d = scratch()
    O._data_dir = d; O._lfs = lfs_shim
    O.ensureTemplate()
    assert(lfs_shim.attributes(O.dir() .. "/template.svg", "mode") == "file", "no template in the new folder")
    eq(lfs_shim.attributes(O.legacyDir(), "mode"), nil, "the old folder was created")
end)

t.test("an existing old folder keeps working, and gets no second template", function()
    local O = fresh()
    local d = scratch()
    O._data_dir = d; O._lfs = lfs_shim
    os.execute("mkdir -p '" .. d .. "/icons/bookshelf.ornaments/Autumn'")
    svg(d .. "/icons/bookshelf.ornaments/cat.svg")
    svg(d .. "/icons/bookshelf.ornaments/Autumn/leaf.svg")
    O.ensureTemplate()
    eq(lfs_shim.attributes(O.dir(), "mode"), "directory", "the new folder should exist, for the path the browser shows")
    eq(lfs_shim.attributes(O.dir() .. "/template.svg", "mode"), nil, "a second template was seeded")
    local all, packs = O.listAll()
    eq(names(all), "cat.svg,Autumn/leaf.svg")
    eq(table.concat(packs, ","), "Autumn")
end)

t.test("both folders are read; the same file in both comes from the new one", function()
    local O = fresh()
    local d = scratch()
    O._data_dir = d; O._lfs = lfs_shim
    local old, new = d .. "/icons/bookshelf.ornaments", d .. "/settings/bookshelf/ornaments"
    os.execute("mkdir -p '" .. old .. "/Autumn' '" .. new .. "/Autumn' '" .. new .. "/Halloween'")
    svg(old .. "/Autumn/leaf.svg"); svg(new .. "/Autumn/leaf.svg"); svg(old .. "/Autumn/acorn.svg")
    svg(new .. "/Halloween/bat.svg"); svg(old .. "/loose.svg")
    local all, packs = O.listAll()
    eq(names(all), "loose.svg,Autumn/acorn.svg,Autumn/leaf.svg,Halloween/bat.svg")
    eq(table.concat(packs, ","), "Autumn,Halloween", "one Autumn pack, not two")
    for _i, e in ipairs(all) do
        if e.name == "Autumn/leaf.svg" then eq(e.path, new .. "/Autumn/leaf.svg", "the old copy won") end
        if e.name == "Autumn/acorn.svg" then eq(e.path, old .. "/Autumn/acorn.svg") end
    end
    eq(O.packDir("Halloween"), new .. "/Halloween")
    eq(O.packDir("Autumn"), new .. "/Autumn", "a pack in both: its theme comes from the new folder")
end)

t.test("a file added to either folder is seen without a restart", function()
    local O = fresh()
    local d = scratch()
    O._data_dir = d; O._lfs = lfs_shim
    O.SCAN_TTL = 0
    os.execute("mkdir -p '" .. d .. "/icons/bookshelf.ornaments' '" .. d .. "/settings/bookshelf/ornaments'")
    svg(d .. "/icons/bookshelf.ornaments/a.svg")
    eq(#O.listAll(), 1)
    os.execute("sleep 1")
    svg(d .. "/icons/bookshelf.ornaments/b.svg")
    eq(#O.listAll(), 2, "a file added to the old folder was missed")
end)

t.done()
