-- tests/_test_countdown.lua
-- The countdown micromodule's pure date helpers (spec's _ hooks): strict
-- YYYY-MM-DD parsing, canonical formatting, and the noon-anchored whole-day
-- difference that keeps DST shifts from miscounting by one.
package.path = "./?.lua;./?/init.lua;" .. package.path

package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }

local spec = dofile("micromodules/countdown.lua")
local t = dofile("tests/_helpers.lua").runner()

t.test("parseDate: strict YYYY-MM-DD only", function()
    local y, m, d = spec._parseDate("2026-08-10")
    assert(y == 2026 and m == 8 and d == 10)
    assert(spec._parseDate("2026-8-10") == nil, "unpadded month rejected")
    assert(spec._parseDate("10/08/2026") == nil, "other formats rejected")
    assert(spec._parseDate("2026-08-10x") == nil, "trailing junk rejected")
    assert(spec._parseDate(nil) == nil)
    assert(spec._parseDate(20260810) == nil, "non-string rejected")
end)

t.test("fmtDate zero-pads to the canonical shape", function()
    assert(spec._fmtDate(2026, 8, 3) == "2026-08-03")
    assert(spec._fmtDate(999, 12, 31) == "0999-12-31")
end)

t.test("parse and format round-trip", function()
    local y, m, d = spec._parseDate("2027-01-05")
    assert(spec._fmtDate(y, m, d) == "2027-01-05")
end)

-- daysUntil measures against the real "today", so derive expectations from
-- today's date rather than fixed dates.
local function shifted(days)
    local now = os.date("*t")
    now.hour, now.min, now.sec = 12, 0, 0
    local target = os.date("*t", os.time(now) + days * 86400)
    return target.year, target.month, target.day
end

t.test("daysUntil: today is 0", function()
    local now = os.date("*t")
    assert(spec._daysUntil(now.year, now.month, now.day) == 0)
end)

t.test("daysUntil: future and past whole-day counts", function()
    assert(spec._daysUntil(shifted(1)) == 1, "tomorrow")
    assert(spec._daysUntil(shifted(10)) == 10, "ten days out")
    assert(spec._daysUntil(shifted(-5)) == -5, "five days ago")
    assert(spec._daysUntil(shifted(365)) == 365, "a year out")
end)

t.test("dayNumber matches known dates", function()
    local T = function(y, m, d) return { year = y, month = m, day = d } end
    assert(spec._daysUntil(1970, 1, 1, T(1970, 1, 1)) == 0)
    assert(spec._daysUntil(2026, 11, 20, T(1970, 1, 1)) == 20777)
    assert(spec._daysUntil(2000, 3, 1, T(2000, 2, 28)) == 2, "leap day 2000")
    assert(spec._daysUntil(1900, 3, 1, T(1900, 2, 28)) == 1, "no leap day 1900")
end)

t.test("issue 616: a date past 2038 counts forward, not from 1970", function()
    local today = { year = 2026, month = 11, day = 20 }
    -- 2075-04-15 from 2026-11-20 (the reporter's numbers): 17678 days until.
    assert(spec._daysUntil(2075, 4, 15, today) == 17678)
    assert(spec._daysUntil(2140, 1, 1, today) > 0)
    -- A 64-bit test machine can't fail the line above the way a Kobo did, so
    -- also pin that the target never goes through os.time (32-bit time_t).
    local src = io.open("micromodules/countdown.lua"):read("*a")
    assert(not src:find("os.time", 1, true), "countdown must not call os.time")
end)

t.done()
