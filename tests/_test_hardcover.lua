-- tests/_test_hardcover.lua
-- Pure-Lua tests for the optional Hardcover integration.

local store = {}
package.loaded["lib/bookshelf_settings_store"] = {
    read = function(key, default)
        local v = store[key]
        if v == nil then return default end
        return v
    end,
    save = function(key, value) store[key] = value end,
    delete = function(key) store[key] = nil end,
    isTrue = function(key) return store[key] == true end,
}

local hc_settings = {
    books = {
        ["/books/a.epub"] = { book_id = 123, edition_id = 456, title = "Linked A" },
        ["/books/b.epub"] = { book_id = 999, title = "Linked B" },
    },
}

package.loaded["datastorage"] = {
    getSettingsDir = function() return "/settings" end,
}

package.loaded["luasettings"] = {
    open = function(_, path)
        assert(path == "/settings/hardcoversync_settings.lua", "unexpected settings path: " .. tostring(path))
        return {
            readSetting = function(_, key) return hc_settings[key] end,
            saveSetting = function(_, key, value) hc_settings[key] = value end,
            flush = function() end,
        }
    end,
}

package.loaded["hardcover/lib/hardcover_api"] = {
    me = function() return { id = 42 } end,
    query = function(_, _query, vars)
        assert(vars.userId == 42, "user id should be fetched and cached")
        assert(#vars.ids == 2, "expected two linked Hardcover ids")
        return {
            books = {
                { id = 123, rating = 4.5, ratings_count = 12,
                  user_books = { { id = 10, rating = nil } } },
                { id = 999, rating = nil, ratings_count = 0,
                  user_books = { { id = 11, rating = nil } } },
            },
        }
    end,
}

local Hardcover = dofile("lib/bookshelf_hardcover.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end

local function eq(a, e, msg)
    if a ~= e then error((msg or "") .. " expected=" .. tostring(e) .. " got=" .. tostring(a), 2) end
end

test("refreshRatings fetches linked book ratings and caches them", function()
    local ok, result = Hardcover.refreshRatings()
    assert(ok, tostring(result))
    eq(result.linked, 2)
    eq(result.rated, 1)
    eq(hc_settings.user_id, 42)
    eq(store.hardcover_ratings["123"].rating, 4.5)
    eq(store.hardcover_ratings["999"].rating, false)
end)

test("enrichBook adds Hardcover link and cached rating", function()
    Hardcover.invalidate()
    local book = { filepath = "/books/a.epub" }
    Hardcover.enrichBook(book)
    eq(book.hardcover_book_id, 123)
    eq(book.hardcover_edition_id, 456)
    eq(book.hardcover_rating, 4.5)
end)

test("unrated linked book has link but no rating", function()
    Hardcover.invalidate()
    local book = { filepath = "/books/b.epub" }
    Hardcover.enrichBook(book)
    eq(book.hardcover_book_id, 999)
    eq(book.hardcover_rating, nil)
end)

test("linkBook writes Hardcover settings and invalidates read cache", function()
    Hardcover.invalidate()
    local ok, err = Hardcover.linkBook("/books/c.epub", {
        book_id = 321,
        edition_id = 654,
        edition_format = "E-Book",
        title = "Linked C",
        pages = 123,
    })
    assert(ok, tostring(err))
    local link = Hardcover.getLink("/books/c.epub")
    eq(link.book_id, 321)
    eq(link.edition_id, 654)
    eq(link.edition_format, "E-Book")
    eq(link.title, "Linked C")
    eq(link.pages, 123)
end)

test("clearLink removes the shared Hardcover link fields", function()
    local ok, err = Hardcover.clearLink("/books/c.epub")
    assert(ok, tostring(err))
    local link = Hardcover.getLink("/books/c.epub")
    eq(link.book_id, nil)
    eq(link.edition_id, nil)
    eq(link.title, nil)
end)

test("table identifiers can expose embedded Hardcover ids", function()
    local book = {
        filepath = "/books/d.epub",
        identifiers = {
            ["hardcover-id"] = 777,
            ["hardcover-edition"] = 888,
        },
    }
    local ids = Hardcover.getEmbeddedIdentifiers(book)
    assert(ids:find("hardcover%-id:777"), ids)
    assert(ids:find("hardcover%-edition:888"), ids)
    assert(Hardcover.hasHardcoverIdentifiers(book))
end)

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
