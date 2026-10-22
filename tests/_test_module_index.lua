-- tests/_test_module_index.lua
-- Looking a micro-module up used to run every module file in both dirs (cold
-- on a PW5, 124ms of a full-screen open showing 7 of 17). The last full scan
-- now leaves an index (key -> file) and a lookup runs just that file, while
-- the dirs hold exactly the files they held then. Any change to them, or a key
-- the named file no longer defines, goes back through the full scan.
-- Run from the plugin root: lua tests/_test_module_index.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()

package.loaded["logger"] = { dbg = function() end, info = function() end,
                             warn = function() end, err = function() end }
local USER = "/u/bookshelf/micromodules"
package.loaded["datastorage"] = { getSettingsDir = function() return "/u" end }

local cache = {}
package.loaded["lib/bookshelf_module_cache"] = {
    read = function(k) return cache[k] end,
    save = function(k, v) cache[k] = v end,
}
local any_enabled = true
package.loaded["lib/bookshelf_settings_store"] = {
    microAnyEnabled = function() return any_enabled end,
}

local M = dofile("lib/bookshelf_start_menu_modules.lua")
-- The bundled dir is resolved from the loader's own path.
local BUNDLED = "micromodules"

-- Files per dir: fname -> the key it defines.
local files = {}
local function setFiles(user, bundled)
    files[USER], files[BUNDLED] = user, bundled
end
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(path, what)
        if what == "mode" and files[path] then return "directory" end
    end,
    dir = function(path)
        local names = {}
        for n in pairs(files[path] or {}) do names[#names + 1] = n end
        table.sort(names)
        local i = 0
        return function() i = i + 1; return names[i] end
    end,
}

-- loadfile records what ran and returns a spec, never touching the disk. (The
-- loader uses loadfile + call so a module file receives its folder as `...`.)
local ran = {}
local real_loadfile = loadfile
_G.loadfile = function(path, ...)
    local dir, fname = path:match("^(.*)/([^/]+)$")
    if dir and files[dir] and files[dir][fname] then
        return function()
            ran[#ran + 1] = path
            return { key = files[dir][fname], title = fname .. "@" .. dir,
                     render = function() end }
        end
    end
    return real_loadfile(path, ...)
end

local function fresh()
    M._test.reset()
    ran = {}
end

setFiles({ ["mine.lua"] = "mine" },
         { ["a.lua"] = "a", ["b.lua"] = "b", ["c.lua"] = "c", ["d.lua"] = "d" })

t.test("with no index the first lookup scans everything and leaves one", function()
    fresh()
    assert(M.get("a"), "a not found")
    assert(#ran == 5, "a full scan runs all 5 files, ran " .. #ran)
    assert(cache.module_index and cache.module_index.keys.a, "no index was saved")
end)

t.test("a restart with the same files runs only the file it needs", function()
    fresh()
    assert(M.get("c"), "c not found")
    assert(#ran == 1 and ran[1]:find("c.lua", 1, true), "ran " .. table.concat(ran, ","))
    assert(M.get("mine"), "the user's module was not found")
    assert(#ran == 2, "ran " .. #ran)
    assert(M.title("a") == "a.lua@" .. BUNDLED)
    assert(#ran == 3)
end)

t.test("a full scan after lazy loads runs nothing twice", function()
    fresh()
    M.get("c")
    local keys = M.keys()    -- the picker lists them all
    assert(#keys == 5, "got " .. #keys .. " keys")
    local seen = {}
    for _, p in ipairs(ran) do
        assert(not seen[p], p .. " ran twice"); seen[p] = true
    end
end)

t.test("a module added to a dir sends the next lookup through the full scan", function()
    setFiles({ ["mine.lua"] = "mine", ["new.lua"] = "new" },
             { ["a.lua"] = "a", ["b.lua"] = "b", ["c.lua"] = "c", ["d.lua"] = "d" })
    fresh()
    assert(M.get("a"))
    assert(#ran == 6, "the stale index was trusted, ran " .. #ran)
end)

t.test("a user module overriding a bundled one wins", function()
    setFiles({ ["mine.lua"] = "mine", ["my_a.lua"] = "a" },
             { ["a.lua"] = "a", ["b.lua"] = "b", ["c.lua"] = "c", ["d.lua"] = "d" })
    fresh()
    assert(M.get("a").title == "my_a.lua@" .. USER, "the bundled module won")
    fresh()                    -- and again, through the fresh index
    assert(M.get("a").title == "my_a.lua@" .. USER, "the index lost the override")
    assert(#ran == 1)
end)

t.test("a file that no longer defines its key falls back to the full scan", function()
    fresh()
    M.get("a")                 -- index is current
    files[BUNDLED]["b.lua"] = "b2"   -- same file names, different key
    fresh()
    assert(M.get("b") == nil, "b is gone")
    assert(M.get("b2"), "b2 not found after the rescan")
end)

t.test("with every surface off nothing is run", function()
    any_enabled = false
    fresh()
    assert(M.get("a") == nil and #ran == 0, "ran " .. #ran)
    any_enabled = true
end)

t.done()
