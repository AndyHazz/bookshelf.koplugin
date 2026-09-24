-- tests/_test_quote_filters.lua
-- Issue 368: books and highlight colours left out of the quote of the day.
-- A skipped book never supplies the daily quote (its own %quote token still
-- does); a skipped colour is left out of both; and a daily pick persisted
-- before a change is not adopted after it.
package.path = "./?.lua;./?/init.lua;" .. package.path

package.loaded["lib/bookshelf_text_safe"] = { safe = function(s) return s end }
package.loaded["logger"] = { dbg = function() end, info = function() end,
                             warn = function() end, err = function() end }
local kv = {}
package.loaded["lib/bookshelf_settings_store"] = {
    read  = function(k, default) if kv[k] == nil then return default end return kv[k] end,
    save  = function(k, v) kv[k] = v end,
    delete = function(k) kv[k] = nil end,
    flush = function() end,
}
package.loaded["readhistory"] = { hist = { { file = "/grim.epub" }, { file = "/kind.epub" } } }
local BOOKS = {
    ["/grim.epub"] = { title = "Grim", ann = {
        { drawer = "lighten", text = "A grim line.", page = 1, color = "yellow" },
        { drawer = "lighten", text = "Chris", page = 2, color = "purple" },
    } },
    ["/kind.epub"] = { title = "Kind", ann = {
        { drawer = "lighten", text = "A kind line.", page = 1, color = "yellow" },
        { drawer = "underscore", text = "Alice", page = 2, color = "purple" },
        { drawer = "lighten", text = "An old line.", page = 3 },   -- no colour recorded
    } },
}
package.loaded["docsettings"] = {
    hasSidecarFile = function(_self, fp) return BOOKS[fp] ~= nil end,
    open = function(_self, fp)
        return { readSetting = function(_s, k)
            if k == "doc_props" then return { title = BOOKS[fp].title } end
            if k == "annotations" then return BOOKS[fp].ann end
        end }
    end,
}
package.loaded["lib/bookshelf_start_menu_modules"] = { menu_generation = 1 }

local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()
local eq = helpers.eq

-- Every quote the daily pick could land on: reroll through the pool.
local function pool(Q)
    local seen, n = {}, 0
    for _i = 1, 30 do
        local q = Q.ofTheDay()
        if q and not seen[q.text] then seen[q.text] = true; n = n + 1 end
        Q.reroll()
    end
    return seen, n
end

t.test("with nothing left out, every highlight is in the pool", function()
    kv = {}
    local _seen, n = pool(dofile("lib/bookshelf_quotes.lua"))
    eq(n, 5)
end)

t.test("a skipped book never supplies the daily quote", function()
    kv = {}
    local Q = dofile("lib/bookshelf_quotes.lua")
    Q.skipBook("/grim.epub")
    eq(Q.skippedBookCount(), 1)
    local seen = pool(Q)
    assert(not seen["A grim line."] and not seen["Chris"], "grim.epub still quoted")
    assert(seen["A kind line."], "the other book must still be quoted")
    -- ...but its own per-book token still draws from it.
    local q = Q.forBook("/grim.epub")
    assert(q and (q.text == "A grim line." or q.text == "Chris"))
    Q.unskipAllBooks()
    eq(Q.skippedBookCount(), 0)
end)

t.test("a skipped colour is left out of both; an uncoloured highlight stays", function()
    kv = {}
    local Q = dofile("lib/bookshelf_quotes.lua")
    Q.setColorSkipped("purple", true)
    assert(Q.isColorSkipped("purple"))
    local seen, n = pool(Q)
    assert(not seen["Chris"] and not seen["Alice"], "purple still quoted")
    eq(n, 3)
    assert(seen["An old line."], "a highlight with no colour recorded is never filtered")
    for _i = 1, 10 do
        Q.rerollBook()
        local q = Q.forBook("/kind.epub")
        assert(q and q.text ~= "Alice", "per-book token quoted a skipped colour")
    end
    Q.setColorSkipped("purple", false)
    assert(not Q.isColorSkipped("purple"))
    eq(kv.micromodule_quote_of_day_skip_colors, nil)
end)

t.test("the colours listed are every one in use, skipped or not", function()
    kv = {}
    local Q = dofile("lib/bookshelf_quotes.lua")
    Q.setColorSkipped("purple", true)
    local list = Q.coloursInUse()
    eq(table.concat(list, ","), "purple,yellow")
end)

t.test("a persisted daily pick from before a change is not adopted after it", function()
    kv = {}
    local Q = dofile("lib/bookshelf_quotes.lua")
    local first = Q.ofTheDay()
    assert(first)
    Q.skipBook(first.filepath)
    local Q2 = dofile("lib/bookshelf_quotes.lua")   -- a restart: kv survives
    local after = Q2.ofTheDay()
    assert(after and after.filepath ~= first.filepath,
        "restart adopted the persisted pick from a skipped book")
end)

t.done()
