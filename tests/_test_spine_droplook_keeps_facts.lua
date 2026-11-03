-- tests/_test_spine_droplook_keeps_facts.lua
-- A book's spine look is forgotten whenever the book changes (a status or
-- rating, removal from history, a cover change, extraction finishing). It used
-- to delete the book's WHOLE facts row, and with it the publication date
-- (%published, the Publication year sort), the page count, the highlight count
-- and the read progress. Only the look and the cached status may go.
-- Run from the plugin root: lua tests/_test_spine_droplook_keeps_facts.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq
local src = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")
local body = src:match("\nfunction SpineShelf%.dropLook%(fp%)\n(.-)\nend\n")
assert(body, "SpineShelf.dropLook moved or was renamed")

local function run()
    local calls = {}
    local F = {
        drop = function(fp) calls[#calls + 1] = { "drop", fp } end,
        put = function(fp, f) calls[#calls + 1] = { "put", fp, f } end,
    }
    local env = setmetatable({ _look_cache = { ["/b/a.epub"] = {} }, _look_count = 1,
        _facts = function() return F end, math = math }, { __index = _G })
    local code = "return function(fp)\n" .. body .. "\nend"
    local chunk = assert((loadstring or load)(code, "=dropLook"))
    if setfenv then setfenv(chunk, env) else chunk = assert(load(code, "=dropLook", "t", env)) end
    chunk()("/b/a.epub")
    return calls, env
end

t.test("the facts row is not deleted", function()
    local calls = run()
    for _i, c in ipairs(calls) do assert(c[1] ~= "drop", "the whole row was deleted") end
end)

t.test("the look and the cached status are cleared; the date, pages, highlights and progress kept", function()
    local calls, env = run()
    eq(#calls, 1)
    local f = calls[1][3]
    for _i, k in ipairs({ "r", "g", "b", "a", "s", "sk", "m" }) do
        eq(f[k], false, k .. " was not cleared")
    end
    for _i, k in ipairs({ "pd", "pdm", "p", "psrc", "hl", "hm", "rp", "rpm" }) do
        eq(f[k], nil, k .. " was touched")
    end
    eq(env._look_cache["/b/a.epub"], nil, "the session's copy of the look was kept")
end)

-- invalidateBook runs on every status or rating change (through the
-- repository's progress invalidation), but a spine's colours come from its
-- cover: only a cover change may send it back to be sampled again.
local inv = src:match("\nfunction SpineShelf%.invalidateBook%(fp, cover%)\n(.-)\nend\n")

t.test("invalidateBook takes whether the cover changed", function()
    assert(inv, "SpineShelf.invalidateBook(fp, cover) is missing")
end)

local function runInv(cover)
    local dropped, status = 0, 0
    local env = setmetatable({
        _plan_cache = {}, _meta_memo = {}, _hydrate_cache = {}, _progress_validated = {},
        SpineShelf = {
            dropLook = function() dropped = dropped + 1 end,
            dropStatus = function() status = status + 1 end,
            invalidateRender = function() end,
        },
    }, { __index = _G })
    local code = "return function(fp, cover)\n" .. inv .. "\nend"
    local chunk = assert((loadstring or load)(code, "=invalidateBook"))
    if setfenv then setfenv(chunk, env) else chunk = assert(load(code, "=invalidateBook", "t", env)) end
    chunk()("/b/a.epub", cover)
    return dropped, status
end

t.test("a status or rating change keeps the spine's colours", function()
    local dropped, status = runInv(nil)
    eq(dropped, 0, "the colours were dropped for a status change")
    eq(status, 1, "the cached status was kept")
end)

t.test("a cover change samples the colours again", function()
    local dropped = runInv(true)
    eq(dropped, 1)
end)

t.test("wiring: only extraction and the cover picker say the cover changed", function()
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    assert(w:find("for fp in pairs(ready_paths) do SpineShelf.invalidateBook(fp, true) end", 1, true),
        "a book whose cover just arrived keeps its stand-in colours")
    assert(w:find("local spine_done = self:_refreshSpineInPlace(filepath, true)", 1, true),
        "a changed cover keeps the old colours")
    assert(w:find('require("lib/bookshelf_spine_shelf").invalidateBook(fp)\n', 1, true),
        "a status change must not say the cover changed")
end)

t.done()
