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

--- %sysused - system memory in use in MiB, rounded. Takes BYTES USED (not a
--- total/available pair) so no caller has to agree with another about units.
function Semantics.sysused(used_bytes)
    if not used_bytes then return "" end
    return math.floor(used_bytes / 1024 / 1024 + 0.5) .. " MiB"
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

--- %book_pct and friends - a 0..1 fraction as a rounded percentage. Already
--- identical in both plugins; pinned so it stays so.
function Semantics.pct(fraction)
    if fraction == nil then return "" end
    return string.format("%d%%", math.floor(fraction * 100 + 0.5))
end

return Semantics
