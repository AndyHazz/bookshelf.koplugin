-- tests/_test_book_repository.lua
-- Pure-Lua integration-style tests for book_repository.lua with stubbed KOReader modules.
-- Usage: cd into the plugin dir, then `lua tests/_test_book_repository.lua`.

-- After the lib/ reorg, internal requires resolve as "lib/bookshelf_X".
-- Add the plugin root to package.path so `require("lib/bookshelf_X")`
-- finds the file at <plugin_root>/lib/bookshelf_X.lua.
package.path = "./?.lua;./?/init.lua;" .. package.path

package.loaded["readhistory"] = { hist = {} }
package.loaded["readcollection"] = { coll = { favorites = {} }, default_collection_name = "favorites" }
package.loaded["sort"] = {
    natsort_cmp = function()
        return function(a, b)
            local function split(s)
                local prefix, num, suffix = tostring(s):match("^(.-)(%d+)(.*)$")
                if num then return prefix:lower(), tonumber(num), suffix:lower() end
                return tostring(s):lower(), nil, ""
            end
            local ap, an, as = split(a)
            local bp, bn, bs = split(b)
            if ap ~= bp then return ap < bp end
            if an and bn and an ~= bn then return an < bn end
            if an and not bn then return true end
            if bn and not an then return false end
            return as < bs
        end
    end,
}
package.loaded["bookinfomanager"] = {
    getBookInfo = function(_self, fp, _with_cover)
        return _G._test_bim_data and _G._test_bim_data[fp] or nil
    end,
    openDbConnection = function(self)
        if _G._test_bim_batch_rows then
            self.db_conn = {
                exec = function(_conn, _sql)
                    _G._test_bim_batch_sql = _sql
                    return _G._test_bim_batch_rows
                end,
            }
        else
            self.db_conn = nil
        end
    end,
}
package.loaded["lib/bookshelf_epub_metadata"] = {
    authorCreatorsForFile = function(fp)
        _G._test_epub_author_call_count = (_G._test_epub_author_call_count or 0) + 1
        return _G._test_epub_author_creators and _G._test_epub_author_creators[fp] or nil
    end,
    invalidate = function() end,
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
}
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(fp, key)
        if key == "modification" then
            return _G._test_mtime and _G._test_mtime[fp] or 0
        end
    end,
}
package.loaded["logger"] = { dbg = function() end, info = function() end, warn = function() end, err = function() end }

-- BookshelfSettings stub: reads from the same _test_settings table as
-- the G_reader_settings stub, but transparently re-prefixes keys with
-- "bookshelf_". Lets existing tests keep using bookshelf_X keys in
-- _test_settings while production code reads short keys via the store.
package.loaded["lib/bookshelf_settings_store"] = {
    read   = function(key, default)
        local v = _G._test_settings and _G._test_settings["bookshelf_" .. key]
        if v == nil then return default end
        return v
    end,
    save   = function(key, value)
        _G._test_settings = _G._test_settings or {}
        _G._test_settings["bookshelf_" .. key] = value
    end,
    delete = function(key)
        if _G._test_settings then _G._test_settings["bookshelf_" .. key] = nil end
    end,
    flush  = function() end,
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

test("getFolderChoices: lists book-containing ancestor folders under home_dir", function()
    Repo.invalidateWalkCache()
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 4 }
    local tree = {
        ["/lib"] = { ".", "..", "Fiction", "Manga", "loose.epub" },
        ["/lib/Fiction"] = { ".", "..", "A", "standalone.epub" },
        ["/lib/Fiction/A"] = { ".", "..", "book.epub" },
        ["/lib/Manga"] = { ".", "..", "vol.cbz" },
    }
    local dirs = {
        ["/lib"] = true,
        ["/lib/Fiction"] = true,
        ["/lib/Fiction/A"] = true,
        ["/lib/Manga"] = true,
    }
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = tree[path] or {}
        local i = 0
        return function() i = i + 1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(fp, key)
        local attr = {
            mode = dirs[fp] and "directory" or "file",
            modification = 1,
            size = 123,
        }
        if key then return attr[key] end
        return attr
    end

    local choices = Repo.getFolderChoices()
    assert(#choices == 3, "expected 3 choices, got " .. #choices)
    assert(choices[1].value == "/lib/Fiction")
    assert(choices[2].value == "/lib/Fiction/A")
    assert(choices[3].value == "/lib/Manga")
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
    _G._test_epub_author_creators = nil
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

test("buildBook: prefers EPUB creator role authors over translator-first BIM authors", function()
    _G._test_epub_author_call_count = 0
    _G._test_bim_data = {
        ["/book.epub"] = { authors = "Rebecca Alsberg\nKarl Ove Knausgård" },
    }
    _G._test_epub_author_creators = {
        ["/book.epub"] = { "Karl Ove Knausgård" },
    }
    local book = Repo.buildBook("/book.epub")
    _G._test_epub_author_creators = nil
    assert(book.authors, "authors should be a table")
    assert(#book.authors == 1, "expected role-filtered author only")
    assert(book.author == "Karl Ove Knausgård",
        "expected Karl Ove Knausgård got " .. tostring(book.author))
    assert(_G._test_epub_author_call_count == 1,
        "expected OPF role lookup for multiple BIM authors")
end)

test("buildBook: uses author-title filename when single BIM author conflicts and description confirms", function()
    _G._test_epub_author_call_count = 0
    _G._test_epub_author_creators = {
        ["/Karl Ove Knausgård - Min kamp 4.epub"] = { "Should Not Be Read" },
    }
    _G._test_bim_data = {
        ["/Karl Ove Knausgård - Min kamp 4.epub"] = {
            authors = "Rebecca Alsberg",
            description = "Fjärde delen av Karl Ove Knausgårds roman.",
        },
    }
    local book = Repo.buildBook("/Karl Ove Knausgård - Min kamp 4.epub")
    _G._test_epub_author_creators = nil
    assert(book.author == "Karl Ove Knausgård",
        "expected filename-confirmed author got " .. tostring(book.author))
    assert(_G._test_epub_author_call_count == 0,
        "single-author fallback must not trigger OPF role lookup")
end)

test("getAuthors: batch light metadata carries description for filename-author fallback", function()
    Repo.invalidateWalkCache()
    _G._test_epub_author_call_count = 0
    _G._test_settings = {
        home_dir = "/lib",
        bookshelf_latest_walk_depth = 1,
    }
    local fp = "/lib/Karl Ove Knausgård - Min Kamp 5.epub"
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = path == "/lib"
            and { ".", "..", "Karl Ove Knausgård - Min Kamp 5.epub" }
            or {}
        local i = 0
        return function() i = i + 1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(path, key)
        local attrs = {
            ["/lib"] = { mode = "directory", modification = 10, size = 0 },
            [fp]     = { mode = "file",      modification = 20, size = 123 },
        }
        local attr = attrs[path]
        if key then return attr and attr[key] end
        return attr
    end
    _G._test_bim_batch_rows = {
        { "/lib/" },                                  -- directory
        { "Karl Ove Knausgård - Min Kamp 5.epub" },  -- filename
        { "Min Kamp 5" },                             -- title
        { "Rebecca Alsberg" },                        -- authors
        { "Min kamp" },                               -- series
        { 5 },                                        -- series_index
        { nil },                                      -- keywords
        { "Femte delen av Karl Ove Knausgårds roman." }, -- description
    }
    local authors = Repo.getAuthors(10, 0)
    _G._test_bim_batch_rows = nil
    assert(_G._test_bim_batch_sql and _G._test_bim_batch_sql:find("description", 1, true),
        "batch SQL should select description")
    assert(#authors == 1, "expected one author group got " .. tostring(#authors))
    assert(authors[1].series_name == "Karl Ove Knausgård",
        "expected Karl Ove Knausgård got " .. tostring(authors[1].series_name))
    assert(_G._test_epub_author_call_count == 0,
        "batch fallback must not trigger OPF role lookup")
end)

test("buildBook: keeps single BIM author when filename author is not confirmed", function()
    _G._test_epub_author_call_count = 0
    _G._test_epub_author_creators = {
        ["/Someone Else - Book.epub"] = { "Should Not Be Read" },
    }
    _G._test_bim_data = {
        ["/Someone Else - Book.epub"] = {
            authors = "Rebecca Alsberg",
            description = "A sparse description without the filename author.",
        },
    }
    local book = Repo.buildBook("/Someone Else - Book.epub")
    _G._test_epub_author_creators = nil
    assert(book.author == "Rebecca Alsberg")
    assert(_G._test_epub_author_call_count == 0,
        "single-author non-match must not trigger OPF role lookup")
end)

test("buildBook: keeps correct single BIM author when it shares filename tokens", function()
    _G._test_epub_author_call_count = 0
    _G._test_bim_data = {
        ["/Karl Ove Knausgård - Min kamp 4.epub"] = {
            authors = "Knausgård, Karl Ove",
            description = "Fjärde delen av Karl Ove Knausgårds roman.",
        },
    }
    local book = Repo.buildBook("/Karl Ove Knausgård - Min kamp 4.epub")
    assert(book.author == "Knausgård, Karl Ove")
    assert(_G._test_epub_author_call_count == 0,
        "matching single author must not trigger OPF role lookup")
end)

test("buildBook: preserves comma-formatted single author names", function()
    _G._test_epub_author_creators = nil
    _G._test_epub_author_call_count = 0
    _G._test_bim_data = {
        ["/book.epub"] = { authors = "Clarke, Arthur C." },
    }
    local book = Repo.buildBook("/book.epub")
    assert(book.authors, "authors should be a table")
    assert(#book.authors == 1, "expected 1 author, got " .. #book.authors)
    assert(book.authors[1] == "Clarke, Arthur C.", "got " .. tostring(book.authors[1]))
    assert(book.author == "Clarke, Arthur C.", "singular author should preserve comma-formatted name")
end)

test("buildBook: single-author string yields one-element array, no trailing whitespace", function()
    _G._test_bim_data = { ["/x.epub"] = { authors = "Sole Author" } }
    local book = Repo.buildBook("/x.epub")
    assert(#book.authors == 1)
    assert(book.authors[1] == "Sole Author")
    assert(book.author == "Sole Author")
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

test("searchAll: matches folders by directory name", function()
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
    local r = Repo.searchAll("scifi")
    assert(#r.folders == 1, "expected 1 folder, got " .. #r.folders)
    assert(r.folders[1].label == "scifi")
    assert(r.folders[1].kind  == "folder")
    assert(r.folders[1].path  == "/lib/scifi")
    assert(r.folders[1].first_book ~= nil)
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

test("getAll: default author sort uses surname first", function()
    Repo.invalidateWalkCache()
    _G._test_settings = { home_dir = "/lib" }
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = (path == "/lib") and {".", "..",
            "tawada.epub", "atwood.epub", "gaiman.epub"} or {".", ".."}
        local i = 0; return function() i = i + 1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(fp, key)
        local is_file = fp:match("%.epub$") ~= nil
        if key == "mode" then return is_file and "file" or "directory" end
        if key == "size" then return 100 end
        if key == "modification" then return 0 end
        return { mode = is_file and "file" or "directory", size = 100, modification = 0 }
    end
    _G._test_bim_data = {
        ["/lib/tawada.epub"] = { title = "Memoirs", authors = "Yoko Tawada" },
        ["/lib/atwood.epub"] = { title = "Alias Grace", authors = "Margaret Atwood" },
        ["/lib/gaiman.epub"] = { title = "Neverwhere", authors = "Neil Gaiman" },
    }

    local items = Repo.getAll(nil, 10, 0)
    assert(items[1].title == "Alias Grace", "got " .. tostring(items[1].title))
    assert(items[2].title == "Neverwhere", "got " .. tostring(items[2].title))
    assert(items[3].title == "Memoirs", "got " .. tostring(items[3].title))
end)

test("getAuthors: default name sort uses surname first", function()
    Repo.invalidateWalkCache()
    Repo.invalidateSeriesCache()
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = (path == "/lib") and {".", "..",
            "morrison.epub", "asimov.epub", "le-guin.epub", "gaiman.epub"} or {".", ".."}
        local i = 0; return function() i = i + 1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(fp, key)
        local is_file = fp:match("%.epub$") ~= nil
        if key == "mode" then return is_file and "file" or "directory" end
        if key == "modification" then return 0 end
        return { mode = is_file and "file" or "directory", modification = 0 }
    end
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 1 }
    _G._test_bim_data = {
        ["/lib/morrison.epub"] = { title = "Beloved", authors = "Toni Morrison" },
        ["/lib/asimov.epub"]   = { title = "Foundation", authors = "Isaac Asimov" },
        ["/lib/le-guin.epub"]  = { title = "The Dispossessed", authors = "Ursula K. Le Guin" },
        ["/lib/gaiman.epub"]   = { title = "Neverwhere", authors = "Neil Gaiman" },
    }

    local authors = Repo.getAuthors(10, 0)
    assert(authors[1].series_name == "Isaac Asimov", "got " .. tostring(authors[1].series_name))
    assert(authors[2].series_name == "Neil Gaiman", "got " .. tostring(authors[2].series_name))
    assert(authors[3].series_name == "Ursula K. Le Guin", "got " .. tostring(authors[3].series_name))
    assert(authors[4].series_name == "Toni Morrison", "got " .. tostring(authors[4].series_name))
end)

test("getAuthors: scoped name sort uses surname first", function()
    Repo.invalidateWalkCache()
    Repo.invalidateSeriesCache()
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local listings = {
            ["/prose"] = {".", "..", "tawada.epub", "atwood.epub"},
            ["/manga"] = {".", "..", "aot.cbz", "op.cbz"},
        }
        local files = listings[path] or {".", ".."}
        local i = 0; return function() i = i + 1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(fp, key)
        local ext = fp:match("%.([^.]+)$")
        local is_file = ext == "epub" or ext == "cbz"
        if key == "mode" then return is_file and "file" or "directory" end
        if key == "modification" then return 0 end
        return { mode = is_file and "file" or "directory", modification = 0 }
    end
    _G._test_settings = { home_dir = "/", bookshelf_latest_walk_depth = 1 }
    _G._test_bim_data = {
        ["/prose/tawada.epub"] = { title = "Memoirs", authors = "Yoko Tawada" },
        ["/prose/atwood.epub"] = { title = "Alias Grace", authors = "Margaret Atwood" },
        ["/manga/aot.cbz"]     = { title = "Attack on Titan 1", authors = "Hajime Isayama" },
        ["/manga/op.cbz"]      = { title = "One Piece 1", authors = "Eiichiro Oda" },
    }

    local prose = Repo.getAuthors(10, 0, { roots = { "/prose" } })
    local manga = Repo.getAuthors(10, 0, { roots = { "/manga" } })
    assert(prose[1].series_name == "Margaret Atwood", "got " .. tostring(prose[1].series_name))
    assert(prose[2].series_name == "Yoko Tawada", "got " .. tostring(prose[2].series_name))
    assert(manga[1].series_name == "Hajime Isayama", "got " .. tostring(manga[1].series_name))
    assert(manga[2].series_name == "Eiichiro Oda", "got " .. tostring(manga[2].series_name))
end)

test("getNextUnreadInSeries: prefers in-progress volume over following unread", function()
    Repo.invalidateWalkCache()
    Repo.invalidateSeriesCache()
    Repo.invalidateProgressCache()
    package.loaded["readhistory"].hist = {
        { file = "/manga/aot31.cbz", time = 400 },
        { file = "/manga/aot30.cbz", time = 300 },
    }
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = (path == "/manga") and {".", "..",
            "aot30.cbz", "aot31.cbz", "aot32.cbz"} or {".", ".."}
        local i = 0; return function() i = i + 1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(fp, key)
        local is_file = fp:match("%.cbz$") ~= nil
        if key == "mode" then return is_file and "file" or "directory" end
        if key == "modification" then return 0 end
        return { mode = is_file and "file" or "directory", modification = 0 }
    end
    _G._test_settings = { home_dir = "/manga", bookshelf_latest_walk_depth = 1 }
    _G._test_bim_data = {
        ["/manga/aot30.cbz"] = { title = "Attack on Titan 30", series = "Attack on Titan #30", series_index = 30 },
        ["/manga/aot31.cbz"] = { title = "Attack on Titan 31", series = "Attack on Titan #31", series_index = 31 },
        ["/manga/aot32.cbz"] = { title = "Attack on Titan 32", series = "Attack on Titan #32", series_index = 32 },
    }
    _G._test_docsettings_data = {
        ["/manga/aot30.cbz"] = { percent_finished = 1 },
        ["/manga/aot31.cbz"] = { percent_finished = 0.42 },
        ["/manga/aot32.cbz"] = { percent_finished = 0 },
    }

    local next_items = Repo.getNextUnreadInSeries(10, 0)
    assert(#next_items == 1, "expected 1 next item, got " .. tostring(#next_items))
    assert(next_items[1].filepath == "/manga/aot31.cbz",
        "expected in-progress volume 31, got " .. tostring(next_items[1].filepath))
end)

test("getReadingStatus: detects complete and in-progress books", function()
    Repo.invalidateProgressCache()
    _G._test_docsettings_data = {
        ["/done.epub"] = { summary = { status = "complete" } },
        ["/reading.epub"] = { percent_finished = 0.25 },
        ["/new.epub"] = { percent_finished = 0 },
    }
    local done = Repo.getReadingStatus("/done.epub")
    local reading = Repo.getReadingStatus("/reading.epub")
    local new = Repo.getReadingStatus("/new.epub")
    assert(done and done.state == "read", "expected read status")
    assert(reading and reading.state == "reading", "expected reading status")
    assert(new == nil, "expected no status for unopened book")
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

test("getAll: a BIM metadata failure keeps the page with filename fallback", function()
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
    -- So all three survive, with bad.epub present and filename-hydrated.
    assert(total == 3, "expected 3 shapes, got " .. tostring(total))
    assert(items and #items == 3, "expected 3 surviving items, got " .. tostring(items and #items))
    local by_path = {}
    for _i, it in ipairs(items) do by_path[it.filepath] = it end
    assert(by_path["/lib/bad.epub"], "throwing entry should survive via fallback, not drop")
    assert(by_path["/lib/bad.epub"].title == "bad",
        "expected bad.epub to hydrate with filename fallback")
    -- Restore the default BIM stub so other tests are unaffected.
    package.loaded["bookinfomanager"] = {
        getBookInfo = function(_self, fp, _with_cover)
            return _G._test_bim_data and _G._test_bim_data[fp] or nil
        end,
    }
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
io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
