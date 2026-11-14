-- tests/_test_curated.lua
-- lib/bookshelf_curated: a hand-ordered shelf's books (issue 390).
--
-- A Curated shelf is a KOReader collection shown as a shelf: source =
-- { kind = "collection", id = <collection name> }, sorted by the
-- collection's own order. This module is the one place that adds, removes
-- and reorders its books, on top of KOReader's ReadCollection.
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }

-- ReadCollection, with KOReader's own contract for the parts used.
local RC, writes, missing
local function newRC()
    writes, missing = 0, {}
    RC = { coll = { favorites = {} }, coll_settings = { favorites = { order = 1 } },
           default_collection_name = "favorites" }
    function RC:getCollectionNextOrder(name)
        if self.coll_settings[name].collate then return nil end
        local max = 0
        for _k, it in pairs(self.coll[name]) do if max < it.order then max = it.order end end
        return max + 1
    end
    function RC:addItem(file, name)
        assert(not missing[file], "KOReader raises on a file that is not there")
        self.coll[name][file] = { file = file, text = file:gsub(".*/", ""), order = self:getCollectionNextOrder(name) }
    end
    function RC:removeItem(file, name, no_write)
        if self.coll[name][file] then
            self.coll[name][file] = nil
            if not no_write then self:write() end
            return true
        end
    end
    function RC:addCollection(name)
        local max = 0
        for _k, s in pairs(self.coll_settings) do if max < s.order then max = s.order end end
        self.coll_settings[name] = { order = max + 1 }
        self.coll[name] = {}
    end
    function RC:write() writes = writes + 1 end
    package.loaded["readcollection"] = RC
end
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(fp) if missing[fp] then return nil end return { mode = "file" } end,
}
local invalidated, narrow = 0, {}
package.loaded["lib/bookshelf_book_repository"] = {
    invalidateBookCache = function() invalidated = invalidated + 1 end,
    invalidateCollectionCache = function(name) narrow[#narrow + 1] = name end,
}
-- KOReader keys a collection's items by the file's REAL path.
local links = {}
package.loaded["ffi/util"] = { realpath = function(fp) return links[fp] or fp end }

local C = require("lib/bookshelf_curated")
local function reset() newRC(); invalidated = 0; narrow = {}; links = {} end
local function fps(name) return table.concat(C.books(name), " ") end

-- ── Shelves are collections ─────────────────────────────────────────────────

t.test("create makes a KOReader collection with that name", function()
    reset()
    eq(C.create("Beach reads"), "Beach reads")
    assert(RC.coll["Beach reads"], "no collection")
    eq(C.exists("Beach reads"), true)
    eq(C.exists("nope"), false)
    eq(writes, 1, "not written: gone on restart")
end)

t.test("create with a name already in use hands back that collection, untouched", function()
    reset()
    C.create("TBR"); C.add("TBR", "/b/x")
    eq(C.create("TBR"), "TBR")
    eq(fps("TBR"), "/b/x")
end)

t.test("create refuses no name, and the favorites collection's name", function()
    reset()
    eq(C.create(""), nil); eq(C.create(nil), nil); eq(C.create("   "), nil)
    eq(C.create("favorites"), nil, "that one has a shelf and a card of its own")
end)

-- ── Books ───────────────────────────────────────────────────────────────────

t.test("books go on the end, in the order they were added", function()
    reset()
    C.create("s")
    eq(C.add("s", "/b/one"), true); eq(C.add("s", "/b/two"), true)
    eq(fps("s"), "/b/one /b/two")
    eq(C.has("s", "/b/two"), true); eq(C.has("s", "/b/three"), false)
    eq(C.count("s"), 2)
end)

t.test("a book is on a shelf once", function()
    reset()
    C.create("s"); C.add("s", "/b/one")
    eq(C.add("s", "/b/one"), false)
    eq(C.count("s"), 1)
end)

t.test("a file that is not on the device is refused, not an error", function()
    reset()
    C.create("s")
    missing["/b/gone"] = true
    eq(C.add("s", "/b/gone"), false)
    eq(C.count("s"), 0)
end)

t.test("adding to a collection that does not exist does nothing", function()
    reset()
    eq(C.add("ghost", "/b/one"), false)
    eq(C.exists("ghost"), false)
end)

t.test("remove takes a book off and says whether it was there", function()
    reset()
    C.create("s"); C.add("s", "/b/one"); C.add("s", "/b/two")
    eq(C.remove("s", "/b/one"), true)
    eq(C.remove("s", "/b/one"), false)
    eq(fps("s"), "/b/two")
end)

t.test("every change is written and drops the shelves' cached books", function()
    reset()
    C.create("s")
    local w, i = writes, invalidated
    C.add("s", "/b/one")
    assert(writes > w, "add not written"); assert(invalidated > i, "add left the old shelf cached")
    w, i = writes, invalidated
    C.has("s", "/b/one"); C.books("s"); C.count("s")
    eq(writes, w, "a read wrote"); eq(invalidated, i)
    C.add("s", "/b/one")
    eq(writes, w, "a change that changed nothing wrote")
end)

t.test("a book reached through a linked folder is the same book", function()
    -- /mnt/us is a link to /mnt/base-us on a Kindle; the shelf may hold
    -- either spelling, the collection holds the real one.
    reset()
    C.create("s")
    links["/link/x"] = "/real/x"
    eq(C.add("s", "/link/x"), true)
    eq(C.has("s", "/link/x"), true); eq(C.has("s", "/real/x"), true)
    eq(C.add("s", "/real/x"), false, "added twice under its two names")
    eq(C.add("s", "/link/x"), false, "re-added: it would jump to the end")
    eq(C.count("s"), 1)
    eq(C.remove("s", "/link/x"), true)
    eq(C.count("s"), 0)
end)

t.test("many books go on, or come off, with one write", function()
    reset()
    C.create("s")
    local w = writes
    eq(C.addMany("s", { "/b/a", "/b/b", "/b/a", "/b/c" }), 3)
    eq(writes, w + 1, "a write a book: seconds for a big selection on a device")
    eq(fps("s"), "/b/a /b/b /b/c")
    w = writes
    eq(C.removeMany("s", { "/b/a", "/b/zz", "/b/c" }), 2)
    eq(writes, w + 1)
    eq(fps("s"), "/b/b")
    w = writes
    eq(C.addMany("s", { "/b/b" }), 0)
    eq(writes, w, "nothing changed, nothing written")
end)

t.test("a new order drops only this collection's cached shelves", function()
    -- Authors, Series and the rest do not depend on a collection's order;
    -- dropping them made the next visit to each regroup a 1,500-book library.
    reset()
    C.create("s")
    for _i, n in ipairs({ "a", "b" }) do C.add("s", "/b/" .. n) end
    local i = invalidated
    C.setOrder("s", { "/b/b", "/b/a" })
    eq(invalidated, i, "every cache was dropped for a reorder")
    eq(narrow[#narrow], "s")
end)

-- ── Order ───────────────────────────────────────────────────────────────────

t.test("books come in the collection's own order", function()
    reset()
    C.create("s")
    RC.coll.s = {
        ["/b/c"] = { file = "/b/c", text = "c", order = 1 },
        ["/b/a"] = { file = "/b/a", text = "a", order = 3 },
        ["/b/b"] = { file = "/b/b", text = "b", order = 2 },
    }
    eq(fps("s"), "/b/c /b/b /b/a")
end)

t.test("a collection KOReader sorts itself has no order: by name, and it says so", function()
    reset()
    C.create("s")
    RC.coll_settings.s.collate = "title"
    RC.coll.s = { ["/b/z"] = { file = "/b/z", text = "z" }, ["/b/a"] = { file = "/b/a", text = "a" } }
    eq(fps("s"), "/b/a /b/z")
    eq(C.ordered("s"), false)
    RC.coll_settings.s.collate = nil
    RC.coll.s["/b/z"].order, RC.coll.s["/b/a"].order = 1, 2
    eq(C.ordered("s"), true)
end)

t.test("setOrder writes the order given, and makes the collection hand-ordered", function()
    reset()
    C.create("s")
    for _i, n in ipairs({ "a", "b", "c" }) do C.add("s", "/b/" .. n) end
    RC.coll_settings.s.collate = "title"
    eq(C.setOrder("s", { "/b/c", "/b/a", "/b/b" }), true)
    eq(fps("s"), "/b/c /b/a /b/b")
    eq(RC.coll_settings.s.collate, nil, "KOReader would go on sorting it its own way")
    eq(C.ordered("s"), true)
end)

t.test("setOrder keeps a book the caller left out, after the ones named", function()
    reset()
    C.create("s")
    for _i, n in ipairs({ "a", "b", "c" }) do C.add("s", "/b/" .. n) end
    C.setOrder("s", { "/b/c", "/b/zzz" })
    eq(fps("s"), "/b/c /b/a /b/b")
end)

t.test("move takes the book at one place to another", function()
    reset()
    C.create("s")
    for _i, n in ipairs({ "a", "b", "c", "d" }) do C.add("s", "/b/" .. n) end
    eq(C.move("s", 4, 1), true)
    eq(fps("s"), "/b/d /b/a /b/b /b/c")
    eq(C.move("s", 1, 3), true)
    eq(fps("s"), "/b/a /b/b /b/d /b/c")
    eq(C.move("s", 2, 2), false); eq(C.move("s", 9, 1), false); eq(C.move("s", 1, 0), false)
end)

t.test("move works from a given order, for a shelf shown some other way round", function()
    -- The shelf on screen is the truth when the collection has no order of
    -- its own yet: the first move starts from what the reader sees.
    reset()
    C.create("s")
    RC.coll_settings.s.collate = "title"
    RC.coll.s = { ["/b/a"] = { file = "/b/a", text = "a" }, ["/b/b"] = { file = "/b/b", text = "b" },
                  ["/b/c"] = { file = "/b/c", text = "c" } }
    eq(C.move("s", 1, 3, { "/b/c", "/b/b", "/b/a" }), true)
    eq(fps("s"), "/b/b /b/a /b/c")
end)

t.test("indexOf is a book's place", function()
    reset()
    C.create("s")
    for _i, n in ipairs({ "a", "b" }) do C.add("s", "/b/" .. n) end
    eq(C.indexOf("s", "/b/b"), 2); eq(C.indexOf("s", "/b/q"), nil)
end)

t.done()
