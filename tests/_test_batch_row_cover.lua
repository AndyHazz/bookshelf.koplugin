-- tests/_test_batch_row_cover.lua
-- Issue 451: covers that came back on Refresh metadata and vanished on the
-- next page. buildBookMeta's no-cover path takes the text row from the
-- batched BIM rows, which are a snapshot; a row captured before the cover was
-- extracted says "no cover", and a record built from it draws the
-- placeholder. A cover in the scaled-cover cache proves such a row is out of
-- date, so buildBookMeta must ask BIM live then -- and only then, so books
-- that really have no cover keep the fast path.
--
-- Stubs lifted from _test_lightmeta_lazy.lua.
--[[ original header follows ]]
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


local BOOKS = { "/home/stale.epub", "/home/nocover.epub", "/home/cover.epub" }
-- What the snapshot says (captured before stale.epub's cover was extracted)...
local BATCH_HAS_COVER = { ["/home/stale.epub"] = nil, ["/home/nocover.epub"] = nil,
                          ["/home/cover.epub"] = "Y" }
-- ...and what BIM says now.
local LIVE_HAS_COVER = { ["/home/stale.epub"] = "Y", ["/home/nocover.epub"] = nil,
                         ["/home/cover.epub"] = "Y" }

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

local live_reads = {}
package.loaded["bookinfomanager"] = {
    openDbConnection = function(self)
        self.db_conn = self.db_conn or {
            exec = function(_self, _sql)
                local cols = {}
                for c = 1, 15 do cols[c] = {} end
                for i, fp in ipairs(BOOKS) do
                    cols[1][i], cols[2][i] = "/home/", fp:match("([^/]+)$")
                    cols[3][i] = "Title " .. i
                    cols[11][i] = "Y"                    -- has_meta
                    cols[12][i] = BATCH_HAS_COVER[fp]    -- has_cover
                end
                return cols
            end,
        }
        return self.db_conn
    end,
    getBookInfo = function(_self, fp)
        live_reads[fp] = (live_reads[fp] or 0) + 1
        return { title = "Live " .. fp, has_meta = "Y", has_cover = LIVE_HAS_COVER[fp] }
    end,
}

local cached = {}
package.loaded["lib/bookshelf_scaled_cover_cache"] = {
    has = function(_self, fp) return cached[fp] == true end,
    get = function() return nil end,
    drop = function() end,
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

local function build(fp)
    live_reads = {}
    return Repo.buildBookMeta(fp, { want_cover = false })
end

t.test("a cached cover overrules a snapshot row that says no cover", function()
    cached = { ["/home/stale.epub"] = true }
    local rec = build("/home/stale.epub")
    assert(rec and rec.has_cover, "record drew the placeholder: has_cover=" .. tostring(rec and rec.has_cover))
    assert((live_reads["/home/stale.epub"] or 0) == 1, "expected one live read")
end)

t.test("a book with no cover and nothing cached stays on the batch row", function()
    cached = {}
    local rec = build("/home/nocover.epub")
    assert(rec and not rec.has_cover)
    assert(not live_reads["/home/nocover.epub"], "fast path lost: a live read for a coverless book")
end)

t.test("a batch row that already has the cover needs no live read", function()
    cached = { ["/home/cover.epub"] = true }
    local rec = build("/home/cover.epub")
    assert(rec and rec.has_cover)
    assert(not live_reads["/home/cover.epub"], "live read for a row that was right")
end)

t.done()
