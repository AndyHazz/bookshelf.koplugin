-- tests/_test_folder_cover_cache.lua
-- A folder tile works out its book once per walk, not once per fetch.
--
-- WHAT NEEDS PINNING. #409 made a folder tile show the book the folder
-- itself opens with, which means ordering the folder's books, which means a
-- light metadata record -- a BookInfoManager lookup -- for every book sitting
-- in that folder. That runs per folder ON the visible page, which sounded
-- bounded when it was written ("the immediate children are sorted, a handful,
-- normally") and is not: a folder holding a few hundred books is ordinary,
-- and the work repeats on every single fetch. Every page turn, every chip
-- pre-warm and every shelf rebuild pays it again for the same folders.
--
-- Measured on the real KOReader rig, 8 folders of 120 books on one page,
-- desktop hardware: the getAll hydrate went 3ms -> 164ms across 448575e
-- alone, all of it in folderCoverPaths. On a Kobo with 568 books the reporter
-- of issue 422 logged 567ms in that one call.
--
-- The member list only changes when the library walk does, so the ordering
-- can be memoised with the same lifetime, keyed by the sort that produced it.
-- Two exceptions, both here: a filtered call is never memoised (the predicate
-- is a closure, so it cannot be keyed), and a sort that depends on read state
-- is dropped when read state changes, which is what the key's `s:<key>:`
-- shape is for -- Repo.invalidateReadStateCache already matches that shape.
--
-- Usage (from plugin root): lua tests/_test_folder_cover_cache.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local SortEngine = dofile("lib/bookshelf_sort_engine.lua")
local src = io.open("lib/bookshelf_book_repository.lua"):read("*a")

local function extract(name, sig)
    local pat = "\nfunction " .. name:gsub("[%.%(%)%-]", "%%%0") .. sig .. "\n(.-)\nend\n"
    local body = src:match(pat)
    assert(body, name .. " moved or was renamed")
    return body
end

local WALK = {
    "/lib/Folder/zulu.epub",
    "/lib/Folder/alpha.epub",
    "/lib/Folder/mike.epub",
}
local TITLES = {
    ["/lib/Folder/zulu.epub"]  = "Zulu",
    ["/lib/Folder/alpha.epub"] = "Alpha",
    ["/lib/Folder/mike.epub"]  = "Mike",
}

-- One env per scenario, holding the module-level caches the function reads.
local function newEnv()
    local e = { builds = 0, _folder_cover_cache = {}, _folder_cover_cache_order = {} }
    -- The real insertion-order cap is pinned in _test_book_repository; here it
    -- only has to store, so a miss means the memo genuinely missed.
    e._capInsert = function(cache, order, key, value)
        cache[key] = value
        order[#order + 1] = key
    end
    e.Repo = {
        getFolderBookPaths = function()
            local c = {}
            for i, v in ipairs(WALK) do c[i] = v end
            return c
        end,
    }
    e.SortEngine = SortEngine
    e._buildBookMetaLight = function(fp)
        e.builds = e.builds + 1
        return { filepath = fp, title = TITLES[fp] }
    end
    e._lightMetaForFp = function(_, fp) return { filepath = fp, title = TITLES[fp] } end
    e.ipairs, e.pairs, e.table, e.type, e.tostring = ipairs, pairs, table, type, tostring
    local fn = assert(load("return function(path, sort_priority, limit, opts)\n"
        .. extract("Repo.folderCoverPaths", "%(path, sort_priority, limit, opts%)")
        .. "\nend", "folderCoverPaths", "t", e))
    e.call = fn()
    return e
end

local BY_TITLE  = { { key = "title" } }
local BY_OPENED = { { key = "last_opened", reverse = true } }

t.test("the same folder and sort is worked out once, not once per fetch", function()
    local e = newEnv()
    local first  = e.call("/lib/Folder", BY_TITLE, 4, {})
    local after  = e.builds
    local second = e.call("/lib/Folder", BY_TITLE, 4, {})
    eq(e.builds, after, "the second fetch rebuilt the folder's records")
    eq(table.concat(second, ","), table.concat(first, ","), "the memo changed the answer")
end)

t.test("a different sort is a different answer, so a different entry", function()
    local e = newEnv()
    e.call("/lib/Folder", BY_TITLE, 4, {})
    local after = e.builds
    e.call("/lib/Folder", BY_OPENED, 4, {})
    assert(e.builds > after, "a second sort must not be served the first one's order")
end)

t.test("a filtered call is never memoised", function()
    -- opts.match is a compiled closure: nothing in it can go in a key, so a
    -- filtered chip keeps paying, rather than risk fronting a folder with a
    -- book the filter excludes.
    local e = newEnv()
    local yes = function() return true end
    e.call("/lib/Folder", BY_TITLE, 4, { match = yes })
    local after = e.builds
    e.call("/lib/Folder", BY_TITLE, 4, { match = yes })
    assert(e.builds > after, "a filtered call was served from the memo")
end)

t.test("clearing the cache (a fresh walk) brings the work back", function()
    local e = newEnv()
    e.call("/lib/Folder", BY_TITLE, 4, {})
    local after = e.builds
    e._folder_cover_cache = {}
    e.call("/lib/Folder", BY_TITLE, 4, {})
    assert(e.builds > after, "a fresh walk must re-order the folder")
end)

t.test("the memo is per folder, not global", function()
    local e = newEnv()
    e.call("/lib/Folder", BY_TITLE, 4, {})
    local after = e.builds
    e.call("/lib/Other", BY_TITLE, 4, {})
    assert(e.builds > after, "a second folder was served the first folder's order")
end)

t.test("reading a book drops the read-state orders and keeps the rest", function()
    -- Mirrors what Repo.invalidateReadStateCache already does for
    -- _bySource_cache, which is why the key carries `s:<key>:` segments.
    local env = {
        _bySource_cache = {},
        _folder_cover_cache = {
            ["/lib/A\0s:title:f;l:4"]       = { "x" },
            ["/lib/B\0s:last_opened:r;l:4"] = { "y" },
        },
        pairs = pairs, ipairs = ipairs,
        READ_STATE_SORT_TOKENS = { "s:last_opened:", "s:percent_read:",
                                   "s:read_status", "s:rating:" },
    }
    local fn = assert(load(extract("Repo.invalidateReadStateCache", "%(%)"),
        "invalidateReadStateCache", "t", env))
    fn()
    assert(env._folder_cover_cache["/lib/A\0s:title:f;l:4"],
        "a filename/title order cannot change because a book was read")
    eq(env._folder_cover_cache["/lib/B\0s:last_opened:r;l:4"], nil,
        "a last-opened order must be dropped when read state moves")
end)

t.test("both walk-invalidation sites clear the memo", function()
    -- The member list is the input, so the two places that empty
    -- _folder_book_paths_cache must empty this one in the same breath.
    local n_paths, n_cover = 0, 0
    for _ in src:gmatch("_folder_book_paths_cache = {}") do n_paths = n_paths + 1 end
    for _ in src:gmatch("_folder_cover_cache = {}") do n_cover = n_cover + 1 end
    assert(n_cover >= n_paths,
        ("the memo is cleared %d time(s), the member list %d"):format(n_cover, n_paths))
end)

t.done()
