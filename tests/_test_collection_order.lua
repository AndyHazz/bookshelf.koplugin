-- tests/_test_collection_order.lua
-- Arranging a KOReader collection from the shelf's sort picker.
--
-- Usage (from plugin root): lua tests/_test_collection_order.lua
--
-- The collection-order sort key (issue #441) files a collection shelf the way
-- KOReader does, but the only way to CHANGE that order was KOReader's own
-- collections view: Collections > the collection > menu > Arrange books in
-- collection > Manual sorting. The maintainer asked for it beside the key it
-- drives.
--
-- KOReader's window cannot simply be called. FileManagerCollection's arrange
-- dialog reads the file manager's open booklist (self.booklist_menu), which
-- does not exist while the shelf is up. Its manual-sort branch is small,
-- though -- a SortWidget, then write each item's position as its `order`,
-- then mark the collection manually collated -- and that is what this module
-- does, the same way.
--
-- ReadCollection is faked with the fields and semantics KOReader's has: coll
-- is name -> file -> item, coll_settings carries collate, and write() takes
-- the set of collections to persist.

package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

package.loaded["logger"] = { dbg = function() end, info = function() end,
                             warn = function() end, err = function() end }
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }

local written
local function freshCollections()
    written = nil
    local rc = {
        coll = {
            discworld = {
                ["/b/03 Equal Rites.epub"]      = { file = "/b/03 Equal Rites.epub",      order = 1 },
                ["/b/02 The Light Fantastic.epub"] = { file = "/b/02 The Light Fantastic.epub", order = 2 },
                ["/b/01 The Colour of Magic.epub"] = { file = "/b/01 The Colour of Magic.epub", order = 3 },
            },
            -- A collection with a collate of its own: KOReader saved no order.
            unordered = {
                ["/b/Zed.epub"]   = { file = "/b/Zed.epub" },
                ["/b/Alpha.epub"] = { file = "/b/Alpha.epub" },
                ["/b/mid.epub"]   = { file = "/b/mid.epub" },
            },
            favorites = {},
        },
        coll_settings = {
            discworld = { order = 2 },
            unordered = { order = 3, collate = "natural", collate_reverse = true },
            favorites = { order = 1 },
        },
    }
    function rc:write(updated) written = updated end
    package.loaded["readcollection"] = rc
    return rc
end

local shown
package.loaded["ui/uimanager"] = { show = function(_self, w) shown = w end,
                                   close = function() end,
                                   setDirty = function() end }
package.loaded["ui/widget/sortwidget"] = {
    new = function(_self, o) o.is_sort_widget = true; return o end,
}

local Order = dofile("lib/bookshelf_collection_order.lua")

local function texts(items)
    local out = {}
    for i, it in ipairs(items) do out[i] = it.text end
    return table.concat(out, " | ")
end

-- ── exists ────────────────────────────────────────────────────────────────

t.test("a real collection is arrangeable", function()
    freshCollections()
    eq(Order.exists("discworld"), true)
end)

t.test("a pinned tag chip is not: it is kind 'collection' with no collection behind it", function()
    -- The editor maps "Specific tag..." to kind = collection with the TAG as
    -- the id. There is nothing to arrange, so no button should offer to.
    freshCollections()
    eq(Order.exists("sci-fi"), false)
    eq(Order.exists(nil), false)
end)

-- ── items ─────────────────────────────────────────────────────────────────

t.test("the window opens in the order KOReader files the collection", function()
    freshCollections()
    eq(texts(Order.items("discworld")),
       "03 Equal Rites.epub | 02 The Light Fantastic.epub | 01 The Colour of Magic.epub",
       "the arrangement did not start from the collection's own order")
end)

t.test("each item names its file by basename, as KOReader's window does", function()
    freshCollections()
    local first = Order.items("discworld")[1]
    eq(first.file, "/b/03 Equal Rites.epub")
    eq(first.text, "03 Equal Rites.epub")
end)

t.test("a collection with no manual order starts alphabetical, case-blind", function()
    -- KOReader writes `order` only for a manually collated collection, so a
    -- collated one arrives with none. KOReader starts from whatever its
    -- collate showed; the nearest thing here that needs no copy of every
    -- collate is its default, a name order.
    freshCollections()
    eq(texts(Order.items("unordered")), "Alpha.epub | mid.epub | Zed.epub")
end)

t.test("a missing collection gives an empty arrangement, not an error", function()
    freshCollections()
    eq(#Order.items("nope"), 0)
end)

-- ── save ──────────────────────────────────────────────────────────────────

t.test("saving writes each book's new position as its order", function()
    local rc = freshCollections()
    local items = Order.items("discworld")
    -- The reader drags The Colour of Magic to the top.
    local reordered = { items[3], items[1], items[2] }
    Order.save("discworld", reordered)
    local c = rc.coll.discworld
    eq(c["/b/01 The Colour of Magic.epub"].order, 1)
    eq(c["/b/03 Equal Rites.epub"].order, 2)
    eq(c["/b/02 The Light Fantastic.epub"].order, 3)
end)

t.test("saving makes the collection manually collated, as KOReader's does", function()
    -- Without this KOReader would go on filing it by its old collate, and
    -- write() would persist NO order at all (it keeps `order` only when the
    -- collate is manual).
    local rc = freshCollections()
    Order.save("unordered", Order.items("unordered"))
    eq(rc.coll_settings.unordered.collate, nil, "the collate survived the save")
    eq(rc.coll_settings.unordered.collate_reverse, nil)
    eq(rc.coll_settings.unordered.order, 3, "the collection's own place in the list moved")
end)

t.test("saving persists that one collection and no other", function()
    freshCollections()
    Order.save("discworld", Order.items("discworld"))
    assert(written and written.discworld == true, "the arrangement was not written")
    for name in pairs(written) do
        assert(name == "discworld", "an untouched collection was rewritten: " .. name)
    end
end)

t.test("a book removed while the window was open is skipped, not a crash", function()
    -- KOReader's updateCollectionOrder indexes coll[item.file] blind.
    local rc = freshCollections()
    local items = Order.items("discworld")
    rc.coll.discworld["/b/02 The Light Fantastic.epub"] = nil
    Order.save("discworld", items)
    eq(rc.coll.discworld["/b/01 The Colour of Magic.epub"].order, 2,
        "the positions left a gap where the removed book was")
end)

t.test("a book added while the window was open goes after the arranged ones", function()
    -- It is in the collection but not in the arrangement, so its old order
    -- would collide with a new position. It keeps its place relative to any
    -- other latecomer, after everything the reader actually arranged.
    local rc = freshCollections()
    local items = Order.items("discworld")
    rc.coll.discworld["/b/04 Mort.epub"] = { file = "/b/04 Mort.epub", order = 1 }
    Order.save("discworld", items)
    eq(rc.coll.discworld["/b/04 Mort.epub"].order, 4,
        "a latecomer collided with an arranged book's position")
    eq(rc.coll.discworld["/b/03 Equal Rites.epub"].order, 1)
end)

-- ── arrange ───────────────────────────────────────────────────────────────

t.test("arrange opens KOReader's sort window, under KOReader's own title", function()
    -- The native window's title, so KOReader's own catalogue translates it
    -- in every language rather than this plugin's needing a new string.
    freshCollections()
    shown = nil
    Order.arrange("discworld")
    assert(shown and shown.is_sort_widget, "no sort window was shown")
    eq(shown.title, "Arrange books in collection")
    eq(texts(shown.item_table),
       "03 Equal Rites.epub | 02 The Light Fantastic.epub | 01 The Colour of Magic.epub")
end)

t.test("confirming saves the order and tells the caller", function()
    local rc = freshCollections()
    shown = nil
    local saved = false
    Order.arrange("discworld", function() saved = true end)
    local it = shown.item_table
    shown.item_table = { it[3], it[1], it[2] }
    shown:callback()
    eq(rc.coll.discworld["/b/01 The Colour of Magic.epub"].order, 1)
    eq(saved, true, "the caller was not told the order changed")
end)

t.test("closing without confirming changes nothing", function()
    -- SortWidget calls back only on its tick; cancel and close just close.
    local rc = freshCollections()
    shown = nil
    Order.arrange("discworld")
    eq(rc.coll.discworld["/b/03 Equal Rites.epub"].order, 1)
    eq(written, nil, "the collection was written without a confirm")
end)

t.test("arrange on something that is not a collection shows nothing", function()
    freshCollections()
    shown = nil
    Order.arrange("sci-fi")
    eq(shown, nil, "an empty sort window was opened for a tag")
end)

t.done()
