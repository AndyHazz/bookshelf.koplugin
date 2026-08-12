-- lib/bookshelf_opds_prefs.lua
-- Per-catalog OPDS tuning: the four settings that live on an OPDS chip, their
-- option lists, and the resolution of a chip's stored value into the number
-- the fetch path actually wants.
--
-- WHY PER CHIP (and not one global, and not per server). Bookshelf's OPDS
-- defaults are deliberately conservative because the catalogs most people
-- point it at are public ones: covers are fetched only when a book is tapped,
-- a fetched feed is reused until the user asks for a refresh, and the page
-- size follows the shelf. Those are the right defaults for Gutenberg or
-- Internet Archive and the wrong ones for a Calibre-Web box on your own LAN,
-- where round trips are cheap and the library changes under you. So every
-- setting here reads "unset = whatever the shelf does today", and a chip is
-- the unit of override: the chip is already where a catalog's download folder
-- lives (issue #319), and two chips on one server wanting different behaviour
-- (one browsing, one watching new arrivals) is a real case that a
-- server-keyed store would have to invent a tie-break for.
--
-- Nothing here reads or writes settings. A chip's fields are persisted with
-- the rest of the chip by TabModel.save (which stores the whole tab table, so
-- these need no schema registration), and this module only ever maps a stored
-- field to a value. That keeps it a pure function table and testable without
-- a KOReader tree.
--
-- Every stored value is the RAW value, never an index into the option list:
-- reordering or inserting an option must not silently change what existing
-- chips do.
local _ = require("lib/bookshelf_i18n").gettext

local M = {}

-- Sentinel for "refresh every time this catalog is opened". Distinct from nil
-- (never expire on age) and it cannot be 0-as-falsy confusion in Lua, but it
-- IS 0, so every comparison against it must be `== 0` and never `not x`.
M.REFRESH_ALWAYS = 0

local HOUR, DAY = 3600, 86400

-- Refresh age: how stale a stored copy of a feed may be before opening the
-- catalog refetches it. nil is the default and means age alone never triggers
-- a refetch -- the swipe-down gesture stays the only refresh, which is what
-- every release up to now did.
--
-- The default's LABEL names that gesture on purpose. A cached feed that never
-- expires surprised the reporter of #321 badly enough to hand-edit a settings
-- file, having never found the swipe; the setting that explains the current
-- behaviour is also the best place to teach it.
M.REFRESH_OPTIONS = {
    { value = nil,               label_func = function() return _("Only when I swipe down") end },
    { value = HOUR,              label_func = function() return _("If it's over an hour old") end },
    { value = DAY,               label_func = function() return _("If it's over a day old") end },
    { value = DAY * 7,           label_func = function() return _("If it's over a week old") end },
    { value = M.REFRESH_ALWAYS,  label_func = function() return _("Every time I open it") end },
}

-- Cover loading. "tap" is the shipped behaviour: the shelf shows a title and
-- author card and a cover is downloaded only for the book the user taps. Bulk
-- cover downloads over a slow public catalog made paging feel broken, which is
-- why that is the default and why turning it off is opt-in per catalog.
--
-- DELIBERATELY NOT OFFERED: a "use the small thumbnail instead" variant. Which
-- URL a record's cover is has to be one answer shared by
-- bookshelf_opds_covers (cachePath, fetchMissing, the credential gate) AND the
-- repo, which calls cachePath while building records and knows nothing about
-- chips. A per-chip preference splits that agreement across two modules, and
-- when they disagree the symptom is a cover that downloads to one path and is
-- looked for at another - covers that silently never appear. Not worth it for
-- "slightly smaller downloads".
M.COVER_TAP  = "tap"
M.COVER_AUTO = "auto"

M.COVER_OPTIONS = {
    { value = nil,          label_func = function() return _("Load when I tap a book") end },
    { value = M.COVER_AUTO, label_func = function() return _("Load automatically") end },
}

-- Nav-tile resolution. Some catalogs present every BOOK as a one-book
-- subcatalog rather than as an entry you can download: ManyBooks' title lists
-- and Gutenberg's category lists both do. The shelf cannot know a folder holds
-- a single book without fetching it, so those tiles render as folders that
-- resolve when tapped - and once automatic covers are on, they render as a
-- real book cover wearing folder chrome, which reads as a bug.
--
-- Turning this on fetches each such tile's feed in the background so a
-- folder-of-one flattens into its book (the repo already does that flattening
-- once the child feed is cached; this only populates the cache).
--
-- Off by default, and the default matters more here than anywhere else in this
-- file: this is one feed fetch PER TILE, so a fifteen-tile page is fifteen
-- requests. An always-on, six-wide-parallel version of exactly this was built
-- and removed (1477764) because public catalogs throttled the burst and served
-- half-filled pages. It is back only as an opt-in, and paced one request per
-- tick rather than in a burst.
--
-- Honest about the limit: a tile holding two editions (Gutenberg's do) is a
-- real folder and stays one. This makes single-book folders into books; it
-- cannot make a two-item folder into a book.
M.RESOLVE_BOOKS = "books"

M.RESOLVE_OPTIONS = {
    { value = nil,             label_func = function() return _("Leave them as folders") end },
    { value = M.RESOLVE_BOOKS, label_func = function() return _("Show them as books") end },
}

-- How many records to ask a feed for in one go. nil follows the shelf's own
-- page size, which is what the fetch path has always used and which keeps the
-- first page appearing as fast as the layout allows. A bigger number is fewer
-- round trips and a longer wait for the first paint -- worth it on a LAN,
-- rarely worth it otherwise.
M.BATCH_OPTIONS = {
    { value = nil, label_func = function() return _("Match the shelf") end },
    { value = 50,  label_func = function() return "50" end },
    { value = 100, label_func = function() return "100" end },
    { value = 200, label_func = function() return "200" end },
}

-- Socket timeouts, as the (block, total) pair socketutil wants. The default
-- pair is KOReader's own LARGE_BLOCK/LARGE_TOTAL, which is what every feed
-- fetch has used to date and is tuned for public catalogs that stall.
--
-- The short pair is the one worth having: on a server on your own network a
-- 30-second wait for something that is simply not running reads as a hang,
-- and failing in 10 tells you the truth sooner.
M.TIMEOUT_DEFAULT = 30
local TIMEOUT_PAIRS = {
    [10] = { block = 5,  total = 10 },
    [30] = { block = 10, total = 30 },
    [60] = { block = 15, total = 60 },
}

M.TIMEOUT_OPTIONS = {
    { value = nil, label_func = function() return _("30 seconds") end },
    { value = 10,  label_func = function() return _("10 seconds") end },
    { value = 60,  label_func = function() return _("60 seconds") end },
}

-- A stored value is only honoured if it is one this build offers. A chip
-- written by a newer version (or hand-edited) falls back to the default
-- rather than reaching the fetch path as a nonsense number.
local function validated(options, value)
    for _i, opt in ipairs(options) do
        if opt.value == value then return value end
    end
    return nil
end

-- refreshAge(tab) -> seconds, or nil for "never expire on age".
-- Returns M.REFRESH_ALWAYS (0) for "every time", so callers MUST test with
-- `age == 0` before any truthiness check.
function M.refreshAge(tab)
    if type(tab) ~= "table" then return nil end
    local v = tab.opds_refresh_age
    if type(v) ~= "number" then return nil end
    return validated(M.REFRESH_OPTIONS, v)
end

-- isStale(tab, fetched_at, now) -> boolean. The single place the age rule
-- lives, so the caller never re-derives it.
--
-- A window that was never fetched (fetched_at 0 or nil) is NOT stale: it is
-- empty, and the fetch path already treats an empty window as needing a
-- fetch. Saying "stale" here too would turn one fetch into two.
function M.isStale(tab, fetched_at, now)
    local age = M.refreshAge(tab)
    if age == nil then return false end
    if type(fetched_at) ~= "number" or fetched_at <= 0 then return false end
    if age == M.REFRESH_ALWAYS then return true end
    if type(now) ~= "number" then return false end
    -- A fetched_at in the future (clock moved back, or a file copied from
    -- another device) reads as age 0, not as a huge negative age that would
    -- keep the window fresh forever.
    local elapsed = now - fetched_at
    if elapsed < 0 then return true end
    return elapsed >= age
end

-- coverMode(tab) -> M.COVER_TAP | M.COVER_AUTO | M.COVER_AUTO_THUMB
function M.coverMode(tab)
    if type(tab) ~= "table" then return M.COVER_TAP end
    local v = validated(M.COVER_OPTIONS, tab.opds_cover_mode)
    return v or M.COVER_TAP
end

-- autoCovers(tab) -> boolean. The question every call site on the render path
-- actually asks.
function M.autoCovers(tab)
    return M.coverMode(tab) == M.COVER_AUTO
end

-- resolveNav(tab) -> boolean. Should the background pass fetch nav tiles to
-- flatten single-book folders?
function M.resolveNav(tab)
    if type(tab) ~= "table" then return false end
    return validated(M.RESOLVE_OPTIONS, tab.opds_resolve_nav) == M.RESOLVE_BOOKS
end

-- batchSize(tab, view_size) -> number. view_size is the shelf's own page size
-- and is used as-is when the chip has no override, so an unset chip fetches
-- exactly what it fetched before this setting existed.
function M.batchSize(tab, view_size)
    local fallback = (type(view_size) == "number" and view_size > 0)
        and view_size or 24
    if type(tab) ~= "table" then return fallback end
    local v = validated(M.BATCH_OPTIONS, tab.opds_batch)
    if type(v) ~= "number" or v <= 0 then return fallback end
    return v
end

-- timeouts(tab) -> { block_timeout = n, total_timeout = n }
--
-- Keys match the net_opts shape bookshelf_opds_covers already passes to
-- CoverFetch.download and that OpdsFeed.fetch now accepts, so the result goes
-- straight to either without a translation step in between (a translation step
-- is where a block/total pair gets silently swapped).
--
-- Always a fresh table: handing out the shared pair would let one caller's
-- mutation retune every later request in the session.
function M.timeouts(tab)
    local secs = M.TIMEOUT_DEFAULT
    if type(tab) == "table" then
        local v = validated(M.TIMEOUT_OPTIONS, tab.opds_timeout)
        if type(v) == "number" then secs = v end
    end
    local pair = TIMEOUT_PAIRS[secs] or TIMEOUT_PAIRS[M.TIMEOUT_DEFAULT]
    return { block_timeout = pair.block, total_timeout = pair.total }
end

-- labelFor(options, value) -> the option list's label for a stored value, or
-- the default option's label when the value is not one we offer. Used by the
-- editor to render each row's current state.
function M.labelFor(options, value)
    for _i, opt in ipairs(options) do
        if opt.value == value then return opt.label_func() end
    end
    return options[1].label_func()
end

return M
