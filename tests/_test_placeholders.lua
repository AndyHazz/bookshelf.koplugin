-- tests/_test_placeholders.lua
-- PR 515: a user patch or plugin supplies the placeholder for books without a
-- cover. The registry lives in package.loaded so a patch can register before
-- bookshelf loads; the first provider (by id) to return a widget wins, and a
-- provider that errors or returns nil leaves the book to the next one.
--
-- Usage (from plugin root): lua tests/_test_placeholders.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t, eq = helpers.runner(), helpers.eq

package.loaded["logger"] = { warn = function() end }

-- A patch that runs before bookshelf has loaded at all.
local early = package.loaded["bookshelf.placeholders"] or {}
package.loaded["bookshelf.placeholders"] = early
early["early-patch"] = function(book) if book.early then return { tag = "early" } end end

local P = require("lib/bookshelf_placeholders")

t.test("a provider registered before bookshelf loaded is kept", function()
    eq(P.widgetFor({ early = true }, 10, 10).tag, "early")
end)

t.test("nothing registered for a book: nil, so bookshelf draws its own", function()
    eq(P.widgetFor({}, 10, 10), nil)
end)

t.test("providers are asked in id order and the first widget wins", function()
    P.register("b", function() return { tag = "b" } end)
    P.register("a", function() return { tag = "a" } end)
    eq(P.widgetFor({}, 10, 10).tag, "a")
    P.register("a", nil)
    eq(P.widgetFor({}, 10, 10).tag, "b")
    P.register("b", nil)
end)

t.test("an erroring or nil provider falls through to the next", function()
    P.register("a", function() error("boom") end)
    P.register("b", function() return nil end)
    P.register("c", function(_book, w, h, ctx) return { w = w, h = h, bare = ctx.bare } end)
    local got = P.widgetFor({}, 30, 45, { bare = true })
    eq(got.w, 30); eq(got.h, 45); eq(got.bare, true)
    for _i, id in ipairs({ "a", "b", "c" }) do P.register(id, nil) end
end)

t.test("a provider's opts come back with its widget, and default to a table", function()
    P.register("a", function() return { tag = "a" }, { frame = false } end)
    local _w, opts = P.widgetFor({}, 10, 10)
    eq(opts.frame, false)
    P.register("a", function() return { tag = "a" } end)
    _w, opts = P.widgetFor({}, 10, 10)
    eq(type(opts), "table"); eq(opts.frame, nil)
    P.register("a", nil)
end)

t.test("bad registrations are refused", function()
    eq(P.register(nil, function() end), false)
    eq(P.register("x", "not a function"), false)
end)

t.test("the fallback card asks the providers before drawing its own", function()
    local src = io.open("lib/bookshelf_spine_widget.lua"):read("*a")
    local body = src:match("\nfunction SpineWidget:_renderFallback%(%)\n(.-)\nend\n")
    assert(body, "could not find SpineWidget:_renderFallback")
    local ask = body:find("Placeholders.widgetFor(", 1, true)
    local bare = body:find("if self.bare_placeholder then return bareCard() end", 1, true)
    assert(ask and bare and ask < bare, "providers must be asked before the bare card")
end)

t.test("an unframed placeholder gets no glyphs or badges over it", function()
    local src = io.open("lib/bookshelf_spine_widget.lua"):read("*a")
    local body = src:match("\nfunction SpineWidget:_renderShadowedCard%(inner%)\n(.-)\nend\n")
    assert(body, "could not find SpineWidget:_renderShadowedCard")
    local early = body:find("if self._unframed_placeholder then", 1, true)
    local glyphs = body:find("-- 2. In-progress glyph", 1, true)
    assert(early and glyphs and early < glyphs, "the unframed path must return before any overlay")
end)

t.done()
