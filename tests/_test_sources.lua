-- tests/_test_sources.lua
-- The shelf source registry (lib/bookshelf_sources, issue 452): what a plugin's
-- spec must look like, how a broken one degrades, and the questions the rest of
-- Bookshelf asks it.
package.path = "./?.lua;./?/init.lua;" .. package.path
local warned = {}
package.loaded["logger"] = { dbg = function() end, info = function() end,
                              warn = function(...) warned[#warned + 1] = table.concat({ ... }, " ") end,
                              err = function() end }

local t  = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq
package.loaded["lib/bookshelf_sources"] = nil
local Sources = require("lib/bookshelf_sources")

local function spec(over)
    local s = {
        api = 1,
        label = function() return "Demo" end,
        available = function() return true end,
        list = function() return { { title = "B", filepath = "/d/b" }, { title = "A", filepath = "/d/a" } } end,
    }
    for k, v in pairs(over or {}) do s[k] = v end
    return s
end

t.test("the built-in Kindle and Kobo sources are registered", function()
    Sources._reset()
    assert(Sources.get("kindle"), "kindle")
    assert(Sources.get("kobo"), "kobo")
    assert(Sources.get("kobo").picker ~= false, "Kobo is an ordinary picker row, not a fixed shelf button")
    assert(Sources.get("kindle").library == true, "Kindle books count as library books")
end)

t.test("a good spec registers; a bad one is refused with a reason", function()
    Sources._reset()
    assert(Sources.register("demo", spec()))
    local ok, why = Sources.register("demo2", spec({ list = "nope" }))
    assert(not ok and why:match("list"), why)
    ok, why = Sources.register("opds", spec())
    assert(not ok and why:match("built%-in"), "a built-in kind must not be taken over")
    ok, why = Sources.register("has space", spec())
    assert(not ok, "ids are short words")
    ok, why = Sources.register("future", spec({ api = Sources.API + 1 }))
    assert(not ok and why:match("API"), "a spec for a newer contract is refused")
    ok, why = Sources.register("demo3", spec({ open = 42 }))
    assert(not ok and why:match("open"), "an optional hook must be a function when given")
end)

t.test("list stamps source_kind and passes the shelf's own source table", function()
    Sources._reset()
    local seen
    Sources.register("demo", spec({ list = function(src) seen = src; return { { title = "X" } } end }))
    local books = Sources.list("demo", { kind = "demo", id = "lib-7" })
    eq(#books, 1)
    eq(books[1].source_kind, "demo")
    eq(seen.id, "lib-7")
end)

t.test("an unavailable, missing or throwing source lists nothing", function()
    Sources._reset()
    Sources.register("off", spec({ available = function() return false end,
                                   list = function() error("must not be asked") end }))
    eq(Sources.list("off"), nil)
    eq(Sources.list("nothing-here"), nil)
    warned = {}
    Sources.register("boom", spec({ list = function() error("server down") end }))
    eq(Sources.list("boom"), nil)
    assert(#warned > 0 and warned[1]:match("server down"), "a throw is logged")
    Sources.register("junk", spec({ list = function() return { "not a record", { title = "ok" } } end }))
    eq(#Sources.list("junk"), 1)
end)

t.test("the picker offers available sources that did not opt out", function()
    Sources._reset()
    Sources.register("demo", spec())
    Sources.register("hidden", spec({ picker = false }))
    Sources.register("gone", spec({ available = function() return false end }))
    local ids = table.concat(Sources.pickerIds(), ",")
    assert(ids:match("demo"), ids)
    assert(not ids:match("hidden") and not ids:match("gone"), ids)
end)

t.test("library sources need the opt-in AND a shelf that uses them", function()
    Sources._reset()
    Sources.register("lib", spec({ library = true }))
    Sources.register("nolib", spec())
    eq(#Sources.libraryIds({}), 0)
    local ids = Sources.libraryIds({ { source = { kind = "lib" } }, { source = { kind = "nolib" } } })
    eq(table.concat(ids, ","), "lib")
end)

t.test("ownerOf: the stamp first, then each source's own test", function()
    Sources._reset()
    Sources.register("demo", spec({ owns = function(b) return b.demo_id ~= nil end }))
    eq(Sources.ownerOf({ source_kind = "demo" }), "demo")
    eq(Sources.ownerOf({ demo_id = 3 }), "demo", "a rebuilt record without the stamp")
    eq(Sources.ownerOf({ is_kindle = true }), "kindle")
    eq(Sources.ownerOf({ filepath = "/x.epub" }), nil)
end)

t.test("invalidate reaches every source, and a throwing one does not stop the rest", function()
    Sources._reset()
    local got = {}
    Sources.register("a", spec({ invalidate = function() error("x") end }))
    Sources.register("b", spec({ invalidate = function(fp) got[#got + 1] = fp end }))
    Sources.invalidate("/f")
    eq(got[1], "/f")
end)

t.test("the plugin entry point hands off to the registry", function()
    local main = io.open("main.lua"):read("*a")
    assert(main:match("Bookshelf%.SOURCE_API = require%(\"lib/bookshelf_sources\"%)%.API"))
    assert(main:match("function Bookshelf:registerSource%(id, spec%)"))
end)

t.done()
