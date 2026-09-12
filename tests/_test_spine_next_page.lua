-- tests/_test_spine_next_page.lua
-- Where the spine plan says the NEXT page begins.
--
-- ── THE BUG ─────────────────────────────────────────────────────────────────
--
-- The shelf cursor is an ITEM index, and a grouped shelf's item is a whole
-- group: a Genres shelf where "Fantasy" holds 157 books has those 157 books
-- as ONE item. A page fits about 52 of them, so the page finishes ZERO items,
-- and the old code said:
--
--     shown = fully and last_item or (last_item - 1)   -- = 0 here
--     if shown < 1 then shown = 1 end                  -- so: 1
--
-- Stepping the cursor by one item then stepped past the WHOLE group. Reported
-- from a device: page 1 read "1-52 of 1236", one tap forward read "158-207",
-- and books 53-157 of Fantasy could not be reached in either direction. Every
-- genre and author bigger than one page lost everything after its first
-- pageful. The floor's own comment said it existed "so a group larger than a
-- whole page can still be advanced past", which is exactly the wrong remedy:
-- the group should be advanced THROUGH.
--
-- ── WHAT IS PINNED HERE ─────────────────────────────────────────────────────
--
-- plan() now also reports where the next page starts, as an item index plus a
-- count of that item's spines already behind us, and takes that count back as
-- opts.skip. This exercises the block that computes it: the arithmetic is the
-- whole fix, and it is the part that must not drift.
--
-- Extracted rather than driven through SpineShelf.plan(), for the reason
-- tests/_test_spine_plan_page_count.lua gives: plan is a 400-line function
-- that needs a Screen, a font cache and a populated BookInfoManager.
--
-- Usage (from plugin root): lua tests/_test_spine_next_page.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = dofile("tests/_helpers.lua")
local t = H.runner()
local eq = H.eq

local whole = assert(io.open("lib/bookshelf_spine_shelf.lua")):read("*a")
local block = whole:match("\n(%s*local shown, next_item, next_skip = 0, nil, 0\n.-\n%s*end)\n%s*_flushLooks%(%)")
assert(block, "the plan's next-page block moved or was renamed")

local function compile(code, env)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, "next-page block"))
        _G.setfenv(f, env)
        return f
    end
    return assert(load(code, "next-page block", "t", env))
end

-- items: a list of group sizes, e.g. {157, 60} is two groups.
-- last: how many of the flattened spines this page fitted.
-- skip: how many were already behind us when the page started.
local function run(sizes, last, skip)
    local entries = {}
    for item = 1, #sizes do
        for _n = 1, sizes[item] do
            entries[#entries + 1] = { item_idx = item }
        end
    end
    -- plan drops the skipped head before laying out, so the block sees the
    -- same shortened list it would see on device.
    skip = skip or 0
    if skip > 0 then
        local kept = {}
        for i = skip + 1, #entries do kept[#kept + 1] = entries[i] end
        entries = kept
    end
    local env = { entries = entries, rows = { { last = last } }, skip = skip }
    local f = compile(block .. " ; return shown, next_item, next_skip", env)
    local shown, next_item, next_skip = f()
    return { shown = shown, item = next_item, skip = next_skip }
end

-- ── The reported case ───────────────────────────────────────────────────────

t.test("a group bigger than a page resumes INSIDE it", function()
    -- Fantasy: 157 books, 52 fit. The next page must be the same item, 52
    -- spines in -- not the item after it.
    local r = run({ 157, 60 }, 52)
    eq(r.item, 1, "still inside Fantasy")
    eq(r.skip, 52, "carrying on from where the page stopped")
end)

t.test("the second page of a group resumes further in, not back at 52", function()
    -- Continuing the above: starting 52 in, another 52 fit.
    local r = run({ 157, 60 }, 52, 52)
    eq(r.item, 1)
    eq(r.skip, 104, "the skip accumulates across pages of the same group")
end)

t.test("the LAST page of a group hands on to the next item", function()
    -- 157 books, 104 already behind, 53 remain and all fit.
    local r = run({ 157, 60 }, 53, 104)
    eq(r.item, 2, "Fantasy is finished, so the next genre starts")
    eq(r.skip, 0, "and it starts at its beginning")
end)

t.test("no book is skipped and none repeats across a whole group", function()
    -- Walk the group the way the shelf does and account for every spine.
    local sizes, page = { 157, 60 }, 52
    local skip, seen, guard = 0, 0, 0
    while skip < sizes[1] and guard < 20 do
        guard = guard + 1
        local fits = math.min(page, sizes[1] - skip)
        local r = run(sizes, fits, skip)
        seen = seen + fits
        if r.item ~= 1 then break end
        eq(r.skip, skip + fits, "each page must resume exactly where the last ended")
        skip = r.skip
    end
    eq(seen, sizes[1], "every book in the group is reachable, exactly once")
end)

-- ── The cases that already worked, which must keep working ──────────────────

t.test("items that fit whole still advance in item units", function()
    -- Three small groups, all complete on this page.
    local r = run({ 4, 5, 6 }, 15)
    eq(r.shown, 3, "all three finished")
    eq(r.item, 4, "the next page starts at the item after them")
    eq(r.skip, 0)
end)

t.test("a page ending exactly on a group boundary does not resume inside it", function()
    local r = run({ 10, 10 }, 10)
    eq(r.shown, 1, "the first group finished")
    eq(r.item, 2); eq(r.skip, 0)
end)

t.test("a page cut mid-group reports only the groups it FINISHED", function()
    -- Two complete groups then part of a third.
    local r = run({ 4, 5, 100 }, 12)
    eq(r.shown, 2, "the third is unfinished, so it is not counted as shown")
    eq(r.item, 3); eq(r.skip, 3, "three of the third group are behind us")
end)

t.test("the whole window fitting names the item after the last", function()
    -- Nothing follows in the supplied slice; the caller decides if more exist.
    local r = run({ 3, 3 }, 6)
    eq(r.item, 3)
    eq(r.skip, 0)
end)

t.test("shown never drops below one, so a stuck page is still impossible", function()
    -- The old floor stays: it is the STEP that no longer relies on it.
    local r = run({ 200 }, 52)
    eq(r.shown, 1)
end)

t.done()
