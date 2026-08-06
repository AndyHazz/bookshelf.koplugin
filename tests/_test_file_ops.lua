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
}
package.loaded["readcollection"] = {
    updateItem = function(_self, old, new) calls[#calls + 1] = { "coll", old, new } end,
    updateItemsByPath = function(_self, old, new) calls[#calls + 1] = { "colldir", old, new } end,
}
package.loaded["lib/bookshelf_hardcover"] = {
    relinkPath = function(old, new) calls[#calls + 1] = { "hc", old, new } end,
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
    eq(#broadcasts, 1)
    eq(broadcasts[1].name, "InvalidateMetadataCache")
    eq(broadcasts[1].arg, "/h/a/one.epub")
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

t.done()
