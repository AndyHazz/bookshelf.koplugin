-- tests/_test_file_ops.lua
-- Pure path maths + move planning + engine sequencing for
-- lib/bookshelf_file_ops. Runs standalone: `lua tests/_test_file_ops.lua`.

package.path = "./?.lua;./?/init.lua;" .. package.path

-- ---------- Stub KOReader modules (before requiring the module) ----------
package.loaded["logger"] = {
    info = function() end, warn = function() end, dbg = function() end,
}

local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()
local eq = helpers.eq

local FileOps = require("lib/bookshelf_file_ops")

-- ---------- path helpers ----------
t.test("normDir strips trailing slashes, keeps root", function()
    eq(FileOps.normDir("/mnt/us/ebooks/"), "/mnt/us/ebooks")
    eq(FileOps.normDir("/mnt/us/ebooks"), "/mnt/us/ebooks")
    eq(FileOps.normDir("/"), "/")
end)

t.test("basename / parentDir / joinDir", function()
    eq(FileOps.basename("/a/b/c.epub"), "c.epub")
    eq(FileOps.basename("/a/b/"), "b")
    eq(FileOps.parentDir("/a/b/c.epub"), "/a/b")
    eq(FileOps.parentDir("/a"), "/")
    eq(FileOps.joinDir("/a/b", "c.epub"), "/a/b/c.epub")
    eq(FileOps.joinDir("/", "c.epub"), "/c.epub")
end)

t.test("destPath joins basename onto destination", function()
    eq(FileOps.destPath("/a/b/c.epub", "/x/y"), "/x/y/c.epub")
    eq(FileOps.destPath("/a/b/c.epub", "/x/y/"), "/x/y/c.epub")
    eq(FileOps.destPath("/a/b/c.epub", "/"), "/c.epub")
end)

t.test("prefixSwap rewrites under old_dir, nil otherwise", function()
    eq(FileOps.prefixSwap("/a/b/c.epub", "/a/b", "/x"), "/x/c.epub")
    eq(FileOps.prefixSwap("/a/b", "/a/b", "/x"), "/x")
    eq(FileOps.prefixSwap("/a/bb/c.epub", "/a/b", "/x"), nil)  -- no partial-segment match
    eq(FileOps.prefixSwap("/other/c.epub", "/a/b", "/x"), nil)
end)

t.test("shelfDepth mirrors walkBooks arithmetic", function()
    eq(FileOps.shelfDepth("/home", "/home"), 0)
    eq(FileOps.shelfDepth("/home/a", "/home"), 1)
    eq(FileOps.shelfDepth("/home/a/b/c", "/home"), 3)
    eq(FileOps.shelfDepth("/elsewhere", "/home"), nil)
end)

t.test("isVisibleOnShelf: inside within depth yes, deeper/outside no", function()
    eq(FileOps.isVisibleOnShelf("/home/a/b/c", "/home", 3), true)
    eq(FileOps.isVisibleOnShelf("/home/a/b/c/d", "/home", 3), false)
    eq(FileOps.isVisibleOnShelf("/elsewhere", "/home", 3), false)
end)

-- ---------- planMoves ----------
t.test("planMoves partitions moves vs skip reasons", function()
    local disk = {
        ["/h/a/one.epub"] = true,
        ["/h/a/two.epub"] = true,
        ["/h/dst/two.epub"] = true,     -- collision for two.epub
        ["/h/dst/already.epub"] = true, -- same_dir case source
        ["/h/dst"] = true,
    }
    local plan = FileOps.planMoves(
        { "/h/a/one.epub", "/h/a/two.epub", "/h/a/gone.epub",
          "/h/dst/already.epub", "/h/a/open.epub" },
        "/h/dst/",
        {
            exists = function(p) return disk[p] == true end,
            in_use_paths = { ["/h/a/open.epub"] = true },
        })
    eq(#plan.moves, 1)
    eq(plan.moves[1].from, "/h/a/one.epub")
    eq(plan.moves[1].to, "/h/dst/one.epub")
    local reasons = {}
    for _i, s in ipairs(plan.skipped) do reasons[s.path] = s.reason end
    eq(reasons["/h/a/two.epub"], "exists")
    eq(reasons["/h/a/gone.epub"], "missing")
    eq(reasons["/h/dst/already.epub"], "same_dir")
    eq(reasons["/h/a/open.epub"], "in_use")
end)

-- ---------- engine stubs ----------
local calls = {}          -- ordered log of side effects
local mv_ok = true        -- toggle mv success per test
local mv_fail_paths = {}  -- set of paths that fail: { [path] = true }
local sql_fail = false    -- toggle BIM UPDATE failure per test

package.loaded["apps/filemanager/filemanager"] = {
    moveFile = function(_self, from, to)
        calls[#calls + 1] = { "mv", from, to }
        if mv_fail_paths[from] then return false end
        return mv_ok
    end,
    instance = nil,
}
package.loaded["docsettings"] = {
    updateLocation = function(old, new)
        calls[#calls + 1] = { "sdr", old, new }
    end,
}
package.loaded["readhistory"] = {
    updateItem = function(_self, old, new) calls[#calls + 1] = { "hist", old, new } end,
    updateItemsByPath = function(_self, old, new) calls[#calls + 1] = { "histdir", old, new } end,
    updateItems = function(_self, files, new_path)
        local n = 0
        for _f in pairs(files) do n = n + 1 end
        calls[#calls + 1] = { "histbatch", n, new_path }
    end,
}
package.loaded["readcollection"] = {
    updateItem = function(_self, old, new) calls[#calls + 1] = { "coll", old, new } end,
    updateItemsByPath = function(_self, old, new) calls[#calls + 1] = { "colldir", old, new } end,
    updateItems = function(_self, files, new_path)
        local n = 0
        for _f in pairs(files) do n = n + 1 end
        calls[#calls + 1] = { "collbatch", n, new_path }
    end,
}
package.loaded["lib/bookshelf_hardcover"] = {
    relinkPath = function(old, new) calls[#calls + 1] = { "hc", old, new } end,
    relinkPaths = function(list) calls[#calls + 1] = { "hcbatch", #list } end,
}
package.loaded["ui/widget/booklist"] = {
    resetBookInfoCache = function(old) calls[#calls + 1] = { "blcache", old } end,
}
package.loaded["datastorage"] = {
    getSettingsDir = function() return "/tmp/_test_fileops_settings" end,
}
local broadcasts = {}
package.loaded["ui/event"] = { new = function(_self, name, arg) return { name = name, arg = arg } end }
package.loaded["ui/uimanager"] = {
    broadcastEvent = function(_self, ev) broadcasts[#broadcasts + 1] = ev end,
}
-- lfs stub: BIM db "exists" so the UPDATE path runs.
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(path, key)
        if path == "/tmp/_test_fileops_settings/bookinfo_cache.sqlite3" then
            return key == "mode" and "file" or { mode = "file" }
        end
        return nil
    end,
    mkdir = function() return true end,
}
local sql_binds = {}
package.loaded["lua-ljsqlite3/init"] = {
    open = function(_path)
        if sql_fail then error("cannot open") end
        return {
            prepare = function(_self, sql)
                return {
                    bind = function(s, ...)
                        local args = {...}
                        sql_binds[#sql_binds + 1] = { sql = sql, ... }
                        -- Also log BIM call to calls array: new_dir (arg 1) and old_dir (arg 3)
                        if sql:match("UPDATE bookinfo") then
                            calls[#calls + 1] = { "bim", args[1], args[3] }
                        end
                        return s
                    end,
                    step = function() return nil end,
                    close = function() end,
                }
            end,
            close = function() end,
        }
    end,
}
-- ReaderUI / Park stubs for inUsePaths
package.loaded["apps/reader/readerui"] = {
    instance = { document = { file = "/h/open-now.epub" } },
}
package.loaded["lib/bookshelf_reader_park"] = {
    parkedFile = function() return "/h/parked.epub" end,
}

-- Re-require picks up the same cached module (engine functions do their
-- own lazy requires, so no reload of FileOps is needed).

t.test("moveBook: mv then fix-ups in spec order", function()
    calls = {}
    local ok = FileOps.moveBook("/h/a/one.epub", "/h/dst/one.epub")
    eq(ok, true)
    eq(calls[1], { "mv", "/h/a/one.epub", "/h/dst/one.epub" })
    eq(calls[2], { "sdr", "/h/a/one.epub", "/h/dst/one.epub" })
    eq(calls[3], { "hist", "/h/a/one.epub", "/h/dst/one.epub" })
    eq(calls[4], { "coll", "/h/a/one.epub", "/h/dst/one.epub" })
    eq(calls[5], { "hc", "/h/a/one.epub", "/h/dst/one.epub" })
    eq(calls[6], { "blcache", "/h/a/one.epub" })
    eq(calls[7], { "bim", "/h/dst/", "/h/a/" })
end)

t.test("moveBook: BIM row UPDATE binds slash-terminated dirs", function()
    calls = {}; sql_binds = {}
    FileOps.moveBook("/h/a/one.epub", "/h/dst/one.epub")
    eq(#sql_binds, 1)
    -- BIM keys rows on (directory, filename) with directory ending in a
    -- slash: stale_sweep reconstructs fp as directory .. filename.
    eq(sql_binds[1][1], "/h/dst/")
    eq(sql_binds[1][2], "one.epub")
    eq(sql_binds[1][3], "/h/a/")
    eq(sql_binds[1][4], "one.epub")
end)

t.test("moveBook: mv failure = no fix-ups, returns error", function()
    calls = {}; mv_ok = false
    local ok, reason = FileOps.moveBook("/h/a/one.epub", "/h/dst/one.epub")
    mv_ok = true
    eq(ok, nil)
    eq(reason, "error")
    eq(#calls, 1)  -- only the mv attempt
end)

t.test("moveBook: SQL failure falls back to InvalidateMetadataCache", function()
    calls = {}; broadcasts = {}; sql_fail = true
    FileOps.moveBook("/h/a/one.epub", "/h/dst/one.epub")
    sql_fail = false
    eq(#broadcasts, 2)
    eq(broadcasts[1].name, "InvalidateMetadataCache")
    eq(broadcasts[1].arg, "/h/a/one.epub")
    eq(broadcasts[2].name, "InvalidateMetadataCache")
    eq(broadcasts[2].arg, "/h/dst/one.epub")
end)

t.test("moveBooks: summary counts moved / failed / skipped", function()
    calls = {}
    local plan = {
        moves = {
            { from = "/h/a/one.epub", to = "/h/dst/one.epub" },
            { from = "/h/a/two.epub", to = "/h/dst/two.epub" },
        },
        skipped = {
            { path = "/h/a/x.epub", reason = "exists" },
            { path = "/h/a/y.epub", reason = "exists" },
            { path = "/h/a/z.epub", reason = "in_use" },
        },
    }
    local summary = FileOps.moveBooks(plan)
    eq(#summary.moved, 2)
    eq(summary.moved_to[2], "/h/dst/two.epub")
    eq(summary.failed, 0)
    eq(summary.skipped.exists, 2)
    eq(summary.skipped.in_use, 1)
end)

t.test("moveBooks: one failing move doesn't abort batch, order preserved", function()
    calls = {}; mv_fail_paths = {}
    -- Middle book fails; survivors 1 and 3 succeed
    mv_fail_paths["/h/a/two.epub"] = true
    local plan = {
        moves = {
            { from = "/h/a/one.epub", to = "/h/dst/one.epub" },
            { from = "/h/a/two.epub", to = "/h/dst/two.epub" },
            { from = "/h/a/three.epub", to = "/h/dst/three.epub" },
        },
        skipped = {},
    }
    local summary = FileOps.moveBooks(plan)
    eq(summary.failed, 1)
    eq(#summary.moved, 2)
    eq(summary.moved[1], "/h/a/one.epub")
    eq(summary.moved[2], "/h/a/three.epub")
    eq(summary.moved_to[1], "/h/dst/one.epub")
    eq(summary.moved_to[2], "/h/dst/three.epub")
    mv_fail_paths = {}
end)

t.test("inUsePaths: open reader + parked reader", function()
    local set = FileOps.inUsePaths()
    eq(set["/h/open-now.epub"], true)
    eq(set["/h/parked.epub"], true)
end)

-- ---------- ImageSource.rekeyFolderPaths ----------
t.test("rekeyFolderPaths rewrites folder keys and image values", function()
    local saved
    package.loaded["lib/bookshelf_settings_store"] = {
        read = function(key)
            if key == "folder_images" then
                return {
                    ["/h/a"]        = "/h/a/cover.jpg",      -- moved folder itself
                    ["/h/a/sub"]    = "/elsewhere/pic.png",  -- descendant key, external image
                    ["/h/other"]    = "/h/other/cover.jpg",  -- untouched
                }
            end
            return nil
        end,
        save = function(_key, t2) saved = t2 end,
        generation = function() return 0 end,
    }
    -- RenderImage is required at image_source module top; stub before require.
    package.loaded["ui/renderimage"] = {}
    local ImageSource = require("lib/bookshelf_image_source")
    local changed = ImageSource.rekeyFolderPaths("/h/a", "/h/b/a")
    eq(changed, true)
    eq(saved["/h/b/a"], "/h/b/a/cover.jpg")
    eq(saved["/h/b/a/sub"], "/elsewhere/pic.png")
    eq(saved["/h/other"], "/h/other/cover.jpg")
    eq(saved["/h/a"], nil)
end)

-- ---------- folder ops ----------
-- Filesystem-shaped lfs stub: `dirs` holds directories, `files` holds
-- files, and lfs.dir iterates the immediate children of a path. Needed
-- because relocateFolder now discovers books with FileOps.listBooksUnder
-- (a real recursive walk) rather than the depth-bounded library cache.
local dirs = {}
local files = {}
local function setTree(dir_list, file_list)
    dirs, files = {}, {}
    for _i, d in ipairs(dir_list or {}) do dirs[d] = true end
    for _i, f in ipairs(file_list or {}) do files[f] = true end
end
package.loaded["libs/libkoreader-lfs"].attributes = function(path, key)
    if path == "/tmp/_test_fileops_settings/bookinfo_cache.sqlite3" then
        return key == "mode" and "file" or { mode = "file" }
    end
    if dirs[path] then
        return key == "mode" and "directory" or { mode = "directory" }
    end
    if files[path] then
        return key == "mode" and "file" or { mode = "file" }
    end
    return nil
end
package.loaded["libs/libkoreader-lfs"].mkdir = function(path)
    if dirs[path] or files[path] then return nil, "exists" end
    dirs[path] = true
    return true
end
-- Immediate children of `path`, as lfs.dir yields them.
package.loaded["libs/libkoreader-lfs"].dir = function(path)
    local prefix = (path == "/") and "/" or (path .. "/")
    local entries = {}
    for _t, set in ipairs({ dirs, files }) do
        for p in pairs(set) do
            if p ~= path and p:sub(1, #prefix) == prefix then
                local rest = p:sub(#prefix + 1)
                if not rest:find("/", 1, true) then entries[rest] = true end
            end
        end
    end
    local list = {}
    for e in pairs(entries) do list[#list + 1] = e end
    table.sort(list)
    local i = 0
    return function() i = i + 1; return list[i] end, {}
end

t.test("listBooksUnder finds books at ANY depth, skips .sdr and non-books", function()
    -- The regression this guards: the depth-bounded library walk (default
    -- 3) missed deeply-nested books, so a folder move skipped their
    -- sidecar fix-up and detached progress in "dir" metadata mode.
    setTree({ "/h/a", "/h/a/b", "/h/a/b/c", "/h/a/b/c/d", "/h/a/b/c/d/e",
              "/h/a/one.sdr" },
            { "/h/a/top.epub",
              "/h/a/b/c/d/e/deep.epub",   -- 5 levels down, past any cap of 3
              "/h/a/notabook.txt.bak",
              "/h/a/one.sdr/metadata.epub.lua" })
    package.loaded["lib/bookshelf_book_repository"] = {
        isBookFile = function(name) return name:sub(-5) == ".epub" end,
    }
    local found = FileOps.listBooksUnder("/h/a/")
    table.sort(found)
    eq(found, { "/h/a/b/c/d/e/deep.epub", "/h/a/top.epub" })
end)

t.test("createFolder validates name and collision", function()
    setTree({ "/h" })
    eq({ FileOps.createFolder("/h", "  ") }, { nil, "bad_name" })
    eq({ FileOps.createFolder("/h", "a/b") }, { nil, "bad_name" })
    eq({ FileOps.createFolder("/h", ".hidden") }, { nil, "bad_name" })
    eq(FileOps.createFolder("/h/", "New Books"), "/h/New Books")
    eq({ FileOps.createFolder("/h", "New Books") }, { nil, "exists" })
end)

t.test("_rewriteTabPaths rewrites folder chip sources and filter lists", function()
    local saved_tabs
    package.loaded["lib/bookshelf_tab_model"] = {
        load = function()
            return {
                { id = "t1", source = { kind = "folder", id = "/h/a" }, filter = {} },
                { id = "t2", source = { kind = "folder_flat", id = "/h/a/sub" }, filter = {} },
                { id = "t3", source = { kind = "all" },
                  filter = { folders = {
                      include = { ["/h/a"] = true, ["/h/other"] = true },
                      exclude = { ["/h/a/skip"] = true },
                  } } },
            }
        end,
        save = function(tabs) saved_tabs = tabs end,
    }
    local changed = FileOps._rewriteTabPaths("/h/a", "/h/b")
    eq(changed, true)
    eq(saved_tabs[1].source.id, "/h/b")
    eq(saved_tabs[2].source.id, "/h/b/sub")
    eq(saved_tabs[3].filter.folders.include["/h/b"], true)
    eq(saved_tabs[3].filter.folders.include["/h/other"], true)
    eq(saved_tabs[3].filter.folders.include["/h/a"], nil)
    eq(saved_tabs[3].filter.folders.exclude["/h/b/skip"], true)
end)

-- FileManagerShortcuts stores shortcuts class-level (backed by
-- G_reader_settings), so relocateFolder's rewrite calls it with no FM
-- instance required.
package.loaded["apps/filemanager/filemanagershortcuts"] = {
    updateItemsByPath = function(_self, old, new)
        calls[#calls + 1] = { "shortcuts", old, new }
    end,
}

t.test("relocateFolder: prechecks, per-book fixups, prefix rewrites", function()
    setTree({ "/h/a", "/h/a/sub", "/h/dst" },
            { "/h/a/one.epub", "/h/a/sub/two.epub" })
    package.loaded["lib/bookshelf_book_repository"] = {
        isBookFile = function(name) return name:sub(-5) == ".epub" end,
    }
    local rekeyed
    package.loaded["lib/bookshelf_image_source"] = {
        rekeyFolderPaths = function(old, new) rekeyed = { old, new } end,
    }
    package.loaded["lib/bookshelf_tab_model"] = {
        load = function() return {} end, save = function() end,
    }
    calls = {}
    -- self-nesting and collision guards
    eq({ FileOps.relocateFolder("/h/a", "/h/a/inside") }, { nil, "self" })
    eq({ FileOps.relocateFolder("/h/a", "/h/dst") }, { nil, "exists" })
    eq({ FileOps.relocateFolder("/h/gone", "/h/x") }, { nil, "missing" })
    -- happy path
    local ok, n = FileOps.relocateFolder("/h/a/", "/h/dst/a")
    eq(ok, true)
    eq(n, 2)
    eq(calls[1], { "mv", "/h/a", "/h/dst/a" })
    eq(calls[2], { "sdr", "/h/a/one.epub", "/h/dst/a/one.epub" })
    -- per-book: sdr, hc, blcache, bim for book 1 (calls 2-5), then book 2 (6-9)
    eq(calls[6], { "sdr", "/h/a/sub/two.epub", "/h/dst/a/sub/two.epub" })
    -- prefix rewrites after the per-book loop
    eq(calls[10], { "histdir", "/h/a", "/h/dst/a" })
    eq(calls[11], { "colldir", "/h/a", "/h/dst/a" })
    eq(calls[12], { "shortcuts", "/h/a", "/h/dst/a" })
    eq(rekeyed, { "/h/a", "/h/dst/a" })
end)

t.test("relocateFolder: in-use book under the folder blocks the move", function()
    setTree({ "/h/a" }, { "/h/a/one.epub" })
    calls = {}
    local prev_file = package.loaded["apps/reader/readerui"].instance.document.file
    package.loaded["apps/reader/readerui"].instance.document.file = "/h/a/open-now.epub"
    local ok, reason = FileOps.relocateFolder("/h/a", "/h/dst-unused")
    package.loaded["apps/reader/readerui"].instance.document.file = prev_file
    eq(ok, nil)
    eq(reason, "in_use")
    eq(#calls, 0)
end)

t.test("relocateFolder: mv failure aborts, no fixups run", function()
    setTree({ "/h/a", "/h/dst" }, { "/h/a/one.epub" })
    local rekeyed_fail
    package.loaded["lib/bookshelf_image_source"] = {
        rekeyFolderPaths = function(old, new) rekeyed_fail = { old, new } end,
    }
    package.loaded["lib/bookshelf_tab_model"] = {
        load = function() return {} end, save = function() end,
    }
    calls = {}
    mv_ok = false
    local ok, reason = FileOps.relocateFolder("/h/a", "/h/dst/a")
    mv_ok = true
    eq(ok, nil)
    eq(reason, "error")
    -- Only the mv attempt; no sdr/hc/blcache/bim/histdir/colldir
    eq(#calls, 1)
    eq(calls[1], { "mv", "/h/a", "/h/dst/a" })
    eq(rekeyed_fail, nil)
end)

t.test("renameFolder maps to relocateFolder in the same parent", function()
    setTree({ "/h/a" })
    calls = {}
    eq({ FileOps.renameFolder("/h/a", "b/c") }, { nil, "bad_name" })
    local ok = FileOps.renameFolder("/h/a", "renamed")
    eq(ok, true)
    eq(calls[1], { "mv", "/h/a", "/h/renamed" })
end)

-- ---------- folder picker choice assembly ----------
t.test("buildChoices: Home first, exclusions drop self and descendants", function()
    package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
    local Picker = require("lib/bookshelf_folder_picker")
    local out = Picker.buildChoices({
        { value = "/h/a",     label = "a",     subtitle = "/h/a" },
        { value = "/h/a/sub", label = "sub",   subtitle = "/h/a/sub" },
        { value = "/h/other", label = "other", subtitle = "/h/other" },
    }, "/h/", { "/h/a" })
    eq(#out, 2)
    eq(out[1].value, "/h")          -- Home entry, normalised
    eq(out[2].value, "/h/other")    -- /h/a and /h/a/sub excluded
end)

t.test("moveBooks reports progress for every file, in order", function()
    setTree({}, {})
    calls = {}
    local seen = {}
    local plan = {
        moves = {
            { from = "/h/a/1.epub", to = "/h/b/1.epub" },
            { from = "/h/a/2.epub", to = "/h/b/2.epub" },
            { from = "/h/a/3.epub", to = "/h/b/3.epub" },
        },
        skipped = {},
    }
    local summary = FileOps.moveBooks(plan, function(done, total, path)
        seen[#seen + 1] = { done, total, path }
    end)
    eq(#summary.moved, 3)
    eq(#seen, 3)
    eq(seen[1], { 1, 3, "/h/a/1.epub" })
    eq(seen[3], { 3, 3, "/h/a/3.epub" })
end)

t.test("a throwing progress callback cannot break the batch", function()
    setTree({}, {})
    local plan = { moves = { { from = "/h/a/1.epub", to = "/h/b/1.epub" } }, skipped = {} }
    local summary = FileOps.moveBooks(plan, function() error("boom") end)
    eq(#summary.moved, 1)
    eq(summary.failed, 0)
end)

-- ---------- atomic rename fast path + batching ----------
t.test("os.rename is tried first, and skips the mv subprocess", function()
    local orig_rename = os.rename
    calls = {}
    os.rename = function(_from, _to) return true end
    local ok = FileOps.moveBook("/h/a/one.epub", "/h/dst/one.epub")
    os.rename = orig_rename
    eq(ok, true)
    for _i, c in ipairs(calls) do
        if c[1] == "mv" then error("fell back to /bin/mv despite rename succeeding") end
    end
    -- fix-ups still ran
    eq(calls[1], { "sdr", "/h/a/one.epub", "/h/dst/one.epub" })
end)

t.test("a failed rename falls back to /bin/mv", function()
    local orig_rename = os.rename
    calls = {}
    os.rename = function(_from, _to) return nil, "EXDEV" end
    local ok = FileOps.moveBook("/h/a/one.epub", "/h/dst/one.epub")
    os.rename = orig_rename
    eq(ok, true)
    eq(calls[1], { "mv", "/h/a/one.epub", "/h/dst/one.epub" })
end)

t.test("batch: history/collections/hardcover written ONCE, not per book", function()
    calls = {}
    local plan = {
        moves = {
            { from = "/h/a/1.epub", to = "/h/dst/1.epub" },
            { from = "/h/a/2.epub", to = "/h/dst/2.epub" },
            { from = "/h/a/3.epub", to = "/h/dst/3.epub" },
        },
        skipped = {},
    }
    local summary = FileOps.moveBooks(plan)
    eq(#summary.moved, 3)
    local n = { hist = 0, coll = 0, hc = 0, histbatch = 0, collbatch = 0, hcbatch = 0 }
    local batch_args = {}
    for _i, c in ipairs(calls) do
        if n[c[1]] ~= nil then n[c[1]] = n[c[1]] + 1 end
        if c[1] == "histbatch" or c[1] == "collbatch" then batch_args[c[1]] = { c[2], c[3] } end
    end
    eq(n.hist, 0, "per-book history flush should not run in batch mode")
    eq(n.coll, 0, "per-book collection write should not run in batch mode")
    eq(n.hc, 0, "per-book hardcover save should not run in batch mode")
    eq(n.histbatch, 1)
    eq(n.collbatch, 1)
    eq(n.hcbatch, 1)
    eq(batch_args.histbatch, { 3, "/h/dst" }, "batched call gets all 3 old paths + dest dir")
    eq(batch_args.collbatch, { 3, "/h/dst" })
end)

t.test("batch is skipped when the plan spans several destinations", function()
    calls = {}
    local plan = {
        moves = {
            { from = "/h/a/1.epub", to = "/h/x/1.epub" },
            { from = "/h/a/2.epub", to = "/h/y/2.epub" },
        },
        skipped = {},
    }
    FileOps.moveBooks(plan)
    local per_book, batched = 0, 0
    for _i, c in ipairs(calls) do
        if c[1] == "hist" then per_book = per_book + 1 end
        if c[1] == "histbatch" then batched = batched + 1 end
    end
    eq(per_book, 2, "mixed destinations must fall back to per-book updates")
    eq(batched, 0)
end)

t.test("batch: a failed move contributes nothing to the deferred flush", function()
    calls = {}
    mv_fail_paths = { ["/h/a/2.epub"] = true }
    local plan = {
        moves = {
            { from = "/h/a/1.epub", to = "/h/dst/1.epub" },
            { from = "/h/a/2.epub", to = "/h/dst/2.epub" },
        },
        skipped = {},
    }
    local summary = FileOps.moveBooks(plan)
    mv_fail_paths = {}
    eq(summary.failed, 1)
    eq(#summary.moved, 1)
    for _i, c in ipairs(calls) do
        if c[1] == "histbatch" then
            eq(c[2], 1, "only the successfully moved book may be flushed")
        end
    end
end)

t.done()
