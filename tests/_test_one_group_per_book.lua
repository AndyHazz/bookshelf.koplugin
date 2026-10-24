-- tests/_test_one_group_per_book.lua
-- Library & search > "Show each book in one group only": on Authors, Genres
-- and Collections shelves a book with several values sits under one of them
-- (its first author or genre, the collection highest in KOReader's list),
-- not under each. The shelf's view only: search, filter pickers and "more by
-- this author" still see every value.
--
-- Usage (from plugin root): lua tests/_test_one_group_per_book.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()

local src = assert(io.open("lib/bookshelf_book_repository.lua")):read("*a")

local function fn(pattern, what)
    local body = src:match(pattern)
    assert(body, what .. " moved or was renamed")
    return body
end

-- Repo.oneGroupPerBook and Repo._oneGroupShapes, run against a stub setting.
local setting = false
local function loadView()
    local code = fn("\n(function Repo%.oneGroupPerBook%(%).-\nend)\n", "oneGroupPerBook")
        .. "\n" .. fn("\n(function Repo%._oneGroupShapes%(cached%).-\nend)\n", "_oneGroupShapes")
    local Repo = {}
    local env = { Repo = Repo, ipairs = ipairs, pairs = pairs,
        BookshelfSettings = { read = function(k)
            assert(k == "group_first_only", k)
            return setting
        end } }
    assert(load(code, "view", "t", env))()
    return Repo
end

local function shape(name, books)
    local s = { series_name = name, filepaths = {}, books_meta = {}, latest = 99, latest_added = 99 }
    for _i, b in ipairs(books) do
        s.filepaths[#s.filepaths + 1] = b[1]
        s.books_meta[#s.books_meta + 1] = { filepath = b[1], first_group = b[2] or nil,
            _last_read = b[3] or 0, date_added = b[4] or 0 }
    end
    return s
end

-- "a" is by Ann and Bob; "b" by Bob alone; "c" by Cy and Ann.
local function cache()
    return { groups = {
        shape("Ann", { { "a", true, 5, 1 }, { "c", false, 9, 9 } }),
        shape("Bob", { { "a", false, 5, 1 }, { "b", true, 2, 3 } }),
        shape("Cy",  { { "c", true, 9, 9 } }),
    } }
end

t.test("off, the shelf shows every group with every book", function()
    setting = false
    local R, c = loadView(), cache()
    assert(R._oneGroupShapes(c) == c.groups)
end)

t.test("on, each book stays only in its first group", function()
    setting = true
    local R, c = loadView(), cache()
    local out = R._oneGroupShapes(c)
    assert(#out == 3, #out)
    assert(table.concat(out[1].filepaths, ",") == "a", table.concat(out[1].filepaths, ","))
    assert(table.concat(out[2].filepaths, ",") == "b")
    assert(table.concat(out[3].filepaths, ",") == "c")
    assert(#out[1].books_meta == 1, "books_meta not filtered with the paths")
    -- Recently read / added follow the books left in the group, not the
    -- ones taken out (Ann kept "c"'s read time of 9 before).
    assert(out[1].latest == 5 and out[1].latest_added == 1, out[1].latest)
    -- The cached shapes are untouched: search and pickers read them.
    assert(#c.groups[1].filepaths == 2, "the cache was filtered in place")
    assert(R._oneGroupShapes(c) == out, "derived list rebuilt on every call")
end)

t.test("a group left with no books of its own disappears", function()
    setting = true
    local R = loadView()
    local out = R._oneGroupShapes({ groups = {
        shape("Fiction", { { "a", true } }),
        shape("Fantasy", { { "a", false } }),
    } })
    assert(#out == 1 and out[1].series_name == "Fiction")
end)

t.test("the book's first non-empty value is the one marked", function()
    local b = fn("\nlocal function _buildGroups%(.-\nend\n", "_buildGroups")
    assert(b:find("local first_seen = false", 1, true)
        and b:find("local is_first = not first_seen", 1, true), "no first-value marker")
    -- Inside the non-empty check: an empty first author must not win.
    assert(b:find('if raw_k and raw_k ~= "" then%s+local is_first'), "marker counts empty values")
    assert(b:find("b.first_group = (g._first and g._first[b.filepath]) or nil", 1, true),
        "the mark never reaches the group's books")
    local stash = fn("\nlocal function _cacheGroupShapes%(.-\nend\n", "_cacheGroupShapes")
    assert(stash:find("first_group  = b.first_group,", 1, true), "the shape drops the mark")
end)

t.test("Authors and Genres shelves read the view; lookups read the cache", function()
    local a = fn("\nfunction Repo%.getAuthors%(.-\nend\n", "getAuthors")
    local g = fn("\nfunction Repo%.getGenres%(.-\nend\n", "getGenres")
    assert(a:find("ipairs(Repo._oneGroupShapes(cached))", 1, true), "Authors")
    assert(g:find("ipairs(Repo._oneGroupShapes(cached))", 1, true), "Genres")
    for _i, name in ipairs({ "getGroupChoices", "getGroupFilepaths" }) do
        local body = fn("\nfunction Repo%." .. name .. "%(.-\nend\n", name)
        assert(not body:find("_oneGroupShapes", 1, true), name .. " would lose co-authors")
    end
    local f = fn("\nfunction Repo%.findGroup%(kind, name, shelf%).-\nend\n", "findGroup")
    assert(f:find("shelf and Repo._oneGroupShapes(cache) or cache.groups", 1, true))
    local w = assert(io.open("lib/bookshelf_widget.lua")):read("*a")
    assert(w:find("Repo.findGroup(e.kind, e.label, true)", 1, true),
        "a drill-down restored after sleep shows books the shelf left out")
    assert(src:find('if Repo.oneGroupPerBook() then parts[#parts + 1] = "g1" end', 1, true),
        "getBySource's cache would serve the other answer after a toggle")
end)

t.test("a book in several collections goes in the highest in KOReader's list", function()
    local tags = fn("\nfunction Repo%.getTags%(.-\nend\n", "getTags")
    local block = tags:match("(    local owner\n.-\n    end\n)    local groups = {}")
    assert(block, "the owner block moved")
    local env = { Repo = { oneGroupPerBook = function() return true end },
        pairs = pairs, math = math,
        rc = { coll_settings = { Later = { order = 3 }, First = { order = 1 }, Mid = { order = 2 } },
               coll = {
                   favorites = { a = { file = "a" } },
                   Later = { a = { file = "a" }, b = { file = "b" } },
                   Mid   = { a = { file = "a" } },
                   First = { c = { file = "c" } },
                   Zed   = { c = { file = "c" } }, -- no order: last
               } } }
    local owner = assert(load(block .. "\nreturn owner", "owner", "t", env))()
    assert(owner.a == "Mid", "a: " .. tostring(owner.a))
    assert(owner.b == "Later", "b: " .. tostring(owner.b))
    assert(owner.c == "First", "c: " .. tostring(owner.c))
    assert(tags:find("if owner and owner[fp] ~= coll_name then fp = nil end", 1, true)
        and tags:find("local book = fp and _lightMetaForFp(light_cache, fp)", 1, true),
        "other collections still take the book")
end)

t.test("the Library & search row toggles it and redraws the shelf", function()
    local st = assert(io.open("lib/bookshelf_settings.lua")):read("*a")
    local row = st:match('text = _%("Show each book in one group only"%),(.-)\n        },')
    assert(row, "no row")
    assert(row:find('BookshelfSettings.save("group_first_only", not on)', 1, true))
    assert(row:find("self._bw:_rebuild()", 1, true), "the shelf keeps the old grouping")
end)

t.done()
