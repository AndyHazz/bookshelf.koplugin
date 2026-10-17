-- tests/_test_subshelf_count.lua
-- The stack count badge on a shelf of shelves' tiles (issue 527). A tile has
-- no folder on disk to walk, so _subShelfItems hands it the distinct local
-- books of its shelf (_subShelfMemberFps), and only when the badge's folder
-- setting would show them -- the walk is a full fetch of every shelf inside.
--
-- Usage (from plugin root): lua tests/_test_subshelf_count.lua

package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local src = io.open("lib/bookshelf_widget.lua"):read("a")
local body = src:match("(function BookshelfWidget:_subShelfMemberFps%(tab%).-\nend\n)")
assert(body, "_subShelfMemberFps is missing")

local tabs, by_source, fetches, folders = {}, {}, {}, {}
local TabModel = {
    isShelves = function(tb) return type(tb) == "table" and type(tb.source) == "table"
        and tb.source.kind == "shelves" end,
    childrenOf = function(id)
        local out = {}
        for _i, tb in ipairs(tabs) do if tb.parent == id then out[#out + 1] = tb end end
        return out
    end,
}
local Repo = {
    getBySource = function(source, _filter, sort, _off, _lim, opts)
        fetches[#fetches + 1] = { kind = source.kind, sort = sort, opts = opts }
        return by_source[source.id or source.kind] or {}
    end,
    getFolderBookPaths = function(path) return folders[path] end,
}
local env = setmetatable({
    Repo = Repo, SPINE_ALL_LIMIT = 1000000,
    require = function(name)
        if name == "lib/bookshelf_tab_model" then return TabModel end
        return require(name)
    end,
}, { __index = _G })
local BookshelfWidget = {}
local chunk = assert(load("local BookshelfWidget = ...\n" .. body, "=member_fps", "t", env))
chunk(BookshelfWidget)
local W = BookshelfWidget

local function sorted(list) table.sort(list); return table.concat(list, ",") end

t.test("a shelf counts its books, a grouped shelf its groups' members", function()
    tabs = {}
    by_source = {
        C = { { filepath = "/a" }, { filepath = "/b" } },
        authors = { { kind = "author", books = { { filepath = "/c" }, { filepath = "/d" } } } },
    }
    eq(sorted(W._subShelfMemberFps(W, { id = "x", source = { kind = "collection", id = "C" } })), "/a,/b")
    eq(sorted(W._subShelfMemberFps(W, { id = "y", source = { kind = "authors" } })), "/c,/d")
end)

t.test("Home's folder cards count what is inside them", function()
    tabs = {}
    by_source = { all = { { kind = "folder", path = "/lib/Fiction" }, { filepath = "/top.epub" } } }
    folders = { ["/lib/Fiction"] = { "/lib/Fiction/1.epub", "/lib/Fiction/2.epub" } }
    eq(sorted(W._subShelfMemberFps(W, { id = "h", source = { kind = "all" } })),
       "/lib/Fiction/1.epub,/lib/Fiction/2.epub,/top.epub")
end)

t.test("a shelf of shelves sums its shelves, counting a shared book once", function()
    tabs = {
        { id = "in", parent = "sos", source = { kind = "shelves" } },
        { id = "p", parent = "sos", source = { kind = "collection", id = "P" } },
        { id = "q", parent = "in", source = { kind = "collection", id = "Q" } },
    }
    by_source = { P = { { filepath = "/1" }, { filepath = "/2" } },
                  Q = { { filepath = "/2" }, { filepath = "/3" } } }
    eq(sorted(W._subShelfMemberFps(W, { id = "sos", source = { kind = "shelves" } })), "/1,/2,/3")
end)

t.test("an OPDS shelf and remote records count nothing", function()
    tabs, fetches = {}, {}
    eq(#W._subShelfMemberFps(W, { id = "o", source = { kind = "opds", id = "O" } }), 0)
    eq(#fetches, 0, "an OPDS shelf must not be fetched for a count")
    by_source = { R = { { filepath = "https://x/1" }, { filepath = "/local" } } }
    eq(sorted(W._subShelfMemberFps(W, { id = "r", source = { kind = "collection", id = "R" } })), "/local")
end)

t.test("the fetch is light and under the shelf's own sort (the cached list)", function()
    tabs, fetches = {}, {}
    by_source = { C = {} }
    local sort = { { key = "title" } }
    W._subShelfMemberFps(W, { id = "x", source = { kind = "collection", id = "C" }, sort_priority = sort })
    eq(fetches[1].sort, sort)
    eq(fetches[1].opts.light_only, true)
end)

t.test("the tiles only pay for it when the folder badge shows", function()
    local items = src:match("function BookshelfWidget:_subShelfItems.-\nend\n")
    assert(items:match('want_count = %(mode == "folders" or mode == "all"%)'),
        "the count is not gated on the folder badge setting")
    assert(items:match("member_fps%s*=%s*want_count and self:_subShelfMemberFps%(c%)"),
        "the tile does not carry its members")
    local row = io.open("lib/bookshelf_shelf_row.lua"):read("a")
    assert(row:match("elseif item%.member_fps then%s*%-%-[^\n]*\n[^\n]*\n%s*folder_fpaths = item%.member_fps"),
        "the cover badge ignores a sub-shelf's members")
end)

t.done()
