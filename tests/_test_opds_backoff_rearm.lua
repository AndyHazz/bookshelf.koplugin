-- tests/_test_opds_backoff_rearm.lua
-- Backing off an OPDS catalog is a PAUSE, not a stop.
--
-- THE REGRESSION (found on device while testing the issue 434 back-off).
-- Once the cover pool saw a 429 it stopped filling, which is right, and then
-- nothing ever asked for the rest. The cover chain is armed by a page event,
-- so the covers on the page already on screen simply never arrived:
--
--     "covers seem to stop loading until I go back and forth in pagination
--      to jog them in"  (maintainer, on a PW5 against a capped mock)
--
-- Before the back-off the pool narrowed and carried on, so covers did land,
-- just slowly. Stopping dead was worse for the reader than the bug being
-- fixed, which is the trade this file guards.
--
-- THE SHAPE OF THE FIX. The abandoned run schedules its own retry for when
-- the pause lapses, and re-arms through _opdsEnsureCovers rather than
-- resuming the dead queue, so what gets fetched is recomputed against what is
-- on screen THEN. Three properties matter and all three are cheap to lose:
--
--   1. it retries at all;
--   2. it waits for the back-off rather than retrying immediately, which
--      would just spend the window again;
--   3. it is guarded by the chain token, so a page turn during the wait
--      cancels it instead of fetching covers for a page nobody is on.
--
-- Source-anchored because the pool is a forked, polled, token-guarded
-- state machine; the behaviour itself was verified on device. If this ever
-- becomes extractable, prefer driving it.
--
-- Usage (from plugin root): lua tests/_test_opds_backoff_rearm.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq
local src = io.open("lib/bookshelf_widget.lua"):read("*a")

-- The tail of the pool, from the rate-limit branch to the end of the run.
local tail = src:match("(if state%.ratelimited and stillCurrent%(%) then.-\n        end)")
assert(tail, "the rate-limited re-arm moved or was renamed")
local code = tail:gsub("%-%-[^\n]*", "")

t.test("an abandoned run comes back for the rest by itself", function()
    assert(code:find("_opdsEnsureCovers", 1, true),
        "nothing re-arms the chain, so the current page's covers never arrive")
    assert(code:find("UIManager:scheduleIn", 1, true),
        "the retry must be scheduled, not run inline")
end)

t.test("it waits for the back-off it just recorded", function()
    -- Retrying immediately would spend the window the server is waiting to
    -- clear, which is the whole thing the back-off exists to stop.
    assert(code:find("rateLimitedFor", 1, true),
        "the wait must come from the recorded back-off, not a constant")
    local at_wait  = code:find("rateLimitedFor", 1, true)
    local at_sched = code:find("UIManager:scheduleIn", 1, true)
    assert(at_wait and at_sched and at_wait < at_sched,
        "the delay has to be worked out before it is scheduled with")
end)

t.test("a page turn during the wait cancels it", function()
    -- stillCurrent() compares the chain token, which every new chain bumps.
    -- Without the check inside the callback, a retry fired for a page the
    -- reader left would fetch covers nothing is going to paint.
    local n = select(2, code:gsub("stillCurrent%(%)", ""))
    assert(n >= 2,
        "expected the guard both before scheduling and inside the callback, found " .. n)
    local at_sched = code:find("UIManager:scheduleIn", 1, true)
    local inside   = code:find("stillCurrent()", at_sched, true)
    assert(inside, "the scheduled callback must re-check before it acts")
end)

t.test("the marker the child writes is distinguishable from a body", function()
    -- The forked worker cannot record the back-off itself (its memory is
    -- discarded), so it writes a marker. If that marker could occur in a real
    -- feed, a legitimate body would be read as a refusal.
    local Feed = dofile("lib/bookshelf_opds_feed.lua")
    local marker = Feed.RATE_LIMIT_MARKER
    eq(type(marker), "string", "the marker exists")
    eq(marker:sub(1, 1), "\0", "it starts with a NUL, which XML and JSON cannot")
    assert(not marker:find("<", 1, true) and not marker:find("{", 1, true),
        "and cannot be mistaken for the start of a feed")
end)

t.test("a refused COVER is what actually triggers the back-off", function()
    -- Measured on device against a capped mock: a page of twenty books made
    -- twenty requests and the log showed 3 x 200 then 7 x 429, ALL of them
    -- covers -- and no back-off at all, because covers do not go through
    -- OpdsFeed.fetch. They go through CoverFetch.download, which reported a
    -- refusal as the opaque string "download failed (429)". The pool could
    -- only narrow and carry on, and the refused covers were dropped.
    local cf = io.open("lib/bookshelf_cover_fetch.lua"):read("*a")
    assert(cf:find('return nil, "ratelimited"', 1, true),
        "the cover download must report a 429 in the same vocabulary as the feed")

    local wsrc = io.open("lib/bookshelf_widget.lua"):read("*a")
    -- Both workers, feed and cover, have to write the marker.
    local n = select(2, wsrc:gsub("RATE_LIMIT_MARKER", ""))
    assert(n >= 3,
        "expected the marker written by both workers and read by the parent, found " .. n)

    -- And the refusal must be attributable: a cover item carries no
    -- fetch_url, so without its own url the back-off is recorded against
    -- nil and no pause is ever taken.
    assert(wsrc:find("item.cover_url = plan.url", 1, true),
        "a cover item must carry the url it fetched from")
    assert(wsrc:find("or e.item.cover_url", 1, true),
        "and the collector must fall back to it when attributing a refusal")
end)

t.done()
