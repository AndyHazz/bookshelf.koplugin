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

-- Two sentinels, both of which must be compared with == and never tested for
-- truthiness: they ARE 0 and -1.
--
--   REFRESH_ALWAYS  refetch on every entry to the catalog
--   REFRESH_NEVER   never expire on age; the swipe-down gesture is the only
--                   refresh, which is what every release up to now did
M.REFRESH_ALWAYS = 0
M.REFRESH_NEVER  = -1

local MINUTE, HOUR, DAY = 60, 3600, 86400

-- SWIPE-DOWN ONLY by default, and the default is the point of this setting.
--
-- This was five minutes, chosen against #321: that reporter hand-edited a
-- settings file to get fresh content, never having found the swipe-down
-- gesture, and an age default meant nobody had to find it.
--
-- What changed is what a cached feed now IS. It used to be one batch, so
-- expiring it cost one request and the reader lost nothing they had built up.
-- A feed now accumulates as it is paged, and the last-page chevron will walk a
-- category to its end on request - hundreds of entries and a minute of
-- fetching. The age check refetches with replace, ONE batch: so walking a
-- category to page 78, going to make a cup of tea, and coming back put the
-- reader on page 1 of a single batch with all of that thrown away. Five
-- minutes is far shorter than the work it can now discard.
--
-- The staleness #321 complained about is also much cheaper to fix than it was:
-- swipe-down works from anywhere in a catalog, including inside a drilled
-- subcatalog, and it no longer empties the shelf when the network is
-- unreachable. Readers who never find it see a catalog that only changes when
-- they ask - which for a book catalog, unlike a news feed, is a defensible
-- thing to be. Anyone who wants the old behaviour sets it per catalog.
--
-- Where this is checked has not changed: on ENTERING a feed, inside the
-- user-initiated gate, so a passive rebuild still makes no network call.
--
-- Ordering: the default leads, because labelFor renders an unset chip with
-- OPTIONS[1] and the row would otherwise read as something the chip is not.
-- After that, ascending, with the always-refetch opt-in at the end.
M.REFRESH_DEFAULT = M.REFRESH_NEVER

M.REFRESH_OPTIONS = {
    { value = M.REFRESH_NEVER,   label_func = function() return _("Only when I swipe down") end },
    { value = 5 * MINUTE,        label_func = function() return _("If it's over 5 minutes old") end },
    { value = HOUR,              label_func = function() return _("If it's over an hour old") end },
    { value = DAY,               label_func = function() return _("If it's over a day old") end },
    { value = DAY * 7,           label_func = function() return _("If it's over a week old") end },
    { value = M.REFRESH_ALWAYS,  label_func = function() return _("Every time I open it") end },
}

-- Cover loading is no longer a choice: the shelf always fills covers.
--
-- It was opt-in because the original implementation downloaded a whole page
-- SERIALLY on the UI thread, and over a slow public catalog that made paging
-- feel broken. That implementation is gone -- fetches run in forked workers
-- off the UI thread, a landed cover repaints on a ramp, and a page turn
-- abandons the chain. The reason for the option went with it, and a covers
-- plugin whose covers are off by default is a bad joke.
--
-- DELIBERATELY NOT OFFERED: a "use the small thumbnail instead" variant. Which
-- URL a record's cover is has to be one answer shared by
-- bookshelf_opds_covers (cachePath, fetchMissing, the credential gate) AND the
-- repo, which calls cachePath while building records and knows nothing about
-- chips. A per-chip preference splits that agreement across two modules, and
-- when they disagree the symptom is a cover that downloads to one path and is
-- looked for at another - covers that silently never appear.

-- Nav-tile resolution is no longer a choice either: a subcatalog holding one
-- book is always shown as that book.
--
-- It was opt-in because it costs one feed fetch PER TILE, and a fifteen-tile
-- page was fifteen requests paced one per tick. Three things changed that
-- arithmetic: tiles that DECLARE more than one item are skipped without being
-- fetched (IA's category tiles say ~10000 apiece), the fetches run in parallel
-- workers rather than one per tick, and a resolved tile's cover now joins the
-- same chain instead of waiting for a second pass.
--
-- Honest about the limit, which no setting could fix: a tile holding two
-- editions (Gutenberg's do) is a real folder and stays one. This makes
-- single-book folders into books; it cannot make a two-item folder into a
-- book.

-- How many records to ask a feed for is no longer a choice either: one
-- screenful, and the shelf keeps a page in hand ahead of you
-- (BookshelfWidget:_opdsPrefetchAhead).
--
-- A fixed number was the wrong shape twice over. Too small and every page turn
-- waited on a round trip; too large and the FIRST page waited on all of them.
-- Worse, it was a number chosen against a page size that changes underneath it
-- - swiping up to reveal another row grew the view past the batch, and the
-- extra slots stayed empty because nothing had asked for those books.
--
-- Fetching exactly one screen keeps the first paint as fast as the layout
-- allows, and the background top-up means the round trip for the NEXT screen
-- has already happened by the time you ask for it.

-- Socket timeouts, as the (block, total) pair socketutil wants. One pair for
-- everyone: 20s to the first byte, 30s in total.
--
-- This was configurable so a LAN server could fail fast instead of hanging for
-- KOReader's 30/60 default. It is not worth a menu row -- 30 seconds is
-- already "this server is not answering" on any network, and the short pair
-- only ever changed how quickly you learnt that.
--
-- THE BLOCK TIMEOUT WAS 10 AND THAT WAS TOO TIGHT FOR ARCHIVE.ORG, measured
-- on a Paperwhite (2026-08-17): its ordinary browse feeds come back in
-- 10.5s -- "fetch=63223ms (10537ms avg)" across a six-item pool, every one of
-- them a hair over the limit -- and its language FACET feeds are heavier
-- still. Those failed outright, with "wantread" (a TLS read that never got its
-- first byte in time), and the shelf then rendered an empty state for a feed
-- nobody had managed to read. A catalog tuned to fail one second before it
-- would have succeeded is worse than a slow one.
--
-- 20, not more: the TOTAL is still 30, so the worst case for a genuinely dead
-- server is unchanged -- this only decides how long a slow-but-alive server is
-- given to start answering.
local TIMEOUT_BLOCK = 20
local TIMEOUT_TOTAL = 30

-- How many background fetches one catalog may have in flight at once.
--
-- TEN, measured (2026-08-15, Gutenberg per-book feeds, disjoint URL slices):
--
--   width  3   4.8s   median 766ms   0 fails    3.7 req/s
--   width  6   2.5s   median 762ms   0 fails    7.1 req/s
--   width 10   1.9s   median 791ms   0 fails    9.6 req/s
--   width 16   5.3s   median 870ms   1 fail     3.4 req/s
--
-- Clean linear scaling to 10 with FLAT latency - no throttling signature at
-- all - and then a collapse at 16 to worse than width 3, with errors. So the
-- server's ceiling is real and sits between the two; 10 is 35% faster than 6
-- and still the safe side of it.
--
-- The pool still HALVES this on any failure and recovers slowly (see
-- bookshelf_widget's _opdsCoverPool). One catalog was measurable here -
-- Internet Archive was unreachable from the test network, and it is the one
-- with a throttling history - so the client has to notice a server pushing
-- back rather than trust this number everywhere.
M.CONCURRENCY = 10

-- A stored value is only honoured if it is one this build offers. A chip
-- written by a newer version (or hand-edited) falls back to the default
-- rather than reaching the fetch path as a nonsense number.
local function validated(options, value)
    for _i, opt in ipairs(options) do
        if opt.value == value then return value end
    end
    return nil
end

-- refreshAge(tab) -> seconds, M.REFRESH_ALWAYS (0) or M.REFRESH_NEVER (-1).
-- Never nil: unset means the default, not "no expiry". Callers MUST compare
-- against the sentinels with == rather than testing truthiness.
function M.refreshAge(tab)
    if type(tab) ~= "table" then return M.REFRESH_DEFAULT end
    local v = tab.opds_refresh_age
    if type(v) ~= "number" then return M.REFRESH_DEFAULT end
    return validated(M.REFRESH_OPTIONS, v) or M.REFRESH_DEFAULT
end

-- isStale(tab, fetched_at, now) -> boolean. The single place the age rule
-- lives, so the caller never re-derives it.
--
-- A window that was never fetched (fetched_at 0 or nil) is NOT stale: it is
-- empty, and the fetch path already treats an empty window as needing a
-- fetch. Saying "stale" here too would turn one fetch into two.
function M.isStale(tab, fetched_at, now)
    local age = M.refreshAge(tab)
    if age == M.REFRESH_NEVER then return false end
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

-- autoCovers(tab) -> boolean. Kept as a function, not inlined at the call
-- sites, so the reason it is always true stays in one place (see the cover
-- comment above) and a future change has one thing to edit.
function M.autoCovers(_tab)
    return true
end

-- resolveNav(tab) -> boolean. Should the background pass fetch nav tiles to
-- flatten single-book folders? Always, now.
function M.resolveNav(_tab)
    return true
end

-- concurrency(tab) -> the pool's STARTING width. The pool narrows from here on
-- failure; this is the opening bid, not a ceiling it must respect.
function M.concurrency(_tab)
    return M.CONCURRENCY
end

-- timeouts(tab) -> { block_timeout = n, total_timeout = n }
--
-- Keys match the net_opts shape bookshelf_opds_covers already passes to
-- CoverFetch.download and that OpdsFeed.fetch accepts, so the result goes
-- straight to either without a translation step in between (a translation step
-- is where a block/total pair gets silently swapped).
--
-- Always a fresh table: handing out a shared pair would let one caller's
-- mutation retune every later request in the session.
function M.timeouts(_tab)
    return { block_timeout = TIMEOUT_BLOCK, total_timeout = TIMEOUT_TOTAL }
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
