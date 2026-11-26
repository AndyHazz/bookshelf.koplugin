-- tests/_test_curated_add_place.lua
-- Where books go when they are added to a hand-ordered shelf: after the
-- books already there (the default), or in the first places.
--
-- Usage (from plugin root): lua tests/_test_curated_add_place.lua
--
-- A shelf is a KOReader collection, so ReadCollection is faked with the
-- fields and semantics KOReader's has (coll is name -> file -> item, an added
-- book is filed after the last order, write() takes the collections to
-- persist). lib/bookshelf_collection_order is the real one.

package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

package.loaded["logger"] = { dbg = function() end, info = function() end,
                             warn = function() end, err = function() end }
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
package.loaded["ui/uimanager"] = { show = function() end, close = function() end, setDirty = function() end }
package.loaded["ui/widget/sortwidget"] = { new = function(_self, o) return o end }
package.loaded["lib/bookshelf_book_repository"] = {
    invalidateBookCache = function() end,
}

local writes
local function freshCollections(books)
    writes = 0
    local coll = {}
    for i, f in ipairs(books) do coll[f] = { file = f, order = i } end
    local rc = { coll = { reads = coll }, coll_settings = { reads = { order = 1 } } }
    function rc:addItem(file, name)
        local max = 0
        for _k, it in pairs(self.coll[name]) do if it.order > max then max = it.order end end
        self.coll[name][file] = { file = file, order = max + 1 }
    end
    function rc:write() writes = writes + 1 end
    package.loaded["readcollection"] = rc
    return rc
end

local Curated = dofile("lib/bookshelf_curated.lua")

t.test("books go after the ones already there, in the order given", function()
    freshCollections({ "/b/a.epub", "/b/b.epub" })
    eq(Curated.addMany("reads", { "/b/c.epub", "/b/d.epub" }), 2)
    eq(table.concat(Curated.books("reads"), " "), "/b/a.epub /b/b.epub /b/c.epub /b/d.epub")
end)

t.test("first: they take the first places, in the order given", function()
    freshCollections({ "/b/a.epub", "/b/b.epub" })
    eq(Curated.addMany("reads", { "/b/c.epub", "/b/d.epub" }, { first = true }), 2)
    eq(table.concat(Curated.books("reads"), " "), "/b/c.epub /b/d.epub /b/a.epub /b/b.epub",
       "the new books are not in the first places, or the old ones lost their order")
end)

t.test("first: one book goes in front of the rest", function()
    freshCollections({ "/b/a.epub", "/b/b.epub", "/b/c.epub" })
    eq(Curated.addMany("reads", { "/b/z.epub" }, { first = true }), 1)
    eq(table.concat(Curated.books("reads"), " "), "/b/z.epub /b/a.epub /b/b.epub /b/c.epub")
end)

t.test("first: a book already there is passed over and does not move", function()
    freshCollections({ "/b/a.epub", "/b/b.epub" })
    eq(Curated.addMany("reads", { "/b/b.epub", "/b/c.epub" }, { first = true }), 1)
    eq(table.concat(Curated.books("reads"), " "), "/b/c.epub /b/a.epub /b/b.epub")
end)

t.test("first: nothing added changes nothing and writes nothing", function()
    freshCollections({ "/b/a.epub", "/b/b.epub" })
    eq(Curated.addMany("reads", { "/b/a.epub" }, { first = true }), 0)
    eq(writes, 0)
    eq(table.concat(Curated.books("reads"), " "), "/b/a.epub /b/b.epub")
end)

t.test("first on an empty shelf is just the books, in order", function()
    freshCollections({})
    eq(Curated.addMany("reads", { "/b/a.epub", "/b/b.epub" }, { first = true }), 2)
    eq(table.concat(Curated.books("reads"), " "), "/b/a.epub /b/b.epub")
end)

t.test("a shelf that does not exist is passed over", function()
    freshCollections({})
    eq(Curated.addMany("nope", { "/b/a.epub" }, { first = true }), 0)
end)

t.done()
