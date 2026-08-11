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

-- self stub: the two collaborators are the remote-record test and the stack
-- resolver, both of which the real method delegates to.
local function paths_for(fields)
    local env = { type = type, pcall = pcall, pairs = pairs, ipairs = ipairs }
    local self_tbl = {
        _isRemoteRecord = function(_self, fp)
            return type(fp) == "string" and fp:find("^OPDS://") ~= nil
        end,
        _resolveStackPaths = function(_self, group) return group.books or {} end,
    }
    for k, v in pairs(fields) do self_tbl[k] = v end
    local f = compile("local self = ... ; " .. body, env)
    return f(self_tbl)
end

t.test("flat chip: every book across ALL pages, not just the visible page", function()
    local out = paths_for{
        _draft_items_cache = { all_items = {
            { filepath = "/b/1.epub" }, { filepath = "/b/2.epub" },
            { filepath = "/b/3.epub" }, { filepath = "/b/4.epub" },
        } },
        _page_items = { { filepath = "/b/1.epub" }, { filepath = "/b/2.epub" } },
    }
    assert(#out == 4, "expected the whole fetched set (4), got " .. #out)
end)

t.test("falls back to the visible page when no fetch cache exists yet", function()
    local out = paths_for{ _page_items = { { filepath = "/b/1.epub" } } }
    assert(#out == 1 and out[1] == "/b/1.epub")
end)

t.test("stack tiles contribute their member books, not the tile", function()
    local out = paths_for{
        _draft_items_cache = { all_items = {
            { kind = "series", label = "Dune", books = { "/b/d1.epub", "/b/d2.epub" } },
            { filepath = "/b/loose.epub" },
        } },
    }
    table.sort(out)
    assert(#out == 3, "series members + the loose book, got " .. #out)
    assert(out[1] == "/b/d1.epub" and out[3] == "/b/loose.epub")
end)

t.test("duplicates collapse (a book in two stacks is selected once)", function()
    local out = paths_for{
        _draft_items_cache = { all_items = {
            { kind = "author", books = { "/b/x.epub", "/b/y.epub" } },
            { kind = "genre",  books = { "/b/y.epub", "/b/z.epub" } },
            { filepath = "/b/x.epub" },
        } },
    }
    assert(#out == 3, "x, y, z once each; got " .. #out)
end)

t.test("remote catalog records are skipped", function()
    local out = paths_for{
        _draft_items_cache = { all_items = {
            { filepath = "/b/local.epub" },
            { filepath = "OPDS://srv/urn:gutenberg:1" },
            { kind = "opds_nav", books = { "OPDS://srv/urn:gutenberg:2" } },
        } },
    }
    assert(#out == 1 and out[1] == "/b/local.epub",
        "only the local book should be selectable")
end)

t.test("junk entries and empty views are handled", function()
    assert(#paths_for{ _draft_items_cache = { all_items = {} } } == 0)
    assert(#paths_for{} == 0, "no cache and no page items")
    local out = paths_for{
        _draft_items_cache = { all_items = {
            "not a table", { }, { filepath = "" }, { filepath = "/b/ok.epub" },
        } },
    }
    assert(#out == 1 and out[1] == "/b/ok.epub")
end)

t.test("a throwing stack resolver does not take the whole selection down", function()
    local env = { type = type, pcall = pcall, pairs = pairs, ipairs = ipairs }
    local f = compile("local self = ... ; " .. body, env)
    local out = f{
        _isRemoteRecord = function() return false end,
        _resolveStackPaths = function() error("boom") end,
        _draft_items_cache = { all_items = {
            { kind = "series", books = { "/b/a.epub" } },
            { filepath = "/b/b.epub" },
        } },
    }
    assert(#out == 1 and out[1] == "/b/b.epub",
        "the plain book survives a failing stack resolve")
end)

t.done()
