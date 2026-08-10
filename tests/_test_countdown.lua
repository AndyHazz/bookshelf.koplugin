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

t.done()
