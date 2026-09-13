-- tests/_test_series_group_date_added.lua
-- A series group must carry latest_added, or "Sort by date added" buries it.
--
-- ── WHAT WENT WRONG ─────────────────────────────────────────────────────────
--
-- The sort engine's date_added comparator reads three shapes:
--
--     local av = a.date_added or a.latest_added or (a.attr and a.attr.modification)
--
-- and its own comment says latest_added is "set in _buildGroups so a 'Sort by
-- date added' on Authors / Genres / Series / Tags / Formats tabs surfaces
-- groups containing recently-added books first".
--
-- But the repo has TWO group builders. _buildGroups sets it. getSeriesGroups
-- has its own, which tracked `latest` (max read-time-or-mtime, for "latest
-- activity") and never latest_added -- so on a Series source every group came
-- back with nil, cmp's isMissing fired, and SORT_TO_END put it last.
--
-- Reported from a device: three books synced in, two appeared at the top of a
-- Home/Series chip sorted by "Most recently added", the third vanished after a
-- few minutes. It had not vanished -- it had been sorted to position ~242 of
-- 242. The delay is the giveaway: before metadata extraction the book has no
-- series, so it is a STANDALONE, and standalones do set latest_added (they are
-- built a few lines below the groups). Once BIM found its series it became a
-- group and fell off the end. A second book in the same library, third-newest
-- and in a series, had been missing the same way unnoticed.
--
-- Usage (from plugin root): lua tests/_test_series_group_date_added.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = dofile("tests/_helpers.lua")
local t = H.runner()

local src = assert(io.open("lib/bookshelf_book_repository.lua")):read("*a")
local eng = assert(io.open("lib/bookshelf_sort_engine.lua")):read("*a")

local body = src:match("\n(function Repo%.getSeriesGroups%(.-\nend)\n")
assert(body, "getSeriesGroups moved or was renamed")

t.test("a new series group starts with a date-added key", function()
    -- Without the field on the initialiser the first member's update below has
    -- nothing to compare against.
    -- Up to _seen rather than the first "}": the initialiser contains a
    -- nested `books = {}`, which a non-greedy brace match stops at.
    local init = body:match("g = {(%s*series_name.-_seen)")
    assert(init, "the group initialiser moved")
    assert(init:find("latest_added", 1, true),
        "the group initialiser does not declare latest_added: " .. init)
end)

t.test("each member can raise the group's date added", function()
    -- Max across members, like _buildGroups: a series is "recently added" if
    -- ANY volume in it is, which is what makes a new book in an old series
    -- surface at all.
    assert(body:find("g.latest_added", 1, true),
        "no member ever updates the group's latest_added")
end)

t.test("it is NOT the same field as `latest`", function()
    -- `latest` is max(read_time or mtime) and drives "latest activity"; reusing
    -- it for date-added would make merely OPENING an old book look like adding
    -- it, quietly reordering the shelf under the user.
    local lat = body:match("local t = read_time%[book%.filepath%][^\n]*")
    assert(lat, "the latest-activity line moved")
    assert(not lat:find("latest_added", 1, true),
        "date added is being taken from the read-time line: " .. lat)
end)

t.test("the cached shape carries it, so a cache hit sorts like a miss", function()
    -- The shape is what survives in _series_cache. Dropping the field here
    -- would make the bug come back only after the TTL warmed, which is far
    -- harder to spot than a consistent failure.
    -- Anchored on series_name: there is a second shapes[] stash nearby for
    -- STANDALONES, and matching that one passed while the group shape was
    -- still dropping the field.
    local stash = src:match("shapes%[#shapes %+ 1%] = {%s*series_name(.-)}")
    assert(stash, "the series-group shape stash moved")
    assert(stash:find("latest_added", 1, true),
        "the cached shape drops latest_added: " .. stash)
end)

t.test("and the shape is read back out again", function()
    local back = src:match("return {%s*series_name%s*=%s*shape%.series_name.-}")
    assert(back, "the shape-to-group conversion moved")
    assert(back:find("latest_added", 1, true),
        "the cached shape is rebuilt without latest_added: " .. back)
end)

-- ── the degrade path: a ONE-BOOK series ────────────────────────────────────
--
-- This is what the device report actually turned on. With "show singles and
-- series" (mode == "both") and hide-single set, _seriesReadout sets
-- `degrade`, skips any 1-book group, and re-adds it through addSingle. Both
-- missing books were the only volume of their series in the library, so
-- neither ever travelled as a group -- the group fix above could not reach
-- them, and the re-add carried `latest` but not latest_added.

t.test("a degraded one-book series keeps its date added", function()
    local add = src:match("addSingle%({%s*standalone%s*=%s*true(.-)}%)")
    assert(add, "the degrade re-add moved")
    assert(add:find("latest_added", 1, true),
        "a 1-book series loses its date added on the way back to a single, "
        .. "so it sorts to the END of Most recently added: " .. add)
end)

t.test("it takes it from the group shape, not from `latest`", function()
    -- s.latest folds in read time. Sourcing date-added from it would make
    -- opening an old single-volume book look like adding it.
    local add = src:match("addSingle%({%s*standalone%s*=%s*true(.-)}%)")
    assert(add:match("latest_added%s*=%s*s%.latest_added"),
        "expected latest_added = s.latest_added, got: " .. tostring(add))
end)

-- ── the contract this satisfies ────────────────────────────────────────────

t.test("the comparator really does need this field", function()
    -- Pins the reason. If the sort engine stops reading latest_added, the four
    -- assertions above are busywork and should be revisited rather than kept.
    assert(eng:find("a.date_added or a.latest_added", 1, true),
        "the date_added comparator no longer reads latest_added")
end)

t.test("a missing key sorts to the END, which is why it looked deleted", function()
    assert(eng:find("if am%s+then return SORT_TO_END", 1, false)
        or eng:find("if am          then return SORT_TO_END", 1, true),
        "cmp no longer sends a missing value to the end")
end)

t.done()
