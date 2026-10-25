-- tests/_test_module_book_helpers.lua
-- ctx.open_book(book) and ctx.show_book(book): the public way for a module to
-- open a book or show its book menu. Third-party modules (Reading Log) reached
-- for the shelf's private bw:_openBook / bw:_showBookDetail instead, which a
-- rename here would silently break. book is a record or a filepath.
--
-- And ctx.surface on a tap: the ctx a module's on_tap gets said "hero" in the
-- full-screen view too, so a module could not tell where it was tapped.
-- Run from the plugin root: lua tests/_test_module_book_helpers.lua
package.path = "./?.lua;" .. package.path
local t  = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq

local hm = io.open("lib/bookshelf_hero_modules.lua"):read("*a")
local BODY = hm:match("\nfunction HeroModules%.bookHelpers%(ctx%)\n(.-)\nend\n")

local function compile(code, env, name)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, name)); _G.setfenv(f, env); return f
    end
    return assert(load(code, name, "t", env))
end

-- helpers(ctx) -> ctx with the helpers, and a log of what they did.
local function helpers(ctx)
    assert(BODY, "HeroModules.bookHelpers(ctx) not found")
    local log = {}
    local env = setmetatable({}, { __index = _G })
    env.require = function(name)
        if name == "lib/bookshelf_module_open" then
            return { open = function(c, book) log[#log + 1] = { "open", c, book } end }
        elseif name == "lib/bookshelf_book_repository" then
            return { buildBook = function(fp) return { filepath = fp, title = "Built " .. fp } end }
        end
        return require(name)
    end
    compile("local ctx = ... ; " .. BODY, env, "helpers")(ctx)
    return ctx, log
end

t.test("open_book opens a record or a path the way a module's cover tap does", function()
    local ctx, log = helpers({ bw = {} })
    ctx.open_book("/books/a.epub")
    eq(log[1][1], "open"); eq(log[1][2], ctx, "not the module's own ctx")
    eq(log[1][3].filepath, "/books/a.epub")
    local rec = { filepath = "/books/b.epub", title = "B" }
    ctx.open_book(rec)
    eq(log[2][3], rec, "a record was not passed through")
    ctx.open_book(nil); ctx.open_book({}); ctx.open_book(42)
    eq(#log, 2, "nothing to open, but something was opened")
end)

t.test("show_book shows the book menu, built from a path", function()
    local shown
    local bw = { _showBookDetail = function(_self, book) shown = book end }
    local ctx, log = helpers({ bw = bw })
    ctx.show_book("/books/a.epub")
    assert(shown, "the book menu was not shown")
    eq(shown.title, "Built /books/a.epub", "a bare path was not built into a record")
    local rec = { filepath = "/books/b.epub", title = "B" }
    ctx.show_book(rec)
    eq(shown, rec, "a full record was rebuilt")
    eq(#log, 0)
end)

t.test("show_book opens the book where there is no book menu", function()
    -- Inside a book (the reader's micro-modules view) and in the module
    -- picker's preview there is no shelf to show a book menu from.
    for _i, bw in ipairs({ { _reader_context = true, _showBookDetail = function() error("shown") end }, false }) do
        local ctx, log = helpers({ bw = bw or nil })
        ctx.show_book("/books/a.epub")
        eq(#log, 1, "nothing opened"); eq(log[1][1], "open")
    end
end)

t.test("every ctx a module gets has the helpers, and a tap knows its surface", function()
    local ctxf = hm:match("\nfunction HeroModules%._ctx%(bw, refresh, entry%)\n(.-)\nend\n")
    assert(ctxf, "HeroModules._ctx moved")
    assert(ctxf:find("HeroModules.bookHelpers(ctx)", 1, true), "the tap ctx has no book helpers")
    assert(ctxf:find("_micro_fullscreen", 1, true) and ctxf:find('"fullscreen"', 1, true),
        "a tap in the full-screen view still reports the top panel")
    local n = select(2, hm:gsub("HeroModules%.bookHelpers%(ctx%)", ""))
    assert(n >= 2, "the render ctx has no book helpers")
    local sm = io.open("lib/bookshelf_start_menu.lua"):read("*a")
    local m = select(2, sm:gsub('require%("lib/bookshelf_hero_modules"%)%.bookHelpers%(', ""))
    eq(m, 2, "the start menu's render and tap ctx do not both have the book helpers")
    local readme = io.open("micromodules/README.md"):read("*a")
    assert(readme:find("ctx.open_book", 1, true) and readme:find("ctx.show_book", 1, true),
        "the helpers are not documented for module authors")
end)

t.done()
