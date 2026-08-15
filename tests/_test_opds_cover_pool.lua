-- tests/_test_opds_cover_pool.lua
-- _opdsCoverPool: the forked worker pool that fetches OPDS covers and child
-- feeds off the UI thread. This is the path that actually runs on device
-- (_opdsCoverStep is the fallback for platforms that cannot fork), and it was
-- the untested one.
--
-- What it has to keep doing:
--   * never more than the concurrency cap in flight
--   * cached covers cost no worker at all
--   * a resolved one-book folder's cover joins the queue STILL RUNNING, so a
--     catalog made entirely of folder tiles starts filling seconds in rather
--     than after the last resolve
--   * a superseded page kills its workers instead of finishing into a shelf
--     nobody is looking at
--   * a broken fork falls back to the sequential chain rather than dropping
--     the work
--
-- Extracted by name and run against stubs, like the step chain's suite: the
-- real method needs ffi, UIManager and the widget tree.
package.path = "./?.lua;./?/init.lua;" .. package.path

local pass, fail = 0, 0
local function eq(got, want, label)
    if got == want then pass = pass + 1
    else fail = fail + 1; print("FAIL " .. label .. ": got " .. tostring(got) .. " want " .. tostring(want)) end
end
local function ok(cond, label)
    if cond then pass = pass + 1 else fail = fail + 1; print("FAIL " .. label) end
end

local src = io.open("lib/bookshelf_widget.lua"):read("*a")
local body = src:match("\nfunction BookshelfWidget:_opdsCoverPool%(queue, token, state%)\n(.-)\nend\n")
ok(body ~= nil, "_opdsCoverPool(queue, token, state) found in the widget")
assert(body, "cannot continue without the function body")

local function compile(code, env)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, "_opdsCoverPool"))
        _G.setfenv(f, env)
        return f
    end
    return assert(load(code, "_opdsCoverPool", "t", env))
end

-- Rig. Every launched worker completes on the NEXT poll, handing back whatever
-- out_for() says. opts:
--   cached          - set of record ids already on disk
--   fork_fails      - true: runInSubProcess returns nil from the very first call
--   fork_fails_after- launch count after which forking starts failing
--   resolved_covers - feed url -> record id the resolve pipelines in
--   store_fails     - feed urls whose body will not store
local function rig(opts)
    opts = opts or {}
    local log = { launched = {}, terminated = {}, rebuilds = 0, dirty = 0,
                  stored = {}, fell_back = nil, max_in_flight = 0 }
    local pending = nil
    local next_pid = 100
    local live = {}          -- pid -> item, for workers not yet reaped
    local open_count = 0     -- workers forked but not yet harvested

    local ffiutil = {
        runInSubProcess = function(payload, _with_pipe)
            if opts.fork_fails then return nil end
            if opts.fork_fails_after and #log.launched >= opts.fork_fails_after then
                return nil
            end
            next_pid = next_pid + 1
            log.launched[#log.launched + 1] = next_pid
            live[next_pid] = (live[next_pid] or 0)
            open_count = open_count + 1
            if open_count > log.max_in_flight then log.max_in_flight = open_count end
            return next_pid, next_pid          -- pid doubles as the fd handle
        end,
        -- Everything launched is finished by the time the next poll looks.
        isSubProcessDone       = function(_pid) return true end,
        getNonBlockingReadSize = function(_fd) return 1 end,
        -- Harvesting a worker's output is what retires it, so this is where
        -- the in-flight count comes back down.
        readAllFromFD          = function(fd)
            open_count = open_count - 1
            return log.out_by_pid[fd] or ""
        end,
        terminateSubProcess    = function(pid)
            log.terminated[#log.terminated + 1] = pid
        end,
        writeToFD              = function() end,
    }
    log.out_by_pid = setmetatable({}, { __index = function() return "" end })

    local covers = {
        needsFetch = function(rec)
            -- Faithful to the real one: no record means no cover url, which
            -- means nothing to fetch -> false. The old stub returned true
            -- here, which is why it could not see a page item being dropped
            -- by the cover-skip branch.
            if type(rec) ~= "table" or rec.id == nil then return false end
            return not (opts.cached and opts.cached[rec.id])
        end,
        fetchPlan = function(rec, _creds)
            log.planned = (log.planned or 0) + 1
            return { url = "u", path = "p" }
        end,
        cachePath  = function() return "p" end,
        sweepCache = function() log.sweeps = (log.sweeps or 0) + 1 end,
    }
    local feed = { fetch = function() return "<feed/>" end }

    local BookshelfWidget = {}
    local self_tbl = {
        _rebuild = function() log.rebuilds = log.rebuilds + 1 end,
        _opdsEnsureCovers = function() log.rearms = (log.rearms or 0) + 1 end,
        _opdsCoverStep = function(_s, q, i, _tok, _st)
            log.fell_back = { n = #q, idx = i }
        end,
        _opds_cover_token = opts.token or 7,
        -- A landed page asks for the next one until the window is deep
        -- enough. opts.lookahead_pages is how many the stub will hand out.
        _opdsLookaheadItem = function(_self)
            log.lookahead_calls = (log.lookahead_calls or 0) + 1
            local left = (opts.lookahead_pages or 0) - (log.pages_queued or 0)
            if left <= 0 then return nil end
            log.pages_queued = (log.pages_queued or 0) + 1
            return { kind = "page", server_key = "srv", feed_url = "https://c/list",
                     fetch_url = "https://c/list?p=" .. (log.pages_queued + 1),
                     plan = opts.plan or 6, timeouts = {} }
        end,
    }
    BookshelfWidget.live = self_tbl

    local env = {
        require = function(name)
            if name == "ffi/util" then
                if opts.no_ffi then error("no ffi here") end
                return ffiutil
            end
            if name == "lib/bookshelf_opds_covers" then return covers end
            if name == "lib/bookshelf_opds_feed" then return feed end
            if name == "lib/bookshelf_cover_fetch" then return { download = function() return true end } end
            -- Only reached as the fallback when a chain carries no width of
            -- its own; the real value comes off the state.
            if name == "lib/bookshelf_opds_prefs" then
                return { CONCURRENCY = 3 }
            end
            error("unexpected require: " .. tostring(name))
        end,
        UIManager = {
            -- Two different schedules go through here. The pool's own next
            -- tick uses OPDS_POOL_POLL; collectLater (the zombie reaper) uses
            -- a 1-second beat. Counting the latter is how a test can see that
            -- a killed worker was queued for collection at all.
            scheduleIn = function(_self, secs, fn)
                if secs == 1 then
                    log.collected = (log.collected or 0) + 1
                else
                    pending = fn
                end
            end,
            setDirty   = function() log.dirty = log.dirty + 1 end,
        },
        BookshelfWidget = BookshelfWidget,
        _gettime = function()
            log.clock = (log.clock or 0) + 0.001
            return log.clock
        end,
        logger   = { dbg = function() end },
        string = string, math = math, tostring = tostring,
        ipairs = ipairs, pairs = pairs, type = type, pcall = pcall,
        _storeFeedPage = function(_sk, store_url, _fetched, _b)
            log.paged = (log.paged or 0) + 1
            log.paged_into = store_url
            return opts.page_stores ~= false
        end,
        _storeChildFeed = function(_sk, url, _b)
            if opts.store_fails and opts.store_fails[url] then return false end
            log.stored[#log.stored + 1] = url
            return true
        end,
        _opdsResolvedCoverItem = function(_sk, url)
            local id = opts.resolved_covers and opts.resolved_covers[url]
            if not id then return nil end
            log.pipelined = (log.pipelined or 0) + 1
            return { kind = "cover", rec = { id = id } }
        end,
        _opdsPaintThreshold = function(painted)
            painted = painted or 0
            if painted < 1 then return 1 end
            if painted < 3 then return 2 end
            return 4
        end,
        -- The ceiling the pool falls back to when an item carries no plan.
        OPDS_LOOKAHEAD_MAX_REQUESTS = 6,
        OPDS_FETCH_CONCURRENCY = 3,
        OPDS_POOL_POLL         = 0.15,
    }

    local fn = compile("local self, queue, token, state = ... ; " .. body, env)
    return {
        log = log,
        self_tbl = self_tbl,
        widget_class = BookshelfWidget,
        -- Everything launched so far reports "1" (a cover landed) or a feed
        -- body, depending on what its item was.
        answer_all = function(text)
            for _i, pid in ipairs(log.launched) do
                log.out_by_pid[pid] = text or "1"
            end
        end,
        start = function(queue, token, state)
            pending = nil
            fn(self_tbl, queue, token, state)
        end,
        poll = function()
            local p = pending
            if not p then return false end
            pending = nil
            p()
            return true
        end,
        has_pending = function() return pending ~= nil end,
        fresh_state = function()
            return { creds = {}, landed = 0, painted = 0, resolved = 0 }
        end,
    }
end

local function cover_queue(n)
    local q = {}
    for i = 1, n do q[i] = { kind = "cover", rec = { id = i } } end
    return q
end
local function resolve_queue(n)
    local q = {}
    for i = 1, n do
        q[i] = { kind = "resolve", server_key = "srv",
                 feed_url = "https://c/detail/" .. i,
                 timeouts = { block_timeout = 5, total_timeout = 10 } }
    end
    return q
end

-- ── concurrency cap ─────────────────────────────────────────────────────────
do
    local r = rig()
    r.start(cover_queue(8), 7, r.fresh_state())
    eq(#r.log.launched, 3, "no width on the state falls back to the default of 3")
    r.answer_all("1")
    r.poll()
    eq(#r.log.launched, 6, "each finished worker is replaced, still 3 at a time")
    eq(r.log.max_in_flight, 3, "never exceeds the cap")
end

-- The width is per catalog (Prefs.concurrency), carried on the chain's state.
do
    local r = rig()
    local st = r.fresh_state()
    st.concurrency = 1
    r.start(cover_queue(8), 7, st)
    eq(#r.log.launched, 1, "a catalog set to 1 fetches strictly one at a time")
    r.answer_all("1")
    r.poll()
    eq(r.log.max_in_flight, 1, "and never has two in flight")
end

do
    local r = rig()
    local st = r.fresh_state()
    st.concurrency = 6
    r.start(cover_queue(8), 7, st)
    eq(#r.log.launched, 6, "a LAN server set to 6 fills six workers")
    eq(r.log.max_in_flight, 6, "up to its own cap and no further")
end

-- ── cached covers cost nothing ──────────────────────────────────────────────
do
    local r = rig{ cached = { [1] = true, [2] = true, [3] = true } }
    r.start(cover_queue(4), 7, r.fresh_state())
    eq(#r.log.launched, 1, "three cached records are skipped without a worker")
end

-- ── the first cover repaints on its own ─────────────────────────────────────
do
    local r = rig()
    local st = r.fresh_state()
    r.start(cover_queue(6), 7, st)
    r.answer_all("1")
    r.poll()
    eq(st.landed, 3, "the first three landed")
    ok(r.log.rebuilds >= 1, "and the shelf repainted rather than staying blank")
end

-- ── a resolve pipelines its cover into the running queue ────────────────────
-- The point of the whole exercise: on a catalog of folder tiles, the covers
-- used to wait for the tail re-arm, so nothing appeared until the LAST resolve
-- came back.
do
    local r = rig{ resolved_covers = { ["https://c/detail/1"] = 91,
                                       ["https://c/detail/2"] = 92,
                                       ["https://c/detail/3"] = 93 } }
    local st = r.fresh_state()
    st.want_covers = true
    local q = resolve_queue(3)
    r.start(q, 7, st)
    eq(#r.log.launched, 3, "all three resolves are in flight")
    r.answer_all("<feed/>")
    r.poll()
    eq(st.resolved, 3, "all three resolved")
    eq(#q, 6, "and each appended its book's cover to the queue being drained")
    eq(#r.log.launched, 6, "which were launched in the SAME chain, not after it")
    r.answer_all("1")
    r.poll()
    eq(st.landed, 3, "the pipelined covers landed inside this chain")
end

do
    local r = rig{ resolved_covers = { ["https://c/detail/1"] = 91 } }
    local st = r.fresh_state()              -- want_covers left unset
    local q = resolve_queue(1)
    r.start(q, 7, st)
    r.answer_all("<feed/>")
    r.poll()
    eq(#q, 1, "tap-only covers: a resolve queues no download")
    eq((r.log.pipelined or 0), 0, "and the resolved record is not even looked up")
end

do
    local r = rig{ store_fails = { ["https://c/detail/1"] = true },
                   resolved_covers = { ["https://c/detail/1"] = 91 } }
    local st = r.fresh_state()
    st.want_covers = true
    local q = resolve_queue(1)
    r.start(q, 7, st)
    r.answer_all("<feed/>")
    r.poll()
    eq(#q, 1, "a body that would not store appends nothing")
    eq(st.resolved, 0, "and leaves the tile unresolved, so it stays retryable")
end

-- ── the next page is fetched in the pool, silently ──────────────────────────
-- The first attempt at a lookahead drove _opdsFetchMore, the USER-FACING
-- fetch: Trapper, a modal progress line that yields for input, and a tail that
-- re-clamps the cursor. It blocked input on a page already delivered and moved
-- the shelf under a swipe in flight. This one rides the pool, which forks for
-- the request, touches no cursor and shows no widget.
do
    local r = rig()
    local st = r.fresh_state()
    local q = { { kind = "page", server_key = "srv",
                  feed_url = "https://c/list", fetch_url = "https://c/list?p=2",
                  timeouts = {} } }
    r.start(q, 7, st)
    eq(#r.log.launched, 1, "the page fetch goes through a forked worker")
    r.answer_all("<feed/>")
    r.poll()
    eq(r.log.paged, 1, "the body is parsed and stored by the PARENT")
    eq(r.log.paged_into, "https://c/list",
        "records are filed under the feed on screen, not under its rel=next")
    eq(st.paged, 1, "and counted")
    ok(r.log.rebuilds >= 1, "the tail repaints so the page count updates")
end

do
    -- A page that would not store must not be counted: the window did not
    -- grow, so nothing has been gained and the next turn still needs a fetch.
    local r = rig{ page_stores = false }
    local st = r.fresh_state()
    r.start({ { kind = "page", server_key = "srv", feed_url = "https://c/list",
                fetch_url = "https://c/list?p=2", timeouts = {} } }, 7, st)
    r.answer_all("<feed/>")
    r.poll()
    eq(st.paged or 0, 0, "an unusable page counts for nothing")
end

do
    -- Paging away kills it like any other worker: the user is somewhere else
    -- and the page they were reading ahead of is gone.
    local r = rig()
    r.start({ { kind = "page", server_key = "srv", feed_url = "https://c/list",
                fetch_url = "https://c/list?p=2", timeouts = {} } }, 7, r.fresh_state())
    r.self_tbl._opds_cover_token = 8
    r.poll()
    eq(#r.log.terminated, 1, "an abandoned lookahead is killed, not left running")
end

do
    -- Ordering is not cosmetic here. Queued LAST, behind ten covers at 3-5
    -- seconds each on Internet Archive, the lookahead never ran: the reader
    -- paged first, the token bumped, and the pool killed an item that had not
    -- started. Measured on device - three decisions to fetch, zero kind=page
    -- workers, and the blocking fetch it exists to prevent five seconds later
    -- every time.
    local r = rig()
    local st = r.fresh_state()
    st.concurrency = 2                        -- narrower than the queue
    local q = cover_queue(6)
    table.insert(q, 1, { kind = "page", server_key = "srv",
                         feed_url = "https://c/list",
                         fetch_url = "https://c/list?p=2", timeouts = {} })
    r.start(q, 7, st)
    r.answer_all("<feed/>")
    r.poll()
    eq(r.log.paged, 1, "the lookahead runs in the FIRST wave, not after the covers")
end

do
    -- Eager: a landed page queues the next until the window is deep enough.
    -- The chain is sequential (each url lives in the previous page), so depth
    -- is reached one request at a time - but every one of them happens in a
    -- forked worker, not on the render path.
    local r = rig{ lookahead_pages = 3 }
    local st = r.fresh_state()
    local q = { { kind = "page", server_key = "srv", feed_url = "https://c/list",
                  fetch_url = "https://c/list?p=2", timeouts = {} } }
    r.start(q, 7, st)
    r.answer_all("<feed/>")
    r.poll()                     -- page 2 lands, queues page 3
    eq(#q, 2, "a landed page queues the next")
    r.answer_all("<feed/>")
    r.poll()                     -- page 3 lands, queues page 4
    eq(#q, 3, "and keeps going while the lookahead still wants more")
    r.answer_all("<feed/>")
    r.poll()
    r.answer_all("<feed/>")
    r.poll()
    eq(#q, 4, "stopping when the lookahead declines, not running away")
    ok(st.paged >= 3, "every page it walked was stored")
end

do
    -- A page that will not store must not extend the walk: no progress was
    -- made, so asking for more would spin against a server giving us nothing.
    local r = rig{ lookahead_pages = 5, page_stores = false }
    local st = r.fresh_state()
    local q = { { kind = "page", server_key = "srv", feed_url = "https://c/list",
                  fetch_url = "https://c/list?p=2", timeouts = {} } }
    r.start(q, 7, st)
    r.answer_all("<feed/>")
    r.poll()
    eq(#q, 1, "an unusable page does not queue another")
end

do
    -- The budget is spent in requests, planned from the page size the server
    -- declared. A server that serves two records a page must not turn one
    -- render into a crawl - whatever the cap leaves, the next render asks for.
    local r = rig{ lookahead_pages = 10, plan = 2 }
    local st = r.fresh_state()
    local q = { { kind = "page", server_key = "srv", feed_url = "https://c/list",
                  fetch_url = "https://c/list?p=2", plan = 2, timeouts = {} } }
    r.start(q, 7, st)
    for _i = 1, 6 do r.answer_all("<feed/>"); r.poll() end
    eq(st.paged, 2, "the run stops at its planned request budget")
    ok(#q <= 3, "and queues no more than the budget allows, got " .. #q)
end

-- ── the pool narrows when the server pushes back ────────────────────────────
-- A fixed width cannot be right for both a healthy catalogue and one that
-- meters its clients, and only one of those was reachable to measure. So the
-- pool watches what comes back: an empty result is a timeout, a refusal or an
-- error page, and it halves rather than finishing the queue at a width the
-- server has already rejected.
do
    local r = rig()
    local st = r.fresh_state()
    st.concurrency = 8
    r.start(cover_queue(40), 7, st)
    eq(#r.log.launched, 8, "opens at the width it was given")
    r.answer_all("")                     -- every worker comes back empty
    r.poll()
    ok(r.log.max_in_flight <= 8, "never exceeds the opening width")
    local after_first = #r.log.launched
    r.answer_all("")
    r.poll()
    -- 8 -> 4 -> 2: each poll halves once per failed worker, floored at 1.
    ok(#r.log.launched - after_first < 8,
        "a failing server gets fewer workers on the next round, not the same 8")
end

do
    local r = rig()
    local st = r.fresh_state()
    st.concurrency = 4
    r.start(cover_queue(40), 7, st)
    r.answer_all("1")                    -- everything succeeds
    r.poll()
    eq(r.log.max_in_flight, 4, "a healthy server keeps the full width")
end

do
    -- The floor matters: halving to zero would stall the pool with nothing in
    -- flight and nothing able to start it.
    local r = rig()
    local st = r.fresh_state()
    st.concurrency = 1
    r.start(cover_queue(10), 7, st)
    r.answer_all("")
    r.poll()
    ok(#r.log.launched > 1, "a width of 1 keeps making progress after a failure")
end

-- ── paging abandons the chain ───────────────────────────────────────────────
do
    local r = rig()
    r.start(cover_queue(8), 7, r.fresh_state())
    eq(#r.log.launched, 3, "three workers out")
    r.self_tbl._opds_cover_token = 8            -- the user paged
    r.poll()
    eq(#r.log.terminated, 3, "every in-flight worker is killed")
    ok(not r.has_pending(), "and the pool stops polling")
    -- Killing is not collecting: SIGKILL leaves a zombie until someone
    -- waitpid()s it, and this loop is the last thing that knows the pid.
    -- Four of these were found on the test device after an evening's browsing.
    eq(r.log.collected, 3, "and every killed worker is queued for collection")
end

do
    -- Shelf torn down inside the window: same abandon path as paging.
    local r = rig()
    r.start(cover_queue(8), 7, r.fresh_state())
    r.widget_class.live = { not_us = true }
    r.poll()
    eq(#r.log.terminated, 3, "a closed shelf kills its workers too")
    ok(not r.has_pending(), "and stops polling")
    eq(r.log.collected, 3, "and collects them, so a closed shelf leaves no zombies")
end

-- ── the tail ────────────────────────────────────────────────────────────────
do
    local r = rig()
    local st = r.fresh_state()
    r.start(cover_queue(2), 7, st)
    r.answer_all("1")
    r.poll()                                    -- both land, queue drained
    eq(st.landed, 2, "both covers landed")
    eq((r.log.sweeps or 0), 1, "the cache cap is enforced once at the tail")
    eq((r.log.rearms or 0), 0, "a covers-only pass does not re-arm")
end

do
    local r = rig{ resolved_covers = {} }
    local st = r.fresh_state()
    st.want_covers = true
    r.start(resolve_queue(1), 7, st)
    r.answer_all("<feed/>")
    r.poll()
    eq(st.resolved, 1, "the folder resolved")
    eq((r.log.rearms or 0), 1, "the tail re-arm is still the backstop")
    ok(r.log.rebuilds >= 1, "and the flattened tile is repainted")
end

-- ── forking unavailable / broken ────────────────────────────────────────────
do
    local r = rig{ no_ffi = true }
    r.start(cover_queue(3), 7, r.fresh_state())
    ok(r.log.fell_back ~= nil, "no ffi at all: hands the whole queue to the step chain")
    eq(r.log.fell_back.n, 3, "with nothing dropped")
end

do
    local r = rig{ fork_fails = true }
    r.start(cover_queue(3), 7, r.fresh_state())
    ok(r.log.fell_back ~= nil, "a fork that fails immediately falls back")
    eq(r.log.fell_back.n, 3, "with the whole queue intact")
end

do
    local r = rig{ fork_fails_after = 2 }
    local st = r.fresh_state()
    r.start(cover_queue(6), 7, st)
    eq(#r.log.launched, 2, "two workers got out before forking broke")
    r.answer_all("1")
    r.poll()
    ok(r.log.fell_back ~= nil, "the remainder goes to the step chain")
    ok(r.log.fell_back.n > 0, "and it is the UNFETCHED remainder, not nothing")
end

print(string.format("opds cover pool: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
