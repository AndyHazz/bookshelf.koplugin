-- tests/_test_book_repository.lua
-- Pure-Lua integration-style tests for book_repository.lua with stubbed KOReader modules.
-- Usage: cd into the plugin dir, then `lua tests/_test_book_repository.lua`.

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

local Repo = dofile("lib/bookshelf_book_repository.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end

-- ============================================================================
-- Task 2.1: smoke + getCurrent
-- ============================================================================

test("smoke: Repo loads", function() assert(type(Repo) == "table") end)

test("getCurrent: returns nil when no lastfile in settings", function()
    _G._test_settings = nil
    local b = Repo.getCurrent()
    assert(b == nil, "expected nil, got " .. tostring(b))
end)

test("getCurrent: returns a book when lastfile is set", function()
    _G._test_settings = { lastfile = "/books/dune.epub" }
    _G._test_bim_data = {
        ["/books/dune.epub"] = {
            title = "Dune",
            authors = "Frank Herbert",
            series = "Dune #1",
            pages = 688,
        }
    }
    _G._test_docsettings_data = {
        ["/books/dune.epub"] = {
            last_page = 142,
            percent_finished = 0.206,
        }
    }
    local b = Repo.getCurrent()
    assert(b ~= nil, "expected a book record")
    assert(b.title == "Dune", "expected title=Dune got " .. tostring(b.title))
    assert(b.author == "Frank Herbert", "expected author got " .. tostring(b.author))
    assert(b.series_name == "Dune", "expected series_name=Dune got " .. tostring(b.series_name))
    assert(b.series_num == "1", "expected series_num=1 got " .. tostring(b.series_num))
    assert(b.page_num == 142, "expected page_num=142 got " .. tostring(b.page_num))
    assert(b.page_count == 688, "expected page_count=688 got " .. tostring(b.page_count))
    assert(b.format == "EPUB", "expected format=EPUB got " .. tostring(b.format))
    assert(b.filename == "dune", "expected filename=dune got " .. tostring(b.filename))
end)

-- ============================================================================
-- Task 2.2: getRecent (already committed)
-- ============================================================================

test("getRecent: orders by ReadHistory.hist time desc, caps at limit", function()
    package.loaded["readhistory"].hist = {
        { file = "/a.epub", time = 300 },
        { file = "/b.epub", time = 200 },
        { file = "/c.epub", time = 100 },
    }
    _G._test_bim_data = {
        ["/a.epub"] = { title = "A" },
        ["/b.epub"] = { title = "B" },
        ["/c.epub"] = { title = "C" },
    }
    local recent = Repo.getRecent(2)
    assert(#recent == 2, "got " .. #recent)
    assert(recent[1].title == "A")
    assert(recent[2].title == "B")
end)

-- ============================================================================
-- Task 2.3: getLatest
-- ============================================================================

test("getRecent: an entry that fails to build does not inflate the total", function()
    -- Counting before the metadata build let a nil-building entry (OPDS
    -- pseudo-path, vanished file) claim a slot in the total without adding
    -- a row - the chip's pagination then promised pages it could not fill.
    package.loaded["readhistory"].hist = {
        { file = "/lib/real1.epub",          time = 300 },
        { file = "OPDS://server/ghost",       time = 200 },
        { file = "/lib/real2.epub",          time = 100 },
    }
    _G._test_bim_data = {
        ["/lib/real1.epub"] = { title = "Real One" },
        ["/lib/real2.epub"] = { title = "Real Two" },
    }
    local out, total = Repo.getRecent(10, 0)
    assert(#out == 2, "expected 2 rendered rows, got " .. #out)
    assert(total == 2, "the ghost must not count: total " .. tostring(total))
end)

test("getLatest: orders by mtime desc, respects limit and depth", function()
    Repo.invalidateWalkCache()
    -- Stub a tiny directory walk via the lfs mock above.
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files
        if path == "/home" then files = { ".", "..", "old.epub", "new.epub", "sub" }
        elseif path == "/home/sub" then files = { ".", "..", "deep.epub" }
        else files = {} end
        local i = 0
        return function() i = i + 1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(fp, key)
        local times = { ["/home/old.epub"] = 100, ["/home/new.epub"] = 500, ["/home/sub/deep.epub"] = 300 }
        local modes = { ["/home/sub"] = "directory" }
        if key == "modification" then return times[fp] or 0
        elseif key == "mode" then return modes[fp] or "file" end
    end
    _G._test_settings = { home_dir = "/home", bookshelf_latest_walk_depth = 3 }
    _G._test_bim_data = {
        ["/home/old.epub"]      = { title = "Old" },
        ["/home/new.epub"]      = { title = "New" },
        ["/home/sub/deep.epub"] = { title = "Deep" },
    }
    local latest = Repo.getLatest(3)
    assert(#latest == 3, "got " .. #latest)
    assert(latest[1].title == "New")
    assert(latest[2].title == "Deep")
    assert(latest[3].title == "Old")
end)

test("getLatest: recognises fb2.zip, ignores images and bare archives", function()
    -- #118: compound ".fb2.zip" must be treated as a book (KOReader reads it),
    -- while a bare ".zip" archive and image sidecars must NOT appear as books.
    Repo.invalidateWalkCache()
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = (path == "/home") and {
            ".", "..",
            "story.fb2.zip",   -- compound book -> include
            "novel.epub",      -- include
            "scan.djv",        -- DjVu variant -> include
            "cover.jpg",       -- image -> exclude
            "art.png",         -- image -> exclude
            "backup.zip",      -- bare archive -> exclude
            "notes.py",        -- script -> exclude
        } or {}
        local i = 0
        return function() i = i + 1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(_fp, key)
        if key == "mode" then return "file" end
        return 0
    end
    _G._test_settings = { home_dir = "/home", bookshelf_latest_walk_depth = 1 }
    _G._test_bim_data = {
        ["/home/story.fb2.zip"] = { title = "Story" },
        ["/home/novel.epub"]    = { title = "Novel" },
        ["/home/scan.djv"]      = { title = "Scan" },
    }
    local latest = Repo.getLatest(20)
    local titles = {}
    for _i, b in ipairs(latest) do titles[b.title] = true end
    assert(#latest == 3, "expected 3 books (fb2.zip, epub, djv), got " .. #latest)
    assert(titles["Story"] and titles["Novel"] and titles["Scan"],
        "expected Story + Novel + Scan to be listed")
end)

test("getBySource: fb2.zip groups under the FB2 format card with plain fb2", function()
    Repo.invalidateWalkCache()
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 1 }
    _G._test_bim_data = {
        ["/lib/zipped.fb2.zip"] = { title = "Zipped" },
        ["/lib/plain.fb2"]      = { title = "Plain" },
        ["/lib/other.epub"]     = { title = "Other" },
    }
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = (path == "/lib")
            and { ".", "..", "zipped.fb2.zip", "plain.fb2", "other.epub" } or {}
        local i = 0; return function() i = i + 1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(_fp, key)
        if key == "mode" then return "file" end
        return 0
    end
    local list, total = Repo.getBySource({ kind = "format", id = "fb2" }, nil, nil, 0, 10)
    Repo.invalidateWalkCache()
    assert(total == 2, "expected 2 FB2 books (plain + zipped), got " .. tostring(total))
end)

test("folder labels flip a calibre-style trailing article (#341)", function()
    -- "Locked Tomb, The" on disk displays as "The Locked Tomb"; sort still
    -- keys off the on-disk name (that IS the article-insensitive ordering
    -- the naming convention buys). Author-ish names stay untouched.
    Repo.invalidateWalkCache()
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 3 }
    _G._test_bim_data = {
        ["/lib/Locked Tomb, The/g1.epub"] = { title = "Gideon" },
        ["/lib/Osman, Richard/t1.epub"]   = { title = "Thursday" },
    }
    local lfs_stub = package.loaded["libs/libkoreader-lfs"]
    local prev_dir, prev_attributes = lfs_stub.dir, lfs_stub.attributes
    local DIRS = { ["/lib/Locked Tomb, The"] = true, ["/lib/Osman, Richard"] = true }
    local LISTING = {
        ["/lib"] = { ".", "..", "Locked Tomb, The", "Osman, Richard" },
        ["/lib/Locked Tomb, The"] = { ".", "..", "g1.epub" },
        ["/lib/Osman, Richard"]   = { ".", "..", "t1.epub" },
    }
    lfs_stub.dir = function(path)
        local files = LISTING[path] or {}
        local i = 0; return function() i = i + 1; return files[i] end
    end
    lfs_stub.attributes = function(fp, key)
        local mode = DIRS[fp] and "directory" or "file"
        if key == "mode" then return mode end
        if key == "modification" then return 0 end
        if key == nil then return { mode = mode, modification = 0, size = 9 } end
    end

    local items = Repo.getAll(nil, 10, 0)
    local labels = {}
    for _i, it in ipairs(items or {}) do
        if it.kind == "folder" then labels[#labels + 1] = it.label end
    end
    local joined = table.concat(labels, " | ")
    assert(joined:find("The Locked Tomb", 1, true),
        "trailing ', The' must flip to the front, got: " .. joined)
    assert(joined:find("Osman, Richard", 1, true),
        "an author-style name must stay untouched, got: " .. joined)

    lfs_stub.dir, lfs_stub.attributes = prev_dir, prev_attributes
    _G._test_settings = {}
    Repo.invalidateWalkCache()
end)

test("getBySource: a specific-author chip matches whatever the name format (#347)",
function()
    -- The chip's id is the author CARD's display name, which follows the
    -- "Author name formatting" setting - under "Surname, First name" that is
    -- "Osman, Richard" while every book stores "Richard Osman". The predicate
    -- must canonicalise both sides, or the chip is empty in exactly that
    -- setting (the reporter's family-wide repro).
    Repo.invalidateWalkCache()
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 1 }
    _G._test_bim_data = {
        ["/lib/thursday.epub"] = { title = "The Thursday Murder Club",
                                   authors = "Richard Osman" },
        ["/lib/other.epub"]    = { title = "Other", authors = "Ann Leckie" },
    }
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = (path == "/lib")
            and { ".", "..", "thursday.epub", "other.epub" } or {}
        local i = 0; return function() i = i + 1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(_fp, key)
        if key == "mode" then return "file" end
        return 0
    end
    -- The failing form: chip created while the display setting was
    -- "Surname, First name".
    local _list, total = Repo.getBySource(
        { kind = "author", id = "Osman, Richard" }, nil, nil, 0, 10)
    assert(total == 1,
        "a last_first-formatted chip id must still match, got " .. tostring(total))
    -- The raw form keeps working.
    local _list2, total2 = Repo.getBySource(
        { kind = "author", id = "Richard Osman" }, nil, nil, 0, 10)
    assert(total2 == 1,
        "the raw-name chip id must keep matching, got " .. tostring(total2))
    Repo.invalidateWalkCache()
end)

-- ============================================================================
-- Task 2.4: getFavorites + getSeriesGroups
-- ============================================================================

test("getFavorites: pulls from ReadCollection.coll.favorites", function()
    -- favorites default sort is "updated" (by collection `order`, newest
    -- favourited first); attr.access is only used by the date_added key.
    package.loaded["readcollection"].coll = {
        favorites = {
            ["/a.epub"] = { file = "/a.epub", order = 1, attr = { access = 200 } },
            ["/b.epub"] = { file = "/b.epub", order = 2, attr = { access = 300 } },
        }
    }
    _G._test_bim_data = {
        ["/a.epub"] = { title = "A" },
        ["/b.epub"] = { title = "B" },
    }
    local favs = Repo.getFavorites(10)
    assert(#favs == 2)
    assert(favs[1].title == "B", "expected B (most recently favourited) first")
end)

test("getSeriesGroups: groups books by series_name, sorts by latest activity", function()
    Repo.invalidateWalkCache()
    package.loaded["readhistory"].hist = {
        { file = "/lib/dune.epub", time = 500 },
        { file = "/lib/foundation1.epub", time = 400 },
        { file = "/lib/foundation2.epub", time = 450 },
        { file = "/lib/standalone.epub", time = 100 },
    }
    _G._test_bim_data = {
        ["/lib/dune.epub"]        = { title = "Dune", series = "Dune #1" },
        ["/lib/foundation1.epub"] = { title = "Foundation", series = "Foundation #1" },
        ["/lib/foundation2.epub"] = { title = "Foundation and Empire", series = "Foundation #2" },
        ["/lib/standalone.epub"]  = { title = "Standalone" },
    }
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 1 }
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = (path == "/lib")
            and { ".", "..", "dune.epub", "foundation1.epub", "foundation2.epub", "standalone.epub" }
            or {}
        local i = 0
        return function() i = i + 1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(_fp, key)
        if key == "mode" then return "file" end
        if key == "modification" then return 0 end
    end
    local groups = Repo.getSeriesGroups(10)
    -- Standalone should NOT appear (no series).
    assert(#groups == 2, "expected 2 series groups, got " .. #groups)
    -- Dune is most recently active (time=500).
    assert(groups[1].series_name == "Dune")
    assert(groups[2].series_name == "Foundation")
    -- Foundation has 2 books; ensure ordered by series_num.
    assert(#groups[2].books == 2)
    -- hydrateSeriesShape fully hydrates only books[1] (the visible spine
    -- cover); subsequent books are filepath stubs since the drill-down
    -- view re-hydrates per-book. Verify ordering by filepath here, not
    -- title.
    assert(groups[2].books[1].title == "Foundation")
    assert(groups[2].books[2].filepath == "/lib/foundation2.epub")
end)

-- issue #299: a Calibre custom series column puts the book in BOTH stacks.
-- The secondary series can only come from metadata.calibre's user_metadata
-- (EPUB metadata and BIM carry one series), which only the PLAIN rapidjson
-- parse keeps -- load_calibre strips it, verified empirically. The stub
-- offers both loaders so the test also pins WHICH one the code chose.
test("getSeriesGroups: a Calibre series column adds a second membership (#299)",
function()
    Repo.invalidateWalkCache()
    package.loaded["readhistory"].hist = {
        { file = "/lib/foreverwar.epub", time = 500 },
    }
    _G._test_bim_data = {
        ["/lib/foreverwar.epub"] = { title = "The Forever War",
                                     series = "The Forever War #1" },
        ["/lib/other.epub"]      = { title = "Other" },
    }
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 1,
                          bookshelf_calibre_metadata = true }
    -- SAVED AND RESTORED, unlike the suite's usual drive-by stubbing: this
    -- attributes stub answers the no-key TABLE form (walkBooks prefers it,
    -- and _calibreMetadataFor reads .size off it), and the table MUST carry
    -- mode -- walkBooks reads attr.mode off the table and only falls back to
    -- keyed calls when the table form returns nil, so a mode-less table made
    -- the walk skip every entry. Left in place, the same stub then leaked
    -- "file"-for-everything into later tests.
    local lfs_stub = package.loaded["libs/libkoreader-lfs"]
    local prev_dir, prev_attributes = lfs_stub.dir, lfs_stub.attributes
    lfs_stub.dir = function(path)
        local files = (path == "/lib")
            and { ".", "..", "foreverwar.epub", "other.epub" } or {}
        local i = 0
        return function() i = i + 1; return files[i] end
    end
    lfs_stub.attributes = function(_fp, key)
        if key == "mode" then return "file" end
        if key == "modification" then return 0 end
        if key == nil then
            return { mode = "file", modification = 0, size = 1024 }
        end
    end
    local calibre_entries = {
        {
            lpath = "foreverwar.epub",
            title = "The Forever War",
            series = "The Forever War", series_index = 1,
            pubdate = "1974-01-01T00:00:00+00:00",
            publisher = "St. Martin's Press",
            rating = 9,
            user_metadata = {
                ["#series2"] = { datatype = "series",
                                 ["#value#"] = "SF Masterworks",
                                 ["#extra#"] = 83 },
                ["#notseries"] = { datatype = "text",
                                   ["#value#"] = "ignore me" },
                ["#signed"] = { datatype = "bool", ["#value#"] = true },
                ["#dateread"] = { datatype = "datetime",
                                  ["#value#"] = "2019-06-02T00:00:00+00:00" },
                ["#review"] = { datatype = "comments",
                                ["#value#"] = "<p>very long HTML…</p>" },
            },
        },
    }
    -- LAYERED over the suite's existing rapidjson stub (the hardcover cache
    -- fake installs one with the encode/decode the enrichment paths need),
    -- and restored below -- replacing it outright broke every Hardcover test
    -- that ran after this one.
    local prev_rapidjson = package.loaded["rapidjson"]
    local rj = {}
    for k, v in pairs(prev_rapidjson or {}) do rj[k] = v end
    rj.load = function(_path) return calibre_entries end
    rj.load_calibre = function(_path)
        error("load_calibre strips user_metadata; the small-file path "
            .. "must take the plain parse")
    end
    package.loaded["rapidjson"] = rj

    local groups = Repo.getSeriesGroups(10)
    -- Two stacks (plus the standalone, which is not a group): the primary
    -- series and the custom column's.
    local names = {}
    for _i, g in ipairs(groups) do
        if g.series_name then names[g.series_name] = g end
    end
    assert(names["The Forever War"], "the primary series stack is missing")
    assert(names["SF Masterworks"],
        "the custom series column must create its own stack")
    -- Same book, both stacks, and the SECONDARY stack orders by the
    -- secondary number (#83), not the primary's #1.
    local sm = names["SF Masterworks"]
    assert(sm.books[1].filepath == "/lib/foreverwar.epub"
        or (sm.books[1].title == "The Forever War"),
        "the book must be a member of the secondary stack")
    -- The text-typed column must NOT have become a series.
    assert(not names["ignore me"],
        "a non-series custom column leaked into the series stacks")

    -- The %calibre{name} field map: standard fields and custom columns,
    -- rendered to strings at slim time, keyed without '#', lowercased.
    local rec = Repo.buildBookMeta("/lib/foreverwar.epub")
    assert(rec and type(rec.calibre) == "table",
        "the book record must carry the calibre field map")
    local f = rec.calibre
    assert(f.pubdate == "1974", "pubdate reduces to the year, got "
        .. tostring(f.pubdate))
    assert(f.publisher == "St. Martin's Press", "publisher passes through")
    assert(f.rating == "4.5", "rating halves to the star scale, got "
        .. tostring(f.rating))
    assert(f.notseries == "ignore me", "a text column keyed without '#'")
    assert(f.signed == "yes", "a true bool renders as yes")
    assert(f.dateread == "2019", "a datetime column reduces to the year")
    assert(f.review == nil, "comments-datatype columns must be skipped")

    package.loaded["rapidjson"] = prev_rapidjson
    lfs_stub.dir, lfs_stub.attributes = prev_dir, prev_attributes
    _G._test_settings = {}
    Repo.invalidateWalkCache()
end)

-- The harvest sidecar (calibre.bookshelf.json): KOReader's calibre plugin
-- rewrites metadata.calibre from load_calibre's whitelist on wireless sync,
-- permanently deleting author_sort and user_metadata. A calibre-written file
-- passing through us harvests those two into our own sidecar; a rewritten
-- file gets them merged back. This drives the full cycle.
test("calibre harvest: written on a calibre file, merged back after the wipe",
function()
    Repo.invalidateWalkCache()
    package.loaded["readhistory"].hist = {}
    _G._test_bim_data = {
        ["/lib/foreverwar.epub"] = { title = "The Forever War" },
    }
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 1,
                          bookshelf_calibre_metadata = true }
    local lfs_stub = package.loaded["libs/libkoreader-lfs"]
    local prev_dir, prev_attributes = lfs_stub.dir, lfs_stub.attributes
    lfs_stub.dir = function(path)
        local files = (path == "/lib") and { ".", "..", "foreverwar.epub" } or {}
        local i = 0
        return function() i = i + 1; return files[i] end
    end
    lfs_stub.attributes = function(_fp, key)
        if key == "mode" then return "file" end
        if key == "modification" then return 0 end
        if key == nil then
            return { mode = "file", modification = 0, size = 1024 }
        end
    end

    -- Phase 1: a calibre-written file (author_sort + user_metadata present).
    local calibre_file = {
        { lpath = "foreverwar.epub", title = "The Forever War",
          author_sort = "Haldeman, Joe",
          series = "The Forever War", series_index = 1,
          user_metadata = {
              ["#series2"] = { datatype = "series",
                               ["#value#"] = "SF Masterworks",
                               ["#extra#"] = 83 },
          } },
    }
    local harvest_file = nil   -- what our sidecar "contains on disk"
    local dumped
    local prev_rapidjson = package.loaded["rapidjson"]
    local rj = {}
    for k, v in pairs(prev_rapidjson or {}) do rj[k] = v end
    rj.load = function(path)
        if path:find("calibre.bookshelf.json", 1, true) then
            if not harvest_file then error("no harvest yet") end
            return harvest_file
        end
        return calibre_file
    end
    rj.dump = function(value, path, _opts)
        assert(path:find("calibre.bookshelf.json", 1, true),
            "the only thing we ever write is our own sidecar: " .. path)
        dumped = value
        harvest_file = value
    end
    package.loaded["rapidjson"] = rj

    local groups = Repo.getSeriesGroups(10)
    assert(dumped and dumped.books and dumped.books["foreverwar.epub"],
        "a calibre-written file must be harvested")
    local h = dumped.books["foreverwar.epub"]
    assert(h.author_sort == "Haldeman, Joe", "author_sort must be harvested")
    assert(h.extra_series and h.extra_series[1].name == "SF Masterworks",
        "the series column must be harvested")

    -- Phase 2: KOReader's plugin has rewritten the file -- whitelisted fields
    -- only. The 60s TTL memo would hide the change, so invalidate as a chip
    -- switch after a real sync would.
    calibre_file = {
        { lpath = "foreverwar.epub", title = "The Forever War",
          series = "The Forever War", series_index = 1 },
    }
    Repo.invalidateWalkCache()
    Repo.invalidateCalibreCache()

    local groups2 = Repo.getSeriesGroups(10)
    local names = {}
    for _i, g in ipairs(groups2) do
        if g.series_name then names[g.series_name] = true end
    end
    assert(names["SF Masterworks"],
        "the harvested series column must survive the wireless-sync wipe")

    package.loaded["rapidjson"] = prev_rapidjson
    lfs_stub.dir, lfs_stub.attributes = prev_dir, prev_attributes
    _G._test_settings = {}
    Repo.invalidateWalkCache()
    Repo.invalidateCalibreCache()
end)

-- %books_read's backing count: Finished means KOReader's own Reader Status.
test("countFinishedBooks: counts Finished sidecars across the walk", function()
    Repo.invalidateWalkCache()
    _G._test_bim_data = {
        ["/lib/done.epub"]    = { title = "Done" },
        ["/lib/reading.epub"] = { title = "Reading" },
        ["/lib/unread.epub"]  = { title = "Unread" },
    }
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 1 }
    _G._test_docsettings_data = {
        ["/lib/done.epub"]    = { summary = { status = "complete" } },
        ["/lib/reading.epub"] = { summary = { status = "reading" },
                                  percent_finished = 0.4 },
    }
    local lfs_stub = package.loaded["libs/libkoreader-lfs"]
    local prev_dir, prev_attributes = lfs_stub.dir, lfs_stub.attributes
    lfs_stub.dir = function(path)
        local files = (path == "/lib")
            and { ".", "..", "done.epub", "reading.epub", "unread.epub" } or {}
        local i = 0
        return function() i = i + 1; return files[i] end
    end
    lfs_stub.attributes = function(_fp, key)
        if key == "mode" then return "file" end
        if key == "modification" then return 0 end
    end
    local prev_sidecar = package.loaded["docsettings"].hasSidecarFile
    package.loaded["docsettings"].hasSidecarFile = function(_self, fp)
        return _G._test_docsettings_data[fp] ~= nil
    end

    assert(Repo.countFinishedBooks() == 1,
        "one Finished book, got " .. tostring(Repo.countFinishedBooks()))
    -- Cached inside the TTL: mark another finished, count holds until the
    -- walk cache is invalidated (a library change).
    _G._test_docsettings_data["/lib/reading.epub"].summary.status = "complete"
    assert(Repo.countFinishedBooks() == 1, "the TTL cache must hold")
    Repo.invalidateWalkCache()
    Repo.invalidateProgressCache()
    assert(Repo.countFinishedBooks() == 2,
        "after invalidation the new Finished book must count")

    package.loaded["docsettings"].hasSidecarFile = prev_sidecar
    lfs_stub.dir, lfs_stub.attributes = prev_dir, prev_attributes
    _G._test_settings = {}
    _G._test_docsettings_data = nil
    Repo.invalidateWalkCache()
end)

-- The spine plan mutates the SHARED light-meta record (bakes the sidecar's
-- status + a checked flag onto it so paints skip DocSettings). A status edit
-- fires invalidateProgressCache, which must strip those fields too -- or the
-- plan's `if src.status == nil` guard keeps serving the old status until
-- restart: the stale reading-glyph bug on the spine shelf.
test("invalidateProgressCache strips spine-plan fields from shared light records", function()
    Repo.invalidateWalkCache()
    Repo.invalidateLightMeta()
    Repo.invalidateBookCache("test")
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 1 }
    _G._test_bim_data = { ["/lib/spine.epub"] = { title = "Spine" } }
    local lfs_stub = package.loaded["libs/libkoreader-lfs"]
    local prev_dir, prev_attributes = lfs_stub.dir, lfs_stub.attributes
    lfs_stub.dir = function(path)
        local files = (path == "/lib") and { ".", "..", "spine.epub" } or {}
        local i = 0
        return function() i = i + 1; return files[i] end
    end
    lfs_stub.attributes = function(_fp, key)
        if key == "mode" then return "file" end
        if key == "modification" then return 0 end
        if key == "size" then return 1 end
    end
    -- Give the BIM stub the batch-SELECT surface so _getLightMetaCache
    -- builds the shared memoised map -- the sharing under test. Column-major
    -- arrays, ljsqlite3 exec shape.
    local bim = package.loaded["bookinfomanager"]
    local prev_open, prev_conn = bim.openDbConnection, bim.db_conn
    bim.openDbConnection = function() end
    bim.db_conn = { exec = function()
        return { { "/lib/" }, { "spine.epub" }, { "Spine" },
                 { "A. Author" }, {}, {}, {}, {} }
    end }

    -- A custom sort routes the library kind through the predicate path,
    -- which serves the memoised light records (the device shape: the Home
    -- chip sorts by date added).
    local sortp = { { key = "date_added", reverse = true } }
    local function fetch()
        Repo.spine_light = true
        local page = Repo.getBySource({ kind = "library" }, nil, sortp, 0, 10)
        Repo.spine_light = false
        return page and page[1]
    end
    local rec = fetch()
    assert(rec and rec.filepath == "/lib/spine.epub", "fetch must find the book")
    -- Bake the plan's mutations, then prove the harness really shares the
    -- record -- a fresh-record harness would pass the final assertions
    -- against the bug.
    rec.status = "reading"
    rec._spine_status_checked = true
    local rec_again = fetch()
    assert(rec_again == rec, "harness must serve the SHARED light record")
    Repo.invalidateProgressCache(rec.filepath)
    local rec_after = fetch()
    assert(rec_after == rec, "still the shared record after invalidation")
    assert(rec_after.status == nil,
        "status edit must strip the plan-baked status, got " .. tostring(rec_after.status))
    assert(rec_after._spine_status_checked == nil,
        "the checked flag must clear so the plan re-reads the sidecar")

    bim.openDbConnection, bim.db_conn = prev_open, prev_conn
    lfs_stub.dir, lfs_stub.attributes = prev_dir, prev_attributes
    _G._test_settings = {}
    _G._test_bim_data = nil
    Repo.invalidateWalkCache()
    Repo.invalidateLightMeta()
end)

-- KOReader's "Folders and files mixed" (collate_mixed) on the home view:
-- OFF partitions folders before books, ON interleaves them by the sort key.
test("getAll honours collate_mixed in both positions", function()
    Repo.invalidateWalkCache()
    _G._test_bim_data = {
        ["/lib/alpha.epub"] = { title = "Alpha" },
        ["/lib/omega.epub"] = { title = "Omega" },
        ["/lib/Mystery/m1.epub"] = { title = "M One" },
        ["/lib/Zebra/z1.epub"]   = { title = "Z One" },
    }
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 3 }
    local lfs_stub = package.loaded["libs/libkoreader-lfs"]
    local prev_dir, prev_attributes = lfs_stub.dir, lfs_stub.attributes
    local DIRS = { ["/lib/Mystery"] = true, ["/lib/Zebra"] = true }
    local LISTING = {
        ["/lib"] = { ".", "..", "alpha.epub", "omega.epub", "Mystery", "Zebra" },
        ["/lib/Mystery"] = { ".", "..", "m1.epub" },
        ["/lib/Zebra"]   = { ".", "..", "z1.epub" },
    }
    lfs_stub.dir = function(path)
        local files = LISTING[path] or {}
        local i = 0
        return function() i = i + 1; return files[i] end
    end
    lfs_stub.attributes = function(fp, key)
        local mode = DIRS[fp] and "directory" or "file"
        if key == "mode" then return mode end
        if key == "modification" then return 0 end
        if key == nil then return { mode = mode, modification = 0, size = 9 } end
    end

    local function order(mixed, priority)
        _G._test_settings.collate_mixed = mixed
        Repo.invalidateWalkCache()   -- drops the getAll shape cache too
        local items = Repo.getAll(nil, 10, 0, priority)
        local out = {}
        for _i, it in ipairs(items or {}) do
            out[#out + 1] = (it.kind == "folder") and ("D:" .. (it.label or "?"))
                            or ("B:" .. (it.title or "?"))
        end
        return table.concat(out, " ")
    end

    assert(order(false):match("^D:.* D:.* B:.* B:"),
        "mixed OFF must partition folders first, got: " .. order(false))
    local got = order(true)
    assert(got:match("^B:Alpha D:Mystery B:Omega D:Zebra"),
        "mixed ON must interleave by title, got: " .. got)

    -- The DEFAULT home chip threads sort_priority = filename (tab model),
    -- which is the configuration the report came from: the toggle must
    -- hold under a per-chip priority too.
    local PRIO = { { key = "filename", reverse = false } }
    local off = order(false, PRIO)
    assert(off:match("^D:.* D:.* B:.* B:"),
        "mixed OFF under chip priority must partition folders first, got: " .. off)
    local on = order(true, PRIO)
    assert(on:match("^B:.* D:.* B:.* D:") or on:match("^B:.* B:.* D:.* D:") == nil
           and on:match("D:") ~= nil and not on:match("^D:.* D:"),
        "mixed ON under chip priority must interleave, got: " .. on)

    lfs_stub.dir, lfs_stub.attributes = prev_dir, prev_attributes
    _G._test_settings = {}
    Repo.invalidateWalkCache()
end)

-- issue #127 (A): an empty / whitespace / name-less embedded series must not
-- create a junk stack. The Calibre branch already guarded this; the embedded
-- info.series branch now does too.
test("getSeriesGroups: empty/whitespace/name-less embedded series is dropped (#127)", function()
    Repo.invalidateWalkCache()
    package.loaded["readhistory"].hist = {}
    _G._test_bim_data = {
        ["/lib/real.epub"]    = { title = "Real", series = "Real Series #1" },
        ["/lib/empty.epub"]   = { title = "Empty", series = "" },
        ["/lib/ws.epub"]      = { title = "WS", series = "   " },
        ["/lib/numonly.epub"] = { title = "NumOnly", series = " #3" },
    }
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 1 }
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = (path == "/lib")
            and { ".", "..", "real.epub", "empty.epub", "ws.epub", "numonly.epub" }
            or {}
        local i = 0
        return function() i = i + 1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(_fp, key)
        if key == "mode" then return "file" end
        if key == "modification" then return 0 end
    end
    local groups = Repo.getSeriesGroups(10)
    assert(#groups == 1, "expected only the real series, got " .. #groups)
    assert(groups[1].series_name == "Real Series",
        "got " .. tostring(groups[1].series_name))
end)

-- issue #127 (B): "hide single-book stacks" option. Default off shows a
-- one-book series; on hides it while keeping multi-book series.
test("getSeriesGroups: hide_single_book_stacks hides one-book series only when on (#127)", function()
    local function setup()
        Repo.invalidateWalkCache()
        package.loaded["readhistory"].hist = {}
        _G._test_bim_data = {
            ["/lib/d.epub"]  = { title = "Dune", series = "Dune #1" },
            ["/lib/f1.epub"] = { title = "F1", series = "Foundation #1" },
            ["/lib/f2.epub"] = { title = "F2", series = "Foundation #2" },
        }
        package.loaded["libs/libkoreader-lfs"].dir = function(path)
            local files = (path == "/lib")
                and { ".", "..", "d.epub", "f1.epub", "f2.epub" } or {}
            local i = 0
            return function() i = i + 1; return files[i] end
        end
        package.loaded["libs/libkoreader-lfs"].attributes = function(_fp, key)
            if key == "mode" then return "file" end
            if key == "modification" then return 0 end
        end
    end
    -- Default (off): the one-book Dune stack and the two-book Foundation both show.
    setup()
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 1 }
    local off = Repo.getSeriesGroups(10)
    assert(#off == 2, "option off: expected 2 groups, got " .. #off)
    -- On: the single-book Dune stack is hidden; Foundation (2 books) remains.
    setup()
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 1,
                          bookshelf_hide_single_book_stacks = true }
    local on = Repo.getSeriesGroups(10)
    assert(#on == 1, "option on: expected 1 group, got " .. #on)
    assert(on[1].series_name == "Foundation", "got " .. tostring(on[1].series_name))
end)

-- ============================================================================
-- Task 2.5: enrichStats
-- ============================================================================

-- enrichStats now queries the statistics plugin's SQLite DB directly
-- (the plugin's own getBookStat is integer-id-keyed and returns
-- KeyValuePage-shaped output, not what we need). Pure-Lua tests can't
-- exercise SQLite without complex setup, so the contract test below just
-- confirms the no-data path is a clean no-op.
test("enrichStats: no md5 / no DB → no-op, no crash", function()
    package.loaded["util"] = { partialMD5 = function() return nil end }
    local b = { filepath = "/x.epub" }
    local ok = pcall(Repo.enrichStats, b)
    assert(ok, "enrichStats let an error propagate")
    assert(b.book_time_left_minutes == nil)
    assert(b.book_read_time_seconds == nil)
end)

-- ============================================================================
-- Task 2.6: author splitting, pcall guards, deduplication
-- ============================================================================

test("buildBook: forwards want_cover to BIM so callers can skip the decode", function()
    -- The in-reader status line (lib/bookshelf_reader_status) rebuilds the
    -- record on every ReaderView paint and never looks at the cover, so it
    -- must be able to skip BIM's zstd decode and Blitbuffer allocation the
    -- same way the grid's cache-hit paths do. buildBookMeta already took
    -- opts.want_cover; buildBook had no way to pass it through.
    local seen = {}
    local original = package.loaded["bookinfomanager"]
    package.loaded["bookinfomanager"] = {
        getBookInfo = function(_self, fp, with_cover)
            seen[#seen + 1] = with_cover
            return _G._test_bim_data and _G._test_bim_data[fp] or nil
        end,
    }
    package.loaded["bookshelf_book_repository"] = nil
    local R = dofile("lib/bookshelf_book_repository.lua")
    _G._test_bim_data = { ["/wc.epub"] = { title = "Cover Skipped" } }

    R.buildBook("/wc.epub")
    R.buildBook("/wc.epub", { want_cover = false })

    package.loaded["bookinfomanager"] = original
    assert(seen[1] == true, "default should still ask for the cover, got " .. tostring(seen[1]))
    assert(seen[2] == false, "want_cover=false should reach BIM, got " .. tostring(seen[2]))
end)

test("buildBook: splits newline-separated authors and trims whitespace", function()
    -- BIM stores multiple authors newline-separated (see splitAuthors / #74).
    _G._test_bim_data = {
        ["/book.epub"] = { authors = "Frank Herbert\n  Isaac Asimov \nArthur C. Clarke" },
    }
    local book = Repo.buildBook("/book.epub")
    assert(book.authors, "authors should be a table")
    assert(#book.authors == 3, "expected 3 authors, got " .. #book.authors)
    assert(book.authors[1] == "Frank Herbert", "got " .. tostring(book.authors[1]))
    assert(book.authors[2] == "Isaac Asimov", "got " .. tostring(book.authors[2]))
    assert(book.authors[3] == "Arthur C. Clarke", "got " .. tostring(book.authors[3]))
    assert(book.author == "Frank Herbert", "singular author should be trimmed first")
end)

test("buildBook: single-author string yields one-element array, no trailing whitespace", function()
    _G._test_bim_data = { ["/x.epub"] = { authors = "Sole Author" } }
    local book = Repo.buildBook("/x.epub")
    assert(#book.authors == 1)
    assert(book.authors[1] == "Sole Author")
    assert(book.author == "Sole Author")
end)

test("buildBook: fb2 comma-joined authors split, double spaces collapsed (#242)", function()
    -- crengine composes fb2 authors from structured first/middle/last fields,
    -- joining multiple authors with ", " and leaving a double space where the
    -- middle name is empty: "Alpha  Tester, Beta  Cowriter". Comma is a safe
    -- separator ONLY for fb2 -- structured fields mean it can't be a
    -- "Surname, Forename" library-format name.
    for _i, fp in ipairs({ "/two.fb2", "/two.fb2.zip", "/TWO.FB2.ZIP" }) do
        _G._test_bim_data = { [fp] = { authors = "Alpha  Tester, Beta  Cowriter" } }
        local book = Repo.buildBook(fp)
        assert(#book.authors == 2, fp .. ": expected 2 authors, got " .. #book.authors)
        assert(book.authors[1] == "Alpha Tester", fp .. ": got " .. tostring(book.authors[1]))
        assert(book.authors[2] == "Beta Cowriter", fp .. ": got " .. tostring(book.authors[2]))
    end
end)

test("buildBook: comma stays part of the name for non-fb2 formats (#74)", function()
    _G._test_bim_data = { ["/clarke.epub"] = { authors = "Clarke, Arthur C." } }
    local book = Repo.buildBook("/clarke.epub")
    assert(#book.authors == 1, "expected 1 author, got " .. #book.authors)
    assert(book.authors[1] == "Clarke, Arthur C.")
end)

test("buildBook: single fb2 author with empty middle-name slot is cleaned", function()
    _G._test_bim_data = { ["/one.fb2.zip"] = { authors = "Alpha  Tester" } }
    local book = Repo.buildBook("/one.fb2.zip")
    assert(#book.authors == 1)
    assert(book.authors[1] == "Alpha Tester",
        "internal double space should collapse, got " .. tostring(book.authors[1]))
end)

test("buildBookMeta: Hardcover enrichment never sticks in sticky metadata cache", function()
    local fp = "/hardcover-cache.epub"
    _G._test_settings = {
        bookshelf_hardcover_links = {
            -- Explicit per-book flags: a Hardcover cover/description is only
            -- shown when the flag is on (no live "fill when missing" any more).
            [fp] = { book_id = 123, title = "Remote Link",
                     use_description = true, use_cover = true },
        },
    }
    hccache.clear()
    hccache.seed("enrich", "123", {
        description = "Remote description",
        cover_path = "/tmp/remote-cover.jpg",
    })
    local Hardcover = require("lib/bookshelf_hardcover")
    Hardcover.invalidate()

    _G._test_bim_data = {
        [fp] = {
            has_meta = "Y",
            title = "Local Title",
            authors = "Local Author",
        },
    }
    local enriched = Repo.buildBookMeta(fp)
    assert(enriched.description == "Remote description", "expected remote description")
    assert(enriched.cover_image_path == "/tmp/remote-cover.jpg", "expected remote cover")

    -- Simulate Clear link / Clear cache, then BIM being temporarily unable
    -- to provide metadata. The fallback path should return a clean copy of
    -- the sticky record, not stale Hardcover fields from before the unlink.
    _G._test_settings.bookshelf_hardcover_links = {}
    _G._test_settings.bookshelf_hardcover_enrichment = {}
    Hardcover.invalidate()
    _G._test_bim_data[fp] = {}

    local fallback = Repo.buildBookMeta(fp)
    assert(fallback.title == "Local Title", "sticky metadata record was not used")
    assert(fallback.description == nil, "stale Hardcover description leaked")
    assert(fallback.cover_image_path == nil, "stale Hardcover cover leaked")
    assert(fallback.hardcover_book_id == nil, "stale Hardcover id leaked")
end)

test("buildBook: nil authors → nil array (not crash)", function()
    _G._test_bim_data = { ["/x.epub"] = {} }
    local book = Repo.buildBook("/x.epub")
    assert(book.authors == nil)
    assert(book.author == nil)
end)

-- Device bug: tapping an OPDS catalog entry rebuilt the preview/cell record
-- from its "OPDS://server/id" pseudo-path via buildBook/buildBookMeta. There
-- is no file behind a remote entry, so BIM/Calibre/filename fallbacks built a
-- stripped stand-in -- no cover, no series, title = the raw feed id (e.g.
-- "urn:gutenberg:1727:2") -- which then replaced the good feed record in the
-- hero and the tapped shelf cell. buildBook/buildBookMeta must return nil for
-- an OPDS pseudo-path so every "or <original record>" fallback wins instead.
test("buildBookMeta: returns nil for an OPDS pseudo-path, no stripped stand-in", function()
    _G._test_bim_data = nil
    local meta = Repo.buildBookMeta("OPDS://abc/urn:x")
    assert(meta == nil, "expected nil, got " .. tostring(meta))
end)

test("buildBook: returns nil for an OPDS pseudo-path, no stripped stand-in", function()
    _G._test_bim_data = nil
    local book = Repo.buildBook("OPDS://abc/urn:x")
    assert(book == nil, "expected nil, got " .. tostring(book))
end)

test("getLatest: unreadable directory does not crash the walk", function()
    Repo.invalidateWalkCache()
    -- Stub lfs.dir so it raises on '/home/badperms' but works on '/home'.
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        if path == "/home/badperms" then
            error("permission denied: " .. path)
        end
        local files
        if path == "/home" then files = { ".", "..", "ok.epub", "badperms" }
        else files = {} end
        local i = 0
        return function() i = i + 1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(fp, key)
        local times = { ["/home/ok.epub"] = 100 }
        local modes = { ["/home/badperms"] = "directory" }
        if key == "modification" then return times[fp] or 0
        elseif key == "mode" then return modes[fp] or "file" end
    end
    _G._test_settings = { home_dir = "/home", bookshelf_latest_walk_depth = 3 }
    _G._test_bim_data = { ["/home/ok.epub"] = { title = "OK" } }

    local ok, latest = pcall(Repo.getLatest, 5)
    assert(ok, "getLatest crashed on unreadable dir: " .. tostring(latest))
    assert(#latest == 1)
    assert(latest[1].title == "OK")
end)

test("enrichStats: missing util.partialMD5 → no-op", function()
    package.loaded["util"] = nil
    local b = { filepath = "/x.epub" }
    local ok = pcall(Repo.enrichStats, b)
    assert(ok, "enrichStats let an error propagate")
    assert(b.book_time_left_minutes == nil)
end)

test("getSeriesGroups: dedupes books across multiple history entries for the same filepath", function()
    Repo.invalidateWalkCache()
    package.loaded["readhistory"].hist = {
        { file = "/lib/foundation1.epub", time = 500 },
        { file = "/lib/foundation1.epub", time = 400 },  -- same book, opened earlier
        { file = "/lib/foundation2.epub", time = 300 },
    }
    _G._test_bim_data = {
        ["/lib/foundation1.epub"] = { title = "Foundation",            series = "Foundation #1" },
        ["/lib/foundation2.epub"] = { title = "Foundation and Empire", series = "Foundation #2" },
    }
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 1 }
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = (path == "/lib") and { ".", "..", "foundation1.epub", "foundation2.epub" } or {}
        local i = 0
        return function() i = i + 1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(_fp, key)
        if key == "mode" then return "file" end
        if key == "modification" then return 0 end
    end
    local groups = Repo.getSeriesGroups(10)
    assert(#groups == 1, "expected 1 group, got " .. #groups)
    assert(#groups[1].books == 2, "expected 2 unique books in Foundation, got " .. #groups[1].books)
    assert(groups[1]._seen == nil, "_seen helper should be removed from public shape")
end)

test("walk cache: second call inside TTL skips lfs.dir; invalidate forces re-walk", function()
    Repo.invalidateWalkCache()
    local dir_calls = 0
    _G._test_settings = { home_dir = "/cached", bookshelf_latest_walk_depth = 1 }
    _G._test_bim_data = { ["/cached/a.epub"] = { title = "A" } }
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        dir_calls = dir_calls + 1
        local files = (path == "/cached") and { ".", "..", "a.epub" } or {}
        local i = 0
        return function() i = i + 1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(_fp, key)
        if key == "mode" then return "file" end
        if key == "modification" then return 0 end
    end

    Repo.getLatest(5)
    local after_first = dir_calls
    Repo.getLatest(5)        -- same key inside TTL — should hit cache
    assert(dir_calls == after_first,
           "expected cached walk to skip lfs.dir, got " .. (dir_calls - after_first) .. " extra calls")

    Repo.invalidateWalkCache()
    Repo.getLatest(5)        -- post-invalidate: must re-walk
    assert(dir_calls > after_first,
           "expected lfs.dir to be called after invalidate, got 0 extra calls")
end)

test("getSeriesGroups: cache skips lfs walk; bbs rebuilt fresh per call", function()
    Repo.invalidateWalkCache() -- also clears the series cache

    -- Counting stubs:
    --   dir_calls — lfs.dir invocations (the cache's main savings target)
    --   bim_calls — BookInfoManager:getBookInfo calls (must run on every
    --               getSeriesGroups call so cover_bbs are fresh; the
    --               previous version that cached Book records crashed
    --               with use-after-free on freed cover_bbs).
    local dir_calls = 0
    local bim_calls = 0
    local original_bim = package.loaded["bookinfomanager"]
    package.loaded["bookinfomanager"] = {
        getBookInfo = function(_self, fp, _with_cover)
            bim_calls = bim_calls + 1
            return _G._test_bim_data and _G._test_bim_data[fp] or nil
        end,
    }
    package.loaded["bookshelf_book_repository"] = nil
    local Repo2 = dofile("lib/bookshelf_book_repository.lua")

    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        dir_calls = dir_calls + 1
        local files = (path == "/lib") and { ".", "..", "a.epub", "b.epub", "c.epub" } or {}
        local i = 0
        return function() i = i + 1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(_fp, key)
        if key == "mode" then return "file" end
        if key == "modification" then return 0 end
    end
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 1 }
    _G._test_bim_data = {
        ["/lib/a.epub"] = { title = "A1", series = "Alpha #1", series_index = 1 },
        ["/lib/b.epub"] = { title = "A2", series = "Alpha #2", series_index = 2 },
        ["/lib/c.epub"] = { title = "B1", series = "Beta #1",  series_index = 1 },
    }

    Repo2.getSeriesGroups(4)
    local dir_after_first = dir_calls
    local bim_after_first = bim_calls
    assert(bim_after_first >= 3, "expected >=3 BIM calls on first build, got " .. bim_after_first)
    assert(dir_after_first >= 1, "expected lfs.dir called on first build")

    Repo2.getSeriesGroups(4)
    -- Walk skipped on cache hit:
    assert(dir_calls == dir_after_first,
           "expected lfs.dir to be skipped on cache hit, got "
           .. (dir_calls - dir_after_first) .. " extra walks")
    -- BIM re-runs to rebuild cover_bbs (the safety contract):
    assert(bim_calls > bim_after_first,
           "expected BIM to re-run on cache hit so cover_bbs are fresh "
           .. "(use-after-free fix); got 0 extra calls")

    Repo2.invalidateWalkCache() -- chained invalidation drops series too
    Repo2.getSeriesGroups(4)
    assert(dir_calls > dir_after_first,
           "expected lfs.dir to be called after invalidate")

    package.loaded["bookinfomanager"] = original_bim
end)

-- ============================================================================
-- searchAll
-- ============================================================================

test("searchAll: returns empty result for blank query", function()
    Repo.invalidateWalkCache()
    local r = Repo.searchAll("")
    assert(type(r) == "table")
    assert(#(r.books   or {}) == 0)
    assert(#(r.folders or {}) == 0)
    assert(#(r.authors or {}) == 0)
    assert(#(r.series  or {}) == 0)
    assert(#(r.genres  or {}) == 0)
end)

test("searchAll: matches books by title", function()
    Repo.invalidateWalkCache()
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = (path == "/lib") and {".", "..", "dune.epub", "foundation.epub"} or {".", ".."}
        local i = 0; return function() i = i+1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(fp, key)
        if key == "mode" then return "file" end
        return 0
    end
    _G._test_settings  = { home_dir = "/lib", bookshelf_latest_walk_depth = 1 }
    _G._test_bim_data  = {
        ["/lib/dune.epub"]       = { title = "Dune", authors = "Frank Herbert" },
        ["/lib/foundation.epub"] = { title = "Foundation", authors = "Isaac Asimov" },
    }
    local r = Repo.searchAll("dune")
    assert(#r.books == 1, "expected 1 book, got " .. #r.books)
    assert(r.books[1].title == "Dune")
end)

test("searchAll: matches author groups by name", function()
    Repo.invalidateWalkCache()
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = (path == "/lib") and {".", "..", "dune.epub", "foundation.epub"} or {".", ".."}
        local i = 0; return function() i = i+1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(fp, key)
        if key == "mode" then return "file" end
        return 0
    end
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 1 }
    _G._test_bim_data = {
        ["/lib/dune.epub"]       = { title = "Dune",       authors = "Frank Herbert" },
        ["/lib/foundation.epub"] = { title = "Foundation", authors = "Isaac Asimov" },
    }
    Repo.invalidateSeriesCache()
    local r = Repo.searchAll("asimov")
    assert(#r.authors == 1, "expected 1 author group, got " .. #r.authors)
    assert(r.authors[1].series_name == "Isaac Asimov",
        "expected Isaac Asimov got " .. tostring(r.authors[1].series_name))
    assert(#r.authors[1].books == 1)
end)

test("searchAll: genres match by default and can be switched off (issue 371)", function()
    Repo.invalidateWalkCache()
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = (path == "/lib") and {".", "..", "dune.epub", "foundation.epub"} or {".", ".."}
        local i = 0; return function() i = i+1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(fp, key)
        if key == "mode" then return "file" end
        return 0
    end
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 1 }
    _G._test_bim_data = {
        ["/lib/dune.epub"]       = { title = "Dune", authors = "Frank Herbert", keywords = "Space opera" },
        ["/lib/foundation.epub"] = { title = "Foundation", authors = "Isaac Asimov" },
    }
    Repo.invalidateSeriesCache()
    local r = Repo.searchAll("opera")
    assert(#r.books == 1 and r.books[1].title == "Dune", "genre match expected by default, got " .. #r.books)
    assert(#r.genres == 1, "genre group expected by default, got " .. #r.genres)

    _G._test_settings.bookshelf_search_include_genres = false
    local r2 = Repo.searchAll("opera")
    assert(#r2.books == 0, "no genre matches with the setting off, got " .. #r2.books)
    assert(#r2.genres == 0, "no genre groups with the setting off, got " .. #r2.genres)
    -- Titles and authors still match.
    assert(#Repo.searchAll("dune").books == 1)
end)

test("searchAll: folder names off by default, matched with opt-in (#190)", function()
    Repo.invalidateWalkCache()
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        if path == "/lib" then
            local files = {".", "..", "scifi"}
            local i = 0; return function() i=i+1; return files[i] end
        elseif path == "/lib/scifi" then
            local files = {".", "..", "dune.epub"}
            local i = 0; return function() i=i+1; return files[i] end
        else
            local files = {".", ".."}
            local i = 0; return function() i=i+1; return files[i] end
        end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(fp, key)
        if key == "mode" then
            if fp == "/lib/scifi" then return "directory" end
            return "file"
        end
        return 0
    end
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 2 }
    _G._test_bim_data = { ["/lib/scifi/dune.epub"] = { title = "Dune", authors = "Frank Herbert" } }

    -- default: folder names are excluded from search (they duplicate the
    -- author/series/genre group of the same name in folder-organised libraries)
    local r = Repo.searchAll("scifi")
    assert(#r.folders == 0, "folders should be excluded by default, got " .. #r.folders)

    -- opt-in via the advanced setting: folder names are matched again
    _G._test_settings.bookshelf_search_include_folders = true
    local r2 = Repo.searchAll("scifi")
    assert(#r2.folders == 1, "expected 1 folder with setting on, got " .. #r2.folders)
    assert(r2.folders[1].label == "scifi")
    assert(r2.folders[1].kind  == "folder")
    assert(r2.folders[1].path  == "/lib/scifi")
    assert(r2.folders[1].first_book ~= nil)
end)

-- ============================================================================
-- findGroup
-- ============================================================================

test("findGroup: returns nil for unknown kind", function()
    local g = Repo.findGroup("unknown", "anything")
    assert(g == nil)
end)

test("findGroup: returns nil when name not in author cache", function()
    Repo.invalidateWalkCache()
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = (path == "/lib") and {".", "..", "dune.epub"} or {".", ".."}
        local i = 0; return function() i=i+1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(fp, key)
        if key == "mode" then return "file" end; return 0
    end
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 1 }
    _G._test_bim_data = { ["/lib/dune.epub"] = { title = "Dune", authors = "Frank Herbert" } }
    Repo.invalidateSeriesCache()
    Repo.getAuthors(10, 0) -- warm cache
    local g = Repo.findGroup("author", "Tolkien")
    assert(g == nil, "expected nil for non-existent author")
end)

test("findGroup: returns hydrated group for known author", function()
    Repo.invalidateWalkCache()
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = (path == "/lib") and {".", "..", "dune.epub", "dune2.epub"} or {".", ".."}
        local i = 0; return function() i=i+1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(fp, key)
        if key == "mode" then return "file" end; return 0
    end
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 1 }
    _G._test_bim_data = {
        ["/lib/dune.epub"]  = { title = "Dune",           authors = "Frank Herbert" },
        ["/lib/dune2.epub"] = { title = "Dune Messiah",   authors = "Frank Herbert" },
    }
    Repo.invalidateSeriesCache()
    Repo.getAuthors(10, 0) -- warm cache
    local g = Repo.findGroup("author", "Frank Herbert")
    assert(g ~= nil, "expected a group record")
    assert(g.series_name == "Frank Herbert")
    assert(#g.books == 2, "expected 2 books, got " .. #g.books)
end)

test("getAuthors: spine_light serves light copies, no full builds", function()
    -- Spine mode flattens groups into member spines, so the front-book cover
    -- is never rendered -- yet every page turn paid a full buildBookMeta per
    -- group (device report: paging the author shelf felt slow).
    Repo.invalidateWalkCache()
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = (path == "/lib") and {".", "..", "dune.epub", "dune2.epub"} or {".", ".."}
        local i = 0; return function() i=i+1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(fp, key)
        if key == "mode" then return "file" end; return 0
    end
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 1 }
    _G._test_bim_data = {
        ["/lib/dune.epub"]  = { title = "Dune",         authors = "Frank Herbert" },
        ["/lib/dune2.epub"] = { title = "Dune Messiah", authors = "Frank Herbert" },
    }
    Repo.invalidateSeriesCache()
    local orig_build = Repo.buildBookMeta
    local builds = 0
    Repo.buildBookMeta = function(...) builds = builds + 1; return orig_build(...) end
    Repo.spine_light = true
    local ok, err = pcall(function()
        local groups = Repo.getAuthors(10, 0)
        assert(#groups == 1, "expected one author group")
        local g = groups[1]
        assert(#g.books == 2, "expected both members hydrated")
        assert(g.books[1].title == "Dune", "light copy lost its title")
        assert(builds == 0,
            "spine_light must not pay a full buildBookMeta, got " .. builds)
        -- The spine plan BAKES status onto the records it renders; the light
        -- copies must isolate the cached shape from that (the stale-glyph
        -- lesson, e7559e6: shared records smear one render's status into the
        -- next fetch).
        g.books[1].status = "reading"
        local again = Repo.getAuthors(10, 0)
        assert(again[1].books[1].status == nil,
            "a baked status leaked into the cached shape")
    end)
    Repo.spine_light = nil
    Repo.buildBookMeta = orig_build
    if not ok then error(err) end
end)

-- ============================================================================
-- getSortKey
-- ============================================================================

test("getSortKey: returns chip default when setting missing", function()
    _G._test_settings = {}
    assert(Repo.getSortKey("authors") == "latest_read")
    assert(Repo.getSortKey("all") == "title")
    assert(Repo.getSortKey("latest") == "mtime")
end)

test("getSortKey: returns saved setting when valid", function()
    _G._test_settings = { bookshelf_sort_authors = "book_count" }
    assert(Repo.getSortKey("authors") == "book_count")
end)

test("getSortKey: falls back to default when saved value is invalid", function()
    _G._test_settings = { bookshelf_sort_authors = "garbage_value" }
    assert(Repo.getSortKey("authors") == "latest_read")
end)

test("getSortKey: returns nil for unknown chip", function()
    _G._test_settings = {}
    assert(Repo.getSortKey("nonexistent") == nil)
end)

test("getSeriesGroups: respects bookshelf_sort_series=book_count", function()
    Repo.invalidateWalkCache()
    Repo.invalidateSeriesCache()
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = (path == "/lib") and {".", "..",
            "small1.epub", "big1.epub", "big2.epub", "big3.epub"} or {".", ".."}
        local i = 0; return function() i = i+1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(fp, key)
        if key == "mode" then return "file" end
        return 0
    end
    _G._test_bim_data = {
        ["/lib/small1.epub"] = { title = "S1", series = "Smaller #1" },
        ["/lib/big1.epub"]   = { title = "B1", series = "Bigger #1" },
        ["/lib/big2.epub"]   = { title = "B2", series = "Bigger #2" },
        ["/lib/big3.epub"]   = { title = "B3", series = "Bigger #3" },
    }
    _G._test_settings = {
        home_dir = "/lib",
        bookshelf_latest_walk_depth = 1,
        bookshelf_sort_series = "book_count",
    }
    local out, total = Repo.getSeriesGroups(8)
    assert(total == 2, "expected 2 series groups, got " .. tostring(total))
    assert(out[1].series_name == "Bigger", "expected Bigger first (3 books), got " .. tostring(out[1].series_name))
    assert(out[2].series_name == "Smaller", "expected Smaller second (1 book), got " .. tostring(out[2].series_name))
end)

test("getLatest: sorts by mtime newest-first (the only valid sort for latest)", function()
    Repo.invalidateWalkCache()
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = (path == "/lib") and {".", "..", "z_oldest.epub", "a_newest.epub"} or {".", ".."}
        local i = 0; return function() i = i+1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(fp, key)
        if key == "mode" then return "file" end
        if key == "modification" then
            return fp:match("z_oldest") and 100 or 200
        end
        return nil
    end
    _G._test_mtime = { ["/lib/z_oldest.epub"] = 100, ["/lib/a_newest.epub"] = 200 }
    _G._test_bim_data = {
        ["/lib/z_oldest.epub"] = { title = "Aardvark" },
        ["/lib/a_newest.epub"] = { title = "Zebra" },
    }
    _G._test_settings = {
        home_dir = "/lib",
        bookshelf_latest_walk_depth = 1,
        -- Setting bookshelf_sort_latest is a no-op: _SORT_VALID['latest']
        -- only whitelists "mtime", so unknown sort keys fall through to
        -- the default which is also "mtime".
        bookshelf_sort_latest = "title",
    }
    local out = Repo.getLatest(8)
    assert(#out == 2)
    -- a_newest has the higher mtime so comes first, regardless of title.
    assert(out[1].title == "Zebra", "expected Zebra (newest mtime) first, got " .. tostring(out[1].title))
    assert(out[2].title == "Aardvark")
end)

-- ============================================================================
-- getLanguages
-- ============================================================================

test("getLanguages: region variants collapse and display the friendly name", function()
    -- All of en / en-US / en-GB should collapse to one card labelled "English".
    Repo.invalidateWalkCache()
    Repo.invalidateSeriesCache()
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = (path == "/lib") and {".", "..",
            "a.epub", "b.epub", "c.epub"} or {".", ".."}
        local i = 0; return function() i = i+1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(_fp, key)
        if key == "mode" then return "file" end; return 0
    end
    _G._test_bim_data = {
        ["/lib/a.epub"] = { title = "A", authors = "X", language = "en" },
        ["/lib/b.epub"] = { title = "B", authors = "X", language = "en-US" },
        ["/lib/c.epub"] = { title = "C", authors = "X", language = "en-GB" },
    }
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 1 }
    local out, total = Repo.getLanguages(10, 0)
    assert(total == 1, "expected 1 group, got " .. tostring(total))
    assert(out[1].series_name == "English",
        "expected display label 'English', got '" .. tostring(out[1].series_name) .. "'")
    assert(#out[1].books == 3, "expected 3 books in group, got " .. #out[1].books)
end)

test("getLanguages: underscore region variants collapse (zh_TW -> zh)", function()
    Repo.invalidateWalkCache()
    Repo.invalidateSeriesCache()
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = (path == "/lib") and {".", "..", "a.epub", "b.epub"} or {".", ".."}
        local i = 0; return function() i = i+1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(_fp, key)
        if key == "mode" then return "file" end; return 0
    end
    _G._test_bim_data = {
        ["/lib/a.epub"] = { title = "A", authors = "X", language = "zh_TW" },
        ["/lib/b.epub"] = { title = "B", authors = "X", language = "zh" },
    }
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 1 }
    local out, total = Repo.getLanguages(10, 0)
    assert(total == 1, "expected 1 group, got " .. tostring(total))
    assert(out[1].series_name == "Chinese",
        "expected display label 'Chinese', got '" .. tostring(out[1].series_name) .. "'")
    assert(#out[1].books == 2, "expected 2 books in group, got " .. #out[1].books)
end)

test("getLanguages: case-insensitive collapse (EN and en merge)", function()
    Repo.invalidateWalkCache()
    Repo.invalidateSeriesCache()
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = (path == "/lib") and {".", "..", "a.epub", "b.epub"} or {".", ".."}
        local i = 0; return function() i = i+1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(_fp, key)
        if key == "mode" then return "file" end; return 0
    end
    _G._test_bim_data = {
        ["/lib/a.epub"] = { title = "A", authors = "X", language = "EN" },
        ["/lib/b.epub"] = { title = "B", authors = "X", language = "en" },
    }
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 1 }
    local out, total = Repo.getLanguages(10, 0)
    assert(total == 1, "expected 1 group, got " .. tostring(total))
    assert(out[1].series_name == "English",
        "expected display label 'English', got '" .. tostring(out[1].series_name) .. "'")
    assert(#out[1].books == 2, "expected 2 books, got " .. #out[1].books)
end)

test("getLanguages: full language names resolve to the friendly label", function()
    -- "English" / "english" both resolve (via the name map) to the same key
    -- and the same friendly label as "en" / "eng".
    Repo.invalidateWalkCache()
    Repo.invalidateSeriesCache()
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = (path == "/lib") and {".", "..", "a.epub", "b.epub"} or {".", ".."}
        local i = 0; return function() i = i+1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(_fp, key)
        if key == "mode" then return "file" end; return 0
    end
    _G._test_bim_data = {
        ["/lib/a.epub"] = { title = "A", authors = "X", language = "English" },
        ["/lib/b.epub"] = { title = "B", authors = "X", language = "english" },
    }
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 1 }
    local out, total = Repo.getLanguages(10, 0)
    -- Both resolve to "eng" so they merge; display label is "English".
    assert(total == 1, "expected 1 group, got " .. tostring(total))
    assert(out[1].series_name == "English",
        "expected 'English', got '" .. tostring(out[1].series_name) .. "'")
    assert(#out[1].books == 2, "expected 2 books, got " .. #out[1].books)
end)

test("getLanguages: groups books by language metadata", function()
    Repo.invalidateWalkCache()
    Repo.invalidateSeriesCache()
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = (path == "/lib") and {".", "..",
            "en1.epub", "en2.epub", "es1.epub", "fr1.epub", "untagged.epub"}
            or {".", ".."}
        local i = 0; return function() i = i+1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(_fp, key)
        if key == "mode" then return "file" end
        return 0
    end
    _G._test_bim_data = {
        ["/lib/en1.epub"]      = { title = "E1", authors = "A", language = "en" },
        ["/lib/en2.epub"]      = { title = "E2", authors = "A", language = "en-US" },
        ["/lib/es1.epub"]      = { title = "S1", authors = "B", language = "es" },
        ["/lib/fr1.epub"]      = { title = "F1", authors = "C", language = "fr" },
        ["/lib/untagged.epub"] = { title = "U1", authors = "D" },  -- no language
    }
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 1 }
    local out, total = Repo.getLanguages(10, 0)
    -- 4 groups: English (en + en-US collapse), Spanish, French, Unknown.
    assert(total == 4, "expected 4 language groups, got " .. tostring(total))
    assert(out[1].series_name == "English", "expected 'English' first, got " .. tostring(out[1].series_name))
    assert(#out[1].books == 2, "expected the English group to have 2 books, got " .. #out[1].books)
end)

test("getLanguages: untagged books fall into the Unknown bucket", function()
    Repo.invalidateWalkCache()
    Repo.invalidateSeriesCache()
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = (path == "/lib") and {".", "..",
            "tagged.epub", "untagged1.epub", "untagged2.epub"} or {".", ".."}
        local i = 0; return function() i = i+1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(_fp, key)
        if key == "mode" then return "file" end; return 0
    end
    _G._test_bim_data = {
        ["/lib/tagged.epub"]    = { title = "T",  authors = "A", language = "en" },
        ["/lib/untagged1.epub"] = { title = "U1", authors = "B" },
        ["/lib/untagged2.epub"] = { title = "U2", authors = "C", language = "" },
    }
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 1 }
    local out, total = Repo.getLanguages(10, 0)
    assert(total == 2, "expected 2 groups (en + Unknown), got " .. tostring(total))
    local unknown
    for _i, g in ipairs(out) do
        if g.series_name == "Unknown" then unknown = g end
    end
    assert(unknown ~= nil, "expected an Unknown language group")
    assert(#unknown.books == 2,
        "expected Unknown group to hold 2 books, got " .. #unknown.books)
end)

test("getLanguages: findGroup resolves a language card by name", function()
    Repo.invalidateWalkCache()
    Repo.invalidateSeriesCache()
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = (path == "/lib") and {".", "..", "fr.epub"} or {".", ".."}
        local i = 0; return function() i = i+1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(_fp, key)
        if key == "mode" then return "file" end; return 0
    end
    _G._test_bim_data = {
        ["/lib/fr.epub"] = { title = "FR", authors = "C", language = "fr" },
    }
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 1 }
    Repo.getLanguages(10, 0)  -- warm cache
    -- Cards are labelled with the friendly name now, so drilldown resolves
    -- by "French" (the card's series_name), not the raw "fr" code.
    local g = Repo.findGroup("language", "French")
    assert(g ~= nil, "expected a language group")
    assert(g.series_name == "French")
    assert(#g.books == 1)
end)

-- ============================================================================
-- home_dir hardening: refuse to walk filesystem root or unset home_dir.
-- Reproduces the Reddit Kobo crash where tapping Home tab drove getAll
-- into "/" and the recursive walk OOM-killed KOReader.
-- ============================================================================

test("getAll: returns empty when home_dir is nil", function()
    Repo.invalidateWalkCache()
    _G._test_settings = { home_dir = nil }
    local dir_called = false
    package.loaded["libs/libkoreader-lfs"].dir = function(_path)
        dir_called = true
        return function() return nil end
    end
    local items, total = Repo.getAll()
    assert(items and #items == 0, "expected empty items")
    assert(total == 0, "expected total=0")
    assert(not dir_called, "lfs.dir must not be called when home_dir is nil")
end)

test("getAll: returns empty when home_dir is empty string", function()
    Repo.invalidateWalkCache()
    _G._test_settings = { home_dir = "" }
    local dir_called = false
    package.loaded["libs/libkoreader-lfs"].dir = function(_path)
        dir_called = true
        return function() return nil end
    end
    local items, total = Repo.getAll()
    assert(items and #items == 0)
    assert(total == 0)
    assert(not dir_called, "lfs.dir must not be called for empty home_dir")
end)

test("getAll: walks \"/\" but skips pseudo-filesystem subtrees", function()
    Repo.invalidateWalkCache()
    _G._test_settings = { home_dir = "/" }
    -- Track which top-level dirs the walk actually opens. A naive walk
    -- would call lfs.dir on /proc, /sys, /dev — the denylist must block
    -- those, while letting real dirs (mnt, home, etc.) through.
    local opened = {}
    package.loaded["libs/libkoreader-lfs"].dir = function(p)
        opened[p] = true
        local listings = {
            ["/"]      = { ".", "..", "proc", "sys", "dev", "run", "tmp",
                           "lost+found", "mnt", "home" },
            ["/mnt"]   = { ".", "..", "book.epub" },
            ["/home"]  = { ".", "..", "novel.epub" },
        }
        local files = listings[p] or {}
        local i = 0
        return function() i = i + 1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(fp, key)
        local modes = {
            ["/proc"]        = "directory", ["/sys"]  = "directory",
            ["/dev"]         = "directory", ["/run"]  = "directory",
            ["/tmp"]         = "directory", ["/lost+found"] = "directory",
            ["/mnt"]         = "directory", ["/home"] = "directory",
            ["/mnt/book.epub"]   = "file",
            ["/home/novel.epub"] = "file",
        }
        if key == "mode"         then return modes[fp] end
        if key == "size"         then return 100 end
        if key == "modification" then return 0 end
        if not key then
            if modes[fp] then return { mode = modes[fp], size = 100, modification = 0 } end
        end
    end
    _G._test_bim_data = {
        ["/mnt/book.epub"]   = { title = "MountBook" },
        ["/home/novel.epub"] = { title = "HomeNovel" },
    }
    local items = Repo.getAll(nil, 10, 0)
    assert(items, "getAll returned nil")
    -- Pseudo-fs dirs must not be opened anywhere in the walk.
    assert(not opened["/proc"], "denylist breach: /proc was walked")
    assert(not opened["/sys"], "denylist breach: /sys was walked")
    assert(not opened["/dev"], "denylist breach: /dev was walked")
    assert(not opened["/run"], "denylist breach: /run was walked")
    assert(not opened["/tmp"], "denylist breach: /tmp was walked")
    assert(not opened["/lost+found"], "denylist breach: /lost+found was walked")
end)

test("getAll: explicit drilldown path bypasses home_dir guard", function()
    Repo.invalidateWalkCache()
    _G._test_settings = { home_dir = nil }  -- bogus home_dir
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = (path == "/explicit") and { ".", "..", "x.epub" } or {}
        local i = 0
        return function() i = i + 1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(_fp, key)
        if key == "mode" then return "file" end
        if key == "size" then return 100 end
        if key == "modification" then return 0 end
        return { mode = "file", size = 100, modification = 0 }
    end
    _G._test_bim_data = { ["/explicit/x.epub"] = { title = "X" } }
    local items = Repo.getAll("/explicit", 10, 0)
    assert(items and #items == 1, "expected 1 item, got " .. tostring(items and #items))
    assert(items[1].title == "X")
end)

test("getAll: hydrates Hardcover enrichment for book rows", function()
    Repo.invalidateWalkCache()
    local fp = "/lib/enriched.epub"
    _G._test_settings = {
        home_dir = "/lib",
        bookshelf_latest_walk_depth = 1,
        bookshelf_hardcover_links = {
            [fp] = { book_id = 123, title = "Remote Link",
                     use_description = true, use_cover = true },
        },
    }
    hccache.clear()
    hccache.seed("enrich", "123", {
        description = "Remote description",
        cover_path = "/tmp/remote-cover.jpg",
    })
    local Hardcover = require("lib/bookshelf_hardcover")
    Hardcover.invalidate()
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = (path == "/lib") and { ".", "..", "enriched.epub" } or {}
        local i = 0
        return function() i = i + 1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(_fp, key)
        if key == "mode" then return "file" end
        if key == "size" then return 100 end
        if key == "modification" then return 0 end
        return { mode = "file", size = 100, modification = 0 }
    end
    _G._test_bim_data = {
        [fp] = {
            has_meta = "Y",
            title = "Local Title",
            authors = "Local Author",
        },
    }

    local items, total = Repo.getAll(nil, 10, 0)
    assert(total == 1, "expected total=1, got " .. tostring(total))
    assert(items and #items == 1, "expected one hydrated item")
    assert(items[1].description == "Remote description", "missing Hardcover description")
    assert(items[1].cover_image_path == "/tmp/remote-cover.jpg", "missing Hardcover cover")
    assert(items[1].hardcover_book_id == 123, "missing Hardcover book id")

    -- Second call exercises getAll's shape-cache HIT hydration path.
    local cached_items, cached_total = Repo.getAll(nil, 10, 0)
    assert(cached_total == 1, "expected cached total=1")
    assert(cached_items and #cached_items == 1, "expected one cached hydrated item")
    assert(cached_items[1].description == "Remote description", "cached path missed Hardcover description")
    assert(cached_items[1].cover_image_path == "/tmp/remote-cover.jpg", "cached path missed Hardcover cover")
end)

test("getLatest: unset home_dir falls back to / and walks safely (denylist active)", function()
    Repo.invalidateWalkCache()
    -- home_dir nil → getLatest's `or "/"` fallback fires → walkBooks
    -- walks "/" with SYSTEM_DIR_NAMES filtering. The user-visible result
    -- is whatever real subtrees exist under "/" without /proc /sys etc.
    _G._test_settings = { home_dir = nil, bookshelf_latest_walk_depth = 2 }
    local opened = {}
    package.loaded["libs/libkoreader-lfs"].dir = function(p)
        opened[p] = true
        local listings = {
            ["/"]    = { ".", "..", "proc", "sys", "dev" },  -- no real subdirs
        }
        local files = listings[p] or {}
        local i = 0
        return function() i = i + 1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(fp, key)
        if key == "mode" and (fp == "/proc" or fp == "/sys" or fp == "/dev") then
            return "directory"
        end
        if key == "modification" then return 0 end
    end
    local out = Repo.getLatest(5)
    assert(out and #out == 0, "expected no books (only pseudo-fs at root)")
    assert(opened["/"], "walk should still open / (denylist filters children, not root)")
    assert(not opened["/proc"], "denylist breach: /proc opened")
    assert(not opened["/sys"], "denylist breach: /sys opened")
    assert(not opened["/dev"], "denylist breach: /dev opened")
end)

test("getLatest: walks \"/\" but never descends into /proc /sys /dev", function()
    Repo.invalidateWalkCache()
    _G._test_settings = { home_dir = "/", bookshelf_latest_walk_depth = 3 }
    local opened = {}
    package.loaded["libs/libkoreader-lfs"].dir = function(p)
        opened[p] = true
        local listings = {
            ["/"]     = { ".", "..", "proc", "sys", "dev", "run", "mnt" },
            ["/mnt"]  = { ".", "..", "found.epub" },
            -- proc/sys/dev/run intentionally omitted: if the denylist is
            -- breached, lfs.dir(<denied>) will be called and listings[p]
            -- returns nil → the iterator yields nothing, but `opened`
            -- still records the breach.
        }
        local files = listings[p] or {}
        local i = 0
        return function() i = i + 1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(fp, key)
        local modes = {
            ["/proc"] = "directory", ["/sys"] = "directory",
            ["/dev"]  = "directory", ["/run"] = "directory",
            ["/mnt"]  = "directory",
            ["/mnt/found.epub"] = "file",
        }
        if key == "mode"         then return modes[fp] end
        if key == "modification" then return 100 end
    end
    _G._test_bim_data = { ["/mnt/found.epub"] = { title = "Found" } }
    local out = Repo.getLatest(5)
    -- The real book under /mnt should surface; pseudo-fs roots stay unopened.
    assert(out and #out == 1, "expected 1 book under /mnt, got " .. tostring(out and #out))
    assert(out[1].title == "Found")
    assert(not opened["/proc"], "walkBooks descended into /proc despite denylist")
    assert(not opened["/sys"], "walkBooks descended into /sys despite denylist")
    assert(not opened["/dev"], "walkBooks descended into /dev despite denylist")
    assert(not opened["/run"], "walkBooks descended into /run despite denylist")
end)

-- ============================================================================
-- buildBookMeta hardening: a single throwing book must not kill the page
-- ============================================================================

test("getAll: a buildBookMeta failure on one entry doesn't kill the page", function()
    Repo.invalidateWalkCache()
    _G._test_settings = { home_dir = "/lib" }
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = (path == "/lib")
            and { ".", "..", "good.epub", "bad.epub", "also_good.epub" }
            or {}
        local i = 0
        return function() i = i + 1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(_fp, key)
        if key == "mode" then return "file" end
        if key == "size" then return 100 end
        if key == "modification" then return 0 end
        return { mode = "file", size = 100, modification = 0 }
    end
    -- Make BIM throw for /lib/bad.epub but return data for the other two.
    package.loaded["bookinfomanager"] = {
        getBookInfo = function(_self, fp, _with_cover)
            if fp == "/lib/bad.epub" then error("simulated parser blow-up on " .. fp) end
            local data = {
                ["/lib/good.epub"]      = { title = "Good" },
                ["/lib/also_good.epub"] = { title = "Also Good" },
            }
            return data[fp]
        end,
    }
    local items, total = Repo.getAll(nil, 10, 0)
    -- Since #71 (pcall-guard inside buildBookMeta), a throwing BIM row no
    -- longer drops the book: getBookInfo's blow-up is caught and the entry
    -- degrades to a filename-fallback record instead of crashing the page.
    -- So all three survive, with bad.epub present but un-hydrated.
    assert(total == 3, "expected 3 shapes, got " .. tostring(total))
    assert(items and #items == 3, "expected 3 surviving items, got " .. tostring(items and #items))
    local by_path = {}
    for _i, it in ipairs(items) do by_path[it.filepath] = it end
    assert(by_path["/lib/bad.epub"], "throwing entry should survive via fallback, not drop")
    -- Restore the default BIM stub so other tests are unaffected.
    package.loaded["bookinfomanager"] = {
        getBookInfo = function(_self, fp, _with_cover)
            return _G._test_bim_data and _G._test_bim_data[fp] or nil
        end,
    }
end)

-- #113 / issue 90: "sort folders by book count" must order folder cards by
-- how many books each holds (recursively). Regression guard for the
-- single-pass counting in getAll's needs.book_count block: a book under a
-- listed folder is attributed to that folder, so the sort value matches the
-- badge. Folder names are deliberately anti-correlated with their counts so
-- a broken counter (all zero -> name tie-break) sorts differently.
test("getAll: sort by book_count orders folders by recursive book count", function()
    Repo.invalidateWalkCache()
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 2 }
    _G._test_bim_data = {
        ["/lib/aaa/x1.epub"] = { title = "x1" },
        ["/lib/bbb/y1.epub"] = { title = "y1" },
        ["/lib/bbb/y2.epub"] = { title = "y2" },
        ["/lib/bbb/y3.epub"] = { title = "y3" },
        ["/lib/ccc/z1.epub"] = { title = "z1" },
        ["/lib/ccc/z2.epub"] = { title = "z2" },
    }
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local listings = {
            ["/lib"]     = { ".", "..", "aaa", "bbb", "ccc" },
            ["/lib/aaa"] = { ".", "..", "x1.epub" },
            ["/lib/bbb"] = { ".", "..", "y1.epub", "y2.epub", "y3.epub" },
            ["/lib/ccc"] = { ".", "..", "z1.epub", "z2.epub" },
        }
        local files = listings[path] or {}
        local i = 0
        return function() i = i + 1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(fp, key)
        local is_dir = (fp == "/lib/aaa" or fp == "/lib/bbb" or fp == "/lib/ccc")
        local mode   = is_dir and "directory" or "file"
        if key == nil then return { mode = mode, modification = 0 } end
        if key == "mode"         then return mode end
        if key == "modification" then return 0 end
        return nil
    end
    -- Descending book_count: bbb(3), ccc(2), aaa(1). Name order would be the
    -- reverse, so a correct count is the only way to get this order.
    local items, total = Repo.getAll(nil, 10, 0, { { key = "book_count", reverse = true } })
    assert(total == 3, "expected 3 folder shapes, got " .. tostring(total))
    assert(items and #items == 3, "expected 3 items, got " .. tostring(items and #items))
    assert(items[1].path == "/lib/bbb",
        "highest count folder should sort first, got " .. tostring(items[1].path))
    assert(items[2].path == "/lib/ccc",
        "middle count folder should sort second, got " .. tostring(items[2].path))
    assert(items[3].path == "/lib/aaa",
        "lowest count folder should sort last, got " .. tostring(items[3].path))
    Repo.invalidateWalkCache()
end)

-- ============================================================================
-- Task 3.1: getBySource generic resolver
-- ============================================================================
-- Shared setup helpers for the resolver smoke tests.
-- Three books in two subdirs under /lib:
--   /lib/comics/alpha.epub  keywords="manga"
--   /lib/comics/bravo.epub  keywords="manga"
--   /lib/novels/charlie.epub  keywords="sci-fi"
--
-- loadCandidatesByPredicate uses cachedWalk internally (depth=2), so
-- the lfs stub must handle directory recursion: lfs.attributes(fp) with
-- no key argument must return a table for walkBooks' fast-path branch.

local function _setupResolverLibrary()
    Repo.invalidateWalkCache()
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 2 }
    _G._test_bim_data = {
        ["/lib/comics/alpha.epub"]   = { title = "Alpha",   keywords = "manga"  },
        ["/lib/comics/bravo.epub"]   = { title = "Bravo",   keywords = "manga"  },
        ["/lib/novels/charlie.epub"] = { title = "Charlie", keywords = "sci-fi" },
    }
    -- Stub readcollection: wishlist has just alpha.epub.
    package.loaded["readcollection"] = {
        coll = {
            favorites = {},
            wishlist  = { { file = "/lib/comics/alpha.epub" } },
        },
        default_collection_name = "favorites",
    }
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local listings = {
            ["/lib"]         = { ".", "..", "comics", "novels" },
            ["/lib/comics"]  = { ".", "..", "alpha.epub", "bravo.epub" },
            ["/lib/novels"]  = { ".", "..", "charlie.epub" },
        }
        local files = listings[path] or {}
        local i = 0
        return function() i = i + 1; return files[i] end
    end
    -- lfs.attributes(fp) with no-key arg must return a table so walkBooks'
    -- fast-path branch (`if attr and ...`) correctly classifies dirs vs files.
    -- The keyed form (mode/modification) is the fallback for stubs that return nil.
    package.loaded["libs/libkoreader-lfs"].attributes = function(fp, key)
        local is_dir = (fp == "/lib/comics" or fp == "/lib/novels")
        local mode   = is_dir and "directory" or "file"
        if key == nil then
            -- Return a full table so walkBooks skips the two-call fallback.
            return { mode = mode, modification = 0 }
        end
        if key == "mode"         then return mode end
        if key == "modification" then return 0 end
        return nil
    end
    package.loaded["bookinfomanager"] = {
        getBookInfo = function(_self, fp, _with_cover)
            return _G._test_bim_data and _G._test_bim_data[fp] or nil
        end,
    }
end

local function _teardownResolverLibrary()
    -- Restore the default BIM and collection stubs so later tests are clean.
    package.loaded["bookinfomanager"] = {
        getBookInfo = function(_self, fp, _with_cover)
            return _G._test_bim_data and _G._test_bim_data[fp] or nil
        end,
    }
    package.loaded["readcollection"] = {
        coll = { favorites = {} },
        default_collection_name = "favorites",
    }
    Repo.invalidateWalkCache()
end

test("getBySource: folder kind returns folder+book cards at the picked path", function()
    -- Folder chips share Home (folders)'s tree view: dispatched via
    -- Repo.getAll(source.id), so subfolders appear as folder cards and
    -- books at that level appear as book cards. source.id is stored
    -- without a trailing slash (matches the drilldown shape.path
    -- convention and avoids _joinPath double-slashing).
    _setupResolverLibrary()
    local list, total = Repo.getBySource({ kind = "folder", id = "/lib/comics" }, nil, nil, 0, 10)
    _teardownResolverLibrary()
    assert(type(list) == "table", "expected table, got " .. type(list))
    -- /lib/comics has no subfolders in the test library, so we get the
    -- two book cards (alpha, bravo) -- same count as the old flat path.
    assert(#list == 2, "expected 2 books in /lib/comics, got " .. #list)
    assert(total == 2, "expected total=2, got " .. tostring(total))
end)

test("getBySource: collection kind returns books in the named collection", function()
    _setupResolverLibrary()
    local list, total = Repo.getBySource({ kind = "collection", id = "wishlist" }, nil, nil, 0, 10)
    _teardownResolverLibrary()
    assert(type(list) == "table")
    assert(#list == 1, "expected 1 book in wishlist, got " .. #list)
    assert(list[1].title == "Alpha", "expected Alpha, got " .. tostring(list[1].title))
    assert(total == 1, "expected total=1, got " .. tostring(total))
end)

test("getBySource: a collection keeps its native KOReader order (#441)", function()
    _setupResolverLibrary()
    -- A native collection stores a per-item `order`, and KOReader's own
    -- getOrderedCollection sorts on exactly that. Set here as the REVERSE of
    -- alphabetical, so a path that discards the order and falls back to the
    -- engine's title/filename tie-break cannot pass by accident.
    package.loaded["readcollection"].coll.reading = {
        ["/lib/novels/charlie.epub"] = { file = "/lib/novels/charlie.epub", order = 1 },
        ["/lib/comics/bravo.epub"]   = { file = "/lib/comics/bravo.epub",   order = 2 },
        ["/lib/comics/alpha.epub"]   = { file = "/lib/comics/alpha.epub",   order = 3 },
    }
    local list = Repo.getBySource({ kind = "collection", id = "reading" }, nil,
                                  { { key = "collection_order", reverse = false } }, 0, 10)
    _teardownResolverLibrary()
    local got = {}
    for i, b in ipairs(list) do got[i] = b.title end
    got = table.concat(got, ",")
    assert(got == "Charlie,Bravo,Alpha",
        "expected the collection's own order, got " .. got)
end)

test("getBySource: genre kind filters books via BIM keywords->genres mapping", function()
    _setupResolverLibrary()
    -- buildBookMeta maps BIM `keywords` string -> genres array; the genre
    -- predicate in getBySource checks b.genres, so this exercises the full path.
    local list, total = Repo.getBySource({ kind = "genre", id = "manga" }, nil, nil, 0, 10)
    _teardownResolverLibrary()
    assert(type(list) == "table")
    assert(#list == 2, "expected 2 manga books, got " .. #list)
    assert(total == 2, "expected total=2, got " .. tostring(total))
end)

test("getBySource: unknown kind returns empty list and zero total", function()
    local list, total = Repo.getBySource({ kind = "not_a_real_kind" }, nil, nil, 0, 10)
    assert(type(list) == "table")
    assert(#list == 0, "expected empty list for unknown kind, got " .. #list)
    assert(total == 0, "expected total=0, got " .. tostring(total))
end)

-- ─── kindle kind (issue #355) ────────────────────────────────────────────────
-- Records come from the Kindle catalogue bridge, not from the filesystem or
-- BIM, so the dispatch's job is: ask the source, sort with the shelf's own
-- SortEngine (the point of the exercise -- the Kindle plugin's own list has one
-- hardcoded title order), paginate, and stay inert when there is no Kindle.
local function _fakeKindleSource(books, available)
    local by_path = {}
    for _i, b in ipairs(books or {}) do
        by_path[b.filepath] = b
        if b.kindle_source_path then by_path[b.kindle_source_path] = b end
    end
    local fake = {
        isAvailable = function() return available ~= false end,
        listBooks = function() return books or {} end,
        recordFor = function(path) return by_path[path] end,
        _calls = 0,
    }
    package.loaded["lib/bookshelf_kindle_source"] = fake
    return fake
end
local function _kindleBook(title, pct)
    return {
        filepath = "/mnt/us/documents/" .. title .. ".kfx",
        filename = title .. ".kfx",
        title = title, display_title = title,
        format = "kfx", book_pct = pct, is_kindle = true,
        attr = { mode = "file", size = 1000, modification = 0 },
    }
end

test("getBySource: kindle kind lists the catalogue bridge's books", function()
    _fakeKindleSource({ _kindleBook("Mort"), _kindleBook("Equal Rites") })
    local list, total = Repo.getBySource({ kind = "kindle" }, nil, nil, 0, 10)
    package.loaded["lib/bookshelf_kindle_source"] = nil
    assert(#list == 2, "expected 2 Kindle books, got " .. #list)
    assert(total == 2, "expected total=2, got " .. tostring(total))
    assert(list[1].is_kindle == true, "records keep their Kindle marker")
end)

test("getBySource: kindle kind sorts with the shelf's sort_priority", function()
    _fakeKindleSource({ _kindleBook("Mort"), _kindleBook("Equal Rites"), _kindleBook("Sourcery") })
    local list = Repo.getBySource({ kind = "kindle" }, nil,
        { { key = "title", reverse = false } }, 0, 10)
    package.loaded["lib/bookshelf_kindle_source"] = nil
    assert(list[1].title == "Equal Rites",
        "expected title sort, got " .. tostring(list[1].title))
    assert(list[3].title == "Sourcery", "expected Sourcery last, got " .. tostring(list[3].title))
end)

test("getBySource: kindle kind paginates and still reports the full total", function()
    _fakeKindleSource({ _kindleBook("A"), _kindleBook("B"), _kindleBook("C"), _kindleBook("D") })
    local list, total = Repo.getBySource({ kind = "kindle" }, nil,
        { { key = "title", reverse = false } }, 2, 2)
    package.loaded["lib/bookshelf_kindle_source"] = nil
    assert(#list == 2, "expected a 2-book page, got " .. #list)
    assert(total == 4, "total must be the whole shelf, got " .. tostring(total))
    assert(list[1].title == "C", "expected the third book first, got " .. tostring(list[1].title))
end)

test("buildBook: re-attaches the Kindle identity when rehydrating from a path", function()
    -- The hero and the tap-preview rebuild a record from its filepath alone (six
    -- call sites in the widget). A Kindle record that lost is_kindle on the way
    -- through would then be handed to ReaderUI as a raw .kfx, which it cannot
    -- read: the book would just fail to open. Re-attaching here fixes every one
    -- of those sites at once.
    local kfx = "/mnt/us/documents/The Goal.kfx"
    _fakeKindleSource({ {
        filepath = kfx, kindle_source_path = kfx,
        title = "The Goal", author = "Goldratt, Eliyahu M.",
        cover_image_path = "/mnt/us/system/thumbnails/thumbnail_B002LHRM2O_EBOK_portrait.jpg",
        book_pct = 0.886, status = "reading", is_kindle = true,
        kindle_book_id = "cc:abc",
    } })
    local b = Repo.buildBook(kfx)
    package.loaded["lib/bookshelf_kindle_source"] = nil
    assert(b ~= nil, "buildBook returned nil for a Kindle path")
    assert(b.is_kindle == true, "is_kindle must survive rehydration")
    assert(b.kindle_book_id == "cc:abc", "the catalogue id must survive")
    -- BIM knows nothing about a .kfx, so the catalogue's presentation data is
    -- all there is; without it the hero shows a bare filename.
    assert(b.title == "The Goal", "title fell back to the catalogue, got " .. tostring(b.title))
    assert(b.cover_image_path ~= nil, "cover path must survive")
end)

test("buildBookMeta: re-attaches the Kindle identity, cover and catalogue title", function()
    -- buildBookMeta, not buildBook, is the funnel that matters: three sites in
    -- the widget rebuild ONE spine through it and write the result straight back
    -- into _page_items (see find_and_swap and the selection repaint). A Kindle
    -- record replaced there loses its cover and its title, and because the page
    -- array itself is overwritten the damage survives every later rebuild --
    -- which is exactly the "tapped cover turns into a placeholder" bug.
    local kfx = "/mnt/us/documents/Goldratt/The Goal.kfx"
    local thumb = "/mnt/us/system/thumbnails/thumbnail_B002LHRM2O_EBOK_portrait.jpg"
    _fakeKindleSource({ {
        filepath = kfx, kindle_source_path = kfx,
        title = "The Goal: A Process of Ongoing Improvement",
        display_title = "The Goal: A Process of Ongoing Improvement",
        author = "Goldratt, Eliyahu M.", cover_image_path = thumb,
        is_kindle = true, kindle_book_id = "cc:abc",
    } })
    local b = Repo.buildBookMeta(kfx)
    package.loaded["lib/bookshelf_kindle_source"] = nil
    assert(b ~= nil, "buildBookMeta returned nil")
    assert(b.is_kindle == true, "is_kindle must survive")
    assert(b.cover_image_path == thumb, "cover path must survive, got " .. tostring(b.cover_image_path))
    -- BIM knows nothing about a .kfx, so buildBookMeta falls back to the
    -- filename as a title. The catalogue's title is strictly better and must win.
    assert(b.title == "The Goal: A Process of Ongoing Improvement",
        "catalogue title must beat the filename fallback, got " .. tostring(b.title))
end)

test("buildBookMeta: keeps the flags the OPEN path needs, not just the visible ones", function()
    -- Opening a book rehydrates its record first (the per-book spine swap writes
    -- the buildBookMeta result straight back into _page_items), so every field
    -- the open path reads has to survive that -- not only the ones you can see.
    --
    -- Both of these were lost, with consequences: without kindle_needs_prepare a
    -- tap skips the "this takes a few minutes" confirm and drops the user into an
    -- uncancellable conversion; without kindle_block_reason a blocked book falls
    -- back to "drm" and is refused with the wrong explanation.
    local kfx = "/mnt/us/documents/Campaign.kfx"
    _fakeKindleSource({ {
        filepath = kfx, kindle_source_path = kfx, title = "Campaign",
        is_kindle = true, kindle_needs_prepare = true,
    } })
    local b = Repo.buildBookMeta(kfx)
    package.loaded["lib/bookshelf_kindle_source"] = nil
    assert(b.kindle_needs_prepare == true,
        "kindle_needs_prepare must survive rehydration (the prepare confirm)")

    local azw3 = "/mnt/us/documents/Unreadable.azw3"
    _fakeKindleSource({ {
        filepath = azw3, kindle_source_path = azw3, title = "Unreadable",
        is_kindle = true, kindle_blocked = true, kindle_block_reason = "unsupported",
    } })
    local blocked = Repo.buildBookMeta(azw3)
    package.loaded["lib/bookshelf_kindle_source"] = nil
    assert(blocked.kindle_blocked == true, "still blocked")
    assert(blocked.kindle_block_reason == "unsupported",
        "the reason must survive, or the wrong refusal message is shown; got "
        .. tostring(blocked.kindle_block_reason))
end)

test("buildBookMeta: a real embedded title still beats the catalogue's", function()
    -- Once a book has been converted, the EPUB's own metadata is what the reader
    -- shows, so it wins -- the catalogue only fills a gap.
    local epub = "/cache/kindle.koplugin/cc_abc.epub"
    _G._test_bim_data = { [epub] = { title = "The Goal", authors = "Eliyahu M. Goldratt" } }
    _fakeKindleSource({ {
        filepath = epub, kindle_source_path = "/mnt/us/documents/The Goal.kfx",
        title = "Catalogue Title That Should Lose", is_kindle = true,
    } })
    local b = Repo.buildBookMeta(epub)
    package.loaded["lib/bookshelf_kindle_source"] = nil
    _G._test_bim_data = nil
    assert(b.title == "The Goal", "embedded title must win, got " .. tostring(b.title))
    assert(b.is_kindle == true, "identity still re-attached")
end)

test("buildBook: leaves an ordinary book untouched when a Kindle library exists", function()
    -- The overlay must be strictly scoped to paths the Kindle source knows.
    _fakeKindleSource({ { filepath = "/mnt/us/documents/Kindle.kfx", is_kindle = true } })
    _G._test_bim_data = { ["/books/normal.epub"] = { title = "Normal Book" } }
    local b = Repo.buildBook("/books/normal.epub")
    package.loaded["lib/bookshelf_kindle_source"] = nil
    _G._test_bim_data = nil
    assert(b.is_kindle == nil, "an ordinary book must not be marked as Kindle")
    assert(b.title == "Normal Book", "title unchanged, got " .. tostring(b.title))
end)

test("getBySource: kindle shelf honours a Hardcover cover, not just the hero", function()
    -- Kindle records come from the catalogue bridge, so they never pass through
    -- buildBookMeta -- which is where the two cover overrides live (a picked
    -- custom cover, then Hardcover for a linked use_cover book). Without them
    -- the shelf keeps showing Amazon's thumbnail while the hero shows the
    -- Hardcover art, and a per-book repaint makes the shelf cover flicker to the
    -- Hardcover one and back.
    local kfx = "/mnt/us/documents/Linked.kfx"
    local thumb = "/mnt/us/system/thumbnails/thumbnail_LINKED_EBOK_portrait.jpg"
    _G._test_settings = {
        bookshelf_hardcover_links = {
            [kfx] = { book_id = 777, title = "Linked", use_cover = true },
        },
    }
    hccache.clear()
    hccache.seed("enrich", "777", { cover_path = "/tmp/hardcover-linked.jpg" })
    local Hardcover = require("lib/bookshelf_hardcover")
    Hardcover.invalidate()

    _fakeKindleSource({ {
        filepath = kfx, kindle_source_path = kfx, title = "Linked",
        cover_image_path = thumb, is_kindle = true,
    } })
    local list = Repo.getBySource({ kind = "kindle" }, nil, nil, 0, 10)
    package.loaded["lib/bookshelf_kindle_source"] = nil
    _G._test_settings = nil
    hccache.clear()
    Hardcover.invalidate()
    assert(list[1].cover_image_path == "/tmp/hardcover-linked.jpg",
        "shelf must use the Hardcover cover, got " .. tostring(list[1].cover_image_path))
end)

test("getBySource: an unlinked Kindle book keeps its catalogue thumbnail", function()
    local kfx = "/mnt/us/documents/Plain.kfx"
    local thumb = "/mnt/us/system/thumbnails/thumbnail_PLAIN_EBOK_portrait.jpg"
    _fakeKindleSource({ {
        filepath = kfx, kindle_source_path = kfx, title = "Plain",
        cover_image_path = thumb, is_kindle = true,
    } })
    local list = Repo.getBySource({ kind = "kindle" }, nil, nil, 0, 10)
    package.loaded["lib/bookshelf_kindle_source"] = nil
    assert(list[1].cover_image_path == thumb,
        "no override -> Amazon's thumbnail, got " .. tostring(list[1].cover_image_path))
end)

-- ─── Kindle books in local search (issue #355) ───────────────────────────────
-- Search is where "do I already have this?" gets asked, and until now the answer
-- ignored the Kindle library entirely -- you had to be standing on the Kindle
-- chip. The chip is the opt-in signal: having made one means those books are part
-- of the library you think of as yours, so search covers them.
local function _kindleChipConfigured(yes)
    _G._test_settings = _G._test_settings or {}
    _G._test_settings["bookshelf_tabs"] = yes
        and { { id = "all", label = "Home", source = { kind = "all" } },
              { id = "kindle-1", label = "Kindle", source = { kind = "kindle" } } }
        or  { { id = "all", label = "Home", source = { kind = "all" } } }
end

test("searchBooks: finds a Kindle book when a Kindle chip is configured", function()
    _kindleChipConfigured(true)
    _fakeKindleSource({ {
        filepath = "/mnt/us/documents/Mort.kfx", kindle_source_path = "/mnt/us/documents/Mort.kfx",
        title = "Mort", author = "Terry Pratchett", is_kindle = true,
    } })
    local hits = Repo.searchBooks("pratchett", 20)
    package.loaded["lib/bookshelf_kindle_source"] = nil
    _G._test_settings = nil
    local found
    for _i, b in ipairs(hits) do if b.title == "Mort" then found = b end end
    assert(found ~= nil, "Kindle book missing from search results")
    assert(found.is_kindle == true, "and it keeps its Kindle identity")
end)

test("searchBooks: ignores the Kindle library when no Kindle chip is configured", function()
    _kindleChipConfigured(false)
    _fakeKindleSource({ {
        filepath = "/mnt/us/documents/Mort.kfx", title = "Mort",
        author = "Terry Pratchett", is_kindle = true,
    } })
    local hits = Repo.searchBooks("pratchett", 20)
    package.loaded["lib/bookshelf_kindle_source"] = nil
    _G._test_settings = nil
    for _i, b in ipairs(hits) do
        assert(b.title ~= "Mort", "Kindle book leaked into search without a Kindle chip")
    end
end)

test("searchBooks: ignores the Kindle library when it isn't available", function()
    -- Non-Kindle device, or the plugin gone: a chip may still be configured from
    -- a previous device, and must not produce results.
    _kindleChipConfigured(true)
    _fakeKindleSource({ { filepath = "/x/Mort.kfx", title = "Mort", is_kindle = true } }, false)
    local hits = Repo.searchBooks("mort", 20)
    package.loaded["lib/bookshelf_kindle_source"] = nil
    _G._test_settings = nil
    for _i, b in ipairs(hits) do
        assert(b.title ~= "Mort", "unavailable Kindle library produced results")
    end
end)

test("searchBooks: a Kindle book must match every query word, like any other", function()
    _kindleChipConfigured(true)
    _fakeKindleSource({ {
        filepath = "/mnt/us/documents/Mort.kfx", title = "Mort",
        author = "Terry Pratchett", is_kindle = true,
    } })
    local both = Repo.searchBooks("mort pratchett", 20)
    local wrong = Repo.searchBooks("mort tolkien", 20)
    package.loaded["lib/bookshelf_kindle_source"] = nil
    _G._test_settings = nil
    local hit_both, hit_wrong = false, false
    for _i, b in ipairs(both)  do if b.title == "Mort" then hit_both  = true end end
    for _i, b in ipairs(wrong) do if b.title == "Mort" then hit_wrong = true end end
    assert(hit_both, "title + author should match")
    assert(not hit_wrong, "a word matching nothing must exclude the book")
end)

test("searchAll: surfaces Kindle books through the books section", function()
    _kindleChipConfigured(true)
    _fakeKindleSource({ {
        filepath = "/mnt/us/documents/Mort.kfx", title = "Mort",
        author = "Terry Pratchett", is_kindle = true,
    } })
    local res = Repo.searchAll("pratchett")
    package.loaded["lib/bookshelf_kindle_source"] = nil
    _G._test_settings = nil
    local found = false
    for _i, b in ipairs(res.books or {}) do if b.title == "Mort" then found = true end end
    assert(found, "searchAll should inherit searchBooks' Kindle results")
end)

-- ─── The shelf-wide tallies count the Kindle library too ────────────────────
-- countByStatus feeds the Shelf size module, countFinishedBooks feeds
-- %books_read. Both asked getAllFilepaths -- the WALKED library -- so a user
-- with a Kindle chip was shown a shelf size that left their Kindle books out.
-- Measured on a PW5: 247 reported, 353 actually on the shelf, and 14 finished
-- against 18. Same opt-in as search: no Kindle chip, no change.
local _walk_prev
local function _setupWalk(files, statuses, kindle_chip)
    Repo.invalidateWalkCache()
    Repo.invalidateProgressCache()
    _G._test_bim_data = {}
    for _i, name in ipairs(files) do
        _G._test_bim_data["/lib/" .. name] = { title = name }
    end
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 1 }
    _kindleChipConfigured(kindle_chip)
    _G._test_docsettings_data = {}
    for name, st in pairs(statuses or {}) do
        _G._test_docsettings_data["/lib/" .. name] = { summary = { status = st } }
    end
    local lfs_stub = package.loaded["libs/libkoreader-lfs"]
    _walk_prev = { dir = lfs_stub.dir, attributes = lfs_stub.attributes,
                   sidecar = package.loaded["docsettings"].hasSidecarFile }
    lfs_stub.dir = function(path)
        local entries = { ".", ".." }
        if path == "/lib" then
            for _i, name in ipairs(files) do entries[#entries + 1] = name end
        end
        local i = 0
        return function() i = i + 1; return entries[i] end
    end
    lfs_stub.attributes = function(_fp, key)
        if key == "mode" then return "file" end
        if key == "modification" then return 0 end
    end
    package.loaded["docsettings"].hasSidecarFile = function(_self, fp)
        return _G._test_docsettings_data[fp] ~= nil
    end
end

local function _teardownWalk()
    local lfs_stub = package.loaded["libs/libkoreader-lfs"]
    lfs_stub.dir, lfs_stub.attributes = _walk_prev.dir, _walk_prev.attributes
    package.loaded["docsettings"].hasSidecarFile = _walk_prev.sidecar
    package.loaded["lib/bookshelf_kindle_source"] = nil
    _G._test_settings = {}
    _G._test_docsettings_data = nil
    Repo.invalidateWalkCache()
    Repo.invalidateProgressCache()
end

test("countByStatus: Kindle books count towards the shelf's size", function()
    _setupWalk({ "done.epub", "reading.epub" },
               { ["done.epub"] = "complete", ["reading.epub"] = "reading" }, true)
    _fakeKindleSource({
        { filepath = "/k/a.kfx", title = "A", _status = "finished" },
        { filepath = "/k/b.kfx", title = "B", _status = "reading"  },
        { filepath = "/k/c.kfx", title = "C", _status = "unread"   },
    })
    local total, counts = Repo.countByStatus()
    _teardownWalk()
    assert(total == 5, "2 walked + 3 Kindle = 5, got " .. tostring(total))
    assert(counts.finished == 2, "finished should be 1 + 1, got " .. tostring(counts.finished))
    assert(counts.reading  == 2, "reading should be 1 + 1, got "  .. tostring(counts.reading))
    assert(counts.unread   == 1, "unread should be 0 + 1, got "   .. tostring(counts.unread))
end)

test("countByStatus: no Kindle chip leaves the tally exactly as it was", function()
    -- The opt-in. A user who has never made a Kindle chip must see the same
    -- number as before, even on a Kindle with a readable catalogue.
    _setupWalk({ "done.epub", "reading.epub" },
               { ["done.epub"] = "complete", ["reading.epub"] = "reading" }, false)
    _fakeKindleSource({
        { filepath = "/k/a.kfx", title = "A", _status = "finished" },
        { filepath = "/k/b.kfx", title = "B", _status = "unread"   },
    })
    local total, counts = Repo.countByStatus()
    _teardownWalk()
    assert(total == 2, "walked library only, got " .. tostring(total))
    assert(counts.finished == 1, "got " .. tostring(counts.finished))
    assert(counts.unread == 0, "the Kindle unread must not leak in, got " .. tostring(counts.unread))
end)

test("countByStatus: an unreadable Kindle library leaves the tally alone", function()
    -- A chip carried over from another device, on hardware with no catalogue.
    _setupWalk({ "done.epub" }, { ["done.epub"] = "complete" }, true)
    _fakeKindleSource({ { filepath = "/k/a.kfx", title = "A", _status = "finished" } }, false)
    local total = Repo.countByStatus()
    _teardownWalk()
    assert(total == 1, "unavailable source must contribute nothing, got " .. tostring(total))
end)

test("countFinishedBooks: a book finished on the Kindle counts as finished", function()
    -- Both spellings, because normalisation lives elsewhere and a change there
    -- must not silently drop Kindle books out of %books_read.
    _setupWalk({ "done.epub" }, { ["done.epub"] = "complete" }, true)
    _fakeKindleSource({
        { filepath = "/k/a.kfx", title = "A", _status = "finished" },
        { filepath = "/k/b.kfx", title = "B", _status = "complete" },
        { filepath = "/k/c.kfx", title = "C", _status = "reading"  },
    })
    local n = Repo.countFinishedBooks()
    _teardownWalk()
    assert(n == 3, "1 walked + 2 Kindle finished = 3, got " .. tostring(n))
end)

test("countFinishedBooks: the Kindle share is added per call, never cached", function()
    -- The walked count is persisted for 24h and is correct only because every
    -- local mutation drops it. NOTHING drops it when a Kindle status changes,
    -- so folding the Kindle share into the stored value would serve a stale
    -- number for up to a day. Here the walk cache is deliberately left warm:
    -- the answer must still move when the catalogue does.
    _setupWalk({ "done.epub" }, { ["done.epub"] = "complete" }, true)
    _fakeKindleSource({ { filepath = "/k/a.kfx", title = "A", _status = "finished" } })
    assert(Repo.countFinishedBooks() == 2, "1 walked + 1 Kindle")
    -- Same walk, same caches, one more finished Kindle book.
    _fakeKindleSource({
        { filepath = "/k/a.kfx", title = "A", _status = "finished" },
        { filepath = "/k/b.kfx", title = "B", _status = "finished" },
    })
    local n = Repo.countFinishedBooks()
    _teardownWalk()
    assert(n == 3,
        "the Kindle share must be recomputed per call, got " .. tostring(n)
        .. " -- a cached total would still read 2")
end)

test("getBySource: kindle kind is empty when there is no Kindle library", function()
    -- Every non-Kindle device: no catalogue, or the plugin absent.
    _fakeKindleSource({ _kindleBook("Mort") }, false)
    local list, total = Repo.getBySource({ kind = "kindle" }, nil, nil, 0, 10)
    package.loaded["lib/bookshelf_kindle_source"] = nil
    assert(#list == 0, "expected no books when unavailable, got " .. #list)
    assert(total == 0, "expected total=0, got " .. tostring(total))
end)

test("getBySource: folder honours sort_priority via getAll override", function()
    -- Specific-folder chips thread their sort_priority into Repo.getAll
    -- (which routes through SortEngine.chainedComparator). A title-desc
    -- priority therefore flips the book partition's order; Bravo > Alpha
    -- so Bravo lands first. This is the contract the chip editor's sort UI
    -- exposes for folder chips.
    _setupResolverLibrary()
    local priority = { { key = "title", reverse = true } }
    local list, _total = Repo.getBySource({ kind = "folder", id = "/lib/comics" }, nil, priority, 0, 10)
    _teardownResolverLibrary()
    assert(#list == 2, "expected 2 results, got " .. #list)
    assert(list[1].title == "Bravo",
           "expected Bravo first (title desc), got " .. tostring(list[1].title))
    assert(list[2].title == "Alpha",
           "expected Alpha second, got " .. tostring(list[2].title))
end)

test("getBySource: folder_flat returns all books recursively, no folder cards", function()
    -- #76: a flattened folder chip lists every book under the path at any
    -- depth, with NO subfolder cards (unlike the "folder" tree view). So a
    -- flatten of /lib pulls alpha + bravo (comics) + charlie (novels) = 3
    -- book records, and none of them is a folder card.
    _setupResolverLibrary()
    local list, total = Repo.getBySource({ kind = "folder_flat", id = "/lib" }, nil, nil, 0, 10)
    _teardownResolverLibrary()
    assert(type(list) == "table", "expected table, got " .. type(list))
    assert(#list == 3, "expected 3 books flattened under /lib, got " .. #list)
    assert(total == 3, "expected total=3, got " .. tostring(total))
    for _i, it in ipairs(list) do
        assert(it.kind ~= "folder", "flattened view must not contain folder cards")
        assert(type(it.filepath) == "string", "expected a book record with a filepath")
    end
end)

test("getBySource: folder_flat scoped to a subfolder lists only its books", function()
    -- Flatten of a subfolder is bounded to that subtree's books.
    _setupResolverLibrary()
    local list, total = Repo.getBySource({ kind = "folder_flat", id = "/lib/comics" }, nil, nil, 0, 10)
    _teardownResolverLibrary()
    assert(#list == 2, "expected 2 books under /lib/comics, got " .. #list)
    assert(total == 2, "expected total=2, got " .. tostring(total))
end)

-- ============================================================================
-- getBySource cache hit/miss + invalidation
-- ============================================================================

test("getBySource: second call with same key returns same cached instance", function()
    _setupResolverLibrary()
    -- Call once to warm the cache.
    local list1, total1 = Repo.getBySource({ kind = "genre", id = "manga" }, nil, nil, 0, 10)
    -- Call again with identical args; should return the same underlying table.
    local list2, total2 = Repo.getBySource({ kind = "genre", id = "manga" }, nil, nil, 0, 10)
    _teardownResolverLibrary()
    assert(total1 == total2, "totals differ between calls")
    assert(#list1 == #list2, "list lengths differ between calls")
end)

test("getBySource: different keys do not share cache entries", function()
    _setupResolverLibrary()
    local list_manga,  _ = Repo.getBySource({ kind = "genre", id = "manga"  }, nil, nil, 0, 10)
    local list_scifi,  _ = Repo.getBySource({ kind = "genre", id = "sci-fi" }, nil, nil, 0, 10)
    _teardownResolverLibrary()
    assert(#list_manga == 2, "expected 2 manga results, got " .. #list_manga)
    assert(#list_scifi == 1, "expected 1 sci-fi result, got " .. #list_scifi)
end)

test("getBySource: invalidateBookCache clears bySource cache so next call rebuilds", function()
    _setupResolverLibrary()
    -- Warm cache.
    local list1, total1 = Repo.getBySource({ kind = "genre", id = "manga" }, nil, nil, 0, 10)
    assert(#list1 == 2, "expected 2 on first call, got " .. #list1)
    -- Invalidate.
    Repo.invalidateBookCache("test")
    -- Simulate a library change: remove one manga book from BIM and the lfs stub.
    _G._test_bim_data = {
        ["/lib/comics/alpha.epub"]   = { title = "Alpha",   keywords = "manga"  },
        ["/lib/novels/charlie.epub"] = { title = "Charlie", keywords = "sci-fi" },
    }
    -- Rebuild the walk cache too so cachedWalk sees the reduced library.
    Repo.invalidateWalkCache()
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local listings = {
            ["/lib"]         = { ".", "..", "comics", "novels" },
            ["/lib/comics"]  = { ".", "..", "alpha.epub" },  -- bravo.epub gone
            ["/lib/novels"]  = { ".", "..", "charlie.epub" },
        }
        local files = listings[path] or {}
        local i = 0
        return function() i = i + 1; return files[i] end
    end
    local list2, total2 = Repo.getBySource({ kind = "genre", id = "manga" }, nil, nil, 0, 10)
    _teardownResolverLibrary()
    assert(#list2 == 1, "expected 1 after invalidation + library change, got " .. #list2)
    assert(total2 == 1, "expected total=1 after invalidation, got " .. tostring(total2))
    _ = total1  -- silence unused-variable warning from strict linters
end)

-- ============================================================================
-- Status / rating filters must consult DocSettings, not stat for a sibling
-- .sdr folder. KOReader's "Book metadata location" can be "dir" or "hash",
-- in which case no <book>.sdr exists next to the file, yet DocSettings still
-- holds the book's status/rating. The resolver library's lfs stub returns
-- "file" for any .sdr path (only /lib/comics and /lib/novels are dirs), so it
-- models exactly that centralised-metadata case. Reported in issue #117:
-- every book read as unread in the filter while covers showed the real status.
-- ============================================================================

test("getBySource: status filter finds on-hold book when metadata is not in a sibling .sdr", function()
    -- A status filter on a Recent chip exercises the predicate-path status
    -- loop -- the reporter's "custom recent filter" in #117. Recent draws from
    -- ReadHistory, so seed it with all three books.
    _setupResolverLibrary()
    package.loaded["readhistory"].hist = {
        { file = "/lib/comics/alpha.epub",   time = 300 },
        { file = "/lib/comics/bravo.epub",   time = 200 },
        { file = "/lib/novels/charlie.epub", time = 100 },
    }
    _G._test_docsettings_data = {
        ["/lib/comics/alpha.epub"]   = { summary = { status = "abandoned" } },  -- on_hold
        ["/lib/comics/bravo.epub"]   = { summary = { status = "reading"   } },
        ["/lib/novels/charlie.epub"] = { summary = { status = "complete"  } },  -- finished
    }
    local list, total = Repo.getBySource(
        { kind = "recent" }, { statuses = { on_hold = true } }, nil, 0, 10)
    package.loaded["readhistory"].hist = {}
    _teardownResolverLibrary()
    _G._test_docsettings_data = nil
    assert(total == 1, "expected 1 on-hold book, got " .. tostring(total))
    assert(list[1] and list[1].title == "Alpha",
        "expected Alpha, got " .. tostring(list[1] and list[1].title))
end)

test("getBySource: a filtered Recent or collection chip keeps books outside home (issue 305)", function()
    -- Read or collected from outside the home folder: the plain chip showed
    -- them, but a filter sent the chip through the library walk, which never
    -- sees them.
    _setupResolverLibrary()
    _G._test_bim_data["/elsewhere/delta.epub"] = { title = "Delta" }
    package.loaded["readhistory"].hist = {
        { file = "/lib/comics/alpha.epub", time = 300 },
        { file = "/elsewhere/delta.epub",  time = 200 },
    }
    _G._test_docsettings_data = {
        ["/lib/comics/alpha.epub"] = { summary = { status = "reading" } },
        ["/elsewhere/delta.epub"]  = { summary = { status = "reading" } },
    }
    local list, total = Repo.getBySource(
        { kind = "recent" }, { statuses = { reading = true } }, nil, 0, 10)
    local titles = {}
    for _i, b in ipairs(list) do titles[#titles + 1] = b.title end
    table.sort(titles)
    package.loaded["readcollection"].coll.wishlist[2] = { file = "/elsewhere/delta.epub" }
    local clist = Repo.getBySource({ kind = "collection", id = "wishlist" },
        { statuses = { reading = true } }, nil, 0, 10)
    package.loaded["readhistory"].hist = {}
    _teardownResolverLibrary()
    _G._test_docsettings_data = nil
    assert(total == 2, "expected both reading books, got " .. tostring(total))
    assert(table.concat(titles, ",") == "Alpha,Delta", "got " .. table.concat(titles, ","))
    assert(#clist == 2, "collection lost the book outside home: " .. #clist)
end)

test("getBySource: a sorted Recent chip still shows only books, not KOReader's own files", function()
    -- The default Recent chip carries a sort, so every reader takes the list
    -- path; KOReader's history also holds opened images and its quickstart
    -- guide, which the library walk never showed.
    _setupResolverLibrary()
    local prev_ds = package.loaded["datastorage"]
    package.loaded["datastorage"] = { getDataDir = function() return "/ko" end,
                                      getSettingsDir = function() return "/ko/settings" end }
    _G._test_bim_data["/elsewhere/delta.epub"] = { title = "Delta" }
    _G._test_bim_data["/ko/help/quickstart-en.html"] = { title = "Quickstart" }
    _G._test_bim_data["/elsewhere/photo.png"] = { title = "Photo" }
    package.loaded["readhistory"].hist = {
        { file = "/elsewhere/delta.epub", time = 3 },
        { file = "/ko/help/quickstart-en.html", time = 2 },
        { file = "/elsewhere/photo.png", time = 1 },
    }
    local list = Repo.getBySource({ kind = "recent" }, nil,
        { { key = "last_opened", reverse = true } }, 0, 10)
    package.loaded["readhistory"].hist = {}
    package.loaded["datastorage"] = prev_ds
    _teardownResolverLibrary()
    local titles = {}
    for _i, b in ipairs(list) do titles[#titles + 1] = b.title end
    assert(table.concat(titles, ",") == "Delta", "got " .. table.concat(titles, ","))
end)

test("getBySource: rating filter finds rated book when metadata is not in a sibling .sdr", function()
    _setupResolverLibrary()
    _G._test_docsettings_data = {
        ["/lib/comics/alpha.epub"] = { summary = { rating = 5 } },
        ["/lib/comics/bravo.epub"] = { summary = { rating = 3 } },
    }
    local list, total = Repo.getBySource({ kind = "rating", id = "5" }, nil, nil, 0, 10)
    _teardownResolverLibrary()
    _G._test_docsettings_data = nil
    assert(total == 1, "expected 1 five-star book, got " .. tostring(total))
    assert(list[1] and list[1].title == "Alpha",
        "expected Alpha, got " .. tostring(list[1] and list[1].title))
end)

-- ============================================================================
-- Languages grouping: every spelling of a language (2-letter, 3-letter,
-- region-tagged, full name) must collapse into one card with a friendly,
-- localised label -- not split across cards labelled with raw codes (#114
-- follow-up). bookshelf_lang.canonical owns the mapping; this checks the
-- repository wires grouping through it.
-- ============================================================================

local function _setupLangLibrary()
    Repo.invalidateWalkCache()
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 2 }
    _G._test_bim_data = {
        ["/lib/a.epub"] = { title = "A", language = "en" },
        ["/lib/b.epub"] = { title = "B", language = "eng" },
        ["/lib/c.epub"] = { title = "C", language = "English" },
        ["/lib/d.epub"] = { title = "D", language = "en-GB" },
        ["/lib/e.epub"] = { title = "E", language = "de" },
        ["/lib/f.epub"] = { title = "F" },  -- no language -> Unknown
    }
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = path == "/lib"
            and { ".", "..", "a.epub", "b.epub", "c.epub", "d.epub", "e.epub", "f.epub" }
            or {}
        local i = 0
        return function() i = i + 1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(fp, key)
        if key == nil then return { mode = "file", modification = 0 } end
        if key == "mode" then return "file" end
        if key == "modification" then return 0 end
        return nil
    end
    package.loaded["bookinfomanager"] = {
        getBookInfo = function(_self, fp) return _G._test_bim_data and _G._test_bim_data[fp] end,
    }
end

test("getLanguages: en / eng / en-GB / English collapse into one 'English' card", function()
    _setupLangLibrary()
    local groups = Repo.getLanguages(20)
    Repo.invalidateWalkCache()
    local by_label = {}
    for _i, g in ipairs(groups) do by_label[g.series_name] = #g.books end
    assert(by_label["English"] == 4,
        "expected 4 books under English, got " .. tostring(by_label["English"]))
    assert(by_label["German"] == 1,
        "expected 1 book under German, got " .. tostring(by_label["German"]))
    -- No raw-code labels leaked through.
    assert(by_label["en"] == nil and by_label["eng"] == nil and by_label["english"] == nil,
        "raw-code language label leaked into a card")
end)

test("getBySource: a language chip (source.id = display label) matches all variants", function()
    _setupLangLibrary()
    -- A chip created from the English card carries its display label as id.
    local list, total = Repo.getBySource({ kind = "language", id = "English" }, nil, nil, 0, 20)
    Repo.invalidateWalkCache()
    assert(total == 4, "expected 4 English books via chip, got " .. tostring(total))
end)

-- ============================================================================
-- Task 6b: full-filter integration at every repository site
-- ============================================================================

-- Shared walk/lfs setup for the filter integration tests.
local function _setupFilterLibrary()
    Repo.invalidateWalkCache()
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 1 }
    _G._test_bim_data = {
        -- unread, Sci-Fi, en, EPUB
        ["/lib/scifi.epub"]   = { title = "SciFi Book",  keywords = "Sci-Fi",  language = "en" },
        -- unread, Fantasy, de, EPUB
        ["/lib/fantasy.epub"] = { title = "Fantasy Book", keywords = "Fantasy", language = "de" },
        -- reading (has sidecar), Sci-Fi, en, PDF
        ["/lib/reading.pdf"]  = { title = "Reading PDF",  keywords = "Sci-Fi",  language = "en" },
    }
    _G._test_docsettings_data = {
        ["/lib/reading.pdf"] = { summary = { status = "reading" } },
    }
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = (path == "/lib")
            and { ".", "..", "scifi.epub", "fantasy.epub", "reading.pdf" } or {}
        local i = 0; return function() i = i + 1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(_fp, key)
        if key == nil then return { mode = "file", modification = 0 } end
        if key == "mode" then return "file" end
        if key == "modification" then return 0 end
        return nil
    end
    package.loaded["readcollection"] = {
        coll = { favorites = {} },
        default_collection_name = "favorites",
    }
end

local function _teardownFilterLibrary()
    _G._test_docsettings_data = nil
    package.loaded["readcollection"] = {
        coll = { favorites = {} },
        default_collection_name = "favorites",
    }
    Repo.invalidateWalkCache()
end

-- Test 1: genre-only filter narrows by genre and does NOT crash.
-- Before this fix, _filterAllShapes tested filter.statuses directly;
-- a genre-only filter (no .statuses) would nil-index and crash.
test("getAll: genre-only filter narrows by genre without crashing", function()
    _setupFilterLibrary()
    local items, total = Repo.getAll(nil, 10, 0, nil, { genres = { ["Sci-Fi"] = true } })
    _teardownFilterLibrary()
    -- scifi.epub and reading.pdf both carry the Sci-Fi keyword.
    assert(total == 2, "expected 2 Sci-Fi items, got " .. tostring(total))
    assert(items and #items == 2, "expected 2 hydrated items, got " .. tostring(items and #items))
    local titles = {}
    for _i, it in ipairs(items) do titles[it.title] = true end
    assert(titles["SciFi Book"],  "SciFi Book should be included")
    assert(titles["Reading PDF"], "Reading PDF should be included")
    assert(not titles["Fantasy Book"], "Fantasy Book should be excluded")
end)

-- Test 2: cross-dimension AND: status + language.
test("getAll: cross-dimension filter (status+lang) returns only matching books", function()
    _setupFilterLibrary()
    local items, total = Repo.getAll(nil, 10, 0, nil,
        { statuses = { unread = true }, langs = { en = true } })
    _teardownFilterLibrary()
    -- Only scifi.epub is unread AND English. fantasy.epub is unread but German.
    -- reading.pdf is English but status=reading.
    assert(total == 1, "expected 1 unread+English item, got " .. tostring(total))
    assert(items and #items == 1)
    assert(items[1].title == "SciFi Book",
        "expected SciFi Book, got " .. tostring(items[1] and items[1].title))
end)

-- Test 3: format filter — proves light records get format filled.
test("getAll: format filter returns only books with matching extension", function()
    _setupFilterLibrary()
    local items, total = Repo.getAll(nil, 10, 0, nil, { formats = { EPUB = true } })
    _teardownFilterLibrary()
    -- scifi.epub and fantasy.epub are .epub; reading.pdf is not.
    assert(total == 2, "expected 2 EPUB items, got " .. tostring(total))
    assert(items and #items == 2)
    local titles = {}
    for _i, it in ipairs(items) do titles[it.title] = true end
    assert(titles["SciFi Book"],   "SciFi Book (EPUB) should be included")
    assert(titles["Fantasy Book"], "Fantasy Book (EPUB) should be included")
    assert(not titles["Reading PDF"], "Reading PDF should be excluded (not EPUB)")
end)

-- Test 4: status-only filter still behaves exactly as before (back-compat).
test("getAll: status-only filter still works correctly (back-compat)", function()
    _setupFilterLibrary()
    local items, total = Repo.getAll(nil, 10, 0, nil, { statuses = { reading = true } })
    _teardownFilterLibrary()
    -- Only reading.pdf has status=reading (sidecar present).
    assert(total == 1, "expected 1 reading item, got " .. tostring(total))
    assert(items and #items == 1)
    assert(items[1].title == "Reading PDF",
        "expected Reading PDF, got " .. tostring(items[1] and items[1].title))
end)

-- Test 5: getTags with a status filter drops non-matching books and empty groups.
test("getTags: status filter drops non-matching books and empties collection groups", function()
    Repo.invalidateWalkCache()
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 1 }
    _G._test_bim_data = {
        ["/lib/a.epub"] = { title = "A" },
        ["/lib/b.epub"] = { title = "B" },
        ["/lib/c.epub"] = { title = "C" },
    }
    -- Two collections: "scifi" has a.epub (reading) + b.epub (unread).
    -- "fantasy" has c.epub (unread).
    -- With a { statuses = { reading = true } } filter:
    --   "scifi" retains only a.epub (1 book), "fantasy" becomes empty -> dropped.
    _G._test_docsettings_data = {
        ["/lib/a.epub"] = { summary = { status = "reading" } },
    }
    package.loaded["readcollection"] = {
        coll = {
            favorites = {},
            scifi     = {
                ["/lib/a.epub"] = { file = "/lib/a.epub", order = 1, attr = { access = 100 } },
                ["/lib/b.epub"] = { file = "/lib/b.epub", order = 2, attr = { access = 200 } },
            },
            fantasy   = {
                ["/lib/c.epub"] = { file = "/lib/c.epub", order = 1, attr = { access = 50  } },
            },
        },
        default_collection_name = "favorites",
    }
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = (path == "/lib")
            and { ".", "..", "a.epub", "b.epub", "c.epub" } or {}
        local i = 0; return function() i = i + 1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(_fp, key)
        if key == nil then return { mode = "file", modification = 0 } end
        if key == "mode" then return "file" end
        if key == "modification" then return 0 end
        return nil
    end

    local groups, total = Repo.getTags(10, 0, nil, { statuses = { reading = true } })

    _G._test_docsettings_data = nil
    package.loaded["readcollection"] = {
        coll = { favorites = {} },
        default_collection_name = "favorites",
    }
    Repo.invalidateWalkCache()

    -- "fantasy" group becomes empty after filtering, so it should be dropped.
    assert(total == 1, "expected 1 non-empty group after status filter, got " .. tostring(total))
    assert(groups and #groups == 1, "expected 1 group, got " .. tostring(groups and #groups))
    assert(groups[1].series_name == "scifi",
        "expected 'scifi' group, got " .. tostring(groups[1] and groups[1].series_name))
    assert(#groups[1].books == 1,
        "expected 1 book in scifi group, got " .. tostring(#groups[1].books))
    assert(groups[1].books[1].title == "A",
        "expected book A in scifi group, got " .. tostring(groups[1].books[1] and groups[1].books[1].title))
end)

-- ============================================================================
-- filter round-trip: editor-emitted value must match raw book field
-- Exercises the bug where distinctFilterValues stores a display label
-- ("English", Title-cased genre) but Filter.matches compared it raw against
-- book.lang ("en") / book.genres (lowercase). Repo.filterOpts() injects the
-- same canonicalisers used by getLanguages/_buildGroups so both sides collapse
-- to the same key.
-- ============================================================================

test("filter round-trip: language label 'English' matches book with lang='en'", function()
    -- Simulate what distinctFilterValues("langs") returns for an English book:
    -- getLanguages groups by canonical key and sets series_name = "English".
    -- The picker stores that label as the filter value.
    local Filter = require("lib/bookshelf_filter")
    local filter = { langs = { ["English"] = true } }
    local compiled = Filter.compile(filter, Repo.filterOpts())
    -- A book whose BIM language field is the raw code "en" must match.
    assert(Filter.matches({ lang = "en" }, compiled),
        "lang='en' should match filter value 'English' via lang_canonical")
    -- A book with lang="eng" (3-letter code) must also match.
    assert(Filter.matches({ lang = "eng" }, compiled),
        "lang='eng' should match filter value 'English' via lang_canonical")
    -- A book in a different language must not match.
    assert(not Filter.matches({ lang = "fr" }, compiled),
        "lang='fr' should not match filter value 'English'")
end)

test("filter round-trip: genre label 'Sci-Fi' matches book with genres={'sci-fi'}", function()
    -- distinctFilterValues("genres") stores the display form emitted by getGenres
    -- (Title-Cased via _buildGroups). The raw book.genres entries come from BIM
    -- keywords, which are often lowercase or mixed-case.
    local Filter = require("lib/bookshelf_filter")
    local filter = { genres = { ["Sci-Fi"] = true } }
    local compiled = Filter.compile(filter, Repo.filterOpts())
    -- Lower-case raw tag must match the Title-cased stored label.
    assert(Filter.matches({ genres = { "sci-fi" } }, compiled),
        "genres={'sci-fi'} should match filter value 'Sci-Fi' via genre_normalize")
    -- Unrelated genre must not match.
    assert(not Filter.matches({ genres = { "history" } }, compiled),
        "genres={'history'} should not match filter value 'Sci-Fi'")
    -- No genres at all must not match.
    assert(not Filter.matches({ genres = nil }, compiled),
        "genres=nil should not match filter value 'Sci-Fi'")
end)

-- ============================================================================
-- genre/language filters on group chips (fix: genres/lang dropped from projections)
-- ============================================================================

test("getBySource: genre filter on series chip returns matching series and excludes non-matching", function()
    -- Reproduces the bug: genre filter on a GROUP chip returned zero results
    -- because getSeriesGroups dropped genres from the books_meta projection.
    -- After the fix, books_meta carries genres so _shapeHasFilteredBook works.
    Repo.invalidateWalkCache()
    Repo.invalidateBookCache("test")
    package.loaded["readhistory"].hist = {}
    _G._test_bim_data = {
        -- "Alpha" series: a1 is Adventure+Romance, a2 is Adventure-only
        ["/lib/a1.epub"] = { title = "Alpha 1", series = "Alpha #1", keywords = "Adventure, Romance" },
        ["/lib/a2.epub"] = { title = "Alpha 2", series = "Alpha #2", keywords = "Adventure" },
        -- "Beta" series: only Romance, no Adventure
        ["/lib/b1.epub"] = { title = "Beta 1",  series = "Beta #1",  keywords = "Romance" },
    }
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 1 }
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = (path == "/lib")
            and { ".", "..", "a1.epub", "a2.epub", "b1.epub" } or {}
        local i = 0; return function() i = i + 1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(_fp, key)
        if key == "mode" then return "file" end
        if key == "modification" then return 0 end
    end

    local groups, total = Repo.getBySource(
        { kind = "series" }, { genres = { Adventure = true } }, nil, 0, 50)

    Repo.invalidateWalkCache()
    Repo.invalidateBookCache("test")
    _G._test_bim_data = nil
    _G._test_settings = nil

    -- Alpha has Adventure books; Beta does not.
    assert(type(groups) == "table",
        "expected table, got " .. type(groups))
    local names = {}
    for _i, g in ipairs(groups) do names[g.series_name] = true end
    assert(names["Alpha"],
        "Alpha series (has Adventure books) should be included")
    assert(not names["Beta"],
        "Beta series (no Adventure books) should be excluded")
    assert(total == 1,
        "expected total=1 (only Alpha), got " .. tostring(total))
end)

test("getBySource: language filter on series chip returns matching series and excludes non-matching", function()
    -- Mirror of the genre test above but for the lang dimension. The picker
    -- stores the display label ("English") from getLanguages; lang_canonical
    -- maps it back to the raw "en" stored in book.lang.
    Repo.invalidateWalkCache()
    Repo.invalidateBookCache("test")
    package.loaded["readhistory"].hist = {}
    _G._test_bim_data = {
        -- "EnSeries": books tagged language=en
        ["/lib/en1.epub"] = { title = "En 1", series = "EnSeries #1", language = "en" },
        ["/lib/en2.epub"] = { title = "En 2", series = "EnSeries #2", language = "en" },
        -- "FrSeries": books tagged language=fr
        ["/lib/fr1.epub"] = { title = "Fr 1", series = "FrSeries #1", language = "fr" },
    }
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 1 }
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = (path == "/lib")
            and { ".", "..", "en1.epub", "en2.epub", "fr1.epub" } or {}
        local i = 0; return function() i = i + 1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(_fp, key)
        if key == "mode" then return "file" end
        if key == "modification" then return 0 end
    end

    -- Filter using the display label "English" (what the picker emits after
    -- distinctFilterValues("langs") + getLanguages round-trip).
    local groups, total = Repo.getBySource(
        { kind = "series" }, { langs = { English = true } }, nil, 0, 50)

    Repo.invalidateWalkCache()
    Repo.invalidateBookCache("test")
    _G._test_bim_data = nil
    _G._test_settings = nil

    assert(type(groups) == "table",
        "expected table, got " .. type(groups))
    local names = {}
    for _i, g in ipairs(groups) do names[g.series_name] = true end
    assert(names["EnSeries"],
        "EnSeries (lang=en, label=English) should be included")
    assert(not names["FrSeries"],
        "FrSeries (lang=fr) should be excluded when filtering for English")
    assert(total == 1,
        "expected total=1 (only EnSeries), got " .. tostring(total))
end)

test("getBySource: genre filter on ratings chip returns matching rating and excludes non-matching", function()
    -- Reproduces the bug: genre filter on a RATINGS chip returned zero results
    -- because _buildRatingGroups dropped genres from the books_meta projection.
    -- After the fix, books_meta carries genres so _shapeHasFilteredBook works.
    Repo.invalidateWalkCache()
    Repo.invalidateBookCache("test")
    package.loaded["readhistory"].hist = {}
    _G._test_bim_data = {
        -- 5-star books: one Adventure, one Romance
        ["/lib/5star_adventure.epub"] = { title = "5 Star Adventure", keywords = "Adventure" },
        ["/lib/5star_romance.epub"] = { title = "5 Star Romance", keywords = "Romance" },
        -- 3-star books: only Romance, no Adventure
        ["/lib/3star_romance.epub"] = { title = "3 Star Romance", keywords = "Romance" },
    }
    _G._test_docsettings_data = {
        ["/lib/5star_adventure.epub"] = { summary = { rating = 5 } },
        ["/lib/5star_romance.epub"] = { summary = { rating = 5 } },
        ["/lib/3star_romance.epub"] = { summary = { rating = 3 } },
    }
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 1 }
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = (path == "/lib")
            and { ".", "..", "5star_adventure.epub", "5star_romance.epub", "3star_romance.epub" } or {}
        local i = 0; return function() i = i + 1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(_fp, key)
        if key == "mode" then return "file" end
        if key == "modification" then return 0 end
    end

    local groups, total = Repo.getBySource(
        { kind = "ratings" }, { genres = { Adventure = true } }, nil, 0, 50)

    Repo.invalidateWalkCache()
    Repo.invalidateBookCache("test")
    _G._test_bim_data = nil
    _G._test_docsettings_data = nil
    _G._test_settings = nil

    -- 5-star has an Adventure book; 3-star does not.
    -- With Adventure filter, only 5-star (which has an Adventure book) should be returned.
    assert(type(groups) == "table",
        "expected table, got " .. type(groups))
    assert(#groups == 1,
        "expected 1 rating group (5-star with Adventure), got " .. #groups)
    local g = groups[1]
    assert(g.series_name:find("★★★★★"),
        "expected 5-star rating group, got " .. g.series_name)
    assert(g.books and #g.books == 1,
        "expected 1 book in 5-star group, got " .. (#g.books or 0))
    assert(g.books[1].title == "5 Star Adventure",
        "expected 5 Star Adventure book, got " .. (g.books[1].title or "nil"))
end)

test("getBySource: ratings chip does not crash on rating=0, buckets it as Unrated", function()
    -- Regression: a book with summary.rating = 0 (KOReader's "no rating") keyed
    -- buckets[0] (nil) because 0 is truthy in Lua, crashing on #bucket. It must
    -- land in the Unrated group instead.
    Repo.invalidateWalkCache()
    Repo.invalidateBookCache("test")
    package.loaded["readhistory"].hist = {}
    _G._test_bim_data = {
        ["/lib/rated.epub"]   = { title = "Rated Four" },
        ["/lib/zero.epub"]    = { title = "Zero Rating" },
    }
    _G._test_docsettings_data = {
        ["/lib/rated.epub"] = { summary = { rating = 4 } },
        ["/lib/zero.epub"]  = { summary = { rating = 0 } },   -- the crash trigger
    }
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 1 }
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = (path == "/lib")
            and { ".", "..", "rated.epub", "zero.epub" } or {}
        local i = 0; return function() i = i + 1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(_fp, key)
        if key == "mode" then return "file" end
        if key == "modification" then return 0 end
    end

    local ok, groups = pcall(function()
        return (Repo.getBySource({ kind = "ratings" }, {}, nil, 0, 50))
    end)

    Repo.invalidateWalkCache()
    Repo.invalidateBookCache("test")
    _G._test_bim_data = nil
    _G._test_docsettings_data = nil
    _G._test_settings = nil

    assert(ok, "ratings chip crashed on a rating=0 book: " .. tostring(groups))
    assert(type(groups) == "table" and #groups == 2,
        "expected 2 groups (4-star + Unrated), got " .. (type(groups) == "table" and #groups or type(groups)))
    local unrated
    for _i, g in ipairs(groups) do if g.series_name == "Unrated" then unrated = g end end
    assert(unrated, "expected an Unrated group")
    assert(#unrated.books == 1 and unrated.books[1].title == "Zero Rating",
        "rating=0 book should be in Unrated")
end)

-- ============================================================================
-- OOM-backstop: hydration clamp
-- ============================================================================

-- Shared setup: 600 books, one unique genre each, all in a flat /genres dir.
-- Gives us a library that exceeds the MAX_HYDRATE cap (512) so we can verify
-- that the enumeration path (distinctFilterValues) returns the full 600, while
-- the hydrating path (getGenres with limit=100000) is clamped to <=512.
local function _setup600GenreLibrary()
    Repo.invalidateWalkCache()
    _G._test_settings = { home_dir = "/genres", bookshelf_latest_walk_depth = 1 }
    local files_list = { ".", ".." }
    local bim_data = {}
    for i = 1, 600 do
        local fp = string.format("/genres/book%04d.epub", i)
        local genre = string.format("Genre%04d", i)
        files_list[#files_list + 1] = string.format("book%04d.epub", i)
        bim_data[fp] = { title = string.format("Book %d", i), keywords = genre }
    end
    _G._test_bim_data = bim_data
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local listing = (path == "/genres") and files_list or {}
        local i = 0
        return function() i = i + 1; return listing[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(_fp, key)
        if key == nil then return { mode = "file", modification = 0 } end
        if key == "mode" then return "file" end
        if key == "modification" then return 0 end
        return nil
    end
end

local function _teardown600GenreLibrary()
    _G._test_bim_data = nil
    _G._test_settings = nil
    Repo.invalidateWalkCache()
end

test("hydration clamp: distinctFilterValues returns full list past MAX_HYDRATE", function()
    -- distinctFilterValues("genres") routes through getGroupChoices, which builds
    -- the genre cache with limit=0 (no hydration), then reads shapes directly.
    -- It must return the complete list even when the library has more distinct
    -- genres than MAX_HYDRATE (512).
    _setup600GenreLibrary()
    local choices = Repo.distinctFilterValues("genres")
    _teardown600GenreLibrary()
    assert(#choices == 600,
        "expected 600 distinct genres (uncapped enumeration path), got " .. #choices)
end)

test("hydration clamp: getGenres(100000) hydrates at most 512 cards but reports true total", function()
    -- A caller passing an unbounded limit to a hydrating fetcher should be
    -- clamped to MAX_HYDRATE (512), not OOM-killed. The returned `total` must
    -- still reflect the true library size so pagination computes correctly.
    _setup600GenreLibrary()
    local cards, total = Repo.getGenres(100000, 0)
    _teardown600GenreLibrary()
    assert(total == 600,
        "expected total=600 (true library count), got " .. tostring(total))
    assert(#cards <= 512,
        "expected hydrated card count <= 512 (MAX_HYDRATE), got " .. #cards)
end)

test("hydration clamp: getAll(nil,100000,0) hydrates at most 512 items but reports true total", function()
    -- getAll is the Home-chip path and the busiest hydrating fetcher.
    -- An unbounded limit (or a huge one) must be clamped to MAX_HYDRATE (512)
    -- so a misconfigured caller cannot OOM the device. The returned `total`
    -- must still reflect the full library count so pagination stays correct.
    Repo.invalidateWalkCache()
    _G._test_settings = { home_dir = "/allbooks", bookshelf_latest_walk_depth = 1 }
    local files_list = { ".", ".." }
    local bim_data = {}
    for i = 1, 600 do
        local fp = string.format("/allbooks/book%04d.epub", i)
        files_list[#files_list + 1] = string.format("book%04d.epub", i)
        bim_data[fp] = { title = string.format("Book %d", i) }
    end
    _G._test_bim_data = bim_data
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local listing = (path == "/allbooks") and files_list or {}
        local i = 0
        return function() i = i + 1; return listing[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(_fp, key)
        if key == nil then return { mode = "file", modification = 0 } end
        if key == "mode" then return "file" end
        if key == "modification" then return 0 end
        return nil
    end
    local items, total = Repo.getAll(nil, 100000, 0)
    _G._test_bim_data = nil
    _G._test_settings = nil
    Repo.invalidateWalkCache()
    assert(total == 600,
        "expected total=600 (true library count), got " .. tostring(total))
    assert(#items <= 512,
        "expected hydrated item count <= 512 (MAX_HYDRATE), got " .. tostring(#items))
end)

-- ============================================================================
-- Rating filter dimension
-- ============================================================================

test("getBySource: ratings filter narrows to rated books (sidecar-gated)", function()
    Repo.invalidateWalkCache()
    -- Three books: one rated 5, one rated 3, one unopened (no sidecar).
    _G._test_settings = { home_dir = "/ratings_test", bookshelf_latest_walk_depth = 1 }
    _G._test_bim_data = {
        ["/ratings_test/five.epub"]   = { title = "Five Stars"  },
        ["/ratings_test/three.epub"]  = { title = "Three Stars" },
        ["/ratings_test/unread.epub"] = { title = "Unread"      },
    }
    -- DocSettings stubs: summary.rating drives Repo.readProgress.
    -- 'unread.epub' has no entry so _hasSidecar returns false => treated as unrated.
    _G._test_docsettings_data = {
        ["/ratings_test/five.epub"]  = { summary = { rating = 5 } },
        ["/ratings_test/three.epub"] = { summary = { rating = 3 } },
    }
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = (path == "/ratings_test")
            and { ".", "..", "five.epub", "three.epub", "unread.epub" }
            or {}
        local i = 0
        return function() i = i + 1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(_fp, key)
        if key == nil then return { mode = "file", modification = 0 } end
        if key == "mode" then return "file" end
        if key == "modification" then return 0 end
    end

    -- Filter to 5-star books only.
    local filter5 = { ratings = { ["5"] = true } }
    local items5, total5 = Repo.getBySource({ kind = "library" }, filter5,
        { { key = "title", reverse = false } }, 0, 100)
    assert(total5 == 1,
        "expected 1 five-star book, got " .. tostring(total5))
    assert(items5[1] and items5[1].title == "Five Stars",
        "expected 'Five Stars', got " .. tostring(items5[1] and items5[1].title))

    -- Filter to unrated books: includes 'unread.epub' (no sidecar => unrated)
    -- and should exclude the rated ones.
    local filter_unrated = { ratings = { unrated = true } }
    local items_u, total_u = Repo.getBySource({ kind = "library" }, filter_unrated,
        { { key = "title", reverse = false } }, 0, 100)
    assert(total_u == 1,
        "expected 1 unrated book, got " .. tostring(total_u))
    assert(items_u[1] and items_u[1].title == "Unread",
        "expected 'Unread', got " .. tostring(items_u[1] and items_u[1].title))

    -- Clean up
    _G._test_docsettings_data = nil
    Repo.invalidateWalkCache()
end)

test("distinctFilterValues ratings: returns 6 fixed entries with string keys", function()
    local vals = Repo.distinctFilterValues("ratings")
    assert(#vals == 6, "expected 6 rating values, got " .. tostring(#vals))
    assert(vals[1].value == "5",       "first value should be '5', got " .. tostring(vals[1].value))
    assert(vals[6].value == "unrated", "last value should be 'unrated', got " .. tostring(vals[6].value))
    -- all values are strings (not numbers)
    for i = 1, #vals do
        assert(type(vals[i].value) == "string",
            "entry " .. i .. " value should be string, got " .. type(vals[i].value))
    end
end)

-- ============================================================================
-- filterValueCounts (faceted counts)
-- ============================================================================

-- Shared library setup: 3 EPUBs + 2 PDFs; 2 EPUBs and 1 PDF have genre=Action;
-- the remaining 1 EPUB and 1 PDF have genre=Romance.
local function _setupFacetLibrary()
    Repo.invalidateWalkCache()
    _G._test_settings = { home_dir = "/flib", bookshelf_latest_walk_depth = 1 }
    _G._test_bim_data = {
        ["/flib/epub1_action.epub"] = { title = "E1", keywords = "Action" },
        ["/flib/epub2_action.epub"] = { title = "E2", keywords = "Action" },
        ["/flib/epub3_romance.epub"] = { title = "E3", keywords = "Romance" },
        ["/flib/pdf1_action.pdf"]   = { title = "P1", keywords = "Action" },
        ["/flib/pdf2_romance.pdf"]  = { title = "P2", keywords = "Romance" },
    }
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = (path == "/flib") and {
            ".", "..",
            "epub1_action.epub", "epub2_action.epub", "epub3_romance.epub",
            "pdf1_action.pdf", "pdf2_romance.pdf",
        } or {}
        local i = 0
        return function() i = i + 1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(_fp, key)
        if key == nil then return { mode = "file", modification = 0 } end
        if key == "mode" then return "file" end
        if key == "modification" then return 0 end
        return nil
    end
end

local function _teardownFacetLibrary()
    _G._test_bim_data = nil
    _G._test_settings = nil
    Repo.invalidateWalkCache()
end

test("filterValueCounts: faceted format counts reflect a genre filter", function()
    -- With genres={Action} active, format counts should be:
    --   EPUB=2 (epub1_action, epub2_action), PDF=1 (pdf1_action)
    -- NOT the static totals EPUB=3, PDF=2.
    _setupFacetLibrary()
    local counts = Repo.filterValueCounts("formats", { genres = { Action = true } })
    _teardownFacetLibrary()
    assert(counts ~= nil, "expected counts table, got nil")
    assert(counts["EPUB"] == 2,
        "expected EPUB=2 under Action filter, got " .. tostring(counts["EPUB"]))
    assert(counts["PDF"] == 1,
        "expected PDF=1 under Action filter, got " .. tostring(counts["PDF"]))
end)

test("filterValueCounts: fast path returns nil when no other dim is active", function()
    _setupFacetLibrary()
    -- Empty filter: no other dim is active; caller should use static totals.
    local counts = Repo.filterValueCounts("formats", {})
    _teardownFacetLibrary()
    assert(counts == nil, "expected nil fast path for empty filter, got " .. tostring(counts))
end)

test("filterValueCounts: nil filter also returns nil fast path", function()
    _setupFacetLibrary()
    local counts = Repo.filterValueCounts("formats", nil)
    _teardownFacetLibrary()
    assert(counts == nil, "expected nil fast path for nil filter")
end)

test("filterValueCounts: exclude-self - formats filter ignored when viewing formats dim", function()
    -- With filter = { formats={EPUB=true}, genres={Action=true} }:
    -- viewing "formats" dim excludes formats from the reduced filter,
    -- so we get counts among ALL formats of Action books (EPUB=2, PDF=1).
    _setupFacetLibrary()
    local counts = Repo.filterValueCounts("formats",
        { formats = { EPUB = true }, genres = { Action = true } })
    _teardownFacetLibrary()
    assert(counts ~= nil, "expected counts table")
    assert(counts["EPUB"] == 2,
        "expected EPUB=2 (self-dim excluded), got " .. tostring(counts["EPUB"]))
    assert(counts["PDF"] == 1,
        "expected PDF=1 (self-dim excluded), got " .. tostring(counts["PDF"]))
end)

test("filterValueCounts: statuses dim returns nil (out of scope)", function()
    local counts = Repo.filterValueCounts("statuses",
        { genres = { Action = true } })
    assert(counts == nil, "expected nil for statuses dim")
end)

test("filterValueCounts: folders dim returns nil (out of scope)", function()
    local counts = Repo.filterValueCounts("folders",
        { genres = { Action = true } })
    assert(counts == nil, "expected nil for folders dim")
end)

test("filterValueCounts: rating faceting buckets correctly under a genre filter", function()
    -- Library: 3 books with genre=Action; 2 have sidecars (ratings 4 and 5),
    -- 1 has no sidecar (unrated). With genres={Action} as the reduced filter,
    -- the rating dim counts should be: "4"=1, "5"=1, unrated=1.
    Repo.invalidateWalkCache()
    _G._test_settings = { home_dir = "/rlib", bookshelf_latest_walk_depth = 1 }
    _G._test_bim_data = {
        ["/rlib/r4_action.epub"]     = { title = "R4",  keywords = "Action" },
        ["/rlib/r5_action.epub"]     = { title = "R5",  keywords = "Action" },
        ["/rlib/unrated_action.epub"]= { title = "UR",  keywords = "Action" },
        ["/rlib/r3_other.epub"]      = { title = "R3O", keywords = "Romance" },
    }
    _G._test_docsettings_data = {
        ["/rlib/r4_action.epub"]  = { summary = { rating = 4 } },
        ["/rlib/r5_action.epub"]  = { summary = { rating = 5 } },
        ["/rlib/r3_other.epub"]   = { summary = { rating = 3 } },
        -- unrated_action.epub has NO entry => _hasSidecar returns false => unrated
    }
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = (path == "/rlib") and {
            ".", "..",
            "r4_action.epub", "r5_action.epub", "unrated_action.epub", "r3_other.epub",
        } or {}
        local i = 0
        return function() i = i + 1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(_fp, key)
        if key == nil then return { mode = "file", modification = 0 } end
        if key == "mode" then return "file" end
        if key == "modification" then return 0 end
        return nil
    end

    local counts = Repo.filterValueCounts("ratings",
        { genres = { Action = true } })

    _G._test_docsettings_data = nil
    Repo.invalidateWalkCache()

    assert(counts ~= nil, "expected counts for rating dim under genre filter")
    assert(counts["4"] == 1,
        "expected 1 four-star Action book, got " .. tostring(counts["4"]))
    assert(counts["5"] == 1,
        "expected 1 five-star Action book, got " .. tostring(counts["5"]))
    assert(counts["unrated"] == 1,
        "expected 1 unrated Action book, got " .. tostring(counts["unrated"]))
    -- r3_other is Romance; filtered out by genres={Action}, so should not count.
    assert((counts["3"] or 0) == 0,
        "expected Romance book to be excluded, got counts[3]=" .. tostring(counts["3"]))
end)

-- ============================================================================
-- Issue #160: series_membership on the Series source
-- ============================================================================

-- Shared fixture: two series (Dune: 1 book, Foundation: 2 books) + a
-- standalone. Read times make the default latest-activity sort
-- deterministic: Dune 500 > Foundation 450 > standalone 100.
local function seriesMixFixture()
    Repo.invalidateWalkCache()
    package.loaded["readhistory"].hist = {
        { file = "/lib/dune.epub", time = 500 },
        { file = "/lib/foundation1.epub", time = 400 },
        { file = "/lib/foundation2.epub", time = 450 },
        { file = "/lib/standalone.epub", time = 100 },
    }
    _G._test_bim_data = {
        ["/lib/dune.epub"]        = { title = "Dune", series = "Dune #1" },
        ["/lib/foundation1.epub"] = { title = "Foundation", series = "Foundation #1" },
        ["/lib/foundation2.epub"] = { title = "Foundation and Empire", series = "Foundation #2" },
        ["/lib/standalone.epub"]  = { title = "Standalone" },
    }
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 1 }
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = (path == "/lib")
            and { ".", "..", "dune.epub", "foundation1.epub", "foundation2.epub", "standalone.epub" }
            or {}
        local i = 0
        return function() i = i + 1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(_fp, key)
        if key == "mode" then return "file" end
        if key == "modification" then return 0 end
    end
end

test("getSeriesGroups: 'both' mixes standalone books into the stack list (#160)", function()
    seriesMixFixture()
    local items, total = Repo.getSeriesGroups(10, 0, nil, { series_membership = "both" })
    assert(total == 3, "expected 2 stacks + 1 standalone, got " .. tostring(total))
    assert(#items == 3, "expected 3 hydrated items, got " .. #items)
    -- Latest-activity order: Dune stack, Foundation stack, standalone single.
    assert(items[1].series_name == "Dune", "first should be Dune stack")
    assert(items[2].series_name == "Foundation", "second should be Foundation stack")
    assert(items[3].books == nil, "standalone must be a plain book record, not a stack")
    assert(items[3].title == "Standalone", "got " .. tostring(items[3].title))
    assert(items[3].filepath == "/lib/standalone.epub")
end)

test("getSeriesGroups: 'standalone' returns only the singles (#160)", function()
    seriesMixFixture()
    local items, total = Repo.getSeriesGroups(10, 0, nil, { series_membership = "standalone" })
    assert(total == 1, "expected only the standalone, got " .. tostring(total))
    assert(items[1].books == nil and items[1].title == "Standalone")
end)

test("getSeriesGroups: unset filter keeps today's stacks-only behaviour (#160)", function()
    seriesMixFixture()
    local items, total = Repo.getSeriesGroups(10)
    assert(total == 2, "expected 2 stacks only, got " .. tostring(total))
    for _i, it in ipairs(items) do
        assert(it.books, "no plain books expected without the filter")
    end
end)

test("getSeriesGroups: hide_single + 'both' degrades 1-book stacks to singles (#160)", function()
    seriesMixFixture()
    _G._test_settings.bookshelf_hide_single_book_stacks = true
    -- Unset filter: the 1-book Dune stack is dropped entirely (#127 behaviour).
    local _items, total = Repo.getSeriesGroups(10)
    assert(total == 1, "hide_single alone should leave just Foundation, got " .. tostring(total))
    -- 'both': in a mixed view Dune isn't noise - it reappears as a plain book.
    local items2, total2 = Repo.getSeriesGroups(10, 0, nil, { series_membership = "both" })
    assert(total2 == 3, "expected Foundation stack + Dune single + standalone, got " .. tostring(total2))
    local titles = {}
    for _i, it in ipairs(items2) do
        if not it.books then titles[it.title] = true end
    end
    assert(titles["Dune"], "Dune should surface as a single book")
    assert(titles["Standalone"], "standalone still present")
    _G._test_settings.bookshelf_hide_single_book_stacks = nil
end)

test("getSeriesGroups: count sort ranks 1-book stacks above standalones (#160)", function()
    seriesMixFixture()
    -- "book_count" legacy sort key = count descending. A standalone isn't a
    -- series at all, so it must rank BELOW a 1-book series, not tie with it.
    local items, total = Repo.getSeriesGroups(10, 0, "book_count",
        { series_membership = "both" })
    assert(total == 3, "expected 3 items, got " .. tostring(total))
    assert(items[1].series_name == "Foundation", "2-book stack first")
    assert(items[2].series_name == "Dune", "1-book stack second")
    assert(items[3].books == nil and items[3].title == "Standalone",
        "standalone last, got " .. tostring(items[3].title or items[3].series_name))
end)

test("getSeriesGroups: other dimensions still filter standalones under 'both' (#160)", function()
    seriesMixFixture()
    -- Mark the standalone finished; everything else has no sidecar (unread).
    _G._test_docsettings_data = {
        ["/lib/standalone.epub"] = { summary = { status = "complete" } },
    }
    local items, total = Repo.getSeriesGroups(10, 0, nil,
        { series_membership = "both", statuses = { finished = true } })
    assert(total == 1, "only the finished standalone should survive, got " .. tostring(total))
    assert(items[1] and items[1].title == "Standalone")
    _G._test_docsettings_data = nil
end)

test("getFolderBookPaths: finds books nested deeper than the home walk depth (#202)", function()
    -- Novels/Genre/Subgenre/Author/Book.epub sits 4 dirs below home; the
    -- home-rooted walk (depth 3) never reaches it, so the status-filter
    -- predicate saw the Novels folder as empty and dropped it. The fallback
    -- walks the asked-about folder itself with the same depth budget.
    Repo.invalidateWalkCache()
    local tree = {
        ["/home"]                              = { ".", "..", "Novels" },
        ["/home/Novels"]                       = { ".", "..", "Genre" },
        ["/home/Novels/Genre"]                 = { ".", "..", "Subgenre" },
        ["/home/Novels/Genre/Subgenre"]        = { ".", "..", "Author" },
        ["/home/Novels/Genre/Subgenre/Author"] = { ".", "..", "Book.epub" },
    }
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = tree[path] or {}
        local i = 0
        return function() i = i + 1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(fp, key)
        local mode = tree[fp] and "directory" or "file"
        if key == "modification" then return 0
        elseif key == "mode" then return mode end
    end
    _G._test_settings = { home_dir = "/home", bookshelf_latest_walk_depth = 3 }
    _G._test_bim_data = {
        ["/home/Novels/Genre/Subgenre/Author/Book.epub"] = { title = "Deep Book" },
    }

    local paths = Repo.getFolderBookPaths("/home/Novels")
    assert(#paths == 1, "expected the deep book via the folder-rooted fallback, got " .. #paths)
    assert(paths[1] == "/home/Novels/Genre/Subgenre/Author/Book.epub")

    -- Every drill level re-anchors the depth budget, mirroring how browsing
    -- reveals one more level per drill.
    local sub = Repo.getFolderBookPaths("/home/Novels/Genre")
    assert(#sub == 1, "expected the deep book from the Genre level too, got " .. #sub)
end)

-- ============================================================================
-- Task 5: getAllFolderChoices - move destinations including empty folders
-- ============================================================================

test("getAllFolderChoices: lists every dir within walk depth, empty ones too", function()
    -- getFolderChoices only surfaces folders that hold a book (derived from
    -- the book-walk cache); a move destination can legitimately be an empty
    -- folder, so this is a directory-only lfs walk instead.
    Repo.invalidateWalkCache()
    local tree = {
        ["/h"]                       = { ".", "..", "a", ".hidden", "book.sdr", "one.epub" },
        ["/h/a"]                      = { ".", "..", "empty", "deep1" },
        ["/h/a/empty"]                = { ".", ".." },
        ["/h/a/deep1"]                = { ".", "..", "deep2" },
        ["/h/a/deep1/deep2"]          = { ".", "..", "deep3" },
        ["/h/a/deep1/deep2/deep3"]    = { ".", ".." },
        ["/h/.hidden"]                = { ".", ".." },
        ["/h/book.sdr"]               = { ".", ".." },
    }
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = tree[path] or {}
        local i = 0
        return function() i = i + 1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(fp, key)
        if key == "mode" then return tree[fp] and "directory" or "file" end
    end
    _G._test_settings = { home_dir = "/h", bookshelf_latest_walk_depth = 3 }

    local choices = Repo.getAllFolderChoices()

    -- deep3 sits at level 4 (home=1, a=2, deep1=3, deep2=4... walk recursion
    -- adds a child at the level it's discovered then recurses at level+1, so
    -- deep2 is added while walking at level 3 and its own children are
    -- refused because the recursive call is at level 4 > depth 3).
    assert(#choices == 4, "expected 4 folders, got " .. #choices)

    local by_value = {}
    for _i, c in ipairs(choices) do by_value[c.value] = c end

    assert(by_value["/h/a"], "expected a")
    assert(by_value["/h/a"].label == "a")
    assert(by_value["/h/a"].subtitle == "/h/a")

    assert(by_value["/h/a/empty"], "expected a/empty")
    assert(by_value["/h/a/empty"].label == "empty")
    assert(by_value["/h/a/empty"].subtitle == "/h/a/empty")

    assert(by_value["/h/a/deep1"], "expected a/deep1")
    assert(by_value["/h/a/deep1"].label == "deep1")

    assert(by_value["/h/a/deep1/deep2"], "expected a/deep1/deep2")
    assert(by_value["/h/a/deep1/deep2"].label == "deep2")

    assert(not by_value["/h/a/deep1/deep2/deep3"], "deep3 is past the walk depth, must be excluded")
    assert(not by_value["/h/.hidden"], "hidden dirs must be excluded")
    assert(not by_value["/h/book.sdr"], "sidecar .sdr dirs must be excluded")
    assert(not by_value["/h/one.epub"], "files must never appear as folder choices")

    -- Sorted by lowercased full path, same convention as getFolderChoices.
    local values = {}
    for _i, c in ipairs(choices) do values[#values + 1] = c.value end
    assert(values[1] == "/h/a", "got " .. tostring(values[1]))
    assert(values[2] == "/h/a/deep1", "got " .. tostring(values[2]))
    assert(values[3] == "/h/a/deep1/deep2", "got " .. tostring(values[3]))
    assert(values[4] == "/h/a/empty", "got " .. tostring(values[4]))
end)

-- ============================================================================
-- getBySource: opds kind attaches cover_image_path, never cover_bb/has_cover
-- (device corruption fix - see lib/bookshelf_opds_covers.lua's cachedPath doc
-- and the comment above the cover-attach loop in the opds branch above)
-- ============================================================================

test("getBySource: opds kind attaches cover_image_path via OpdsCovers.cachedPath, never cover_bb/has_cover", function()
    local rec_cached  = { filepath = "OPDS://srv/1", title = "Cached",
                          opds = { thumbnail_url = "http://srv/1.jpg" } }
    local rec_missing = { filepath = "OPDS://srv/2", title = "Missing",
                          opds = { thumbnail_url = "http://srv/2.jpg" } }

    package.loaded["lib/bookshelf_opds_window"] = {
        load = function(_id, _feed_url) return { entries = {}, fetched_at = 1, total = 2 } end,
        slice = function(_win, _offset, _limit)
            if _win and _win.entries and #_win.entries > 0 then
                local _src, _out = _win.entries, {}
                local _from = (_offset or 0) + 1
                local _to = math.min((_offset or 0) + (_limit or #_src), #_src)
                for _i = _from, _to do
                    local _c = {}
                    for _k, _v in pairs(_src[_i]) do _c[_k] = _v end
                    _out[#_out + 1] = _c
                end
                return _out, #_src, false
            end
            -- Fresh copies, same contract as the real slice().
            local page = {}
            for _i, r in ipairs({ rec_cached, rec_missing }) do
                local copy = {}
                for k, v in pairs(r) do copy[k] = v end
                page[#page + 1] = copy
            end
            return page, 2, false
        end,
        needsFetch = function() return false end,
    }
    package.loaded["lib/bookshelf_opds_covers"] = {
        cachePath = function(rec) return "/cache/" .. rec.filepath .. ".img" end,
        cachedPath = function(rec)
            if rec.filepath == "OPDS://srv/1" then return "/cache/OPDS://srv/1.img" end
            return nil
        end,
    }

    local list, total = Repo.getBySource(
        { kind = "opds", id = "srv", feed_url = "http://srv/feed" }, nil, nil, 0, 10)

    package.loaded["lib/bookshelf_opds_window"] = nil
    package.loaded["lib/bookshelf_opds_covers"] = nil

    assert(total == 2, "total passed through from slice")
    assert(#list == 2, "both records returned")
    assert(list[1].cover_image_path == "/cache/OPDS://srv/1.img",
        "the cached record gets cover_image_path from OpdsCovers.cachedPath")
    assert(list[1].cover_bb == nil, "opds branch never sets cover_bb")
    assert(list[1].has_cover == nil, "opds branch never sets has_cover")
    assert(list[2].cover_image_path == nil, "a record with nothing cached yet stays nil, not a placeholder value")
    assert(list[2].cover_bb == nil, "opds branch never sets cover_bb (record 2)")
    assert(list[2].has_cover == nil, "opds branch never sets has_cover (record 2)")
end)

-- ============================================================================
-- getBySource: opds nav-tile cover borrow (mechanism 2) -- a nav record with
-- no cover of its own borrows the first cached cover out of its child feed's
-- own (already fetched) window; never-drilled or nothing-cached stays nil.
-- ============================================================================

test("getBySource: opds nav tile borrows first cached child cover when it has none of its own", function()
    local nav = { filepath = "OPDS://srv2/nav/fic", kind = "opds_nav", is_opds_nav = true,
                  is_remote = true, title = "Fiction",
                  opds = { feed_url = "http://srv2/fiction" } }

    package.loaded["lib/bookshelf_opds_window"] = {
        load = function(_id, feed_url)
            if feed_url == "http://srv2/fiction" then
                return { entries = {
                    { filepath = "OPDS://srv2/c1", opds = { thumbnail_url = "http://srv2/c1.jpg" } },
                    { filepath = "OPDS://srv2/c2", opds = { thumbnail_url = "http://srv2/c2.jpg" } },
                } }
            end
            return { entries = {} }
        end,
        slice = function(_win, _offset, _limit)
            if _win and _win.entries and #_win.entries > 0 then
                local _src, _out = _win.entries, {}
                local _from = (_offset or 0) + 1
                local _to = math.min((_offset or 0) + (_limit or #_src), #_src)
                for _i = _from, _to do
                    local _c = {}
                    for _k, _v in pairs(_src[_i]) do _c[_k] = _v end
                    _out[#_out + 1] = _c
                end
                return _out, #_src, false
            end
            local copy = {}
            for k, v in pairs(nav) do copy[k] = v end
            return { copy }, 1, false
        end,
        needsFetch = function() return false end,
    }
    package.loaded["lib/bookshelf_opds_covers"] = {
        cachePath = function(rec) return "/cache/" .. rec.filepath .. ".img" end,
        cachedPath = function(rec)
            -- The nav tile has no cover of its own; only the SECOND child
            -- entry has a cached cover, so the borrow must skip the first.
            if rec.filepath == "OPDS://srv2/c2" then return "/cache/c2.img" end
            return nil
        end,
    }

    local list = Repo.getBySource(
        { kind = "opds", id = "srv2", feed_url = "http://srv2/root" }, nil, nil, 0, 10)

    package.loaded["lib/bookshelf_opds_window"] = nil
    package.loaded["lib/bookshelf_opds_covers"] = nil

    assert(list[1].cover_image_path == "/cache/c2.img",
        "nav tile borrows the first cached cover found among its child entries")
    assert(list[1].cover_borrowed == true,
        "a borrowed cover is flagged so it doesn't permanently suppress the tile's own cover fetch")
end)

test("getBySource: opds nav tile stays nil when the child feed has no cached window", function()
    local nav = { filepath = "OPDS://srv3/nav/fic", kind = "opds_nav", is_opds_nav = true,
                  is_remote = true, title = "Fiction",
                  opds = { feed_url = "http://srv3/fiction" } }

    package.loaded["lib/bookshelf_opds_window"] = {
        -- Never drilled into: no persisted window for the child feed.
        load = function(_id, _feed_url) return { entries = {} } end,
        slice = function(_win, _offset, _limit)
            if _win and _win.entries and #_win.entries > 0 then
                local _src, _out = _win.entries, {}
                local _from = (_offset or 0) + 1
                local _to = math.min((_offset or 0) + (_limit or #_src), #_src)
                for _i = _from, _to do
                    local _c = {}
                    for _k, _v in pairs(_src[_i]) do _c[_k] = _v end
                    _out[#_out + 1] = _c
                end
                return _out, #_src, false
            end
            local copy = {}
            for k, v in pairs(nav) do copy[k] = v end
            return { copy }, 1, false
        end,
        needsFetch = function() return false end,
    }
    package.loaded["lib/bookshelf_opds_covers"] = {
        cachePath = function(rec) return "/cache/" .. rec.filepath .. ".img" end,
        cachedPath = function(_rec) return nil end,
    }

    local list = Repo.getBySource(
        { kind = "opds", id = "srv3", feed_url = "http://srv3/root" }, nil, nil, 0, 10)

    package.loaded["lib/bookshelf_opds_window"] = nil
    package.loaded["lib/bookshelf_opds_covers"] = nil

    assert(list[1].cover_image_path == nil,
        "no cached child window -> nav tile stays a placeholder")
    assert(list[1].cover_borrowed == nil,
        "nothing borrowed -> the flag is never set")
end)

test("getBySource: opds nav tile cover borrow is capped at the first 12 child entries", function()
    local nav = { filepath = "OPDS://srv4/nav/fic", kind = "opds_nav", is_opds_nav = true,
                  is_remote = true, title = "Fiction",
                  opds = { feed_url = "http://srv4/fiction" } }
    local entries = {}
    for i = 1, 13 do
        entries[i] = { filepath = "OPDS://srv4/c" .. i,
                       opds = { thumbnail_url = "http://srv4/c" .. i .. ".jpg" } }
    end

    package.loaded["lib/bookshelf_opds_window"] = {
        load = function(_id, feed_url)
            if feed_url == "http://srv4/fiction" then return { entries = entries } end
            return { entries = {} }
        end,
        slice = function(_win, _offset, _limit)
            if _win and _win.entries and #_win.entries > 0 then
                local _src, _out = _win.entries, {}
                local _from = (_offset or 0) + 1
                local _to = math.min((_offset or 0) + (_limit or #_src), #_src)
                for _i = _from, _to do
                    local _c = {}
                    for _k, _v in pairs(_src[_i]) do _c[_k] = _v end
                    _out[#_out + 1] = _c
                end
                return _out, #_src, false
            end
            local copy = {}
            for k, v in pairs(nav) do copy[k] = v end
            return { copy }, 1, false
        end,
        needsFetch = function() return false end,
    }
    package.loaded["lib/bookshelf_opds_covers"] = {
        cachePath = function(rec) return "/cache/" .. rec.filepath .. ".img" end,
        cachedPath = function(rec)
            -- Only the 13th entry (past the 12-entry scan cap) has a cache hit.
            if rec.filepath == "OPDS://srv4/c13" then return "/cache/c13.img" end
            return nil
        end,
    }

    local list = Repo.getBySource(
        { kind = "opds", id = "srv4", feed_url = "http://srv4/root" }, nil, nil, 0, 10)

    package.loaded["lib/bookshelf_opds_window"] = nil
    package.loaded["lib/bookshelf_opds_covers"] = nil

    assert(list[1].cover_image_path == nil,
        "the only cache hit is past the scan cap, so the nav tile stays nil")
end)

test("getBySource: opds nav tile cover borrow skips coverless entries without spending the scan budget", function()
    -- Nav-first ordering (bookshelf_opds_window's mapEntries puts nav entries
    -- before books) means a subcatalog's own window can start with a long run
    -- of nav children that have no cover URL at all. Those must be ruled out
    -- for free -- the scan cap only counts entries actually STATTED
    -- (OpdsCovers.cachedPath called), not raw index -- or a page with 12+ of
    -- them defeats the borrow before it ever reaches a real cached cover.
    local nav = { filepath = "OPDS://srv5/nav/fic", kind = "opds_nav", is_opds_nav = true,
                  is_remote = true, title = "Fiction",
                  opds = { feed_url = "http://srv5/fiction" } }
    local entries = {}
    for i = 1, 20 do
        entries[i] = { filepath = "OPDS://srv5/subnav" .. i, is_opds_nav = true, opds = {} }
    end
    entries[21] = { filepath = "OPDS://srv5/book1", opds = { thumbnail_url = "http://srv5/book1.jpg" } }

    package.loaded["lib/bookshelf_opds_window"] = {
        load = function(_id, feed_url)
            if feed_url == "http://srv5/fiction" then return { entries = entries } end
            return { entries = {} }
        end,
        slice = function(_win, _offset, _limit)
            if _win and _win.entries and #_win.entries > 0 then
                local _src, _out = _win.entries, {}
                local _from = (_offset or 0) + 1
                local _to = math.min((_offset or 0) + (_limit or #_src), #_src)
                for _i = _from, _to do
                    local _c = {}
                    for _k, _v in pairs(_src[_i]) do _c[_k] = _v end
                    _out[#_out + 1] = _c
                end
                return _out, #_src, false
            end
            local copy = {}
            for k, v in pairs(nav) do copy[k] = v end
            return { copy }, 1, false
        end,
        needsFetch = function() return false end,
    }
    package.loaded["lib/bookshelf_opds_covers"] = {
        -- Mirrors the real module: nil when the record has no cover URL at
        -- all, so the 20 coverless subnav entries cost nothing to rule out.
        cachePath = function(rec)
            if not (rec.opds and (rec.opds.thumbnail_url or rec.opds.image_url)) then return nil end
            return "/cache/" .. rec.filepath .. ".img"
        end,
        cachedPath = function(rec)
            if rec.filepath == "OPDS://srv5/book1" then return "/cache/book1.img" end
            return nil
        end,
    }

    local list = Repo.getBySource(
        { kind = "opds", id = "srv5", feed_url = "http://srv5/root" }, nil, nil, 0, 10)

    package.loaded["lib/bookshelf_opds_window"] = nil
    package.loaded["lib/bookshelf_opds_covers"] = nil

    assert(list[1].cover_image_path == "/cache/book1.img",
        "the 20 coverless entries didn't spend the budget, so entry 21 is still reached")
    assert(list[1].cover_borrowed == true, "borrowed cover is flagged")
end)

test("getBySource: opds nav tile's own cover wins over a previously borrowed one once it lands on disk", function()
    -- Verifies the self-heal ordering the fix depends on: the own-cover loop
    -- runs BEFORE the borrow loop and the borrow only fills a nil
    -- cover_image_path, so once the tile's own artwork is cached, a later
    -- rebuild resolves it via cachedPath(rec) directly and the borrow (and
    -- its cover_borrowed flag) is never applied at all.
    local nav = { filepath = "OPDS://srv6/nav/fic", kind = "opds_nav", is_opds_nav = true,
                  is_remote = true, title = "Fiction",
                  opds = { feed_url = "http://srv6/fiction", thumbnail_url = "http://srv6/fic.jpg" } }
    local child = { filepath = "OPDS://srv6/c1", opds = { thumbnail_url = "http://srv6/c1.jpg" } }
    -- Two children deliberately: one would make this a "folder of one" and the
    -- tile would be replaced by the book itself before the cover passes run
    -- (see the flattening tests below), which is a different question from the
    -- own-cover-vs-borrow precedence this test is about.
    local child2 = { filepath = "OPDS://srv6/c2", opds = { thumbnail_url = "http://srv6/c2.jpg" } }

    package.loaded["lib/bookshelf_opds_window"] = {
        load = function(_id, feed_url)
            if feed_url == "http://srv6/fiction" then return { entries = { child, child2 } } end
            return { entries = {} }
        end,
        slice = function(_win, _offset, _limit)
            if _win and _win.entries and #_win.entries > 0 then
                local _src, _out = _win.entries, {}
                local _from = (_offset or 0) + 1
                local _to = math.min((_offset or 0) + (_limit or #_src), #_src)
                for _i = _from, _to do
                    local _c = {}
                    for _k, _v in pairs(_src[_i]) do _c[_k] = _v end
                    _out[#_out + 1] = _c
                end
                return _out, #_src, false
            end
            local copy = {}
            for k, v in pairs(nav) do copy[k] = v end
            return { copy }, 1, false
        end,
        needsFetch = function() return false end,
    }
    package.loaded["lib/bookshelf_opds_covers"] = {
        cachePath = function(rec) return "/cache/" .. rec.filepath .. ".img" end,
        -- The nav tile's OWN cover has now landed on disk, same as the
        -- child's -- if precedence were wrong, the borrow would still win.
        cachedPath = function(rec)
            if rec.filepath == nav.filepath then return "/cache/own.img" end
            if rec.filepath == child.filepath then return "/cache/c1.img" end
            return nil
        end,
    }

    local list = Repo.getBySource(
        { kind = "opds", id = "srv6", feed_url = "http://srv6/root" }, nil, nil, 0, 10)

    package.loaded["lib/bookshelf_opds_window"] = nil
    package.loaded["lib/bookshelf_opds_covers"] = nil

    assert(list[1].cover_image_path == "/cache/own.img",
        "the tile's own cover takes precedence over the child-borrowed one")
    assert(list[1].cover_borrowed == nil,
        "not flagged as borrowed once its own cover is in use")
end)

-- ============================================================================
-- getCoverBB: remote (OPDS) pseudo-paths never reach the local metadata layer
-- ============================================================================
--
-- A remote catalog record has no local file and no BIM row. Its cover is a
-- cached image file the repo attaches as cover_image_path, and SpineWidget's
-- external-cover branch renders that before this lazy path is reached -- but a
-- COVERLESS remote cell still falls through to getCoverBB, which would run a
-- BIM/SQLite lookup per cell per rebuild for a row that cannot exist.

test("getCoverBB: an OPDS pseudo-path returns nil without consulting BIM", function()
    -- Seeded deliberately: without the guard the stub would hand back a bb for
    -- the pseudo-path, so this fails loudly if the early return is removed.
    _G._test_bim_data = { ["OPDS://srv/1"] = { cover_bb = "REMOTE_BB" } }
    assert(Repo.getCoverBB("OPDS://srv/1") == nil,
        "remote pseudo-path must short-circuit to nil")
end)

test("getCoverBB: a local filepath still returns BIM's cover bb", function()
    _G._test_bim_data = { ["/lib/a.epub"] = { cover_bb = "LOCAL_BB" } }
    assert(Repo.getCoverBB("/lib/a.epub") == "LOCAL_BB",
        "the guard must not touch the local path")
    _G._test_bim_data = nil
end)

-- ============================================================================
-- getBySource: the nav-tile cover borrow bounds its RAW iterations too
-- ============================================================================
--
-- The stat budget (NAV_COVER_BORROW_SCAN) only counts entries actually
-- statted, so a child window that starts with a long run of coverless entries
-- is walked in full -- per nav tile, per rebuild. Cheap per iteration, but a
-- 1000-entry window makes it a shape worth removing.

test("getBySource: opds nav tile cover borrow stops after 200 raw child entries", function()
    local nav = { filepath = "OPDS://srv7/nav/fic", kind = "opds_nav", is_opds_nav = true,
                  is_remote = true, title = "Fiction",
                  opds = { feed_url = "http://srv7/fiction" } }
    local entries = {}
    for i = 1, 250 do
        entries[i] = { filepath = "OPDS://srv7/subnav" .. i, is_opds_nav = true, opds = {} }
    end
    entries[260] = { filepath = "OPDS://srv7/book1", opds = { thumbnail_url = "http://srv7/b1.jpg" } }
    for i = 251, 259 do
        entries[i] = { filepath = "OPDS://srv7/subnav" .. i, is_opds_nav = true, opds = {} }
    end

    local cachepath_calls = 0
    package.loaded["lib/bookshelf_opds_window"] = {
        load = function(_id, feed_url)
            if feed_url == "http://srv7/fiction" then return { entries = entries } end
            return { entries = {} }
        end,
        slice = function(_win, _offset, _limit)
            if _win and _win.entries and #_win.entries > 0 then
                local _src, _out = _win.entries, {}
                local _from = (_offset or 0) + 1
                local _to = math.min((_offset or 0) + (_limit or #_src), #_src)
                for _i = _from, _to do
                    local _c = {}
                    for _k, _v in pairs(_src[_i]) do _c[_k] = _v end
                    _out[#_out + 1] = _c
                end
                return _out, #_src, false
            end
            local copy = {}
            for k, v in pairs(nav) do copy[k] = v end
            return { copy }, 1, false
        end,
        needsFetch = function() return false end,
    }
    package.loaded["lib/bookshelf_opds_covers"] = {
        cachePath = function(rec)
            cachepath_calls = cachepath_calls + 1
            if not (rec.opds and (rec.opds.thumbnail_url or rec.opds.image_url)) then return nil end
            return "/cache/" .. rec.filepath .. ".img"
        end,
        cachedPath = function(rec)
            if rec.filepath == "OPDS://srv7/book1" then return "/cache/book1.img" end
            return nil
        end,
    }

    local list = Repo.getBySource(
        { kind = "opds", id = "srv7", feed_url = "http://srv7/root" }, nil, nil, 0, 10)

    package.loaded["lib/bookshelf_opds_window"] = nil
    package.loaded["lib/bookshelf_opds_covers"] = nil

    -- One call for the nav tile's OWN cover (the loop above the borrow), then
    -- at most 200 for the child scan.
    assert(cachepath_calls <= 201,
        "borrow walked past the raw-iteration cap: " .. cachepath_calls .. " cachePath calls")
    assert(list[1].cover_image_path == nil,
        "the only cache hit sits past the raw cap, so the tile stays a placeholder")
end)

-- ============================================================================
-- getBySource: opds "downloaded" decoration
-- ============================================================================
--
-- The download flow (the OPDS book modal in bookshelf_widget) records
-- opds_downloads[<OPDS pseudo-path>] = <on-disk path>. The opds branch marks a
-- visible-slice record `downloaded` only when that mapping still resolves to a
-- file, so deleting the book in the file manager retires the flag with no
-- bookkeeping pass of its own.

-- Earlier tests in this file replace the shared lfs stub's `attributes` and
-- leave it replaced (one of them answers "file" for every path it doesn't know,
-- which would flag every mapping as present). Install a purpose-built one here
-- and hand the previous back in the cleanup so nothing downstream shifts.
local _saved_lfs_attributes
local function _opdsDownloadStubs(recs)
    local lfs_stub = package.loaded["libs/libkoreader-lfs"]
    _saved_lfs_attributes = lfs_stub.attributes
    lfs_stub.attributes = function(fp, key)
        if key == "mode" then
            return _G._test_file_modes and _G._test_file_modes[fp] or nil
        end
        if key == "modification" then
            return _G._test_mtime and _G._test_mtime[fp] or 0
        end
    end
    package.loaded["lib/bookshelf_opds_window"] = {
        load = function() return { entries = {}, fetched_at = 1, total = #recs } end,
        slice = function()
            local page = {}
            for _i, r in ipairs(recs) do
                local copy = {}
                for k, v in pairs(r) do copy[k] = v end
                page[#page + 1] = copy
            end
            return page, #recs, false
        end,
        needsFetch = function() return false end,
    }
    package.loaded["lib/bookshelf_opds_covers"] = {
        cachePath  = function() return nil end,
        cachedPath = function() return nil end,
    }
end

local function _opdsDownloadCleanup()
    package.loaded["lib/bookshelf_opds_window"] = nil
    package.loaded["lib/bookshelf_opds_covers"] = nil
    package.loaded["libs/libkoreader-lfs"].attributes = _saved_lfs_attributes
    _G._test_file_modes = nil
    if _G._test_settings then _G._test_settings["bookshelf_opds_downloads"] = nil end
end

test("getBySource: opds marks a record downloaded when its mapping resolves to a file", function()
    _opdsDownloadStubs({
        { filepath = "OPDS://dl/1", title = "Have it" },
        { filepath = "OPDS://dl/2", title = "Not mapped" },
    })
    _G._test_settings = _G._test_settings or {}
    _G._test_settings["bookshelf_opds_downloads"] = { ["OPDS://dl/1"] = "/books/have-it.epub" }
    _G._test_file_modes = { ["/books/have-it.epub"] = "file" }

    local list = Repo.getBySource(
        { kind = "opds", id = "dl", feed_url = "http://dl/feed" }, nil, nil, 0, 10)
    _opdsDownloadCleanup()

    assert(list[1].downloaded == true, "mapped record with the file present is flagged")
    assert(list[2].downloaded == nil, "a record with no mapping is left alone")
end)

test("getBySource: opds leaves downloaded unset when the mapped file is gone", function()
    _opdsDownloadStubs({ { filepath = "OPDS://dl2/1", title = "Deleted since" } })
    _G._test_settings = _G._test_settings or {}
    _G._test_settings["bookshelf_opds_downloads"] = { ["OPDS://dl2/1"] = "/books/gone.epub" }
    _G._test_file_modes = nil   -- nothing on disk

    local list = Repo.getBySource(
        { kind = "opds", id = "dl2", feed_url = "http://dl2/feed" }, nil, nil, 0, 10)
    _opdsDownloadCleanup()

    assert(list[1].downloaded == nil,
        "a mapping pointing at a deleted file must not flag the record")
end)

test("getBySource: opds ignores a mapping that points at a directory", function()
    _opdsDownloadStubs({ { filepath = "OPDS://dl3/1", title = "Dir" } })
    _G._test_settings = _G._test_settings or {}
    _G._test_settings["bookshelf_opds_downloads"] = { ["OPDS://dl3/1"] = "/books" }
    _G._test_file_modes = { ["/books"] = "directory" }

    local list = Repo.getBySource(
        { kind = "opds", id = "dl3", feed_url = "http://dl3/feed" }, nil, nil, 0, 10)
    _opdsDownloadCleanup()

    assert(list[1].downloaded == nil, "only a real file counts as downloaded")
end)

test("getBySource: opds skips the download pass entirely when nothing is mapped", function()
    _opdsDownloadStubs({ { filepath = "OPDS://dl4/1", title = "Fresh" } })
    _G._test_settings = _G._test_settings or {}
    _G._test_settings["bookshelf_opds_downloads"] = nil
    -- Seeded so a pass that ran regardless of the (absent) mapping would still
    -- find nothing to flag -- the assertion is about the flag, the stat count
    -- is covered by the empty-map short-circuit in the branch itself.
    _G._test_file_modes = { ["/books/anything.epub"] = "file" }

    local list = Repo.getBySource(
        { kind = "opds", id = "dl4", feed_url = "http://dl4/feed" }, nil, nil, 0, 10)
    _opdsDownloadCleanup()

    assert(list[1].downloaded == nil, "no mapping means no decoration")
end)

-- ============================================================================
-- getBySource: opds "folder of one" flattening
-- ============================================================================
--
-- Gutenberg's popular lists make every work a nav folder whose child feed holds
-- exactly one book. When that child window is already CACHED (drilled into at
-- least once), the nav record is replaced in the page by the child book itself,
-- so the user reads the book's own tile instead of a folder that holds one
-- thing. Cache-only: an unfetched child stays a folder.

local _saved_flat_lfs_attributes
local function _opdsFlattenLfsStub()
    local lfs_stub = package.loaded["libs/libkoreader-lfs"]
    _saved_flat_lfs_attributes = lfs_stub.attributes
    lfs_stub.attributes = function(fp, key)
        if key == "mode" then
            return _G._test_file_modes and _G._test_file_modes[fp] or nil
        end
        if key == "modification" then
            return _G._test_mtime and _G._test_mtime[fp] or 0
        end
    end
end

local function _opdsFlattenCleanup()
    package.loaded["lib/bookshelf_opds_window"] = nil
    package.loaded["lib/bookshelf_opds_covers"] = nil
    if _saved_flat_lfs_attributes then
        package.loaded["libs/libkoreader-lfs"].attributes = _saved_flat_lfs_attributes
        _saved_flat_lfs_attributes = nil
    end
    _G._test_file_modes = nil
    if _G._test_settings then _G._test_settings["bookshelf_opds_downloads"] = nil end
end

test("getBySource: opds nav folder holding exactly one cached book renders as that book", function()
    local nav = { filepath = "OPDS://f1/nav/work", kind = "opds_nav", is_opds_nav = true,
                  is_remote = true, title = "Moby Dick", display_title = "Moby Dick",
                  opds = { feed_url = "http://f1/work" } }
    local child = { filepath = "OPDS://f1/book1", title = "Moby Dick", display_title = "Moby Dick",
                    is_remote = true,
                    opds = { feed_url = "http://f1/work", thumbnail_url = "http://f1/b1.jpg",
                             acquisitions = { { type = "application/epub+zip", href = "http://f1/b1.epub" } } } }

    _opdsFlattenLfsStub()
    package.loaded["lib/bookshelf_opds_window"] = {
        load = function(_id, feed_url)
            if feed_url == "http://f1/work" then
                return { entries = { child }, fetched_at = 1 }
            end
            return { entries = {}, fetched_at = 1 }
        end,
        slice = function(_win, _offset, _limit)
            if _win and _win.entries and #_win.entries > 0 then
                local _src, _out = _win.entries, {}
                local _from = (_offset or 0) + 1
                local _to = math.min((_offset or 0) + (_limit or #_src), #_src)
                for _i = _from, _to do
                    local _c = {}
                    for _k, _v in pairs(_src[_i]) do _c[_k] = _v end
                    _out[#_out + 1] = _c
                end
                return _out, #_src, false
            end
            local copy = {}
            for k, v in pairs(nav) do copy[k] = v end
            return { copy }, 1, false
        end,
        needsFetch = function() return false end,
    }
    package.loaded["lib/bookshelf_opds_covers"] = {
        cachePath = function(rec)
            if not (rec.opds and (rec.opds.thumbnail_url or rec.opds.image_url)) then return nil end
            return "/cache/" .. rec.filepath .. ".img"
        end,
        cachedPath = function(rec)
            if rec.filepath == "OPDS://f1/book1" then return "/cache/b1.img" end
            return nil
        end,
    }
    _G._test_settings = _G._test_settings or {}
    _G._test_settings["bookshelf_opds_downloads"] = { ["OPDS://f1/book1"] = "/books/moby.epub" }
    _G._test_file_modes = { ["/books/moby.epub"] = "file" }

    local list, total = Repo.getBySource(
        { kind = "opds", id = "f1", feed_url = "http://f1/root" }, nil, nil, 0, 10)
    _opdsFlattenCleanup()

    assert(total == 1, "the page still holds one record")
    assert(list[1].filepath == "OPDS://f1/book1", "the nav record is replaced by the child book")
    assert(list[1].is_opds_nav == nil, "the substituted record is an ordinary remote book")
    assert(list[1].kind == nil, "no leftover opds_nav kind")
    assert(list[1].opds.acquisitions ~= nil, "the book's acquisitions come through, so download works")
    -- Decoration ordering: the substitution happens BEFORE the cover and
    -- downloaded passes, so the book is decorated like any other page record.
    assert(list[1].cover_image_path == "/cache/b1.img", "the substituted book gets its OWN cached cover")
    assert(list[1].cover_borrowed == nil, "its own cover is not a borrow")
    assert(list[1].downloaded == true, "the downloaded tick lands on the substituted book")
    -- Shallow copy, same discipline as OpdsWindow.slice: the stored child entry
    -- must not pick up render state that would then be persisted.
    assert(child.cover_image_path == nil, "the stored child entry is never decorated")
    assert(child.downloaded == nil, "the stored child entry is never flagged downloaded")
end)

test("getBySource: opds nav folder with two cached books stays a folder (and loads the child window once)", function()
    local nav = { filepath = "OPDS://f2/nav/fic", kind = "opds_nav", is_opds_nav = true,
                  is_remote = true, title = "Fiction",
                  opds = { feed_url = "http://f2/fiction" } }
    local loads = 0
    package.loaded["lib/bookshelf_opds_window"] = {
        load = function(_id, feed_url)
            if feed_url == "http://f2/fiction" then
                loads = loads + 1
                return { entries = {
                    { filepath = "OPDS://f2/b1", opds = { thumbnail_url = "http://f2/b1.jpg" } },
                    { filepath = "OPDS://f2/b2", opds = { thumbnail_url = "http://f2/b2.jpg" } },
                }, fetched_at = 1 }
            end
            return { entries = {}, fetched_at = 1 }
        end,
        slice = function(_win, _offset, _limit)
            if _win and _win.entries and #_win.entries > 0 then
                local _src, _out = _win.entries, {}
                local _from = (_offset or 0) + 1
                local _to = math.min((_offset or 0) + (_limit or #_src), #_src)
                for _i = _from, _to do
                    local _c = {}
                    for _k, _v in pairs(_src[_i]) do _c[_k] = _v end
                    _out[#_out + 1] = _c
                end
                return _out, #_src, false
            end
            local copy = {}
            for k, v in pairs(nav) do copy[k] = v end
            return { copy }, 1, false
        end,
        needsFetch = function() return false end,
    }
    package.loaded["lib/bookshelf_opds_covers"] = {
        cachePath = function(rec)
            if not (rec.opds and (rec.opds.thumbnail_url or rec.opds.image_url)) then return nil end
            return "/cache/" .. rec.filepath .. ".img"
        end,
        cachedPath = function(rec)
            if rec.filepath == "OPDS://f2/b1" then return "/cache/b1.img" end
            return nil
        end,
    }

    local list = Repo.getBySource(
        { kind = "opds", id = "f2", feed_url = "http://f2/root" }, nil, nil, 0, 10)
    _opdsFlattenCleanup()

    assert(list[1].is_opds_nav == true, "two books is a folder, not a book")
    assert(list[1].filepath == "OPDS://f2/nav/fic", "the nav record is left in place")
    assert(list[1].cover_image_path == "/cache/b1.img", "the cover borrow still runs for a real folder")
    assert(list[1].cover_borrowed == true, "and is still flagged as borrowed")
    assert(loads == 1, "the flatten check and the cover borrow share ONE child-window load, got " .. loads)
end)

test("getBySource: opds nav folder holding one book plus a subfolder stays a folder", function()
    local nav = { filepath = "OPDS://f3/nav/fic", kind = "opds_nav", is_opds_nav = true,
                  is_remote = true, title = "Fiction",
                  opds = { feed_url = "http://f3/fiction" } }
    package.loaded["lib/bookshelf_opds_window"] = {
        load = function(_id, feed_url)
            if feed_url == "http://f3/fiction" then
                return { entries = {
                    { filepath = "OPDS://f3/b1", title = "Lone", opds = {} },
                    { filepath = "OPDS://f3/nav/sub", is_opds_nav = true, opds = { feed_url = "http://f3/sub" } },
                }, fetched_at = 1 }
            end
            return { entries = {}, fetched_at = 1 }
        end,
        slice = function(_win, _offset, _limit)
            if _win and _win.entries and #_win.entries > 0 then
                local _src, _out = _win.entries, {}
                local _from = (_offset or 0) + 1
                local _to = math.min((_offset or 0) + (_limit or #_src), #_src)
                for _i = _from, _to do
                    local _c = {}
                    for _k, _v in pairs(_src[_i]) do _c[_k] = _v end
                    _out[#_out + 1] = _c
                end
                return _out, #_src, false
            end
            local copy = {}
            for k, v in pairs(nav) do copy[k] = v end
            return { copy }, 1, false
        end,
        needsFetch = function() return false end,
    }
    package.loaded["lib/bookshelf_opds_covers"] = {
        cachePath = function() return nil end,
        cachedPath = function() return nil end,
    }

    local list = Repo.getBySource(
        { kind = "opds", id = "f3", feed_url = "http://f3/root" }, nil, nil, 0, 10)
    _opdsFlattenCleanup()

    assert(list[1].is_opds_nav == true,
        "a child feed with a subfolder still has somewhere to drill, so it stays a folder")
    assert(list[1].filepath == "OPDS://f3/nav/fic", "the nav record is left in place")
end)

test("getBySource: opds nav folder with no cached child window stays a folder", function()
    local nav = { filepath = "OPDS://f4/nav/work", kind = "opds_nav", is_opds_nav = true,
                  is_remote = true, title = "Never drilled",
                  opds = { feed_url = "http://f4/work" } }
    package.loaded["lib/bookshelf_opds_window"] = {
        -- Never fetched: OpdsWindow.load hands back the empty default.
        load = function(_id, _feed_url) return { entries = {}, fetched_at = 0 } end,
        slice = function(_win, _offset, _limit)
            if _win and _win.entries and #_win.entries > 0 then
                local _src, _out = _win.entries, {}
                local _from = (_offset or 0) + 1
                local _to = math.min((_offset or 0) + (_limit or #_src), #_src)
                for _i = _from, _to do
                    local _c = {}
                    for _k, _v in pairs(_src[_i]) do _c[_k] = _v end
                    _out[#_out + 1] = _c
                end
                return _out, #_src, false
            end
            local copy = {}
            for k, v in pairs(nav) do copy[k] = v end
            return { copy }, 1, false
        end,
        needsFetch = function() return false end,
    }
    package.loaded["lib/bookshelf_opds_covers"] = {
        cachePath = function() return nil end,
        cachedPath = function() return nil end,
    }

    local list = Repo.getBySource(
        { kind = "opds", id = "f4", feed_url = "http://f4/root" }, nil, nil, 0, 10)
    _opdsFlattenCleanup()

    assert(list[1].is_opds_nav == true,
        "nothing cached to flatten with: the folder is unchanged until it is drilled once")
    assert(list[1].filepath == "OPDS://f4/nav/work", "the nav record is left in place")
end)

test("getBySource: opds nav folder whose child window is only partly fetched stays a folder", function()
    -- A drill that was cancelled (or failed) part-way persists a window holding
    -- page 1 with next_url still set -- and page 1 of a Gutenberg-collapsed feed
    -- is exactly one book. Flattening that would hide the REST of the
    -- subcatalogue for good: nothing re-fetches a child feed except drilling
    -- into it, which the flattened tile no longer offers. appendPage leaves
    -- next_url nil exactly when the feed is exhausted, so "more to come" is the
    -- test, and a server that always emits rel=next degrades to a folder.
    local nav = { filepath = "OPDS://f6/nav/work", kind = "opds_nav", is_opds_nav = true,
                  is_remote = true, title = "Partly fetched",
                  opds = { feed_url = "http://f6/work" } }
    local child = { filepath = "OPDS://f6/book1", title = "Page one of many",
                    opds = { feed_url = "http://f6/work",
                             acquisitions = { { type = "application/epub+zip", href = "http://f6/b1.epub" } } } }
    package.loaded["lib/bookshelf_opds_window"] = {
        load = function(_id, feed_url)
            if feed_url == "http://f6/work" then
                return { entries = { child }, fetched_at = 1, next_url = "http://f6/work?page=2" }
            end
            return { entries = {}, fetched_at = 1 }
        end,
        slice = function(_win, _offset, _limit)
            if _win and _win.entries and #_win.entries > 0 then
                local _src, _out = _win.entries, {}
                local _from = (_offset or 0) + 1
                local _to = math.min((_offset or 0) + (_limit or #_src), #_src)
                for _i = _from, _to do
                    local _c = {}
                    for _k, _v in pairs(_src[_i]) do _c[_k] = _v end
                    _out[#_out + 1] = _c
                end
                return _out, #_src, false
            end
            local copy = {}
            for k, v in pairs(nav) do copy[k] = v end
            return { copy }, 1, false
        end,
        needsFetch = function() return false end,
    }
    package.loaded["lib/bookshelf_opds_covers"] = {
        cachePath = function() return nil end,
        cachedPath = function() return nil end,
    }

    local list = Repo.getBySource(
        { kind = "opds", id = "f6", feed_url = "http://f6/root" }, nil, nil, 0, 10)
    _opdsFlattenCleanup()

    assert(list[1].is_opds_nav == true,
        "an unexhausted child feed may hold more books, so the folder stays drillable")
    assert(list[1].filepath == "OPDS://f6/nav/work", "the nav record is left in place")
end)

test("getBySource: opds nav folder whose lone child has no acquisitions stays a folder", function()
    -- A record with nothing to download is not a book the user can do anything
    -- with; promoting it would swap a working folder for a dead tile.
    local nav = { filepath = "OPDS://f7/nav/work", kind = "opds_nav", is_opds_nav = true,
                  is_remote = true, title = "Work",
                  opds = { feed_url = "http://f7/work" } }
    package.loaded["lib/bookshelf_opds_window"] = {
        load = function(_id, feed_url)
            if feed_url == "http://f7/work" then
                return { entries = {
                    { filepath = "OPDS://f7/x", title = "Nothing to download",
                      opds = { feed_url = "http://f7/work" } },
                }, fetched_at = 1 }
            end
            return { entries = {}, fetched_at = 1 }
        end,
        slice = function(_win, _offset, _limit)
            if _win and _win.entries and #_win.entries > 0 then
                local _src, _out = _win.entries, {}
                local _from = (_offset or 0) + 1
                local _to = math.min((_offset or 0) + (_limit or #_src), #_src)
                for _i = _from, _to do
                    local _c = {}
                    for _k, _v in pairs(_src[_i]) do _c[_k] = _v end
                    _out[#_out + 1] = _c
                end
                return _out, #_src, false
            end
            local copy = {}
            for k, v in pairs(nav) do copy[k] = v end
            return { copy }, 1, false
        end,
        needsFetch = function() return false end,
    }
    package.loaded["lib/bookshelf_opds_covers"] = {
        cachePath = function() return nil end,
        cachedPath = function() return nil end,
    }

    local list = Repo.getBySource(
        { kind = "opds", id = "f7", feed_url = "http://f7/root" }, nil, nil, 0, 10)
    _opdsFlattenCleanup()

    assert(list[1].is_opds_nav == true,
        "a lone child with no acquisitions is not a downloadable book, so the folder stays")
    assert(list[1].filepath == "OPDS://f7/nav/work", "the nav record is left in place")
end)

test("getBySource: opds folder-of-one flattening is skipped on the light_only scan path", function()
    -- light_only ("Go to letter") asks for records to READ SORT KEYS off, with
    -- a limit of the whole window. Nothing on that path renders a tile, so the
    -- per-record disk work (child-window loads, cover stats) must not happen.
    local nav = { filepath = "OPDS://f5/nav/work", kind = "opds_nav", is_opds_nav = true,
                  is_remote = true, title = "Work",
                  opds = { feed_url = "http://f5/work" } }
    local child = { filepath = "OPDS://f5/book1", title = "Lone Book",
                    opds = { feed_url = "http://f5/work", thumbnail_url = "http://f5/b1.jpg" } }
    local child_loads, cached_calls = 0, 0
    package.loaded["lib/bookshelf_opds_window"] = {
        load = function(_id, feed_url)
            if feed_url == "http://f5/work" then
                child_loads = child_loads + 1
                return { entries = { child }, fetched_at = 1 }
            end
            return { entries = {}, fetched_at = 1 }
        end,
        slice = function(_win, _offset, _limit)
            if _win and _win.entries and #_win.entries > 0 then
                local _src, _out = _win.entries, {}
                local _from = (_offset or 0) + 1
                local _to = math.min((_offset or 0) + (_limit or #_src), #_src)
                for _i = _from, _to do
                    local _c = {}
                    for _k, _v in pairs(_src[_i]) do _c[_k] = _v end
                    _out[#_out + 1] = _c
                end
                return _out, #_src, false
            end
            local copy = {}
            for k, v in pairs(nav) do copy[k] = v end
            return { copy }, 1, false
        end,
        needsFetch = function() return false end,
    }
    package.loaded["lib/bookshelf_opds_covers"] = {
        cachePath  = function(rec) return "/cache/" .. rec.filepath .. ".img" end,
        cachedPath = function(_rec) cached_calls = cached_calls + 1; return "/cache/x.img" end,
    }

    local list = Repo.getBySource(
        { kind = "opds", id = "f5", feed_url = "http://f5/root" }, nil, nil, 0, 10,
        { light_only = true })
    _opdsFlattenCleanup()

    assert(list[1].is_opds_nav == true, "light_only leaves the nav record alone")
    assert(list[1].cover_image_path == nil, "light_only attaches no cover at all")
    assert(cached_calls == 0, "no cover stats on the light_only path, got " .. cached_calls)
    assert(child_loads == 0, "no child-window loads on the light_only path, got " .. child_loads)
end)

-- ============================================================================
-- getBySource: opds feed summaries fill the standard `description` field
-- ============================================================================
--
-- A feed record keeps its blurb under opds.summary (what the download modal
-- reads). Every GENERIC consumer -- the hero's %description token, the
-- description viewer -- reads the `description` field a local book carries, so
-- the decoration mirrors one into the other on the page records only. The
-- persisted window keeps storing the summary exactly once (see the scrub list
-- in lib/bookshelf_opds_window.lua).

test("getBySource: opds book records mirror opds.summary into description", function()
    local with_summary = { filepath = "OPDS://d1/1", title = "With", is_remote = true,
                           opds = { summary = "<p>A blurb.</p>",
                                    acquisitions = { { type = "application/epub+zip",
                                                       href = "http://d1/1.epub" } } } }
    local no_summary   = { filepath = "OPDS://d1/2", title = "Without", is_remote = true,
                           opds = { acquisitions = { { type = "application/epub+zip",
                                                       href = "http://d1/2.epub" } } } }
    -- A record that somehow already carries its own description keeps it: the
    -- mirror fills a gap, it never overwrites.
    local own_desc     = { filepath = "OPDS://d1/3", title = "Own", is_remote = true,
                           description = "already mine",
                           opds = { summary = "feed blurb",
                                    acquisitions = { { type = "application/epub+zip",
                                                       href = "http://d1/3.epub" } } } }
    local nav          = { filepath = "OPDS://d1/nav/x", kind = "opds_nav", is_opds_nav = true,
                           is_remote = true, title = "Folder",
                           opds = { feed_url = "http://d1/sub" } }

    _opdsFlattenLfsStub()
    package.loaded["lib/bookshelf_opds_window"] = {
        -- The child feed is uncached, so the nav tile stays a folder and this
        -- test is only about the description mirror.
        load = function(_id, _feed_url) return { entries = {}, fetched_at = 0 } end,
        slice = function(_win, _offset, _limit)
            if _win and _win.entries and #_win.entries > 0 then
                local _src, _out = _win.entries, {}
                local _from = (_offset or 0) + 1
                local _to = math.min((_offset or 0) + (_limit or #_src), #_src)
                for _i = _from, _to do
                    local _c = {}
                    for _k, _v in pairs(_src[_i]) do _c[_k] = _v end
                    _out[#_out + 1] = _c
                end
                return _out, #_src, false
            end
            local page = {}
            for _i, r in ipairs({ with_summary, no_summary, own_desc, nav }) do
                local copy = {}
                for k, v in pairs(r) do copy[k] = v end
                page[#page + 1] = copy
            end
            return page, 4, false
        end,
        needsFetch = function() return false end,
    }
    package.loaded["lib/bookshelf_opds_covers"] = {
        cachePath  = function(_rec) return nil end,
        cachedPath = function(_rec) return nil end,
    }

    local list = Repo.getBySource(
        { kind = "opds", id = "d1", feed_url = "http://d1/root" }, nil, nil, 0, 10)
    _opdsFlattenCleanup()

    assert(list[1].description == "<p>A blurb.</p>",
        "a book with a feed summary gets it as description, got " .. tostring(list[1].description))
    assert(list[1].opds.summary == "<p>A blurb.</p>",
        "the original opds.summary is left alone")
    assert(list[2].description == nil,
        "a book with no summary keeps a nil description, got " .. tostring(list[2].description))
    assert(list[3].description == "already mine",
        "an existing description is never overwritten, got " .. tostring(list[3].description))
    assert(list[4].description == nil, "a nav folder is not a book and gets no description")
end)

test("getBySource: the flattened folder-of-one book carries its summary as description", function()
    -- Decoration ordering again: the substituted child must be decorated like
    -- any other page record, description included.
    local nav = { filepath = "OPDS://d2/nav/work", kind = "opds_nav", is_opds_nav = true,
                  is_remote = true, title = "Moby Dick",
                  opds = { feed_url = "http://d2/work" } }
    local child = { filepath = "OPDS://d2/book1", title = "Moby Dick", is_remote = true,
                    opds = { feed_url = "http://d2/work", summary = "Call me Ishmael.",
                             acquisitions = { { type = "application/epub+zip",
                                                href = "http://d2/b1.epub" } } } }

    _opdsFlattenLfsStub()
    package.loaded["lib/bookshelf_opds_window"] = {
        load = function(_id, feed_url)
            if feed_url == "http://d2/work" then return { entries = { child }, fetched_at = 1 } end
            return { entries = {}, fetched_at = 1 }
        end,
        slice = function(_win, _offset, _limit)
            if _win and _win.entries and #_win.entries > 0 then
                local _src, _out = _win.entries, {}
                local _from = (_offset or 0) + 1
                local _to = math.min((_offset or 0) + (_limit or #_src), #_src)
                for _i = _from, _to do
                    local _c = {}
                    for _k, _v in pairs(_src[_i]) do _c[_k] = _v end
                    _out[#_out + 1] = _c
                end
                return _out, #_src, false
            end
            local copy = {}
            for k, v in pairs(nav) do copy[k] = v end
            return { copy }, 1, false
        end,
        needsFetch = function() return false end,
    }
    package.loaded["lib/bookshelf_opds_covers"] = {
        cachePath  = function(_rec) return nil end,
        cachedPath = function(_rec) return nil end,
    }

    local list = Repo.getBySource(
        { kind = "opds", id = "d2", feed_url = "http://d2/root" }, nil, nil, 0, 10)
    _opdsFlattenCleanup()

    assert(list[1].filepath == "OPDS://d2/book1", "the folder still flattens to the child book")
    assert(list[1].description == "Call me Ishmael.",
        "and the substituted book carries the description, got " .. tostring(list[1].description))
    assert(child.description == nil,
        "the STORED child entry is never decorated (it would be persisted)")
end)

-- ============================================================================
-- Repo.opdsLoneChildBook -- the tap-side face of the "folder of one" predicate
-- ============================================================================
--
-- The widget asks this before drilling into a nav tile: a subcatalog holding
-- exactly one book is opened AS that book (its detail modal) rather than drilled
-- into and backed out of. Same predicate the tile flattening uses, so the two
-- can never disagree; the record comes back decorated like any shelf record.

test("Repo.opdsLoneChildBook returns a decorated copy for a cached folder of one", function()
    local child = { filepath = "OPDS://L1/book1", title = "Lone", is_remote = true,
                    opds = { summary = "The only book here.",
                             thumbnail_url = "http://L1/b1.jpg",
                             acquisitions = { { type = "application/epub+zip",
                                                href = "http://L1/b1.epub" } } } }
    _opdsFlattenLfsStub()
    package.loaded["lib/bookshelf_opds_window"] = {
        load = function(_id, feed_url)
            if feed_url == "http://L1/work" then return { entries = { child }, fetched_at = 1 } end
            return { entries = {}, fetched_at = 0 }
        end,
        -- opdsLoneChildBook reads the child window through slice() now
        -- (two rows is all it needs to disqualify one), so the stub has to
        -- answer for the window it is handed.
        slice = function(_win, _offset, _limit)
            local _src, _out = (_win and _win.entries) or {}, {}
            local _to = math.min((_offset or 0) + (_limit or #_src), #_src)
            for _i = (_offset or 0) + 1, _to do
                local _c = {}
                for _k, _v in pairs(_src[_i]) do _c[_k] = _v end
                _out[#_out + 1] = _c
            end
            return _out, #_src, false
        end,
    }
    package.loaded["lib/bookshelf_opds_covers"] = {
        cachePath  = function(rec) return "/cache/" .. rec.filepath .. ".img" end,
        cachedPath = function(rec)
            if rec.filepath == "OPDS://L1/book1" then return "/cache/b1.img" end
            return nil
        end,
    }
    _G._test_settings = _G._test_settings or {}
    _G._test_settings["bookshelf_opds_downloads"] = { ["OPDS://L1/book1"] = "/books/lone.epub" }
    _G._test_file_modes = { ["/books/lone.epub"] = "file" }

    local rec = Repo.opdsLoneChildBook("L1", "http://L1/work")
    _opdsFlattenCleanup()

    assert(rec ~= nil, "a cached folder of one resolves to its book")
    assert(rec.filepath == "OPDS://L1/book1", "it is the child book, got " .. tostring(rec.filepath))
    assert(rec ~= child, "a COPY, so the stored window entry can't be decorated")
    assert(rec.description == "The only book here.", "decorated with the feed summary as description")
    assert(rec.cover_image_path == "/cache/b1.img", "decorated with its own cached cover")
    assert(rec.downloaded == true, "decorated with the downloaded tick")
    assert(child.description == nil, "the stored entry stays clean")
    assert(child.cover_image_path == nil, "the stored entry stays clean (cover)")
    assert(child.downloaded == nil, "the stored entry stays clean (downloaded)")
end)

test("Repo.opdsLoneChildBook says nil for an uncached, multi-book or unexhausted child", function()
    local one = { filepath = "OPDS://L2/b1", title = "One", is_remote = true,
                  opds = { acquisitions = { { type = "application/epub+zip", href = "http://L2/1.epub" } } } }
    local two = { filepath = "OPDS://L2/b2", title = "Two", is_remote = true,
                  opds = { acquisitions = { { type = "application/epub+zip", href = "http://L2/2.epub" } } } }
    _opdsFlattenLfsStub()
    package.loaded["lib/bookshelf_opds_window"] = {
        load = function(_id, feed_url)
            if feed_url == "http://L2/multi" then return { entries = { one, two }, fetched_at = 1 } end
            if feed_url == "http://L2/partial" then
                -- One book, but the feed still has a rel=next: page 2 could hold
                -- more, and nothing would ever re-fetch a flattened tile.
                return { entries = { one }, fetched_at = 1, next_url = "http://L2/partial?p=2" }
            end
            return { entries = {}, fetched_at = 0 }
        end,
        -- opdsLoneChildBook reads the child window through slice() now
        -- (two rows is all it needs to disqualify one), so the stub has to
        -- answer for the window it is handed.
        slice = function(_win, _offset, _limit)
            local _src, _out = (_win and _win.entries) or {}, {}
            local _to = math.min((_offset or 0) + (_limit or #_src), #_src)
            for _i = (_offset or 0) + 1, _to do
                local _c = {}
                for _k, _v in pairs(_src[_i]) do _c[_k] = _v end
                _out[#_out + 1] = _c
            end
            return _out, #_src, false
        end,
    }
    package.loaded["lib/bookshelf_opds_covers"] = {
        cachePath = function(_rec) return nil end, cachedPath = function(_rec) return nil end,
    }

    local uncached = Repo.opdsLoneChildBook("L2", "http://L2/never")
    local multi    = Repo.opdsLoneChildBook("L2", "http://L2/multi")
    local partial  = Repo.opdsLoneChildBook("L2", "http://L2/partial")
    local no_key   = Repo.opdsLoneChildBook(nil, "http://L2/multi")
    _opdsFlattenCleanup()

    assert(uncached == nil, "a child that has never been fetched is not a lone book")
    assert(multi == nil, "two books is a real folder")
    assert(partial == nil, "a feed with more pages behind it keeps its folder")
    assert(no_key == nil, "a missing server key answers nil rather than erroring")
end)

-- ============================================================================
-- progressFor's gate answer, and fileSizeFor
-- ============================================================================

test("progressFor reports whether the book has ever been opened", function()
    -- The fifth return is the sidecar gate the function already runs, handed
    -- back instead of discarded. List view's Progress column needs it to tell
    -- a never-opened book (the dash) from one opened and still at 0% ("0%"),
    -- and it must be the SAME answer, not a second guess at it.
    _G._test_docsettings_data = {
        ["/books/read.epub"] = { percent_finished = 0.4,
                                 summary = { status = "reading" } },
    }
    Repo.invalidateProgressCache()

    local pct, status, _rating, _pages, opened = Repo.progressFor("/books/read.epub")
    assert(opened == true, "a book with a sidecar reads as opened")
    assert(pct == 0.4 and status == "reading", "the first four returns moved")

    local _p, _s, _r, _pg, never = Repo.progressFor("/books/untouched.epub")
    assert(never == false, "a book with no sidecar must not read as opened")

    local _p2, _s2, _r2, _pg2, no_path = Repo.progressFor(nil)
    assert(no_path == false, "a nil filepath must not read as opened")

    _G._test_docsettings_data = nil
    Repo.invalidateProgressCache()
end)

test("fileSizeFor stats once and memoizes, and forgets on a walk invalidate", function()
    -- A book on disk always has a size, and BookInfoManager stores none, so
    -- the File size column has to come here. 27 rows a page turn means the
    -- memo is the whole cost model.
    local calls = 0
    local prev_attr = package.loaded["libs/libkoreader-lfs"].attributes
    package.loaded["libs/libkoreader-lfs"].attributes = function(fp, key)
        if key == "size" then
            calls = calls + 1
            if fp == "/books/there.epub" then return 4096 end
            return nil                      -- no file behind it
        end
        return prev_attr(fp, key)
    end

    Repo.invalidateWalkCache()
    assert(Repo.fileSizeFor("/books/there.epub") == 4096)
    assert(Repo.fileSizeFor("/books/there.epub") == 4096)
    assert(calls == 1, "the second read statted again, got " .. calls)

    -- A miss is remembered too, or a stale path re-stats on every page turn
    -- for as long as it stays on screen.
    assert(Repo.fileSizeFor("/books/gone.epub") == nil)
    assert(Repo.fileSizeFor("/books/gone.epub") == nil)
    assert(calls == 2, "the miss was not memoized, got " .. calls)

    -- Degenerate inputs answer nil without touching the filesystem.
    assert(Repo.fileSizeFor(nil) == nil)
    assert(Repo.fileSizeFor("") == nil)
    assert(calls == 2, "a nil/empty path reached the filesystem")

    -- A walk invalidation is the signal that files may have been added,
    -- removed or replaced, so the sizes have to be re-read.
    Repo.invalidateWalkCache()
    assert(Repo.fileSizeFor("/books/there.epub") == 4096)
    assert(calls == 3, "invalidateWalkCache did not clear the size memo")

    package.loaded["libs/libkoreader-lfs"].attributes = prev_attr
    Repo.invalidateWalkCache()
end)

-- ============================================================================
-- Device-library sources (Kindle / Kobo) must honour the chip's FILTER.
--
-- They used to skip it entirely: list, sort, slice, return. So a filter set on
-- a Kindle chip did nothing -- a rating filter excluding 1-star books still
-- showed them, which is how this was reported. Verified on a PW5 before the
-- fix: 106 books with the 1-star title present, 105 with it gone after.
--
-- The count matters as much as the membership: `total` drives pagination, so
-- filtering after the slice would leave a page short and the page count wrong.

local function stub_kindle_source(books)
    package.loaded["lib/bookshelf_kindle_source"] = {
        isAvailable = function() return true end,
        listBooks = function()
            local out = {}
            for i, b in ipairs(books) do out[i] = b end
            return out
        end,
    }
end

local KINDLE_BOOKS = {
    { title = "One Star",  filepath = "/k/one.kfx",  rating = 1, _status = "reading" },
    { title = "Four Star", filepath = "/k/four.kfx", rating = 4, _status = "reading" },
    { title = "Unrated",   filepath = "/k/none.kfx", rating = nil, _status = "reading" },
}

test("getBySource(kindle): a rating filter excludes the rated-out books", function()
    stub_kindle_source(KINDLE_BOOKS)
    local list, total = Repo.getBySource({ kind = "kindle" },
        { ratings = { ["2"] = true, ["3"] = true, ["4"] = true, ["5"] = true, unrated = true } },
        nil, 0, 100)
    local seen = {}
    for _i, b in ipairs(list) do seen[b.title] = true end
    assert(not seen["One Star"], "the 1-star book must be filtered out")
    assert(seen["Four Star"], "the 4-star book must remain")
    assert(seen["Unrated"], "unrated was selected, so it must remain")
    assert(#list == 2, "expected 2 books, got " .. #list)
    assert(total == 2, "total must be the FILTERED count (it drives pagination), got "
        .. tostring(total))
    package.loaded["lib/bookshelf_kindle_source"] = nil
end)

test("getBySource(kindle): no filter returns everything", function()
    stub_kindle_source(KINDLE_BOOKS)
    local list, total = Repo.getBySource({ kind = "kindle" }, nil, nil, 0, 100)
    assert(#list == 3 and total == 3,
        "an inactive filter must not drop anything, got " .. #list .. "/" .. tostring(total))
    package.loaded["lib/bookshelf_kindle_source"] = nil
end)

test("getBySource(kindle): an empty filter table is inactive, not exclude-all", function()
    stub_kindle_source(KINDLE_BOOKS)
    local list = Repo.getBySource({ kind = "kindle" }, {}, nil, 0, 100)
    assert(#list == 3, "an empty filter must behave as no filter, got " .. #list)
    package.loaded["lib/bookshelf_kindle_source"] = nil
end)

test("getBySource(kobo): the same filter gap is closed", function()
    package.loaded["lib/bookshelf_kobo_source"] = {
        isAvailable = function() return true end,
        -- the branch decodes a cover per visible record; nothing to decode here
        coverBB = function() return nil end,
        listBooks = function()
            return {
                { title = "Kobo One",  filepath = "/kb/a.epub", rating = 1, _status = "reading" },
                { title = "Kobo Four", filepath = "/kb/b.epub", rating = 4, _status = "reading" },
            }
        end,
    }
    local list, total = Repo.getBySource({ kind = "kobo" },
        { ratings = { ["4"] = true } }, nil, 0, 100)
    assert(#list == 1 and total == 1, "expected only the 4-star Kobo book, got " .. #list)
    assert(list[1].title == "Kobo Four", "wrong book kept: " .. tostring(list[1].title))
    package.loaded["lib/bookshelf_kobo_source"] = nil
end)

test("getBySource(kindle): a genre filter sees Hardcover genres, not just sidecar ones", function()
    -- Genres on a Kindle record come from Hardcover enrichment, which is
    -- normally applied to the visible slice only -- AFTER the filter would
    -- have run. So a genre filter used to exclude a book that does have the
    -- genre, which is the case the reporter hit after adding genres via
    -- Hardcover.
    stub_kindle_source({
        { title = "Enriched", filepath = "/k/e.kfx", _status = "reading" },
        { title = "Plain",    filepath = "/k/p.kfx", _status = "reading" },
    })
    -- The repo MEMOISES the Hardcover module (getHardcover caches it), so
    -- swapping package.loaded after the first call is not seen. Patch the
    -- memoised table itself.
    local HC = require("lib/bookshelf_hardcover")
    local prev_apply, prev_avail = HC.applyMetadata, HC.isAvailable
    HC.isAvailable = function() return true end
    HC.applyMetadata = function(book)
        if book.filepath == "/k/e.kfx" then book.genres = { "Fantasy" } end
    end
    local list, total = Repo.getBySource({ kind = "kindle" },
        { genres = { ["Fantasy"] = true } }, nil, 0, 100)
    HC.applyMetadata, HC.isAvailable = prev_apply, prev_avail
    package.loaded["lib/bookshelf_kindle_source"] = nil
    assert(#list == 1 and total == 1,
        "expected only the Hardcover-enriched book, got " .. #list)
    assert(list[1].title == "Enriched",
        "wrong book kept: " .. tostring(list[1].title))
end)

test("getBySource(kindle): a rating-only filter does NOT pay for enrichment", function()
    -- The enrichment pass is gated on the filter constraining genres, so a
    -- rating filter over a large catalogue keeps costing one page.
    stub_kindle_source(KINDLE_BOOKS)
    local calls = 0
    local HC = require("lib/bookshelf_hardcover")
    local prev_apply, prev_avail = HC.applyMetadata, HC.isAvailable
    HC.isAvailable = function() return true end
    HC.applyMetadata = function() calls = calls + 1 end
    Repo.getBySource({ kind = "kindle" }, { ratings = { ["4"] = true } }, nil, 0, 100)
    HC.applyMetadata, HC.isAvailable = prev_apply, prev_avail
    package.loaded["lib/bookshelf_kindle_source"] = nil
    assert(calls == 0, "a rating filter must not enrich the whole list, got " .. calls .. " calls")
end)

test("kindleFilepaths: lists the catalogue, and is EMPTY without a Kindle library", function()
    package.loaded["lib/bookshelf_kindle_source"] = nil
    assert(#Repo.kindleFilepaths() == 0, "no Kindle source must yield no paths")

    package.loaded["lib/bookshelf_kindle_source"] = {
        isAvailable = function() return false end,
        listBooks = function() error("must not be called when unavailable") end,
    }
    assert(#Repo.kindleFilepaths() == 0, "an unavailable source must yield no paths")

    stub_kindle_source({
        { title = "A", filepath = "/k/a.kfx" },
        { title = "B", filepath = "/k/b.kfx" },
        { title = "No path" },
    })
    local paths = Repo.kindleFilepaths()
    table.sort(paths)
    assert(#paths == 2 and paths[1] == "/k/a.kfx" and paths[2] == "/k/b.kfx",
        "expected the two real paths, got " .. table.concat(paths, ","))
    package.loaded["lib/bookshelf_kindle_source"] = nil
end)

-- ─── A chip's filter picker describes that chip's source ────────────────────
-- Both halves of the picker -- the value list and the faceted counts -- used to
-- come from the walked library, so editing a Kindle or Kobo chip's filter
-- offered the local library's genres and counted local books against them:
-- values that match nothing on the chip they belong to. Harmless while those
-- chips ignored their filters, misleading once they applied them.
local function _valueSet(choices)
    local set = {}
    for _i, c in ipairs(choices or {}) do set[c.value] = c.count or 0 end
    return set
end

-- Genres on a catalogue record come from Hardcover, which the repo MEMOISES,
-- so the live module table is patched rather than package.loaded.
local function _withHardcoverGenres(by_path, fn)
    local HC = require("lib/bookshelf_hardcover")
    local prev_apply, prev_avail = HC.applyMetadata, HC.isAvailable
    HC.isAvailable = function() return true end
    HC.applyMetadata = function(book)
        local g = by_path[book.filepath]
        if g then book.genres = g end
    end
    local ok, err = pcall(fn)
    HC.applyMetadata, HC.isAvailable = prev_apply, prev_avail
    if not ok then error(err, 0) end
end

test("distinctFilterValues(genres): a Kindle chip offers ITS genres, not the library's", function()
    _setupResolverLibrary()   -- walked library: genres manga + sci-fi
    stub_kindle_source({
        { title = "Enriched", filepath = "/k/e.kfx", _status = "reading" },
        { title = "Plain",    filepath = "/k/p.kfx", _status = "reading" },
    })
    local scoped, unscoped
    _withHardcoverGenres({ ["/k/e.kfx"] = { "Fantasy" } }, function()
        scoped   = _valueSet(Repo.distinctFilterValues("genres", { kind = "kindle" }))
        unscoped = _valueSet(Repo.distinctFilterValues("genres"))
    end)
    package.loaded["lib/bookshelf_kindle_source"] = nil
    _teardownResolverLibrary()
    assert(scoped["Fantasy"] == 1,
        "the Kindle chip must offer its own genre, got count " .. tostring(scoped["Fantasy"]))
    assert(scoped["manga"] == nil,
        "a library genre must NOT be offered on a Kindle chip -- it matches nothing there")
    -- The other direction, or a change that simply returned the catalogue for
    -- every chip would pass the assertions above.
    assert(unscoped["manga"] == 2, "the library picker must be unchanged, got "
        .. tostring(unscoped["manga"]))
    assert(unscoped["Fantasy"] == nil, "Kindle genres must not leak into the library picker")
end)

test("distinctFilterValues: the picker's value actually matches its book", function()
    -- The point of reusing _buildGroups: a value the picker stores has to land
    -- in the same key space Filter.matches compares against. Emitting raw
    -- record fields would look right in the list and then match nothing.
    stub_kindle_source({ { title = "E", filepath = "/k/e.kfx", _status = "reading" } })
    local value
    _withHardcoverGenres({ ["/k/e.kfx"] = { "sci-fi" } }, function()
        local choices = Repo.distinctFilterValues("genres", { kind = "kindle" })
        value = choices[1] and choices[1].value
    end)
    package.loaded["lib/bookshelf_kindle_source"] = nil
    assert(value, "expected a genre choice")
    local Filter = require("lib/bookshelf_filter")
    local compiled = Filter.compile({ genres = { [value] = true } }, Repo.filterOpts())
    assert(Filter.matches({ genres = { "sci-fi" } }, compiled),
        "the offered value " .. tostring(value) .. " must match the book it came from")
end)

test("distinctFilterValues(formats): a Kindle chip offers KFX, not the library's EPUB", function()
    _setupResolverLibrary()
    stub_kindle_source({ { title = "E", filepath = "/k/e.kfx", _status = "reading" } })
    local scoped = _valueSet(Repo.distinctFilterValues("formats", { kind = "kindle" }))
    package.loaded["lib/bookshelf_kindle_source"] = nil
    _teardownResolverLibrary()
    assert(scoped["KFX"] == 1, "expected the catalogue's own format, got "
        .. tostring(scoped["KFX"]))
    assert(scoped["EPUB"] == nil, "the library's format must not be offered")
end)

test("distinctFilterValues(langs): a Kindle chip shows friendly language names", function()
    -- Languages are where the group cache's key and its LABEL differ: it keys
    -- on the canonical code and displays "English". Building the picker from
    -- raw record fields would put "en" in front of the user, which is the
    -- regression reusing _buildGroups exists to prevent.
    stub_kindle_source({ { title = "E", filepath = "/k/e.kfx", lang = "en" } })
    local choices = Repo.distinctFilterValues("langs", { kind = "kindle" })
    package.loaded["lib/bookshelf_kindle_source"] = nil
    assert(#choices == 1, "expected one language group, got " .. #choices)
    assert(choices[1].label == "English",
        "expected the friendly name the library picker shows, got "
        .. tostring(choices[1].label))
end)

test("distinctFilterValues(formats): the record's own format wins over its path", function()
    -- The case a converted Kindle book creates: the record still reports KFX
    -- (the format the user owns) while its filepath is now the converted EPUB.
    -- Filter.matches compares record.format, so a picker keyed on the PATH
    -- would offer "EPUB" for a book the filter only ever sees as "KFX" -- an
    -- option that silently matches nothing.
    stub_kindle_source({ {
        title = "Converted", format = "KFX",
        filepath = "/mnt/us/koreader/cache/kindle.koplugin/cc_x.epub",
        _status = "reading",
    } })
    local choices = Repo.distinctFilterValues("formats", { kind = "kindle" })
    package.loaded["lib/bookshelf_kindle_source"] = nil
    assert(#choices == 1, "expected one format group, got " .. #choices)
    assert(choices[1].value == "KFX",
        "the picker must offer the format the filter compares, got "
        .. tostring(choices[1].value))
    -- The property that actually matters: the offered value matches the book.
    local Filter = require("lib/bookshelf_filter")
    local compiled = Filter.compile({ formats = { [choices[1].value] = true } },
        Repo.filterOpts())
    assert(Filter.matches({ format = "KFX" }, compiled),
        "the offered value must match the record it came from")
end)

test("filter: a Format value matches whatever case it was saved in", function()
    -- A saved filter outlives the code that wrote it. A chip holding "kfx"
    -- against records reporting "KFX" excludes every book and is indis-
    -- tinguishable on screen from an empty library, so the match normalises
    -- both sides rather than trusting every producer to agree. Seen for real:
    -- a chip created while a half-updated plugin was running stored the old
    -- lowercase token and showed nothing after the restart.
    local Filter = require("lib/bookshelf_filter")
    for _, saved in ipairs({ "kfx", "KFX", "Kfx" }) do
        local compiled = Filter.compile({ formats = { [saved] = true } },
            Repo.filterOpts())
        assert(Filter.matches({ format = "KFX" }, compiled),
            ("a filter saved as %q must match a KFX record"):format(saved))
    end
    -- The mirror image, and the half a one-sided fix misses: the RECORD is the
    -- stale one. Normalising only where the filter is built passes every
    -- assertion above and still fails here.
    for _, reported in ipairs({ "kfx", "KFX", "Kfx" }) do
        local c = Filter.compile({ formats = { KFX = true } }, Repo.filterOpts())
        assert(Filter.matches({ format = reported }, c),
            ("a record reporting %q must match a KFX filter"):format(reported))
    end
    -- And it must still EXCLUDE, or "case-insensitive" would just mean
    -- "matches everything".
    local compiled = Filter.compile({ formats = { kfx = true } }, Repo.filterOpts())
    assert(not Filter.matches({ format = "EPUB" }, compiled),
        "a KFX filter must still exclude an EPUB book")
    assert(not Filter.matches({ format = nil }, compiled),
        "a record with no format must not slip through")
end)

test("distinctFilterValues: a walk-backed chip still gets the library", function()
    -- Only catalogue sources are redirected; every other chip keeps the group
    -- cache, which is faster than rebuilding per record.
    _setupResolverLibrary()
    -- A catalogue is live and available: if the whitelist were dropped, this
    -- chip would silently start describing it instead of the library.
    stub_kindle_source({ { title = "K", filepath = "/k/k.kfx", lang = "en" } })
    local all = _valueSet(Repo.distinctFilterValues("genres", { kind = "all" }))
    local langs = _valueSet(Repo.distinctFilterValues("langs", { kind = "all" }))
    package.loaded["lib/bookshelf_kindle_source"] = nil
    _teardownResolverLibrary()
    assert(langs["English"] == nil,
        "the Kindle catalogue must not be consulted for a Home chip")
    assert(all["manga"] == 2, "a Home chip must still describe the library, got "
        .. tostring(all["manga"]))
end)

test("distinctFilterValues: an OPDS chip is never redirected", function()
    -- Deliberate: answering "which genres are there?" for a remote catalogue
    -- means a network fetch, and opening a filter picker must not reach the
    -- network. OPDS keeps the library-wide list.
    _setupResolverLibrary()
    -- Same guard as the Home chip: a live catalogue must not be substituted
    -- for the remote one just because it is the cheap thing to reach for.
    stub_kindle_source({ { title = "K", filepath = "/k/k.kfx", lang = "en" } })
    local opds = _valueSet(Repo.distinctFilterValues("genres",
        { kind = "opds", id = "https://example.invalid/feed" }))
    local opds_langs = _valueSet(Repo.distinctFilterValues("langs",
        { kind = "opds", id = "https://example.invalid/feed" }))
    package.loaded["lib/bookshelf_kindle_source"] = nil
    _teardownResolverLibrary()
    assert(opds_langs["English"] == nil,
        "an OPDS chip must not be served another source's catalogue")
    assert(opds["manga"] == 2,
        "an OPDS chip must fall back to the library rather than fetch, got "
        .. tostring(opds["manga"]))
end)

test("distinctFilterValues: an unavailable Kindle library falls back", function()
    -- A chip carried over from another device: better the library's values than
    -- an empty picker with no way to build a filter at all.
    _setupResolverLibrary()
    package.loaded["lib/bookshelf_kindle_source"] = {
        isAvailable = function() return false end,
        listBooks = function() return { { title = "X", filepath = "/k/x.kfx" } } end,
    }
    local scoped = _valueSet(Repo.distinctFilterValues("genres", { kind = "kindle" }))
    package.loaded["lib/bookshelf_kindle_source"] = nil
    _teardownResolverLibrary()
    assert(scoped["manga"] == 2, "expected the library fallback, got "
        .. tostring(scoped["manga"]))
end)

test("distinctFilterValues(collections): only collections holding this source's books", function()
    _setupResolverLibrary()
    package.loaded["readcollection"] = {
        coll = {
            favorites        = {},
            ["Library only"] = { ["/lib/comics/alpha.epub"] = true },
            ["Kindle shelf"] = { ["/k/e.kfx"] = true },
        },
        default_collection_name = "favorites",
    }
    stub_kindle_source({ { title = "E", filepath = "/k/e.kfx", _status = "reading" } })
    local scoped = _valueSet(Repo.distinctFilterValues("collections", { kind = "kindle" }))
    package.loaded["lib/bookshelf_kindle_source"] = nil
    _teardownResolverLibrary()
    assert(scoped["Kindle shelf"] == 1,
        "a collection holding this chip's book must be offered, got "
        .. tostring(scoped["Kindle shelf"]))
    assert(scoped["Library only"] == nil,
        "a collection holding none of this chip's books filters to nothing, "
        .. "so it must not be offered")
end)

test("filterValueCounts: a Kindle chip's facet counts come from its catalogue", function()
    -- The counts overlay only runs when ANOTHER dimension is active, so the
    -- status filter here is what makes this reachable at all.
    _setupResolverLibrary()
    stub_kindle_source({
        { title = "A", filepath = "/k/a.kfx", _status = "reading"  },
        { title = "B", filepath = "/k/b.kfx", _status = "reading"  },
        { title = "C", filepath = "/k/c.kfx", _status = "finished" },
    })
    local counts
    _withHardcoverGenres({
        ["/k/a.kfx"] = { "Fantasy" },
        ["/k/b.kfx"] = { "Fantasy" },
        ["/k/c.kfx"] = { "Fantasy" },
    }, function()
        counts = Repo.filterValueCounts("genres",
            { statuses = { reading = true } }, { kind = "kindle" })
    end)
    package.loaded["lib/bookshelf_kindle_source"] = nil
    _teardownResolverLibrary()
    assert(counts, "expected scoped counts")
    assert(counts["Fantasy"] == 2,
        "only the two Reading Kindle books should count, got " .. tostring(counts["Fantasy"]))
    assert(counts["manga"] == nil, "library genres must not appear in a Kindle chip's counts")
end)

test("filterValueCounts(ratings): buckets come from the catalogue's own books", function()
    _setupResolverLibrary()
    stub_kindle_source({
        { title = "A", filepath = "/k/a.kfx", rating = 4, _status = "reading" },
        { title = "B", filepath = "/k/b.kfx", rating = 4, _status = "reading" },
        { title = "C", filepath = "/k/c.kfx", rating = 1, _status = "finished" },
    })
    local counts = Repo.filterValueCounts("ratings",
        { statuses = { reading = true } }, { kind = "kindle" })
    package.loaded["lib/bookshelf_kindle_source"] = nil
    _teardownResolverLibrary()
    assert(counts, "expected scoped rating counts")
    assert(counts["4"] == 2, "two Reading 4-star Kindle books, got " .. tostring(counts["4"]))
    assert(counts["1"] == 0, "the 1-star book is Finished, so excluded, got "
        .. tostring(counts["1"]))
end)

test("filterValueCounts: a Kobo chip is scoped the same way", function()
    -- Same treatment, so the two virtual libraries cannot drift apart.
    _setupResolverLibrary()
    package.loaded["lib/bookshelf_kobo_source"] = {
        isAvailable = function() return true end,
        coverBB = function() return nil end,
        listBooks = function()
            return {
                { title = "K1", filepath = "/kb/a.epub", rating = 4, _status = "reading" },
                { title = "K2", filepath = "/kb/b.epub", rating = 4, _status = "finished" },
            }
        end,
    }
    local counts = Repo.filterValueCounts("ratings",
        { statuses = { reading = true } }, { kind = "kobo" })
    package.loaded["lib/bookshelf_kobo_source"] = nil
    _teardownResolverLibrary()
    assert(counts and counts["4"] == 1,
        "expected the single Reading Kobo book, got " .. tostring(counts and counts["4"]))
end)

-- ─── Marking a Kindle book finished has to reach the catalogue cache ────────
-- The catalogue bakes each record's status in at build time and keeps that
-- build for 60s. Marking a Kindle book finished wrote the sidecar but left the
-- cached record alone, so a rebuild inside that window served the OLD status
-- back: on a PW5 three books were marked finished with identical sidecars and
-- only one showed the Finished tick, all three appearing after a restart.
local function _kindleCacheSpy(paths)
    local calls = { invalidate = 0 }
    local by_path = {}
    for _i, fp in ipairs(paths) do by_path[fp] = true end
    package.loaded["lib/bookshelf_kindle_source"] = {
        isAvailable = function() return true end,
        listBooks = function() return {} end,
        isKindlePath = function(fp) return by_path[fp] == true end,
        invalidate = function() calls.invalidate = calls.invalidate + 1 end,
    }
    return calls
end

test("invalidateProgressCache: a Kindle book drops the catalogue cache", function()
    local calls = _kindleCacheSpy({ "/mnt/us/documents/A.kfx" })
    Repo.invalidateProgressCache("/mnt/us/documents/A.kfx")
    package.loaded["lib/bookshelf_kindle_source"] = nil
    assert(calls.invalidate == 1,
        "marking a Kindle book must drop the catalogue cache, got "
        .. calls.invalidate .. " calls")
end)

test("invalidateProgressCache: a local book leaves the catalogue alone", function()
    -- Scoped deliberately: every local status change dropping the catalogue
    -- would make the next Kindle shelf re-query SQLite for nothing.
    local calls = _kindleCacheSpy({ "/mnt/us/documents/A.kfx" })
    Repo.invalidateProgressCache("/lib/local.epub")
    package.loaded["lib/bookshelf_kindle_source"] = nil
    assert(calls.invalidate == 0,
        "a local book must not drop the Kindle catalogue, got "
        .. calls.invalidate .. " calls")
end)

test("invalidateProgressCache: a whole-library invalidation drops it too", function()
    local calls = _kindleCacheSpy({ "/mnt/us/documents/A.kfx" })
    Repo.invalidateProgressCache()
    package.loaded["lib/bookshelf_kindle_source"] = nil
    assert(calls.invalidate == 1,
        "an unscoped invalidation must include the catalogue, got "
        .. calls.invalidate .. " calls")
end)

test("invalidateProgressCache: no Kindle source loaded is not an error", function()
    -- Every non-Kindle device: the module must not be pulled in just to ask.
    package.loaded["lib/bookshelf_kindle_source"] = nil
    local ok = pcall(Repo.invalidateProgressCache, "/lib/local.epub")
    assert(ok, "invalidation must survive there being no Kindle source")
    assert(package.loaded["lib/bookshelf_kindle_source"] == nil,
        "asking must not LOAD the Kindle source on a device that has none")
end)

test("kindleFilepaths is NOT folded into getAllFilepaths", function()
    -- getAllFilepaths means "the walked library", and callers rely on that:
    -- folder listings, walk-cache keying. countByStatus DOES count Kindle books
    -- (the Shelf size module should show the whole shelf), but it adds them
    -- itself, behind the Kindle-chip gate -- it does not get them from here.
    stub_kindle_source({ { title = "K", filepath = "/k/only.kfx" } })
    local walked = Repo.getAllFilepaths() or {}
    for _i, fp in ipairs(walked) do
        assert(fp ~= "/k/only.kfx", "a Kindle path leaked into the walked library")
    end
    package.loaded["lib/bookshelf_kindle_source"] = nil
end)

-- ── the page count scan reaches every consumer ─────────────────────────────
--
-- "Extract page counts" persists what it finds into the shelf's own store,
-- not into the book's sidecar: a count for a never-opened book must not be
-- the reason a sidecar appears. progressFor is what every lazy consumer asks
-- (the Pages column, the %page_count token, the sort key), so it has to look
-- there too, or the scan shows up in the spine widths -- which read the store
-- directly -- and nowhere else.

-- counts: fp -> pages (a "print" count) or {pages, tag}. shownPages is the
-- real one's rule, restated: only print / stable / render counts are shown.
local function with_scan_store(counts, fn)
    local previous = package.loaded["lib/bookshelf_spine_shelf"]
    local function entry(fp)
        local c = counts[fp]
        if type(c) == "table" then return c[1], c[2] end
        return c, c and "print" or nil
    end
    package.loaded["lib/bookshelf_spine_shelf"] = {
        cachedProgress = function(fp)
            local n, tag = entry(fp)
            if not n then return nil, nil, false end
            return n, nil, false, tag, false
        end,
        shownPages = function(fp)
            local n, tag = entry(fp)
            if tag == "print" or tag == "user" or tag == "stable" or tag == "render" then
                return n
            end
            return nil
        end,
    }
    local ok, err = pcall(fn)
    package.loaded["lib/bookshelf_spine_shelf"] = previous
    if not ok then error(err, 0) end
end

test("a scanned page count reaches progressFor for an unopened book", function()
    _G._test_docsettings_data = nil          -- no sidecar: never opened
    with_scan_store({ ["/lib/scanned.epub"] = 412 }, function()
        local _pct, _status, _rating, pages, opened =
            Repo.progressFor("/lib/scanned.epub")
        assert(pages == 412, "expected the scan's count, got " .. tostring(pages))
        assert(opened == false, "the book is still unopened")
    end)
end)

test("the HERO's record gets the scanned count too", function()
    -- The hero builds its book through buildBook, not through the lazy
    -- resolver the shelf rows use, so the two paths have to consult the store
    -- separately (device report: a page_count token on the hero stayed empty).
    _G._test_bim_data = { ["/lib/heroscan.epub"] = { title = "Hero" } }
    with_scan_store({ ["/lib/heroscan.epub"] = 377 }, function()
        local b = Repo.buildBook("/lib/heroscan.epub")
        assert(b, "buildBook returned nothing")
        assert(b.page_count == 377,
            "expected the scan's count on the hero record, got "
            .. tostring(b.page_count))
    end)
end)

test("a layout render is never shown as the book's page count", function()
    -- Reddit report: extracted counts "way off, like a factor of 4". A render
    -- at crengine's default layout is a spine-width scale, not the book's
    -- length; nor is a legacy "scan" count, which could be one.
    _G._test_docsettings_data = nil
    _G._test_bim_data = { ["/lib/layout.epub"] = { title = "L" } }
    with_scan_store({ ["/lib/layout.epub"] = { 1600, "layout" },
                      ["/lib/legacy.epub"] = { 1600, "scan" } }, function()
        local _pct, _st, _r, pages = Repo.progressFor("/lib/layout.epub")
        assert(pages == nil, "progressFor showed a layout count: " .. tostring(pages))
        local b = Repo.buildBook("/lib/layout.epub")
        assert(b and b.page_count == nil,
            "the hero showed a layout count: " .. tostring(b and b.page_count))
        assert(Repo.pageCountFor("/lib/legacy.epub", nil) == nil,
            "a legacy scan count was shown")
        assert(Repo.pageCountFor("/lib/legacy p(90).epub", nil) == 90,
            "the filename marker still answers")
    end)
end)

test("a render at the reader's layout IS shown", function()
    _G._test_docsettings_data = nil
    with_scan_store({ ["/lib/user.epub"] = { 852, "user" } }, function()
        assert(Repo.pageCountFor("/lib/user.epub", nil) == 852)
    end)
end)

test("BIM's own count still wins over the scan store", function()
    -- The store is a fallback, not an override: a book BIM has counted knows
    -- better than a scan estimate.
    _G._test_bim_data = { ["/lib/haspages.epub"] = { title = "P", pages = 512 } }
    with_scan_store({ ["/lib/haspages.epub"] = 999 }, function()
        local b = Repo.buildBook("/lib/haspages.epub")
        assert(b.page_count == 512,
            "expected BIM's count, got " .. tostring(b.page_count))
    end)
end)

test("one function owns the end of the page-count ladder", function()
    -- Three consumers ask the same question -- the hero through buildBook, the
    -- rows through progressFor, the spine plan for its widths -- and each had
    -- grown its own ending. Two of them got patched separately in two days.
    assert(type(Repo.pageCountFor) == "function", "Repo.pageCountFor missing")
    with_scan_store({ ["/lib/x.epub"] = 300 }, function()
        assert(Repo.pageCountFor("/lib/x.epub", 512) == 512,
            "what the caller already knows wins")
        assert(Repo.pageCountFor("/lib/x.epub", nil) == 300, "then the store")
        assert(Repo.pageCountFor("/lib/y p(88).epub", nil) == 88,
            "and the filename marker answers when the store does not")
        assert(Repo.pageCountFor("/lib/z.epub", 0) == nil,
            "a zero is not a count")
        assert(Repo.pageCountFor(nil, nil) == nil, "no path, no answer")
    end)
end)

test("an opened book with no committed total still gets the marker", function()
    -- The sidecar branch of progressFor used to skip the filename marker and
    -- go straight to the store, so an opened reflowable named p(N) with no
    -- total yet answered differently from the same book unopened.
    _G._test_docsettings_data = { ["/lib/opened p(415).epub"] = { percent_finished = 0.5 } }
    with_scan_store({}, function()
        local _p, _s, _r, pages, opened = Repo.progressFor("/lib/opened p(415).epub")
        assert(opened == true, "the book has a sidecar")
        assert(pages == 415, "expected the marker, got " .. tostring(pages))
    end)
    _G._test_docsettings_data = nil
end)

test("a scanned count outranks a filename marker; the marker is the fallback", function()
    -- The maintainer: a p(N) set by Calibre "won't be as accurate as ours",
    -- and a reader with those in their file names may want to override them.
    -- A scan that keeps file names as a source stores the marker's own
    -- number, so for that reader nothing changes.
    with_scan_store({ ["/lib/marked p(250).epub"] = 999 }, function()
        local _p, _s, _r, pages = Repo.progressFor("/lib/marked p(250).epub")
        assert(pages == 999, "expected the scan's count, got " .. tostring(pages))
    end)
    with_scan_store({}, function()
        local _p, _s, _r, pages = Repo.progressFor("/lib/unscanned p(250).epub")
        assert(pages == 250, "an unscanned book lost its marker: " .. tostring(pages))
    end)
end)

test("no scanned count leaves the answer nil rather than zero", function()
    with_scan_store({}, function()
        local _p, _s, _r, pages = Repo.progressFor("/lib/unknown.epub")
        assert(pages == nil, "expected nil, got " .. tostring(pages))
    end)
end)

test("the shelf module missing is not an error", function()
    -- The repository must load and answer on its own; the shelf requires it
    -- back, so this lookup is lazy and has to tolerate an absent module.
    local previous = package.loaded["lib/bookshelf_spine_shelf"]
    package.loaded["lib/bookshelf_spine_shelf"] = nil
    local ok, pages = pcall(function()
        return select(4, Repo.progressFor("/lib/whatever.epub"))
    end)
    package.loaded["lib/bookshelf_spine_shelf"] = previous
    assert(ok, "progressFor must not raise when the shelf module is absent")
    assert(pages == nil, "expected nil, got " .. tostring(pages))
end)

-- ── KOReader custom metadata (issue #381) ──────────────────────────────────
-- KOReader lets any of title / authors / series / series_index / language /
-- keywords / description be overwritten per book from Book information, and
-- shows the overwritten value everywhere. The shelf read only `keywords`, so
-- a corrected title or author was ignored here and nowhere else -- reported
-- against CBZ comics, whose metadata a ComicInfo plugin writes into exactly
-- this field.
--
-- These drive the REAL gate (a sibling .sdr found through a directory
-- listing), because the gate is what decides whether the file is read at all.

local _real_lfs_attributes = package.loaded["libs/libkoreader-lfs"].attributes
local _real_docsettings    = package.loaded["docsettings"]

-- fp -> custom_props table
local function with_custom_props(fp, props, fn)
    local base   = fp:match("^(.*)%.") or fp
    local parent, stem = base:match("^(.*/)([^/]+)$")
    local sdr    = parent .. stem .. ".sdr"
    local cmf    = sdr .. "/custom_metadata.lua"
    local leaf   = fp:match("([^/]+)$")
    -- The gate asks with a trailing slash ("/lib/"), the library walk without
    -- it ("/lib"). Both have to answer, or the walk decides the folder is a
    -- file and finds no books at all. Declared BEFORE the stubs below: a
    -- closure that names it later resolves it as a nil global, not an upvalue.
    local parent_bare = parent:gsub("/+$", "")
    local function is_parent(path) return path == parent or path == parent_bare end

    package.loaded["libs/libkoreader-lfs"].attributes = function(path, key)
        if key == "mode" then
            if is_parent(path) or path == sdr then return "directory" end
            if path == cmf then return "file" end
            -- Anything else the walk asks about is a book file.
            return "file"
        end
        return _real_lfs_attributes(path, key)
    end
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        -- The book AND its sidecar dir: the gate looks for the .sdr here and
        -- the library walk looks for the book.
        local entries = is_parent(path) and { ".", "..", leaf, stem .. ".sdr" }
                                          or { ".", ".." }
        local i = 0
        return function() i = i + 1; return entries[i] end
    end
    package.loaded["docsettings"] = setmetatable({
        findCustomMetadataFile = function(_self, f) return f == fp and cmf or nil end,
        openSettingsFile = function(f)
            return { readSetting = function(_s, key)
                if key == "custom_props" then return props end
                return nil
            end }
        end,
    }, { __index = _real_docsettings })

    -- The gate memoises its directory listings and its location decision.
    Repo.invalidateWalkCache()
    local ok, err = pcall(fn)

    package.loaded["libs/libkoreader-lfs"].attributes = _real_lfs_attributes
    package.loaded["libs/libkoreader-lfs"].dir = nil
    package.loaded["docsettings"] = _real_docsettings
    Repo.invalidateWalkCache()
    if not ok then error(err, 0) end
end

local CFP = "/lib/comic.cbz"

local function bim_row(row)
    _G._test_bim_data = { [CFP] = row }
end

test("custom title wins over the extracted one", function()
    bim_row({ title = "comic Vol.2024 #04", authors = "Not An Author" })
    with_custom_props(CFP, { title = "The Last Amazon, Part 4 of 5" }, function()
        local b = Repo.buildBookMeta(CFP)
        assert(b.title == "The Last Amazon, Part 4 of 5",
            "expected the custom title, got " .. tostring(b.title))
    end)
end)

test("custom authors win, and split on newlines like the extracted field", function()
    bim_row({ title = "T", authors = "The Last Amazon, Part 4 of 5 (March, 2025)" })
    with_custom_props(CFP, { authors = "Kelly Thompson\nHayden Sherman" }, function()
        local b = Repo.buildBookMeta(CFP)
        assert(b.author == "Kelly Thompson", "primary author: " .. tostring(b.author))
        assert(#b.authors == 2 and b.authors[2] == "Hayden Sherman",
            "expected both authors, got " .. tostring(#b.authors))
    end)
end)

test("custom series and index win, as name plus number", function()
    bim_row({ title = "T", series = "Wrong Series #9" })
    with_custom_props(CFP, { series = "Absolute Wonder Woman", series_index = "4" }, function()
        local b = Repo.buildBookMeta(CFP)
        assert(b.series_name == "Absolute Wonder Woman", "series: " .. tostring(b.series_name))
        assert(b.series_num == "4", "index: " .. tostring(b.series_num))
    end)
end)

test("a custom series with only an extracted index keeps that index", function()
    -- A real combination: the user fixed the series name and never touched
    -- the number, so the name and the number come from different sources.
    bim_row({ title = "T", series = "Wrong Series #7" })
    with_custom_props(CFP, { series = "Absolute Wonder Woman" }, function()
        local b = Repo.buildBookMeta(CFP)
        assert(b.series_name == "Absolute Wonder Woman", "series: " .. tostring(b.series_name))
        assert(b.series_num == "7", "index should fall back to BIM, got " .. tostring(b.series_num))
    end)
end)

test("custom language and description win", function()
    bim_row({ title = "T", language = "eng", description = "extracted blurb" })
    with_custom_props(CFP, { language = "fra", description = "my own blurb" }, function()
        local b = Repo.buildBookMeta(CFP)
        assert(b.lang == "fra", "lang: " .. tostring(b.lang))
        assert(b.description == "my own blurb", "description: " .. tostring(b.description))
    end)
end)

test("custom metadata beats Calibre, which beats the extracted row", function()
    -- Calibre's default filename import splits "Title - Author", which is how
    -- the reporter's comics ended up with a chapter title as their author.
    -- The user's own correction has to outrank that.
    local CalibreMeta = package.loaded["lib/calibre_metadata"]
    local real_entry = CalibreMeta.entryFor
    CalibreMeta.entryFor = function(fp)
        if fp ~= CFP then return nil end
        return { title = "comic Vol.2024 #04",
                 authors = { "The Last Amazon, Part 4 of 5 (March, 2025)" } }
    end
    bim_row({ title = "extracted", authors = "Extracted Author" })
    local ok, err = pcall(function()
        with_custom_props(CFP, { title = "The Last Amazon, Part 4 of 5",
                                 authors = "Kelly Thompson" }, function()
            local b = Repo.buildBookMeta(CFP)
            assert(b.title == "The Last Amazon, Part 4 of 5", "title: " .. tostring(b.title))
            assert(b.author == "Kelly Thompson", "author: " .. tostring(b.author))
        end)
        -- And with no custom metadata, Calibre still wins over the row: the
        -- existing behaviour this fix must not have inverted.
        local b2 = Repo.buildBookMeta(CFP)
        assert(b2.title == "comic Vol.2024 #04", "calibre title: " .. tostring(b2.title))
    end)
    CalibreMeta.entryFor = real_entry
    if not ok then error(err, 0) end
end)

test("cleared keywords still read as no genres", function()
    -- Our own genre editor writes "" to mean cleared, and that must not fall
    -- back to the file's own keywords. The one field with nil-vs-empty
    -- semantics; generalising the reader must not have flattened it.
    bim_row({ title = "T", keywords = "Comics" })
    with_custom_props(CFP, { keywords = "" }, function()
        local b = Repo.buildBookMeta(CFP)
        assert(b.genres == nil or #b.genres == 0,
            "expected no genres, got " .. tostring(b.genres and b.genres[1]))
    end)
end)

test("no custom metadata leaves the chain alone", function()
    bim_row({ title = "Extracted Title", authors = "Extracted Author" })
    local b = Repo.buildBookMeta(CFP)
    assert(b.title == "Extracted Title", "title: " .. tostring(b.title))
    assert(b.author == "Extracted Author", "author: " .. tostring(b.author))
end)

test("the author chip uses the custom author too", function()
    -- buildBookMeta feeds the shelf; the light builder feeds the author,
    -- series and genre chips. Each carried its own copy of the resolution
    -- chain, which is how a book ends up filed under one author and displayed
    -- with another. Assert the chip, since that is what a reader browses.
    bim_row({ title = "extracted", authors = "Extracted Author",
              series = "Wrong Series #9" })
    Repo.invalidateSeriesCache()
    with_custom_props(CFP, { title = "The Last Amazon, Part 4 of 5",
                             authors = "Kelly Thompson",
                             series = "Absolute Wonder Woman",
                             series_index = "4" }, function()
        _G._test_settings.home_dir = "/lib"
        _G._test_settings.bookshelf_latest_walk_depth = 1
        Repo.invalidateSeriesCache()
        local groups = Repo.getAuthors(10, 0) or {}
        assert(#groups == 1, "expected one author group, got " .. #groups)
        assert(groups[1].series_name == "Kelly Thompson"
                or groups[1].name == "Kelly Thompson",
            "author group should be the custom author, got " ..
            tostring(groups[1].series_name or groups[1].name))
        local heavy = Repo.buildBookMeta(CFP)
        assert(heavy.author == "Kelly Thompson", "shelf record disagrees")
    end)
    _G._test_settings.home_dir = nil
    _G._test_settings.bookshelf_latest_walk_depth = nil
    Repo.invalidateSeriesCache()
end)

-- ── BIM handle recovery ─────────────────────────────────────────────────────
-- A failed BookInfoManager:openDbConnection (a full volume makes SQLite throw
-- on prepare) leaves db_conn set and the cached statements dead, so every
-- later read raises "object is closed" until KOReader restarts. Repo resets
-- the handle and retries once, rate-limited. Tests drive the exported entry
-- point with a fake BIM rather than the module-cached one, so they describe
-- the recovery itself and nothing about which BIM the repo found.

-- Fake BIM in the poisoned state: reads throw until the connection is reset.
local function poisoned_bim(opts)
    opts = opts or {}
    local bim = {
        db_conn      = { open = true },
        closes       = 0,
        reads        = 0,
        heals_on_reset = opts.heals ~= false,
    }
    function bim:getBookInfo(_fp, _with_cover)
        self.reads = self.reads + 1
        if self.db_conn then
            error("common/lua-ljsqlite3/init.lua:60: ljsqlite3[misuse] object is closed", 0)
        end
        return { title = "recovered" }
    end
    function bim:closeDbConnection()
        self.closes = self.closes + 1
        if opts.close_raises then
            error("ljsqlite3[misuse] object is closed", 0)
        end
        if self.heals_on_reset then self.db_conn = nil end
    end
    return bim
end

-- The cooldown is wall-clock; move time rather than sleep.
local _real_time = os.time
local function at_time(t, fn)
    os.time = function() return t end
    local ok, err = pcall(fn)
    os.time = _real_time
    if not ok then error(err, 0) end
end

test("bimGetBookInfo is exported", function()
    -- The widget's own BIM reads route through this; a missing export would
    -- only show up as a runtime nil call on a device.
    assert(type(Repo.bimGetBookInfo) == "function", "Repo.bimGetBookInfo missing")
end)

test("a poisoned handle is reset and the read retried", function()
    local bim = poisoned_bim()
    at_time(1000, function()
        local info, err = Repo.bimGetBookInfo(bim, "/lib/a.epub", false)
        assert(info and info.title == "recovered", "read did not recover")
        assert(err == nil, "no error should be reported after recovery")
    end)
    assert(bim.closes == 1, "expected exactly one reset, got " .. bim.closes)
    assert(bim.reads == 2, "expected one failed read and one retry, got " .. bim.reads)
end)

test("a healthy read never touches the connection", function()
    local bim = poisoned_bim()
    bim.db_conn = nil               -- reads succeed
    at_time(2000, function()
        local info, err = Repo.bimGetBookInfo(bim, "/lib/a.epub", false)
        assert(info and info.title == "recovered")
        assert(err == nil)
    end)
    assert(bim.closes == 0, "a successful read must not reset anything")
end)

test("resets are rate-limited: a dead DB is not reset per book", function()
    -- The case this guards: the volume is full, so the reopen fails too. One
    -- reset per cooldown; the rest of the page reports failure without
    -- hammering SQLite on the slowest device we run on.
    local bim = poisoned_bim({ heals = false })
    at_time(3000, function()
        for _i = 1, 25 do Repo.bimGetBookInfo(bim, "/lib/a.epub", false) end
    end)
    assert(bim.closes == 1, "expected 1 reset inside the window, got " .. bim.closes)
    -- Past the cooldown, it is allowed to try again: the disk may have been
    -- freed up, and the alternative is a session that never recovers.
    at_time(3000 + 60, function() Repo.bimGetBookInfo(bim, "/lib/a.epub", false) end)
    assert(bim.closes == 2, "expected a second reset after the cooldown, got " .. bim.closes)
end)

test("a failed read reports the error rather than a missing row", function()
    -- Callers distinguish these: "BIM has no row" queues an extraction,
    -- "BIM is not answering" must not.
    local bim = poisoned_bim({ heals = false })
    at_time(5000, function()
        local info, err = Repo.bimGetBookInfo(bim, "/lib/a.epub", false)
        assert(info == nil, "no info on failure")
        assert(type(err) == "string" and err:find("closed"), "error text passed back")
    end)
end)

test("closeDbConnection raising still clears the handle", function()
    -- ljsqlite3 close() raises on an already-closed connection, and BIM nils
    -- db_conn only after close() returns -- so the reset has to clear it
    -- itself or openDbConnection keeps taking its early return forever.
    local bim = poisoned_bim({ close_raises = true })
    at_time(7000, function() Repo.bimGetBookInfo(bim, "/lib/a.epub", false) end)
    assert(bim.db_conn == nil, "db_conn must be cleared even when close() throws")
end)

test("getCoverBB returns nil (not a crash) while BIM is unhealthy", function()
    -- The device symptom: the shelf keeps painting cached covers while every
    -- fresh decode fails. It must degrade, not throw.
    local original = package.loaded["bookinfomanager"]
    package.loaded["bookinfomanager"] = {
        getBookInfo = function() error("ljsqlite3[misuse] object is closed", 0) end,
        closeDbConnection = function() end,
    }
    Repo.invalidateWalkCache()
    local ok, bb = pcall(Repo.getCoverBB, "/lib/a.epub")
    package.loaded["bookinfomanager"] = original
    Repo.invalidateWalkCache()
    assert(ok, "getCoverBB must not propagate a BIM error")
    assert(bb == nil, "no cover to return")
end)

-- ── Home folders as shelf sections ──────────────────────────────────────────

test("getFolderSections: books arrive in tree order, tagged with their folder", function()
    Repo.invalidateWalkCache()
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files
        if path == "/lib" then
            files = { ".", "..", "loose.epub", "Culture", "Discworld" }
        elseif path == "/lib/Culture" then
            files = { ".", "..", "c1.epub", "c2.epub" }
        elseif path == "/lib/Discworld" then
            files = { ".", "..", "d1.epub", "Witches" }
        elseif path == "/lib/Discworld/Witches" then
            files = { ".", "..", "w1.epub", "w2.epub" }
        else files = {} end
        local i = 0
        return function() i = i + 1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(fp, key)
        local dirs = {
            ["/lib/Culture"] = true, ["/lib/Discworld"] = true,
            ["/lib/Discworld/Witches"] = true,
        }
        if key == "modification" then return 100
        elseif key == "mode" then return dirs[fp] and "directory" or "file" end
    end
    -- Mixed ON, so the sections stand in plain tree order. With it off they
    -- are partitioned instead, which the block at the end of this test
    -- covers -- getAll does the same for the tree view.
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 3,
                          collate_mixed = true }
    _G._test_bim_data = {
        ["/lib/loose.epub"]                = { title = "Loose" },
        ["/lib/Culture/c1.epub"]           = { title = "C One" },
        ["/lib/Culture/c2.epub"]           = { title = "C Two" },
        ["/lib/Discworld/d1.epub"]         = { title = "D One" },
        ["/lib/Discworld/Witches/w1.epub"] = { title = "W One" },
        ["/lib/Discworld/Witches/w2.epub"] = { title = "W Two" },
    }
    local out, total = Repo.getFolderSections(20, 0)
    -- BOOKS are the items, not sections: the spine cursor counts items, so
    -- a folder bigger than a page would otherwise be unpageable.
    assert(total == 6, "six books expected, got " .. tostring(total))
    assert(#out == 6, "all six in the window, got " .. #out)
    -- Tree order: the root's loose books, then each folder's own books
    -- before its children's.
    local order = {}
    for i = 1, #out do order[i] = out[i].filepath end
    assert(order[1] == "/lib/loose.epub", "got " .. tostring(order[1]))
    assert(order[2] == "/lib/Culture/c1.epub", "got " .. tostring(order[2]))
    assert(order[4] == "/lib/Discworld/d1.epub", "got " .. tostring(order[4]))
    assert(order[5] == "/lib/Discworld/Witches/w1.epub", "got " .. tostring(order[5]))
    -- The tag is what the shelf badges a run with. Books loose at the root
    -- carry none: a badge naming the home directory would say nothing.
    assert(out[1].shelf_section == nil, "the root run carries no label")
    assert(out[2].shelf_section == "Culture", "got " .. tostring(out[2].shelf_section))
    assert(out[4].shelf_section == "Discworld", "got " .. tostring(out[4].shelf_section))

    -- ...and with "folders and files mixed" OFF, the same partition the tree
    -- view gets: every folder before the root's own loose books. Without it
    -- the spine shelf put the newest root book ahead of everything while
    -- cover and list mode showed folders first from the same settings.
    _G._test_settings.collate_mixed = false
    Repo.invalidateWalkCache()
    local part = Repo.getFolderSections(20, 0)
    local porder = {}
    for i = 1, #part do porder[i] = part[i].filepath end
    assert(porder[1] == "/lib/Culture/c1.epub", "got " .. tostring(porder[1]))
    assert(porder[#porder] == "/lib/loose.epub",
        "the root's loose book should come last, got " .. tostring(porder[#porder]))
    -- the folders keep their own tree order between themselves
    assert(porder[3] == "/lib/Discworld/d1.epub", "got " .. tostring(porder[3]))
    _G._test_settings.collate_mixed = true
    assert(out[5].shelf_section == "Witches", "got " .. tostring(out[5].shelf_section))
    assert(out[2].shelf_section_path == "/lib/Culture",
        "got " .. tostring(out[2].shelf_section_path))
end)

test("getFolderSections: the window slices books, so a big folder still pages", function()
    Repo.invalidateWalkCache()
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files
        if path == "/lib" then files = { ".", "..", "Big" }
        elseif path == "/lib/Big" then
            files = { ".", ".." }
            for i = 1, 10 do files[#files + 1] = string.format("b%02d.epub", i) end
        else files = {} end
        local i = 0
        return function() i = i + 1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(fp, key)
        if key == "modification" then return 100
        elseif key == "mode" then return fp == "/lib/Big" and "directory" or "file" end
    end
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 3 }
    _G._test_bim_data = {}
    for i = 1, 10 do
        _G._test_bim_data[string.format("/lib/Big/b%02d.epub", i)] =
            { title = string.format("B%02d", i) }
    end
    local page1, total = Repo.getFolderSections(4, 0)
    assert(total == 10, "ten books, got " .. tostring(total))
    assert(#page1 == 4, "a window of four, got " .. #page1)
    local page2 = Repo.getFolderSections(4, 4)
    assert(#page2 == 4, "the next four, got " .. #page2)
    assert(page1[1].filepath ~= page2[1].filepath, "the window must advance")
    -- Every book still knows its section, so the badge repeats on the next
    -- shelf rather than the run vanishing at a page break.
    assert(page2[1].shelf_section == "Big", "got " .. tostring(page2[1].shelf_section))
end)

test("getFolderSections: a one-book folder folds into its parent's run", function()
    Repo.invalidateWalkCache()
    -- The Calibre shape: Author/Title/book.epub. Without the fold every book
    -- would badge itself with its own title.
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files
        if path == "/lib" then files = { ".", "..", "Banks" }
        elseif path == "/lib/Banks" then files = { ".", "..", "Excession", "Inversions" }
        elseif path == "/lib/Banks/Excession" then files = { ".", "..", "ex.epub" }
        elseif path == "/lib/Banks/Inversions" then files = { ".", "..", "in.epub" }
        else files = {} end
        local i = 0
        return function() i = i + 1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(fp, key)
        local dirs = {
            ["/lib/Banks"] = true, ["/lib/Banks/Excession"] = true,
            ["/lib/Banks/Inversions"] = true,
        }
        if key == "modification" then return 100
        elseif key == "mode" then return dirs[fp] and "directory" or "file" end
    end
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 3 }
    _G._test_bim_data = {
        ["/lib/Banks/Excession/ex.epub"]  = { title = "Excession" },
        ["/lib/Banks/Inversions/in.epub"] = { title = "Inversions" },
    }
    local out, total = Repo.getFolderSections(20, 0)
    assert(total == 2, "two books, got " .. tostring(total))
    assert(out[1].shelf_section == "Banks", "got " .. tostring(out[1].shelf_section))
    assert(out[2].shelf_section == "Banks", "got " .. tostring(out[2].shelf_section))
end)

test("allHasBooks: the whole cached set of a path, nil when nothing is cached", function()
    -- The shelf asks this after a windowed fetch whose page showed folders
    -- only: does the SET hold a book anywhere, so the label strip is decided
    -- per chip rather than per page. Home holds two folders and no loose
    -- book; each folder holds one.
    Repo.invalidateWalkCache()
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 1 }
    package.loaded["libs/libkoreader-lfs"].dir = function(p)
        local listings = {
            ["/lib"]         = { ".", "..", "Culture", "Expanse" },
            ["/lib/Culture"] = { ".", "..", "cp.epub" },
            ["/lib/Expanse"] = { ".", "..", "lw.epub" },
        }
        local files = listings[p] or {}
        local i = 0
        return function() i = i + 1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(fp, key)
        local modes = {
            ["/lib"] = "directory", ["/lib/Culture"] = "directory", ["/lib/Expanse"] = "directory",
            ["/lib/Culture/cp.epub"] = "file", ["/lib/Expanse/lw.epub"] = "file",
        }
        if key == "mode"         then return modes[fp] end
        if key == "size"         then return 100 end
        if key == "modification" then return 0 end
        if not key and modes[fp] then return { mode = modes[fp], size = 100, modification = 0 } end
    end
    _G._test_bim_data = {
        ["/lib/Culture/cp.epub"] = { title = "Consider Phlebas" },
        ["/lib/Expanse/lw.epub"] = { title = "Leviathan Wakes" },
    }
    assert(Repo.allHasBooks(nil) == nil, "nothing cached yet must answer nil")
    local _items, total = Repo.getAll(nil, 10, 0)
    assert(total == 2, "two folders at the root, got " .. tostring(total))
    assert(Repo.allHasBooks(nil) == false, "the root set is folders only")
    Repo.getAll("/lib/Culture", 10, 0)
    assert(Repo.allHasBooks("/lib/Culture") == true, "the folder holds a book")
    assert(Repo.allHasBooks("/lib/Nowhere") == nil, "an unwalked path is unknown")
end)

-- ============================================================================
-- Shape cache LRU cap: _all_cache / _bySource_cache / _meta_record_cache
-- (2026-09-16 memory inventory: all three had no size bound)
-- ============================================================================

test("_shapeCachePut: filling _all_cache with 60 keys keeps exactly the last 48", function()
    Repo.invalidateWalkCache()
    for i = 1, 60 do
        Repo._shapeCachePut("all", "k" .. i, { i = i })
    end
    local counts = Repo._shapeCacheCounts()
    assert(counts.all == 48, "expected 48 entries, got " .. tostring(counts.all))
    for i = 1, 12 do
        assert(Repo._shapeCacheGet("all", "k" .. i) == nil,
            "k" .. i .. " should have been evicted")
    end
    for i = 13, 60 do
        assert(Repo._shapeCacheGet("all", "k" .. i) ~= nil,
            "k" .. i .. " should still be cached")
    end
end)

test("_shapeCachePut: re-inserting an existing key refreshes it instead of growing the cache", function()
    Repo.invalidateWalkCache()
    for i = 1, 48 do
        Repo._shapeCachePut("all", "n" .. i, i)
    end
    assert(Repo._shapeCacheCounts().all == 48, "expected 48 after the initial fill")

    -- Re-insert key n1: must not grow the cache, and must move n1 to the
    -- newest position.
    local was_new = Repo._shapeCachePut("all", "n1", "refreshed")
    assert(was_new == false, "n1 already existed, expected a refill (was_new=false)")
    assert(Repo._shapeCacheCounts().all == 48, "a refill must not grow the count")

    -- A 49th distinct key: with n1 refreshed to newest, n2 is now the
    -- oldest and must be the one evicted, not n1.
    Repo._shapeCachePut("all", "n49", 49)
    assert(Repo._shapeCacheCounts().all == 48, "cap must still hold after the 49th insert")
    assert(Repo._shapeCacheGet("all", "n1") ~= nil,
        "n1 was refreshed and should have survived")
    assert(Repo._shapeCacheGet("all", "n2") == nil,
        "n2 was the oldest after the refill and should have been evicted")
end)

test("_shapeCachePut: same 48-entry cap applies to _bySource_cache", function()
    Repo.invalidateWalkCache()
    for i = 1, 60 do
        Repo._shapeCachePut("by_source", "s" .. i, { "fp" .. i })
    end
    local counts = Repo._shapeCacheCounts()
    assert(counts.by_source == 48, "expected 48 entries, got " .. tostring(counts.by_source))
    for i = 1, 12 do
        assert(Repo._shapeCacheGet("by_source", "s" .. i) == nil,
            "s" .. i .. " should have been evicted")
    end
    for i = 13, 60 do
        assert(Repo._shapeCacheGet("by_source", "s" .. i) ~= nil,
            "s" .. i .. " should still be cached")
    end
end)

test("invalidateWalkCache clears _meta_record_cache; invalidateBookCache keeps it", function()
    local fp = "/meta-cache-clear.epub"
    _G._test_settings = {}
    _G._test_docsettings_data = nil
    _G._test_bim_data = {
        [fp] = { has_meta = "Y", title = "Sticky Title", authors = "Sticky Author" },
    }
    Repo.buildBookMeta(fp)
    assert(Repo._shapeCacheCounts().meta > 0,
        "expected the sticky record to be cached after buildBookMeta")

    Repo.invalidateWalkCache()
    assert(Repo._shapeCacheCounts().meta == 0,
        "invalidateWalkCache must clear _meta_record_cache")

    Repo.buildBookMeta(fp)
    assert(Repo._shapeCacheCounts().meta > 0,
        "expected the sticky record to be cached again")

    -- The memo exists to mask BIM's transient wipe of a record DURING a
    -- re-extraction, and "refresh-metadata" / "scanAllMetadata" reach
    -- invalidateBookCache at exactly that moment - clearing it there would
    -- flicker the spine to fallback rendering in the very window it guards.
    Repo.invalidateBookCache("test")
    assert(Repo._shapeCacheCounts().meta > 0,
        "invalidateBookCache must keep the last-good records for the refresh cycle")
end)

-- ============================================================================
io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
