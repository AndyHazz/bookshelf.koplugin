-- tests/_test_cover_fetch_auth.lua
-- A cover download keeps its credentials across a redirect.
--
-- THE DEFECT. Exactly the one fixed for feed fetches in 12ba447, in the other
-- file. luasocket builds the Authorization header itself from
-- reqt.user/reqt.password, inside a table adjustheaders creates. On a 3xx,
-- trequest calls tredirect(reqt, location) with the ORIGINAL request and
-- rebuilds the follow-up from `headers = reqt.headers` -- which never held the
-- header -- passing neither user nor password. The second hop goes out
-- unauthenticated and the server answers 401.
--
-- CoverFetch.download was still handing luasocket user/password and nothing
-- else, so an authenticated catalogue whose cover urls redirect (a CDN, a
-- signed-url handoff, Flask's trailing-slash tidy-up) lost every cover while
-- its feeds worked fine -- a confusing shape to debug, since the shelf
-- populates and only the pictures are missing.
--
-- The helper now lives in bookshelf_http, shared by both callers, because two
-- copies of an auth header is exactly the kind of thing that drifts.
--
-- Usage (from plugin root): lua tests/_test_cover_fetch_auth.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

package.loaded["logger"] = { dbg = function() end, info = function() end,
                             warn = function() end, err = function() end }

t.test("the auth header helper is shared, not copied", function()
    local Http = dofile("lib/bookshelf_http.lua")
    eq(type(Http.basicAuthHeader), "function",
       "bookshelf_http owns the helper")

    -- The feed layer must USE it rather than keep its own copy: two
    -- implementations of an auth header drift, and the drift is silent.
    local feed = io.open("lib/bookshelf_opds_feed.lua"):read("*a")
    assert(feed:find("bookshelf_http", 1, true),
        "the feed layer should reach for the shared helper")
    local n = select(2, feed:gsub("mime%.b64", ""))
    eq(n, 0, "the feed layer should no longer encode its own")
end)

t.test("no credentials means no header, wherever it is asked from", function()
    local Http = dofile("lib/bookshelf_http.lua")
    eq(Http.basicAuthHeader(nil, "pass"), nil, "no user")
    eq(Http.basicAuthHeader("user", nil), nil, "no password")
    eq(Http.basicAuthHeader("", ""), nil, "empty is not a credential")
    eq(Http.basicAuthHeader("user", ""), nil, "an empty password is not one either")
end)

t.test("the encoding is the one curl sends", function()
    if not (pcall(require, "mime") and pcall(require, "socket.url")) then
        print("note: encoding check skipped (no luasocket mime)")
        return
    end
    local Http = dofile("lib/bookshelf_http.lua")
    eq(Http.basicAuthHeader("user", "pass"), "Basic dXNlcjpwYXNz")
    -- luasocket unescapes the password before encoding it; mirrored so that
    -- moving the helper cannot change what any existing catalogue sends.
    eq(Http.basicAuthHeader("user", "p%40ss"), Http.basicAuthHeader("user", "p@ss"),
       "the password is unescaped exactly as luasocket would have done")
end)

t.test("the cover download sends the header itself", function()
    local src = io.open("lib/bookshelf_cover_fetch.lua"):read("*a")
    -- The GET that fetches the image, not the data-uri branch above it.
    local body = src:match("(local ok_req2, code = pcall.-\n    end%))")
    assert(body, "the cover request moved or was renamed")
    assert(body:find("Authorization", 1, true),
        "the cover request must set Authorization itself, or a redirect drops it")
    assert(src:find("basicAuthHeader", 1, true),
        "and it must use the shared helper rather than a second copy")
end)

t.done()
