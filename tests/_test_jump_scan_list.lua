-- tests/_test_jump_scan_list.lua
-- _jumpScanList: which list "Go to letter" searches, and which sort key it
-- reads off it (#307).
--
-- The bug: the jump fetched the CHIP's source no matter what was on screen,
-- so inside a subfolder it searched the parent's listing and answered "No
-- items start with X" for a letter the user could see. The branches here have
-- to mirror _fetchChipItems -- whatever the shelf renders is what a letter
-- has to be found in.
--
-- Driven against the real method body, extracted by name and run under a stub
-- `self` plus a stub Repo (as _test_select_all_view does).
package.path = "./?.lua;./?/init.lua;" .. package.path

local t = dofile("tests/_helpers.lua").runner()

local src  = io.open("lib/bookshelf_widget.lua"):read("*a")
local body = src:match("\nfunction BookshelfWidget:_jumpScanList%(%)\n(.-)\nend\n")
assert(body, "could not find BookshelfWidget:_jumpScanList() - renamed?")

local function compile(code, env)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, "_jumpScanList"))
        _G.setfenv(f, env)
        return f
    end
    return assert(load(code, "_jumpScanList", "t", env))
end

-- Run the method. opts:
--   tab   - what TabModel.getById returns for the active chip
--   drill - the drilldown path (defaults to none)
--   all_priority - what Repo.getSortPriority("all") answers
--   getAll / getBySource - override to raise, to test the pcall guards
-- Returns items, sort_key, via, and a record of the repo calls made.
local function scan(opts)
    local calls = {}
    local Repo = {
        getAll = function(path, limit, offset, sort_priority, filter, o)
            calls.getAll = { path = path, limit = limit, offset = offset,
                             sort_priority = sort_priority, filter = filter,
                             opts = o }
            if opts.getAll_throws then error("walk blew up") end
            return opts.rows or { { title = "from getAll" } }, 1
        end,
        getBySource = function(source, filter, sort_priority, offset, limit, o)
            calls.getBySource = { source = source, filter = filter,
                                  sort_priority = sort_priority,
                                  offset = offset, limit = limit, opts = o }
            return opts.rows or { { title = "from getBySource" } }, 1
        end,
        getSortPriority = function(id)
            calls.getSortPriority = id
            return opts.all_priority
        end,
    }
    local env = {
        require = function(name)
            assert(name == "lib/bookshelf_tab_model", "unexpected require: " .. name)
            return { getById = function() return opts.tab end }
        end,
        Repo = Repo, math = math, pcall = pcall, tostring = tostring,
    }
    local self_tbl = {
        chip            = opts.chip or "library",
        _drilldown_path = opts.drill or {},
        _total_items    = opts.total_items,
    }
    local f = compile("local self = ... ; " .. body, env)
    local items, sort_key, via = f(self_tbl)
    return items, sort_key, via, calls
end

local SP2 = { { key = "filename" }, { key = "title" } }

-- ── Folder drill: the reported bug ──

t.test("a folder drill searches the DRILLED path, not the chip's source", function()
    local _, _, via, calls = scan{
        tab   = { source = { kind = "all" }, sort_priority = SP2 },
        drill = { { kind = "folder", payload = { path = "/books/scifi" } } },
    }
    assert(calls.getAll, "should have gone through getAll")
    assert(calls.getAll.path == "/books/scifi",
        "searched " .. tostring(calls.getAll.path))
    assert(not calls.getBySource, "must not fall back to the chip's source")
    assert(via == "getAll-folder", "got " .. tostring(via))
end)

t.test("a folder drill carries the chip's filter into the scan", function()
    local filter = { read_status = { unread = true } }
    local _, _, _, calls = scan{
        tab   = { source = { kind = "all" }, sort_priority = SP2, filter = filter },
        drill = { { kind = "folder", payload = { path = "/books/scifi" } } },
    }
    assert(calls.getAll.filter == filter,
        "the jump must see the same books the shelf shows")
end)

t.test("a folder drill sorts by the chip's level 2, like the shelf does", function()
    local _, key = scan{
        tab   = { source = { kind = "all" }, sort_priority = SP2 },
        drill = { { kind = "folder", payload = { path = "/books/scifi" } } },
    }
    assert(key == "title", "got " .. tostring(key))
end)

t.test("one-level chip: the key comes from the 'all' fallback getAll uses", function()
    local _, key, _, calls = scan{
        tab   = { source = { kind = "all" }, sort_priority = { { key = "filename" } } },
        drill = { { kind = "folder", payload = { path = "/books/scifi" } } },
        all_priority = { { key = "author_surname" } },
    }
    assert(calls.getAll.sort_priority == nil,
        "no level 2 means getAll picks its own default")
    assert(calls.getSortPriority == "all")
    assert(key == "author_surname", "got " .. tostring(key))
end)

t.test("the scan is light_only and unpaginated", function()
    local _, _, _, calls = scan{
        tab   = { source = { kind = "all" }, sort_priority = SP2 },
        drill = { { kind = "folder", payload = { path = "/books/scifi" } } },
        total_items = 42,
    }
    assert(calls.getAll.opts.light_only == true, "must not hydrate covers")
    assert(calls.getAll.offset == 0, "must start at the top of the listing")
    assert(calls.getAll.limit >= 10000, "got " .. tostring(calls.getAll.limit))
end)

t.test("a repo blow-up is reported, not raised", function()
    local items, _, via = scan{
        tab   = { source = { kind = "all" }, sort_priority = SP2 },
        drill = { { kind = "folder", payload = { path = "/books/scifi" } } },
        getAll_throws = true,
    }
    assert(items == nil, "no list to scan")
    assert(via:find("^getAll%-ERR:"), "got " .. tostring(via))
end)

-- ── The other views ──

t.test("no drill: the chip's own source, filter and sort", function()
    local filter = { read_status = { unread = true } }
    local _, key, via, calls = scan{
        tab = { source = { kind = "authors" }, sort_priority = SP2, filter = filter },
    }
    assert(via == "getBySource", "got " .. tostring(via))
    assert(calls.getBySource.source.kind == "authors")
    assert(calls.getBySource.filter == filter)
    assert(key == "filename", "top level sorts by level 1, got " .. tostring(key))
end)

t.test("no drill and no configured tab: falls back to the chip id", function()
    local _, _, _, calls = scan{ chip = "series" }
    assert(calls.getBySource.source.kind == "series")
end)

t.test("a group drill scans the payload's books, level 2 keyed", function()
    local books = { { title = "b" }, { title = "a" } }
    local items, key, via = scan{
        tab   = { source = { kind = "series" }, sort_priority = SP2 },
        drill = { { kind = "series", payload = { books = books } } },
    }
    assert(items == books, "the shelf's own order, already sorted")
    assert(key == "title", "got " .. tostring(key))
    assert(via == "drilldown-payload")
end)

t.test("a group drill with a one-level chip keeps that level", function()
    local books = { { title = "b" } }
    local _, key = scan{
        tab   = { source = { kind = "series" }, sort_priority = { { key = "filename" } } },
        drill = { { kind = "series", payload = { books = books } } },
    }
    assert(key == "filename", "got " .. tostring(key))
end)

t.test("an OPDS subcatalog drill scans that subcatalog's window", function()
    local _, key, via, calls = scan{
        tab   = { source = { kind = "opds", id = "srv" }, sort_priority = SP2 },
        drill = { { kind = "opds_nav",
                    payload = { server_key = "srv", feed_url = "http://x/sub" } } },
    }
    assert(via == "getBySource-opds_nav", "got " .. tostring(via))
    assert(calls.getBySource.source.feed_url == "http://x/sub",
        "got " .. tostring(calls.getBySource.source.feed_url))
    assert(calls.getBySource.source.id == "srv")
    assert(key == nil, "feed order is semantic; there is no sort key to name")
end)

t.done()
