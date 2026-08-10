-- tests/_test_localdate.lua
-- lib/bookshelf_localdate: translates English day/month NAMES inside an
-- os.date-formatted string through KOReader's datetime translation tables
-- (C-locale os.date output vs the KOReader UI language). Matching is by
-- maximal letter-run, so names translate whole and the single pass can't
-- re-translate its own output; everything unrecognised is left alone.
package.path = "./?.lua;./?/init.lua;" .. package.path

local t = dofile("tests/_helpers.lua").runner()

t.test("translates long/short months and weekdays, keeps the rest", function()
    package.loaded["datetime"] = {
        longMonthTranslation  = { July = "julio", August = "agosto" },
        shortMonthTranslation = { Jul = "jul" },
        shortDayOfWeekTranslation = { Mon = "lun" },
        shortDayOfWeekToLongTranslation = { Mon = "lunes" },
    }
    local LD = dofile("lib/bookshelf_localdate.lua")
    assert(LD.localize("Monday 7 July") == "lunes 7 julio",
        LD.localize("Monday 7 July"))
    assert(LD.localize("Mon 7 Jul") == "lun 7 jul")
    assert(LD.localize("07/08/2026") == "07/08/2026", "digits untouched")
    assert(LD.localize("Foo 7 July") == "Foo 7 julio", "unknown words kept")
end)

t.test("whole-word matching: 'Monday' never splits into Mon+day", function()
    package.loaded["datetime"] = {
        shortDayOfWeekTranslation = { Mon = "lun" },
        -- no short-to-long table: "Monday" has no translation of its own
    }
    local LD = dofile("lib/bookshelf_localdate.lua")
    assert(LD.localize("Monday") == "Monday",
        "untranslatable long name stays whole: " .. LD.localize("Monday"))
end)

t.test("degrades to a no-op without KOReader's datetime module", function()
    package.loaded["datetime"] = nil
    package.preload["datetime"] = function() error("not in harness") end
    local LD = dofile("lib/bookshelf_localdate.lua")
    assert(LD.localize("Monday 7 July") == "Monday 7 July")
    package.preload["datetime"] = nil
end)

t.test("non-string input passes through", function()
    local LD = dofile("lib/bookshelf_localdate.lua")
    assert(LD.localize(nil) == nil)
    assert(LD.localize(42) == 42)
end)

t.done()
