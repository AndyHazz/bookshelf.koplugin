--- token_semantics.lua
---
--- VENDORED FILE. Byte-identical copies live at:
---   bookends.koplugin/token_semantics.lua
---   bookshelf.koplugin/lib/token_semantics.lua
--- Never edit one without the other. tools/check_token_parity.sh fails on drift.
---
--- The single source of truth for how a token VALUE is formatted, so that a
--- template copied between the reader overlay (bookends) and the library
--- screen (bookshelf) renders the same thing. Bookshelf #348 was filed because
--- it did not: %warmth read 0-24 in one and 0-100 in the other, and a
--- frontlight that was off read "OFF" in one and "0" in the other.
---
--- Pure Lua by design: no KOReader requires, no globals, no I/O. Callers fetch
--- the raw values from PowerD / NetworkMgr / /proc and pass them in. That is
--- what lets this file run under a standalone `lua`, and what makes
--- token_conformance.lua an exhaustive contract rather than a spot check.
---
--- Convention: a nil input means "no data" and returns "" so the containing
--- line, or an [if:token] gate, collapses cleanly.

local Semantics = {}

--- Nerd Font private-use-area codepoints. KOReader registers
--- nerdfonts/symbols.ttf as a global font fallback, so any TextWidget renders
--- these without a special face. They live here rather than at each call site
--- because a glyph copied wrongly is exactly how %wifi drifted the first time.
Semantics.GLYPHS = {
    wifi_on     = "\xEE\xB2\xA8", -- U+ECA8 wifi
    wifi_off    = "\xEE\xB2\xA9", -- U+ECA9 wifi-off
    light_on    = "\xEE\xB7\xA6", -- U+EDE6 lightbulb-on
    light_off   = "\xEE\xA8\xB5", -- U+EA35 lightbulb-outline
    night       = "\xEE\xB2\x93", -- U+EC93 weather-night
    day         = "\xEE\xB2\x98", -- U+EC98 weather-sunny
    warmth_low  = "\xEE\x88\x8C", -- U+E20C thermometer-low
    warmth_mid  = "\xEE\x88\x8A", -- U+E20A thermometer
    warmth_high = "\xEE\x88\x8B", -- U+E20B thermometer-high
}

--- %warmth - the device's OWN warmth scale (0-24 on a Kindle PW5; Kobo
--- differs), NOT a percentage. Bookends has always reported the native value
--- and its users' conditionals are written against it, so bookshelf yields
--- here (#348). Empty on hardware with no natural light, so [if:warmth] gates
--- the whole section out on such devices rather than showing a bare 0.
function Semantics.warmth(native_raw, has_natural_light)
    if not has_natural_light or native_raw == nil then return "" end
    return tostring(native_raw)
end

--- %warmth_pct - the same warmth as a 0-100 percentage, "%"-suffixed to match
--- %book_pct so it drops straight into a template. This is the migration
--- target for anyone who wants the number bookshelf used to print for %warmth.
function Semantics.warmthPct(pct, has_natural_light)
    if not has_natural_light or pct == nil then return "" end
    return math.floor(pct + 0.5) .. "%"
end

--- %warmth_icon - three-step thermometer ramp over the 0-100 warmth:
--- cool below 34, mid to 66, warm at 67 and above.
function Semantics.warmthIcon(pct, has_natural_light)
    if not has_natural_light or pct == nil then return "" end
    if pct < 34 then return Semantics.GLYPHS.warmth_low end
    if pct < 67 then return Semantics.GLYPHS.warmth_mid end
    return Semantics.GLYPHS.warmth_high
end

--- %light - frontlight intensity on the device's own scale, or the word "OFF"
--- at zero. The word rather than "0" is deliberate and is the behaviour #348
--- asked for: a status line reading "OFF" states the light is off, where "0"
--- reads as a measurement that happens to be low.
--- Pass nil when the device has no frontlight at all.
function Semantics.light(intensity)
    if intensity == nil then return "" end
    if intensity == 0 then return "OFF" end
    return tostring(intensity)
end

--- %light_pct - intensity normalised to 0-100 with a "%" suffix. fl_max varies
--- by device (24 on a PW5), which is why the raw %light is kept alongside it.
function Semantics.lightPct(intensity, fl_max)
    if intensity == nil or not fl_max or fl_max <= 0 then return "" end
    return math.floor(intensity / fl_max * 100 + 0.5) .. "%"
end

--- %light_icon - lightbulb-on when lit, lightbulb-outline when not.
--- nil (no frontlight hardware) yields "" rather than the off glyph, so a
--- device without a frontlight shows nothing instead of claiming it is off.
function Semantics.lightIcon(intensity)
    if intensity == nil then return "" end
    return intensity > 0 and Semantics.GLYPHS.light_on
                          or Semantics.GLYPHS.light_off
end

--- %ram - KOReader's own resident set size in MiB, floored, with the short
--- "M" suffix. Bookshelf printed " MiB" and rounded; bookends' compact form
--- wins because its users' layouts are sized for it (#348).
--- Takes KILOBYTES. Callers reading /proc/self/statm must convert pages first
--- (pages * 4), callers reading VmRSS already have kB.
function Semantics.ram(rss_kb)
    if not rss_kb then return "" end
    return math.floor(rss_kb / 1024) .. "M"
end

--- %disk - free space on the home volume, one decimal place, "G" suffix.
--- Takes BYTES. Already identical in both plugins; pinned here so it stays so.
function Semantics.disk(bytes_available)
    if not bytes_available or bytes_available <= 0 then return "" end
    return string.format("%.1fG", bytes_available / 1024 / 1024 / 1024)
end

--- %mem - system memory in use, as a percentage. TRUNCATED, not rounded:
--- bookends floored and bookshelf rounded, so a true 37.6% printed "37%" in
--- the reader and "38%" on the shelf (#348). total and available must be in
--- the SAME unit; the ratio makes which unit irrelevant.
function Semantics.mem(total, available)
    if not total or total <= 0 or not available then return "" end
    return math.floor((total - available) / total * 100) .. "%"
end

--- %sysused - system memory in use in MiB, rounded, with the short "M" suffix.
--- Same call as %ram above: bookshelf printed " MiB", bookends' compact form
--- wins because its users' layouts are sized for it (#348). %sysused arrived
--- from bookshelf after that sweep and kept the long suffix by oversight.
--- Takes BYTES USED (not a total/available pair) so no caller has to agree
--- with another about units.
function Semantics.sysused(used_bytes)
    if not used_bytes then return "" end
    return math.floor(used_bytes / 1024 / 1024 + 0.5) .. "M"
end

--- %batt - battery capacity with a "%" suffix.
function Semantics.batt(capacity)
    if capacity == nil then return "" end
    return capacity .. "%"
end

--- %batt_icon - KOReader's own battery symbol, so the glyph matches the stock
--- footer. symbol_fn must be a closure already bound to PowerD, e.g.
---   function(charged, charging, cap)
---       return powerd:getBatterySymbol(charged, charging, cap)
---   end
--- is_charged MUST be passed through honestly: bookshelf hardcoded false, which
--- made the charged glyph unreachable on a full battery (#348).
function Semantics.battIcon(symbol_fn, is_charged, is_charging, capacity)
    if type(symbol_fn) ~= "function" or capacity == nil then return "" end
    return symbol_fn(is_charged and true or false,
                     is_charging and true or false,
                     capacity) or ""
end

--- %wifi / %wifi_icon - the glyph reflects a WORKING connection, so a radio
--- that is on but unlinked shows wifi-off. The symbol font ships only two
--- glyphs and "on but no link" communicates "no connection" to a reader.
--- Bookshelf aliased %wifi to the radio state alone and so claimed a
--- connection it did not have (#348). Use [if:wifi=on] to test the radio and
--- [if:connected=yes] to test the link.
function Semantics.wifi(is_on, is_connected)
    if is_on and is_connected then return Semantics.GLYPHS.wifi_on end
    return Semantics.GLYPHS.wifi_off
end

--- %nightmode - moon when night mode is active, sun otherwise.
function Semantics.nightmode(is_night)
    return is_night and Semantics.GLYPHS.night or Semantics.GLYPHS.day
end

--- Durations (%book_read_time, %book_time_left, %session_time, %time_today)
--- follow KOReader's own duration_format setting (Settings > Device > Time and
--- date), so a reader who picked "letters" or "modern" sees it everywhere.
--- Bookshelf hardcoded "3h 05m" (#348; bookends documented this in its #111).
--- `datetime` is INJECTED rather than required so this file stays KOReader-free
--- and so KOReader's formatter is never reimplemented - reimplementing it would
--- simply create a third dialect to drift from.
function Semantics.duration(datetime, secs, duration_format)
    if not secs or secs <= 0 then return "" end
    if type(datetime) ~= "table"
       or type(datetime.secondsToClockDuration) ~= "function" then
        return ""
    end
    return datetime.secondsToClockDuration(
        duration_format or "classic", secs, true) or ""
end

-- ── Per-book metadata formatting ───────────────────────────────────────────
-- Added when bookends gained bookshelf's metadata tokens (#348). These live
-- here for the same reason the device rules do: two plugins showing the same
-- book's rating, size or status must show it the same way, and the only way to
-- guarantee that is one implementation.

--- %status - reading status normalised to four canonical strings, so
--- [if:status=finished] is reliable. These are NOT translated and must not be:
--- conditionals compare against them, and they have to mean the same thing in
--- every language. KOReader's own vocabulary ("complete", "abandoned", "new")
--- maps in; anything unrecognised passes through, since a state this build has
--- not heard of is still information.
function Semantics.status(raw)
    if raw == "complete" then return "finished" end
    if raw == "abandoned" then return "on_hold" end
    if raw == "new" or raw == nil or raw == "" then return "unread" end
    return tostring(raw)
end

--- %status_label - the same four states as words a reader recognises.
--- `labels` is injected (a table keyed by canonical status) rather than
--- required, keeping this file free of gettext. An unknown state returns its
--- raw value rather than empty: blanking it would look like a broken token.
function Semantics.statusLabel(canonical, labels)
    local label = labels and labels[canonical]
    if label == nil then return canonical or "" end
    if type(label) == "function" then return label() end
    return tostring(label)
end

--- %rating - N filled plus (5-N) empty stars. Plain Unicode, not Private Use
--- Area, so it renders in any face. Empty for unrated so [if:rating] can gate
--- the line.
function Semantics.stars(rating)
    local r = math.floor(tonumber(rating) or 0)
    if r < 1 then return "" end
    if r > 5 then r = 5 end
    local filled = "\xE2\x98\x85"  -- U+2605 BLACK STAR
    local empty  = "\xE2\x98\x86"  -- U+2606 WHITE STAR
    return filled:rep(r) .. empty:rep(5 - r)
end

--- %size - a file size a reader can scan at a glance. Returns nil (not "") for
--- a non-size so the caller can tell "no value" from "zero bytes".
function Semantics.fileSize(bytes)
    if type(bytes) ~= "number" or bytes < 0 then return nil end
    if bytes < 1024 then return string.format("%d B", bytes) end
    local kb = bytes / 1024
    if kb < 1024 then return string.format("%d KB", math.floor(kb + 0.5)) end
    return string.format("%.1f MB", kb / 1024)
end

--- %added / %opened - ISO date from a unix epoch. A non-positive epoch is "no
--- date" rather than 1970: every field that reaches here uses 0 for unknown.
--- Returns nil for no date, so the caller decides what empty looks like.
function Semantics.isoDate(epoch)
    if type(epoch) ~= "number" or epoch <= 0 then return nil end
    return os.date("%Y-%m-%d", epoch)
end

--- %authors_short - one name, "A and B", or "A, B, et al." for three or more.
--- The connectives are injected for translation, defaulting to English.
function Semantics.authorsShort(list, and_word, et_al)
    if type(list) ~= "table" or #list == 0 then return "" end
    if #list == 1 then return tostring(list[1]) end
    if #list == 2 then
        return tostring(list[1]) .. (and_word or " and ") .. tostring(list[2])
    end
    return tostring(list[1]) .. ", " .. tostring(list[2]) .. (et_al or ", et al.")
end

--- %highlights / %notes / %bookmarks / %annotations - counts over a list of
--- KOReader annotation items, which is the same shape in a live reader
--- (ReaderAnnotation.annotations) and in a DocSettings sidecar.
---
--- The rules are KOReader's own, copied from
--- readerannotation.lua:getNumberOfHighlightsAndNotes and verified against it
--- rather than assumed: an item with a `drawer` is a highlight UNLESS it also
--- carries a `note`, in which case it counts as a note and NOT as a highlight.
--- An item with no drawer is a bookmark. The total is simply every item.
---
--- Here because the reader can ask KOReader directly while the library screen
--- has to count sidecar entries itself, and two implementations of "what is a
--- note" would drift the first time KOReader changed its mind.
function Semantics.annotationCounts(items)
    local out = { highlights = 0, notes = 0, bookmarks = 0, total = 0 }
    if type(items) ~= "table" then return out end
    for _idx, item in ipairs(items) do
        out.total = out.total + 1
        if type(item) == "table" and item.drawer then
            if item.note then
                out.notes = out.notes + 1
            else
                out.highlights = out.highlights + 1
            end
        else
            out.bookmarks = out.bookmarks + 1
        end
    end
    return out
end

--- %book_pct and friends - a 0..1 fraction as a rounded percentage. Already
--- identical in both plugins; pinned so it stays so.
function Semantics.pct(fraction)
    if fraction == nil then return "" end
    return string.format("%d%%", math.floor(fraction * 100 + 0.5))
end


-- ─── Description sanitising ──────────────────────────────────────────────────
--
-- VENDORED, and vendored for a concrete reason: %description existed in
-- bookshelf with this sanitiser and was ported to bookends in 85aa7c8 WITHOUT
-- it, so bookends rendered "<p>The first ever collection of..." on screen while
-- bookshelf rendered the text. Exactly the drift the vendoring exists to stop,
-- caught on a device screenshot rather than by any test.
--
-- A <dc:description> is HTML, not text. Block tags become newlines, everything
-- else is stripped, entities are decoded, and empty spacer paragraphs are
-- dropped. Stripping MARKUP is not the same as cleaning DATA - the text itself
-- is passed through untouched.

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

function Semantics.cleanDescription(raw)
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
            -- Pretty-printed source (<p>\n  Text\n</p>) leaves indentation
            -- whitespace right after the </p> -> \n\n newlines we inserted;
            -- the newline-collapse above only touches newlines, not the
            -- spaces/tabs that follow them, so trim each paragraph's own
            -- edges here rather than just the whole string's (issue #306).
            local trimmed = (para:gsub("^%s+", ""):gsub("%s+$", ""))
            -- nbsp (U+00A0 = 0xC2 0xA0 in UTF-8) isn't %s in Lua patterns;
            -- coerce to a regular space before the whitespace strip.
            local stripped = trimmed:gsub("\xC2\xA0", " "):gsub("%s+", "")
            if stripped ~= "" then
                kept[#kept + 1] = trimmed
            end
        end
        text = table.concat(kept, "\n\n")
    end
    -- Trim leading/trailing whitespace + newlines.
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

return Semantics
