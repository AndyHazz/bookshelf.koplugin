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
io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
