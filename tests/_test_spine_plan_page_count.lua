-- tests/_test_spine_plan_page_count.lua
-- The spine plan's page-count block: what the width uses, and what it leaves
-- behind on the record.
--
-- Run from the plugin root: lua tests/_test_spine_plan_page_count.lua
--
-- WHAT HAPPENED. The block resolves a count so the spine can be drawn at the
-- right width, and it did that correctly -- into a LOCAL. The record's own
-- page_count was assigned in one branch only (the sidecar read), so a count
-- that came from the persisted scan store made the spine wider and reached
-- nothing else: %page_count in the hero stayed empty for exactly the books the
-- scan had just measured. Device report, twice in two days.
--
-- Extracted rather than driven through SpineShelf.plan(): the block is a dozen
-- lines inside a 440-line function that needs a Screen, a font cache and a
-- populated BookInfoManager. Compiling it with an environment makes its
-- upvalues stubbable, which is the only way to say "the store had it and the
-- sidecar did not" precisely.

package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local whole = assert(io.open("lib/bookshelf_spine_shelf.lua")):read("*a")
-- The thickness locals (issue 387, SpineShelf.thicknessPages) sit between the
-- declaration and the block, so the match spans them.
local block = whole:match("\n(%s*local pages = src%.page_count\n.-\n%s*do\n.-\n%s*src%._spine_status_checked = true\n%s*end)\n")
assert(block, "the plan's page-count block moved or was renamed")

local function compile(code, env)
    if _G.setfenv then
        local f = assert(_G.loadstring(code))
        _G.setfenv(f, env)
        return f
    end
    return assert(load(code, "page-count block", "t", env))
end

-- opts: store = {p=, s=, known=, tag=} (tag defaults to "print"), sidecar = {pc=, status=}, record = {...}
local function run(opts)
    local record = opts.record or {}
    record.filepath = record.filepath or "/books/a.epub"
    local calls = { readProgress = 0, persist = 0 }
    local env = {
        pcall = pcall,
        src = record,
        ok_repo = true,
        _gettime = function() return 0 end,
        _t_pages = 0,
        SCAN_TAGS  = { print = true, layout = true, scan = true },
        SHOWN_TAGS = { print = true, stable = true, render = true },
        SpineShelf = {
            cachedProgress = function()
                local s = opts.store
                if not s then return nil, nil, false end
                return s.p, s.s, s.known == true, s.tag or "print", false
            end,
            persistProgress = function() calls.persist = calls.persist + 1 end,
        },
        Repo = {
            readProgress = function()
                calls.readProgress = calls.readProgress + 1
                local sc = opts.sidecar or {}
                return sc.pct, sc.status, nil, sc.pc
            end,
            -- Stands in for the real ladder tail, which _test_book_repository
            -- pins on its own. What matters here is that the block ASKS.
            pageCountFor = function(filepath, known)
                if tonumber(known) and tonumber(known) > 0 then return tonumber(known) end
                local n = filepath and filepath:match("p%((%d+)%)")
                return n and tonumber(n) or opts.tail_answer
            end,
        },
    }
    local pages, thick = compile(block .. "\nreturn pages, thick", env)()
    return pages, record, calls, thick
end

t.test("a count from the store reaches the record, not just the width", function()
    -- The bug. known=true, so nothing opens the sidecar: before the fix the
    -- width got 412 and record.page_count stayed nil.
    local pages, rec, calls = run{ store = { p = 412, s = "reading", known = true } }
    eq(pages, 412, "the width still gets its count")
    eq(rec.page_count, 412, "and so does anything reading the record")
    eq(calls.readProgress, 0, "a known store entry is not re-read from disk")
end)

t.test("a layout count sets the width and nothing else", function()
    -- Reddit report: extracted counts "way off, like a factor of 4". The
    -- scan's render is a spine-width scale; on the record it became the
    -- book's %page_count, badge and sort key.
    local pages, rec, calls, thick = run{
        store = { p = 1600, s = nil, known = true, tag = "layout" } }
    eq(thick.scan, 1600, "the width lost its count")
    eq(pages, nil)
    eq(rec.page_count, nil, "a layout count reached the record")
    eq(calls.readProgress, 0,
        "a width-only count must still spare the sidecar read on every plan")
end)

t.test("the filename marker reaches the record too", function()
    -- Nothing anywhere, so the tail runs; p(300) is free and explicit (#159).
    local pages, rec = run{ record = { filepath = "/books/Dune p(300).epub" } }
    eq(pages, 300)
    eq(rec.page_count, 300)
end)

t.test("the record's own count outranks the sidecar's", function()
    -- BIM's count is what the hero and the rows show. The sidecar's figure is
    -- the last render's, which differs with font size, so taking it here drew
    -- the same book a few pixels narrower on the shelf than anywhere else.
    local pages, rec, calls = run{
        record  = { page_count = 480 },
        store   = { p = 480, s = nil, known = false },
        sidecar = { pc = 351, status = "reading" },
    }
    eq(calls.readProgress, 1, "an unvalidated entry is still refreshed")
    eq(pages, 480, "the width keeps the record's count")
    eq(rec.page_count, 480)
    eq(rec.status, "reading", "the refresh is still worth making: status arrived")
end)

t.test("with no count of its own the record takes the sidecar's", function()
    local pages, rec = run{ sidecar = { pc = 351, status = "reading" } }
    eq(pages, 351)
    eq(rec.page_count, 351)
end)

t.test("a book with no count anywhere leaves the record alone", function()
    -- nil, not 0: spineWidthDp(nil) is the DEFAULT_PAGES width, and 0 would
    -- pin the book at MIN_W_DP as though it were a pamphlet.
    local pages, rec = run{}
    eq(pages, nil)
    eq(rec.page_count, nil)
    eq(rec._spine_status_checked, true, "still checked, so the glyph resolver stops asking")
end)

t.done()
