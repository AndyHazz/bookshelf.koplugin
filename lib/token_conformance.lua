--- token_conformance.lua
---
--- VENDORED FILE. Byte-identical copies live at:
---   bookends.koplugin/token_conformance.lua
---   bookshelf.koplugin/lib/token_conformance.lua
---
--- The parity contract for bookshelf #348. Each row is one call into
--- token_semantics.lua and the exact string it must return. Both repos run
--- these rows, so a value can only change by changing this file in both -
--- which is the point.
---
--- Rows carry an explicit `n` (argument count) because arguments legitimately
--- include trailing nils, and `#args` would silently truncate them.
--- `why` is shown in test output so a failure explains itself.
--- A row may also carry `field`, for a function that returns a TABLE: the
--- runner then compares result[field] rather than the result itself.

-- Glyphs are compared as literals rather than by reading Semantics.GLYPHS,
-- so a typo'd codepoint in the module cannot also "fix" the expectation.
local WIFI_ON     = "\xEE\xB2\xA8"
local WIFI_OFF    = "\xEE\xB2\xA9"
local LIGHT_ON    = "\xEE\xB7\xA6"
local LIGHT_OFF   = "\xEE\xA8\xB5"
local NIGHT       = "\xEE\xB2\x93"
local DAY         = "\xEE\xB2\x98"
local WARMTH_LOW  = "\xEE\x88\x8C"
local WARMTH_MID  = "\xEE\x88\x8A"
local WARMTH_HIGH = "\xEE\x88\x8B"

-- A stub standing in for KOReader's datetime module, matching the shape the
-- real one exposes. Kept here so both repos exercise duration identically.
local datetime_stub = {
    secondsToClockDuration = function(fmt, secs, with_hours)
        if fmt == "letters" then
            return string.format("%dh%dm", math.floor(secs / 3600),
                                 math.floor((secs % 3600) / 60))
        end
        return string.format("%d:%02d", math.floor(secs / 3600),
                             math.floor((secs % 3600) / 60))
    end,
}

return {
    -- %warmth: native device scale, gated on natural-light hardware. #348.
    { fn = "warmth", args = {12, true},  n = 2, expect = "12",
      why = "native scale, not a percentage" },
    { fn = "warmth", args = {0, true},   n = 2, expect = "0",
      why = "zero warmth is a real value, not absent" },
    { fn = "warmth", args = {24, true},  n = 2, expect = "24",
      why = "PW5 maximum is 24, not 100" },
    { fn = "warmth", args = {12, false}, n = 2, expect = "",
      why = "no natural-light hardware yields empty so [if:warmth] collapses" },
    { fn = "warmth", args = {nil, true}, n = 2, expect = "",
      why = "nil means no data" },

    -- %warmth_pct / %warmth_icon: the 0-100 escape hatch and its ramp.
    { fn = "warmthPct",  args = {50, true},  n = 2, expect = "50%",
      why = "percentage form carries the suffix" },
    { fn = "warmthPct",  args = {49.6, true}, n = 2, expect = "50%",
      why = "rounded, not truncated" },
    { fn = "warmthPct",  args = {50, false}, n = 2, expect = "" },
    { fn = "warmthIcon", args = {0, true},   n = 2, expect = WARMTH_LOW },
    { fn = "warmthIcon", args = {33, true},  n = 2, expect = WARMTH_LOW,
      why = "below 34 is cool" },
    { fn = "warmthIcon", args = {34, true},  n = 2, expect = WARMTH_MID,
      why = "34 is the first mid value" },
    { fn = "warmthIcon", args = {66, true},  n = 2, expect = WARMTH_MID },
    { fn = "warmthIcon", args = {67, true},  n = 2, expect = WARMTH_HIGH,
      why = "67 is the first warm value" },
    { fn = "warmthIcon", args = {50, false}, n = 2, expect = "" },

    -- %light: the word OFF at zero. #348.
    { fn = "light", args = {0},   n = 1, expect = "OFF",
      why = "the reported bug: bookshelf printed 0" },
    { fn = "light", args = {12},  n = 1, expect = "12" },
    { fn = "light", args = {nil}, n = 1, expect = "",
      why = "no frontlight hardware" },

    { fn = "lightPct",  args = {12, 24},  n = 2, expect = "50%" },
    { fn = "lightPct",  args = {0, 24},   n = 2, expect = "0%",
      why = "zero is a percentage, unlike %light which words it" },
    { fn = "lightPct",  args = {12, 0},   n = 2, expect = "",
      why = "unknown fl_max cannot be normalised" },
    { fn = "lightPct",  args = {12, nil}, n = 2, expect = "" },
    { fn = "lightIcon", args = {1},   n = 1, expect = LIGHT_ON },
    { fn = "lightIcon", args = {0},   n = 1, expect = LIGHT_OFF },
    { fn = "lightIcon", args = {nil}, n = 1, expect = "",
      why = "no frontlight shows nothing, not an off bulb" },

    -- %ram: short suffix, floored. #348.
    { fn = "ram", args = {86016}, n = 1, expect = "84M",
      why = "short M suffix, not MiB" },
    { fn = "ram", args = {86527}, n = 1, expect = "84M",
      why = "floored, not rounded" },
    { fn = "ram", args = {nil},   n = 1, expect = "" },

    -- %disk: identical in both already; pinned.
    { fn = "disk", args = {13207024435}, n = 1, expect = "12.3G" },
    { fn = "disk", args = {0},           n = 1, expect = "" },
    { fn = "disk", args = {nil},         n = 1, expect = "" },

    -- %mem: TRUNCATED. #348.
    { fn = "mem", args = {1000, 624}, n = 2, expect = "37%",
      why = "37.6 truncates to 37; bookshelf rounded to 38" },
    { fn = "mem", args = {1000, 500}, n = 2, expect = "50%" },
    { fn = "mem", args = {0, 0},      n = 2, expect = "" },
    { fn = "mem", args = {nil, nil},  n = 2, expect = "" },

    -- %sysused: MiB, rounded, takes bytes used.
    { fn = "sysused", args = {88080384}, n = 1, expect = "84M",
      why = "short M suffix, not MiB - same call as %ram (#348)" },
    { fn = "sysused", args = {nil},      n = 1, expect = "" },

    -- %batt / %batt_icon: isCharged must reach the symbol function. #348.
    { fn = "batt", args = {82},  n = 1, expect = "82%" },
    { fn = "batt", args = {nil}, n = 1, expect = "" },
    { fn = "battIcon",
      args = {function(charged, charging, cap)
                  return string.format("%s|%s|%d",
                      tostring(charged), tostring(charging), cap)
              end, true, false, 100},
      n = 4, expect = "true|false|100",
      why = "charged must arrive as true; bookshelf hardcoded false" },
    { fn = "battIcon",
      args = {function(charged, charging, cap)
                  return string.format("%s|%s|%d",
                      tostring(charged), tostring(charging), cap)
              end, false, true, 40},
      n = 4, expect = "false|true|40" },
    { fn = "battIcon", args = {nil, true, false, 100}, n = 4, expect = "",
      why = "no symbol function available" },

    -- %wifi: link state, not radio state. #348.
    { fn = "wifi", args = {true, true},   n = 2, expect = WIFI_ON },
    { fn = "wifi", args = {true, false},  n = 2, expect = WIFI_OFF,
      why = "radio on but unlinked is not a connection" },
    { fn = "wifi", args = {false, false}, n = 2, expect = WIFI_OFF },

    { fn = "nightmode", args = {true},  n = 1, expect = NIGHT },
    { fn = "nightmode", args = {false}, n = 1, expect = DAY },

    -- Durations follow the user's duration_format. #348 / bookends #111.
    { fn = "duration", args = {datetime_stub, 11100, "classic"}, n = 3,
      expect = "3:05", why = "classic format" },
    { fn = "duration", args = {datetime_stub, 11100, "letters"}, n = 3,
      expect = "3h5m", why = "the setting must be honoured, not hardcoded" },
    { fn = "duration", args = {datetime_stub, 0, "classic"},     n = 3,
      expect = "" },
    { fn = "duration", args = {nil, 11100, "classic"},           n = 3,
      expect = "", why = "no datetime module available" },

    -- ── Per-book metadata (#348, added with the bookends surface port) ──
    { fn = "status", args = {"complete"},  n = 1, expect = "finished",
      why = "KOReader's vocabulary maps to the canonical one" },
    { fn = "status", args = {"abandoned"}, n = 1, expect = "on_hold" },
    { fn = "status", args = {"new"},       n = 1, expect = "unread" },
    { fn = "status", args = {nil},         n = 1, expect = "unread",
      why = "no DocSettings means unread, not empty" },
    { fn = "status", args = {""},          n = 1, expect = "unread" },
    { fn = "status", args = {"reading"},   n = 1, expect = "reading" },
    { fn = "status", args = {"weird"},     n = 1, expect = "weird",
      why = "an unknown state is still information; do not blank it" },

    { fn = "statusLabel", args = {"finished", { finished = "Finished" }}, n = 2,
      expect = "Finished" },
    { fn = "statusLabel", args = {"reading", { reading = function() return "Reading" end }},
      n = 2, expect = "Reading", why = "a label may be a deferred gettext call" },
    { fn = "statusLabel", args = {"weird", {}}, n = 2, expect = "weird",
      why = "unknown state falls back to the raw value" },

    { fn = "stars", args = {3},   n = 1, expect = "\xE2\x98\x85\xE2\x98\x85\xE2\x98\x85\xE2\x98\x86\xE2\x98\x86" },
    { fn = "stars", args = {0},   n = 1, expect = "",
      why = "unrated is empty so [if:rating] gates the line" },
    { fn = "stars", args = {9},   n = 1, expect = "\xE2\x98\x85\xE2\x98\x85\xE2\x98\x85\xE2\x98\x85\xE2\x98\x85",
      why = "clamped to five" },
    { fn = "stars", args = {nil}, n = 1, expect = "" },

    { fn = "fileSize", args = {512},      n = 1, expect = "512 B" },
    { fn = "fileSize", args = {2048},     n = 1, expect = "2 KB" },
    { fn = "fileSize", args = {5242880},  n = 1, expect = "5.0 MB" },
    { fn = "fileSize", args = {0},        n = 1, expect = "0 B",
      why = "zero bytes is a real size, distinct from no size" },
    { fn = "fileSize", args = {-1},       n = 1, expect = nil },
    { fn = "fileSize", args = {nil},      n = 1, expect = nil,
      why = "nil, not empty string, so the caller can tell them apart" },

    { fn = "isoDate", args = {0},   n = 1, expect = nil,
      why = "0 means unknown, not 1970" },
    { fn = "isoDate", args = {-5},  n = 1, expect = nil },
    { fn = "isoDate", args = {nil}, n = 1, expect = nil },

    { fn = "authorsShort", args = {{"Asimov"}}, n = 1, expect = "Asimov" },
    { fn = "authorsShort", args = {{"Asimov", "Bradbury"}}, n = 1,
      expect = "Asimov and Bradbury" },
    { fn = "authorsShort", args = {{"Asimov", "Bradbury", "Clarke"}}, n = 1,
      expect = "Asimov, Bradbury, et al.", why = "three or more collapses" },
    { fn = "authorsShort", args = {{"A", "B"}, " & "}, n = 2,
      expect = "A & B", why = "the connective is injected for translation" },
    { fn = "authorsShort", args = {{}},  n = 1, expect = "" },
    { fn = "authorsShort", args = {nil}, n = 1, expect = "" },

    -- Annotation counts. KOReader's own rule, and the subtle part is that a
    -- highlight carrying a note counts as a NOTE and not also as a highlight.
    { fn = "annotationCounts", args = {{ { drawer = "lighten" },
                { drawer = "lighten", note = "thought" },
                { page = 12 },
                { drawer = "underscore" } }},
      n = 1, field = "highlights", expect = 2,
      why = "a noted highlight is not counted here" },
    { fn = "annotationCounts", args = {{ { drawer = "lighten" },
                { drawer = "lighten", note = "thought" },
                { page = 12 },
                { drawer = "underscore" } }},
      n = 1, field = "notes", expect = 1 },
    { fn = "annotationCounts", args = {{ { drawer = "lighten" },
                { drawer = "lighten", note = "thought" },
                { page = 12 },
                { drawer = "underscore" } }},
      n = 1, field = "bookmarks", expect = 1,
      why = "no drawer means a bookmark" },
    { fn = "annotationCounts", args = {{ { drawer = "lighten" },
                { drawer = "lighten", note = "thought" },
                { page = 12 },
                { drawer = "underscore" } }},
      n = 1, field = "total", expect = 4 },
    { fn = "annotationCounts", args = {nil}, n = 1, field = "total", expect = 0 },
    { fn = "annotationCounts", args = {{}}, n = 1, field = "highlights", expect = 0 },

    -- %book_pct: identical already; pinned.
    { fn = "pct", args = {0.19},  n = 1, expect = "19%" },
    { fn = "pct", args = {0.195}, n = 1, expect = "20%", why = "rounded" },
    { fn = "pct", args = {0},     n = 1, expect = "0%" },
    { fn = "pct", args = {nil},   n = 1, expect = "" },

    -- cleanDescription: a <dc:description> is HTML, and both plugins have to
    -- agree on what comes out of it. Bookends rendered raw "<p>" on a device
    -- screenshot because the port took the token and not the sanitiser, so
    -- these rows exist to make that divergence a test failure next time.
    { fn = "cleanDescription", args = {"<p>Hello</p>"}, n = 1,
      expect = "Hello", why = "tags stripped, trailing break trimmed" },
    { fn = "cleanDescription", args = {"<p>One</p><p>Two</p>"}, n = 1,
      expect = "One\n\nTwo", why = "paragraph break kept as a blank line" },
    { fn = "cleanDescription", args = {"A<br/>B"}, n = 1,
      expect = "A\nB", why = "<br> is a single newline" },
    { fn = "cleanDescription", args = {"<p>One</p><p>&nbsp;</p><p>Two</p>"}, n = 1,
      expect = "One\n\nTwo", why = "nbsp-only spacer paragraph dropped" },
    { fn = "cleanDescription", args = {"Fish &amp; &lt;chips&gt;"}, n = 1,
      expect = "Fish & <chips>", why = "amp decoded last, so lt/gt survive" },
    { fn = "cleanDescription", args = {"Banks&rsquo; best &mdash; ever"}, n = 1,
      expect = "Banks\xE2\x80\x99 best \xE2\x80\x94 ever", why = "named entities" },
    { fn = "cleanDescription", args = {"&#72;&#x69;"}, n = 1,
      expect = "Hi", why = "numeric entities, decimal and hex" },
    { fn = "cleanDescription", args = {"<P>Upper</P>"}, n = 1,
      expect = "Upper", why = "publishers uppercase tags" },
    { fn = "cleanDescription", args = {""},  n = 1, expect = "" },
    { fn = "cleanDescription", args = {nil}, n = 1, expect = "" },
}
