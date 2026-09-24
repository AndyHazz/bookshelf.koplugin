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
-- Every harvest the module writes during a withStubbedJson run, newest last.
local DUMPS = {}
-- lua-rapidjson decodes JSON null to a sentinel, rapidjson.null, not to nil.
-- A plain table stands in for it: what matters is that it is a truthy non-nil
-- value the module can only recognise by comparing against rapidjson.null.
local NULL = setmetatable({}, { __tostring = function() return "rapidjson.null" end })
local function withStubbedJson(books, harvest, home)
    home = home or "/lib"
    local META = "/lib/metadata.calibre"
    local HARV = "/lib/calibre.bookshelf.json"
    package.loaded["rapidjson"] = {
        load = function(path)
            if path == META then return books end
            if path == HARV then return { version = 1, books = harvest } end
            error("unexpected path " .. tostring(path))
        end,
        null = NULL,
        dump = function(obj, path)
            DUMPS[#DUMPS + 1] = { obj = obj, path = path }
            return true
        end,
    }
    package.loaded["libs/libkoreader-lfs"] = {
        attributes = function(path, what)
            -- POSIX collapses repeated slashes, so a real lfs finds the file
            -- either way. The stub has to, or the test would "pass" by failing
            -- to find the library at all.
            if type(path) == "string" then path = path:gsub("//+", "/") end
            if path ~= META then return nil end
            if what == "mode" then return "file" end
            return { mode = "file", modification = 12345, size = 2048 }
        end,
    }
    _G.G_reader_settings = {
        readSetting = function(_self, key)
            if key == "home_dir" then return home end
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

-- ── issue 372: a home_dir with a trailing slash found nothing ─────────────

t.test("a trailing slash on home_dir still resolves every book", function()
    -- The file is found either way, because POSIX collapses "//". What broke
    -- was the KEY: the library root kept the slash, so every entry went in as
    -- "/lib//a/Dune.epub" while the book's own path is "/lib/a/Dune.epub".
    -- Nothing matched, the harvest sidecar was still written with every column
    -- in it, and the reporter saw a correct-looking file and no data.
    local M = withStubbedJson(STRIPPED, HARVEST, "/lib/")
    local e = M.entryFor("/lib/a/Dune.epub", true)
    assert(e, "a trailing slash on home_dir lost the whole library")
    assert(e.author_sort == "Herbert, Frank", "author_sort: " .. tostring(e.author_sort))
    assert(e.calibre and e.calibre.mood == "cosy", "custom column lost")
end)

t.test("a doubled slash in the CALLER's path resolves too", function()
    -- The other side of the same coin: whoever asks may have built the path
    -- from a joined root of their own.
    local M = withStubbedJson(STRIPPED, HARVEST)
    assert(M.entryFor("/lib//a/Dune.epub", true), "the lookup is not normalised")
end)

t.test("a normal home_dir is unaffected", function()
    local M = withStubbedJson(STRIPPED, HARVEST)
    local e = M.entryFor("/lib/a/Dune.epub", true)
    assert(e and e.calibre and e.calibre.mood == "cosy")
end)

-- ── Harvest carry-forward: never drop a field this writer does not know ────
--
-- Both plugins write calibre.bookshelf.json from their own copy of this file,
-- and users update one plugin without the other. The writer used to rebuild
-- the whole file from the fields IT knew, so an older copy that had any reason
-- to rewrite (a new book, an edited column) dropped every field added after it,
-- for every book - title_sort was the first casualty. Now a field this writer
-- does not recognise is carried forward from the file as it was.
--
-- A calibre-WRITTEN file (has author_sort / user_metadata), so the harvest is
-- rebuilt from it and written.

local function lastHarvest()
    local d = DUMPS[#DUMPS]
    return d and d.obj and d.obj.books
end

t.test("a field this writer does not recognise survives a rewrite", function()
    DUMPS = {}
    local written = {
        -- author_sort changed, so there is a real reason to rewrite
        { lpath = "a/Dune.epub", title = "Dune", author_sort = "Herbert, F." },
    }
    local previous = {
        ["a/Dune.epub"] = { author_sort = "Herbert, Frank", from_the_future = "kept" },
    }
    local M = withStubbedJson(written, previous)
    M.entryFor("/lib/a/Dune.epub", true)
    local h = lastHarvest()
    assert(h, "no harvest was written, so the test proves nothing")
    assert(h["a/Dune.epub"].author_sort == "Herbert, F.", "owned field not updated")
    assert(h["a/Dune.epub"].from_the_future == "kept",
           "an unrecognised field was dropped on rewrite: "
           .. tostring(h["a/Dune.epub"].from_the_future))
end)

t.test("it survives on a book with nothing this writer harvests any more", function()
    DUMPS = {}
    local written = {
        { lpath = "a/Dune.epub", title = "Dune", author_sort = "Herbert, Frank" },
        { lpath = "a/Bare.epub", title = "Bare" },   -- nothing owned to harvest
    }
    local previous = {
        ["a/Dune.epub"] = { author_sort = "Old, Value" },   -- forces a write
        ["a/Bare.epub"] = { from_the_future = "kept" },
    }
    local M = withStubbedJson(written, previous)
    M.entryFor("/lib/a/Dune.epub", true)
    local h = lastHarvest()
    assert(h, "no harvest was written")
    assert(h["a/Bare.epub"] and h["a/Bare.epub"].from_the_future == "kept",
           "a book whose only harvested data is unrecognised lost it")
end)

t.test("a field this writer OWNS is replaced, not carried", function()
    DUMPS = {}
    local written = { { lpath = "a/Dune.epub", title = "Dune", author_sort = "New, A" } }
    local previous = { ["a/Dune.epub"] = { author_sort = "Old, A" } }
    local M = withStubbedJson(written, previous)
    M.entryFor("/lib/a/Dune.epub", true)
    local h = lastHarvest()
    assert(h and h["a/Dune.epub"].author_sort == "New, A",
           "an owned field kept its stale value")
end)

t.test("a book no longer in the library is dropped from the harvest", function()
    DUMPS = {}
    local written = { { lpath = "a/Dune.epub", title = "Dune", author_sort = "Herbert, Frank" } }
    local previous = {
        ["a/Dune.epub"] = { author_sort = "Old, A" },
        ["a/Gone.epub"] = { author_sort = "Removed, A", from_the_future = "x" },
    }
    local M = withStubbedJson(written, previous)
    M.entryFor("/lib/a/Dune.epub", true)
    local h = lastHarvest()
    assert(h, "no harvest was written")
    assert(h["a/Gone.epub"] == nil, "a removed book was kept alive by carry-forward")
end)

t.test("carrying a field forward does not cause a rewrite on its own", function()
    -- Flash wear: the write is skipped when nothing changed. A carried field is
    -- equal by construction, so it must not look like a change every reload.
    DUMPS = {}
    local written = { { lpath = "a/Dune.epub", title = "Dune", author_sort = "Herbert, Frank" } }
    local previous = {
        ["a/Dune.epub"] = { author_sort = "Herbert, Frank", from_the_future = "kept" },
    }
    local M = withStubbedJson(written, previous)
    M.entryFor("/lib/a/Dune.epub", true)
    assert(#DUMPS == 0, "rewrote an unchanged harvest (" .. #DUMPS .. " writes)")
end)

-- ── title_sort, which the harvest claimed to carry and did not ─────────────
--
-- KOReader's wireless sync keeps author_sort but NOT title_sort (its
-- used_metadata list, plugins/calibre.koplugin/metadata.lua), so without the
-- harvest a sync sends bookshelf's title sort back to raw titles.

t.test("title_sort is harvested from a calibre-written file", function()
    DUMPS = {}
    local written = {
        { lpath = "a/Tomb.epub", title = "The Locked Tomb",
          title_sort = "Locked Tomb, The", author_sort = "Muir, Tamsyn" },
    }
    local M = withStubbedJson(written, {})
    M.entryFor("/lib/a/Tomb.epub", true)
    local h = lastHarvest()
    assert(h and h["a/Tomb.epub"], "no harvest entry for the book")
    assert(h["a/Tomb.epub"].title_sort == "Locked Tomb, The",
           "title_sort not harvested: " .. tostring(h["a/Tomb.epub"].title_sort))
end)

t.test("a change to title_sort alone still rewrites the harvest", function()
    DUMPS = {}
    local written = {
        { lpath = "a/Tomb.epub", title = "The Locked Tomb",
          title_sort = "Locked Tomb, The", author_sort = "Muir, Tamsyn" },
    }
    local previous = {
        ["a/Tomb.epub"] = { author_sort = "Muir, Tamsyn", title_sort = "Tomb, The Locked" },
    }
    local M = withStubbedJson(written, previous)
    M.entryFor("/lib/a/Tomb.epub", true)
    local h = lastHarvest()
    assert(h, "a title_sort-only change was not written")
    assert(h["a/Tomb.epub"].title_sort == "Locked Tomb, The", "stale title_sort kept")
end)

t.test("title_sort is restored after a KOReader rewrite", function()
    local stripped = { { lpath = "a/Tomb.epub", title = "The Locked Tomb" } }
    local harvest = { ["a/Tomb.epub"] = { title_sort = "Locked Tomb, The" } }
    local M = withStubbedJson(stripped, harvest)
    local e = M.entryFor("/lib/a/Tomb.epub", true)
    assert(e and e.title_sort == "Locked Tomb, The",
           "title_sort not restored: " .. tostring(e and e.title_sort))
end)

t.test("any harvested field is restored, not only the ones listed here", function()
    -- So the next field added to the harvest needs no change to the restore.
    local stripped = { { lpath = "a/Dune.epub", title = "Dune" } }
    local harvest = { ["a/Dune.epub"] = { from_the_future = "back" } }
    local M = withStubbedJson(stripped, harvest)
    local e = M.entryFor("/lib/a/Dune.epub", true)
    assert(e and e.from_the_future == "back",
           "an unrecognised harvested field was not restored")
end)

t.test("a value present in the file still wins over a restored one", function()
    local stripped = { { lpath = "a/Dune.epub", title = "Dune", author_sort = "Live, A" } }
    local harvest = { ["a/Dune.epub"] = { author_sort = "Harvested, A", from_the_future = "x" } }
    local M = withStubbedJson(stripped, harvest)
    local e = M.entryFor("/lib/a/Dune.epub", true)
    -- author_sort present => this is a calibre-written file, so no restore at
    -- all; either way the live value must be what comes back.
    assert(e and e.author_sort == "Live, A", "harvest overwrote a live value")
end)


-- ── A REAL KOReader rewrite writes nulls, not missing keys ─────────────────
--
-- KOReader's calibre plugin rewrites the file through slim(), which writes every
-- field it keeps as `book[k] or rapidjson.null` - and load_calibre has already
-- dropped author_sort's value, so the rewritten file carries
-- "author_sort": null (confirmed by running CalibreMetadata:init +
-- cleanUnused over a genuine Calibre file). The calibre-written test was
-- author_sort ~= nil, and the decoded null is not nil, so EVERY synced file
-- passed as fresh from Calibre: the restore never ran, and the write path
-- rebuilt the harvest from the stripped file, destroying it. The suite never
-- saw it because its stripped fixtures deleted the keys instead.

local KO_REWRITTEN = {
    { lpath = "a/Tomb.epub", title = "The Locked Tomb", authors = { "Tamsyn Muir" },
      author_sort = NULL, series = NULL, series_index = NULL, size = NULL, tags = {} },
}
local TOMB_HARVEST = {
    ["a/Tomb.epub"] = { author_sort = "Muir, Tamsyn", title_sort = "Locked Tomb, The",
                        calibre = { mood = "cosy" } },
}

t.test("a real KOReader rewrite is recognised as stripped and restored", function()
    local M = withStubbedJson(KO_REWRITTEN, TOMB_HARVEST)
    local e = M.entryFor("/lib/a/Tomb.epub", true)
    assert(e, "no entry")
    assert(e.author_sort == "Muir, Tamsyn",
           "author_sort not restored after a real sync: " .. tostring(e.author_sort))
    assert(e.title_sort == "Locked Tomb, The",
           "title_sort not restored after a real sync: " .. tostring(e.title_sort))
    local f = M.fieldsFor("/lib/a/Tomb.epub", true)
    assert(f and f.mood == "cosy", "custom column not restored after a real sync")
end)

t.test("a real KOReader rewrite does not overwrite the harvest", function()
    DUMPS = {}
    local M = withStubbedJson(KO_REWRITTEN, TOMB_HARVEST)
    M.entryFor("/lib/a/Tomb.epub", true)
    assert(#DUMPS == 0, "the harvest was rewritten from a stripped file - it destroys itself")
end)

t.test("a null in the file never reaches a reader as a value", function()
    local M = withStubbedJson(KO_REWRITTEN, {})
    local e = M.entryFor("/lib/a/Tomb.epub", true)
    assert(e, "no entry")
    assert(e.series == nil, "the null sentinel leaked out as series: " .. tostring(e.series))
    assert(e.author_sort == nil, "the null sentinel leaked out as author_sort")
end)

t.test("a null already saved in a harvest is not restored as a value", function()
    -- The sidecar that the bug left behind on real devices: {author_sort: null}.
    local M = withStubbedJson(KO_REWRITTEN, { ["a/Tomb.epub"] = { author_sort = NULL } })
    local e = M.entryFor("/lib/a/Tomb.epub", true)
    assert(e and e.author_sort == nil, "a saved null was restored: " .. tostring(e and e.author_sort))
end)

t.test("a fresh Calibre file is still trusted wholly, so a cleared column clears", function()
    -- The reason detection exists: a column the user emptied in Calibre must
    -- not be brought back from the harvest.
    local fresh = { { lpath = "a/Tomb.epub", title = "The Locked Tomb", author_sort = "Muir, Tamsyn" } }
    local M = withStubbedJson(fresh, TOMB_HARVEST)
    local f = M.fieldsFor("/lib/a/Tomb.epub", true)
    assert(not (f and f.mood), "a column cleared in Calibre came back from the harvest")
end)


t.done()
