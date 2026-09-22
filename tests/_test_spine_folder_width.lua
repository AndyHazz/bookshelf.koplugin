-- tests/_test_spine_folder_width.lua
-- A folder on a spine shelf is as thick as what it holds, and says it is one.
--
-- Usage (from plugin root): lua tests/_test_spine_folder_width.lua
--
-- Issue 420: nested folders stood as narrow book-like spines, all the same
-- width whatever they held -- a folder has no page count, so the width ladder
-- fell through to an average book's -- and nothing marked them as folders, so
-- they were hard to tell from books and hard to tap. Now a folder is priced as
-- its books (at least two books thick), carries a folder mark where a book
-- shows its status, and its count where a book shows its series number.

package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local src = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")
local SpineLayout = dofile("lib/bookshelf_spine_layout.lua")

local function fn(name, args, env)
    local body = src:match("\nfunction SpineShelf%." .. name .. "%(" .. args:gsub("%p", "%%%0")
                           .. "%)\n(.-)\nend\n")
    assert(body, "SpineShelf." .. name .. " is missing")
    env = env or {}
    env.math, env.tonumber, env.pcall, env.require = math, tonumber, pcall, env.require or require
    return assert(load("return function(" .. args .. ")\n" .. body .. "\nend", name, "t", env))()
end

local width = fn("folderWidthDp", "n", { SpineLayout = SpineLayout })

t.test("a folder is priced as the books it holds", function()
    assert(width(3) > width(2), "three books no thicker than two")
    eq(width(3), SpineLayout.spineWidthDp(SpineLayout.DEFAULT_PAGES * 3))
end)

t.test("never thinner than two books: a folder is something to tap", function()
    eq(width(1), width(2))
    eq(width(0), width(2))
    eq(width(nil), width(2))
    assert(width(2) > SpineLayout.spineWidthDp(nil), "no wider than an average book")
end)

t.test("a big folder stops at the thickest spine", function()
    eq(width(50), SpineLayout.MAX_W_DP)
end)

-- ── the count ──────────────────────────────────────────────────────────────

local paths = { ["/lib/A"] = { "a1", "a2", "a3" }, ["/lib/Empty"] = {} }
local calls = 0
local count = fn("folderCount", "bk, src", {
    require = function(name)
        assert(name == "lib/bookshelf_book_repository")
        return { getFolderBookPaths = function(p) calls = calls + 1; return paths[p] end }
    end,
})

t.test("a folder standing as itself is counted, at any depth", function()
    local bk = { kind = "folder", path = "/lib/A" }
    eq(count(bk, bk), 3)
end)

t.test("counted once per record", function()
    local bk = { kind = "folder", path = "/lib/A" }
    calls = 0
    count(bk, bk); count(bk, bk)
    eq(calls, 1)
end)

t.test("a wrapper folder stands as its book, so it is not counted", function()
    local bk = { kind = "folder", path = "/lib/A" }
    eq(count(bk, { filepath = "/lib/A/a1" }), nil)
end)

t.test("a book, or an empty folder, has no count", function()
    local b = { filepath = "/x.epub" }
    eq(count(b, b), nil)
    local e = { kind = "folder", path = "/lib/Empty" }
    eq(count(e, e), nil)
end)

-- ── the wiring ─────────────────────────────────────────────────────────────

t.test("the plan widths a counted folder by its books, not the page ladder", function()
    assert(src:find("w_dp = SpineShelf.folderWidthDp(folder_n) * auto_thick", 1, true))
    assert(src:find("folder_n = SpineShelf.folderCount(bk, src),", 1, true),
        "the entry does not carry the count to the painter")
end)

t.test("the spine shows a folder mark and the count", function()
    assert(src:find("local glyph = e.folder_n and GLYPH_FOLDER or _statusGlyph(self.book)", 1, true))
    assert(src:find("local foot = e.folder_n and tostring(e.folder_n)", 1, true))
end)

t.test("the count is part of the render key", function()
    local key = src:match("\nfunction SpineBookSlot:_renderKey%(night%)\n(.-)\nend\n")
    assert(key and key:find("e.folder_n", 1, true),
        "a folder that gains a book would keep its old count painted")
end)

t.done()
