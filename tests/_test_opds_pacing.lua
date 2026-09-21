-- tests/_test_opds_pacing.lua
-- The cover pool SLOWS DOWN for a refusing catalog; it never stops.
--
-- WHY THIS SHAPE (issue 434, third attempt and the one that stuck).
-- KOReader's own OPDS browser makes one request per user action -- its list
-- is text, thumbnail urls are parsed but never downloaded for it -- so it
-- cannot trip a rate limit and has nothing here to copy. Every request in
-- our burst is ours: a cover grid is twenty images a page, fired eight at a
-- time, and a server capped at three refuses most of them.
--
-- The first two attempts abandoned the run and scheduled a retry. Measured on
-- device both times, the covers on the page in front of the reader simply
-- stopped:
--
--     "still only loads a few covers per page then stops"
--     "after a restart, I now only get 2 covers before it appears to stall"
--
-- and the server log showed why -- 3 x 200 then 7 x 429, then silence. The
-- abandon also wedged the poll: fill() stopped advancing next_i, so
-- `next_i < #queue` stayed true forever and the completion tail holding the
-- retry was never reached.
--
-- Slowing down has none of that. The queue keeps draining, so covers keep
-- arriving; a capped server sees roughly the serial traffic stock would have
-- sent; and the retry, the token dance and the re-arm all go away.
--
-- Usage (from plugin root): lua tests/_test_opds_pacing.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq
local src = io.open("lib/bookshelf_widget.lua"):read("*a")

t.test("a refusal narrows and paces, and does NOT abandon the queue", function()
    assert(not src:find("state.ratelimited", 1, true),
        "the abandon flag is back; a paused queue strands the current page")
    local marker = src:match("(if out == OpdsFeed%.RATE_LIMIT_MARKER then.-\n                end)")
    assert(marker, "the refusal branch moved or was renamed")
    assert(marker:find("cap = 1", 1, true), "a refusal must narrow to one worker")
    assert(marker:find("paceFor", 1, true), "and adopt the gap that origin has earned")
    assert(marker:find("notePaced", 1, true), "and record the refusal for next time")
end)

t.test("the poll can still reach completion", function()
    -- The wedge that made the retry unreachable: fill() must not be gated on
    -- anything that also stops next_i advancing, or `next_i < #queue` pins
    -- the poll in its reschedule branch forever.
    local fill = src:match("(local function fill%(%).-\n    end)")
    assert(fill, "fill() moved or was renamed")
    assert(not fill:find("ratelimited", 1, true),
        "fill() must not be gated on a refusal flag; that wedges the poll")
end)

t.test("pacing is seeded from the origin, so page two does not re-burst", function()
    -- Narrowing within a chain was already there and was not enough: the next
    -- page opened at full width and taught the server the same lesson again.
    local seed = src:match("(local pace, next_launch_at = 0, 0.-\n    end)")
    assert(seed, "the pace seed moved or was renamed")
    assert(seed:find("paceFor", 1, true), "the opening pace comes from the origin")
    assert(seed:find("cap = 1", 1, true), "a known-slow origin opens narrow")
end)

t.test("a healthy catalog is untouched", function()
    -- pace 0 must leave the loop exactly as it was, or every catalog pays for
    -- the one that refused.
    assert(src:find("if pace > 0 and _gettime() < next_launch_at then return end", 1, true),
        "the pace gate must be conditional on pace > 0")
    local launch = src:match("(if pace > 0 then\n                    next_launch_at.-\n                end)")
    assert(launch, "the per-launch stamp moved")
    assert(launch:find("return", 1, true),
        "while paced, only one worker may be launched per interval")
end)

t.test("the lookahead declines while an origin is paced", function()
    -- It is speculative page prefetch: the one request we can most afford to
    -- skip while a server is already saying no.
    assert(src:find("opds lookahead: declined, origin paced", 1, true),
        "the lookahead must stand down for a paced origin")
end)

t.done()
