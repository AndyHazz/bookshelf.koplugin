-- tests/_test_hardcover_shelfsync.lua
-- Hardcover enrichment with the Hardcover plugin absent and a second plugin
-- providing the same client (issue 603). That plugin keeps a LIVE settings
-- object (OAuth tokens it refreshes) on the same settings file, stores a
-- book's link in the book's sidecar when it has one, and builds its user and
-- dialog objects per instance rather than as module singletons.

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
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(_p, attr) return attr == "mode" and "file" or nil end,
}

-- A second handle on the settings file would flush stale OAuth tokens over
-- the ones the other plugin refreshed. Count every open.
local opens = 0
package.loaded["luasettings"] = {
    open = function()
        opens = opens + 1
        return {
            readSetting = function() return nil end,
            saveSetting = function() end,
            flush = function() end,
        }
    end,
}

-- Sidecars: which books have one, and what is written to them.
local sidecars = {}
package.loaded["docsettings"] = {
    findCustomCoverFile = function() return nil end,
    getSidecarDir       = function() return "/tmp/bookshelf-hardcover-test" end,
    flushCustomCover    = function() return true end,
    getCustomCoverFile  = function() return nil end,
    hasSidecarFile      = function(_self, fp) return sidecars[fp] ~= nil end,
    open = function(_self, fp)
        local data = sidecars[fp]
        assert(data, "opened a sidecar for a book that has none: " .. tostring(fp))
        return {
            readSetting = function(_s, k) return data[k] end,
            saveSetting = function(_s, k, v) data[k] = v end,
            flush = function() data._flushed = (data._flushed or 0) + 1 end,
        }
    end,
}

-- The other plugin's live settings: a wrapper (readSetting/updateSetting)
-- around its own LuaSettings handle at .settings.
local live_raw, live_flushes
local live = {
    settings = {
        readSetting = function(_s, k) return live_raw[k] end,
        saveSetting = function(_s, k, v) live_raw[k] = v end,
        flush = function() live_flushes = live_flushes + 1 end,
    },
}
function live:readSetting(k) return live_raw[k] end
function live:updateSetting(k, v) live_raw[k] = v end

local queries = {}
local Api = {
    settings = live,
    me = function() return { id = 42 } end,
    query = function(_self, query, variables)
        queries[#queries + 1] = variables
        if variables.ids then
            return { books = {
                { id = 123, rating = 4.5, ratings_count = 12, reviews_count = 2,
                  user_books = {} },
            } }
        end
        return nil, { request_error = "No Hardcover OAuth login or API token is configured" }
    end,
    findEditions = function(_self, book_id)
        return { { book_id = book_id, edition_id = 9, title = "An Edition" } }
    end,
}
package.loaded["shelfsync/lib/hardcover/api"] = Api
local default_query = Api.query

local User = {}
User.__index = User
function User:new(o) return setmetatable(o, self) end
function User:getId()
    assert(self.api == Api, "the user object was not given the client")
    return self.settings:readSetting("user_id") or self.api:me().id
end
package.loaded["shelfsync/lib/common/user"] = User

local built
local DialogManager = {}
DialogManager.__index = DialogManager
function DialogManager:new(o) return setmetatable(o or {}, self) end
function DialogManager:buildSearchDialog(title, items, _active, book_callback)
    built = { manager = self, title = title, items = items, pick = book_callback }
    -- Like the real one: each row is a NEW table with only what the list
    -- shows. No edition id, and the year appended to the title.
    local rows = {}
    for i, b in ipairs(items) do
        rows[i] = { book_id = b.book_id, title = (b.title or "") .. " (1923)" }
    end
    self.search_dialog = { menu = { item_table = rows } }
end
package.loaded["shelfsync/lib/common/ui/dialog_manager"] = DialogManager
package.loaded["shelfsync/lib/common/book"] = {
    editionFormatName = function(_s, f) return f end,
    parseIdentifiers = function() return {} end,
}
package.loaded["shelfsync/lib/hardcover/settings"] = {
    new = function() error("must use the live settings, not build a second one") end,
}

-- This suite covers the FALLBACK list: the plugin's own dialog, used when
-- Bookshelf's picker is not there. (tests/_test_hardcover_own.lua covers
-- Bookshelf's picker with this plugin's client.)
package.loaded["lib/bookshelf_hardcover_picker"] = false

local helpers   = dofile("tests/_helpers.lua")
local hccache   = helpers.install_hardcover_cache_fake()
local Hardcover = dofile("lib/bookshelf_hardcover.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1 else
        fail = fail + 1
        io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n")
    end
end

local function reset()
    settings = {}
    live_raw = { user_id = 42, books = {} }
    live_flushes = 0
    sidecars = {}
    queries = {}
    built = nil
    opens = 0
    Api.query = default_query
    hccache.clear()
    Hardcover.invalidate()
end

test("available with only the second plugin's client", function()
    reset()
    assert(Hardcover.isAvailable() == true, "not available")
    assert(Hardcover.source() == "shelfsync", "source: " .. tostring(Hardcover.source()))
end)

test("a book with no sidecar is linked in the live settings table", function()
    reset()
    assert(Hardcover.linkBook("/books/new.epub", { id = 123, title = "New" }))
    assert(Hardcover.getLink("/books/new.epub").book_id == 123, "own link missing")
    local row = live_raw.books["/books/new.epub"]
    assert(row and row.book_id == 123, "not mirrored to the live table")
    assert(live_flushes > 0, "the live settings were not flushed")
    assert(opens == 0, "opened a second handle on the settings file")
end)

test("a book with a sidecar is linked in the sidecar, where it is read first", function()
    reset()
    sidecars["/books/read.epub"] = { hardcover = { book_id = 1, read_id = 77 } }
    assert(Hardcover.linkBook("/books/read.epub", { id = 123, edition_id = 5, title = "Read" }))
    local side = sidecars["/books/read.epub"]
    assert(side.hardcover.book_id == 123, "sidecar link not updated")
    assert(side.hardcover.edition_id == 5, "sidecar edition not written")
    assert(side.hardcover.read_id == 77, "the other plugin's own fields were dropped")
    assert(side._flushed, "sidecar not flushed")
    assert(live_raw.books["/books/read.epub"] == nil, "also written to the table")
end)

test("a details update moves a table link into the sidecar whole", function()
    reset()
    -- Opened since it was linked: the link is still in the table. The other
    -- plugin reads a sidecar row INSTEAD of the table row, so a row holding
    -- only the refreshed pages would unlink the book for it.
    sidecars["/books/read.epub"] = {}
    live_raw.books["/books/read.epub"] = { book_id = 123, edition_id = 5, read_id = 77 }
    settings["bookshelf_hardcover_links"] = { ["/books/read.epub"] = { book_id = 123, edition_id = 5 } }
    Hardcover.invalidate()
    package.loaded["shelfsync/lib/hardcover/api"].query = function()
        return { book = { id = 123, title = "Fresh", pages = 321 } }
    end
    local ok, err = Hardcover.refreshBook({ filepath = "/books/read.epub" }, { force = true })
    assert(ok, tostring(err))
    local row = sidecars["/books/read.epub"].hardcover
    assert(row and row.pages == 321, "pages not written to the sidecar")
    assert(row.book_id == 123 and row.edition_id == 5 and row.read_id == 77,
        "the sidecar row lost the link it shadows")
    assert(live_raw.books["/books/read.epub"] == nil, "the table copy was left behind")
end)

test("a details update never makes a link-less sidecar row", function()
    reset()
    sidecars["/books/read.epub"] = {}
    settings["bookshelf_hardcover_links"] = { ["/books/read.epub"] = { book_id = 123 } }
    Hardcover.invalidate()
    package.loaded["shelfsync/lib/hardcover/api"].query = function()
        return { book = { id = 123, title = "Fresh", pages = 321 } }
    end
    assert(Hardcover.refreshBook({ filepath = "/books/read.epub" }, { force = true }))
    assert(sidecars["/books/read.epub"].hardcover == nil, "made a row with no book id")
end)

test("clearing a link removes it from the sidecar", function()
    reset()
    sidecars["/books/read.epub"] = { hardcover = { book_id = 123, read_id = 77 } }
    assert(Hardcover.linkBook("/books/read.epub", { id = 123, title = "Read" }))
    assert(Hardcover.clearLink("/books/read.epub"))
    assert(sidecars["/books/read.epub"].hardcover.book_id == nil, "link left behind")
end)

test("the bulk refresh list has Bookshelf's own links", function()
    reset()
    sidecars["/books/read.epub"] = {}
    assert(Hardcover.linkBook("/books/read.epub", { id = 123, title = "Read" }))
    local files = Hardcover.linkedFiles()
    assert(#files == 1 and files[1] == "/books/read.epub",
        "a sidecar-linked book is missing from the refresh list")
end)

test("ratings refresh goes through the client on the live handle", function()
    reset()
    assert(Hardcover.linkBook("/books/new.epub", { id = 123, title = "New" }))
    local ok, err = Hardcover.refreshRatings()
    assert(ok, tostring(err))
    assert(#queries == 1 and queries[1].userId == 42, "query did not run with the user id")
    assert(opens == 0, "opened a second handle on the settings file")
    assert(Hardcover.getCachedRating(123), "rating not cached")
end)

test("the edition picker gets a dialog with the client and a user", function()
    reset()
    local ok, err = Hardcover.showEditionPicker({ filepath = "/books/new.epub" }, 123, {})
    assert(ok, tostring(err))
    assert(built and built.items[1].edition_id == 9, "picker not built")
    assert(built.manager.api == Api, "dialog has no client")
    assert(built.manager.user and built.manager.user:getId() == 42, "dialog has no user")
    assert(built.manager.settings == live, "dialog is not on the live settings")
    assert(User.settings == nil and User.api == nil, "wrote onto the other plugin's class")
end)

test("picking an edition links the edition, not the list row", function()
    reset()
    local done
    assert(Hardcover.showEditionPicker({ filepath = "/books/new.epub" }, 123, {
        on_edition_selected = function(sel) done = sel end,
    }))
    built.pick(built.manager.search_dialog.menu.item_table[1])
    local link = Hardcover.getLink("/books/new.epub")
    assert(link and link.edition_id == 9, "edition id lost: " .. tostring(link and link.edition_id))
    assert(link.title == "An Edition", "title took the row's year suffix: " .. tostring(link.title))
    assert(done and done.edition_id == 9, "the caller was handed the row")
end)

-- Found on the PW5: under the plugin's OAuth sign-in Hardcover returns only
-- the reader's own rows for a book, so the count says 120 and the list is
-- empty. An API token gets them all.
test("reviews are withheld: an OAuth sign-in, a count, and nothing in the list", function()
    reset()
    Api.getAuthMethod = function() return "oauth" end
    local none = { reviews_count = 120, reviews = {}, spoiler_reviews = {} }
    assert(Hardcover.reviewsWithheld(none) == true, "not reported as withheld")
    assert(Hardcover.reviewsWithheld({ reviews_count = 0, reviews = {} }) == false,
        "a book nobody reviewed is not withheld")
    assert(Hardcover.reviewsWithheld({ reviews_count = 3, reviews = { {} } }) == false,
        "reviews that arrived are not withheld")
    assert(Hardcover.reviewsWithheld({ reviews_count = 3, reviews = {}, spoiler_reviews = { {} } }) == false,
        "spoiler reviews that arrived are not withheld")
    Api.getAuthMethod = function() return "api_token" end
    assert(Hardcover.reviewsWithheld(none) == false, "an API token gets every review")
    Api.getAuthMethod = function() error("changed upstream") end
    assert(Hardcover.reviewsWithheld(none) == false, "a broken check must read as not withheld")
    Api.getAuthMethod = nil
    assert(Hardcover.reviewsWithheld(none) == false, "no auth method to ask")
end)

-- "Can we show ... what the current sign in method/plugin name is?"
test("connection: the plugin and how it is signed in", function()
    reset()
    Api.getAuthMethod = function() return "oauth" end
    local c = Hardcover.connection()
    assert(c.source == "shelfsync" and c.label == "ShelfSync" and c.method == "oauth", "oauth not reported")
    Api.getAuthMethod = function() return "api_token" end
    assert(Hardcover.connection().method == "api_key")
    Api.getAuthMethod = function() return nil end
    assert(Hardcover.connection().method == nil, "not signed in must read as no method")
    Api.getAuthMethod = function() error("changed upstream") end
    assert(Hardcover.connection().method == nil and Hardcover.connection().label == "ShelfSync")
    Api.getAuthMethod = nil
end)

test("a request error reads as its message", function()
    reset()
    local ok, err = Hardcover.refreshBook({ filepath = "/books/x.epub" }, { force = true })
    assert(not ok)
    assert(Hardcover.linkBook("/books/x.epub", { id = 5, title = "X" }))
    ok, err = Hardcover.refreshBook({ filepath = "/books/x.epub" }, { force = true })
    assert(not ok, "expected the failed request to fail")
    assert(tostring(err):find("No Hardcover OAuth login", 1, true),
        "error not readable: " .. tostring(err))
end)

-- The Hardcover plugin wins when both are enabled: it is the one whose link
-- table Bookshelf has always mirrored into.
test("the Hardcover plugin is preferred when both are present", function()
    package.loaded["hardcover/lib/hardcover_api"] = { query = function() end }
    local Fresh = dofile("lib/bookshelf_hardcover.lua")
    local src = Fresh.source()      -- the lookup is lazy: ask before unstubbing
    package.loaded["hardcover/lib/hardcover_api"] = nil
    assert(src == "hardcover", "source: " .. tostring(src))
end)

io.stdout:write(("PASS %d  FAIL %d\n"):format(pass, fail))
if fail > 0 then os.exit(1) end
