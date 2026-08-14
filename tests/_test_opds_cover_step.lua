-- tests/_test_opds_cover_step.lua
-- The stepwise automatic-cover chain: one cover per scheduled tick, abandoned
-- the moment the page it was fetching for stops being the page on screen.
--
-- This exists because the thing it protects is a FEELING -- "paging feels
-- stuck" -- and the mechanism that produces it is invisible from the outside.
-- The previous cover pass downloaded a whole page serially inside one call
-- with nothing yielding, so on Internet Archive (8 seconds a cover, measured)
-- the shelf froze in 20-second blocks and page turns did not register. The
-- guarantees below are what replaced that, and each is one line of code that a
-- later edit could quietly drop:
--
--   * exactly one download per tick, so input is processed between covers
--   * the token re-tested EVERY tick, so paging abandons the chain
--   * liveness re-tested every tick, so a closed shelf stops downloading
--   * cached records skipped WITHIN a tick, so a fully-cached page costs
--     nothing rather than a fifth of a second per cell
--
-- Extracted by name and run against stubs: the real method needs UIManager, a
-- network stack and the widget tree.
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
local body = src:match("\nfunction BookshelfWidget:_opdsCoverStep%(queue, idx, token, state%)\n(.-)\nend\n")
ok(body ~= nil, "_opdsCoverStep(queue, idx, token, state) found in the widget")
assert(body, "cannot continue without the function body")

local function compile(code, env)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, "_opdsCoverStep"))
        _G.setfenv(f, env)
        return f
    end
    return assert(load(code, "_opdsCoverStep", "t", env))
end

-- One rig per scenario. `cached` marks records already on disk; `fails` marks
-- records whose download returns false. The rig does NOT auto-run the chain:
-- it captures each scheduled continuation so the test can step it by hand and
-- observe what happened per tick.
local function rig(opts)
    opts = opts or {}
    local log = { fetched = {}, rebuilds = 0, sweeps = 0, dirty = 0,
                  resolved_urls = {}, stored = {} }
    local pending = nil
    local covers = {
        needsFetch = function(rec)
            return not opts.cached or not opts.cached[rec.id]
        end,
        fetchOne = function(rec, creds)
            log.fetched[#log.fetched + 1] = rec.id
            log.creds = creds
            return not (opts.fails and opts.fails[rec.id])
        end,
        sweepCache = function() log.sweeps = log.sweeps + 1 end,
    }
    local feed = {
        fetch = function(url, user, password, timeouts)
            log.resolved_urls[#log.resolved_urls + 1] = url
            log.last_creds = { user = user, password = password }
            log.last_timeouts = timeouts
            if opts.resolve_fails and opts.resolve_fails[url] then return nil, "boom" end
            return "<feed/>"
        end,
    }
    local BookshelfWidget = {}
    local self_tbl = {
        _rebuild = function() log.rebuilds = log.rebuilds + 1 end,
        _opdsEnsureCovers = function() log.rearms = (log.rearms or 0) + 1 end,
        -- Seeded exactly as _opdsEnsureCovers does before starting a chain:
        -- the step compares the token it was handed against this, so a rig
        -- that leaves it nil makes every step read as superseded.
        _opds_cover_token = opts.token or 7,
    }
    BookshelfWidget.live = self_tbl
    local env = {
        require = function(name)
            if name == "lib/bookshelf_opds_covers" then return covers end
            if name == "lib/bookshelf_opds_feed" then return feed end
            error("unexpected require: " .. tostring(name))
        end,
        UIManager = {
            scheduleIn = function(_self, _secs, fn) pending = fn end,
            setDirty   = function() log.dirty = log.dirty + 1 end,
        },
        BookshelfWidget           = BookshelfWidget,
        -- The step now times fetch vs repaint separately. A monotonic counter
        -- rather than a real clock keeps the rig deterministic.
        _gettime                  = function()
            log.clock = (log.clock or 0) + 0.001
            return log.clock
        end,
        logger                    = { dbg = function() end },
        -- The timing lines format their numbers.
        string                    = string,
        math                      = math,
        tostring                  = tostring,
        ipairs                    = ipairs,
        pairs                     = pairs,
        type                      = type,
        pcall                     = pcall,
        _storeChildFeed           = function(sk, url, body)
            if opts.store_fails and opts.store_fails[url] then return false end
            log.stored[#log.stored + 1] = url
            return true
        end,
        -- The tail re-arms through this when anything resolved.
        _opdsEnsureCovers_calls   = 0,
        OPDS_COVER_TICK           = 0.2,
        OPDS_COVER_REBUILD_EVERY  = 4,
    }
    local fn = compile("local self, queue, idx, token, state = ... ; " .. body, env)
    local step = function(queue, idx, token, state)
        pending = nil
        fn(self_tbl, queue, idx, token, state)
    end
    -- The method re-enters itself by name, so route that through the rig too.
    self_tbl._opdsCoverStep = function(_s, q, i, tok, st) return step(q, i, tok, st) end
    return {
        log = log,
        self_tbl = self_tbl,
        widget_class = BookshelfWidget,
        step = step,
        run_pending = function()
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

-- The chain's queue holds TYPED work items, not bare records: a cover item
-- carries the record, a resolve item carries a child feed url. Both kinds share
-- one queue so they cannot race or double the fetches in flight.
local function queue_of(n)
    local q = {}
    for i = 1, n do q[i] = { kind = "cover", rec = { id = i } } end
    return q
end

local function resolve_queue_of(n)
    local q = {}
    for i = 1, n do
        q[i] = { kind = "resolve", server_key = "srv",
                 feed_url = "https://c/detail/" .. i,
                 user = "u", password = "p",
                 timeouts = { block_timeout = 5, total_timeout = 10 } }
    end
    return q
end

-- ── one download per tick ────────────────────────────────────────────────────
do
    local r = rig()
    local q, st = queue_of(3), nil
    st = r.fresh_state()
    r.step(q, 1, 7, st)
    eq(#r.log.fetched, 1, "first step downloads exactly one cover")
    ok(r.has_pending(), "and schedules the next")
    r.run_pending()
    eq(#r.log.fetched, 2, "second tick downloads the second cover")
    r.run_pending()
    eq(#r.log.fetched, 3, "third tick downloads the third")
    r.run_pending()
    eq(#r.log.fetched, 3, "past the end of the queue, nothing more is downloaded")
    ok(not r.has_pending(), "and the chain stops scheduling")
end

-- ── paging abandons the chain ────────────────────────────────────────────────
-- The guarantee that makes paging responsive: a superseded token stops the
-- chain at its very next step, mid-queue.
do
    local r = rig()
    local st = r.fresh_state()
    r.step(queue_of(10), 1, 7, st)
    eq(#r.log.fetched, 1, "one cover fetched before the user pages")
    r.self_tbl._opds_cover_token = 8    -- a newer pass took over
    r.run_pending()
    eq(#r.log.fetched, 1, "the abandoned chain downloads nothing further")
    ok(not r.has_pending(), "and does not keep rescheduling itself")
end

-- ── a closed shelf stops downloading ─────────────────────────────────────────
do
    local r = rig()
    local st = r.fresh_state()
    r.step(queue_of(10), 1, 7, st)
    eq(#r.log.fetched, 1, "one cover fetched before teardown")
    r.widget_class.live = { other = true }   -- shelf closed / replaced
    r.run_pending()
    eq(#r.log.fetched, 1, "a torn-down shelf downloads nothing further")
end

-- ── cached records cost no tick ──────────────────────────────────────────────
-- A page of covers already on disk must not take a fifth of a second per cell
-- to discover that.
do
    local r = rig{ cached = { [1]=true, [2]=true, [3]=true } }
    local st = r.fresh_state()
    r.step(queue_of(3), 1, 7, st)
    eq(#r.log.fetched, 0, "nothing downloaded when every cover is cached")
    ok(not r.has_pending(), "and the whole queue is consumed in one tick")
    eq(r.log.rebuilds, 0, "no repaint when nothing landed")
    eq(r.log.sweeps, 0, "and no cache sweep")
end
do
    -- Cached records interleaved with misses: the misses still each get a tick.
    local r = rig{ cached = { [1]=true, [2]=true, [4]=true } }
    local st = r.fresh_state()
    r.step(queue_of(5), 1, 7, st)
    eq(#r.log.fetched, 1, "skips straight past cached records to the first miss")
    eq(r.log.fetched[1], 3, "and it is the right record")
    r.run_pending()
    eq(#r.log.fetched, 2, "the next miss lands on the following tick")
    eq(r.log.fetched[2], 5, "having skipped the cached one in between")
end

-- ── repaint cadence ──────────────────────────────────────────────────────────
-- Every repaint is a full rebuild and, on e-ink, a flash. Painting per cover
-- costs more than it buys.
do
    local r = rig()
    local st = r.fresh_state()
    r.step(queue_of(9), 1, 7, st)
    for _i = 1, 3 do r.run_pending() end     -- 4 covers landed
    eq(#r.log.fetched, 4, "four covers landed")
    eq(r.log.rebuilds, 1, "one repaint after the fourth, not four")
    for _i = 1, 4 do r.run_pending() end     -- 8 covers landed
    eq(r.log.rebuilds, 2, "a second repaint at eight")
end

-- ── the tail paints the remainder, and sweeps first ──────────────────────────
do
    local r = rig()
    local st = r.fresh_state()
    r.step(queue_of(2), 1, 7, st)
    r.run_pending()                          -- 2 covers landed, below the cadence
    eq(r.log.rebuilds, 0, "no mid-chain repaint below the cadence")
    r.run_pending()                          -- past the end: the tail
    eq(r.log.rebuilds, 1, "the tail paints what the cadence left behind")
    eq(r.log.sweeps, 1, "and sweeps the cache exactly once")
    ok(r.log.dirty > 0, "and marks the shelf dirty so the paint reaches the screen")
end
do
    -- Nothing landed: no sweep, no repaint. A page of failures must not flash
    -- the screen for nothing.
    local r = rig{ fails = { [1]=true, [2]=true } }
    local st = r.fresh_state()
    r.step(queue_of(2), 1, 7, st)
    r.run_pending()
    r.run_pending()
    eq(#r.log.fetched, 2, "both were attempted")
    eq(r.log.rebuilds, 0, "a chain that landed nothing does not repaint")
    eq(r.log.sweeps, 0, "and does not sweep")
end

-- ── credentials are resolved once for the whole chain ─────────────────────────
-- The creds table is the caller-owned memo; a fresh one per tick would re-read
-- the server list for every cover on the page.
do
    local r = rig()
    local st = r.fresh_state()
    st.creds.marker = "memoised"
    r.step(queue_of(3), 1, 7, st)
    r.run_pending()
    eq(r.log.creds and r.log.creds.marker, "memoised",
        "the same creds table is threaded through every tick")
end

-- ── nav resolution shares the chain ──────────────────────────────────────────
-- Resolving a folder is one child-feed fetch per tile, so it has to be paced
-- and abandonable exactly like a cover. Same queue, same token, same guards --
-- two separate chains would double the requests in flight against a catalog
-- that is already the reason this is opt-in.
do
    local r = rig()
    local st = r.fresh_state()
    r.step(resolve_queue_of(3), 1, 7, st)
    eq(#r.log.resolved_urls, 1, "one child feed fetched per tick")
    eq(r.log.resolved_urls[1], "https://c/detail/1", "and it is the first tile's")
    eq(#r.log.stored, 1, "the fetched feed is cached, which is what resolving means")
    r.run_pending()
    eq(#r.log.resolved_urls, 2, "the next tile resolves on the following tick")
end
do
    -- Credentials and the per-catalog timeout must reach the child fetch: a nav
    -- href can name any host, and the chip's timeout governs its subcatalogs.
    local r = rig()
    r.step(resolve_queue_of(1), 1, 7, r.fresh_state())
    eq(r.log.last_creds and r.log.last_creds.user, "u",
        "the resolve fetch carries the credentials resolved when the queue was built")
    eq(r.log.last_timeouts and r.log.last_timeouts.total_timeout, 10,
        "and the catalog's own timeout")
end
do
    -- Paging must abandon resolution too, not just covers.
    local r = rig()
    local st = r.fresh_state()
    r.step(resolve_queue_of(10), 1, 7, st)
    r.self_tbl._opds_cover_token = 8
    r.run_pending()
    eq(#r.log.resolved_urls, 1, "an abandoned chain resolves nothing further")
end
do
    -- A feed that failed to fetch, or parsed to nothing usable, must not count
    -- as resolved: the tile stays a folder and stays retryable.
    local r = rig{ resolve_fails = { ["https://c/detail/1"] = true } }
    local st = r.fresh_state()
    r.step(resolve_queue_of(2), 1, 7, st)
    eq(#r.log.stored, 0, "a failed fetch stores nothing")
    r.run_pending()
    eq(#r.log.stored, 1, "and the chain carries on to the next tile")
    r.run_pending()
    eq(st.resolved, 1, "only the successful one counted")
end
do
    local r = rig{ store_fails = { ["https://c/detail/1"] = true } }
    local st = r.fresh_state()
    r.step(resolve_queue_of(1), 1, 7, st)
    r.run_pending()
    eq(st.resolved, 0, "a feed that parsed to nothing usable does not count as resolved")
    eq((r.log.rearms or 0), 0, "and does not trigger a re-arm")
end

-- ── the re-arm ───────────────────────────────────────────────────────────────
-- Resolution changes the page shape, so the covers the new page wants were
-- never in this queue. Exactly one re-arm recomputes them; a covers-only pass
-- must not re-arm at all, or the chain would never settle.
do
    local r = rig()
    local st = r.fresh_state()
    r.step(resolve_queue_of(1), 1, 7, st)
    r.run_pending()                          -- past the end: the tail
    eq(st.resolved, 1, "the tile resolved")
    eq((r.log.rearms or 0), 1, "a pass that resolved something re-arms once")
    eq(r.log.rebuilds, 1, "and repaints so the flattened tile renders as a book")
    eq(r.log.sweeps, 0, "no cover sweep when no covers landed")
end
do
    local r = rig()
    local st = r.fresh_state()
    r.step(queue_of(2), 1, 7, st)
    r.run_pending()
    r.run_pending()                          -- tail
    ok(st.landed > 0, "covers landed")
    eq((r.log.rearms or 0), 0, "a covers-only pass does NOT re-arm")
end

-- ── mixed queue ──────────────────────────────────────────────────────────────
do
    local mixed = { resolve_queue_of(1)[1], queue_of(1)[1] }
    local r = rig()
    local st = r.fresh_state()
    r.step(mixed, 1, 7, st)
    eq(#r.log.resolved_urls, 1, "the resolve item runs first")
    eq(#r.log.fetched, 0, "and the cover has not been touched yet")
    r.run_pending()
    eq(#r.log.fetched, 1, "the cover follows on the next tick")
    r.run_pending()                          -- tail
    eq((r.log.rearms or 0), 1, "a mixed pass re-arms because something resolved")
    eq(r.log.sweeps, 1, "and sweeps, because a cover landed")
end

print(string.format("opds cover step: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
