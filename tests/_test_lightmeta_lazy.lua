-- tests/_test_lightmeta_lazy.lua
-- The light-meta map holds a record for every book BIM knows about under
-- home_dir. Deriving one is not free -- Calibre lookup, author split, a stat
-- for a custom_metadata sidecar -- and the cost scales with the SIZE OF THE
-- LIBRARY rather than with what is on screen.
--
-- Two things make that proportional to what is actually used: the map builds
-- records on demand, and predicates that can be answered from the filepath
-- alone are asked before a record exists. Neither is observable from a return
-- value, so these tests count the derivations instead, via the Calibre lookup
-- that happens exactly once per record built.

package.path = "./?.lua;./?/init.lua;" .. package.path

local hccache = dofile("tests/_helpers.lua").install_hardcover_cache_fake()
package.loaded["hardcover/lib/hardcover_api"] = { query = function() return nil end }
package.loaded["readhistory"] = { hist = {} }
-- A collection with two members out of forty: membership is answerable from
-- the filepath, so only those two should ever be derived.
package.loaded["readcollection"] = {
    coll = {
        favorites = {},
        shortlist = {
            ["/home/b03.epub"] = { file = "/home/b03.epub" },
            ["/home/b07.epub"] = { file = "/home/b07.epub" },
        },
    },
    default_collection_name = "favorites",
}
package.loaded["logger"] = { dbg = function() end, info = function() end,
                             warn = function() end, err = function() end }
package.loaded["ui/data/isolanguage"] = {
    getLocalizedLanguage = function(_s, iso3) return iso3 end,
}
package.loaded["docsettings"] = {
    open = function() return { readSetting = function() return nil end } end,
    hasSidecarFile = function() return false end,
    findCustomCoverFile = function() return nil end,
    findCustomMetadataFile = function() return nil end,
}
package.loaded["datastorage"] = {
    getDataDir     = function() return "/tmp/bookshelf-lazy-test" end,
    getSettingsDir = function() return "/tmp/bookshelf-lazy-test" end,
}
-- No persistence in this suite: each dofile of the repo starts clean.
package.loaded["persist"] = {
    new = function() return { load = function() return nil end,
                              save = function() return true end,
                              delete = function() return true end } end,
}

-- ONE Calibre lookup happens per light record derived, so this counter is a
-- direct count of derivations.
local derivations = 0
package.loaded["lib/calibre_metadata"] = {
    entryFor   = function() derivations = derivations + 1; return nil end,
    fieldsFor  = function() return nil end,
    invalidate = function() end,
}

local BOOKS = {}
for i = 1, 40 do BOOKS[i] = string.format("/home/b%02d.epub", i) end

package.loaded["libs/libkoreader-lfs"] = {
    dir = function(path)
        local names = { ".", ".." }
        if path == "/home" then
            for i = 1, #BOOKS do names[#names + 1] = BOOKS[i]:match("([^/]+)$") end
        end
        local i = 0
        return function() i = i + 1; return names[i] end
    end,
    attributes = function(fp, key)
        if key == "mode" then return fp == "/home" and "directory" or "file" end
        if key == "modification" then return 100 end
        if key == "size" then return 10 end
        return { mode = fp == "/home" and "directory" or "file",
                 modification = 100, size = 10 }
    end,
}

-- BIM with the BATCH read the light map really uses, so the lazy map is
-- exercised rather than bypassed.
package.loaded["bookinfomanager"] = {
    openDbConnection = function(self)
        self.db_conn = self.db_conn or {
            exec = function(_self, _sql)
                local dirs, files, titles = {}, {}, {}
                for i, fp in ipairs(BOOKS) do
                    dirs[i], files[i] = "/home/", fp:match("([^/]+)$")
                    titles[i] = "Book " .. i
                end
                local empty = {}
                for i = 1, #BOOKS do empty[i] = nil end
                return { dirs, files, titles, empty, empty, empty, empty, empty }
            end,
        }
        return self.db_conn
    end,
    getBookInfo = function(_self, fp)
        return { title = fp:match("([^/]+)$"), has_meta = true }
    end,
}

local _store = {}
package.loaded["lib/bookshelf_settings_store"] = {
    read = function(key, default)
        local v = _store["bookshelf_" .. key]
        if v == nil then return default end
        return v
    end,
    save = function(key, v) _store["bookshelf_" .. key] = v end,
    delete = function(key) _store["bookshelf_" .. key] = nil end,
    flush = function() end,
    generation = function() return 1 end,
    isTrue = function(key) return _store["bookshelf_" .. key] == true end,
    nilOrTrue = function(key)
        local v = _store["bookshelf_" .. key]
        return v == nil or v == true
    end,
    genreSource = function() return nil end,
}
_G.G_reader_settings = setmetatable({}, { __index = function(_, k)
    if k == "readSetting" then
        return function(_, key) if key == "home_dir" then return "/home" end end
    end
    if k == "isTrue" then return function() return false end end
end })

local Repo = dofile("lib/bookshelf_book_repository.lua")
local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()

t.test("a collection chip derives records only for its members", function()
    derivations = 0
    Repo.invalidateWalkCache()
    -- "is it in this collection" is answerable from the filepath alone, so the
    -- other 38 books must never be derived. Deriving the whole library to
    -- return two rows is the cost this exists to remove, and it grows with the
    -- library rather than with the page.
    local out = Repo.getBySource({ kind = "collection", id = "shortlist" },
                                 nil, nil, 0, 10)
    assert(type(out) == "table", "no result")
    -- Generous ceiling: the two members, plus the page slice rebuilding them
    -- through buildBookMeta, plus a little slack. Anything near 40 means every
    -- book in the library was derived to find two.
    assert(derivations <= 10,
        "derived " .. derivations .. " records to return a 2-book collection")
end)

t.test("the map derives nothing until something asks for a book", function()
    derivations = 0
    Repo.invalidateWalkCache()
    -- Building the map itself must cost nothing beyond the batch read.
    local paths = Repo.getAllFilepaths()
    assert(#paths == #BOOKS, "the walk did not see the library: " .. #paths)
    assert(derivations == 0,
        "walking the library derived " .. derivations .. " records nobody asked for")
end)

t.test("a predicate that needs real fields still sees every book", function()
    derivations = 0
    Repo.invalidateWalkCache()
    -- The other half of the contract. A genre predicate cannot be answered
    -- from a filepath, so laziness must not hide books from it: every book
    -- still has to be derived and offered to the predicate, or chips like
    -- Genres and Authors would silently lose their contents.
    local out = Repo.getBySource({ kind = "genre", id = "Nonexistent" }, nil, nil, 0, 10)
    -- And the predicate's answer must still be USED: no book carries this
    -- genre, so a chip that returns rows anyway has stopped filtering.
    assert(type(out) == "table" and #out == 0,
        "a genre no book has matched " .. #(out or {}) .. " books")
    assert(derivations >= #BOOKS,
        "only " .. derivations .. " of " .. #BOOKS
        .. " books were offered to a field-reading predicate")
end)

t.done()
