-- bookshelf_cover_label.lua
-- The "Custom" choice for the line of text under each cover: a token template
-- the reader writes, expanded per book.
--
-- One global setting, like the Title / Author / Series choice it sits beside
-- (Cover display > Show text below covers). The MODE stays where it always was
-- (expanded_shelf_label = "custom"); the template lives under its own key, so
-- switching back to Title keeps it for next time.
--
-- ── What a label can and cannot be ─────────────────────────────────────────
--
-- One line, in the strip's own face and size (Text size > Cover labels), drawn
-- by a single TextWidget that truncates with an ellipsis. So the template is
-- reduced to plain words before it reaches the strip:
--
--   * the inline style tags ([b], [size=], [font=]...) come out: one TextWidget
--     is one style;
--   * %bar comes out, and %spacer becomes a space: both are widgets that split
--     a line, and a centred label has nothing to split;
--   * newlines and runs of whitespace collapse to one space.
--
-- The editor hides the controls and the picker tokens that would only be
-- ignored here (see lib/bookshelf_cover_label_editor.lua and offersToken).
--
-- ── Why the expansion is cached ────────────────────────────────────────────
--
-- A row is rebuilt on every page turn, every refresh and every preview, and a
-- label used to be a field read. Tokens.expand is not: it walks the token
-- names, resolves sidecar fields through TokenRecord, and runs the conditional
-- evaluator. So each book's text is kept, keyed by everything it was expanded
-- from:
--
--   context   the template and case setting, the repository's data generation
--             (bumped by every progress / metadata / stats / library
--             invalidation, which is when a resolved field can change), the
--             author name format setting, and -- only for a template that
--             names a clock or a library-wide counter -- the current minute;
--   per book  the file path plus the record's own title / author / series /
--             page count, because those arrive late on a book BIM is still
--             extracting, with no invalidation to announce them.
--
-- A changed context drops the whole cache rather than adding to it, so it
-- holds one template's worth of books and cannot grow with edits. It is also
-- capped, for a long session paging a big library.
--
-- No device state is passed to Tokens.expand, as on a list row: a cover label
-- is not a status line, and the device tokens answer empty without it.

local CoverLabel = {}

CoverLabel.MODE_SETTING     = "expanded_shelf_label"
CoverLabel.LINE_SETTING     = "expanded_shelf_label_custom"
CoverLabel.DEFAULT_TEMPLATE = "%title"

-- Longer than any slot can show at the smallest label size, short enough that
-- a %description template does not hand the shaper a whole blurb per cover.
CoverLabel.MAX_BYTES = 300

-- Above this many books the cache starts again. A page is a dozen covers, so
-- this is dozens of pages of paging back and forth.
CoverLabel.CACHE_LIMIT = 600

local function store()
    return require("lib/bookshelf_settings_store")
end

-- ── The stored line ────────────────────────────────────────────────────────

-- defaultLine() -> what Custom starts from, and what the editor's Default
-- restores: today's Title label, so choosing Custom changes nothing until the
-- reader edits it.
function CoverLabel.defaultLine()
    return { template = CoverLabel.DEFAULT_TEMPLATE }
end

-- normalise(v, default_template) -> { template, bold, uppercase }, a fresh
-- table. `default_template` is the books' %title unless given (the groups'
-- line passes its own).
--
-- Only the fields a label honours are carried. The shared editor copies every
-- field of the line it is given into its draft, and the draft is what Save
-- writes back, so anything else stored here would ride along forever.
function CoverLabel.normalise(v, default_template)
    default_template = default_template or CoverLabel.DEFAULT_TEMPLATE
    if type(v) == "string" then v = { template = v } end
    if type(v) ~= "table" then return { template = default_template } end
    local t = v.template
    if type(t) ~= "string" then t = default_template end
    return {
        template  = t,
        bold      = v.bold == true or nil,
        uppercase = v.uppercase == true or nil,
    }
end

-- line() -> the saved custom line (a copy), or the default when none is saved.
function CoverLabel.line()
    return CoverLabel.normalise(store().read(CoverLabel.LINE_SETTING))
end

-- save(line) -- the editor's Save: the template, and Custom as the mode.
-- Flushed here, at the end of the interaction, so a crash after Save does not
-- lose it (saveSetting alone is in-memory).
function CoverLabel.save(line)
    local S = store()
    S.save(CoverLabel.LINE_SETTING, CoverLabel.normalise(line))
    S.save(CoverLabel.MODE_SETTING, "custom")
    if S.flush then S.flush() end
end

-- ── Author below series (issue 486) ──────────────────────────────────────
--
-- Group tiles may print one more line: a series stack's author ("I can
-- imagine wanting title under covers and author under series groups").
-- Cover display > Show author below series, off by default. It is the only
-- group text there is: a series stack is the only group with an author of its
-- own (StackDisplay.groupLabel), and 5.4's Custom template for groups had
-- nothing else to say (the group's name is on the tile already; page count,
-- rating and series came out empty, and status read "unread" for every
-- group; maintainer, 2026-10-10). So Custom went, and a reader left on it
-- reads as on, which is all it ever showed. The stored key and its "author"
-- value are 5.4's, so a choice made then carries over.
CoverLabel.GROUP_MODE_SETTING = "group_label"

-- groupMode() -> "author", or nil when off.
function CoverLabel.groupMode()
    local v = store().read(CoverLabel.GROUP_MODE_SETTING)
    if v == "author" or v == "custom" then return "author" end
    return nil
end

-- saveGroupMode(on) -- true for on; 5.4's "author" / "none" strings too.
function CoverLabel.saveGroupMode(mode)
    local S = store()
    local on = mode == true or mode == "author"
    S.save(CoverLabel.GROUP_MODE_SETTING, on and "author" or "none")
    if S.flush then S.flush() end
end

-- ── Per shelf ──────────────────────────────────────────────────────────────
--
-- Each shelf may choose its own text below covers (Shelf style; Reddit,
-- after 5.4: "I only want the series name in a shelf that lists my
-- series"). The Cover display setting above stays the default every shelf
-- without its own wears. Stored on the shelf's tab, mode and line apart as
-- the globals are, so switching a shelf off Custom keeps its template:
--
--   cover_text       "title" / "author" / "series" / "custom" / "none"
--   cover_text_line  its Custom line
--
-- Unset is "follow": a sub-shelf with no choice of its own wears its shelf
-- of shelves' (and so on up), then the default, as a theme does
-- (bookshelf_theme_pack inherited). Mode and line come from the SAME shelf,
-- so a sub-shelf following a Custom parent shows the parent's template.
--
-- Text below GROUPS stays library-wide: the only group text with anything to
-- print is a series stack's author, which only a Series shelf has.

local function tabFor(id)
    if id == nil then return nil end
    if CoverLabel._tab then return CoverLabel._tab(id) end
    local ok, TabModel = pcall(require, "lib/bookshelf_tab_model")
    if not ok or not TabModel or not TabModel.getById then return nil end
    local ok2, tab = pcall(TabModel.getById, id)
    return ok2 and tab or nil
end

-- shelfWith(id, key) -> the first shelf, walking up from `id` through its
-- shelves of shelves, that has `key` set; nil when none has.
local function shelfWith(id, key)
    local seen = {}
    for _i = 1, 32 do
        if id == nil or seen[id] then return nil end
        seen[id] = true
        local tab = tabFor(id)
        if not tab then return nil end
        if tab[key] ~= nil then return tab end
        id = tab.parent
    end
    return nil
end

-- modeFor(id) -> the books' mode as stored for that shelf, its own or the
-- one it follows, else the Cover display setting (nil when that is unset;
-- the callers read nil as Title, as they always have).
function CoverLabel.modeFor(id)
    local tab = shelfWith(id, "cover_text")
    if tab then return tab.cover_text end
    return store().read(CoverLabel.MODE_SETTING)
end

-- lineFor(id) -> the books' Custom line that shelf shows.
function CoverLabel.lineFor(id)
    local tab = shelfWith(id, "cover_text")
    if tab and tab.cover_text == "custom" then
        return CoverLabel.normalise(tab.cover_text_line)
    end
    return CoverLabel.line()
end

-- ── Rendering one label ────────────────────────────────────────────────────

-- Back off to the start of a UTF-8 sequence, so a cut never splits a glyph.
local function utf8Cut(s, max)
    if #s <= max then return s end
    local i = max + 1
    while i > 1 do
        local b = s:byte(i)
        if not b or b < 0x80 or b >= 0xC0 then break end
        i = i - 1
    end
    return s:sub(1, i - 1)
end
CoverLabel.utf8Cut = utf8Cut

-- render(line, record) -> the label text for one book: never nil, "" when the
-- template expands to nothing.
--
-- Tokens.menuPreview is the reduction a label needs already -- calibre braces,
-- {modifiers} off before expansion, style tags stripped, %spacer to a space,
-- whitespace collapsed and trimmed -- with ONE difference: it draws %bar as a
-- little bar of blocks, which in a menu row says "a bar goes here" and under a
-- cover would read as a progress bar that never moves. So the bar goes.
function CoverLabel.render(line, record)
    local Tokens = require("lib/bookshelf_tokens")
    local template = line and line.template or CoverLabel.DEFAULT_TEMPLATE
    local text = Tokens.menuPreview(template, record, nil) or ""
    if text:find(Tokens.BAR_PREVIEW, 1, true) then
        text = text:gsub(Tokens.BAR_PREVIEW, " "):gsub("%s+", " ")
        text = text:match("^%s*(.-)%s*$") or ""
    end
    if text == "" then return "" end
    text = utf8Cut(text, CoverLabel.MAX_BYTES)
    if line and line.uppercase then
        local ok, Segments = pcall(require, "lib/bookshelf_text_segments")
        if ok and Segments and Segments.upper then
            local ok_u, up = pcall(Segments.upper, text)
            if ok_u and type(up) == "string" then text = up end
        end
    end
    return text
end

-- ── The cache ──────────────────────────────────────────────────────────────

-- Token names whose value moves with the clock or with the whole library
-- rather than with this book. A template naming one is keyed to the minute;
-- every other template is keyed to the data generation alone. Matched as
-- substrings of the template, so "%time" also catches %time_12h and
-- %time_today: over-matching only costs a re-expansion a minute.
CoverLabel.CLOCK_TOKENS = {
    "%time", "%date", "%weekday", "%datetime",
    "%books_read", "%books_started", "%books_finished",
    "%total_read_time", "%pages_today",
    "%highlights", "%notes", "%bookmarks", "%annotations",
    "%quote",
}

-- Matched on the bare name, so the delimited %<time_12h> and a condition such
-- as [if:books_read>10] count too. A literal word that happens to contain one
-- ("Sometimes") over-matches, which costs a re-expansion a minute and nothing
-- else.
local function namesClock(template)
    for _i, name in ipairs(CoverLabel.CLOCK_TOKENS) do
        if template:find(name:sub(2), 1, true) then return true end
    end
    return false
end
CoverLabel.namesClock = namesClock

local function repo()
    local ok, R = pcall(require, "lib/bookshelf_book_repository")
    if ok and type(R) == "table" then return R end
    return nil
end

-- context(line, now) -> the string every cached label must have been expanded
-- under. See the header for what goes in and why.
function CoverLabel.context(line, now)
    line = CoverLabel.normalise(line)
    local R = repo()
    local gen = R and R.dataGeneration and R.dataGeneration() or 0
    local fmt = store().read("author_format") or "auto"
    local minute = 0
    if namesClock(line.template) then
        minute = math.floor((now or os.time()) / 60)
    end
    return table.concat({ line.template, line.uppercase and "U" or "-",
                          tostring(gen), tostring(fmt), tostring(minute) }, "\1")
end

-- bookKey(item) -> the per-book half of the key, or nil for a record with no
-- file behind it (those are expanded every time; there is nothing stable to
-- key them by).
function CoverLabel.bookKey(item)
    if type(item) ~= "table" then return nil end
    local fp = item.filepath
    if type(fp) ~= "string" or fp == "" then return nil end
    return table.concat({ fp, tostring(item.title), tostring(item.author),
                          tostring(item.series), tostring(item.series_num),
                          tostring(item.page_count) }, "\1")
end

local _cache, _cache_ctx, _cache_n = {}, nil, 0
local _stats = { hits = 0, misses = 0 }

function CoverLabel.forget()
    _cache, _cache_ctx, _cache_n = {}, nil, 0
end

-- takeStats() -> { hits, misses } since the last call, then resets. For the
-- [bookshelf perf] line ShelfRow logs per row.
function CoverLabel.takeStats()
    local s = { hits = _stats.hits, misses = _stats.misses }
    _stats.hits, _stats.misses = 0, 0
    return s
end

-- resolver(line) -> function(item) -> label text.
--
-- The context is worked out ONCE per call here (a settings read and a
-- generation read), so a row asks it once and not once per cover.
function CoverLabel.resolver(line, now)
    line = CoverLabel.normalise(line)
    local ctx = CoverLabel.context(line, now)
    if ctx ~= _cache_ctx then
        _cache, _cache_ctx, _cache_n = {}, ctx, 0
    end
    local wrap
    return function(item)
        local key = CoverLabel.bookKey(item)
        if key then
            local hit = _cache[key]
            if hit then
                _stats.hits = _stats.hits + 1
                return hit
            end
        end
        _stats.misses = _stats.misses + 1
        if wrap == nil then
            local ok, TR = pcall(require, "lib/bookshelf_token_record")
            wrap = (ok and TR and TR.wrap) or false
        end
        local record = wrap and wrap(item) or item
        local ok, text = pcall(CoverLabel.render, line, record)
        if not ok or type(text) ~= "string" then text = "" end
        if key then
            if _cache_n >= CoverLabel.CACHE_LIMIT then
                _cache, _cache_n = {}, 0
            end
            _cache[key] = text
            _cache_n = _cache_n + 1
        end
        return text
    end
end

-- ── The token picker ───────────────────────────────────────────────────────

-- offersToken(entry) -> false for a Tokens.CATALOGUE entry a cover label can
-- only ignore: the style tags (one TextWidget, one style), %bar and %spacer
-- (line-splitting widgets), the per-language font example, and the Device
-- tokens (no device state reaches a label, so they always answer empty).
function CoverLabel.offersToken(entry)
    if type(entry) ~= "table" then return false end
    if entry.category == "Style" or entry.category == "Device" then return false end
    local tok = entry.token or ""
    if tok:find("%bar", 1, true) or tok:find("%spacer", 1, true)
            or tok:find("[font=", 1, true) then
        return false
    end
    return true
end

return CoverLabel
