--- Icons library catalogue: chip definitions, curated picks, pattern-fill
--- rules, and per-chip exclusions. This file is data-only -- the projection
--- and rendering live in lib/bookshelf_icons_library.lua.
---
--- Curated entry shapes:
---   { code = 0xNNNN, ... }   - Nerd Font glyph picked by codepoint. Label
---                              comes from the font's cmap unless overridden
---                              by `label = ...`.
---   { glyph = "<bytes>", label = "..." }
---                            - Pure-Unicode glyph (not in the cmap). Label
---                              is the hand-written description.
--- Optional fields: `label` (override the cmap name), `insert_value` (token
--- string inserted instead of the literal glyph -- used for dynamic icons).

local _ = require("lib/bookshelf_i18n").gettext

local M = {}

M.CHIPS = {
    { key = "all", label = _("All") },
    { key = "dynamic", label = _("Dynamic") },
    { key = "device", label = _("Device") },
    { key = "reading", label = _("Reading") },
    { key = "time", label = _("Time") },
    { key = "symbols", label = _("Symbols") },
    { key = "arrows", label = _("Arrows") },
    { key = "blocks", label = _("Blocks") },
    { key = "separators", label = _("Separators") },
    { key = "svg", label = _("SVG icon folder") },
}

M.CURATED_BY_CHIP = {
    -- Dynamic entries insert a %token (expanded by lib/bookshelf_tokens.lua)
    -- instead of a literal glyph. Only useful where the picked value lands in
    -- a token template (hero clock/status line); chip labels/icons and start
    -- menu icons render literally, so those callers pass { dynamic = false }.
    -- Vocabulary matches the tokens engine: %batt_icon, %wifi_icon,
    -- %light_icon, %nightmode (no warmth-icon expander here).
    dynamic = {
        { code = 0xE783, label = _("Battery"), insert_value = "%batt_icon" },   -- battery-charging
        { code = 0xECA8, label = _("Wi-Fi"), insert_value = "%wifi_icon" },   -- wifi
        { code = 0xEDE6, label = _("Frontlight"), insert_value = "%light_icon" },   -- lightbulb-on
        { code = 0xEC93, label = _("Night mode"), insert_value = "%nightmode" },   -- weather-night
    },
    device = {
        { code = 0xE782 },   -- battery-alert
        { code = 0xECA8 },   -- wifi
        { code = 0xECA9 },   -- wifi-off
        { code = 0xEBA1 },   -- signal
        { code = 0xE7AE },   -- bluetooth
        { code = 0xE81B },   -- cellphone
        { code = 0xE266 },   -- chip
        { code = 0xF0A0 },   -- hdd
        { code = 0xECED },   -- disk
        { code = 0xE268 },   -- cloud
        { code = 0xF013 },   -- cog
        { code = 0xEDA3 },   -- power-plug
        { code = 0xEDA4 },   -- power-plug-off
        { code = 0xE9CA },   -- headphones
        { code = 0xEECC },   -- headphones-off
        { code = 0xF085 },   -- cogs
        { code = 0xE7DF },   -- brightness-7
        { code = 0xE7DD },   -- brightness-5
        { code = 0xE7E0 },   -- brightness-auto
        { code = 0xF185 },   -- sun
        { code = 0xECA7 },   -- white-balance-sunny
        { code = 0xE7B1 },   -- bluetooth-off
        { code = 0xE7B0 },   -- bluetooth-connect
        { code = 0xEA5A },   -- memory
        { code = 0xEEDA },   -- micro-sd
        { code = 0xEC93 },   -- weather-night
        { code = 0xEC98 },   -- weather-sunny
        { code = 0xECE1 },   -- candle
        { code = 0xF490 },   -- flame
        { code = 0xE943 },   -- flashlight
        { code = 0xE944 },   -- flashlight-off
    },
    reading = {
        { code = 0xE7B9 },   -- book
        { code = 0xE7BD },   -- book-open-variant
        { code = 0xE7BE },   -- book-variant
        { code = 0xE7BA },   -- book-multiple
        { code = 0xEA30 },   -- library
        { code = 0xE7BF },   -- bookmark
        { code = 0xE7C2 },   -- bookmark-outline
        { code = 0xE7C0 },   -- bookmark-check
        { code = 0xEA99 },   -- note
        { code = 0xEAEA },   -- pencil
        { code = 0xEAE9 },   -- pen
        { code = 0xEB46 },   -- read
        { code = 0xE766 },   -- audiobook
        { code = 0xE28A },   -- book-open
        { code = 0xE28B },   -- book-open-o
        { code = 0xECD9 },   -- book-open-page-variant
        { code = 0xECD8 },   -- book-minus
        { code = 0xE7BC },   -- book-open.1
        { code = 0xF02D },   -- book.1
        { code = 0xEE99 },   -- book-unsecure
        { code = 0xEE98 },   -- book-secure
        { code = 0xECDA },   -- book-plus
        { code = 0xE7BB },   -- book-multiple-variant
        { code = 0xF405 },   -- book.2
        { code = 0xE7C4 },   -- bookmark-plus
        { code = 0xE7C3 },   -- bookmark-plus-outline
        { code = 0xE7C1 },   -- bookmark-music
        { code = 0xE7C5 },   -- bookmark-remove
        { code = 0xF02E },   -- bookmark.1
        { code = 0xF461 },   -- bookmark.2
        { code = 0xF097 },   -- bookmark_empty
        { code = 0xEF2C },   -- notebook
        { code = 0xEA31 },   -- library-books
        { code = 0xEA9D },   -- note-text
        { code = 0xF040 },   -- pencil.1
        { code = 0xEDD1 },   -- feather
        { code = 0xE97D },   -- format-quote-close
        { code = 0xEE55 },   -- format-quote-open
        { code = 0xF453 },   -- quote
        { code = 0xF10D },   -- quote_left
        { code = 0xF10E },   -- quote_right
        { code = 0xF06E },   -- eye_open
        { code = 0xF070 },   -- eye_close
        { code = 0xF441 },   -- eye.1
        { code = 0xEDCE },   -- eye-outline
        { code = 0xE907 },   -- eye
        { code = 0xE908 },   -- eye-off
        { code = 0xEDCF },   -- eye-off-outline
        { code = 0xEA94 },   -- newspaper
        { code = 0xF42A },   -- sign-in
        { code = 0xF426 },   -- sign-out
        { code = 0xE245 },   -- glass
        { code = 0xE9A9 },   -- glasses
        { code = 0xF0E5 },   -- comment_alt
        { code = 0xF075 },   -- comment.1
        { code = 0xF41F },   -- comment.2
        { code = 0xF0E6 },   -- comments_alt
        { code = 0xE8EF },   -- email-outline
        { code = 0xE8ED },   -- email
        { code = 0xEB6B },   -- rss-box
        { code = 0xE978 },   -- format-list-bulleted
        { code = 0xEA14 },   -- label
        { code = 0xEA15 },   -- label-outline
    },
    time = {
        { code = 0xE84F },   -- clock
        { code = 0xE851 },   -- clock-fast
        { code = 0xE850 },   -- clock-end
        { code = 0xE71F },   -- alarm
        { code = 0xEE8C },   -- alarm-bell
        { code = 0xE7EC },   -- calendar
        { code = 0xE7ED },   -- calendar-blank
        { code = 0xE7EF },   -- calendar-clock
        { code = 0xE7F5 },   -- calendar-today
        { code = 0xE7EE },   -- calendar-check
        { code = 0xEC1A },   -- timer
        { code = 0xEC1E },   -- timer-sand
        { code = 0xEC88 },   -- watch
        { code = 0xECCD },   -- clock-alert
        { code = 0xE854 },   -- clock-start
        { code = 0xF43A },   -- clock.1
        { code = 0xE853 },   -- clock-out
        { code = 0xE852 },   -- clock-in
        { code = 0xE720 },   -- alarm-check
        { code = 0xF49B },   -- watch.1
        { code = 0xEDAB },   -- timer-sand-empty
        { code = 0xEE8A },   -- timer-sand-full
        { code = 0xE76A },   -- av-timer
        { code = 0xE808 },   -- camera-timer
        { code = 0xE9D9 },   -- history
        { code = 0xEBC4 },   -- speedometer
        { code = 0xF0E4 },   -- dashboard
        { code = 0xF463 },   -- dashboard.1
    },
    symbols = {
        { glyph = "\xE2\x98\xBC", label = _("Sun (outline)") },
        { glyph = "\xE2\x99\xA8", label = _("Hot springs / warmth") },
        { glyph = "\xE2\x99\xA0", label = _("Spade") },
        { glyph = "\xE2\x99\xA3", label = _("Club") },
        { glyph = "\xE2\x99\xA5", label = _("Heart") },
        { glyph = "\xE2\x99\xA6", label = _("Diamond suit") },
        { glyph = "\xE2\x98\x85", label = _("Star (filled)") },
        { glyph = "\xE2\x98\x86", label = _("Star (outline)") },
        { glyph = "\xE2\x88\x9E", label = _("Infinity") },
        { glyph = "\xC2\xA7", label = _("Section sign") },
        { glyph = "\xC2\xB6", label = _("Pilcrow / paragraph") },
        { glyph = "\xE2\x80\xA0", label = _("Dagger") },
        { glyph = "\xE2\x80\xA1", label = _("Double dagger") },
        { glyph = "\xE2\x84\x96", label = _("Numero") },
        { glyph = "\xE2\x9A\xA1", label = _("High voltage") },
        { code = 0xEE26 },   -- view-parallel
        { code = 0xE97C },   -- format-paragraph
        { code = 0xF006 },   -- star_empty
        { code = 0xF41E },   -- star.2
        { code = 0xF123 },   -- star_half_empty
        { code = 0xF121 },   -- code
        { code = 0xE82B },   -- check
        { code = 0xE82C },   -- check-all
        { code = 0xECDF },   -- check-circle
        { code = 0xF046 },   -- check.1
        { code = 0xE725 },   -- alert
        { code = 0xEDBB },   -- alert-decagram
        { code = 0xEE65 },   -- alert-octagram
        { code = 0xE7B4 },   -- blur
        { code = 0xE8C8 },   -- creation
        { code = 0xEC93 },   -- weather-night
        { code = 0xEC98 },   -- weather-sunny
        { code = 0xF0F4 },   -- coffee.1
        { code = 0xEEB2 },   -- chili-mild
        { code = 0xEEB1 },   -- chili-medium
        { code = 0xEEB0 },   -- chili-hot
        { code = 0xE273 },   -- donut
        { code = 0xECE5 },   -- copyright
    },
    arrows = {
        { glyph = "\xE2\x86\x90", label = _("Arrow left") },
        { glyph = "\xE2\x86\x92", label = _("Arrow right") },
        { glyph = "\xE2\x86\x91", label = _("Arrow up") },
        { glyph = "\xE2\x86\x93", label = _("Arrow down") },
        { glyph = "\xE2\x87\x90", label = _("Double arrow left") },
        { glyph = "\xE2\x87\x92", label = _("Double arrow right") },
        { glyph = "\xE2\x87\x91", label = _("Double arrow up") },
        { glyph = "\xE2\x87\x93", label = _("Double arrow down") },
        { glyph = "\xE2\x87\x84", label = _("Arrows left-right") },
        { glyph = "\xE2\x87\x89", label = _("Double arrows right") },
        { glyph = "\xE2\xA5\x96", label = _("Left harpoon with right arrow") },
        { glyph = "\xE2\xA4\xBB", label = _("Curved back arrow") },
        { glyph = "\xE2\x86\xA2", label = _("Arrow left with tail") },
        { glyph = "\xE2\x86\xA3", label = _("Arrow right with tail") },
        { glyph = "\xE2\xA4\x9F", label = _("Arrow left to bar") },
        { glyph = "\xE2\xA4\xA0", label = _("Arrow right to bar") },
        { glyph = "\xE2\x86\xA9", label = _("Arrow left hooked") },
        { glyph = "\xE2\x86\xAA", label = _("Arrow right hooked") },
        { glyph = "\xE2\xA4\xB4", label = _("Arrow right then up") },
        { glyph = "\xE2\xA4\xB5", label = _("Arrow right then down") },
        { glyph = "\xE2\x86\xB0", label = _("Arrow up then left") },
        { glyph = "\xE2\x86\xB1", label = _("Arrow up then right") },
        { glyph = "\xE2\x86\xB2", label = _("Arrow down then left") },
        { glyph = "\xE2\x86\xB3", label = _("Arrow down then right") },
        { glyph = "\xE2\x86\xBA", label = _("Circle arrow left") },
        { glyph = "\xE2\x86\xBB", label = _("Circle arrow right") },
        { glyph = "\xE2\x9E\x94", label = _("Heavy arrow right") },
        { glyph = "\xE2\x9E\x9C", label = _("Heavy round arrow right") },
        { glyph = "\xE2\x9E\x9D", label = _("Triangle-head right") },
        { glyph = "\xE2\x9E\x9E", label = _("Heavy triangle right") },
        { glyph = "\xE2\x9E\xA4", label = _("Arrowhead right") },
        { glyph = "\xE2\x9F\xB5", label = _("Long arrow left") },
        { glyph = "\xE2\x9F\xB6", label = _("Long arrow right") },
        { glyph = "\xE2\x80\xB9", label = _("Single angle left") },
        { glyph = "\xE2\x80\xBA", label = _("Single angle right") },
        { glyph = "\xC2\xAB", label = _("Double angle left") },
        { glyph = "\xC2\xBB", label = _("Double angle right") },
        { code = 0xE740 },   -- arrow-all
        { code = 0xE741 },   -- arrow-bottom-left
        { code = 0xE742 },   -- arrow-bottom-right
        { code = 0xEE91 },   -- arrow-collapse-left
        { code = 0xEE90 },   -- arrow-collapse-down
        { code = 0xEE92 },   -- arrow-collapse-right
        { code = 0xEE93 },   -- arrow-collapse-up
        { code = 0xE744 },   -- arrow-down
        { code = 0xEE2C },   -- arrow-down-bold
        { code = 0xE745 },   -- arrow-down-thick
        { code = 0xF433 },   -- arrow-down.1
        { code = 0xED15 },   -- arrow-expand
        { code = 0xEE94 },   -- arrow-expand-down
        { code = 0xEE95 },   -- arrow-expand-left
        { code = 0xEE96 },   -- arrow-expand-right
        { code = 0xEE97 },   -- arrow-expand-up
        { code = 0xE74C },   -- arrow-left
        { code = 0xEE2F },   -- arrow-left-bold
        { code = 0xE74D },   -- arrow-left-thick
        { code = 0xF434 },   -- arrow-left.1
        { code = 0xE753 },   -- arrow-right
        { code = 0xEE32 },   -- arrow-right-bold
        { code = 0xE754 },   -- arrow-right-thick
        { code = 0xF432 },   -- arrow-right.1
        { code = 0xF479 },   -- arrow-small-down
        { code = 0xF47A },   -- arrow-small-left
        { code = 0xF45C },   -- arrow-small-right
        { code = 0xF478 },   -- arrow-small-up
        { code = 0xE75A },   -- arrow-top-left
        { code = 0xE75B },   -- arrow-top-right
        { code = 0xE75C },   -- arrow-up
        { code = 0xEE35 },   -- arrow-up-bold
        { code = 0xE75D },   -- arrow-up-thick
        { code = 0xF431 },   -- arrow-up.1
        { code = 0xF063 },   -- arrow_down
        { code = 0xF060 },   -- arrow_left
        { code = 0xF061 },   -- arrow_right
        { code = 0xF062 },   -- arrow_up
        { code = 0xF0AB },   -- circle_arrow_down
        { code = 0xF0AA },   -- circle_arrow_up
        { code = 0xF0A9 },   -- circle_arrow_right
        { code = 0xF0A8 },   -- circle_arrow_left
        { code = 0xE9FA },   -- inbox-arrow-down
        { code = 0xEAD0 },   -- inbox-arrow-up
        { code = 0xF124 },   -- location_arrow
        { code = 0xF175 },   -- long_arrow_down
        { code = 0xF177 },   -- long_arrow_left
        { code = 0xED0B },   -- subdirectory-arrow-left
        { code = 0xEB42 },   -- ray-start-arrow
        { code = 0xEB40 },   -- ray-end-arrow
        { code = 0xF176 },   -- long_arrow_up
        { code = 0xF178 },   -- long_arrow_right
        { code = 0xED0C },   -- subdirectory-arrow-right
        { code = 0xE9C6 },   -- hand-pointing-right
        { code = 0xE8B6 },   -- cursor-pointer
        { code = 0xE83B },   -- chevron-double-down
        { code = 0xE83C },   -- chevron-double-left
        { code = 0xE83D },   -- chevron-double-right
        { code = 0xE83E },   -- chevron-double-up
        { code = 0xE83F },   -- chevron-down
        { code = 0xF47C },   -- chevron-down.1
        { code = 0xE840 },   -- chevron-left
        { code = 0xF47D },   -- chevron-left.1
        { code = 0xE841 },   -- chevron-right
        { code = 0xF460 },   -- chevron-right.1
        { code = 0xF054 },   -- chevron_right
        { code = 0xF077 },   -- chevron_up
        { code = 0xF053 },   -- chevron_left
        { code = 0xF139 },   -- chevron_sign_up
        { code = 0xF138 },   -- chevron_sign_right
        { code = 0xF078 },   -- chevron_down
        { code = 0xF137 },   -- chevron_sign_left
        { code = 0xF47B },   -- chevron-up.1
        { code = 0xE842 },   -- chevron-up
        { code = 0xF13A },   -- chevron_sign_down
        { code = 0xEA5D },   -- menu-left
        { code = 0xEA5E },   -- menu-right
        { code = 0xE93E },   -- flag-triangle
        { code = 0xEB3F },   -- ray-end
        { code = 0xEB41 },   -- ray-start
        { code = 0xEB43 },   -- ray-start-end
        { code = 0xEB44 },   -- ray-vertex
        { code = 0xEDA5 },   -- publish
        { code = 0xE910 },   -- fast-forward
        { code = 0xEDD0 },   -- fast-forward-outline
        { code = 0xF049 },   -- fast_backward
        { code = 0xF050 },   -- fast_forward
        { code = 0xECFF },   -- page-first
        { code = 0xED00 },   -- page-last
        { code = 0xE8BA },   -- debug-step-into
        { code = 0xE8BB },   -- debug-step-out
        { code = 0xE8BC },   -- debug-step-over
        { code = 0xEBD4 },   -- step-backward
        { code = 0xEBD5 },   -- step-backward-2
        { code = 0xF051 },   -- step_forward
        { code = 0xF048 },   -- step_backward
        { code = 0xEBD7 },   -- step-forward-2
        { code = 0xEBD6 },   -- step-forward
    },
    blocks = {
        { glyph = "\xE2\x96\x88", label = _("Block (full)") },
        { glyph = "\xE2\x96\x93", label = _("Block (dark)") },
        { glyph = "\xE2\x96\x92", label = _("Block (medium)") },
        { glyph = "\xE2\x96\x91", label = _("Block (light)") },
        { glyph = "\xE2\x96\x80", label = _("Upper half block") },
        { glyph = "\xE2\x96\x90", label = _("Right half block") },
        { glyph = "\xE2\x96\x81", label = _("Lower 1/8 block") },
        { glyph = "\xE2\x96\x82", label = _("Lower 2/8 block") },
        { glyph = "\xE2\x96\x83", label = _("Lower 3/8 block") },
        { glyph = "\xE2\x96\x84", label = _("Lower 4/8 block") },
        { glyph = "\xE2\x96\x85", label = _("Lower 5/8 block") },
        { glyph = "\xE2\x96\x86", label = _("Lower 6/8 block") },
        { glyph = "\xE2\x96\x87", label = _("Lower 7/8 block") },
        { glyph = "\xE2\x96\x8F", label = _("Left 1/8 block") },
        { glyph = "\xE2\x96\x8E", label = _("Left 2/8 block") },
        { glyph = "\xE2\x96\x8D", label = _("Left 3/8 block") },
        { glyph = "\xE2\x96\x8C", label = _("Left 4/8 block") },
        { glyph = "\xE2\x96\x8B", label = _("Left 5/8 block") },
        { glyph = "\xE2\x96\x8A", label = _("Left 6/8 block") },
        { glyph = "\xE2\x96\x89", label = _("Left 7/8 block") },
        { glyph = "\xE2\x96\xA0", label = _("Square (filled)") },
        { glyph = "\xE2\x96\xA1", label = _("Square (empty)") },
        { glyph = "\xE2\x96\xAC", label = _("Rectangle (filled)") },
        { glyph = "\xE2\x96\xAD", label = _("Rectangle (empty)") },
        { glyph = "\xE2\x96\xAE", label = _("Vertical block") },
        { glyph = "\xE2\x96\xAF", label = _("Vertical block (empty)") },
        { glyph = "\xE2\x96\xB0", label = _("Slant block") },
        { glyph = "\xE2\x96\xB1", label = _("Slant block (empty)") },
        { glyph = "\xE2\x97\x8F", label = _("Circle (filled)") },
        { glyph = "\xE2\x97\x8B", label = _("Circle (empty)") },
        { glyph = "\xE2\x97\x90", label = _("Circle (left half)") },
        { glyph = "\xE2\x97\x91", label = _("Circle (right half)") },
        { glyph = "\xE2\x97\x92", label = _("Circle (lower half)") },
        { glyph = "\xE2\x97\x93", label = _("Circle (upper half)") },
        { glyph = "\xE2\x97\x86", label = _("Diamond (filled)") },
        { glyph = "\xE2\x97\x87", label = _("Diamond (empty)") },
    },
    separators = {
        { glyph = "|", label = _("Vertical bar") },
        { glyph = "\xE2\x80\xA2", label = _("Bullet") },
        { glyph = "\xC2\xB7", label = _("Middle dot") },
        { glyph = "\xE2\x8B\xAE", label = _("Vertical ellipsis") },
        { glyph = "\xE2\x80\x94", label = _("Em dash") },
        { glyph = "\xE2\x80\x93", label = _("En dash") },
        { glyph = "\xE2\x80\xA6", label = _("Horizontal ellipsis") },
        { glyph = "/", label = _("Slash") },
        { glyph = "\xE2\x88\x95", label = _("Division slash") },
        { glyph = "\xE2\x81\x84", label = _("Fraction slash") },
        { glyph = "\xE2\x81\x84\xE2\x81\x84", label = _("Double fraction slash") },
        { glyph = "~", label = _("Tilde") },
        { glyph = "\xE2\x80\xA3", label = _("Triangular bullet") },
        { code = 0xE216 },   -- slash
        { code = 0xE8D7 },   -- dots-horizontal
        { code = 0xE8D8 },   -- dots-vertical
        { code = 0xF444 },   -- primitive-dot
        { code = 0xF48B },   -- dash
        { code = 0xF47A },   -- arrow-small-left
        { code = 0xF45C },   -- arrow-small-right
    },
}

M.PATTERNS_BY_CHIP = {
}

M.PATTERN_EXCLUDES = {
}

return M
