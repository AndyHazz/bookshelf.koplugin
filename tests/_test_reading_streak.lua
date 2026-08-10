-- tests/_test_reading_streak.lua
-- The weekly-streak consecutiveness rule (exposed via the spec's
-- _isConsecutiveWeek hook). Week labels are strftime "%Y-%W" (Monday-first):
-- the days before a year's first Monday are week 00, EXCEPT when 1 January
-- is itself a Monday - then the year opens at week 01 and week 00 never
-- exists. That exception is the year-rollover bug this pins down.
package.path = "./?.lua;./?/init.lua;" .. package.path

package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
package.loaded["ffi/util"] = { template = function(s, ...) return s end }

local spec = dofile("micromodules/reading_streak.lua")
local consec = spec._isConsecutiveWeek
local t = dofile("tests/_helpers.lua").runner()

t.test("hook exposed", function()
    assert(type(consec) == "function")
end)

t.test("same year: adjacent weeks only", function()
    assert(consec("2026-14", "2026-15") == true)
    assert(consec("2026-14", "2026-16") == false, "a gap week breaks the streak")
    assert(consec("2026-15", "2026-14") == false, "order matters")
    assert(consec("2026-14", "2026-14") == false, "same week is not consecutive")
end)

t.test("ordinary year rollover lands on week 00", function()
    -- 1 Jan 2027 is a Friday: 2027 opens with a partial week 00.
    assert(consec("2026-52", "2027-00") == true)
    assert(consec("2026-53", "2027-00") == true, "53-week years roll over too")
    assert(consec("2026-52", "2027-01") == false,
        "skipping the partial week 00 is a broken streak")
end)

t.test("Monday-1-Jan rollover lands on week 01 (the 2029 case)", function()
    -- 1 Jan 2029 is a Monday: there is no week 00; the year opens at 01.
    assert(consec("2028-52", "2029-01") == true,
        "unbroken streak across New Year 2029 must be consecutive")
    assert(consec("2028-52", "2029-00") == false,
        "week 00 does not exist in a Monday-opening year")
end)

t.test("more Monday-opening years agree with the calendar", function()
    -- 1 Jan 2018 and 1 Jan 2024 were Mondays; 1 Jan 2023 was a Sunday.
    assert(consec("2017-52", "2018-01") == true)
    assert(consec("2023-52", "2024-01") == true)
    assert(consec("2022-52", "2023-00") == true)
    assert(consec("2022-52", "2023-01") == false)
end)

t.test("rollover requires the old year to have reached week 52", function()
    assert(consec("2026-30", "2027-00") == false,
        "a mid-year last week is months of gap, not a rollover")
end)

t.test("a two-year jump is never consecutive", function()
    assert(consec("2026-52", "2028-00") == false)
end)

t.test("malformed labels fail closed", function()
    assert(consec(nil, "2027-00") == false)
    assert(consec("2026-52", nil) == false)
    assert(consec("garbage", "2027-00") == false)
    assert(consec("2026-52", "alsogarbage") == false)
end)

t.done()
