-- tests/_test_spine_plan_suffix.lua
-- A spine page's items are the shelf's list FROM the page's first item, so a
-- page starting on a new item asked the plan with a shorter list, missed its
-- one-slot cache and rebuilt every entry: on a PW5 Genres shelf of 111
-- genres, 1,800 entries and 1.1-1.4 s on almost every turn (the debug line
-- read "first diff: n=1835 -> n=1818"). A list that is the TAIL of the cached
-- one now takes the cached entries from that item on, renumbered exactly as a
-- fresh build of that list numbers them.
package.path = "./?.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()
local src = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")
local body = src:match("\nlocal function _suffixEntries%(pc, base, ids%)\n(.-)\nend\n")

local function suffix(pc, base, ids)
    assert(body, "_suffixEntries not found")
    return load("local pc, base, ids = ...\n" .. body, "sfx", "t",
        { pairs = pairs, setmetatable = setmetatable })(pc, base, ids)
end

-- Entries as a fresh build makes them for a list of item sizes: item_idx and
-- run_idx count from 1, the first spine has no gap and no seed, every later
-- item's first spine has a gap and a seed naming its neighbours.
local function build(names, sizes)
    local out = {}
    for i = 1, #names do
        for n = 1, sizes[i] do
            local first_of_item = (n == 1)
            out[#out + 1] = {
                item_idx = i, run_idx = i, label = names[i] .. n,
                gap_before = (#out == 0) and 0 or (first_of_item and 20 or 4),
                gap_base   = (#out == 0) and 0 or (first_of_item and 20 or 4),
                orn_seed   = (#out > 0 and first_of_item) and ("grp|" .. names[i - 1] .. "|" .. names[i]) or nil,
            }
        end
    end
    return out
end

local NAMES, SIZES = { "a", "b", "c", "d" }, { 3, 2, 4, 1 }
local pc = { base = "B", ids = { "a:3", "b:2", "c:4", "d:1" }, entries = build(NAMES, SIZES) }

t.test("a tail of the cached list gives a fresh build's entries", function()
    local got = suffix(pc, "B", { "c:4", "d:1" })
    local want = build({ "c", "d" }, { 4, 1 })
    assert(got and #got == #want, "count")
    for i = 1, #want do
        for _i, k in ipairs({ "item_idx", "run_idx", "label", "gap_before", "gap_base", "orn_seed" }) do
            assert(got[i][k] == want[i][k], ("entry %d %s: %s vs %s"):format(i, k, tostring(got[i][k]), tostring(want[i][k])))
        end
    end
end)

t.test("the cached entries are left as they were", function()
    suffix(pc, "B", { "b:2", "c:4", "d:1" })
    assert(pc.entries[4].item_idx == 2 and pc.entries[4].gap_before == 20 and pc.entries[4].orn_seed)
end)

t.test("anything that isn't a tail under the same options misses", function()
    assert(suffix(pc, "OTHER", { "c:4", "d:1" }) == nil, "other options")
    assert(suffix(pc, "B", { "c:4", "x:1" }) == nil, "different items")
    assert(suffix(pc, "B", { "a:3", "b:2", "c:4", "d:1" }) == nil, "same length is the exact-key path's")
    assert(suffix(pc, "B", { "z:1", "a:3", "b:2", "c:4", "d:1" }) == nil, "longer")
    assert(suffix(nil, "B", { "d:1" }) == nil)
    assert(suffix({ base = "B", entries = {} }, "B", { "d:1" }) == nil, "an old slot without ids")
end)

t.test("the plan stores what the tail check needs and uses it on a miss", function()
    assert(src:find("_plan_cache = { key = cache_key, entries = entries, base = base_key, ids = ids }", 1, true))
    assert(src:find("cached = _suffixEntries(_plan_cache, base_key, ids)", 1, true))
end)

t.done()
