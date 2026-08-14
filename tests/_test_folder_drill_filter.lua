-- tests/_test_folder_drill_filter.lua
-- _fetchChipItems, folder-drill branch: what a chip passes down when the user
-- opens a subfolder (#323).
--
-- A filter is a property of the CHIP ("this shelf shows unread books"), so it
-- has to survive the drill exactly as the chip's sort does. It didn't: the
-- drill handed Repo.getAll a nil filter, so finished books that were hidden
-- on the chip's own listing came back the moment you opened a folder in it.
--
-- Driven against the real method body, extracted by name and run under a stub
-- `self` plus a stub Repo (as _test_select_all_view does).
package.path = "./?.lua;./?/init.lua;" .. package.path

local t = dofile("tests/_helpers.lua").runner()

local src  = io.open("lib/bookshelf_widget.lua"):read("*a")
local body = src:match("\nfunction BookshelfWidget:_fetchChipItems%(n, want_all%)\n(.-)\nend\n")
assert(body, "could not find BookshelfWidget:_fetchChipItems() - renamed?")

local function compile(code, env)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, "_fetchChipItems"))
        _G.setfenv(f, env)
        return f
    end
    return assert(load(code, "_fetchChipItems", "t", env))
end

-- Fetch one page of a drilled folder. opts:
--   tab        - what TabModel.getById returns for the active chip
--   path       - the drilled-into folder
--   cursor     - 1-based shelf cursor
--   want_all   - the "Select all in this shelf" widening
-- Returns the recorded Repo.getAll arguments.
local function drill(opts)
    local got
    local Repo = {
        getAll = function(path, limit, offset, sort_priority, filter, o)
            got = { path = path, limit = limit, offset = offset,
                    sort_priority = sort_priority, filter = filter, opts = o }
            return {}, 0
        end,
    }
    local env = {
        require = function(name)
            if name == "lib/bookshelf_tab_model" then
                return { getById = function() return opts.tab end }
            end
            error("unexpected require: " .. name)
        end,
        Repo = Repo, math = math, ipairs = ipairs,
        SELECT_ALL_LIMIT = 5000,
    }
    local self_tbl = {
        chip            = "library",
        _cursor         = opts.cursor or 1,
        _viewSize       = function() return opts.view or 8 end,
        _drilldown_path = { { kind = "folder", payload = { path = opts.path or "/books/scifi" } } },
    }
    local f = compile("local self, n, want_all = ... ; " .. body, env)
    f(self_tbl, 400, opts.want_all)
    return got
end

local FILTER = { read_status = { unread = true } }
local SP2    = { { key = "filename" }, { key = "title" } }

t.test("the chip's filter is inherited by the drilled folder", function()
    local got = drill{ tab = { source = { kind = "all" }, filter = FILTER,
                               sort_priority = SP2 } }
    assert(got.filter == FILTER,
        "a filtered chip must stay filtered one level in")
end)

t.test("no filter on the chip stays no filter", function()
    local got = drill{ tab = { source = { kind = "all" }, sort_priority = SP2 } }
    assert(got.filter == nil, "got " .. tostring(got.filter))
end)

t.test("an unconfigured chip does not blow up on the filter lookup", function()
    local got = drill{ tab = nil }
    assert(got and got.filter == nil)
end)

t.test("levels 2+ still drive the within-folder sort", function()
    local got = drill{ tab = { source = { kind = "all" }, sort_priority = SP2 } }
    assert(got.sort_priority and #got.sort_priority == 1
           and got.sort_priority[1].key == "title",
        "expected the chip's level 2 only")
end)

t.test("a one-level chip hands getAll no priority at all", function()
    local got = drill{ tab = { source = { kind = "all" },
                               sort_priority = { { key = "filename" } } } }
    assert(got.sort_priority == nil, "getAll picks its own default")
end)

t.test("the drilled path is the one fetched, and the cursor pages it", function()
    local got = drill{ tab = { source = { kind = "all" } },
                       path = "/books/scifi/asimov", cursor = 9, view = 8 }
    assert(got.path == "/books/scifi/asimov", "got " .. tostring(got.path))
    assert(got.offset == 8, "cursor 9 is offset 8, got " .. tostring(got.offset))
    assert(got.limit == 8, "one page, got " .. tostring(got.limit))
end)

t.test("select-all widens the window and still inherits the filter", function()
    local got = drill{ tab = { source = { kind = "all" }, filter = FILTER },
                       cursor = 9, want_all = true }
    assert(got.offset == 0 and got.limit == 5000)
    assert(got.filter == FILTER, "selecting all must not select filtered-out books")
end)

t.done()
