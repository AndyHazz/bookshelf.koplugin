-- tests/_test_datetime_localized.lua
-- Issue 545: %datetime{...} passes its format to os.date, whose day and month
-- names come from the C library's locale, which on a Kindle is English
-- whatever KOReader's language. The named date tokens (%date, %weekday...)
-- already map those names through KOReader's own translation tables
-- (lib/bookshelf_localdate); %datetime did not, so a reader building their
-- own date format got English names in a German interface.
package.path = "./?.lua;" .. package.path
package.loaded["device"] = {
    getPowerDevice = function() return nil end, isKindle = function() return false end,
    hasNaturalLight = function() return false end, home_dir = "/",
}
-- KOReader's datetime tables, as a German UI fills them.
package.loaded["datetime"] = {
    longMonthTranslation = { May = "Mai", October = "Oktober" },
    shortMonthTranslation = { May = "Mai", Oct = "Okt" },
    shortDayOfWeekTranslation = { Sun = "So", Thu = "Do" },
    shortDayOfWeekToLongTranslation = { Sun = "Sonntag", Thu = "Donnerstag" },
    secondsToClockDuration = function() return "" end,
}
local i18n = { gettext = function(t) return t end, ngettext = function(s, p, n) return n == 1 and s or p end }
package.loaded["bookshelf_i18n"] = i18n
package.loaded["lib/bookshelf_i18n"] = i18n
_G.G_reader_settings = setmetatable({}, {
    readSetting = function() return nil end, isTrue = function() return false end,
    __index = function() return function() return false end end,
})
local Tokens = dofile("lib/bookshelf_tokens.lua")
local t = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq

local state = { now = os.time({ year = 2026, month = 5, day = 3, hour = 14, min = 35, sec = 0 }) }  -- a Sunday

t.test("%datetime names days and months in KOReader's language", function()
    eq(Tokens.expand("%datetime{%A %d %B}", {}, state), "Sonntag 03 Mai")
    eq(Tokens.expand("%datetime{%a, %b %Y}", {}, state), "So, Mai 2026")
end)

t.test("digits and the reader's own punctuation are left alone", function()
    eq(Tokens.expand("%datetime{%d.%m.%Y %H:%M}", {}, state), "03.05.2026 14:35")
end)

t.test("the named date tokens agree with it", function()
    eq(Tokens.expand("%weekday", {}, state), "Sonntag")
end)

t.done()
