-- tests/_test_asset_folder.lua
-- AssetFolder.scan: the cache key behind every drop-a-file-in folder.
--
-- The whole reason this is not just an mtime is written up in the module
-- header; these pin the two cases that broke, both measured rather than
-- imagined:
--
--   * a DELETE that does not move the directory mtime (Kindle fuse.fsp)
--   * an ADD inside the same whole second as the previous read
--
-- Both end in "restart to see your own file", which is the one outcome a
-- drop-in folder must never have.
--
-- Usage (from plugin root): lua tests/_test_asset_folder.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = dofile("tests/_helpers.lua")
local t = H.runner()
local eq = H.eq

local AF = require("lib/bookshelf_asset_folder")

-- A fake lfs whose mtime we control, so "the mtime did not move" is a thing
-- the test can actually assert rather than hope for.
local function fakeFs(names, mtime)
    return {
        attributes = function(_d, attr)
            if attr == "modification" then return mtime end
        end,
        dir = function()
            local i = 0
            local all = { ".", ".." }
            for _j = 1, #names do all[#all + 1] = names[_j] end
            return function() i = i + 1; return all[i] end
        end,
    }
end

local EXTS = AF.extsFromList({ "png", "svg" })

t.test("scan: returns the matching names, sorted", function()
    local names = AF.scan(fakeFs({ "zebra.png", "apple.svg", "notes.txt" }, 100), "/d", EXTS)
    eq(#names, 2, "the txt is not ours")
    eq(names[1], "apple.svg")
    eq(names[2], "zebra.png")
end)

t.test("scan: the extension test is case-insensitive", function()
    local names = AF.scan(fakeFs({ "A.PNG", "b.SvG" }, 100), "/d", EXTS)
    eq(#names, 2, "got " .. #names)
end)

t.test("scan: . and .. never match", function()
    local names = AF.scan(fakeFs({}, 100), "/d", EXTS)
    eq(#names, 0)
end)

t.test("scan: a REMOVAL changes the key even when the mtime does not", function()
    -- The measured fuse.fsp case. Same mtime either side, one file fewer.
    local _n1, k1 = AF.scan(fakeFs({ "a.png", "b.png" }, 500), "/d", EXTS)
    local _n2, k2 = AF.scan(fakeFs({ "a.png" },           500), "/d", EXTS)
    assert(k1 ~= k2, "a removal must invalidate the cache on its own")
end)

t.test("scan: an ADDITION changes the key even when the mtime does not", function()
    -- Whole-second mtimes: a file written in the same tick as the last read.
    local _n1, k1 = AF.scan(fakeFs({ "a.png" },           500), "/d", EXTS)
    local _n2, k2 = AF.scan(fakeFs({ "a.png", "b.png" },  500), "/d", EXTS)
    assert(k1 ~= k2, "an addition must invalidate the cache on its own")
end)

t.test("scan: an unchanged folder keeps the same key", function()
    -- The cache still has to earn its keep, or every render re-reads
    -- every file.
    local _n1, k1 = AF.scan(fakeFs({ "b.png", "a.svg" }, 500), "/d", EXTS)
    local _n2, k2 = AF.scan(fakeFs({ "a.svg", "b.png" }, 500), "/d", EXTS)
    eq(k1, k2, "same contents, same key, whatever order the OS listed them in")
end)

t.test("scan: a file EDITED in place changes the key via the mtime", function()
    -- The name set cannot see this one, which is why the mtime stays in the
    -- key rather than being replaced by the names.
    local _n1, k1 = AF.scan(fakeFs({ "a.png" }, 500), "/d", EXTS)
    local _n2, k2 = AF.scan(fakeFs({ "a.png" }, 501), "/d", EXTS)
    assert(k1 ~= k2, "an in-place edit must invalidate the cache")
end)

t.test("scan: two different name sets cannot collide into one key", function()
    -- The separator has to be a byte that cannot appear in a filename, or
    -- {"a b", "c"} and {"a", "b c"} would hash alike.
    local _n1, k1 = AF.scan(fakeFs({ "a b.png", "c.png" }, 500), "/d", EXTS)
    local _n2, k2 = AF.scan(fakeFs({ "a.png", "b c.png" }, 500), "/d", EXTS)
    assert(k1 ~= k2, "name sets must not collide")
end)

t.test("scan: a missing folder answers nil rather than an empty success", function()
    -- nil means "could not look"; an empty list would mean "looked, found
    -- nothing" and would poison the cache with a wrong answer.
    local fs = { attributes = function() return nil end, dir = function() end }
    assert(AF.scan(fs, "/gone", EXTS) == nil, "no mtime, no answer")
    assert(AF.scan(nil, "/d", EXTS) == nil, "no fs, no answer")
    assert(AF.scan(fakeFs({}, 1), nil, EXTS) == nil, "no dir, no answer")
end)

t.test("scan: a throwing dir iterator degrades to nil, not a crash", function()
    local fs = {
        attributes = function(_d, a) if a == "modification" then return 1 end end,
        dir = function() error("permission denied") end,
    }
    assert(AF.scan(fs, "/d", EXTS) == nil, "a failed walk must not propagate")
end)

t.test("extsFromList: builds a lowercase set", function()
    local set = AF.extsFromList({ "PNG", "Jpg" })
    assert(set.png and set.jpg, "both should be present, lowercased")
    assert(not set.PNG, "the original case must not be a key")
end)

t.done()
