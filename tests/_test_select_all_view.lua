-- tests/_test_select_all_view.lua
-- _currentViewBookPaths: what "Select all in this shelf" resolves to (issue
-- #320). A chip built from filters is flat, so there is no folder or stack tile
-- to long-press for a group selection; this is the set that replaces it.
--
-- The method only reads fields off `self` and calls two other methods, so it is
-- exercised against a stub widget rather than the real one (which needs the
-- whole KOReader widget tree). Extracted from the source by name, so a rename
-- fails the test instead of silently skipping it.
package.path = "./?.lua;./?/init.lua;" .. package.path

local t = dofile("tests/_helpers.lua").runner()

local src = io.open("lib/bookshelf_widget.lua"):read("*a")
local body = src:match("\nfunction BookshelfWidget:_currentViewBookPaths%(%)\n(.-)\nend\n")
assert(body, "could not find BookshelfWidget:_currentViewBookPaths() - renamed?")

local function compile(code, env)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, "_currentViewBookPaths"))
        _G.setfenv(f, env)
        return f
    end
    return assert(load(code, "_currentViewBookPaths", "t", env))
end

-- self stub. The real method asks _fetchChipItems for the WHOLE view (window
-- -fetched sources return only a page otherwise), then delegates the
-- remote-record test and stack flattening.
--   items      -> what _fetchChipItems(SELECT_ALL_LIMIT, true) yields
--   page_items -> the visible-page fallback used when that fetch fails
local function paths_for(opts)
    local env = {
        type = type, pcall = pcall, pairs = pairs, ipairs = ipairs,
        SELECT_ALL_LIMIT = 5000,
    }
    local asked
    local self_tbl = {
        _isRemoteRecord = function(_self, fp)
            return type(fp) == "string" and fp:find("^OPDS://") ~= nil
        end,
        _resolveStackPaths = function(_self, group) return group.books or {} end,
        _fetchChipItems = function(_self, n, want_all)
            asked = { n = n, want_all = want_all }
            if opts.fetch_fails then error("fetch blew up") end
            return opts.items or {}
        end,
        _page_items = opts.page_items,
    }
    if opts.resolver_throws then
        self_tbl._resolveStackPaths = function() error("boom") end
    end
    local f = compile("local self = ... ; " .. body, env)
    local out = f(self_tbl)
    return out, asked
end

t.test("asks for the WHOLE view, not the visible page", function()
    local out, asked = paths_for{ items = {
        { filepath = "/b/1.epub" }, { filepath = "/b/2.epub" },
    } }
    assert(asked and asked.want_all == true,
        "must request the full set (want_all), not the page window")
    assert(asked.n == 5000, "should pass the select-all ceiling, got " .. tostring(asked.n))
    assert(#out == 2)
end)

t.test("falls back to the visible page if the full fetch fails", function()
    local out = paths_for{ fetch_fails = true,
                           page_items = { { filepath = "/b/1.epub" } } }
    assert(#out == 1 and out[1] == "/b/1.epub",
        "a failed fetch degrades to the page rather than selecting nothing")
end)

t.test("stack tiles contribute their member books, not the tile", function()
    local out = paths_for{ items = {
        { kind = "series", label = "Dune", books = { "/b/d1.epub", "/b/d2.epub" } },
        { filepath = "/b/loose.epub" },
    } }
    table.sort(out)
    assert(#out == 3, "series members + the loose book, got " .. #out)
    assert(out[1] == "/b/d1.epub" and out[3] == "/b/loose.epub")
end)

t.test("duplicates collapse (a book in two stacks is selected once)", function()
    local out = paths_for{ items = {
        { kind = "author", books = { "/b/x.epub", "/b/y.epub" } },
        { kind = "genre",  books = { "/b/y.epub", "/b/z.epub" } },
        { filepath = "/b/x.epub" },
    } }
    assert(#out == 3, "x, y, z once each; got " .. #out)
end)

t.test("remote catalog records are skipped", function()
    local out = paths_for{ items = {
        { filepath = "/b/local.epub" },
        { filepath = "OPDS://srv/urn:gutenberg:1" },
        { kind = "opds_nav", books = { "OPDS://srv/urn:gutenberg:2" } },
    } }
    assert(#out == 1 and out[1] == "/b/local.epub",
        "only the local book should be selectable")
end)

t.test("junk entries and empty views are handled", function()
    assert(#paths_for{ items = {} } == 0)
    assert(#paths_for{} == 0, "nothing fetched, no page items")
    local out = paths_for{ items = {
        "not a table", { }, { filepath = "" }, { filepath = "/b/ok.epub" },
    } }
    assert(#out == 1 and out[1] == "/b/ok.epub")
end)

t.test("a throwing stack resolver does not take the whole selection down", function()
    local out = paths_for{ resolver_throws = true, items = {
        { kind = "series", books = { "/b/a.epub" } },
        { filepath = "/b/b.epub" },
    } }
    assert(#out == 1 and out[1] == "/b/b.epub",
        "the plain book survives a failing stack resolve")
end)

t.done()
