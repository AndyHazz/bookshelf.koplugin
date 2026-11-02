-- tests/_test_page_scan_skip.lua
-- "Only books without a page count" (573): which books the scan leaves alone.
--   * A book whose count came from being opened (the reader's own page count
--     in its sidecar) has a count, and is skipped.
--   * A sidecar that changed since its row was stored (the book was read, or
--     synced) clears the row's reading state, not its scanned count: the scan
--     saw no count there and counted the book again.
-- Both driven against the real bodies, compiled with stub upvalues.
-- Usage (from plugin root): lua tests/_test_page_scan_skip.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

local function compile(code, env, name)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, name))
        _G.setfenv(f, env)
        return f
    end
    return assert(load(code, name, "t", env))
end

-- ── classify (main.lua) ────────────────────────────────────────────────────
local main = io.open("main.lua"):read("*a")
local classify_body = main:match("\n    local function classify%(%)\n(.-)\n    end\n")
assert(classify_body, "scanPageCounts' classify() moved or was renamed")

-- book: { p=, psrc=, opened=, pc=, pc_src= }
local function classify(book, recount)
    local env = setmetatable({
        fps = { "/b/a.epub" }, maybeBreathe = function() end,
        opts = { recount = recount }, skipped = 0, todo = {},
        Repo = {
            pageCountFromFilename = function() return nil end,
            readProgress = function() return nil, nil, nil, book.pc, nil, book.pc_src end,
        },
        SpineShelf = {
            cachedProgress = function() return book.p, nil, false, book.psrc, book.opened end,
        },
    }, { __index = _G })
    compile(classify_body, env, "classify")()
    return #env.todo == 0 and "skipped" or "counted"
end

t.test("a count from opening the book is a count: skipped", function()
    eq(classify({ pc = 312, pc_src = "render" }), "skipped", "sidecar's own count rescanned")
    eq(classify({ p = 312, psrc = "render", opened = true }), "skipped", "stored opened count rescanned")
end)

t.test("Recount all still recounts it", function()
    eq(classify({ pc = 312, pc_src = "render" }, true), "counted")
end)

t.test("a book with no count at all is counted", function()
    eq(classify({}), "counted")
end)

t.test("the scan's own counts are skipped, as before", function()
    eq(classify({ p = 200, psrc = "print" }), "skipped")
    eq(classify({ p = 200, psrc = "user" }), "skipped")
end)

-- ── cachedProgress (lib/bookshelf_spine_shelf.lua) ─────────────────────────
local spine = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")
local cp_body = spine:match("\nfunction SpineShelf%.cachedProgress%(fp%)\n(.-)\nend\n")
assert(cp_body, "SpineShelf.cachedProgress moved or was renamed")

t.test("a changed sidecar drops the reading state, keeps the scanned count", function()
    local row = { p = 240, psrc = "user", s = "reading", sk = true, m = 100 }
    local put
    local env = setmetatable({
        _facts = function() return {
            get = function() return row end,
            put = function(_fp, f) put = f end,
        } end,
        _progress_validated = {},
        _sidecarMtime = function() return 200 end,
    }, { __index = _G })
    local f = compile("local fp = ...\n" .. cp_body, env, "cachedProgress")
    local p, s, known, psrc = f("/b/a.epub")
    eq(p, 240, "scanned count dropped: the scan counted the book again")
    eq(psrc, "user")
    eq(s, nil); eq(known, false)
    eq(put.s, false); eq(put.sk, false); eq(put.p, nil, "count cleared from the row")
end)

t.test("a changed sidecar: a count the sidecar gave is read again", function()
    for _i, tag in ipairs({ "render", "stable" }) do
        local row = { p = 240, psrc = tag, s = "reading", sk = true, m = 100 }
        local env = setmetatable({
            _facts = function() return { get = function() return row end, put = function() end } end,
            _progress_validated = {},
            _sidecarMtime = function() return 200 end,
        }, { __index = _G })
        local p = compile("local fp = ...\n" .. cp_body, env, "cachedProgress")("/b/a.epub")
        eq(p, nil, tag .. " count kept after its sidecar changed")
    end
end)

t.done()
