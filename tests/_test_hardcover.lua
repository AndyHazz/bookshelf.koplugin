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

local identifier_queries = {}
package.loaded["hardcover/lib/hardcover_api"] = {
    me = function() return { id = 42 } end,
    findBookByIdentifiers = function(_, identifiers, user_id)
        assert(user_id == 42, "expected identifier lookup user id")
        identifier_queries[#identifier_queries + 1] = identifiers
        if identifiers.isbn_13 == "9789127173133" then
            return {
                book_id = 1676691,
                edition_id = 32603971,
                edition_format = "Hardcover",
                title = "Kött",
                pages = 378,
            }
        elseif identifiers.book_slug == "flesh-2025" then
            return {
                book_id = 1676691,
                title = "Flesh",
            }
        end
        return nil
    end,
    findBooks = function(_, title, author, user_id)
        assert(title == "Example", "expected picker title search")
        assert(author == "Author", "expected picker author search")
        assert(user_id == 42, "expected picker user id")
        return {
            { book_id = 222, edition_id = 333, title = "Example" },
        }
    end,
    findEditions = function(_, book_id, user_id)
        assert(book_id == 222, "expected edition picker book id")
        assert(user_id == 42, "expected edition picker user id")
        return {
            { book_id = 222, edition_id = 444, title = "Example", edition_format = "E-Book" },
        }
    end,
    query = function(_, _query, vars)
        if _query:find("books_by_pk", 1, true) then
            assert(vars.id == 123, "expected review book id")
            assert(vars.limit == 10, "expected default review limit")
            return {
                books_by_pk = {
                    id = 123,
                    title = "Linked A",
                    rating = 4.25,
                    ratings_count = 12,
                    reviews_count = 2,
                    user_books = {
                        {
                            id = 501,
                            rating = 4,
                            review = "<p>Sharp and strange.</p>",
                            review_raw = nil,
                            review_has_spoilers = false,
                            reviewed_at = "2026-05-01T00:00:00",
                            likes_count = 3,
                            user = { name = "Reader One", username = "readerone" },
                        },
                    },
                },
            }
        end
        assert(vars.userId == 42, "user id should be fetched and cached")
        assert(#vars.ids == 2, "expected two linked Hardcover ids")
        return {
            books = {
                { id = 123, rating = 4.5, ratings_count = 12,
                  reviews_count = 2,
                  user_books = { { id = 10, rating = nil } } },
                { id = 999, rating = nil, ratings_count = 0,
                  reviews_count = 0,
                  user_books = { { id = 11, rating = nil } } },
            },
        }
    end,
}

package.loaded["hardcover/lib/hardcover_settings"] = {
    new = function(_, path, _ui)
        assert(path == "/settings/hardcoversync_settings.lua", "unexpected wrapped settings path")
        return {
            readSetting = function(_, key) return hc_settings[key] end,
            updateSetting = function(_, key, value) hc_settings[key] = value end,
            compatibilityMode = function() return true end,
        }
    end,
}

package.loaded["hardcover/lib/user"] = {
    getId = function(self)
        assert(self.settings and type(self.settings.updateSetting) == "function",
            "picker must use HardcoverSettings, not raw LuaSettings")
        local user_id = self.settings:readSetting("user_id")
        if not user_id then
            user_id = 42
            self.settings:updateSetting("user_id", user_id)
        end
        return user_id
    end,
}

local picker_state = {}
package.loaded["hardcover/lib/ui/dialog_manager"] = {
    new = function(_, o)
        local manager = o or {}
        function manager:buildSearchDialog(title, items, active_item, _book_callback, search_callback, search)
            picker_state.title = title
            picker_state.items = items
            picker_state.active_item = active_item
            picker_state.search_callback = search_callback
            picker_state.search = search
            picker_state.settings = self.settings
        end
        function manager:updateSearchResults(search)
            picker_state.updated_search = search
        end
        return manager
    end,
}

package.loaded["hardcover/lib/book"] = {
    editionFormatName = function(_, edition_format) return edition_format end,
    parseIdentifiers = function() return {} end,
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
    eq(book.hardcover_reviews_count, 2)
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

test("showBookPicker uses Hardcover settings wrapper for Hardcover dialogs", function()
    Hardcover.invalidate()
    picker_state = {}
    local ok, err = Hardcover.showBookPicker({
        filepath = "/books/e.epub",
        title = "Example",
        author = "Author",
        identifiers = "isbn:1234567890",
    })
    assert(ok, tostring(err))
    eq(picker_state.title, "Select Hardcover book")
    eq(picker_state.search, "Example")
    assert(picker_state.settings, "picker settings missing")
    assert(type(picker_state.settings.compatibilityMode) == "function",
        "dialog settings must expose compatibilityMode()")
end)

test("embedded ISBN is preferred over Hardcover slug for edition-specific links", function()
    Hardcover.invalidate()
    identifier_queries = {}
    local ok, err = Hardcover.linkFromEmbeddedIdentifiers({
        filepath = "/books/f.epub",
        identifiers = "hardcover:flesh-2025\nisbn13:978-91-27-17313-3",
    })
    assert(ok, tostring(err))
    eq(identifier_queries[1].isbn_13, "9789127173133")
    eq(identifier_queries[1].book_slug, nil)
    local link = Hardcover.getLink("/books/f.epub")
    eq(link.book_id, 1676691)
    eq(link.edition_id, 32603971)
    eq(link.edition_format, "Hardcover")
    eq(link.title, "Kött")
end)

test("fetchReviews loads and caches non-spoiler Hardcover reviews", function()
    Hardcover.invalidate()
    local ok, result = Hardcover.fetchReviews(123)
    assert(ok, tostring(result))
    eq(result.title, "Linked A")
    eq(result.reviews_count, 2)
    eq(#result.reviews, 1)
    eq(result.reviews[1].user_name, "Reader One")
    eq(result.reviews[1].text, "<p>Sharp and strange.</p>")

    package.loaded["hardcover/lib/hardcover_api"].query = function()
        error("reviews should come from cache")
    end
    local ok_cached, cached = Hardcover.fetchReviews(123)
    assert(ok_cached, tostring(cached))
    eq(cached.reviews[1].user_name, "Reader One")
end)

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
