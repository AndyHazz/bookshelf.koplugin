-- tests/_test_book_review.lua
-- Issues 238, 315: the book modal's "Your review" row reads and writes
-- KOReader's own summary.note, the field its book status page edits, so there
-- is one review, not two. Bodies are extracted from the widget by name.
package.path = "./?.lua;./?/init.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq
local src = io.open("lib/bookshelf_widget.lua"):read("*a")

local sidecars = {}
local DocSettings = {
    hasSidecarFile = function(_s, fp) return sidecars[fp] ~= nil end,
    open = function(_s, fp)
        sidecars[fp] = sidecars[fp] or {}
        local store = sidecars[fp]
        return {
            readSetting = function(_d, k) return store[k] end,
            saveSetting = function(_d, k, v) store[k] = v end,
            flush = function() store._flushed = true end,
        }
    end,
}
local function method(name)
    local body = assert(src:match("\nfunction BookshelfWidget:" .. name .. "%(book(.-)\nend\n"),
        "could not find " .. name)
    local code = "return function(self, book" .. body .. "\nend"
    local env = { require = function(m) assert(m == "docsettings"); return DocSettings end,
                  pcall = pcall, type = type }
    local f
    if _G.setfenv then f = assert(loadstring(code)); setfenv(f, env)
    else f = assert(load(code, name, "t", env)) end
    return f()
end
local get, set = method("_bookReview"), method("_setBookReview")
local bw = { _isRemoteRecord = function(_s, b) return b.filepath:find("^OPDS://") ~= nil end }

t.test("no sidecar, no review, and reading does not create one", function()
    sidecars = {}
    eq(get(bw, { filepath = "/a.epub" }), nil)
    eq(sidecars["/a.epub"], nil)
end)

t.test("the review is summary.note, and the rest of summary survives", function()
    sidecars = { ["/a.epub"] = { summary = { status = "complete", rating = 4 } } }
    set(bw, { filepath = "/a.epub" }, "Loved it.")
    local s = sidecars["/a.epub"].summary
    eq(s.note, "Loved it."); eq(s.status, "complete"); eq(s.rating, 4)
    assert(sidecars["/a.epub"]._flushed)
    eq(get(bw, { filepath = "/a.epub" }), "Loved it.")
end)

t.test("an empty or blank review clears it", function()
    sidecars = { ["/a.epub"] = { summary = { note = "x" } } }
    set(bw, { filepath = "/a.epub" }, "   ")
    eq(sidecars["/a.epub"].summary.note, nil)
    eq(get(bw, { filepath = "/a.epub" }), nil)
end)

t.test("a remote record is never written", function()
    sidecars = {}
    set(bw, { filepath = "OPDS://x/y" }, "text")
    eq(next(sidecars), nil)
end)

t.done()
