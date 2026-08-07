-- tests/_test_cover_apply.lua
-- resetWorkingCache: what the Cover tab's working dir sweep may and may not
-- delete. Pure-Lua -- a tiny virtual filesystem stands in for lfs/os.remove,
-- so the real recursive sweep runs unchanged against a seeded tree.
--
-- The point of the suite: settings/bookshelf_covers stopped being purely
-- transient when the OPDS cover cache moved in under it
-- (lib/bookshelf_opds_covers.lua's cacheDir). This sweep runs on every
-- book-detail modal close, so without an exemption it silently throws away
-- every cached OPDS cover and the next visit to a catalog re-downloads them
-- all (full-size images, so tens of MB on a metered device).
package.path = "./?.lua;./?/init.lua;" .. package.path

package.loaded["datastorage"] = {
    getSettingsDir = function() return "/settings" end,
}

-- ---------- virtual filesystem ----------
-- path -> "file" | "directory". Only the calls resetWorkingCache makes are
-- implemented; dir() errors on a missing path exactly as real lfs does, which
-- is what the module's pcall around it exists for.
local FS = {}
local removed = {}

local function mkfile(p) FS[p] = "file" end
local function mkdir(p)  FS[p] = "directory" end

package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(path, key)
        local mode = FS[path]
        if not mode then return nil end
        if key == "mode" then return mode end
        return { mode = mode }
    end,
    dir = function(path)
        if FS[path] ~= "directory" then error("cannot open " .. tostring(path)) end
        local names, prefix = { ".", ".." }, path .. "/"
        for p in pairs(FS) do
            if p:sub(1, #prefix) == prefix then
                local rest = p:sub(#prefix + 1)
                if not rest:find("/") then names[#names + 1] = rest end
            end
        end
        table.sort(names)
        local i = 0
        return function() i = i + 1; return names[i] end
    end,
    mkdir = function(path) FS[path] = "directory"; return true end,
    rmdir = function(path)
        if FS[path] == "directory" then FS[path] = nil; removed[#removed + 1] = path end
        return true
    end,
}

os.remove = function(path)                       -- luacheck: ignore
    if FS[path] then FS[path] = nil; removed[#removed + 1] = path; return true end
    return nil, "no such file"
end

package.loaded["logger"] = { dbg = function() end, info = function() end,
                             warn = function() end, err = function() end }
package.loaded["lib/bookshelf_settings_store"] = {
    read = function() return {} end,
    save = function() end,
    flush = function() end,
}
package.loaded["lib/bookshelf_image_source"] = { loadImage = function() return nil end }
package.loaded["ffi/util"] = { template = function(s) return s end }
package.loaded["lib/bookshelf_i18n"] = {
    gettext = function(s) return s end,
    ngettext = function(s, p, n) return n == 1 and s or p end,
}

local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()

local CoverApply = dofile("lib/bookshelf_cover_apply.lua")

local ROOT = "/settings/bookshelf_covers"

local function seed()
    FS = {}
    for i = #removed, 1, -1 do removed[i] = nil end
    mkdir(ROOT)
    -- Transient render/download material: this is what the sweep is for.
    mkfile(ROOT .. "/emb_book1.png")
    mkfile(ROOT .. "/emb_book2.png")
    mkdir(ROOT .. "/online")
    mkfile(ROOT .. "/online/result1.jpg")
    mkfile(ROOT .. "/online/result2.jpg")
    mkdir(ROOT .. "/book1")                       -- older per-book download dir
    mkfile(ROOT .. "/book1/dl.jpg")
    -- The OPDS cover cache: persistent, and NOT this feature's to delete.
    mkdir(ROOT .. "/opds")
    mkdir(ROOT .. "/opds/srvkey1")
    mkfile(ROOT .. "/opds/srvkey1/aaaa.img")
    mkfile(ROOT .. "/opds/srvkey1/bbbb.img")
    mkdir(ROOT .. "/opds/srvkey2")
    mkfile(ROOT .. "/opds/srvkey2/cccc.img")
end

t.test("resetWorkingCache deletes the transient working files", function()
    seed()
    CoverApply.resetWorkingCache()
    assert(FS[ROOT .. "/emb_book1.png"] == nil, "embedded-cover extraction left behind")
    assert(FS[ROOT .. "/emb_book2.png"] == nil, "embedded-cover extraction left behind")
    assert(FS[ROOT .. "/online/result1.jpg"] == nil, "online search download left behind")
    assert(FS[ROOT .. "/online"] == nil, "the online/ dir itself is removed")
    assert(FS[ROOT .. "/book1/dl.jpg"] == nil, "per-book download left behind")
    assert(FS[ROOT .. "/book1"] == nil, "the per-book dir itself is removed")
end)

t.test("resetWorkingCache leaves the OPDS cover cache untouched", function()
    seed()
    CoverApply.resetWorkingCache()
    assert(FS[ROOT .. "/opds"] == "directory", "the opds/ dir must survive")
    assert(FS[ROOT .. "/opds/srvkey1"] == "directory", "per-server dir must survive")
    assert(FS[ROOT .. "/opds/srvkey1/aaaa.img"] == "file", "cached OPDS cover deleted")
    assert(FS[ROOT .. "/opds/srvkey1/bbbb.img"] == "file", "cached OPDS cover deleted")
    assert(FS[ROOT .. "/opds/srvkey2/cccc.img"] == "file", "cached OPDS cover deleted")
    for _i, p in ipairs(removed) do
        assert(not p:find("/opds", 1, true),
            "nothing under opds/ may be removed, got " .. p)
    end
end)

t.test("resetWorkingCache keeps the working dir itself", function()
    seed()
    CoverApply.resetWorkingCache()
    assert(FS[ROOT] == "directory", "the working dir is emptied, not removed")
end)

t.test("resetWorkingCache is a no-op when the working dir doesn't exist", function()
    FS = {}
    for i = #removed, 1, -1 do removed[i] = nil end
    CoverApply.resetWorkingCache()
    assert(#removed == 0, "nothing to remove")
end)

t.test("resetWorkingCache tolerates an unreadable subdirectory", function()
    seed()
    local real_dir = package.loaded["libs/libkoreader-lfs"].dir
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        if path == ROOT .. "/online" then error("permission denied") end
        return real_dir(path)
    end
    CoverApply.resetWorkingCache()
    package.loaded["libs/libkoreader-lfs"].dir = real_dir
    assert(FS[ROOT .. "/emb_book1.png"] == nil, "the rest of the sweep still ran")
    assert(FS[ROOT .. "/opds/srvkey1/aaaa.img"] == "file", "opds/ still exempt")
end)

t.done()
