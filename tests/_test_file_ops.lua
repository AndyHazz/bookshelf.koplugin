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

t.done()
