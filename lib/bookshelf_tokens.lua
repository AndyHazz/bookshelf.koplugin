-- bookshelf_tokens.lua
-- Homescreen-scoped token expander. Bookends-compatible syntax, scoped
-- vocabulary tied to homescreen-available data sources.

-- gettext for the picker-facing token descriptions below. Wrapped at
-- catalogue-definition time (eval-on-load), so the picker can keep
-- displaying t.description verbatim and still show the translated text
-- (issue #129). i18n is initialised before plugins load, so the locale
-- is set by the time this module is required.
local _ = require("lib/bookshelf_i18n").gettext
-- The inline style vocabulary ([b] / [i] / [font=] / [size=]). Owned by its
-- own module because the RENDERER needs to split a line on it; needed here
-- because everything that transforms or previews a template has to know which
-- brackets are markup. Pure string code, no requires of its own, no cycle.
local InlineStyle = require("lib/bookshelf_inline_style")

local Tokens = {}

-- Display labels for the token-picker category headers. Kept as literal
-- _() strings (instead of _(t.category) at the picker) so xgettext can
-- extract them -- mirrors bookends' tokens_catalogue, which keys category
-- separately from its label. A _(variable) call never reaches the .pot,
-- so the headers shipped untranslated (issues #129 / #143).
Tokens.CATEGORY_LABELS = {
    Authors  = _("Authors"),
    Book     = _("Book"),
    Device   = _("Device"),
    Logic    = _("Logic"),
    Progress = _("Progress"),
    Style    = _("Style"),
    Time     = _("Time"),
}
function Tokens.categoryLabel(cat)
    return Tokens.CATEGORY_LABELS[cat] or cat
end

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
-- description = _("...") so the strings are extracted by xgettext and
-- translated at load (issue #129). category stays a raw key: it's used for
-- filtering and grouping. The picker maps it to a display label via
-- Tokens.categoryLabel(), whose CATEGORY_LABELS table holds the literal
-- _() strings so xgettext can extract them (issues #129 / #143).
Tokens.CATALOGUE = {
    { category = "Book",     token = "%title",            description = _("Title") },
    { category = "Authors",  token = "%author",           description = _("First author") },
    { category = "Authors",  token = "%author_2",         description = _("Second author") },
    { category = "Authors",  token = "%author_3",         description = _("Third author") },
    { category = "Authors",  token = "%author_count",     description = _("Number of authors (numeric)") },
    { category = "Authors",  token = "%authors",          description = _("All authors, comma-separated") },
    { category = "Authors",  token = "%authors_short",    description = _("First author, or 'A and B', or 'A, B, et al.' for 3+") },
    { category = "Book",     token = "%series_name",      description = _("Series name") },
    { category = "Book",     token = "%series_num",       description = _("Series number") },
    { category = "Book",     token = "%rating",           description = _("Star rating (★★★☆☆), empty when unrated") },
    { category = "Book",     token = "%rating_number",    description = _("Rating as a number 1-5 (empty when unrated)") },
    { category = "Book",     token = "%hardcover_rating", description = _("Cached Hardcover rating number") },
    { category = "Book",     token = "%hardcover_stars",  description = _("Cached Hardcover rating as stars") },
    { category = "Book",     token = "%status",           description = _("Reading status, raw value for conditionals (unread / reading / on_hold / finished)") },
    { category = "Book",     token = "%status_label",     description = _("Reading status as a readable label (Unread / Reading / On hold / Finished)") },
    { category = "Book",     token = "%favourite",        description = _("Favourite icon, empty when not a favourite") },
    { category = "Book",     token = "%filename",         description = _("File name") },
    { category = "Book",     token = "%format",           description = _("Format (EPUB/PDF/…)") },
    { category = "Book",     token = "%calibre{name}",     description = _("A calibre column by name, like %calibre{pubdate} or a custom column; dates show the year (needs the calibre beta)") },
    { category = "Book",     token = "%size",             description = _("File size on disk") },
    { category = "Book",     token = "%added",            description = _("Date added (the file's own date)") },
    { category = "Book",     token = "%description",      description = _("Book blurb (HTML stripped)") },
    { category = "Book",     token = "%quote",            description = _("A random highlight from this book") },
    { category = "Book",     token = "%quote_source",     description = _("The book and author for %quote") },
    { category = "Book",     token = "%lang",             description = _("Language") },
    { category = "Progress", token = "%book_pct",         description = _("Percent read") },
    { category = "Progress", token = "%book_pct_left",    description = _("Percent left") },
    { category = "Progress", token = "%page_num",         description = _("Current page") },
    { category = "Progress", token = "%page_count",       description = _("Total pages (approximate for EPUB)") },
    { category = "Progress", token = "%pages_left",       description = _("Pages left (approximate for EPUB)") },
    { category = "Progress", token = "%book_time_left",   description = _("Time left to finish (statistics)") },
    { category = "Progress", token = "%book_read_time",   description = _("Total time read (statistics)") },
    { category = "Progress", token = "%book_pages_read",  description = _("Pages read (statistics)") },
    { category = "Progress", token = "%days_reading_book",description = _("Days since first opened (statistics)") },
    { category = "Progress", token = "%pages_per_day",    description = _("Pages per day (statistics)") },
    { category = "Progress", token = "%speed",            description = _("Speed in pages/hour (statistics)") },
    { category = "Progress", token = "%opened",           description = _("Date this book was last opened") },
    { category = "Progress", token = "%books_read",       description = _("How many books in your whole library are marked Finished") },
    { category = "Progress", token = "%books_started",    description = _("How many books have any reading time recorded (statistics)") },
    { category = "Time",     token = "%time_12h",         description = _("Time (12-hour)") },
    { category = "Time",     token = "%time_24h",         description = _("Time (24-hour)") },
    { category = "Time",     token = "%date",             description = _("Date (e.g. 4 May)") },
    { category = "Time",     token = "%date_long",        description = _("Date (e.g. 4 May 2026)") },
    { category = "Time",     token = "%date_numeric",     description = _("Date (numeric)") },
    { category = "Time",     token = "%weekday",          description = _("Weekday") },
    { category = "Time",     token = "%weekday_short",    description = _("Weekday (short)") },
    { category = "Device",   token = "%batt",             description = _("Battery percentage") },
    { category = "Device",   token = "%batt_icon",        description = _("Battery icon (Nerd Font)") },
    { category = "Device",   token = "%wifi_icon",        description = _("Wi-Fi icon") },
    { category = "Device",   token = "[if:connected]%wifi_icon[/if]", description = _("Wi-Fi icon only when online") },
    { category = "Device",   token = "%nightmode",        description = _("Night mode icon (moon/sun)") },
    { category = "Device",   token = "%light",            description = _("Frontlight intensity (raw)") },
    { category = "Device",   token = "%light_pct",        description = _("Frontlight intensity (0–100%)") },
    { category = "Device",   token = "%light_icon",       description = _("Frontlight icon") },
    { category = "Device",   token = "%warmth",           description = _("Warmth value (natural-light only)") },
    { category = "Device",   token = "%mem",              description = _("System memory used (%)") },
    { category = "Device",   token = "%sysused",          description = _("System memory used (MiB)") },
    { category = "Device",   token = "%ram",              description = _("KOReader RSS (MiB)") },
    { category = "Device",   token = "%disk",             description = _("Storage free (GB)") },
    { category = "Logic",    token = "[if:foo]…[/if]",    description = _("Show … when token foo is set") },
    { category = "Logic",    token = "[if:not foo]…[/if]",description = _("Show … when foo is empty") },
    { category = "Logic",    token = "[if:foo>50]…[/if]", description = _("Numeric comparison") },
    { category = "Logic",    token = "[if:foo]…[else]…[/if]", description = _("If/else") },
    { category = "Logic",    token = "[if:lang=ja][font=NAME]…[/font][else]…[/if]", description = _("Per-language font: e.g. a Japanese face for ja books, another otherwise") },
    { category = "Logic",    token = "[if:full_width]…[/if]", description = _("Show … only in the full-width status line (micro-module + full-screen views), not the cover-view status") },
    { category = "Logic",    token = "%spacer",           description = _("Elastic gap: pushes content left/right to the region edges") },
    { category = "Progress", token = "%bar",              description = _("Progress bar, filling the rest of the line") },
    { category = "Progress", token = "%bar{rel}",         description = _("Progress bar whose length reflects how long the book is") },
    -- Style tags. The OPENER is what the picker inserts, because a tag with no
    -- closer simply runs to the end of the line -- which is the common case
    -- (a small series number after a %spacer needs no closer at all). The
    -- description names the closer for the reader who wants to end one early.
    --
    -- List lines only, so far: the hero takes [font=] for a whole region and
    -- ignores the rest.
    { category = "Style",    token = "[b]",               description = _("Bold from here on ([/b] ends it)") },
    { category = "Style",    token = "[i]",               description = _("Italic from here on ([/i] ends it)") },
    { category = "Style",    token = "[size=-4]",         description = _("Smaller from here on: 4pt below the line's own size ([/size] ends it)") },
    { category = "Style",    token = "[size=+4]",         description = _("Larger from here on; [size=12] sets an exact point size ([/size] ends it)") },
    { category = "Style",    token = "[font=NAME]",       description = _("A different font from here on: replace NAME with a font name ([/font] ends it)") },
}

local function metaToken(field)
    return function(book) return book and book[field] or "" end
end

-- Author display respects the user's "Author name formatting" setting
-- (Settings > Advanced > Author name formatting). "auto" leaves the
-- stored string alone; "first_last" / "last_first" force every author
-- into the same shape regardless of how each book stored the name.
local _AuthorName
local function _formatAuthor(raw)
    if type(raw) ~= "string" or raw == "" then return raw or "" end
    local ok_s, BookshelfSettings = pcall(require, "lib/bookshelf_settings_store")
    if not ok_s or not BookshelfSettings then return raw end
    local mode = BookshelfSettings.read("author_format") or "auto"
    if mode == "auto" then return raw end
    if not _AuthorName then
        local ok_a, m = pcall(require, "lib/bookshelf_author_name")
        if ok_a then _AuthorName = m end
    end
    if _AuthorName and _AuthorName.formatted then
        return _AuthorName.formatted(raw, mode)
    end
    return raw
end

Tokens.expanders.title       = metaToken("title")
Tokens.expanders.author      = function(book)
    return _formatAuthor(book and book.author or "")
end
Tokens.expanders.author_2    = function(book)
    return _formatAuthor(book and book.authors and book.authors[2] or "")
end
Tokens.expanders.authors     = function(book)
    if not book or not book.authors then return "" end
    local out = {}
    for i, a in ipairs(book.authors) do out[i] = _formatAuthor(a) end
    return table.concat(out, ", ")
end
Tokens.expanders.author_3    = function(book)
    return _formatAuthor(book and book.authors and book.authors[3] or "")
end
-- Number of authors. Falls back to 1 when only book.author is set
-- (single-author light meta records have no .authors array).
Tokens.expanders.author_count = function(book)
    if not book then return "" end
    if book.authors and #book.authors > 0 then return tostring(#book.authors) end
    if book.author and book.author ~= "" then return "1" end
    return ""
end
-- Short list with et al. for 3+. Used for anthology covers where the
-- user wants "Asimov, Bradbury, et al." rather than a 10-author dump.
Tokens.expanders.authors_short = function(book)
    if not book then return "" end
    local list = book.authors
    if (not list or #list == 0) and book.author and book.author ~= "" then
        list = { book.author }
    end
    if not list or #list == 0 then return "" end
    if #list == 1 then return _formatAuthor(list[1]) end
    if #list == 2 then
        return _formatAuthor(list[1]) .. _(" and ") .. _formatAuthor(list[2])
    end
    return _formatAuthor(list[1]) .. ", "
        .. _formatAuthor(list[2]) .. _(", et al.")
end

-- Reading status, normalised to four canonical strings so
-- [if:status=finished]…[/if] etc. is reliable:
--   "unread"   — no DocSettings or status="new"
--   "reading"  — actively in progress
--   "on_hold"  — KOReader's "abandoned"
--   "finished" — KOReader's "complete"
Tokens.expanders.status = function(book)
    if not book then return "" end
    local s = book.status or book._status or book.read_status
    if s == "complete" then return "finished" end
    if s == "abandoned" then return "on_hold" end
    if s == "new" or s == nil or s == "" then return "unread" end
    return s
end

-- %status_label -> the same four states, as words a reader would recognise.
--
-- A SEPARATE token rather than capitalising %status, because %status's four
-- canonical strings are load-bearing: [if:status=finished] compares against
-- them, and they are the same in every language. Translating or title-casing
-- what that token returns would silently break every conditional written
-- against it, and would break it only for users not running in English --
-- which is the worst possible way for it to break.
--
-- So: %status is the value, %status_label is the display. A user who wants
-- "Reading" gets it without writing out four conditionals by hand, which is
-- what the list-view migration note said they would otherwise have to do.
local STATUS_LABELS = {
    unread   = function() return _("Unread")   end,
    reading  = function() return _("Reading")  end,
    on_hold  = function() return _("On hold")  end,
    finished = function() return _("Finished") end,
}
Tokens.expanders.status_label = function(book)
    local s = Tokens.expanders.status(book)
    local label = STATUS_LABELS[s]
    -- Unknown state: return the raw value rather than empty. A state this
    -- build has not heard of is still information, and blanking it would look
    -- like the token was broken.
    if not label then return s end
    return label()
end

-- Rating as a plain number (1-5), empty when unrated. The existing
-- %rating returns star glyphs; this one is the raw value for users who
-- want numeric comparisons in conditionals or a different display.
Tokens.expanders.rating_number = function(book)
    if not book or not book.rating then return "" end
    local r = tonumber(book.rating)
    if not r or r < 1 then return "" end
    return tostring(math.floor(r))
end

-- ── File facts: size and the two dates ─────────────────────────────────────
--
-- The three fields behind these (`size`, `date_added`, `last_opened`) are not
-- on the record the shelf renders -- BookInfoManager stores no file size, and
-- neither date has a memoised accessor. lib/bookshelf_token_record.lua resolves
-- all three on demand, one stat apiece, and only for a template that names one.
-- So these expanders read a field like every other expander does; whether the
-- field is there is the wrapper's problem, not theirs.
--
-- The two formatters are exported because the list view's column accessors
-- render exactly these values and must not disagree about how: two spellings of
-- a file size in one plugin is a difference the user reads as a bug.

-- Binary-prefix sizes, matching how KOReader reports file sizes elsewhere.
-- Returns nil (not "") for a non-size, so a caller can tell "no value" from
-- "zero bytes"; the expander below is what turns nil into the empty string.
function Tokens.formatFileSize(bytes)
    if type(bytes) ~= "number" or bytes < 0 then return nil end
    if bytes < 1024 then return string.format("%d B", bytes) end
    local kb = bytes / 1024
    if kb < 1024 then return string.format("%d KB", math.floor(kb + 0.5)) end
    return string.format("%.1f MB", kb / 1024)
end

-- ISO date from a unix epoch. A non-positive epoch is "no date" rather than
-- 1970: every field that reaches here (a file mtime, a ReadHistory time) uses
-- 0 for "unknown", and the OPDS feed parser stamps a literal
-- `modification = 0` on every catalogue record it builds.
function Tokens.formatDate(epoch)
    if type(epoch) ~= "number" or epoch <= 0 then return nil end
    return os.date("%Y-%m-%d", epoch)
end

Tokens.expanders.size   = function(b)
    return b and Tokens.formatFileSize(b.size) or ""
end
Tokens.expanders.added  = function(b)
    return b and Tokens.formatDate(b.date_added) or ""
end
Tokens.expanders.opened = function(b)
    return b and Tokens.formatDate(b.last_opened) or ""
end

Tokens.expanders.series      = metaToken("series")
Tokens.expanders.series_name = metaToken("series_name")
Tokens.expanders.series_num  = metaToken("series_num")
Tokens.expanders.filename    = metaToken("filename")
Tokens.expanders.lang        = metaToken("lang")
Tokens.expanders.format      = metaToken("format")
-- %rating -> N filled stars + (5-N) empty stars. Rating is stored
-- 1-5 (integer) in the DocSettings summary; book.rating is hydrated
-- by Repo.readProgress via buildBook. Returns empty for unrated /
-- nil so [if:rating]…[/if] can gate the display in the hero line.
-- %rating -> the user's own rating as N filled + (5-N) empty plain-Unicode
-- stars. User ratings stay in native KOReader integer format, kept separate
-- from the Hardcover half-star rendering (%hardcover_stars). Returns "" for
-- unrated/nil so [if:rating]…[/if] can gate the display.
Tokens.expanders.rating = function(book)
    if not book or not book.rating then return "" end
    local r = math.floor(tonumber(book.rating) or 0)
    if r < 1 then return "" end
    if r > 5 then r = 5 end
    local filled = "\xE2\x98\x85"  -- ★ U+2605
    local empty  = "\xE2\x98\x86"  -- ☆ U+2606
    return filled:rep(r) .. empty:rep(5 - r)
end

-- %favourite -> the favourite icon when this book is in the Favourites
-- collection, empty otherwise. Which icon is the user's `fav_icon` setting,
-- the same one the cover badge reads, so a book marked with a heart on a cover
-- is marked with a heart in a list.
--
-- Requested for list view -- "Show favourite icon not on the cover but as a
-- token (maybe before the title by default)" -- but deliberately not restricted
-- to it: a hero region can carry it too, and the token vocabulary is one
-- vocabulary.
--
-- Renders the GLYPH rather than a flag, matching %rating (stars, not a number)
-- and %batt_icon. Because the conditional grammar falls through to the
-- expanders, that one definition also gives [if:favourite]…[/if] for free, so a
-- template can put a separator round it without leaving a stray space on every
-- other book.
--
-- Membership goes straight to ReadCollection, exactly as the cover badge's does
-- (bookshelf_spine_widget.lua:1313-1329): book.in_favorites is only ever set by
-- Repo.getFavorites, so on every other fetch path -- which is every list page
-- that is not the Favourites chip -- the field is nil. The lookup is a hash hit
-- on an in-memory table keyed by filepath, so it costs nothing per row.
--
-- NOT gated on show_fav_badge. That setting governs the corner badge on covers;
-- a token the user typed into a line is the user asking for it here, and
-- silently rendering nothing would look like the token was broken.
--
-- Both spellings resolve. The plugin's user-facing copy says "Favourite"
-- almost everywhere while its data keys say "favorites", and a template that
-- silently renders nothing because of a spelling is a bad half-hour.
local _CoverProgress
local function favouriteGlyph(book)
    local fp = book and book.filepath
    if not fp then return "" end
    local rc_ok, rc = pcall(require, "readcollection")
    local in_fav = rc_ok and rc and rc.coll and rc.coll.favorites
                   and rc.coll.favorites[fp] ~= nil
    if not in_fav then return "" end
    if not _CoverProgress then
        local ok_cp, m = pcall(require, "lib/bookshelf_cover_progress")
        if not ok_cp then return "" end
        _CoverProgress = m
    end
    return _CoverProgress.favoriteIcon() == "star"
        and _CoverProgress.FAV_GLYPH_STAR
        or  _CoverProgress.FAV_GLYPH_HEART
end
Tokens.expanders.favourite = favouriteGlyph
Tokens.expanders.favorite  = favouriteGlyph

local HC_STAR       = "\xef\x80\x85" -- nf-fa-star            (U+F005)
local HC_HALF_STAR  = "\xef\x84\xa3" -- nf-fa-star_half_empty (U+F123)
local HC_EMPTY_STAR = "\xef\x80\x86" -- nf-fa-star_o          (U+F006)

Tokens.expanders.hardcover_rating = function(book)
    if not book or not book.hardcover_rating then return "" end
    local r = tonumber(book.hardcover_rating)
    if not r or r <= 0 then return "" end
    return string.format("%.1f", r):gsub("%.0$", "")
end

-- Build a five-glyph star row (full / half / empty) for a numeric rating
-- in 0-5. Used by the %hardcover_stars token (Hardcover ratings are
-- inherently fractional). Returns "" for a missing/zero rating so the token
-- can gate its display. User ratings do NOT use this -- they stay integer.
function Tokens.starString(rating)
    local r = tonumber(rating)
    if not r or r <= 0 then return "" end
    if r > 5 then r = 5 end
    local whole = math.floor(r)
    local out = {}
    for i = 1, 5 do
        if i <= whole then
            out[#out + 1] = HC_STAR
        elseif i == whole + 1 and r - whole >= 0.5 then
            out[#out + 1] = HC_HALF_STAR
        else
            out[#out + 1] = HC_EMPTY_STAR
        end
    end
    return table.concat(out)
end

Tokens.expanders.hardcover_stars = function(book)
    if not book then return "" end
    return Tokens.starString(book.hardcover_rating)
end

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

Tokens.cleanDescription = cleanDescription      -- exported for tests / ad-hoc use
Tokens.expanders.description = function(book)
    return book and cleanDescription(book.description) or ""
end

-- %quote / %quote_source: a RANDOM highlight from the CURRENTLY SELECTED book
-- (issue #174), so a hero / book-detail region can show one of your own
-- highlights in place of the description. Re-rolls each time the book is
-- selected (the widget bumps the per-book nonce); stable across repaints within
-- one selection. Empty when the book has no highlights or no file.
Tokens.expanders.quote = function(book)
    if not (book and book.filepath) then return "" end
    local ok, Quotes = pcall(require, "lib/bookshelf_quotes")
    if not ok then return "" end
    local q = Quotes.forBook(book.filepath)
    -- Curly-quoted so it reads as a quotation wherever it's dropped in (users
    -- editing a hero template can't easily type the smart quotes themselves).
    return (q and q.text) and ("\xE2\x80\x9C" .. q.text .. "\xE2\x80\x9D") or ""
end
Tokens.expanders.quote_source = function(book)
    if not (book and book.filepath) then return "" end
    local ok, Quotes = pcall(require, "lib/bookshelf_quotes")
    if not ok then return "" end
    local q = Quotes.forBook(book.filepath)
    if not q then return "" end
    local attribution = q.title or ""
    if q.author and q.author ~= "" then
        attribution = attribution ~= "" and (attribution .. ", " .. q.author) or q.author
    end
    return attribution
end

-- HTML escape for text we inject into the reviews-modal markup (book title,
-- reviewer names, meta). Order matters: & first so we don't double-escape.
local function _escHtml(s)
    return (tostring(s or "")
        :gsub("&", "&amp;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;"))
end

-- Tags we allow through from a Hardcover review body into the MuPDF HTML
-- renderer. Everything else is dropped (tags only -- inner text is kept),
-- and ALL attributes are stripped, so no styles / scripts / event handlers
-- survive. script/style blocks are removed wholesale (tag + content).
local REVIEW_ALLOWED_TAGS = {
    p = true, br = true, em = true, i = true, strong = true, b = true,
    ul = true, ol = true, li = true, blockquote = true,
}

-- sanitiseReviewHtml(raw): return a safe HTML fragment for the reviews modal.
-- Keeps whitelisted tags (attribute-stripped, lower-cased, br normalised to
-- <br>), drops every other tag while preserving its inner text, and removes
-- <script>/<style> blocks entirely. Returns "" for nil/empty.
function Tokens.sanitiseReviewHtml(raw)
    if type(raw) ~= "string" or raw == "" then return "" end
    local s = raw
    s = s:gsub("<%s*[sS][cC][rR][iI][pP][tT].-<%s*/%s*[sS][cC][rR][iI][pP][tT]%s*>", "")
    s = s:gsub("<%s*[sS][tT][yY][lL][eE].-<%s*/%s*[sS][tT][yY][lL][eE]%s*>", "")
    s = s:gsub("<(/?)%s*([%a][%w]*)[^>]*>", function(slash, name)
        name = name:lower()
        -- Normalise every break form (<br>, <br/>, and the malformed </br>
        -- some reviews emit) to a plain <br> so the collapse logic below
        -- catches them all.
        if name == "br" then return "<br>" end
        if REVIEW_ALLOWED_TAGS[name] then
            return "<" .. slash .. name .. ">"
        end
        return ""
    end)
    -- KOReader renders every <br> as a blank line, so a <br> padding against a
    -- paragraph boundary doubles the gap. Reviewers commonly emit
    -- "</blockquote><p><br>attribution", which lands an extra blank line
    -- between the quote and its attribution. Drop <br> at the start/end of a
    -- paragraph (real mid-text breaks, e.g. after the attribution, are kept).
    local prev
    repeat
        prev = s
        -- Collapse stacked breaks (reviewers pad with multiple <br> for
        -- spacing, which KOReader renders as one blank line each -> a big
        -- mid-review gap) down to a single break, and drop breaks hugging a
        -- paragraph edge.
        s = s:gsub("<br>%s*<br>", "<br>")
        s = s:gsub("<p>%s*<br>%s*", "<p>")
        s = s:gsub("%s*<br>%s*</p>", "</p>")
    until s == prev
    -- Drop a break hugging any block boundary -- the block already supplies
    -- its own vertical spacing, so the <br> just adds an empty line.
    s = s:gsub("</p>%s*<br>%s*", "</p>")
    s = s:gsub("</blockquote>%s*<br>%s*", "</blockquote>")
    s = s:gsub("</li>%s*<br>%s*", "</li>")
    s = s:gsub("%s*<br>%s*<p>", "<p>")
    s = s:gsub("%s*<br>%s*<blockquote>", "<blockquote>")
    -- Leading / trailing breaks on the whole fragment.
    s = s:gsub("^%s*<br>%s*", "")
    s = s:gsub("%s*<br>%s*$", "")
    -- ── A <br> must not be left inside a <p> (issue #338) ──────────────────
    --
    -- KOReader's HtmlBoxWidget works around a MuPDF bug (a <br> renders as a
    -- break PLUS a blank line) by rewriting every <br> to "&nbsp;<div></div>"
    -- (htmlboxwidget.lua:241). That is only legal OUTSIDE a paragraph: HTML5
    -- parsing closes a <p> at a <div>, so for "<p>a<br>b<br>c</p>" the first
    -- injected div ends the paragraph -- line a gets a full paragraph margin
    -- -- while the rest land outside it, where the trick works. The reported
    -- symptom, exactly: "an extra line break for the first time the <br>
    -- appears", and only the first.
    --
    -- So a paragraph that contains a break becomes a <div class="p"> -- a div
    -- nests inside a div, so the workaround stays intact -- and the modal's
    -- stylesheet gives div.p the same margins as p. Inline spans crossing the
    -- breaks are untouched, since nothing is split.
    s = s:gsub("<p>(.-)</p>", function(chunk)
        if chunk:find("<br>", 1, true) then
            return '<div class="p">' .. chunk .. "</div>"
        end
        return nil   -- keep the original <p> exactly
    end)
    return s
end

-- reviewsHtml(payload): build the HTML body for the Hardcover reviews modal.
-- payload = { title, reviews = {...} }. The overall rating/counts/Refresh
-- summary is a separate native widget row (bookshelf_widget.lua), not part of
-- this HTML. The book title is a bold header; each review gets a bold "Review by" line
-- with the reviewer name in italics plus rating/date/likes meta, then the
-- sanitised review body. Stars use the plain Unicode star (U+2605) so they
-- render in the MuPDF HTML engine's normal font (the Nerd Font PUA glyphs
-- used elsewhere are not guaranteed in that renderer).
-- Region-aware review date. KOReader has no free-form date-format preference,
-- but datetime.secondsToDate(secs, true) returns the localised "Tue Apr 02
-- 2026" form (day/month names translated for the active UI language). Falls
-- back to the ISO date when datetime is unavailable (pure-Lua tests) or the
-- timestamp can't be parsed. Input is Hardcover's ISO "2026-04-02T00:00:00".
local function _formatReviewDate(ts)
    if type(ts) ~= "string" or ts == "" then return nil end
    local ok_dt, datetime = pcall(require, "datetime")
    if ok_dt and type(datetime) == "table"
            and datetime.stringToSeconds and datetime.secondsToDate then
        local ok_s, secs = pcall(datetime.stringToSeconds, (ts:gsub("T", " ")))
        if ok_s and tonumber(secs) and tonumber(secs) > 0 then
            local ok_f, formatted = pcall(datetime.secondsToDate, secs, true)
            if ok_f and type(formatted) == "string" and formatted ~= "" then
                return formatted
            end
        end
    end
    return ts:sub(1, 10)
end

function Tokens.reviewsHtml(payload)
    payload = type(payload) == "table" and payload or {}
    local out = {}
    -- Book title: a large heading above all reviews. Omitted when no title is
    -- given (the book-detail popup shows the title in its header already, so a
    -- heading here would be redundant).
    if payload.title and payload.title ~= "" then
        out[#out + 1] = "<h1>" .. _escHtml(payload.title) .. "</h1>"
    end

    -- The overall rating/counts/Refresh summary line now renders as native
    -- widgets above this HTML (bookshelf_widget.lua's ReviewsHeader) instead
    -- of here: an HTML <a> link had no tap feedback and couldn't easily match
    -- the surrounding text's own (zoom-adjustable) font size. Per-review star
    -- rows below still use the HTML star glyphs (Tokens.starString).
    local reviews = type(payload.reviews) == "table" and payload.reviews or {}
    if #reviews == 0 then
        out[#out + 1] = "<p>No non-spoiler reviews found.</p>"
        return table.concat(out, "\n")
    end

    for _i, review in ipairs(reviews) do
        local name = review.user_name or review.username or "Unknown reader"
        local rr = tonumber(review.rating)
        -- No leading rule above the FIRST review: the native header now ends
        -- in its own hairline (bookshelf_widget.lua's _buildReviewsTab), so a
        -- second rule right below it read as a redundant double line.
        if _i > 1 then out[#out + 1] = "<hr/>" end
        -- Stars on their own line above each review, so they always sit at the
        -- same left-aligned position regardless of name/date length.
        if rr and rr > 0 then
            out[#out + 1] = '<p class="stars">' .. Tokens.starString(rr) .. "</p>"
        end
        local byline = { "<b>Review by</b> <i>" .. _escHtml(name) .. "</i>" }
        local d = _formatReviewDate(review.reviewed_at)
        if d then byline[#byline + 1] = "<i>" .. _escHtml(d) .. "</i>" end
        if tonumber(review.likes_count) and tonumber(review.likes_count) > 0 then
            byline[#byline + 1] = string.format("%d likes", tonumber(review.likes_count))
        end
        out[#out + 1] = '<p class="byline">' .. table.concat(byline, " \xC2\xB7 ") .. "</p>"
        local body = Tokens.sanitiseReviewHtml(review.text or "")
        if body == "" then body = "<p>No review text.</p>" end
        out[#out + 1] = body
    end
    return table.concat(out, "\n")
end

-- autoLinkReportHtml(data): the HTML body for the post-scan auto-link report,
-- rendered in the shared reviews modal. Lists what got linked (so the user can
-- verify each match) and what didn't; the "no identifier" bucket is a count,
-- not hundreds of lines.
--   data = {
--     best_guess = bool,        -- which mode ran (affects wording)
--     cancelled  = bool,
--     linked  = { { name=, matched=, author=, score= }, ... },
--     nomatch = { { name= }, ... },   -- searched/had id but no confident hit
--     no_id   = N,              -- skipped, exact mode only
--     errors  = N,
--   }
function Tokens.autoLinkReportHtml(data)
    data = type(data) == "table" and data or {}
    local linked  = type(data.linked) == "table" and data.linked or {}
    local nomatch = type(data.nomatch) == "table" and data.nomatch or {}
    local DOT = " \xC2\xB7 "  -- " · "
    local ARROW = " \xE2\x86\x92 "  -- " → "
    local out = {}

    out[#out + 1] = "<h1>" .. (data.cancelled and "Auto-link report (cancelled)"
        or "Auto-link report") .. "</h1>"

    -- Summary line.
    local summary = { string.format("Linked %d", #linked) }
    summary[#summary + 1] = string.format("Not matched %d", #nomatch)
    if not data.best_guess and tonumber(data.no_id) and data.no_id > 0 then
        summary[#summary + 1] = string.format("No identifier %d", data.no_id)
    end
    if tonumber(data.errors) and data.errors > 0 then
        summary[#summary + 1] = string.format("Errors %d", data.errors)
    end
    out[#out + 1] = '<p class="rating">' .. table.concat(summary, DOT) .. "</p>"

    -- Linked: one line per book, local name -> matched Hardcover title/author.
    out[#out + 1] = "<hr/>"
    out[#out + 1] = string.format("<p><b>Linked (%d)</b></p>", #linked)
    if #linked == 0 then
        out[#out + 1] = "<p>Nothing linked.</p>"
    else
        local items = {}
        for _, e in ipairs(linked) do
            local line = "<b>" .. _escHtml(e.name or "?") .. "</b>" .. ARROW
                .. _escHtml(e.matched or "?")
            if e.author and e.author ~= "" then
                line = line .. " \xE2\x80\x94 " .. _escHtml(e.author)  -- em dash
            end
            if tonumber(e.score) then
                line = line .. DOT .. string.format("%d%%", e.score)
            end
            items[#items + 1] = "<li>" .. line .. "</li>"
        end
        out[#out + 1] = "<ul>" .. table.concat(items, "\n") .. "</ul>"
    end

    -- Not matched: candidates for Manual link.
    if #nomatch > 0 then
        out[#out + 1] = "<hr/>"
        out[#out + 1] = string.format(
            "<p><b>Not matched (%d)</b> -- try Manual link</p>", #nomatch)
        local items = {}
        for _, e in ipairs(nomatch) do
            items[#items + 1] = "<li>" .. _escHtml(e.name or "?") .. "</li>"
        end
        out[#out + 1] = "<ul>" .. table.concat(items, "\n") .. "</ul>"
    end

    -- No identifier: a single count line (exact mode only).
    if not data.best_guess and tonumber(data.no_id) and data.no_id > 0 then
        out[#out + 1] = "<hr/>"
        out[#out + 1] = string.format(
            "<p><b>No identifier (%d)</b><br/>Skipped -- no ISBN or Hardcover id embedded. Use Best guess or Manual link for these.</p>",
            data.no_id)
    end

    return table.concat(out, "\n")
end

local function pct(v) return string.format("%d%%", math.floor((v or 0) * 100 + 0.5)) end

-- %books_read: how many books in the WHOLE library are marked Finished.
-- A STATE token, exactly like %batt: the widget's device-state builder
-- supplies the count, because a token expander reaching into the repository
-- is the boundary bookshelf_token_record exists to protect (its suite pins
-- that this file never requires the repo). Empty wherever no state is
-- passed -- list rows, like every device token -- and the ask was the hero
-- status line, which passes it.
Tokens.expanders.books_read = function(_b, s)
    return (s and s.books_read) and tostring(s.books_read) or ""
end

-- %books_started: the statistics plugin's own number -- books with any
-- recorded reading time. The pair exists because "books read" means both
-- things to different people: Finished is a deliberate act (Reader Status),
-- started is what the stats database actually measures.
Tokens.expanders.books_started = function(_b, s)
    return (s and s.books_started) and tostring(s.books_started) or ""
end

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
-- os.date weekday/month names come from the C locale (English on Kindle),
-- bypassing gettext -- localize them to the active UI language.
local LocalDate = require("lib/bookshelf_localdate")

Tokens.expanders.time     = function(_b, s) return fmt("%H:%M", s) end
Tokens.expanders.time_24h = function(_b, s) return fmt("%H:%M", s) end
Tokens.expanders.time_12h = function(_b, s)
    local t = fmt("%I:%M %p", s)
    return (t:gsub("^0", ""))
end
Tokens.expanders.date          = function(_b, s) return LocalDate.localize(fmt("%d %b", s)):gsub("^0", "") end
Tokens.expanders.date_long     = function(_b, s) return LocalDate.localize(fmt("%d %B %Y", s)):gsub("^0", "") end
Tokens.expanders.date_numeric  = function(_b, s) return fmt("%d/%m/%Y", s) end
Tokens.expanders.weekday       = function(_b, s) return LocalDate.localize(fmt("%A", s)) end
Tokens.expanders.weekday_short = function(_b, s) return LocalDate.localize(fmt("%a", s)) end

local function minutesToHM(m)
    if not m or m <= 0 then return "" end
    local h = math.floor(m / 60); local mm = m % 60
    return string.format(_("%dh %02dm"), h, mm)
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
    if s < 60 then return string.format(_("%ds"), s) end
    return string.format(_("%dm %02ds"), math.floor(s / 60), s % 60)
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
-- Connection state for CONDITIONS (not a display glyph): "yes" only when Wi-Fi is
-- on AND linked, else empty. So `[if:connected]%wifi_icon[/if]` (or, matching
-- bookends, `[if:connected=yes]%wifi[/if]`) shows the Wi-Fi icon only when
-- actually online (issue #181). %wifi/%wifi_icon stay the glyph.
Tokens.expanders.connected = function(_b, s)
    return (s and s.connected == "yes") and "yes" or ""
end
-- "yes" when the status template is being rendered in a FULL-WIDTH context (the
-- micro-module hero view and the full-screen micro-module overlay), empty in
-- the narrow cover-view right column. Lets power users surface extra content
-- only where there's room, e.g. `%time_12h[if:full_width]  ·  %date[/if]`
-- (issue #178). Set on the state by HeroCard.buildStatusRow.
Tokens.expanders.full_width = function(_b, s)
    return (s and s.full_width) and "yes" or ""
end
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
Tokens.expanders.sysused = function(_b, s) return s and s.sysused_mib and (tostring(s.sysused_mib) .. " MiB") or "" end
Tokens.expanders.ram   = function(_b, s) return s and s.ram_mib and (tostring(s.ram_mib) .. " MiB") or "" end
Tokens.expanders.disk  = function(_b, s) return s and s.disk_free or "" end

-- %bar and %spacer are intentionally NOT in the expander table. The
-- hero card's elastic-line renderer (buildLine in hero_card.lua) detects
-- both tokens AFTER token expansion and splits the line into [before,
-- elastic-widget, after]. Adding an expander here would replace the
-- token with empty text before the renderer ever sees it. This mirrors
-- the bookends approach (which uses a placeholder character) but keeps
-- the literal token text the user typed:
--   %bar    -> progress bar widget, progress-region-only
--   %spacer -> elastic whitespace, available in any region

-- The two spelled once. Every renderer that detects them after expansion
-- matches these rather than restating the pattern -- the list row's findElastic
-- and its strippers, and mapOutsideElastic below. (The hero card still carries
-- its own copies; it predates this and matching them is all it does with them.)
--
-- BAR_MODIFIER_PATTERN is anchored, to be matched at the character AFTER a
-- %bar, and carries the capture the reader needs: `text:find(P, be + 1)`
-- returns start, stop, modifier.
Tokens.BAR_PATTERN          = "%%bar"
Tokens.SPACER_PATTERN       = "%%spacer"
Tokens.BAR_MODIFIER_PATTERN = "^{([%w_,]*)}"

-- ── Transforming a line's TEXT without touching its markup ─────────────────
--
-- Tokens.mapOutsideElastic(text, fn) -> fn applied to every run of text
-- BETWEEN the elastic tokens; %bar, %bar{mod} and %spacer pass through
-- verbatim.
--
-- One caller today, and it is a bug fix: a list line with UPPERCASE set ran
-- the whole expanded string through TextSegments.upper, which uppercased the
-- literal "%spacer" along with everything else. findElastic matches it
-- lowercase, so the token stopped being a token -- the line rendered
-- "THE HOBBIT%SPACER★★★★☆" as one left-aligned run, which is what
-- "the spacer does nothing there" looks like from the outside. %bar had the
-- same fault, and %bar{rel} a second one on top: the modifier is compared
-- lowercase, so an uppercased {REL} silently dropped the relative length.
--
-- The rule this encodes: a case transform belongs to what the reader typed and
-- to what the tokens EXPANDED to, never to a token's own spelling. The hero
-- does not have the bug because it uppercases each side AFTER splitting the
-- line (mkseg in bookshelf_hero_card.lua); the list pre-renders one string per
-- line, so it steps over the tokens instead.
-- Every span a text transform must step over, longest form of each first so a
-- tie on position picks %bar{rel} over the %bar inside it.
--
-- The style tags are here for the same reason the elastic tokens are: they are
-- matched by lowercase name, so "[SIZE=12]" is not a tag and renders as four
-- literal characters in the middle of the line.
local PROTECTED = {
    Tokens.BAR_PATTERN .. "{[%w_,]*}",
    Tokens.BAR_PATTERN,
    Tokens.SPACER_PATTERN,
    InlineStyle.TAG_SPAN_PATTERN,
}

function Tokens.mapOutsideElastic(text, fn)
    if type(text) ~= "string" or text == "" then return text end
    local out, pos = {}, 1
    while true do
        -- Earliest-first, NOT findElastic's ranking: that one hands %bar the
        -- slack wherever it sits, which is the right answer to a different
        -- question and would walk this string out of order.
        local s, e
        for _i, pattern in ipairs(PROTECTED) do
            local ps, pe = text:find(pattern, pos)
            -- On a tie the LONGER match wins, which is what keeps %bar{rel}
            -- whole: the bare %bar starts at the same character.
            if ps and (not s or ps < s or (ps == s and pe > e)) then
                s, e = ps, pe
            end
        end
        if not s then break end
        out[#out + 1] = fn(text:sub(pos, s - 1)) or ""
        out[#out + 1] = text:sub(s, e)
        pos = e + 1
    end
    if #out == 0 then return fn(text) or "" end
    out[#out + 1] = fn(text:sub(pos)) or ""
    return table.concat(out)
end

-- ─── Conditional evaluator ──────────────────────────────────────────────────
-- Recognises [if:cond]…[else]…[/if]. Cond grammar:
--   atom    := [not] (token | token op value)
--   value   := number | "double-quoted string"
--   op      := = | != | < | > | <= | >=
--   expr    := atom (and|or atom)*
-- Strings vs numbers: numeric tokens compare numerically; string tokens
-- compare by string equality. Missing tokens compare as empty/zero.

-- ── %calibre{field}: any calibre column by lookup name ─────────────────────
-- The braces carry an ARGUMENT, not a modifier like {x4}, so this cannot be
-- a plain expander (those are bare %names substituted by gsub). It gets its
-- own pass in Tokens.expand, and menuPreview runs that pass BEFORE its
-- modifier strip, which would otherwise eat the braces and strand a literal
-- "%calibre" in the preview. Field names match case-insensitively, with or
-- without calibre's leading '#' (a custom column "#year" answers both
-- %calibre{year} and %calibre{#Year}). Values come pre-rendered as strings
-- on book.calibre by the repository, only when the calibre beta is on.
local function calibreField(book, field)
    local map = book and book.calibre
    if type(map) ~= "table" then return "" end
    local key = tostring(field or ""):gsub("^%s*#?", ""):gsub("%s*$", ""):lower()
    return map[key] or ""
end

function Tokens.expandCalibreBraces(text, book)
    -- Plain find: the pattern-free form, so the '%' is literal.
    if not text:find("%calibre{", 1, true) then return text end
    return (text:gsub("%%calibre{([^}]*)}", function(field)
        return calibreField(book, field)
    end))
end

local function valueForCondition(name, book, state)
    -- Single source of truth for if-condition values. Falls through to
    -- expanders so e.g. "book_pct" in a condition matches %book_pct token.
    local calibre_arg = name:match("^calibre{(.-)}$")
    if calibre_arg then
        local v = calibreField(book, calibre_arg)
        if v == "" then return nil end
        return v
    end
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
    local v = valueForCondition(body:match("^%s*(calibre%b{})")
                                or body:match("^%s*([%w_]+)") or "", book, state)
    -- token op value form
    local name, op, raw = body:match('^%s*(calibre%b{})%s*([=<>!]+)%s*(.+)%s*$')
    if not name then
        name, op, raw = body:match('^%s*([%w_]+)%s*([=<>!]+)%s*(.+)%s*$')
    end
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
-- Token names + ordering are fixed at module load (no expanders are added
-- after this file finishes loading), so memoise the sorted list once.
-- Tokens.expand previously rebuilt and re-sorted this every call —
-- ~6 calls per hero build × 30 tokens worth of allocation + sort.
local function compareLengthDesc(a, b) return #a > #b end
local _token_names_cache

local function tokenNamesByLengthDesc()
    if _token_names_cache then return _token_names_cache end
    local names = {}
    for k in pairs(Tokens.expanders) do names[#names + 1] = k end
    table.sort(names, compareLengthDesc)
    _token_names_cache = names
    return names
end

local function expandDatetimeBraces(format, state)
    return (format:gsub("%%datetime{(.-)}", function(spec)
        return os.date(spec, timeNow(state))
    end))
end

function Tokens.expand(format, book, state)
    if not format or format == "" then return "" end
    -- Plain-text templates (no %tokens, no [tags], no {datetime}) are
    -- common enough — region defaults, user-typed labels — that a
    -- single :find pays off vs the full conditional + datetime + 30-
    -- token gsub pipeline below. Cheap (~0.5µs) when there ARE tokens.
    if not format:find("[%%[{]") then return format end
    local result = expandDatetimeBraces(format, state)
    result = expandConditionals(result, book, state)
    result = Tokens.expandCalibreBraces(result, book)
    local names = tokenNamesByLengthDesc()
    for _i, name in ipairs(names) do
        local expander = Tokens.expanders[name]
        result = result:gsub("%%" .. name, function()
            return tostring(expander(book, state) or "")
        end)
    end
    return result
end

-- ── How a template reads in a MENU ROW ─────────────────────────────────────
--
-- Tokens.menuPreview(template, book, state) -> a one-line summary.
--
-- Every "Line 2: Tolkien  0% of 310 pages" row and every hero region row shows
-- the template EXPANDED, so the reader sees what the line will say rather than
-- what they typed. Three token families do not survive that trip and have to be
-- handled here instead of leaking into the label:
--
--   %bar        is a WIDGET. It is not text and has no expander, so it arrives
--               at the label as the literal characters "%bar". Bookends shows
--               it as a little bar of geometric shapes and so does this: plain
--               Unicode (U+25B0 / U+25B1), NOT a Private Use Area glyph, so it
--               renders in a menu's ordinary face with no symbols font.
--   {rel}, {xN} are MODIFIERS on those widgets, meaningless as text.
--   %spacer     is an elastic GAP the renderer splits the line on. In a menu
--               row there is nothing to split, so it read as the literal word
--               "%spacer" sitting in the middle of the preview.
--
-- Shared rather than copied: this was three near-identical gsub chains (the
-- list line rows, the hero region rows, the hero line editor), each stripping a
-- different subset -- which is exactly why %spacer survived in two of them.
Tokens.BAR_PREVIEW = "\xE2\x96\xB0\xE2\x96\xB0\xE2\x96\xB1\xE2\x96\xB1"  -- ▰▰▱▱

function Tokens.menuPreview(format, book, state)
    -- Modifiers come off BEFORE expansion, and that order is the whole trick:
    -- %description IS a real token, so expanding first substitutes the blurb
    -- and leaves a literal "{x4}" stranded in the middle of the preview.
    local src = Tokens.expandCalibreBraces(format or "", book)
    src = src:gsub("(%%[%a_]+){[%w_,]*}", "%1")
    local ok, text = pcall(Tokens.expand, src, book, state)
    if not ok or not text then return "" end
    -- The style tags. Most of them ARE rendered now -- a list line turns them
    -- into runs -- but they are markup either way, and a preview that shows
    -- the markup is showing the one thing the reader will not see. One strip
    -- for the whole vocabulary, so a tag added later cannot leak into a menu
    -- row by being forgotten here.
    text = InlineStyle.strip(text)
    -- The two widget-shaped tokens, which have no expanders and so arrive here
    -- as their own literal text.
    text = text:gsub("%%bar", Tokens.BAR_PREVIEW)
    text = text:gsub("%%spacer", " ")
    text = text:gsub("%s+", " ")
    return (text:match("^%s*(.-)%s*$")) or ""
end

function Tokens.isEmpty(s)
    if not s then return true end
    -- Strip the style tags before deciding emptiness, or "[b][/b]" around a
    -- value that resolved to nothing counts as content. One strip for the
    -- whole vocabulary rather than a list to keep in step: the note that used
    -- to sit here -- "new format tags added in future versions need to be
    -- added here" -- is exactly the maintenance this avoids.
    return InlineStyle.strip(s):match("^%s*$") ~= nil
end

return Tokens
