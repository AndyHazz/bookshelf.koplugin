-- tests/_test_random_book_shelves.lua
-- Random book on "current shelf only" with a shelf of shelves open (issue
-- 528). Its source is the "shelves" kind, which holds no books itself, so the
-- pick said "Nothing to pick from here" on a shelf showing a full spine view.
-- It now stands for every shelf inside it, at any depth, as the spine view
-- spills them.
package.path = "./?.lua;./?/init.lua;" .. package.path
local t  = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq

local store = {}
package.loaded["lib/bookshelf_settings_store"] = {
    read = function(k, d) if store[k] == nil then return d end return store[k] end,
    save = function(k, v) store[k] = v end,
}
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
package.loaded["lib/bookshelf_text_safe"] = { safe = function(s) return s end }
package.loaded["libs/libkoreader-lfs"] = { attributes = function() return "file" end }

local tabs = {}
package.loaded["lib/bookshelf_tab_model"] = {
    isShelves = function(tab)
        return type(tab) == "table" and type(tab.source) == "table"
            and tab.source.kind == "shelves"
    end,
    getById = function(id)
        for _i, tb in ipairs(tabs) do if tb.id == id then return tb end end
    end,
    childrenOf = function(id)
        local out = {}
        for _i, tb in ipairs(tabs) do if tb.parent == id then out[#out + 1] = tb end end
        return out
    end,
}

local fetched, shelf_books = {}, {}
package.loaded["lib/bookshelf_book_repository"] = {
    getBySource = function(src)
        local key = src.kind == "library" and "library" or (src.kind .. ":" .. tostring(src.id))
        fetched[#fetched + 1] = key
        return shelf_books[key] or {}
    end,
}

local M = dofile("micromodules/random_unread.lua")

-- pickUnread is local; reach it through the upvalues of the module's functions.
local function findUp(f, name, seen)
    seen = seen or {}
    if type(f) ~= "function" or seen[f] then return nil end
    seen[f] = true
    local i = 1
    while true do
        local n, v = debug.getupvalue(f, i)
        if not n then return nil end
        if n == name then return v end
        local found = findUp(v, name, seen)
        if found then return found end
        i = i + 1
    end
end
local pick
for _k, v in pairs(M) do pick = pick or findUp(v, "pickUnread") end
assert(pick, "pickUnread is no longer reachable")

local function fps(list)
    local out = {}
    for _i, b in ipairs(list) do out[#out + 1] = b.filepath end
    table.sort(out)
    return table.concat(out, ",")
end

-- Every book the pick can return, by rolling until it has seen them all.
local function pool()
    local got = {}
    for _i = 1, 400 do
        local b = pick()
        if not b then return "" end
        got[b.filepath] = b
    end
    local list = {}
    for _fp, b in pairs(got) do list[#list + 1] = b end
    return fps(list)
end

t.test("a shelf of shelves picks from the shelves inside it, at any depth", function()
    store = { active_chip = "sos" }
    tabs = {
        { id = "sos", source = { kind = "shelves" } },
        { id = "a", parent = "sos", source = { kind = "collection", id = "A" } },
        { id = "inner", parent = "sos", source = { kind = "shelves" } },
        { id = "b", parent = "inner", source = { kind = "collection", id = "B" } },
    }
    shelf_books = {
        ["collection:A"] = { { filepath = "/a1" }, { filepath = "/shared" } },
        ["collection:B"] = { { filepath = "/b1" }, { filepath = "/shared" } },
    }
    eq(pool(), "/a1,/b1,/shared")
end)

t.test("an empty shelf of shelves still has nothing to pick", function()
    store = { active_chip = "sos" }
    tabs = { { id = "sos", source = { kind = "shelves" } } }
    eq(pick(), false)
end)

t.test("a grouped shelf inside makes it the whole library, fetched once", function()
    store = { active_chip = "sos" }
    tabs = {
        { id = "sos", source = { kind = "shelves" } },
        { id = "a", parent = "sos", source = { kind = "collection", id = "A" } },
        { id = "au", parent = "sos", source = { kind = "authors" } },
    }
    shelf_books = { library = { { filepath = "/l1" } }, ["collection:A"] = { { filepath = "/a1" } } }
    fetched = {}
    eq(pool(), "/l1")
    eq(fetched[1], "library")
end)

t.test("a child shelf whose status filter rules the pick out is skipped", function()
    store = { active_chip = "sos" }  -- default statuses: unread only
    tabs = {
        { id = "sos", source = { kind = "shelves" } },
        { id = "done", parent = "sos", source = { kind = "collection", id = "D" },
          filter = { statuses = { finished = true } } },
        { id = "a", parent = "sos", source = { kind = "collection", id = "A" } },
    }
    shelf_books = { ["collection:A"] = { { filepath = "/a1" } }, ["collection:D"] = { { filepath = "/d1" } } }
    fetched = {}
    eq(pool(), "/a1")
    for _i, k in ipairs(fetched) do assert(k ~= "collection:D", "fetched a shelf that cannot hold a candidate") end
end)

t.test("an ordinary shelf is unchanged", function()
    store = { active_chip = "a" }
    tabs = { { id = "a", source = { kind = "collection", id = "A" } } }
    shelf_books = { ["collection:A"] = { { filepath = "/a1" }, { filepath = "/a2" } } }
    eq(pool(), "/a1,/a2")
end)

t.done()
