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

package.loaded["logger"] = {
    dbg = function() end, info = function() end,
    warn = function() end, err = function() end,
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

-- enrichBook's use_cover path and the sidecar helpers go through DocSettings.
-- Minimal stub: no pre-existing custom cover, writes are no-ops.
package.loaded["docsettings"] = {
    findCustomCoverFile = function() return nil end,
    getSidecarDir       = function() return "/tmp/bookshelf-hardcover-test" end,
    flushCustomCover    = function() return true end,
    getCustomCoverFile  = function() return nil end,
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

test("enrichBook shows Hardcover cover/description only on an explicit flag", function()
    reset()
    -- /books/a.epub is linked via reset() (book_id 123, edition 456). Mutate
    -- that link's flags directly rather than via linkBook, which would create a
    -- shadowing internal link.
    settings.bookshelf_hardcover_enrichment = {
        ["123:456"] = {
            description = "Cached description.",
            cover_path = "/tmp/cached-cover.jpg",
        },
    }
    Hardcover.invalidate()

    -- Unset flags: nothing is adopted, even though the book has no cover or
    -- description of its own (there is no live "fill when missing" any more).
    local none = Hardcover.enrichBook{
        filepath = "/books/a.epub", title = "A Book", has_cover = false,
    }
    assert(none.description == nil, "adopted a description with no explicit flag")
    assert(none.cover_image_path == nil, "adopted a cover with no explicit flag")

    -- Explicit flags on: adopt the cached values (cover falls back to the
    -- download path since the stub reports no custom .sdr cover).
    hc_settings.books["/books/a.epub"].use_description = true
    hc_settings.books["/books/a.epub"].use_cover       = true
    Hardcover.invalidate()
    local book = Hardcover.enrichBook{
        filepath = "/books/a.epub", title = "A Book", has_cover = false,
    }
    assert(book.description == "Cached description.", tostring(book.description))
    assert(book.cover_image_path == "/tmp/cached-cover.jpg", tostring(book.cover_image_path))
    assert(book.hardcover_description == true, "description marker missing")
    assert(book.hardcover_cover == true, "cover marker missing")

    -- Explicit off: the book's own values are left intact.
    hc_settings.books["/books/a.epub"].use_description = false
    hc_settings.books["/books/a.epub"].use_cover       = false
    Hardcover.invalidate()
    local preserved = Hardcover.enrichBook{
        filepath = "/books/a.epub", description = "Local description.", has_cover = true,
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

-- ─── Pass-2 link-time auto-decision ──────────────────────────────────────────
-- autoDecideFlags is tested in isolation by stubbing the two setters (the real
-- ones touch DocSettings, which isn't mocked here) and asserting the decision.

test("autoDecideFlags enables both overrides for a coverless, descriptionless book", function()
    reset()
    local orig_c, orig_d = Hardcover.setUseCover, Hardcover.setUseDescription
    local calls = {}
    Hardcover.setUseCover       = function(_fp, en) calls.cover = en; return true end
    Hardcover.setUseDescription = function(_fp, en) calls.desc  = en; return true end
    Hardcover.autoDecideFlags(
        { filepath = "/books/a.epub", has_cover = false, description = nil },
        { description = "From Hardcover", cover_path = "/tmp/x.jpg",
          cover_width = 800, cover_height = 1200 })
    Hardcover.setUseCover, Hardcover.setUseDescription = orig_c, orig_d
    assert(calls.cover == true, "cover should auto-enable when the book has none")
    assert(calls.desc  == true, "description should auto-enable when the book has none")
end)

test("autoDecideFlags keeps a higher-resolution embedded cover", function()
    reset()
    local orig_c = Hardcover.setUseCover
    local called = false
    Hardcover.setUseCover = function() called = true; return true end
    Hardcover.autoDecideFlags(
        { filepath = "/books/a.epub", has_cover = true, cover_sizetag = "1600x2400" },
        { cover_path = "/tmp/x.jpg", cover_width = 800, cover_height = 1200 })
    Hardcover.setUseCover = orig_c
    assert(not called, "should not swap when the embedded cover is larger")
end)

test("autoDecideFlags adopts a higher-resolution Hardcover cover", function()
    reset()
    local orig_c = Hardcover.setUseCover
    local en
    Hardcover.setUseCover = function(_fp, e) en = e; return true end
    Hardcover.autoDecideFlags(
        { filepath = "/books/a.epub", has_cover = true, cover_sizetag = "400x600" },
        { cover_path = "/tmp/x.jpg", cover_width = 1000, cover_height = 1500 })
    Hardcover.setUseCover = orig_c
    assert(en == true, "should adopt Hardcover when its cover is larger")
end)

test("autoDecideFlags keeps the embedded cover when sizes can't be compared", function()
    reset()
    local orig_c = Hardcover.setUseCover
    local called = false
    Hardcover.setUseCover = function() called = true; return true end
    Hardcover.autoDecideFlags(
        { filepath = "/books/a.epub", has_cover = true, cover_sizetag = nil },
        { cover_path = "/tmp/x.jpg" })  -- no HC dimensions either
    Hardcover.setUseCover = orig_c
    assert(not called, "unknown dimensions must not trigger a swap")
end)

test("autoDecideFlags records keep-own decisions as explicit false", function()
    reset()
    -- Larger embedded cover + the book's own description: keep both, but record
    -- the decision as explicit false (not nil) so a refresh sees it as decided.
    Hardcover.autoDecideFlags(
        { filepath = "/books/a.epub", has_cover = true, cover_sizetag = "1600x2400",
          description = "Own description" },
        { description = "HC desc", cover_path = "/tmp/x.jpg",
          cover_width = 400, cover_height = 600 })
    local link = Hardcover.getLink("/books/a.epub")
    assert(link.use_cover == false, "keep-own cover should record explicit false")
    assert(link.use_description == false, "keep-own description should record explicit false")
end)

test("autoDecideFlags never overrides an explicit user choice", function()
    reset()
    hc_settings.books["/books/a.epub"].use_cover       = false
    hc_settings.books["/books/a.epub"].use_description = true
    Hardcover.invalidate()
    local orig_c, orig_d = Hardcover.setUseCover, Hardcover.setUseDescription
    local touched = false
    Hardcover.setUseCover       = function() touched = true; return true end
    Hardcover.setUseDescription = function() touched = true; return true end
    Hardcover.autoDecideFlags(
        { filepath = "/books/a.epub", has_cover = false, description = nil },
        { description = "x", cover_path = "/tmp/x.jpg", cover_width = 9, cover_height = 9 })
    Hardcover.setUseCover, Hardcover.setUseDescription = orig_c, orig_d
    assert(not touched, "a decided flag (true/false) must not be re-touched")
end)

test("autoDecideFlags applies the defaults unconditionally (no global gate)", function()
    reset()
    -- The old global fill switches are gone; even with their former keys set
    -- false, the auto-decision still adopts a missing cover/description.
    settings.bookshelf_hardcover_fill_covers       = false
    settings.bookshelf_hardcover_fill_descriptions = false
    local orig_c, orig_d = Hardcover.setUseCover, Hardcover.setUseDescription
    local calls = {}
    Hardcover.setUseCover       = function(_fp, en) calls.cover = en; return true end
    Hardcover.setUseDescription = function(_fp, en) calls.desc  = en; return true end
    Hardcover.autoDecideFlags(
        { filepath = "/books/a.epub", has_cover = false, description = nil },
        { description = "x", cover_path = "/tmp/x.jpg", cover_width = 9, cover_height = 9 })
    Hardcover.setUseCover, Hardcover.setUseDescription = orig_c, orig_d
    assert(calls.cover == true, "cover default must apply with no global gate")
    assert(calls.desc  == true, "description default must apply with no global gate")
end)

-- ─── Per-book flag display ───────────────────────────────────────────────────

test("getEnrichmentFlags reflects the explicit per-book flags", function()
    reset()
    -- No flag set -> off (a Hardcover cover only shows on an explicit flag now).
    local f = Hardcover.getEnrichmentFlags("/books/a.epub")
    assert(f and f.use_cover == false,       "unset cover flag should read as off")
    assert(f and f.use_description == false,  "unset description flag should read as off")
    -- Explicit flags are reflected verbatim.
    hc_settings.books["/books/a.epub"].use_cover       = true
    hc_settings.books["/books/a.epub"].use_description = false
    Hardcover.invalidate()
    local g = Hardcover.getEnrichmentFlags("/books/a.epub")
    assert(g and g.use_cover == true,        "explicit on should read as on")
    assert(g and g.use_description == false,  "explicit off should read as off")
end)

test("enrichBook applies Hardcover metadata only when the toggle is on", function()
    reset()
    settings.bookshelf_hardcover_enrichment = {
        ["123:456"] = {
            title = "HC Title",
            authors = "HC Author One, HC Author Two",
            series_name = "HC Series",
            series_position = 2,
            genres = { "Science Fiction", "Fantasy", "Adventure", "Thriller" },
        },
    }
    Hardcover.invalidate()

    -- Toggle off: the book keeps its own fields.
    local off = Hardcover.enrichBook{
        filepath = "/books/a.epub", title = "Own Title",
        authors = { "Own Author" }, series = "Own #1", genres = { "Own Genre" },
    }
    assert(off.title == "Own Title", "title overridden with toggle off")
    assert(off.hardcover_metadata == nil, "metadata marker set with toggle off")

    -- Toggle on: switch to Hardcover's; genres capped to the setting (2).
    settings.bookshelf_hardcover_use_metadata = true
    settings.bookshelf_hardcover_max_genres = 2
    local on = Hardcover.enrichBook{
        filepath = "/books/a.epub", title = "Own Title",
        authors = { "Own Author" }, series = "Own #1", genres = { "Own Genre" },
    }
    assert(on.hardcover_metadata == true, "metadata marker missing")
    assert(on.title == "HC Title", "title: " .. tostring(on.title))
    assert(on.authors and on.authors[1] == "HC Author One"
        and on.authors[2] == "HC Author Two", "authors not split/overridden")
    assert(on.series == "HC Series #2", "series: " .. tostring(on.series))
    assert(on.series_name == "HC Series", "series_name: " .. tostring(on.series_name))
    assert(on.series_num == "2", "series_num: " .. tostring(on.series_num))
    assert(#on.genres == 2, "genres not capped to 2: " .. #on.genres)
    assert(on.genres[1] == "Science Fiction", "first genre: " .. tostring(on.genres[1]))
end)

io.stdout:write(("PASS %d  FAIL %d\n"):format(pass, fail))
if fail > 0 then os.exit(1) end
