-- bookshelf_pubdate_format.lua
-- A stored publication date ("YYYY", "YYYY-MM" or "YYYY-MM-DD", the shapes
-- lib/bookshelf_pubdate's parseDate keeps) shown in a strftime-style layout:
-- %published{%d %B %Y}, the book menu's Publish date row, and the decade a
-- book goes in on the Decades shelf.
--
-- os.date cannot do this: it formats a timestamp, and a Kindle's 32-bit
-- time_t starts in December 1901, after most public-domain books' dates. So
-- the fields are formatted here, and the weekday is worked out from the date.
--
-- A date has only the parts its source knew: calibre, Hardcover and OPDS
-- catalogues give a year. A layout that asks for a part the date lacks gets
-- the short form instead ("Feb 2016", "2016"), the same one the book menu
-- shows, rather than a day nobody recorded.
--
-- Pure apart from the optional name translation (lib/bookshelf_localdate,
-- KOReader's own day and month translations), so it can be lifted elsewhere.

local M = {}

local MONTHS = { "January", "February", "March", "April", "May", "June", "July",
                 "August", "September", "October", "November", "December" }
local MONTHS_SHORT = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul",
                       "Aug", "Sep", "Oct", "Nov", "Dec" }
local DAYS = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }
local DAYS_SHORT = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }

-- An English name in the interface language. Looked up per call, not cached:
-- the module is also loaded outside KOReader (tests), where there is none.
local function tr(name)
    local ok, L = pcall(require, "lib/bookshelf_localdate")
    if ok and type(L) == "table" and L.localize then return L.localize(name) or name end
    return name
end

-- parts(date) -> y, m, d as numbers (m and d nil when the date has none).
local function parts(date)
    if type(date) ~= "string" then return nil end
    local y, m, d = date:match("^(%d%d%d%d)%-?(%d*)%-?(%d*)$")
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    if not y then return nil end
    if not m or m < 1 or m > 12 then return y end
    if not d or d < 1 or d > 31 then return y, m end
    return y, m, d
end

-- weekday(y, m, d) -> 0 (Sunday) to 6. Sakamoto's method: proleptic
-- Gregorian, any year, no clock involved.
local SAKAMOTO = { 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 }
local function weekday(y, m, d)
    if m < 3 then y = y - 1 end
    return (y + math.floor(y / 4) - math.floor(y / 100) + math.floor(y / 400)
            + SAKAMOTO[m] + d) % 7
end

-- What each code needs, and how it prints.
local NEEDS = { Y = 1, y = 1, m = 2, B = 2, b = 2, d = 3, e = 3, A = 3, a = 3, ["-d"] = 3 }
local CODES = {
    Y = function(y) return string.format("%04d", y) end,
    y = function(y) return string.format("%02d", y % 100) end,
    m = function(_, m) return string.format("%02d", m) end,
    B = function(_, m) return tr(MONTHS[m]) end,
    b = function(_, m) return tr(MONTHS_SHORT[m]) end,
    d = function(_, _, d) return string.format("%02d", d) end,
    ["-d"] = function(_, _, d) return tostring(d) end,
    e = function(_, _, d) return string.format("%2d", d) end,
    A = function(y, m, d) return tr(DAYS[weekday(y, m, d) + 1]) end,
    a = function(y, m, d) return tr(DAYS_SHORT[weekday(y, m, d) + 1]) end,
}

-- short(date) -> "18 Feb 2016", "Feb 2016" or "2016"; "" for no date. A
-- string that is not a stored date comes back as it is.
function M.short(date)
    if date == nil or date == "" then return "" end
    local y, m, d = parts(date)
    if not y then return tostring(date) end
    if d then return string.format("%02d %s %04d", d, tr(MONTHS_SHORT[m]), y) end
    if m then return string.format("%s %04d", tr(MONTHS_SHORT[m]), y) end
    return string.format("%04d", y)
end

-- format(date, spec) -> the date in spec's layout; the short form when the
-- date lacks a part spec asks for; "" for no date.
function M.format(date, spec)
    local y, m, d = parts(date)
    if not y then return "" end
    spec = tostring(spec or "")
    local have = d and 3 or m and 2 or 1
    -- One pass to see what the layout asks for ("%%" is a literal percent).
    for code in spec:gmatch("%%(%-?.)") do
        local need = NEEDS[code]
        if need and need > have then return M.short(date) end
    end
    return (spec:gsub("%%(%-?.)", function(code)
        if code == "%" then return "%" end
        local f = CODES[code]
        if f then return f(y, m, d) end
        -- "%-x" for an x we do not know: give back exactly what was typed.
        return "%" .. code
    end))
end

-- decade(date) -> 1850 for any date in 1850-1859; nil for no date.
function M.decade(date)
    local y = parts(date)
    return y and (y - y % 10) or nil
end

-- decadeLabel(1850) -> "1850s"
function M.decadeLabel(decade)
    return string.format("%ds", decade)
end

return M
