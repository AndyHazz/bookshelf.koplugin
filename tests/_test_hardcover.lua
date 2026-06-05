-- tests/_test_hardcover.lua
-- Pure-Lua tests for Bookshelf's optional Hardcover enrichment cache.

package.path = "./?.lua;./?/init.lua;" .. package.path

local settings = {}
local hc_settings = {
    books = {},
}

package.loaded["lib/bookshelf_settings_store"] = {
    read = function(key, default)
        local v = settings["bookshelf_" .. key]
        if v == nil then return default end
        return v
    end,
    save = function(key, value)
        settings["bookshelf_" .. key] = value
    end,
    delete = function(key)
        settings["bookshelf_" .. key] = nil
    end,
    flush = function() end,
    isTrue = function(key)
        return settings["bookshelf_" .. key] == true
    end,
    nilOrTrue = function(key)
        local v = settings["bookshelf_" .. key]
        return v == nil or v == true
    end,
}

package.loaded["datastorage"] = {
    getSettingsDir = function() return "/tmp/bookshelf-hardcover-test" end,
}

package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(_path, attr)
        if attr == "mode" then return "file" end
        return nil
    end,
}

package.loaded["luasettings"] = {
    open = function(_self, path)
        assert(path == "/tmp/bookshelf-hardcover-test/hardcoversync_settings.lua",
            "unexpected settings path: " .. tostring(path))
        return {
            readSetting = function(_settings, key) return hc_settings[key] end,
            saveSetting = function(_settings, key, value) hc_settings[key] = value end,
            flush = function() end,
        }
    end,
}

package.loaded["hardcover/lib/hardcover_api"] = {
    me = function() return { id = 42 } end,
    query = function(_self, query, variables)
        if query:find("books_by_pk", 1, true) and variables.id then
            return {
                books_by_pk = {
                    id = variables.id,
                    title = "Fresh Hardcover Title",
                    rating = 4.25,
                    ratings_count = 12,
                    reviews_count = 2,
                    user_books = {
                        {
                            id = 501,
                            rating = 4,
                            review = "<p>Sharp and strange.</p>",
                            review_has_spoilers = false,
                            reviewed_at = "2026-05-01T00:00:00",
                            likes_count = 3,
                            user = { name = "Reader One", username = "readerone" },
                        },
                    },
                },
            }
        end
        if variables.ids then
            assert(variables.userId == 42, "expected fetched user id")
            return {
                books = {
                    { id = 123, rating = 4.5, ratings_count = 12,
                      reviews_count = 2, user_books = { { id = 10, rating = nil } } },
                    { id = 999, rating = nil, ratings_count = 0,
                      reviews_count = 0, user_books = { { id = 11, rating = nil } } },
                },
            }
        end
        return {
            book = {
                id = variables.bookId,
                title = "Fresh Hardcover Title",
                description = "Fresh Hardcover description.",
                rating = 4.25,
                ratings_count = 12,
                reviews_count = 2,
            },
        }
    end,
}

local Hardcover = dofile("lib/bookshelf_hardcover.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        pass = pass + 1
    else
        fail = fail + 1
        io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n")
    end
end

local function reset()
    settings = {}
    hc_settings = {
        books = {
            ["/books/a.epub"] = { book_id = 123, edition_id = 456, title = "Linked A" },
            ["/books/b.epub"] = { book_id = 999, title = "Linked B" },
        },
    }
    Hardcover.invalidate()
end

test("linkBook stores a Bookshelf-owned link", function()
    reset()
    local ok, err = Hardcover.linkBook("/books/a.epub", {
        id = 123,
        title = "A Book",
    })
    assert(ok, tostring(err))
    local link = Hardcover.getLink("/books/a.epub")
    assert(link and link.book_id == 123, "missing book_id")
    assert(link.title == "A Book", "missing title")
end)

test("enrichBook fills only missing description and missing cover", function()
    reset()
    assert(Hardcover.linkBook("/books/a.epub", { id = 123, title = "A Book" }))
    settings.bookshelf_hardcover_enrichment = {
        ["123"] = {
            description = "Cached description.",
            cover_path = "/tmp/cached-cover.jpg",
        },
    }
    Hardcover.invalidate()

    local book = Hardcover.enrichBook{
        filepath = "/books/a.epub",
        title = "A Book",
        has_cover = false,
    }
    assert(book.description == "Cached description.", tostring(book.description))
    assert(book.cover_image_path == "/tmp/cached-cover.jpg", tostring(book.cover_image_path))
    assert(book.hardcover_description == true, "description marker missing")
    assert(book.hardcover_cover == true, "cover marker missing")

    local preserved = Hardcover.enrichBook{
        filepath = "/books/a.epub",
        description = "Local description.",
        has_cover = true,
    }
    assert(preserved.description == "Local description.", "overwrote local description")
    assert(preserved.cover_image_path == nil, "overwrote local cover")
end)

test("refreshBook writes cache from Hardcover API", function()
    reset()
    assert(Hardcover.linkBook("/books/a.epub", { id = 123, title = "A Book" }))
    local ok, payload = Hardcover.refreshBook{ filepath = "/books/a.epub" }
    assert(ok, tostring(payload))
    assert(payload.description == "Fresh Hardcover description.", "bad payload")

    local book = Hardcover.enrichBook{ filepath = "/books/a.epub", has_cover = false }
    assert(book.description == "Fresh Hardcover description.", tostring(book.description))
end)

test("refreshBookOnline uses KOReader network manager when available", function()
    reset()
    local network_called = false
    package.loaded["ui/network/manager"] = {
        runWhenOnline = function(_self, callback)
            network_called = true
            callback()
        end,
    }
    assert(Hardcover.linkBook("/books/a.epub", { id = 123, title = "A Book" }))

    local callback_ok, callback_payload
    local ok = Hardcover.refreshBookOnline({ filepath = "/books/a.epub" }, {}, function(refresh_ok, payload)
        callback_ok = refresh_ok
        callback_payload = payload
    end)
    assert(ok == true, "online wrapper did not return true")
    assert(network_called == true, "NetworkMgr:runWhenOnline was not used")
    assert(callback_ok == true, tostring(callback_payload))
    assert(callback_payload.description == "Fresh Hardcover description.", "bad callback payload")
    package.loaded["ui/network/manager"] = nil
end)

test("refreshRatings fetches linked book ratings and caches them", function()
    reset()
    local ok, result = Hardcover.refreshRatings()
    assert(ok, tostring(result))
    assert(result.linked == 2, "expected two linked books")
    assert(result.rated == 1, "expected one rated book")
    assert(hc_settings.user_id == 42, "expected user id cache")
    assert(settings.bookshelf_hardcover_ratings["123"].rating == 4.5,
        "missing cached rating")
    assert(settings.bookshelf_hardcover_ratings["999"].rating == false,
        "unrated books should be cached as false")
end)

test("enrichBook adds cached Hardcover rating and review count", function()
    reset()
    settings.bookshelf_hardcover_ratings = {
        ["123"] = {
            rating = 4.5,
            ratings_count = 12,
            reviews_count = 2,
        },
    }
    Hardcover.invalidate()
    local book = Hardcover.enrichBook{ filepath = "/books/a.epub" }
    assert(book.hardcover_book_id == 123, "missing Hardcover book id")
    assert(book.hardcover_edition_id == 456, "missing Hardcover edition id")
    assert(book.hardcover_rating == 4.5, "missing Hardcover rating")
    assert(book.hardcover_reviews_count == 2, "missing reviews count")
end)

test("fetchReviews loads and caches non-spoiler Hardcover reviews", function()
    reset()
    local ok, result = Hardcover.fetchReviews(123)
    assert(ok, tostring(result))
    assert(result.title == "Fresh Hardcover Title", "missing review title")
    assert(result.reviews_count == 2, "missing review count")
    assert(#result.reviews == 1, "expected one non-spoiler review")
    assert(result.reviews[1].user_name == "Reader One", "missing reviewer")
    assert(result.reviews[1].text == "<p>Sharp and strange.</p>", "missing review text")

    local Api = package.loaded["hardcover/lib/hardcover_api"]
    local old_query = Api.query
    Api.query = function() error("reviews should come from cache") end
    local ok_cached, cached = Hardcover.fetchReviews(123)
    Api.query = old_query
    assert(ok_cached, tostring(cached))
    assert(cached.reviews[1].user_name == "Reader One", "cached review missing")
end)

test("enrichBook falls back to the reviews cache when no ratings entry exists", function()
    reset()
    -- Book is linked (book_id 123) but was linked AFTER the last ratings
    -- sweep, so there is NO entry in the ratings cache. Its aggregate rating
    -- and counts are present in the reviews cache (populated when the user
    -- opened "Reviews..."). The hero must still resolve a numeric rating.
    settings.bookshelf_hardcover_reviews = {
        ["123"] = {
            book_id = 123,
            rating = 4.17,
            ratings_count = 1561,
            reviews_count = 138,
            reviews = {},
        },
    }
    Hardcover.invalidate()

    local book = Hardcover.enrichBook{ filepath = "/books/a.epub" }
    assert(book.hardcover_rating == 4.17,
        "rating not pulled from reviews cache: " .. tostring(book.hardcover_rating))
    assert(book.hardcover_ratings_count == 1561,
        "ratings_count: " .. tostring(book.hardcover_ratings_count))
    assert(book.hardcover_reviews_count == 138,
        "reviews_count: " .. tostring(book.hardcover_reviews_count))
end)

test("enrichBook prefers the ratings cache over the reviews fallback", function()
    reset()
    settings.bookshelf_hardcover_ratings = {
        ["123"] = { rating = 4.5, ratings_count = 12, reviews_count = 2 },
    }
    settings.bookshelf_hardcover_reviews = {
        ["123"] = { book_id = 123, rating = 1.0, ratings_count = 9, reviews_count = 9 },
    }
    Hardcover.invalidate()
    local book = Hardcover.enrichBook{ filepath = "/books/a.epub" }
    assert(book.hardcover_rating == 4.5,
        "ratings cache should win: " .. tostring(book.hardcover_rating))
    assert(book.hardcover_reviews_count == 2,
        "ratings cache counts should win: " .. tostring(book.hardcover_reviews_count))
end)

test("refreshBook back-fills the ratings cache for a newly linked book", function()
    reset()
    assert(Hardcover.linkBook("/books/a.epub", { id = 123, title = "A Book" }))
    local ok, payload = Hardcover.refreshBook{ filepath = "/books/a.epub" }
    assert(ok, tostring(payload))

    local ratings = settings.bookshelf_hardcover_ratings
    assert(ratings and ratings["123"], "refreshBook wrote no ratings entry")
    assert(ratings["123"].rating == 4.25,
        "back-filled rating: " .. tostring(ratings["123"].rating))
    assert(ratings["123"].ratings_count == 12,
        "back-filled ratings_count: " .. tostring(ratings["123"].ratings_count))
    assert(ratings["123"].reviews_count == 2,
        "back-filled reviews_count: " .. tostring(ratings["123"].reviews_count))

    Hardcover.invalidate()
    local book = Hardcover.enrichBook{ filepath = "/books/a.epub" }
    assert(book.hardcover_rating == 4.25,
        "enrichBook did not surface back-filled rating: " .. tostring(book.hardcover_rating))
end)

test("refreshRatings preserves a linked book the API response omits", function()
    reset()
    -- Third linked book whose id the mock response never returns (simulating
    -- a Hasura row cap / partial fetch). Its prior good rating must survive
    -- the refresh rather than being clobbered to false.
    hc_settings.books["/books/c.epub"] = { book_id = 777, title = "Linked C" }
    settings.bookshelf_hardcover_ratings = {
        ["777"] = { rating = 4.2, ratings_count = 50, reviews_count = 9 },
    }
    Hardcover.invalidate()

    local ok = Hardcover.refreshRatings()
    assert(ok, "refreshRatings failed")
    local ratings = settings.bookshelf_hardcover_ratings
    assert(ratings["777"] and ratings["777"].rating == 4.2,
        "omitted linked entry was clobbered: "
        .. tostring(ratings["777"] and ratings["777"].rating))
    assert(ratings["123"].rating == 4.5, "returned entry not updated")
    assert(ratings["999"].rating == false, "unrated returned entry should be false")
end)

io.stdout:write(("PASS %d  FAIL %d\n"):format(pass, fail))
if fail > 0 then os.exit(1) end
