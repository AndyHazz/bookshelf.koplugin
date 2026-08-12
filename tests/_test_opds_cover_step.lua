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
    local log = { fetched = {}, rebuilds = 0, sweeps = 0, dirty = 0 }
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
    local BookshelfWidget = {}
    local self_tbl = {
        _rebuild = function() log.rebuilds = log.rebuilds + 1 end,
        -- Seeded exactly as _opdsEnsureCovers does before starting a chain:
        -- the step compares the token it was handed against this, so a rig
        -- that leaves it nil makes every step read as superseded.
        _opds_cover_token = opts.token or 7,
    }
    BookshelfWidget.live = self_tbl
    local env = {
        require = function(name)
            if name == "lib/bookshelf_opds_covers" then return covers end
            error("unexpected require: " .. tostring(name))
        end,
        UIManager = {
            scheduleIn = function(_self, _secs, fn) pending = fn end,
            setDirty   = function() log.dirty = log.dirty + 1 end,
        },
        BookshelfWidget           = BookshelfWidget,
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
        fresh_state = function() return { creds = {}, landed = 0, painted = 0 } end,
    }
end

local function queue_of(n)
    local q = {}
    for i = 1, n do q[i] = { id = i } end
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

print(string.format("opds cover step: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
