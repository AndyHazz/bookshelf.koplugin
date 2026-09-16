-- tests/_test_file_poll_baseline.lua
-- Files that arrive while the device is asleep must still be noticed.
--
-- ── WHAT WENT WRONG ─────────────────────────────────────────────────────────
--
-- The shelf polls its home directory's mtimes every few seconds and calls
-- Repo.invalidateWalkCache() when they move. That invalidation is the ONLY
-- thing that makes a new book appear: the walk and group caches no longer
-- expire by time ("vestigial; HIT paths no longer consult expires_at"), and
-- getSeriesGroups' cache in particular returns its stored shapes without ever
-- re-statting the filesystem.
--
-- onSuspend cancels the poll; onResume re-arms it, saying it does so "so a
-- wake-up detects any files synced while the device was suspended". But
-- _startFilePoll re-snapshotted unconditionally, so the pre-sleep baseline was
-- thrown away and replaced with the post-sync state -- the change was absorbed
-- into the new baseline and never seen. Books synced overnight stayed
-- invisible until something else happened to invalidate: opening and closing a
-- book, a swipe-down refresh, or a restart.
--
-- The covered-by-another-widget branch already avoids exactly this, and says
-- so: "re-arming via _startFilePoll re-baselines, which silently swallows any
-- file that arrived while covered". The same hazard simply was not applied to
-- the sleep path. _cancelFilePoll never cleared the baseline, so the fix is to
-- stop overwriting it.
--
-- Reported from a device: two books synced in and did not appear, with the
-- files present on disk and correctly timestamped.
--
-- Usage (from plugin root): lua tests/_test_file_poll_baseline.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = dofile("tests/_helpers.lua")
local t = H.runner()
local eq = H.eq

local src = assert(io.open("lib/bookshelf_widget.lua")):read("*a")
local body = src:match("\n(function BookshelfWidget:_startFilePoll%(.-\nend)\n")
assert(body, "_startFilePoll moved or was renamed")

-- Run the real function against stubs, so this tests behaviour rather than
-- the shape of the source.
local function run(existing_baseline)
    local snaps = 0
    local env = {
        BookshelfWidget = {},
        _snapshotHomeDirs = function()
            snaps = snaps + 1
            return { ["/home"] = 2000 }   -- the state AFTER the sync
        end,
        UIManager = { scheduleIn = function() end },
        -- The first tick is armed through _armFilePoll at the module's active
        -- rate; neither is under test here.
        require = function() return { ACTIVE_INTERVAL_S = 5 } end,
    }
    local code = body .. "\nEXPORT = BookshelfWidget._startFilePoll"
    local f
    if _G.setfenv then
        f = assert(_G.loadstring(code, "poll"))
        _G.setfenv(f, env)
    else
        f = assert(load(code, "poll", "t", env))
    end
    f()
    local self_ = { _home_dir_mtimes = existing_baseline, _armFilePoll = function() end }
    env.EXPORT(self_)
    return self_, snaps
end

t.test("a cold start takes a baseline", function()
    -- Without one the first tick would compare against nothing and
    -- false-positive on every existing file.
    local s, snaps = run(nil)
    eq(snaps, 1, "no baseline was taken on a cold start")
    assert(s._home_dir_mtimes, "the baseline was not stored")
end)

t.test("re-arming after sleep KEEPS the pre-sleep baseline", function()
    -- The whole point: onResume re-arms, and the first tick afterwards has to
    -- compare against what the directory looked like BEFORE the device slept.
    local before = { ["/home"] = 1000 }
    local s, snaps = run(before)
    eq(snaps, 0, "re-arming re-snapshotted, swallowing anything synced while asleep")
    eq(s._home_dir_mtimes["/home"], 1000,
        "the pre-sleep baseline was overwritten with the current state")
end)

t.test("an already-running poll is left alone", function()
    -- Idempotence: onResume calls this unconditionally.
    local snaps = 0
    local env = {
        BookshelfWidget = {},
        _snapshotHomeDirs = function() snaps = snaps + 1; return {} end,
        UIManager = { scheduleIn = function() error("rescheduled a live poll") end },
        require = function() return { ACTIVE_INTERVAL_S = 5 } end,
    }
    local code = body .. "\nEXPORT = BookshelfWidget._startFilePoll"
    local f
    if _G.setfenv then
        f = assert(_G.loadstring(code, "poll")); _G.setfenv(f, env)
    else
        f = assert(load(code, "poll", "t", env))
    end
    f()
    local ok = pcall(env.EXPORT, { _file_poll_fn = function() end })
    assert(ok, "an already-running poll was re-armed")
    eq(snaps, 0)
end)

-- ── the poll has to come BACK ──────────────────────────────────────────────
--
-- Cancelling is easy to get right and restarting is not. _stopStatusTimer
-- cancels the poll, and it runs on every path that pauses the shelf --
-- onSuspend, onCloseWidget, _launchReader. But only _rebuild and onResume ever
-- restarted it, and returning from a HOT-PARKED reader deliberately skips the
-- rebuild (that is the whole point of parking). So opening one book killed the
-- poll for the rest of the session.
--
-- Caught on a device: reader closed at 19:27:40, the shelf was on screen from
-- then on, a book synced in at 19:27:53, and the poll's last tick was 19:19:50
-- -- eight minutes earlier, the moment the book had been opened.

local start_body = src:match("\n(function BookshelfWidget:_startStatusTimer%(.-\nend)\n")
local stop_body  = src:match("\n(function BookshelfWidget:_stopStatusTimer%(.-\nend)\n")
assert(start_body and stop_body, "the status timer pair moved or was renamed")

t.test("whatever stops the poll also starts it again", function()
    -- Stated as the symmetry rather than "onShow starts it": the cancel side
    -- is what every pause path funnels through, so the restart belongs on its
    -- counterpart rather than on any one caller.
    assert(stop_body:find("_cancelFilePoll", 1, true),
        "the stop side no longer cancels the poll; this pairing is stale")
    assert(start_body:find("_startFilePoll", 1, true),
        "the stop side cancels the file poll but the start side never revives "
        .. "it, so returning from a parked reader leaves the shelf blind to "
        .. "new files for the rest of the session")
end)

t.done()
