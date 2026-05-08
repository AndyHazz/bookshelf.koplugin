-- tokens.lua
-- Homescreen-scoped token expander. Bookends-compatible syntax, scoped
-- vocabulary tied to homescreen-available data sources.

local Tokens = {}

-- Token registry: name → function(book, state) → string
Tokens.expanders = {}

-- Single source of truth for the default clock/status line template.
-- Reused by hero_card.lua (fallback render) and settings.lua (Default
-- button + initial value when the user has no custom line saved).
Tokens.DEFAULT_CLOCK_LINE =
    "\xef\x82\xa0%disk[if:batt]  %batt_icon%batt[/if]"
 .. "[if:light]  %light_icon%light_pct[/if]  %wifi_icon  %time_12h"

-- Token catalogue — drives the picker UI in settings.lua. Tokens that
-- have no meaningful value on the homescreen (chapter, current page,
-- etc.) are deliberately omitted. Categories give the picker a visual
-- grouping; descriptions are shown next to the token literal.
-- Only tokens that actually have data on the bookshelf home screen.
-- Excluded: chapter/reader-context tokens (no current chapter on home),
-- annotation counts (book_repository doesn't fetch them), %mem/%ram/%disk
-- (not populated in _buildDeviceState).
-- Caveats noted in descriptions: stats tokens need the readerstatistics
-- plugin enabled; %page_num/%page_count are nil for EPUB on home screen.
Tokens.CATALOGUE = {
    { category = "Book",     token = "%title",            description = "Title" },
    { category = "Book",     token = "%author",           description = "First author" },
    { category = "Book",     token = "%authors",          description = "All authors" },
    { category = "Book",     token = "%series_name",      description = "Series name" },
    { category = "Book",     token = "%series_num",       description = "Series number" },
    { category = "Book",     token = "%filename",         description = "File name" },
    { category = "Book",     token = "%format",           description = "Format (EPUB/PDF/…)" },
    { category = "Book",     token = "%description",      description = "Book blurb (HTML stripped)" },
    { category = "Book",     token = "%lang",             description = "Language" },
    { category = "Progress", token = "%book_pct",         description = "Percent read" },
    { category = "Progress", token = "%book_pct_left",    description = "Percent left" },
    { category = "Progress", token = "%page_num",         description = "Current page" },
    { category = "Progress", token = "%page_count",       description = "Total pages (approximate for EPUB)" },
    { category = "Progress", token = "%pages_left",       description = "Pages left (approximate for EPUB)" },
    { category = "Progress", token = "%book_time_left",   description = "Time left to finish (statistics)" },
    { category = "Progress", token = "%book_read_time",   description = "Total time read (statistics)" },
    { category = "Progress", token = "%book_pages_read",  description = "Pages read (statistics)" },
    { category = "Progress", token = "%days_reading_book",description = "Days since first opened (statistics)" },
    { category = "Progress", token = "%pages_per_day",    description = "Pages per day (statistics)" },
    { category = "Progress", token = "%speed",            description = "Speed in pages/hour (statistics)" },
    { category = "Time",     token = "%time_12h",         description = "Time (12-hour)" },
    { category = "Time",     token = "%time_24h",         description = "Time (24-hour)" },
    { category = "Time",     token = "%date",             description = "Date (e.g. 4 May)" },
    { category = "Time",     token = "%date_long",        description = "Date (e.g. 4 May 2026)" },
    { category = "Time",     token = "%date_numeric",     description = "Date (numeric)" },
    { category = "Time",     token = "%weekday",          description = "Weekday" },
    { category = "Time",     token = "%weekday_short",    description = "Weekday (short)" },
    { category = "Device",   token = "%batt",             description = "Battery percentage" },
    { category = "Device",   token = "%batt_icon",        description = "Battery icon (Nerd Font)" },
    { category = "Device",   token = "%wifi_icon",        description = "Wi-Fi icon" },
    { category = "Device",   token = "%nightmode",        description = "Night mode icon (moon/sun)" },
    { category = "Device",   token = "%light",            description = "Frontlight intensity (raw)" },
    { category = "Device",   token = "%light_pct",        description = "Frontlight intensity (0–100%)" },
    { category = "Device",   token = "%light_icon",       description = "Frontlight icon" },
    { category = "Device",   token = "%warmth",           description = "Warmth value (natural-light only)" },
    { category = "Device",   token = "%mem",              description = "System memory used (%)" },
    { category = "Device",   token = "%ram",              description = "KOReader RSS (MiB)" },
    { category = "Device",   token = "%disk",             description = "Storage free (GB)" },
    { category = "Logic",    token = "[if:foo]…[/if]",    description = "Show … when token foo is set" },
    { category = "Logic",    token = "[if:not foo]…[/if]",description = "Show … when foo is empty" },
    { category = "Logic",    token = "[if:foo>50]…[/if]", description = "Numeric comparison" },
    { category = "Logic",    token = "[if:foo]…[else]…[/if]", description = "If/else" },
}

local function metaToken(field)
    return function(book) return book and book[field] or "" end
end

Tokens.expanders.title       = metaToken("title")
Tokens.expanders.author      = metaToken("author")
Tokens.expanders.author_2    = function(book)
    return book and book.authors and book.authors[2] or ""
end
Tokens.expanders.authors     = function(book)
    if not book or not book.authors then return "" end
    return table.concat(book.authors, ", ")
end
Tokens.expanders.series      = metaToken("series")
Tokens.expanders.series_name = metaToken("series_name")
Tokens.expanders.series_num  = metaToken("series_num")
Tokens.expanders.filename    = metaToken("filename")
Tokens.expanders.lang        = metaToken("lang")
Tokens.expanders.format      = metaToken("format")

local function codepointToUtf8(n)
    n = tonumber(n)
    if not n or n < 0 then return "" end
    if n < 0x80    then return string.char(n) end
    if n < 0x800   then return string.char(0xC0 + math.floor(n / 0x40),
                                           0x80 + n % 0x40) end
    if n < 0x10000 then return string.char(0xE0 + math.floor(n / 0x1000),
                                           0x80 + math.floor(n / 0x40) % 0x40,
                                           0x80 + n % 0x40) end
    return ""
end

-- Named HTML entities common in <dc:description> blocks. Mirrors the table
-- in KOReader's util.lua HTML_ENTITIES_TO_UTF8 so we cover the smart-quote
-- and dash zoo most often seen in EPUBs (rsquo / ldquo / mdash etc.).
-- Inlined here rather than `require("util")` so tokens.lua keeps loading
-- in the pure-Lua test harness (which has no KOReader env).
-- &amp; must be applied LAST: any other entity may itself contain '&', and
-- decoding amp first would corrupt them.
local HTML_NAMED_ENTITIES = {
    { "&lt;",     "<"          },
    { "&gt;",     ">"          },
    { "&quot;",   '"'          },
    { "&apos;",   "'"          },
    { "&lsquo;",  "\xE2\x80\x98" }, -- U+2018
    { "&rsquo;",  "\xE2\x80\x99" }, -- U+2019
    { "&ldquo;",  "\xE2\x80\x9C" }, -- U+201C
    { "&rdquo;",  "\xE2\x80\x9D" }, -- U+201D
    { "&sbquo;",  "\xE2\x80\x9A" }, -- U+201A
    { "&bdquo;",  "\xE2\x80\x9E" }, -- U+201E
    { "&ndash;",  "\xE2\x80\x93" }, -- U+2013
    { "&mdash;",  "\xE2\x80\x94" }, -- U+2014
    { "&hellip;", "\xE2\x80\xA6" }, -- U+2026
    { "&trade;",  "\xE2\x84\xA2" }, -- U+2122
    { "&copy;",   "\xC2\xA9"     }, -- U+00A9
    { "&reg;",    "\xC2\xAE"     }, -- U+00AE
    { "&nbsp;",   "\xC2\xA0"     }, -- U+00A0
    { "&amp;",    "&"            }, -- must be last
}

local function cleanDescription(raw)
    if not raw or raw == "" then return "" end
    local text = raw
    -- Block-level tags become newlines BEFORE the generic strip pass.
    -- Case-insensitive (some EPUBs uppercase tags). <div> is handled
    -- alongside <p> because some publishers wrap each paragraph in a
    -- <div> instead of a <p>.
    text = text:gsub("<%s*[bB][rR]%s*/?>", "\n")
    text = text:gsub("</%s*[pP]%s*>", "\n\n")
    text = text:gsub("</%s*[dD][iI][vV]%s*>", "\n\n")
    -- Generic strip for everything else (<p>, <span>, <i>, <b>, …).
    text = text:gsub("<[^>]+>", "")
    -- Named entities first.
    for _i, pair in ipairs(HTML_NAMED_ENTITIES) do
        text = text:gsub(pair[1], pair[2])
    end
    -- Numeric entities — both decimal (&#160;) and hex (&#xA0;).
    text = text:gsub("&#(%d+);",      codepointToUtf8)
    text = text:gsub("&#x(%x+);",     function(h) return codepointToUtf8(tonumber(h, 16)) end)
    -- Collapse runs of 3+ newlines (publishers often have a literal
    -- newline between </p> and the next <p>, which interacts with our
    -- </p> → \n\n to produce 3 newlines = an extra blank line). Two
    -- newlines = one blank line between paragraphs, which is what we
    -- want.
    text = text:gsub("\n\n\n+", "\n\n")
    -- Drop empty/whitespace-only paragraphs. Publishers commonly emit
    -- <p>&nbsp;</p> (or <p>&#xa0;</p>) as a vertical spacer between
    -- real paragraphs. After </p> → \n\n + tag-strip + entity-decode,
    -- those land here as " \xC2\xA0" sandwiched between \n\n delimiters
    -- — the hero card's per-paragraph splitter would then render the
    -- nbsp as its own paragraph (full line of whitespace) on top of the
    -- intended paragraph gap. Filter them out so we get exactly one
    -- paragraph break between content paragraphs.
    do
        local kept = {}
        for para in (text .. "\n\n"):gmatch("(.-)\n\n") do
            -- nbsp (U+00A0 = 0xC2 0xA0 in UTF-8) isn't %s in Lua patterns;
            -- coerce to a regular space before the whitespace strip.
            local stripped = para:gsub("\xC2\xA0", " "):gsub("%s+", "")
            if stripped ~= "" then
                kept[#kept + 1] = para
            end
        end
        text = table.concat(kept, "\n\n")
    end
    -- Trim leading/trailing whitespace + newlines.
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

Tokens.cleanDescription = cleanDescription      -- exported for tests / ad-hoc use
Tokens.expanders.description = function(book)
    return book and cleanDescription(book.description) or ""
end

local function pct(v) return string.format("%d%%", math.floor((v or 0) * 100 + 0.5)) end

Tokens.expanders.page_num   = function(b) return b and b.page_num and tostring(b.page_num) or "" end
Tokens.expanders.page_count = function(b) return b and b.page_count and tostring(b.page_count) or "" end
Tokens.expanders.book_pct       = function(b) return b and b.book_pct and pct(b.book_pct) or "" end
Tokens.expanders.book_pct_left  = function(b) return b and b.book_pct and pct(1 - b.book_pct) or "" end
Tokens.expanders.pages_left     = function(b)
    if not b or not b.page_num or not b.page_count then return "" end
    return tostring(b.page_count - b.page_num)
end

local function timeNow(state)
    return (state and state.now) or os.time()
end
local function fmt(spec, state) return os.date(spec, timeNow(state)) end

Tokens.expanders.time     = function(_b, s) return fmt("%H:%M", s) end
Tokens.expanders.time_24h = function(_b, s) return fmt("%H:%M", s) end
Tokens.expanders.time_12h = function(_b, s)
    local t = fmt("%I:%M %p", s)
    return (t:gsub("^0", ""))
end
Tokens.expanders.date          = function(_b, s) return fmt("%d %b", s):gsub("^0", "") end
Tokens.expanders.date_long     = function(_b, s) return fmt("%d %B %Y", s):gsub("^0", "") end
Tokens.expanders.date_numeric  = function(_b, s) return fmt("%d/%m/%Y", s) end
Tokens.expanders.weekday       = function(_b, s) return fmt("%A", s) end
Tokens.expanders.weekday_short = function(_b, s) return fmt("%a", s) end

local function minutesToHM(m)
    if not m or m <= 0 then return "" end
    local h = math.floor(m / 60); local mm = m % 60
    return string.format("%dh %02dm", h, mm)
end

Tokens.expanders.book_time_left   = function(b) return minutesToHM(b and b.book_time_left_minutes) end
Tokens.expanders.book_read_time   = function(b)
    return b and b.book_read_time_seconds and minutesToHM(math.floor(b.book_read_time_seconds / 60)) or ""
end
Tokens.expanders.pages_today      = function(_b, s) return s and s.pages_today and tostring(s.pages_today) or "" end
Tokens.expanders.time_today       = function(_b, s) return minutesToHM(s and s.time_today_minutes) end
Tokens.expanders.speed            = function(b) return b and b.speed_pph and tostring(b.speed_pph) or "" end
Tokens.expanders.avg_page_time    = function(b)
    if not b or not b.avg_page_time_seconds then return "" end
    local s = b.avg_page_time_seconds
    if s < 60 then return string.format("%ds", s) end
    return string.format("%dm %02ds", math.floor(s / 60), s % 60)
end
Tokens.expanders.book_pages_read    = function(b) return b and b.book_pages_read and tostring(b.book_pages_read) or "" end
Tokens.expanders.days_reading_book  = function(b) return b and b.days_reading_book and tostring(b.days_reading_book) or "" end
Tokens.expanders.pages_per_day      = function(b) return b and b.pages_per_day and tostring(b.pages_per_day) or "" end

Tokens.expanders.highlights   = function(b) return b and b.highlights and tostring(b.highlights) or "" end
Tokens.expanders.notes        = function(b) return b and b.notes and tostring(b.notes) or "" end
Tokens.expanders.bookmarks    = function(b) return b and b.bookmarks and tostring(b.bookmarks) or "" end
Tokens.expanders.annotations  = function(b)
    if not b then return "" end
    local total = (b.highlights or 0) + (b.notes or 0) + (b.bookmarks or 0)
    return total > 0 and tostring(total) or ""
end

Tokens.expanders.batt       = function(_b, s) return s and s.batt and (tostring(s.batt) .. "%") or "" end
-- Status-line icons use Nerd Font private-use-area codepoints. KOReader
-- registers nerdfonts/symbols.ttf as a global font fallback (font.lua),
-- so any TextWidget renders these without needing a special face.
Tokens.expanders.batt_icon = function(_b, s)
    if not s or not s.batt then return "" end
    local ok, PowerD = pcall(function() return require("device"):getPowerDevice() end)
    if not ok or not PowerD or not PowerD.getBatterySymbol then return "" end
    return PowerD:getBatterySymbol(false, s.charging or false, s.batt) or ""
end
Tokens.expanders.light_icon = function(_b, s)
    if not s or not s.light then return "" end
    return s.light > 0 and "\xee\xb7\xa6"   -- U+EDE6 lightbulb-on
                       or  "\xee\xa8\xb5"   -- U+EA35 lightbulb-outline
end
Tokens.expanders.wifi_icon = function(_b, s)
    return (s and s.wifi == "on") and "\xee\xb2\xa8"   -- U+ECA8 wifi connected
                                  or  "\xee\xb2\xa9"   -- U+ECA9 wifi-off
end
Tokens.expanders.wifi = Tokens.expanders.wifi_icon
-- Night mode glyph: moon when night mode is on, sun otherwise. Mirrors
-- bookends (bookends_tokens.lua:2110-2117) — driven by KOReader's
-- persistent "night_mode" setting, not a per-frame state read.
Tokens.expanders.nightmode = function()
    if G_reader_settings:isTrue("night_mode") then
        return "\xee\xb2\x93" -- U+EC93 weather-night (moon)
    end
    return "\xee\xb2\x98"     -- U+EC98 weather-sunny (sun)
end
-- %charging is now redundant — %batt_icon already shows a charging glyph
-- when the device is plugged in. Kept as an alias to %batt_icon so any
-- existing user templates still work.
Tokens.expanders.charging = function(b, s) return Tokens.expanders.batt_icon(b, s) end
Tokens.expanders.light = function(_b, s) return s and s.light or "" end
-- Frontlight intensity normalised to 0–100 via PowerD.fl_max.
-- Mirrors bookends's %light_pct. Includes the trailing "%" for parity
-- with %book_pct so users can drop it directly into a template.
Tokens.expanders.light_pct = function(_b, s)
    if not s or not s.light_pct then return "" end
    return tostring(s.light_pct) .. "%"
end
Tokens.expanders.warmth= function(_b, s) return s and s.warmth and tostring(s.warmth) or "" end
Tokens.expanders.mem   = function(_b, s) return s and s.mem and (tostring(s.mem) .. "%") or "" end
Tokens.expanders.ram   = function(_b, s) return s and s.ram_mib and (tostring(s.ram_mib) .. " MiB") or "" end
Tokens.expanders.disk  = function(_b, s) return s and s.disk_free or "" end

-- %bar is intentionally NOT in the expander table. The hero card's
-- progress renderer (buildProgressLine in hero_card.lua) detects %bar
-- AFTER token expansion and splits the line into [before, BarWidget,
-- after]. Adding an expander here would replace %bar with empty text
-- before the renderer ever sees it. This mirrors the bookends approach
-- (which uses a placeholder character) but keeps %bar as the literal
-- four characters the user typed.

-- ─── Conditional evaluator ──────────────────────────────────────────────────
-- Recognises [if:cond]…[else]…[/if]. Cond grammar:
--   atom    := [not] (token | token op value)
--   value   := number | "double-quoted string"
--   op      := = | != | < | > | <= | >=
--   expr    := atom (and|or atom)*
-- Strings vs numbers: numeric tokens compare numerically; string tokens
-- compare by string equality. Missing tokens compare as empty/zero.

local function valueForCondition(name, book, state)
    -- Single source of truth for if-condition values. Falls through to
    -- expanders so e.g. "book_pct" in a condition matches %book_pct token.
    local exp = Tokens.expanders[name]
    if not exp then return nil end
    local v = exp(book, state)
    if v == nil or v == "" then return nil end
    return v
end

local function asNumber(s)
    if type(s) == "number" then return s end
    if type(s) ~= "string" then return nil end
    local n = tonumber(s)
    if n then return n end
    -- Strip trailing %, try again.
    return tonumber((s:gsub("%%$", "")))
end

local function evaluateAtom(atom, book, state)
    local negate, body = atom:match("^%s*(not)%s+(.+)$")
    if not negate then body = atom end
    local v = valueForCondition(body:match("^%s*([%w_]+)") or "", book, state)
    -- token op value form
    local name, op, raw = body:match('^%s*([%w_]+)%s*([=<>!]+)%s*(.+)%s*$')
    if name and op then
        local lhs = valueForCondition(name, book, state)
        local quoted = raw:match('^"(.-)"$')
        local rhs = quoted or raw
        local result
        if op == "=" then
            result = (tostring(lhs or "") == tostring(rhs))
        elseif op == "!=" then
            result = (tostring(lhs or "") ~= tostring(rhs))
        else
            local lhs_n, rhs_n = asNumber(lhs) or 0, asNumber(rhs) or 0
            if op == "<"  then result = lhs_n <  rhs_n
            elseif op == ">"  then result = lhs_n >  rhs_n
            elseif op == "<=" then result = lhs_n <= rhs_n
            elseif op == ">=" then result = lhs_n >= rhs_n
            end
        end
        if result == nil then result = false end
        if negate then result = not result end
        return result
    end
    -- token-truthy form
    local truthy = (v ~= nil and v ~= "" and v ~= "0" and v ~= 0)
    if negate then truthy = not truthy end
    return truthy
end

local function evaluateExpr(expr, book, state)
    -- Split on `and`/`or`, left-to-right (no precedence: keep it boring).
    local parts, ops = {}, {}
    local pos = 1
    while true do
        -- find next operator: leftmost of and/or, by position
        local sa, ea = expr:find("%s+and%s+", pos)
        local so, eo = expr:find("%s+or%s+",  pos)
        local s, e, op
        if sa and (not so or sa <= so) then
            s, e, op = sa, ea, "and"
        elseif so then
            s, e, op = so, eo, "or"
        end
        if not s then parts[#parts + 1] = expr:sub(pos); break end
        parts[#parts + 1] = expr:sub(pos, s - 1)
        ops[#ops + 1] = op
        pos = e + 1
    end
    local result = evaluateAtom(parts[1], book, state)
    for i, op in ipairs(ops) do
        local r = evaluateAtom(parts[i + 1], book, state)
        if op == "and" then result = result and r else result = result or r end
    end
    return result
end

local function expandConditionals(format, book, state)
    -- Iteratively peel innermost [if:…]…[/if] blocks until none remain.
    -- This handles arbitrary nesting without a real parser by always finding
    -- the leftmost [if:] whose body contains no nested [if:].
    while true do
        -- Scan for an innermost [if:...][/if] block (body has no nested [if:)
        local found = false
        local pos = 1
        while true do
            local ifstart = format:find("%[if:", pos)
            if not ifstart then break end
            local condstart = ifstart + 4
            local condend = format:find("%]", condstart)
            if not condend then break end
            local cond = format:sub(condstart, condend - 1)
            local bodystart = condend + 1
            local endstart = format:find("%[/if%]", bodystart)
            if not endstart then break end
            local body = format:sub(bodystart, endstart - 1)
            local endfinish = endstart + #"[/if]" - 1
            if not body:find("%[if:") then
                -- This is an innermost block; evaluate and replace.
                local truthy = evaluateExpr(cond, book, state)
                local matched
                local mid = body:find("%[else%]")
                if mid then
                    if truthy then matched = body:sub(1, mid - 1)
                    else matched = body:sub(mid + #"[else]") end
                else
                    matched = truthy and body or ""
                end
                format = format:sub(1, ifstart - 1) .. matched .. format:sub(endfinish + 1)
                found = true
                break
            end
            pos = ifstart + 1
        end
        if not found then break end
    end
    return format
end

-- Match longest token names first so %book_pct_left wins over %book_pct.
local function compareLengthDesc(a, b) return #a > #b end
local function tokenNamesByLengthDesc()
    local names = {}
    for k in pairs(Tokens.expanders) do names[#names + 1] = k end
    table.sort(names, compareLengthDesc)
    return names
end

local function expandDatetimeBraces(format, state)
    return (format:gsub("%%datetime{(.-)}", function(spec)
        return os.date(spec, timeNow(state))
    end))
end

function Tokens.expand(format, book, state)
    if not format or format == "" then return "" end
    local result = expandDatetimeBraces(format, state)
    result = expandConditionals(result, book, state)
    local names = tokenNamesByLengthDesc()
    for _, name in ipairs(names) do
        local expander = Tokens.expanders[name]
        result = result:gsub("%%" .. name, function()
            return tostring(expander(book, state) or "")
        end)
    end
    return result
end

function Tokens.isEmpty(s)
    if not s then return true end
    -- Strip the v0.1 inline format tags ([b][i][u] and closers) before deciding
    -- emptiness, otherwise [b][/b] around an empty value would count as
    -- non-empty. New format tags added in future versions need to be added here.
    local stripped = s:gsub("%[/?[biu]%]", "")
    return stripped:match("^%s*$") ~= nil
end

return Tokens
