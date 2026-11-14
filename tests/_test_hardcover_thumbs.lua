-- tests/_test_hardcover_thumbs.lua
-- Cover thumbnails for the Hardcover picker (lib/bookshelf_hardcover_thumbs):
-- a small disk cache keyed by the image's address, and a loader that fetches
-- the ones a page needs, one at a time, each in a child process so the list
-- stays usable while they arrive.
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t, eq = helpers.runner(), helpers.eq

local files, queue
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(path)
        local f = files[path]
        if not f then return nil end
        return { mode = "file", size = f.size or 100, modification = f.mtime or 0 }
    end,
    dir = function(dir)
        local names = {}
        for p in pairs(files) do
            local d, n = p:match("^(.*)/([^/]+)$")
            if d == dir then names[#names + 1] = n end
        end
        local i = 0
        return function() i = i + 1; return names[i] end
    end,
}
package.loaded["lib/bookshelf_paths"] = { cacheFile = function(name) return "/cache/" .. name end }
package.loaded["lib/bookshelf_fs"] = { ensureDir = function() return true end }
package.loaded["ui/uimanager"] = {
    scheduleIn = function(_s, _sec, fn) queue[#queue + 1] = fn end,
    unschedule = function(_s, fn)
        for i = #queue, 1, -1 do if queue[i] == fn then table.remove(queue, i) end end
    end,
}
package.loaded["logger"] = { warn = function() end, dbg = function() end }
local clock = 1000
package.loaded["lib/bookshelf_gettime"] = function() return clock end
local removed = {}
local real_remove = os.remove
os.remove = function(p)
    if type(p) == "string" and p:sub(1, 7) == "/cache/" then removed[#removed + 1] = p; files[p] = nil; return true end
    return real_remove(p)
end

local Thumbs = dofile("lib/bookshelf_hardcover_thumbs.lua")

-- Child processes: spawned[i] = { url, path }; finish(i, ok) ends one.
local spawned, running, killed
Thumbs._spawn = function(url, path)
    spawned[#spawned + 1] = { url = url, path = path }
    running[#spawned] = true
    return #spawned
end
Thumbs._done = function(h) return not running[h] end
Thumbs._kill = function(h) killed[#killed + 1] = h; running[h] = nil end
local function finish(h, ok)
    running[h] = nil
    if ok then files[spawned[h].path] = { size = 5000 } end
end
-- One turn of the loader's poll.
local function tick()
    local q = queue; queue = {}
    for _i, fn in ipairs(q) do fn() end
end
local function reset()
    files, queue, spawned, running, killed, removed, clock = {}, {}, {}, {}, {}, {}, 1000
end
local function rec(id, url) return { book_id = id, cached_image = url and { url = url } or nil } end

t.test("a record's cover address, and a stable file for it", function()
    reset()
    eq(Thumbs.urlOf(rec(1, "https://a.example/x.jpeg")), "https://a.example/x.jpeg")
    eq(Thumbs.urlOf(rec(1)), nil)
    eq(Thumbs.urlOf({ cached_image = { url = "" } }), nil)
    eq(Thumbs.urlOf({ cached_image = "not a table" }), nil)
    eq(Thumbs.urlOf({ cached_image = { url = "ftp://x/y.png" } }), nil, "only web addresses are fetched")
    local a = Thumbs.pathFor("https://a.example/x.jpeg")
    local b = Thumbs.pathFor("https://a.example/y.jpeg")
    assert(a:match("^/cache/covers/hardcover_picker/[%w]+%.img$"), a)
    assert(a ~= b, "two addresses share a file")
    eq(Thumbs.pathFor("https://a.example/x.jpeg"), a)
end)

t.test("cached: only a file that is there, and not an empty one", function()
    reset()
    local url = "https://a.example/x.jpeg"
    eq(Thumbs.cached(url), nil)
    files[Thumbs.pathFor(url)] = { size = 0 }
    eq(Thumbs.cached(url), nil, "a failed download left an empty file")
    files[Thumbs.pathFor(url)] = { size = 4000 }
    eq(Thumbs.cached(url), Thumbs.pathFor(url))
    eq(Thumbs.cached(nil), nil)
end)

t.test("the loader fetches what is missing, one at a time, and says when each lands", function()
    reset()
    local landed = {}
    local L = Thumbs.newLoader{ on_loaded = function(r) landed[#landed + 1] = r.book_id end }
    local A, B, C = rec(1, "https://a/1.jpg"), rec(2, "https://a/2.jpg"), rec(3)
    files[Thumbs.pathFor("https://a/2.jpg")] = { size = 900 }     -- B is cached already
    L:want({ A, B, C, rec(4, "https://a/4.jpg") })
    eq(#spawned, 1, "more than one download at a time")
    eq(spawned[1].url, "https://a/1.jpg")
    tick()
    eq(#landed, 0, "said it landed before the child was done")
    finish(1, true)
    tick()
    eq(landed[1], 1)
    eq(#spawned, 2); eq(spawned[2].url, "https://a/4.jpg")
    finish(2, true)
    tick()
    eq(landed[2], 4)
    tick()
    eq(#spawned, 2, "nothing left to fetch")
    eq(#queue, 0, "the poll goes on with nothing to do")
end)

t.test("a download that fails is not announced and not retried this session", function()
    reset()
    local landed, failed = 0, 0
    local L = Thumbs.newLoader{ on_loaded = function() landed = landed + 1 end,
        on_failed = function() failed = failed + 1 end }
    local A = rec(1, "https://a/1.jpg")
    L:want({ A })
    finish(1, false)
    tick()
    eq(landed, 0)
    eq(failed, 1, "the cell is not told to say No cover")
    L:want({ A })
    eq(#spawned, 1, "a cover that would not download was asked for again")
    eq(L:hasFailed("https://a/1.jpg"), true, "the list cannot tell a failed cover from one loading")
    eq(L:hasFailed("https://a/2.jpg"), false)
end)

t.test("records that share a cover share one download, and all hear of it", function()
    reset()
    local landed = {}
    local L = Thumbs.newLoader{ on_loaded = function(r) landed[#landed + 1] = r.book_id end }
    L:want({ rec(1, "https://a/same.jpg"), rec(2, "https://a/same.jpg") })
    eq(#spawned, 1)
    finish(1, true)
    tick()
    eq(#landed, 2)
    eq(#spawned, 1)
end)

t.test("a new page replaces what is waiting; the one in flight finishes", function()
    reset()
    local landed = {}
    local L = Thumbs.newLoader{ on_loaded = function(r) landed[#landed + 1] = r.book_id end }
    L:want({ rec(1, "https://a/1.jpg"), rec(2, "https://a/2.jpg") })
    L:want({ rec(3, "https://a/3.jpg") })
    finish(1, true)
    tick()
    eq(spawned[2].url, "https://a/3.jpg", "the page that was left is still being fetched")
    eq(#landed, 0, "a cover for a page no longer showing was announced")
end)

t.test("a download that hangs is ended, and the next one starts", function()
    reset()
    local L = Thumbs.newLoader{ on_loaded = function() end }
    L:want({ rec(1, "https://a/1.jpg"), rec(2, "https://a/2.jpg") })
    clock = clock + Thumbs.TIMEOUT_S + 1
    tick()
    eq(killed[1], 1)
    eq(spawned[2].url, "https://a/2.jpg")
end)

t.test("stop: the child is ended and nothing more is announced or polled", function()
    reset()
    local landed = 0
    local L = Thumbs.newLoader{ on_loaded = function() landed = landed + 1 end }
    L:want({ rec(1, "https://a/1.jpg"), rec(2, "https://a/2.jpg") })
    L:stop()
    eq(killed[1], 1)
    eq(#queue, 0)
    tick()
    eq(#spawned, 1); eq(landed, 0)
    L:want({ rec(3, "https://a/3.jpg") })
    eq(#spawned, 1, "a stopped loader started again")
end)

t.test("sweep: covers not looked at for a month go, the rest stay", function()
    reset()
    local now = 50 * 86400
    files["/cache/covers/hardcover_picker/old.img"] = { mtime = now - 40 * 86400 }
    files["/cache/covers/hardcover_picker/new.img"] = { mtime = now - 2 * 86400 }
    files["/cache/covers/hardcover_picker/half.img.tmp"] = { mtime = now - 2 * 86400 }
    Thumbs.sweep(now)
    eq(files["/cache/covers/hardcover_picker/old.img"], nil)
    assert(files["/cache/covers/hardcover_picker/new.img"], "a recent cover was removed")
    eq(files["/cache/covers/hardcover_picker/half.img.tmp"], nil, "a half-written file was left")
end)

t.done()
