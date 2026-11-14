-- tests/_test_hardcover_client.lua
-- Bookshelf's own Hardcover client (lib/bookshelf_hardcover_client): the
-- requests it makes, what it hands back, and what it learns from Hardcover's
-- rate-limit headers. The HTTP and JSON layer is a seam (Client._transport);
-- the response shapes here are from the live API, 2026-11-13.
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t, eq = helpers.runner(), helpers.eq

local key = "KEY.abc.def"
package.loaded["lib/bookshelf_hardcover_key"] = { get = function() return key, key and "own" or nil end }
local clock = 1000
package.loaded["lib/bookshelf_gettime"] = function() return clock end
package.loaded["logger"] = { warn = function() end, dbg = function() end }

local Client = dofile("lib/bookshelf_hardcover_client.lua")

-- Scripted transport: each call pops the next reply.
local sent, replies
Client._transport = function(request, token)
    sent[#sent + 1] = { query = request.query, variables = request.variables, token = token }
    local r = table.remove(replies, 1) or { 200, { data = {} } }
    if type(r) == "function" then r = r(request) end
    return r[1], r[2], r[3]
end
local function reset()
    sent, replies, key, clock = {}, {}, "KEY.abc.def", 1000
    Client._resetRateLimit()
end
local RL = '"Free (JWT)";r=4;t=0, "daily";r=4304;t=2390'

t.test("query: sends the key, hands back the data", function()
    reset()
    replies = { { 200, { data = { me = { { id = 7 } } } }, RL } }
    local data, err = Client:query("{ me { id } }", nil)
    eq(err, nil); eq(data.me[1].id, 7)
    eq(sent[1].token, "KEY.abc.def")
    eq(sent[1].variables, nil)
end)

t.test("query: no key, a rejected key, GraphQL errors and bad replies are told apart", function()
    reset()
    key = nil
    local data, err = Client:query("{ me { id } }")
    eq(data, nil); eq(err.no_key, true); eq(#sent, 0, "a request went out with no key")
    reset()
    replies = { { 401, { error = "invalid_token" } } }
    data, err = Client:query("q")
    eq(data, nil); eq(err.auth_error, true)
    assert(err.request_error:find("rejected", 1, true), err.request_error)
    reset()
    replies = { { 200, { errors = { { message = "field 'x' not found" } } } } }
    data, err = Client:query("q")
    eq(data, nil); eq(err.errors[1].message, "field 'x' not found")
    reset()
    replies = { { 500, nil } }
    data, err = Client:query("q")
    eq(data, nil); assert(err.request_error:find("500", 1, true), err.request_error)
    reset()
    replies = { { nil, nil, nil } }                 -- the request never completed
    data, err = Client:query("q")
    eq(data, nil); eq(err.completed, false)
end)

t.test("rate limit: read from every reply, and waitTime says when to send next", function()
    reset()
    eq(Client.waitTime(), 0, "unknown must not hold a first request back")
    replies = { { 200, { data = {} }, '"Free (JWT)";r=0;t=7, "daily";r=4300;t=2388' } }
    Client:query("q")
    local rl = Client.rateLimit()
    eq(rl.remaining, 0); eq(rl.daily_remaining, 4300)
    eq(Client.waitTime(), 7)
    clock = 1004
    eq(Client.waitTime(), 3, "the wait runs down with the clock")
    clock = 1010
    eq(Client.waitTime(), 0)
    -- Tokens left: no wait.
    replies = { { 200, { data = {} }, RL } }
    Client:query("q")
    eq(Client.waitTime(), 0); eq(Client.rateLimit().remaining, 4)
    -- 429 with no usable header still backs off.
    replies = { { 429, nil, nil } }
    local _d, err = Client:query("q")
    eq(err.rate_limited, true)
    assert(Client.waitTime() > 0, "a 429 must hold the next request back")
    -- The day's budget gone: wait for the day's reset, which is a long time.
    clock = 5000
    replies = { { 429, nil, '"daily";r=0;t=3600' } }
    Client:query("q")
    eq(Client.waitTime(), 3600); eq(Client.rateLimit().daily_remaining, 0)
end)

t.test("me: the account's id", function()
    reset()
    replies = { { 200, { data = { me = { { id = 52409, username = "x" } } } } } }
    eq(Client:me().id, 52409)
    replies = { { 401, {} } }
    local me, err = Client:me()
    eq(me, nil); eq(err.auth_error, true)
end)

local HIT = {
    book_id = 432300, title = "The Able McLaughlins", release_year = 1923,
    users_read_count = 3, pages = 268,
    book_series = { { position = 1, series = { name = "The McLaughlins" } } },
    contributions = { { author = { id = 235426, name = "Margaret Wilson" }, contribution = "Author" } },
    cached_image = { url = "https://assets.example/x.jpeg", width = 333, height = 500 },
}

t.test("findBooks: a search for ids, then the books, in the search's order", function()
    reset()
    replies = {
        { 200, { data = { search = { ids = { "2", "432300" } } } } },
        { 200, { data = { books = { HIT, { book_id = 2, title = "Second" } } } } },
    }
    local books = Client:findBooks("The Able McLaughlins: A Novel", "Margaret Wilson")
    eq(#sent, 2)
    eq(sent[1].variables.query, "The Able McLaughlins Margaret Wilson", "the subtitle goes, the author is appended")
    eq(sent[2].variables.ids[1], 2); eq(sent[2].variables.ids[2], 432300)
    eq(books[1].book_id, 2); eq(books[2].book_id, 432300)
    eq(books[2].title, "The Able McLaughlins")
    -- No hits: an empty list, and no second request.
    reset()
    replies = { { 200, { data = { search = { ids = {} } } } } }
    eq(#Client:findBooks("zzz"), 0); eq(#sent, 1)
    -- A blank title asks nothing.
    reset()
    eq(#Client:findBooks("   "), 0); eq(#sent, 0)
    -- A failed search is nil + the error, not an empty list (issue 310).
    reset()
    replies = { { 500, nil } }
    local none, err = Client:findBooks("x")
    eq(none, nil); assert(err and err.request_error)
end)

t.test("findEditions: each edition as a book record with its edition's own fields", function()
    reset()
    replies = { { 200, { data = { editions = {
        { id = 27550806, title = "The Able McLaughlins", edition_format = nil, reading_format_id = 1,
          pages = 263, release_date = "1923-01-01", users_count = 0,
          publisher = { name = "Cherokee Pub. Co." }, language = { code2 = "en", language = "English" },
          book = { book_id = 432300, title = "Work title", contributions = HIT.contributions } },
        { id = 31, title = "Ebook", edition_format = nil, reading_format_id = 4, pages = 250,
          release_date = "2022-05-01", users_count = 0, book = { book_id = 432300, title = "Work title" } },
        { id = 29308305, title = "Paperback", edition_format = "Paperback", reading_format_id = 1,
          pages = 268, users_count = 22, book = { book_id = 432300, title = "Work title" } },
    } } } } }
    local eds = Client:findEditions(432300)
    eq(sent[1].variables.id, 432300)
    eq(#eds, 3)
    -- E-books first (it is an e-reader), then by how many readers have it.
    eq(eds[1].edition_id, 31); eq(eds[1].edition_format, "E-Book")
    eq(eds[2].edition_id, 29308305); eq(eds[2].edition_format, "Paperback")
    eq(eds[3].edition_id, 27550806); eq(eds[3].edition_format, "Physical Book")
    eq(eds[3].book_id, 432300); eq(eds[3].title, "The Able McLaughlins")
    eq(eds[3].pages, 263); eq(eds[3].release_year, "1923")
    eq(eds[3].publisher, "Cherokee Pub. Co.")
    eq(eds[1].release_year, "2022")
    -- A failure is nil, so the caller can say so.
    reset()
    replies = { { 500, nil } }
    eq(Client:findEditions(1), nil)
end)

t.test("findBookByIdentifiers: edition id, then slug, then ISBN", function()
    reset()
    replies = { { 200, { data = { editions = { { id = 9, title = "Ed", pages = 100,
        book = { book_id = 5, title = "Work" } } } } } } }
    local b = Client:findBookByIdentifiers({ edition_id = "9" })
    eq(sent[1].variables.id, 9); eq(b.book_id, 5); eq(b.edition_id, 9)
    reset()
    replies = { { 200, { data = { books = { { book_id = 6, title = "By slug" } } } } } }
    b = Client:findBookByIdentifiers({ book_slug = "by-slug" })
    eq(sent[1].variables.slug, "by-slug"); eq(b.book_id, 6)
    reset()
    replies = {
        { 200, { data = { editions = { { id = 11302913, title = "Rivers of London", pages = 392,
            book = { book_id = 440003, title = "Rivers of London" } } } } } },
    }
    b = Client:findBookByIdentifiers({ isbn_13 = "9780575097568" })
    eq(sent[1].variables.isbn, "9780575097568")
    assert(sent[1].query:find("isbn_13", 1, true), "asked by the wrong field")
    eq(b.edition_id, 11302913); eq(b.book_id, 440003)
    reset()
    replies = { { 200, { data = { editions = {} } } } }
    eq(Client:findBookByIdentifiers({ isbn_10 = "0877972885" }), nil)
    assert(sent[1].query:find("isbn_10", 1, true))
    reset()
    eq(Client:findBookByIdentifiers({}), nil); eq(#sent, 0)
end)

t.test("hydrateBooks: nothing asked for nothing", function()
    reset()
    eq(#Client:hydrateBooks({}), 0); eq(#sent, 0)
end)

t.test("scrub: JSON nulls become absent, at any depth", function()
    local NULL = {}
    local v = Client._scrub({ a = NULL, b = { c = NULL, d = 1 }, e = { 1, 2 } }, NULL)
    eq(v.a, nil); eq(v.b.c, nil); eq(v.b.d, 1); eq(v.e[2], 2)
end)

t.test("the format name: the edition's own, else from the reading format", function()
    eq(Client:editionFormatName("Paperback", 1), "Paperback")
    eq(Client:editionFormatName(nil, 4), "E-Book")
    eq(Client:editionFormatName("", 2), "Audiobook")
    eq(Client:editionFormatName(nil, 1), "Physical Book")
    eq(Client:editionFormatName(nil, nil), nil)
end)

t.done()
