-- tests/_test_calibre_genres_only.lua
-- Genres from calibre only (issue 583).
--
-- Usage (from plugin root): lua tests/_test_calibre_genres_only.lua
--
-- A book's genres are calibre's tags, else the tags embedded in the file.
-- That fallback is what a retagged library trips on: a book whose calibre
-- entry has NO tags shows the file's old ones, so the Genres shelf grows a
-- stack of the old names beside the new. With the switch on, a book calibre
-- knows takes its genres from calibre alone, an empty list included. A book
-- set to Embedded in its own Tags section still shows the embedded ones.

package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local src = io.open("lib/bookshelf_book_repository.lua"):read("*a")

local function grab(pattern, what)
    local s = src:match(pattern)
    assert(s, what .. " moved")
    return s
end
local cal  = grab("\n(local function _calibreGenres%(cb%)\n.-\nend)\n", "_calibreGenres")
local emb  = grab("\n(local function _embeddedGenres%(filepath, info, cp%)\n.-\nend)\n", "_embeddedGenres")
local gd   = grab("\n(local function genreData%(filepath, cb, info, cp%)\n.-\nend)\n", "genreData")

local settings, per_book = {}, {}
local env = {
    type = type,
    splitGenreTags = function(v)
        if type(v) == "table" then return v end
        local out = {}
        for w in v:gmatch("[^,]+") do out[#out + 1] = w:match("^%s*(.-)%s*$") end
        return out
    end,
    BookshelfSettings = {
        genreSource = function(fp) return per_book[fp] end,
        isTrue = function(k) return settings[k] == true end,
    },
}
local chunk = cal .. "\n" .. emb .. "\n" .. gd .. "\nreturn genreData"
local genreData
if _G.setfenv then
    local f = assert(_G.loadstring(chunk)); _G.setfenv(f, env); genreData = f()
else
    genreData = assert(load(chunk, "genreData", "t", env))()
end

local OLD = { keywords = "Fantasy, Adventure" }

t.test("off (the default): a calibre entry with no tags falls back to the file's", function()
    settings = {}
    local g = genreData("/b.epub", { tags = {} }, OLD, nil)
    eq(g and g[1], "Fantasy")
end)

t.test("on: a calibre entry with no tags means no genres, not the file's", function()
    settings = { calibre_genres_only = true }
    local g, sources = genreData("/b.epub", { tags = {} }, OLD, nil)
    eq(g, nil)
    eq(sources.embedded[1], "Fantasy", "the book's Tags section should still offer the embedded list")
end)

t.test("on: calibre's tags as before when it has some", function()
    settings = { calibre_genres_only = true }
    local g = genreData("/b.epub", { tags = { "Фэнтези" } }, OLD, nil)
    eq(g[1], "Фэнтези"); eq(#g, 1)
end)

t.test("on: a book calibre does not know keeps its own tags", function()
    settings = { calibre_genres_only = true }
    local g = genreData("/b.epub", nil, OLD, nil)
    eq(g[1], "Fantasy")
end)

t.test("on: a book set to Embedded in its Tags section still shows them", function()
    settings = { calibre_genres_only = true }
    per_book["/b.epub"] = "embedded"
    local g = genreData("/b.epub", { tags = { "Фэнтези" } }, OLD, nil)
    eq(g[1], "Fantasy")
    per_book = {}
end)

t.test("the switch sits under Read calibre metadata.calibre and clears the caches", function()
    local s = io.open("lib/bookshelf_settings.lua"):read("*a")
    local row = s:match('text = _%("Genres from calibre only"%),(.-)\n        },')
    assert(row, "no Genres from calibre only row")
    assert(row:find('"calibre_genres_only"'), "the row does not store calibre_genres_only")
    assert(row:find("invalidateWalkCache"), "turning it on leaves the old genres cached")
    assert(row:find("enabled_func"), "the row should be greyed out without calibre metadata")
end)

t.done()
