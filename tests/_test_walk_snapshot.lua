
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


-- ── the bit this suite is actually about ────────────────────────────────────
-- A fake Persist, so the walk snapshot can be written by one module instance
-- and read by the next. Repo is loaded with dofile(), so re-loading it gives a
-- fresh module with an empty in-memory walk cache: that IS a restart, which is
-- the only condition under which the snapshot does anything.
local disk = { data = nil, saves = 0, loads = 0, deletes = 0 }
package.loaded["persist"] = {
    new = function(_self, _opts)
        return {
            load   = function() disk.loads = disk.loads + 1; return disk.data end,
            save   = function(_s, t) disk.saves = disk.saves + 1; disk.data = t; return true end,
            delete = function() disk.deletes = disk.deletes + 1; disk.data = nil; return true end,
        }
    end,
}
-- The hardcover cache fake installs a datastorage with only getSettingsDir;
-- the snapshot path needs getDataDir too.
package.loaded["datastorage"] = {
    getDataDir     = function() return "/tmp/bookshelf-walk-test" end,
    getSettingsDir = function() return "/tmp/bookshelf-walk-test" end,
}

local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()

-- One tree, one mtime table, and a counter for how many directories the walk
-- actually reads. That counter is the whole point: a snapshot that is accepted
-- must read NO directories.
local tree, mtimes, dir_reads

local function setTree(files)
    tree = files
    dir_reads = 0
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        dir_reads = dir_reads + 1
        local names = tree[path] or {}
        local i = 0
        return function() i = i + 1; return names[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(fp, key)
        if key == "modification" then return mtimes[fp] or 0 end
        if key == "mode" then return tree[fp] and "directory" or "file" end
        return nil
    end
end

local function freshRepo()
    -- A restart: new module state, same fake disk.
    return dofile("lib/bookshelf_book_repository.lua")
end

local function setup()
    disk.data, disk.saves, disk.loads, disk.deletes = nil, 0, 0, 0
    mtimes = { ["/home"] = 10, ["/home/sub"] = 20,
               ["/home/a.epub"] = 100, ["/home/sub/b.epub"] = 200 }
    setTree({
        ["/home"]     = { ".", "..", "a.epub", "sub" },
        ["/home/sub"] = { ".", "..", "b.epub" },
    })
    _G._test_settings = { home_dir = "/home", bookshelf_latest_walk_depth = 3 }
    _G._test_bim_data = {
        ["/home/a.epub"]     = { title = "A" },
        ["/home/sub/b.epub"] = { title = "B" },
    }
end

t.test("a fresh walk writes a snapshot", function()
    setup()
    local Repo = freshRepo()
    assert(#Repo.getLatest(10) == 2, "fixture did not walk")
    assert(disk.saves == 1, "the walk was not persisted, saves=" .. disk.saves)
    assert(dir_reads > 0, "nothing was read; the fixture is not exercising the walk")
end)

t.test("a restart reuses the snapshot instead of walking", function()
    setup()
    freshRepo().getLatest(10)          -- populate
    local before = disk.saves
    dir_reads = 0
    local Repo2 = freshRepo()           -- restart
    local out = Repo2.getLatest(10)
    assert(#out == 2, "the snapshot lost books: got " .. #out)
    -- The saving IS the directories not read. Anything else is decoration.
    assert(dir_reads == 0, "walked anyway, read " .. dir_reads .. " directories")
    assert(disk.saves == before, "an accepted snapshot was rewritten")
end)

t.test("a changed directory makes the restart walk again", function()
    setup()
    freshRepo().getLatest(10)
    -- A new book bumps its directory's mtime. This is the ONLY thing standing
    -- between a stale snapshot and a shelf that cannot see new books.
    tree["/home"] = { ".", "..", "a.epub", "sub", "c.epub" }
    mtimes["/home"] = 11
    mtimes["/home/c.epub"] = 300
    _G._test_bim_data["/home/c.epub"] = { title = "C" }
    dir_reads = 0
    local out = freshRepo().getLatest(10)
    assert(dir_reads > 0, "a changed library was served from a stale snapshot")
    assert(#out == 3, "the new book never appeared: got " .. #out)
end)

t.test("a deleted book is noticed too", function()
    setup()
    freshRepo().getLatest(10)
    tree["/home/sub"] = { ".", ".." }
    mtimes["/home/sub"] = 21
    dir_reads = 0
    local out = freshRepo().getLatest(10)
    assert(dir_reads > 0, "a deletion was served from a stale snapshot")
    assert(#out == 1, "the removed book is still listed: got " .. #out)
end)

t.test("a snapshot from a different library is not used", function()
    setup()
    freshRepo().getLatest(10)
    -- home_dir is part of the key. Serving one library's walk for another
    -- would show the wrong books entirely.
    disk.data.key = "/somewhere/else:3"
    dir_reads = 0
    freshRepo().getLatest(10)
    assert(dir_reads > 0, "a snapshot for another home_dir was accepted")
end)

t.test("a snapshot from an older format is not used", function()
    setup()
    freshRepo().getLatest(10)
    disk.data.version = 0
    dir_reads = 0
    freshRepo().getLatest(10)
    assert(dir_reads > 0, "a snapshot with an unknown version was accepted")
end)

t.test("a corrupt snapshot is a miss, not a crash", function()
    setup()
    freshRepo().getLatest(10)
    disk.data.list = "not a table"
    dir_reads = 0
    local out = freshRepo().getLatest(10)
    assert(dir_reads > 0, "a malformed snapshot was accepted")
    assert(#out == 2, "a malformed snapshot broke the walk")
end)

t.test("invalidateWalkCache drops the snapshot as well as the memory", function()
    setup()
    local Repo = freshRepo()
    Repo.getLatest(10)
    Repo.invalidateWalkCache()
    -- Anything that says "forget the library" has to reach the copy that
    -- survives a restart, or the next launch resurrects what was invalidated.
    assert(disk.deletes > 0, "the persisted walk survived an invalidation")
    assert(disk.data == nil, "the snapshot is still on disk")
end)

-- ── plugin formats: the walk is only valid for the format set it saw ─────────
-- Enabling or disabling a plugin changes which files are books without
-- touching a directory, so mtimes alone cannot invalidate the walk. These
-- drive the real lib/bookshelf_plugin_formats against a fake DocumentRegistry.

local PF = require("lib/bookshelf_plugin_formats")

local function setPluginFormats(on)
    if on then
        package.loaded["document/documentregistry"] = {
            image_ext = {},
            providers = {
                { extension = "epub",   provider = { provider = "crengine" } },
                { extension = "meguru", provider = { provider = "meguru" } },
            },
        }
    else
        package.loaded["document/documentregistry"] = nil
    end
    PF._reset()
end

local function setupWithStub()
    setup()
    tree["/home"] = { ".", "..", "a.epub", "sub", "c.meguru" }
    mtimes["/home/c.meguru"] = 300
    _G._test_bim_data["/home/c.meguru"] = { title = "C" }
end

t.test("enabling a plugin format makes the restart walk again and list its files", function()
    setupWithStub()
    setPluginFormats(false)
    local n = #freshRepo().getLatest(10)
    assert(n == 2, "without the plugin, .meguru is not a book: got " .. n)
    setPluginFormats(true)
    dir_reads = 0
    local out = freshRepo().getLatest(10)
    assert(dir_reads > 0, "a snapshot from before the plugin was enabled was accepted")
    assert(#out == 3, "the plugin's book is still hidden: got " .. #out)
    assert(disk.data.formats == "meguru", "the snapshot does not record its format set")
    setPluginFormats(false)
end)

t.test("disabling it drops its files on the next launch, though no directory changed", function()
    setupWithStub()
    setPluginFormats(true)
    assert(#freshRepo().getLatest(10) == 3, "fixture: the plugin's book should be listed")
    setPluginFormats(false)
    dir_reads = 0
    local out = freshRepo().getLatest(10)
    assert(dir_reads > 0, "a snapshot with a disabled plugin's books was accepted")
    assert(#out == 2, "a disabled plugin's book stayed on the shelf: got " .. #out)
end)

t.test("an unchanged format set still reuses the snapshot", function()
    setupWithStub()
    setPluginFormats(true)
    freshRepo().getLatest(10)
    dir_reads = 0
    local out = freshRepo().getLatest(10)
    assert(dir_reads == 0, "walked again with nothing changed: " .. dir_reads .. " dirs")
    assert(#out == 3)
    setPluginFormats(false)
end)

t.test("a snapshot from before format sets were recorded is accepted when there are none", function()
    setup()
    setPluginFormats(false)
    freshRepo().getLatest(10)
    disk.data.formats = nil   -- written by the previous Bookshelf version
    dir_reads = 0
    freshRepo().getLatest(10)
    assert(dir_reads == 0, "an upgrade without plugin formats paid for a walk")
end)

t.test("a format registered after this session's first walk is picked up, groups included", function()
    setupWithStub()
    setPluginFormats(false)
    local Repo = freshRepo()
    assert(#Repo.getLatest(10) == 2)
    local groups_before = Repo.getFormats(20, 0)
    -- The plugin registers its provider later in the same session.
    setPluginFormats(true)
    local out = Repo.getLatest(10)
    assert(#out == 3, "the late-registered format's book is missing: got " .. #out)
    local groups_after = Repo.getFormats(20, 0)
    assert(#groups_after == #groups_before + 1,
        "the Formats grouping kept describing the old book set: "
        .. #groups_before .. " -> " .. #groups_after)
    setPluginFormats(false)
end)

t.done()
