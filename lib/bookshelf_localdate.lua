--[[--
Localize the day/month NAMES in an os.date-formatted string.

`os.date("%A")` / `os.date("%B")` (and their short `%a`/`%b` forms) return
weekday/month names from the C library's LC_TIME locale — which on a Kindle
(and most KOReader targets) is plain English, regardless of the KOReader UI
language. So date tokens and the clock micromodules render "Monday 7 July"
even when the interface is Spanish.

KOReader's own `datetime` module carries translation tables (populated via
its gettext at load) mapping the English names to the active UI language.
This helper maps an os.date output through them: it translates each whole
English name it recognises and leaves digits, punctuation and everything
else untouched.

The map is built once (KOReader's date translations, like its whole gettext
layer, are fixed at startup and only change on restart), and degrades to a
no-op if `datetime` is unavailable (e.g. pure-Lua tests).
]]--

local M = {}

local map  -- English name -> localized name; built lazily

local function buildMap()
    map = {}
    local ok, datetime = pcall(require, "datetime")
    if not (ok and type(datetime) == "table") then return end
    for eng, tr in pairs(datetime.longMonthTranslation or {})     do map[eng] = tr end
    for eng, tr in pairs(datetime.shortMonthTranslation or {})    do map[eng] = tr end
    for eng, tr in pairs(datetime.shortDayOfWeekTranslation or {}) do map[eng] = tr end
    -- No longDayOfWeekTranslation table exists upstream; derive full-weekday
    -- names from the short->long table (keyed on the English long name).
    local EN_LONG_DAY = {
        Mon = "Monday", Tue = "Tuesday", Wed = "Wednesday", Thu = "Thursday",
        Fri = "Friday", Sat = "Saturday", Sun = "Sunday",
    }
    local short_to_long = datetime.shortDayOfWeekToLongTranslation or {}
    for short, eng_long in pairs(EN_LONG_DAY) do
        local tr = short_to_long[short]
        if tr then map[eng_long] = tr end
    end
end

-- Translate recognised English day/month names in `str` to the UI language.
-- Matches maximal letter-runs, so "Monday" translates as a whole (never as
-- "Mon" + "day"), and the single gsub pass can't re-translate its own output.
function M.localize(str)
    if type(str) ~= "string" then return str end
    if not map then buildMap() end
    return (str:gsub("%a+", function(word) return map[word] end))
end
-- Longest first: weekday and month in full, then abbreviated, then without
-- the weekday, then numeric.
M.DATE_FORMS = { "%A %d %B", "%a %d %b", "%d %b", "%d/%m" }

--- The longest of DATE_FORMS for `now`, localized, that `measure(str) -> px`
--- says fits in max_w; the shortest when none does. Shortening the format
--- reads better than truncating it, so callers shrink the font only after.
function M.fitted(now, measure, max_w)
    local last
    for _i, fmt in ipairs(M.DATE_FORMS) do
        last = M.localize(os.date(fmt, now))
        if measure(last) <= max_w then return last end
    end
    return last
end

return M
