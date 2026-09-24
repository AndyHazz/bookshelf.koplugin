-- tests/_test_calibre_page_column.lua
-- Issue 405: the page-count scan can take counts from a Calibre custom
-- column (the Count Pages plugin's #pages). Pins which column is found and
-- what a book's count reads as. Stubs lifted from _test_lightmeta_lazy.lua,
-- whose header follows.
--
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
local FIELDS = {}
package.loaded["lib/calibre_metadata"] = {
    entryFor   = function() derivations = derivations + 1; return nil end,
    fieldsFor  = function(fp, enabled) if enabled then return FIELDS[fp] end end,
    invalidate = function() end,
}


local BOOKS = { "/home/a.epub", "/home/b.epub", "/home/c.epub" }
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
        return { mode = fp == "/home" and "directory" or "file", modification = 100, size = 10 }
    end,
}
package.loaded["bookinfomanager"] = {
    getBookInfo = function(_self, fp) return { title = fp, has_meta = "Y" } end,
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
    nilOrTrue = function(key) local v = _store["bookshelf_" .. key]; return v == nil or v == true end,
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
local eq = helpers.eq

t.test("nothing is read while the Calibre setting is off", function()
    FIELDS = { ["/home/a.epub"] = { pages = "300" } }
    _store.bookshelf_calibre_metadata = nil
    eq(Repo.calibrePageColumn(), nil)
    eq(Repo.calibrePagesFor("/home/a.epub", "pages"), nil)
end)

t.test("#pages is found and read", function()
    _store.bookshelf_calibre_metadata = true
    FIELDS = { ["/home/a.epub"] = { pages = "300" }, ["/home/b.epub"] = { pages = "412.0" } }
    local key, n = Repo.calibrePageColumn()
    eq(key, "pages"); eq(n, 2)
    eq(Repo.calibrePagesFor("/home/a.epub", "pages"), 300)
    eq(Repo.calibrePagesFor("/home/b.epub", "pages"), 412)
    eq(Repo.calibrePagesFor("/home/c.epub", "pages"), nil)
end)

t.test("pages wins over another page column; else the fullest one", function()
    FIELDS = { ["/home/a.epub"] = { pages = "300", pagecount = "310" },
               ["/home/b.epub"] = { pagecount = "200" } }
    eq((Repo.calibrePageColumn()), "pages")
    FIELDS = { ["/home/a.epub"] = { page_est = "300", pagecount = "310" },
               ["/home/b.epub"] = { pagecount = "200" } }
    eq((Repo.calibrePageColumn()), "pagecount")
end)

t.test("non-numbers, zero and unrelated columns are no column", function()
    FIELDS = { ["/home/a.epub"] = { pages = "lots", words = "90000" },
               ["/home/b.epub"] = { pages = "0" } }
    eq(Repo.calibrePageColumn(), nil)
end)

t.test("a Calibre count is a scan count that is shown, and trusted by the next scan", function()
    local src = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")
    local scan  = src:match("local SCAN_TAGS%s*=%s*(%b{})")
    local shown = src:match("local SHOWN_TAGS%s*=%s*(%b{})")
    assert(scan and scan:find("calibre = true", 1, true), "SCAN_TAGS lacks calibre")
    assert(shown and shown:find("calibre = true", 1, true), "SHOWN_TAGS lacks calibre")
    local main = io.open("main.lua"):read("*a")
    assert(main:find('psrc == "calibre"', 1, true), "scanPageCounts would recount Calibre books every run")
end)

t.done()
