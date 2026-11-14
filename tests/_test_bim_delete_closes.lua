-- tests/_test_bim_delete_closes.lua
-- Refresh metadata: the cover went and did not come back (Reddit; the
-- maintainer's PW5, until a swipe down).
--
-- KOReader's BIM:deleteBookInfo prepares a DELETE and never closes it. BIM
-- closes its connection before it forks the extractor so the two processes
-- do not share one; with that statement still alive the close did not take,
-- the extractor started with the main process's handles on the database,
-- and the row it wrote was undone (seen on the rig: the finished row there,
-- then the "in progress" one again). The book sat without a cover until a
-- retry ten seconds on, or for good.
--
-- Repo.bimDelete deletes with a statement it closes itself.
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

local repo = io.open("lib/bookshelf_book_repository.lua"):read("*a")
local BODY = repo:match("\nfunction Repo%.bimDelete%(bim, filepath%)\n(.-)\nend\n")

local function del(bim, fp)
    assert(BODY, "Repo.bimDelete(bim, filepath) not found")
    local env = setmetatable({}, { __index = _G })
    local code = "local bim, filepath = ...\n" .. BODY
    local f
    if _G.setfenv then f = assert(_G.loadstring(code, "bimDelete")); _G.setfenv(f, env)
    else f = assert(load(code, "bimDelete", "t", env)) end
    return f(bim, fp)
end

-- A BIM with a connection that records what its statements were asked.
local function newBim(opts)
    opts = opts or {}
    local log = { prepared = {}, own_delete = 0 }
    local bim = { log = log }
    function bim:openDbConnection()
        if opts.no_conn then return end
        self.db_conn = self.db_conn or {
            prepare = function(_c, sql)
                if opts.prepare_fails then error("no such table") end
                local st = { sql = sql, closed = false, stepped = false }
                function st:bind(...) self.bound = { ... }; return self end
                function st:step() if opts.step_fails then error("database is locked") end; self.stepped = true end
                function st:close() self.closed = true end
                log.prepared[#log.prepared + 1] = st
                return st
            end,
        }
    end
    function bim:deleteBookInfo(fp) log.own_delete = log.own_delete + 1; log.own_fp = fp end
    return bim
end

t.test("the row is deleted by directory and file name, as BIM keys it", function()
    local bim = newBim()
    eq(del(bim, "/mnt/us/ebooks/Sub/A Book.epub"), true)
    local st = bim.log.prepared[1]
    assert(st, "nothing was prepared")
    assert(st.sql:find("DELETE FROM bookinfo", 1, true), "not a delete: " .. st.sql)
    eq(st.bound[1], "/mnt/us/ebooks/Sub/"); eq(st.bound[2], "A Book.epub")
    eq(st.stepped, true)
    eq(bim.log.own_delete, 0, "BIM's own delete ran too: its statement is the one left open")
end)

t.test("the statement is closed: nothing is left on BIM's connection", function()
    local bim = newBim()
    del(bim, "/b/a.epub")
    eq(#bim.log.prepared, 1)
    eq(bim.log.prepared[1].closed, true, "left open: BIM's close before the fork does not take")
end)

t.test("closed even when the delete fails, and BIM's own is tried", function()
    local bim = newBim({ step_fails = true })
    del(bim, "/b/a.epub")
    eq(bim.log.prepared[1].closed, true, "a failed delete left its statement open")
    eq(bim.log.own_delete, 1); eq(bim.log.own_fp, "/b/a.epub")
end)

t.test("no connection to prepare on: BIM's own delete", function()
    local bim = newBim({ no_conn = true })
    del(bim, "/b/a.epub")
    eq(bim.log.own_delete, 1)
    bim = newBim({ prepare_fails = true })
    del(bim, "/b/a.epub")
    eq(bim.log.own_delete, 1)
end)

t.test("no BIM, or no path: nothing, and no error", function()
    eq(del(nil, "/b/a.epub"), false)
    eq(del(newBim(), nil), false)
end)

t.test("nowhere in the plugin deletes a row with BIM's own leaky statement", function()
    for _i, f in ipairs({ "lib/bookshelf_widget_book_popup.lua", "lib/bookshelf_bulk_actions.lua",
                          "lib/bookshelf_stale_sweep.lua", "lib/bookshelf_widget.lua", "main.lua" }) do
        local src = io.open(f):read("*a")
        eq(select(2, src:gsub("BIM:deleteBookInfo%(", "")), 0, f .. " calls BIM:deleteBookInfo")
    end
end)

t.done()
