-- tests/_test_hardcover_own.lua
-- Hardcover with NO sync plugin's client: Bookshelf's own
-- (lib/bookshelf_hardcover_client) and an API key
-- (lib/bookshelf_hardcover_key). A plugin's client still wins when one
-- loads, so nothing changes for a reader who has one.

package.path = "./?.lua;./?/init.lua;" .. package.path

local settings = {}
package.loaded["lib/bookshelf_settings_store"] = {
    read = function(key, default)
        local v = settings["bookshelf_" .. key]
        if v == nil then return default end
        return v
    end,
    save = function(key, value) settings["bookshelf_" .. key] = value end,
    delete = function(key) settings["bookshelf_" .. key] = nil end,
    flush = function() end,
    isTrue = function(key) return settings["bookshelf_" .. key] == true end,
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

-- The plugin's settings file: there (a plugin was installed once, and is off
-- now) or not.
local plugin_file, opens
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(_p, attr)
        if attr == "mode" then return plugin_file and "file" or nil end
        return nil
    end,
}
package.loaded["luasettings"] = {
    open = function()
        opens = opens + 1
        assert(plugin_file, "opened a settings file that is not there")
        return {
            readSetting = function(_s, k) return plugin_file[k] end,
            saveSetting = function(_s, k, v) plugin_file[k] = v end,
            flush = function() plugin_file._flushed = (plugin_file._flushed or 0) + 1 end,
        }
    end,
}
package.loaded["docsettings"] = {
    findCustomCoverFile = function() return nil end,
    getSidecarDir       = function() return "/tmp/bookshelf-hardcover-test" end,
    flushCustomCover    = function() return true end,
    getCustomCoverFile  = function() return nil end,
    hasSidecarFile      = function() return false end,
}

-- has_key: Bookshelf has its own. plugin_key: only a sync plugin's file has one.
local has_key, plugin_key
package.loaded["lib/bookshelf_hardcover_key"] = {
    available = function() return has_key or plugin_key or false end,
    hasOwn = function() return has_key and true or false end,
    get = function()
        if has_key then return "KEY", "own" end
        if plugin_key then return "KEY", "hardcover" end
    end,
}

local queries, me_calls, found
local Client = {
    me = function() me_calls = me_calls + 1; return { id = 42 } end,
    query = function(_s, query, variables)
        queries[#queries + 1] = { query = query, variables = variables }
        if variables and variables.ids then
            return { books = { { id = 123, rating = 4.5, ratings_count = 12, reviews_count = 2, user_books = {} } } }
        end
        if query:find("books_by_pk", 1, true) and variables and variables.limit then
            return { books_by_pk = { id = variables.id, title = "T", rating = 4, ratings_count = 3,
                reviews_count = 1, user_books = { { id = 1, rating = 4, review = "<p>Good.</p>",
                    user = { name = "R" } } }, spoiler_books = {} } }
        end
        return { book = { id = 123, title = "Fresh", pages = 321 } }
    end,
    findEditions = function(_s, book_id)
        return { { book_id = book_id, edition_id = 9, title = "An Edition", pages = 200 } }
    end,
    findBooks = function(_s, title, author)
        found[#found + 1] = { title, author }
        return { { book_id = 5, title = title } }
    end,
    findBookByIdentifiers = function() return nil end,
    editionFormatName = function(_s, f) return f end,
}
package.loaded["lib/bookshelf_hardcover_client"] = Client

local picker
-- The list runs its lookup itself once it is up (spec.load); run it here.
package.loaded["lib/bookshelf_hardcover_picker"] = {
    show = function(spec)
        picker = spec
        if spec.load then spec.records, spec.load_err = spec.load() end
        return true
    end,
}

local helpers   = dofile("tests/_helpers.lua")
local hccache   = helpers.install_hardcover_cache_fake()
local Hardcover = dofile("lib/bookshelf_hardcover.lua")
-- No real files here: reading a book's embedded identifiers would shell out.
Hardcover.getEmbeddedIdentifiers = function() return nil end

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1 else
        fail = fail + 1
        io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n")
    end
end

local function reset()
    settings, plugin_file, opens, has_key, plugin_key = {}, nil, 0, true, false
    queries, me_calls, found, picker = {}, 0, {}, nil
    hccache.clear()
    Hardcover.invalidate()
    Hardcover.invalidateSource()
end

test("a key and no plugin: available, from Bookshelf's own client", function()
    reset()
    assert(Hardcover.isAvailable() == true, "not available")
    assert(Hardcover.source() == "own", "source: " .. tostring(Hardcover.source()))
end)

test("connection: Bookshelf itself, by API key; nothing when Hardcover is off", function()
    reset()
    local c = Hardcover.connection()
    assert(c.source == "own" and c.label == "Bookshelf" and c.method == "api_key")
    has_key = false
    Hardcover.invalidateSource()
    assert(Hardcover.connection() == nil)
end)

test("whenOnline: KOReader's connect-first, and nothing when the reader declines", function()
    reset()
    local ran = 0
    package.loaded["ui/network/manager"] = { runWhenOnline = function(_s, fn) end }   -- declined
    Hardcover.whenOnline(function() ran = ran + 1 end)
    assert(ran == 0, "ran with no connection")
    package.loaded["ui/network/manager"] = { runWhenOnline = function(_s, fn) fn() end }
    Hardcover.whenOnline(function() ran = ran + 1 end)
    assert(ran == 1, "did not run once connected")
    package.loaded["ui/network/manager"] = nil
end)

test("no key and no plugin: not available, until a key is set this session", function()
    reset()
    has_key = false
    Hardcover.invalidateSource()
    assert(Hardcover.isAvailable() == false)
    assert(Hardcover.source() == nil)
    has_key = true
    assert(Hardcover.isAvailable() == false, "the answer is remembered until told otherwise")
    Hardcover.invalidateSource()
    assert(Hardcover.isAvailable() == true, "a key set in settings must switch Hardcover on")
end)

-- Switching a sync plugin off has always switched Hardcover off in
-- Bookshelf. Its key is still in its folder, and must not switch it back on:
-- that takes a key the reader gave Bookshelf (or asked it to keep a copy of).
test("a key left in a switched-off plugin's folder does not switch Hardcover on", function()
    reset()
    has_key, plugin_key = false, true
    Hardcover.invalidateSource()
    assert(Hardcover.isAvailable() == false, "a disabled plugin's key was used unasked")
    assert(Hardcover.source() == nil)
end)

test("ratings refresh: the account id is asked once and kept in Bookshelf's settings", function()
    reset()
    assert(Hardcover.linkBook("/books/a.epub", { id = 123, title = "A" }))
    local ok, err = Hardcover.refreshRatings()
    assert(ok, tostring(err))
    assert(me_calls == 1, "me calls: " .. me_calls)
    assert(queries[1].variables.userId == 42)
    assert(Hardcover.getCachedRating(123), "rating not cached")
    assert(opens == 0, "opened a plugin settings file that does not exist")
    Hardcover.invalidate()
    assert(Hardcover.refreshRatings())
    assert(me_calls == 1, "asked for the account id again")
end)

test("a link is Bookshelf's own; no plugin file is made for it", function()
    reset()
    assert(Hardcover.linkBook("/books/a.epub", { id = 123, edition_id = 9, title = "A" }))
    local link = Hardcover.getLink("/books/a.epub")
    assert(link.book_id == 123 and link.edition_id == 9)
    assert(opens == 0)
    local files = Hardcover.linkedFiles()
    assert(#files == 1 and files[1] == "/books/a.epub", "not in the refresh list")
end)

test("a plugin that is switched off keeps getting links, for when it is back", function()
    reset()
    plugin_file = { books = { ["/books/old.epub"] = { book_id = 77 } } }
    Hardcover.invalidate()
    assert(Hardcover.getLink("/books/old.epub").book_id == 77, "its links are not read")
    assert(Hardcover.linkBook("/books/a.epub", { id = 123, title = "A" }))
    assert(plugin_file.books["/books/a.epub"].book_id == 123, "not written to its table")
    assert(plugin_file._flushed, "not flushed")
end)

test("the edition picker is Bookshelf's own, and a pick links the edition", function()
    reset()
    local done
    local ok, err = Hardcover.showEditionPicker({ filepath = "/books/a.epub" }, 123, {
        on_edition_selected = function(sel) done = sel end,
    })
    assert(ok, tostring(err))
    assert(picker, "the own picker was not opened")
    assert(picker.title == "Select Hardcover edition")
    assert(picker.records[1].edition_id == 9)
    assert(picker.search == nil, "editions are not searched")
    assert(me_calls == 0, "the account id is not needed to list editions")
    picker.on_pick(picker.records[1])
    local link = Hardcover.getLink("/books/a.epub")
    assert(link.book_id == 123 and link.edition_id == 9 and link.pages == 200)
    assert(done and done.edition_id == 9)
end)

test("from the Hardcover menu: a page of it, the lookup in the list, and Linking said first", function()
    reset()
    local over = { crumbs = "Hardcover > Select edition" }
    local order = {}
    Client.findEditions = function(_s, book_id)
        order[#order + 1] = "lookup"
        return { { book_id = book_id, edition_id = 9, title = "An Edition", pages = 200 } }
    end
    local ok = Hardcover.showEditionPicker({ filepath = "/books/a.epub" }, 123, {
        over = over,
        on_start = function() order[#order + 1] = "start:" .. tostring(Hardcover.getLink("/books/a.epub")) end,
    })
    assert(ok)
    assert(picker.over == over, "not opened as a page of the menu")
    assert(type(picker.load) == "function", "the lookup ran before the list was up")
    picker.on_pick(picker.records[1])
    assert(order[1] == "lookup" and order[2] == "start:nil", "on_start did not come before the link: " .. table.concat(order, ","))
    assert(Hardcover.getLink("/books/a.epub").edition_id == 9)
    -- A lookup that fails is said in the list, which still opens.
    reset()
    Client.findEditions = function() return nil end
    assert(Hardcover.showEditionPicker({ filepath = "/books/a.epub" }, 123, {}) == true)
    assert(picker.records == nil and picker.load_err == "Could not fetch Hardcover editions", tostring(picker.load_err))
    Client.findEditions = function(_s, book_id)
        return { { book_id = book_id, edition_id = 9, title = "An Edition", pages = 200 } }
    end
end)

test("the book picker searches through Bookshelf's client", function()
    reset()
    local closed
    local ok, err = Hardcover.showBookPicker({ filepath = "/books/a.epub", title = "Dune", authors = "Frank Herbert" },
        { on_close = function() closed = true end })
    assert(ok, tostring(err))
    assert(picker and picker.title == "Select Hardcover book")
    assert(picker.records[1].book_id == 5)
    assert(picker.search_value == "Dune")
    local more = picker.search("Dune Messiah")
    assert(type(more) == "table" and more[1].title == "Dune Messiah", "search did not come back")
    picker.on_pick(picker.records[1])
    assert(Hardcover.getLink("/books/a.epub").book_id == 5)
    picker.on_close()
    assert(closed, "closing the picker is not passed on")
end)

test("reviews come through Bookshelf's client", function()
    reset()
    local ok, res = Hardcover.fetchReviews(123, { force = true })
    assert(ok, tostring(res))
    assert(#res.reviews == 1 and res.reviews[1].user_name == "R")
end)

-- A plugin's client wins when one loads: its link table is the one Bookshelf
-- has always kept in step, and its readers must see no change.
test("a sync plugin's client is preferred to Bookshelf's own", function()
    reset()
    package.loaded["hardcover/lib/hardcover_api"] = { query = function() end }
    local Fresh = dofile("lib/bookshelf_hardcover.lua")
    local src = Fresh.source()
    package.loaded["hardcover/lib/hardcover_api"] = nil
    assert(src == "hardcover", "source: " .. tostring(src))
end)

-- "I'm wondering why I can't see our library modal when choosing to link a
-- book, I still see the plugin's modal" (maintainer, connected through a
-- sync plugin). Bookshelf's picker is the picker, whoever the client is.
test("a sync plugin's client still gets Bookshelf's picker, and searches with its account id", function()
    reset()
    has_key = false
    local searched
    local User = {}
    User.__index = User
    function User:new(o) return setmetatable(o, self) end
    function User:getId() return 77 end
    package.loaded["shelfsync/lib/common/user"] = User
    package.loaded["shelfsync/lib/common/book"] = { editionFormatName = function(_s, f) return f end }
    package.loaded["shelfsync/lib/common/ui/dialog_manager"] = nil     -- not needed, and not there
    package.loaded["shelfsync/lib/hardcover/api"] = {
        settings = { readSetting = function() end, settings = {
            readSetting = function() end, saveSetting = function() end, flush = function() end } },
        query = function() end,
        findEditions = function(_s, book_id, user_id)
            assert(user_id == 77, "the plugin's client was not given the account id")
            return { { book_id = book_id, edition_id = 9, title = "An Edition" } }
        end,
        findBooks = function(_s, title, _author, user_id)
            searched = { title, user_id }
            return { { book_id = 6, title = title } }
        end,
        findBookByIdentifiers = function() return nil end,
    }
    local Fresh = dofile("lib/bookshelf_hardcover.lua")
    Fresh.getEmbeddedIdentifiers = function() return nil end
    assert(Fresh.source() == "shelfsync")
    picker = nil
    local ok, err = Fresh.showEditionPicker({ filepath = "/books/a.epub" }, 123, {})
    assert(ok, tostring(err))
    assert(picker and picker.records[1].edition_id == 9, "Bookshelf's picker was not used")
    picker = nil
    assert(Fresh.showBookPicker({ filepath = "/books/a.epub", title = "Dune" }, {}))
    assert(picker and picker.search, "the book list cannot be searched")
    picker.search("Dune Messiah")
    assert(searched[1] == "Dune Messiah" and searched[2] == 77, "the new search lost the account id")
    package.loaded["shelfsync/lib/hardcover/api"] = nil
    package.loaded["shelfsync/lib/common/user"] = nil
    package.loaded["shelfsync/lib/common/book"] = nil
end)

-- Found on the PW5: a plugin's OAuth sign-in gets none of other readers'
-- reviews. With a key to hand, the reviews request alone goes through
-- Bookshelf's client.
test("reviews use the key when the plugin's sign-in is withheld them", function()
    reset()
    local plugin_queries = 0
    package.loaded["shelfsync/lib/hardcover/api"] = {
        settings = { readSetting = function() end, settings = {
            readSetting = function() end, saveSetting = function() end, flush = function() end } },
        getAuthMethod = function() return "oauth" end,
        query = function() plugin_queries = plugin_queries + 1; return { books_by_pk = { id = 123,
            reviews_count = 5, user_books = {}, spoiler_books = {} } } end,
    }
    has_key, plugin_key = false, true      -- the key is the plugin's own
    local Fresh = dofile("lib/bookshelf_hardcover.lua")
    assert(Fresh.source() == "shelfsync")
    local ok, res = Fresh.fetchReviews(123, { force = true })
    assert(ok, tostring(res))
    assert(#res.reviews == 1, "the reviews did not come from the key")
    assert(plugin_queries == 0, "the plugin's sign-in was asked anyway")
    -- With an API token in the plugin there is nothing to route around.
    package.loaded["shelfsync/lib/hardcover/api"].getAuthMethod = function() return "api_token" end
    queries = {}
    hccache.clear()
    Fresh.invalidate()
    assert(Fresh.fetchReviews(123, { force = true }))
    assert(plugin_queries == 1 and #queries == 0, "the plugin's own token should have been used")
    package.loaded["shelfsync/lib/hardcover/api"] = nil
end)

io.stdout:write(("PASS %d  FAIL %d\n"):format(pass, fail))
if fail > 0 then os.exit(1) end
