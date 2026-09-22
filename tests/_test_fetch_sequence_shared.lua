-- tests/_test_fetch_sequence_shared.lua
-- _rebuild and _swapShelvesInPlace take their totals and their page from the
-- same two helpers.
--
-- Usage (from plugin root): lua tests/_test_fetch_sequence_shared.lua
--
-- Both paths fetch, note the totals, clamp the cursor, then take the page, and
-- each used to spell every step out itself. Issue 369 was the clamp landing
-- after a fetch it had to correct, fixed in one path before the other was
-- found. The steps either side of the clamp now live in _noteFetchTotals and
-- _takeFetchedPage; the clamp stays with each caller, since the two answer it
-- differently (a retry vs a fall back to the full rebuild).

package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local src = io.open("lib/bookshelf_widget.lua"):read("*a")

local function method(name)
    local args, body = src:match("\nfunction BookshelfWidget:" .. name .. "%((.-)%)\n(.-)\nend\n")
    assert(body, "BookshelfWidget:" .. name .. " is missing")
    return args, body
end

local function load_method(name)
    local args, body = method(name)
    local sig = args ~= "" and ("self, " .. args) or "self"
    return assert(load("return function(" .. sig .. ")\n" .. body .. "\nend",
        name, "t", { math = math, type = type }))()
end

local noteTotals = load_method("_noteFetchTotals")
local takePage   = load_method("_takeFetchedPage")

local function fake(o)
    o = o or {}
    local calls = {}
    local s = {
        _cursor = o.cursor or 1, _cursor_idx = o.cursor_idx,
        _spineTotalPages = function() return o.spine_pages end,
        _syncPageFromCursor = function() calls[#calls + 1] = "sync" end,
        _spineUpdateBookCounts = function() calls[#calls + 1] = "counts" end,
    }
    return s, calls
end

-- ── _noteFetchTotals ───────────────────────────────────────────────────────

t.test("a whole list: total is its length, pages round up", function()
    local s = fake()
    eq(noteTotals(s, { 1, 2, 3, 4, 5, 6, 7 }, nil, 3), 7)
    eq(s._total_items, 7); eq(s._total_pages, 3)
end)

t.test("a windowed source: the hint is the total, not the page it returned", function()
    local s = fake()
    eq(noteTotals(s, { 1, 2, 3 }, 40, 3), 40)
    eq(s._total_pages, 14)
end)

t.test("an empty or short chip is one page", function()
    local s = fake()
    noteTotals(s, {}, nil, 8); eq(s._total_pages, 1)
    noteTotals(s, { 1, 2 }, nil, 8); eq(s._total_pages, 1)
end)

t.test("the spine page map overrides the estimate", function()
    local s = fake({ spine_pages = 5 })
    noteTotals(s, { 1, 2, 3 }, nil, 3)
    eq(s._total_pages, 5)
end)

t.test("the open-ended OPDS flag is taken from the page, and cleared off it", function()
    local s = fake()
    noteTotals(s, { opds_open_ended = true }, 3, 3)
    eq(s._opds_open_ended, true)
    noteTotals(s, { 1 }, nil, 3)
    eq(s._opds_open_ended, nil, "a stale flag outlived the OPDS chip")
end)

-- ── _takeFetchedPage ───────────────────────────────────────────────────────

t.test("a whole list is cut at the cursor", function()
    local s = fake({ cursor = 4 })
    local items = takePage(s, { "a", "b", "c", "d", "e", "f", "g" }, nil, 3)
    eq(items[1], "d"); eq(items[3], "f"); eq(items[4], nil)
    assert(s._page_items == items)
end)

t.test("a windowed page is used as it came", function()
    local s = fake({ cursor = 4 })
    local page = { "x", "y" }
    assert(takePage(s, page, 40, 3) == page)
end)

t.test("the selection is pulled back onto a real book of a partial page", function()
    local s = fake({ cursor = 5, cursor_idx = 3 })
    takePage(s, { "a", "b", "c", "d", "e", "f" }, nil, 3)
    eq(s._cursor_idx, 2)
end)

t.test("the page number is derived after the clamp, before the page is cut", function()
    local s, calls = fake()
    takePage(s, {}, nil, 3)
    eq(calls[1], "sync"); eq(calls[2], "counts")
end)

-- ── both callers use them, in the order the clamp needs ────────────────────

for _i, fname in ipairs({ "_rebuild", "_swapShelvesInPlace" }) do
    t.test(fname .. " notes totals, clamps, then takes the page", function()
        local _a, b = method(fname)
        local note  = b:find("self:_noteFetchTotals(all_items, _total_hint, VIEW_SIZE)", 1, true)
        local clamp = b:find("self:_clampFetchedWindow(total", 1, true)
        local take  = b:find("self:_takeFetchedPage(all_items, _total_hint, VIEW_SIZE)", 1, true)
        assert(note and clamp and take, fname .. " no longer goes through the shared helpers")
        assert(note < clamp and clamp < take, fname .. " clamps out of order (issue 369)")
    end)

    t.test(fname .. " does not repeat the helpers' steps itself", function()
        local _a, b = method(fname)
        for _j, step in ipairs({ "self._total_items = ", "self._total_pages = ",
                                 "self._page_items = ", "all_items.opds_open_ended" }) do
            assert(not b:find(step, 1, true), fname .. " still does " .. step .. " by hand")
        end
    end)
end

t.done()
