--- status_line.lua
---
--- VENDORED FILE. Byte-identical copies live at:
---   bookends.koplugin/status_line.lua
---   bookshelf.koplugin/lib/status_line.lua
--- Never edit one without the other. tools/check_token_parity.sh fails on drift.
---
--- The definition of bookshelf's STATUS LINE: its default appearance and how a
--- stored override resolves against that default.
---
--- Bookends needs this to mirror the line (#348). The naive approach - read
--- G_reader_settings and render whatever is there - gets the common case
--- wrong, because bookshelf only WRITES that key once the user edits a region.
--- On a default install the key is absent or partial and bookshelf renders
--- from its defaults, so a mirror that ignored them would show nothing at all
--- for most users, or would drift field by field for the rest.
---
--- Pure data plus one pure function; no KOReader, no gettext.

local StatusLine = {}

--- Where bookshelf keeps the hero regions. A plain G_reader_settings key, NOT
--- bookshelf's own settings file, and deliberately so: it means bookends reads
--- it with no pcall(require) of a sibling plugin and no file paths, so the
--- interop cannot break when bookshelf refactors.
StatusLine.SETTINGS_KEY = "bookshelf_hero_regions"
StatusLine.REGION_KEY   = "status"

--- The status region's defaults. Must stay identical to what bookshelf renders
--- out of the box; that is the whole point of vendoring rather than copying.
StatusLine.DEFAULTS = {
    -- Whether the reader (bookends) should mirror this line. The setting lives
    -- HERE, in bookshelf's status region, rather than in bookends: this is
    -- bookshelf's line, edited in bookshelf, so the switch for "show it in the
    -- reader too" belongs beside the line itself rather than in a second
    -- plugin's settings. Bookends reads it and honours it; if bookends is not
    -- installed the flag simply does nothing.
    show_in_reader = false,
    template  = "\xef\x82\xa0 %disk[if:batt]  %batt_icon%batt[/if]"
             .. "[if:light]  %light_icon%light_pct[/if]  %wifi_icon  %time_12h",
    font_face = nil,
    font_size = 14,
    bold      = false,
    uppercase = false,
    alignment = "right",
}

--- Resolve a stored region table against the defaults, exactly as bookshelf's
--- hero_regions.resolveOne does: scalar fields override, anything else is
--- ignored, and a template that is not a string falls back rather than
--- rendering as garbage.
--- @param raw table|nil  the stored status entry, or nil when never edited
--- @return table         a resolved copy; never the shared defaults table
function StatusLine.resolve(raw)
    local out = {}
    for k, v in pairs(StatusLine.DEFAULTS) do out[k] = v end
    if type(raw) == "table" then
        for k, v in pairs(raw) do
            local vt = type(v)
            if vt == "string" or vt == "number" or vt == "boolean" then
                out[k] = v
            end
        end
        if type(raw.template) ~= "string" then
            out.template = StatusLine.DEFAULTS.template
        end
    end
    return out
end

--- Pull the status region straight out of a settings object, resolved.
--- `settings` is injected so this file needs no KOReader global; callers pass
--- G_reader_settings.
---
--- The second return means "the user has CUSTOMISED the status line", not
--- "bookshelf is installed" - there is no reliable signal for the latter,
--- since bookshelf writes this key only when a region is edited. It is for
--- wording a menu subtitle, never for deciding whether to render: the mirror
--- renders from the defaults either way, because that is what bookshelf itself
--- puts on screen when the key is absent.
--- @param settings table|nil  a G_reader_settings-shaped object
--- @return table resolved, boolean customised
function StatusLine.fromSettings(settings)
    local raw
    if settings and settings.readSetting then
        local ok, v = pcall(function()
            return settings:readSetting(StatusLine.SETTINGS_KEY)
        end)
        if ok and type(v) == "table" then raw = v[StatusLine.REGION_KEY] end
    end
    return StatusLine.resolve(raw), raw ~= nil
end

--- Where bookshelf publishes the library-wide numbers its status line can
--- reference. Bookends cannot COMPUTE these - counting finished books means
--- stat-ing every sidecar in the library, which is bookshelf's job and far too
--- expensive for a status-bar repaint - but the mirrored line must not show
--- "Books read: %books_read" raw, which is what happened before this existed.
---
--- So bookshelf publishes what it has already computed and bookends reads the
--- number. Slightly stale is exactly right here: the whole promise of the
--- mirror is that the line does not CHANGE between the shelf and a book, and a
--- number that matches what the shelf last showed keeps that promise better
--- than a live recount would.
StatusLine.STATS_KEY = "bookshelf_shared_stats"

--- The tokens bookends resolves from that published table rather than
--- computing. Keyed by token name, valued by the field bookshelf stores.
StatusLine.SHARED_STATS = {
    books_read              = "books_read",
    books_started           = "books_started",
    total_read_time_seconds = "total_read_time_seconds",
    pages_today             = "pages_today",
    time_today_minutes      = "time_today_minutes",
}

--- Read the published numbers, or an empty table.
function StatusLine.sharedStats(settings)
    if not (settings and settings.readSetting) then return {} end
    local ok, v = pcall(function()
        return settings:readSetting(StatusLine.STATS_KEY)
    end)
    return (ok and type(v) == "table") and v or {}
end

--- Bookshelf insets its content by this much on each side, and the mirrored
--- strip has to match or the two lines sit at visibly different x - measured
--- at 37px against bookends' own 18px margin on a 1248px screen, which is a
--- ~20px jump on each edge as the reader crosses between shelf and book.
---
--- The formula is bookshelf's own: the natural padding scales with DPI but is
--- capped at 3% of the width, so a high-DPI screen does not eat 240px of row
--- width and shrink every cover. `padding_fullscreen` is injected (KOReader's
--- Size.padding.fullscreen) so this file stays free of KOReader.
function StatusLine.sidePad(screen_w, padding_fullscreen)
    local natural = math.floor((tonumber(padding_fullscreen) or 0) * 2 * 0.8)
    local capped  = math.floor((tonumber(screen_w) or 0) * 0.03)
    if natural <= 0 then return capped end
    return math.min(natural, capped)
end

return StatusLine
