-- tests/_test_cache_path.lua
-- Our cache files must live in a SUBDIRECTORY of koreader/cache/, never in the
-- root of it.
--
-- ── WHY ─────────────────────────────────────────────────────────────────────
--
-- KOReader's DocCache treats every regular file in that root as part of its own
-- disk cache. Cache:_getDiskCache snapshots anything with mode == "file", the
-- total counts against DocCache's budget, and once the budget is exceeded
-- DocCache:serialize deletes entries oldest-first until it fits again.
--
-- On a Kindle that is not the LRU it looks like. /mnt/us is mounted noatime and
-- FAT stores an access DATE with no time, so reading a file never moves its
-- atime; it stays at creation. Measured on a PW5: bookshelf.lightmeta, read on
-- every shelf open and rewritten the previous day, still carried a ten-day-old
-- atime and sorted AHEAD of a doccache entry KOReader had touched more
-- recently. Our files drift to the front of the queue and cannot climb back.
--
-- Nothing corrupts if one is evicted -- we rebuild -- but lightmeta's rebuild
-- is a full metadata walk, so the symptom is a slow shelf open with no
-- explanation, repeatedly.
--
-- Usage (from plugin root): lua tests/_test_cache_path.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = dofile("tests/_helpers.lua")
local t = H.runner()
local eq = H.eq

local src = assert(io.open("lib/bookshelf_book_repository.lua")):read("*a")

local block = src:match("\n(local CACHE_FILES = .-\nend)\n")
assert(block, "the cache-path helper moved or was renamed")

-- Stub filesystem: records what was created and renamed.
local function makeEnv()
    local fs = { files = {}, dirs = {}, renames = {} }
    local lfs = {
        mkdir = function(d) fs.dirs[d] = true; return true end,
        attributes = function(p, key)
            if key == "mode" then return fs.files[p] and "file" or nil end
        end,
    }
    local env = {
        pcall = pcall, type = type, require = function(name)
            if name == "datastorage" then
                return { getDataDir = function() return "/DATA" end }
            elseif name == "libs/libkoreader-lfs" then
                return lfs
            end
            error("unexpected require: " .. tostring(name))
        end,
        os = { rename = function(a, b)
            fs.renames[#fs.renames + 1] = a .. " -> " .. b
            fs.files[b] = fs.files[a]; fs.files[a] = nil
            return true
        end },
    }
    return env, fs
end

local function compile(env)
    local code = block .. "\nEXPORT = { path = _cachePath, names = CACHE_FILES }"
    if _G.setfenv then
        local f = assert(_G.loadstring(code, "cachepath"))
        _G.setfenv(f, env)
        return f
    end
    return assert(load(code, "cachepath", "t", env))
end

-- ── the path itself ────────────────────────────────────────────────────────

t.test("cache files land in a subdirectory, not the cache root", function()
    local env, _fs = makeEnv()
    compile(env)()
    local p = env.EXPORT.path("bookshelf.lightmeta")
    eq(p, "/DATA/cache/bookshelf/bookshelf.lightmeta")
end)

t.test("the subdirectory is created, since DocCache only skips DIRECTORIES", function()
    -- A path pointing at a directory that does not exist would make Persist
    -- fail and silently disable the cache, which looks identical to eviction.
    local env, fs = makeEnv()
    compile(env)()
    env.EXPORT.path("bookshelf.walk")
    assert(fs.dirs["/DATA/cache/bookshelf/"], "the subdirectory was never created")
end)

-- ── the one-time move ──────────────────────────────────────────────────────

t.test("files left in the root by v5.0.4 and earlier are moved, not abandoned", function()
    -- lightmeta's rebuild is a full metadata walk, so letting it regenerate
    -- would charge every existing user one slow launch.
    local env, fs = makeEnv()
    fs.files["/DATA/cache/bookshelf.lightmeta"] = true
    fs.files["/DATA/cache/bookshelf.walk"] = true
    compile(env)()
    env.EXPORT.path("bookshelf.lightmeta")
    eq(#fs.renames, 2, "expected both existing files moved, got: "
        .. table.concat(fs.renames, ", "))
    assert(fs.files["/DATA/cache/bookshelf/bookshelf.lightmeta"],
        "lightmeta did not arrive in the subdirectory")
end)

t.test("a file that was never there is not invented", function()
    local env, fs = makeEnv()
    compile(env)()
    env.EXPORT.path("bookshelf.walk")
    eq(#fs.renames, 0, "renamed something that did not exist")
end)

t.test("the move runs once, not on every cache access", function()
    -- These helpers are called on every shelf open; re-scanning the root each
    -- time would be a pointless stat storm on a slow fuse mount.
    local env, fs = makeEnv()
    fs.files["/DATA/cache/bookshelf.walk"] = true
    compile(env)()
    env.EXPORT.path("bookshelf.walk")
    env.EXPORT.path("bookshelf.lightmeta")
    env.EXPORT.path("bookshelf.finishedcount")
    eq(#fs.renames, 1, "the migration repeated itself")
end)

t.test("every file we persist is covered by the move", function()
    -- A file added later but left out of the list would silently keep writing
    -- to the old location forever.
    local env = makeEnv()
    compile(env)()
    local listed = {}
    for _i, n in ipairs(env.EXPORT.names) do listed[n] = true end
    for name in src:gmatch('_cachePath%("([%w%.]+)"%)') do
        assert(listed[name], name .. " is persisted but missing from CACHE_FILES")
    end
end)

t.test("a half-present datastorage yields nil rather than throwing", function()
    -- Callers read a nil path as "no cache available" and carry on. Throwing
    -- instead would take out a whole shelf build, which is how this first
    -- showed up: the repository suite has a datastorage stub with no
    -- getDataDir, and 200-odd unrelated tests went red.
    local env = {
        pcall = pcall, type = type,
        require = function(name)
            if name == "datastorage" then return {} end   -- no getDataDir
            return nil
        end,
        os = { rename = function() end },
    }
    compile(env)()
    local ok, res = pcall(env.EXPORT.path, "bookshelf.walk")
    assert(ok, "it threw instead of returning nil: " .. tostring(res))
    eq(res, nil)
end)

-- ── the invariant ──────────────────────────────────────────────────────────

t.test("nothing writes to the cache ROOT any more", function()
    local bad = src:match('"/cache/bookshelf%.[%w]+"')
    assert(not bad, "a cache file is still written to the root: " .. tostring(bad))
end)

t.done()
