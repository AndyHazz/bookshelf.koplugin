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
-- everyone: 10s to the first byte, 30s in total.
--
-- This was configurable so a LAN server could fail fast instead of hanging for
-- KOReader's 30/60 default. It is not worth a menu row -- 30 seconds is
-- already "this server is not answering" on any network, and the short pair
-- only ever changed how quickly you learnt that.
local TIMEOUT_BLOCK = 10
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
