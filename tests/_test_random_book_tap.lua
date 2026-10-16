-- tests/_test_random_book_tap.lua
-- Random book's tap setting: "Show book in top panel" (default) loads the
-- pick into the top panel and keeps the menu open to roll another; "Open book
-- directly" opens it, with the menu closing first (keep_open false).
package.path = "./?.lua;./?/init.lua;" .. package.path
local t  = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq

local store = {}
package.loaded["lib/bookshelf_settings_store"] = {
    read = function(k, d) if store[k] == nil then return d end return store[k] end,
    save = function(k, v) store[k] = v end,
}
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
package.loaded["lib/bookshelf_text_safe"] = { safe = function(s) return s end }
package.loaded["libs/libkoreader-lfs"] = { attributes = function() return "file" end }
local opened_by_reader
package.loaded["apps/reader/readerui"] = { instance = nil,
    showReader = function(_s, fp) opened_by_reader = fp end }

local M = dofile("micromodules/random_unread.lua")

-- The module keeps its pick in an upvalue; put a book there as render would.
local function setPick(book)
    local f, i = M.on_tap, 1
    while true do
        local name = debug.getupvalue(f, i)
        if not name then error("on_tap no longer reads _pick_cache") end
        if name == "_pick_cache" then debug.setupvalue(f, i, { at = os.time(), book = book, die = 1 }); return end
        i = i + 1
    end
end

local function shelf()
    local bw = { calls = {} }
    function bw:_previewBook(b) self.calls[#self.calls + 1] = "preview:" .. b.filepath end
    function bw:_openBook(b) self.calls[#self.calls + 1] = "open:" .. b.filepath end
    return bw
end

t.test("default: the top panel, with the menu kept open", function()
    store = {}
    eq(M.keep_open(), true)
    local bw = shelf(); setPick({ filepath = "/b/a.epub" })
    M.on_tap({ bw = bw })
    eq(table.concat(bw.calls, ","), "preview:/b/a.epub")
end)

t.test("Open book directly: opens it, and the menu does not stay", function()
    store = { micromodule_random_unread_tap = "open" }
    eq(M.keep_open(), false)
    local bw = shelf(); setPick({ filepath = "/b/a.epub" })
    M.on_tap({ bw = bw })
    eq(table.concat(bw.calls, ","), "open:/b/a.epub")
end)

t.test("Open book directly without a shelf goes straight to the reader", function()
    store = { micromodule_random_unread_tap = "open" }
    opened_by_reader = nil
    setPick({ filepath = "/b/c.epub" })
    M.on_tap({})
    eq(opened_by_reader, "/b/c.epub")
end)

t.test("an unknown stored value is the default", function()
    store = { micromodule_random_unread_tap = "something" }
    eq(M.keep_open(), true)
end)

t.done()
