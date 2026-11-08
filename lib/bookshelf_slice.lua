-- lib/bookshelf_slice.lua
-- Work that cannot stop by itself, run in steps.
--
-- Background work on the shelf runs in the UI thread, and a swipe that
-- arrives during a step waits for it. Building the next page ahead was one
-- step however many covers it decoded: 0.5-0.8 s on a Series shelf on a PW5.
-- Slice.start(fn) runs fn in a coroutine; Slice.step(job, over) resumes it
-- until it finishes or a Slice.check() inside finds over() true, then hands
-- the step back. Code calls check() only where pausing is safe (before a
-- cover decode, between rows). Outside a slice check() does nothing, so an
-- ordinary page turn is untouched.
local M = {}

local current -- { co, over } of the step running now

-- start(fn) -> job
function M.start(fn)
    return { co = coroutine.create(fn) }
end

-- step(job, over) -> finished, ok, err
function M.step(job, over)
    local prev = current
    current = { co = job.co, over = over }
    local ok, err = coroutine.resume(job.co)
    current = prev
    if not ok then return true, false, err end
    return coroutine.status(job.co) == "dead", true
end

-- check(): pause here when the step's time is up.
function M.check()
    local c = current
    if not c or coroutine.running() ~= c.co then return end
    -- Never through a C boundary (a sort comparator, say), where a yield
    -- raises instead.
    if coroutine.isyieldable and not coroutine.isyieldable() then return end
    if c.over() then coroutine.yield() end
end

return M
