-- tests/_test_calibre_metadata.lua
-- The vendored calibre reader, exercised directly. It was extracted out of
-- bookshelf_book_repository so BOOKENDS can share it byte-identically (#348):
-- both plugins write the same calibre.bookshelf.json harvest, and a subset
-- writer would clobber the other's author_sort and extra_series.
-- Usage: cd into the plugin dir, then `lua tests/_test_calibre_metadata.lua`.

-- KOReader environment, stubbed the way every other suite here does it. Unlike
-- token_semantics this module is NOT pure by design: reading a settings key and
-- stat-ing a file is its whole job, so the environment is stubbed rather than
-- the module made defensive against a KOReader that cannot happen.
_G.G_reader_settings = {
    readSetting = function(_self, key)
        if key == "home_dir" then return "/nonexistent-library" end
        return nil
    end,
}
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function() return nil end,   -- no metadata.calibre anywhere
}

local t = dofile("tests/_helpers.lua").runner()
local CalibreMeta = dofile("lib/calibre_metadata.lua")

t.test("module exposes its contract", function()
    assert(type(CalibreMeta.entryFor) == "function", "entryFor missing")
    assert(type(CalibreMeta.fieldsFor) == "function", "fieldsFor missing")
    assert(type(CalibreMeta.invalidate) == "function", "invalidate missing")
    assert(CalibreMeta.HARVEST_NAME == "calibre.bookshelf.json",
           "harvest filename must not change: renaming orphans every existing "
           .. "harvest file on every device")
end)

-- The gate is the whole reason this is a parameter rather than a settings read:
-- bookshelf passes its beta setting, bookends passes true because its
-- needs("calibre") check already means the file is untouched unless a template
-- names the token.
t.test("a falsy gate returns nil without touching the filesystem", function()
    assert(CalibreMeta.entryFor("/any/path.epub", false) == nil)
    assert(CalibreMeta.entryFor("/any/path.epub", nil) == nil)
    assert(CalibreMeta.fieldsFor("/any/path.epub", false) == nil)
end)

t.test("a missing metadata.calibre yields nil, not an error", function()
    CalibreMeta.invalidate()
    local ok, res = pcall(CalibreMeta.entryFor, "/nonexistent/book.epub", true)
    assert(ok, "entryFor raised: " .. tostring(res))
    assert(res == nil, "expected nil for a library with no metadata.calibre")
end)


-- ── The harvest merge-back, the reason the sidecar exists ──────────────────
--
-- Scenario, found by testing against a real calibre-written file on device:
-- KOReader's wireless sync rewrites metadata.calibre through its slimming
-- parser, which drops user_metadata (every CUSTOM column) and author_sort. The
-- harvest is supposed to put them back. It did so for author_sort and the extra
-- series, but NOT for custom columns on any book that also had a publisher,
-- pubdate or rating - because those three come from TOP-LEVEL keys that survive
-- the strip, so the entry still had a non-empty `calibre` table and an
-- all-or-nothing nil check skipped the restore entirely. That is most real
-- books, and the loss was silent.
--
-- rapidjson is stubbed rather than real here: the logic under test is the
-- merge, not the parse, and the parse is covered on device.
local function withStubbedJson(books, harvest)
    local META = "/lib/metadata.calibre"
    local HARV = "/lib/calibre.bookshelf.json"
    package.loaded["rapidjson"] = {
        load = function(path)
            if path == META then return books end
            if path == HARV then return { version = 1, books = harvest } end
            error("unexpected path " .. tostring(path))
        end,
        dump = function() return true end,
    }
    package.loaded["libs/libkoreader-lfs"] = {
        attributes = function(path, what)
            if path ~= META then return nil end
            if what == "mode" then return "file" end
            return { mode = "file", modification = 12345, size = 2048 }
        end,
    }
    _G.G_reader_settings = {
        readSetting = function(_self, key)
            if key == "home_dir" then return "/lib" end
            return nil
        end,
    }
    package.loaded["lib/calibre_metadata"] = nil
    local M = dofile("lib/calibre_metadata.lua")
    M.invalidate()
    return M
end

-- A KOReader-REWRITTEN file: no user_metadata, no author_sort anywhere, but the
-- standard top-level fields survive.
local STRIPPED = {
    { lpath = "a/Dune.epub", title = "Dune", publisher = "Chilton Books" },
    { lpath = "a/Sparse.epub", title = "Sparse" },
}
local HARVEST = {
    ["a/Dune.epub"]   = { author_sort = "Herbert, Frank",
                          calibre = { mood = "cosy", wordcount = "188000" } },
    ["a/Sparse.epub"] = { author_sort = "Nobody, A",
                          calibre = { mood = "bleak" } },
}

t.test("merge-back restores author_sort after a KOReader rewrite", function()
    local M = withStubbedJson(STRIPPED, HARVEST)
    local e = M.entryFor("/lib/a/Dune.epub", true)
    assert(e, "no entry")
    assert(e.author_sort == "Herbert, Frank",
           "author_sort not restored: " .. tostring(e.author_sort))
end)

t.test("merge-back restores custom columns even when standard fields survived", function()
    local M = withStubbedJson(STRIPPED, HARVEST)
    local f = M.fieldsFor("/lib/a/Dune.epub", true)
    assert(f, "no calibre fields at all")
    assert(f.publisher == "Chilton Books",
           "the surviving standard field was lost: " .. tostring(f.publisher))
    assert(f.mood == "cosy",
           "harvested custom column NOT restored (the bug): mood=" .. tostring(f.mood))
    assert(f.wordcount == "188000",
           "harvested custom column NOT restored: wordcount=" .. tostring(f.wordcount))
end)

t.test("merge-back still works when nothing standard survived", function()
    local M = withStubbedJson(STRIPPED, HARVEST)
    local f = M.fieldsFor("/lib/a/Sparse.epub", true)
    assert(f and f.mood == "bleak",
           "sparse book lost its harvested column: " .. tostring(f and f.mood))
end)

-- ── Numeric custom columns ────────────────────────────────────────────────
-- Asked for on Reddit: a Calibre "Words" column shown on the book detail view.
-- It arrives from JSON as a number and %g -- the obvious formatter -- switches
-- to exponential at a million, so a long book rendered "1.23457e+06" where the
-- user wanted a word count. Whole numbers print in full; genuine fractions
-- must still keep their decimals.
t.test("a whole-number custom column prints in full, not in exponent form", function()
    local books = {
        { lpath = "a/Short.epub", title = "Short",
          user_metadata = { ["#words"] = { datatype = "int", ["#value#"] = 95000 } } },
        { lpath = "a/Long.epub", title = "Long",
          user_metadata = { ["#words"] = { datatype = "int", ["#value#"] = 1234567 } } },
        { lpath = "a/Exact.epub", title = "Exact",
          user_metadata = { ["#words"] = { datatype = "int", ["#value#"] = 1000000 } } },
    }
    local M = withStubbedJson(books, {})
    assert(M.fieldsFor("/lib/a/Short.epub", true).words == "95000",
        "got " .. tostring(M.fieldsFor("/lib/a/Short.epub", true).words))
    -- The two that %g would have mangled.
    assert(M.fieldsFor("/lib/a/Long.epub", true).words == "1234567",
        "a seven-figure count must not go exponential, got "
        .. tostring(M.fieldsFor("/lib/a/Long.epub", true).words))
    assert(M.fieldsFor("/lib/a/Exact.epub", true).words == "1000000",
        "exactly a million is where %g flips, got "
        .. tostring(M.fieldsFor("/lib/a/Exact.epub", true).words))
end)

t.test("a fractional custom column keeps its decimals", function()
    -- The other half: forcing every number through an integer format would
    -- quietly turn a 4.5 rating column into 4 or 5.
    local books = {
        { lpath = "a/Frac.epub", title = "Frac",
          user_metadata = { ["#score"] = { datatype = "float", ["#value#"] = 4.5 } } },
    }
    local M = withStubbedJson(books, {})
    assert(M.fieldsFor("/lib/a/Frac.epub", true).score == "4.5",
        "fraction lost: " .. tostring(M.fieldsFor("/lib/a/Frac.epub", true).score))
end)

t.test("a value present in the file WINS over the harvested one", function()
    local stripped = {
        { lpath = "a/Dune.epub", title = "Dune", publisher = "New Publisher" },
    }
    local harvest = {
        ["a/Dune.epub"] = { calibre = { publisher = "Stale Publisher",
                                        mood = "cosy" } },
    }
    local M = withStubbedJson(stripped, harvest)
    local f = M.fieldsFor("/lib/a/Dune.epub", true)
    assert(f.publisher == "New Publisher",
           "harvest overwrote a live value: " .. tostring(f.publisher))
    assert(f.mood == "cosy", "and the harvested-only key should still arrive")
end)

t.done()
