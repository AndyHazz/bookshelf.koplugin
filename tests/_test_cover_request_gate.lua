
-- After the lib/ reorg, internal requires resolve as "lib/bookshelf_X".
-- Add the plugin root to package.path so `require("lib/bookshelf_X")`
-- finds the file at <plugin_root>/lib/bookshelf_X.lua.
package.path = "./?.lua;./?/init.lua;" .. package.path

-- Hardcover's enrichment/ratings caches are SQLite-backed (v2.4.2+); install
-- the in-memory cache fake BEFORE any module that loads bookshelf_hardcover, so
-- buildBookMeta/getAll enrichment reads exercise the real cache paths.
local hccache = dofile("tests/_helpers.lua").install_hardcover_cache_fake()

-- Hardcover.enrichBook/applyMetadata only run when the plugin is live, i.e.
-- Hardcover.isAvailable() -- which pcall-requires the external plugin's API
-- module (absent in CI). Stub it (with a query fn, memoised true on first call)
-- BEFORE bookshelf_hardcover is first required, so the enrichment tests below
-- exercise the plugin-present path. Without this the availability gate (v3.8.8)
-- suppresses all enrichment and the description/cover assertions fail.
package.loaded["hardcover/lib/hardcover_api"] = { query = function() return nil end }

package.loaded["readhistory"] = { hist = {} }
package.loaded["readcollection"] = { coll = { favorites = {} }, default_collection_name = "favorites" }
package.loaded["bookinfomanager"] = {
    getBookInfo = function(_self, fp, _with_cover)
        return _G._test_bim_data and _G._test_bim_data[fp] or nil
    end,
}
package.loaded["docsettings"] = {
    open = function(_self, fp)
        return setmetatable({}, { __index = function(_, k)
            if k == "readSetting" then return function(_, key)
                return _G._test_docsettings_data and _G._test_docsettings_data[fp]
                    and _G._test_docsettings_data[fp][key]
            end end
        end })
    end,
    -- enrichBook's use_cover path looks for a custom .sdr cover; none in tests,
    -- so it falls back to the cached download path.
    findCustomCoverFile = function() return nil end,
    -- KOReader resolves the sidecar wherever the "Book metadata location"
    -- setting puts it (alongside the book, a central dir, or by hash). A book
    -- has a sidecar iff we set up DocSettings data for it -- independent of any
    -- sibling .sdr the lfs stub reports. Models the "dir"/"hash" case (#117).
    hasSidecarFile = function(_self, fp)
        return _G._test_docsettings_data and _G._test_docsettings_data[fp] ~= nil or false
    end,
}
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(fp, key)
        if key == "modification" then
            return _G._test_mtime and _G._test_mtime[fp] or 0
        end
    end,
}
package.loaded["logger"] = { dbg = function() end, info = function() end, warn = function() end, err = function() end }

-- ISO language name lookup used by bookshelf_lang (required by the repo at
-- load). 3-letter code -> English name, with the real module's code fallback.
package.loaded["ui/data/isolanguage"] = {
    getLocalizedLanguage = function(_self, iso3)
        local N = { eng = "English", deu = "German", fra = "French",
                    jpn = "Japanese", spa = "Spanish", zho = "Chinese" }
        return N[iso3] or iso3
    end,
}

-- BookshelfSettings stub: reads from the same _test_settings table as
-- the G_reader_settings stub, but transparently re-prefixes keys with
-- "bookshelf_". Lets existing tests keep using bookshelf_X keys in
-- _test_settings while production code reads short keys via the store.
local _store_generation = 1
package.loaded["lib/bookshelf_settings_store"] = {
    read   = function(key, default)
        local v = _G._test_settings and _G._test_settings["bookshelf_" .. key]
        if v == nil then return default end
        return v
    end,
    save   = function(key, value)
        _G._test_settings = _G._test_settings or {}
        _G._test_settings["bookshelf_" .. key] = value
        _store_generation = _store_generation + 1
    end,
    delete = function(key)
        if _G._test_settings then _G._test_settings["bookshelf_" .. key] = nil end
        _store_generation = _store_generation + 1
    end,
    flush  = function() end,
    generation = function() return _store_generation end,
    isTrue = function(key)
        return _G._test_settings and _G._test_settings["bookshelf_" .. key] == true
    end,
    nilOrTrue = function(key)
        if not _G._test_settings then return true end
        local v = _G._test_settings["bookshelf_" .. key]
        return v == nil or v == true
    end,
}
_G.G_reader_settings = setmetatable({}, {
    __index = function(_, k)
        if k == "readSetting" then
            return function(_, key)
                return _G._test_settings and _G._test_settings[key]
            end
        end
        if k == "isTrue" then
            return function(_, key)
                return _G._test_settings and _G._test_settings[key] == true
            end
        end
        return nil
    end,
})


-- ── the bit this suite is about ─────────────────────────────────────────────
-- buildBookMeta's most expensive call is BIM's getBookInfo with a cover: the
-- SELECT drags the compressed blob off disk and zstd-decompresses it. When
-- ScaledCoverCache already holds the scaled cover, SpineWidget paints from
-- that and frees the decoded bb unread, so the whole call was wasted.
--
-- Callers with opts.lazy_cover already pass want_cover=false in that case, but
-- not every route does. These tests pin the gate that sits at the point of
-- use, where a forgetful caller cannot get past it.

package.loaded["datastorage"] = {
    getDataDir     = function() return "/tmp/bookshelf-covergate-test" end,
    getSettingsDir = function() return "/tmp/bookshelf-covergate-test" end,
}

-- Record what BIM was actually asked for.
local asked = {}
package.loaded["bookinfomanager"] = {
    getBookInfo = function(_self, fp, with_cover)
        asked[#asked + 1] = { fp = fp, cover = with_cover and true or false }
        return _G._test_bim_data and _G._test_bim_data[fp] or nil
    end,
}

-- A ScaledCoverCache whose contents the test controls. Loaded before the repo
-- so the repo's require picks this up.
local cached = {}
package.loaded["lib/bookshelf_scaled_cover_cache"] = {
    has = function(_self, fp) return cached[fp] == true end,
    get = function() return nil end,
    put = function(_self, _fp, bb) return bb end,
    drop = function() end,
    clear = function() end,
}

local Repo = dofile("lib/bookshelf_book_repository.lua")
local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()

local FP = "/home/b.epub"

local function setup()
    asked = {}
    cached = {}
    _G._test_settings = { home_dir = "/home" }
    _G._test_bim_data = {
        [FP] = { title = "B", authors = "A", has_meta = true, has_cover = true },
    }
end

local function lastAsk() return asked[#asked] end

t.test("no cover is requested when the scaled cover is already cached", function()
    setup()
    cached[FP] = true
    Repo.buildBookMeta(FP)
    assert(lastAsk(), "BIM was not consulted at all")
    assert(lastAsk().cover == false,
        "asked BIM to decode a cover that was already scaled and cached")
end)

t.test("a cover IS requested when nothing is cached", function()
    setup()
    -- The negative control. Without it the test above passes for a build that
    -- never asks for a cover at all, which would break every uncached book.
    Repo.buildBookMeta(FP)
    assert(lastAsk(), "BIM was not consulted at all")
    assert(lastAsk().cover == true,
        "an uncached cover was never fetched -- the book would render blank")
end)

t.test("an explicit want_cover=false is still honoured", function()
    setup()
    Repo.buildBookMeta(FP, { want_cover = false })
    assert(lastAsk().cover == false, "the caller's own opt-out was ignored")
end)

t.test("the record is still built when the cover is skipped", function()
    setup()
    cached[FP] = true
    local book = Repo.buildBookMeta(FP)
    assert(book, "no record came back")
    assert(book.title == "B", "metadata was lost along with the cover")
    assert(book.filepath == FP, "the record lost its filepath")
end)

t.done()
