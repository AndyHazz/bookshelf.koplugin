-- lib/bookshelf_opds_window.lua
-- Progressive window over one OPDS feed: entries accumulate as the user pages
-- deeper (rel=next), the shelf slices out of it, and it persists so an OPDS
-- chip renders instantly (and offline) on revisit. Network never happens here.

local Store = require("lib/bookshelf_settings_store")
local logger = (function()
    local ok, l = pcall(require, "logger")
    if ok and l then return l end
    return { dbg = function() end }
end)()

local M = {}

-- How many entries ONE fetch walk may accumulate before it stops asking for
-- more pages.
--
-- This is NOT a storage bound - storage is a row per entry now and has no
-- opinion. It bounds REQUESTS: without it, "go to last page" on a category
-- advertising 10000 results walks the whole rel=next chain, hundreds of round
-- trips, with a modal progress line up the entire time. That happened.
--
-- Named for what it does. It replaces a MAX_ENTRIES that meant "how many
-- entries a feed may keep", which the fetch loop then borrowed as its walk
-- bound - two different jobs sharing a number, which is how the walk ended up
-- comparing against a target the storage layer could never let it reach.
M.MAX_FETCH_ENTRIES = 1000
-- Store-wide eviction budget, in ENTRIES, not feeds. A Gutenberg-style
-- catalogue models every work as a one-entry subcatalog, so browsing a
-- category creates a child window per tapped book; a fixed cap on FEEDS
-- counted those the same as a large category window, and evicted a tapped
-- book's child window - whose tile then lost its flatten/borrowed cover on the
-- very repaint that showed the new one. Tiny child windows cost what they
-- weigh. MAX_FEEDS survives as a far-off backstop so a pathological store of
-- thousands of empty windows still converges.
M.MAX_TOTAL_ENTRIES = 20000
M.MAX_FEEDS         = 200
-- How many CONSECUTIVE unusable feed pages (parsed fine, zero usable records)
-- the fetch loop skips before concluding the whole category is unusable.
-- One page was too aggressive: a single mid-chain page of unsupported entries
-- amputated every page behind it. Three in a row should cover IA's all-borrow
-- loan categories (untested live - their server was down when this landed);
-- anything mixed recovers within a page or two.
M.UNUSABLE_PAGE_LIMIT = 3
-- STORAGE IS SQLITE (bookshelf_opds_db), not a Lua settings file any more.
-- This module keeps its shape - load / appendPage / slice / needsFetch / save
-- / reset - because every caller already goes through it, and only the thing
-- underneath changed. See bookshelf_opds_db's header for the measurements
-- that forced it: a 4.7MB store re-serialised on every fetched page, 399ms a
-- time, because LuaSettings can only rewrite the whole file.
--
-- The one visible change is that a window no longer carries `entries`. It
-- cannot: the point is that the rows stay in the database and only the page
-- being rendered is materialised. Callers that used to ask `#win.entries` ask
-- `win.count`; callers that wanted the records call slice(). LuaJIT here has
-- no 5.2 __len on tables (checked), so a lazy proxy would have lied about its
-- own length - explicit is the honest option.
--
-- The old MAX_ENTRIES is gone with it. It existed to bound a file that had to
-- be rewritten whole; a row per entry has no such problem, and truncating
-- feeds at 1000 was never something anyone wanted. What survives is
-- MAX_FETCH_ENTRIES, which bounds REQUESTS rather than storage.
local DB = require("lib/bookshelf_opds_db")
local KEY = "opds_cache"   -- legacy Lua store, read once by the migration


-- NO migration off the old Lua store. Cached feed pages are a CACHE: the
-- worst case of dropping them is that the next visit to a catalog refetches
-- the page it is showing, which is one request the reader does not notice.
-- Migration code, by contrast, is permanent - it has to be carried, read and
-- reasoned about forever to save a refetch once.
--
-- The old settings key is deleted on first use so the 4.7MB file stops being
-- parsed at every launch, which was 306ms of the startup budget.
local _cleared = false
local function clearLegacy()
    if _cleared then return end
    _cleared = true
    if Store.read(KEY) ~= nil then
        Store.delete(KEY)
        logger.dbg("[bookshelf] dropped the legacy Lua opds store; feeds refetch on demand")
    end
end

-- load(server_key, feed_url) -> window handle.
--
-- Metadata plus a COUNT, never the records. Carries its own identity so
-- slice/appendPage/save can reach the right rows without the caller passing
-- the key a second time (and getting it wrong).
function M.load(server_key, feed_url)
    clearLegacy()
    local m = DB.meta(server_key, feed_url)
    m.server_key = server_key
    m.feed_url   = feed_url
    return m
end

-- appendPage(win, mapped) -> win
--
-- Writes the page's records immediately - that is the whole change - and
-- updates the handle in memory so a caller mid-walk sees the new count without
-- a reload. Dedupe is the database's unique index now, not a `seen` set
-- rebuilt over every existing entry on every page.
function M.appendPage(win, mapped)
    if type(mapped) ~= "table" or type(win) ~= "table" then return win end
    local added = DB.append(win.server_key, win.feed_url, mapped.records or {})
    win.count = (win.count or 0) + added
    -- Replaced wholesale when present, same as before: a search link is
    -- feed-level, so a deeper page that does not carry one leaves the last
    -- known value alone rather than clobbering it to nil.
    if mapped.search then win.search = mapped.search end
    win.next_url = mapped.next_url
    if mapped.total then win.total = mapped.total end
    -- The server's declared page size, kept so the lookahead can cost a depth
    -- in requests rather than guessing at it.
    if mapped.items_per_page then win.items_per_page = mapped.items_per_page end
    return win
end

-- slice(win, offset, limit) -> page, total, open_ended
--
-- The page comes from the database by LIMIT/OFFSET, so depth costs an indexed
-- range scan rather than holding the feed in RAM. Records are decoded copies,
-- which preserves the old contract exactly: the caller may decorate what it
-- gets back (cover paths, downloaded flags) without touching what is stored.
function M.slice(win, offset, limit)
    if type(win) ~= "table" then return {}, 0, false end
    local page = DB.slice(win.server_key, win.feed_url, offset or 0,
                          limit or (win.count or 0))
    -- A window the fetch loop marked complete has nothing more behind it: the
    -- feed's next chain terminally ended (or the category was judged
    -- unusable). totalResults routinely over-promises - IA advertises counts
    -- its chain never serves - so a complete window's real total is what is
    -- cached, and it is never open-ended.
    local total = win.complete and (win.count or 0)
                  or win.total or (win.count or 0)
    -- Open-ended means "we do not know where this ends", and that is decided
    -- by `complete` alone - the same rule needsFetch uses. Requiring a
    -- next_url made a window that had LOST its chain look finished: the footer
    -- dropped the "+" and promised an exact page count it had no basis for,
    -- so "1 of 3+" became "1 of 3" and only grew when the reader walked into
    -- it. A feed never seen to end has an unknown length, whether or not we
    -- currently hold a link to follow.
    local open_ended = (not win.complete) and (win.total == nil)
    return page, total, open_ended
end

-- needsFetch(win, offset, limit) -> boolean
-- The slice ran past what is cached, and there is more to be had.
--
-- "More to be had" is NOT "we hold a next link". A window that is not marked
-- complete has never been seen to end, so if its chain is missing we have lost
-- it rather than reached it - and requiring next_url made that state
-- permanent: entries cached, nothing to follow, needsFetch forever false, a
-- category frozen at two pages with no way back. Seen on Internet Archive
-- after a bug left rows in exactly that shape.
--
-- complete is the only honest "there is no more". Everything else is worth
-- asking about, and the walk knows how to rediscover a chain it has lost.
function M.needsFetch(win, offset, limit)
    if type(win) ~= "table" then return false end
    if ((offset or 0) + (limit or 0)) <= (win.count or 0) then return false end
    if win.complete then return false end
    return true
end

-- save(server_key, feed_url, win) - persist the window's METADATA.
--
-- The entries were written when they were appended; there is nothing to
-- re-serialise here, which is the entire point of the change. Eviction runs
-- after, as a DELETE ordered by staleness rather than a walk over every
-- window weighing it.
function M.save(server_key, feed_url, win)
    if type(win) ~= "table" then return end
    DB.setMeta(server_key, feed_url, {
        fetched_at = win.fetched_at,
        next_url   = win.next_url,
        total      = win.total,
        complete   = win.complete,
        trimmed    = win.trimmed,
        search     = win.search,
        items_per_page = win.items_per_page,
    })
    -- next_url must be expressible as "gone": a chain that ended says so by
    -- clearing it, and setMeta reads nil as "leave alone".
    if win.next_url == nil then DB.clearNextUrl(server_key, feed_url) end
    DB.evict(M.MAX_FEEDS, M.MAX_TOTAL_ENTRIES)
end

-- reset(server_key, feed_url) - drop a feed's cached entries.
function M.reset(server_key, feed_url)
    clearLegacy()
    DB.reset(server_key, feed_url)
end

-- count(server_key, feed_url) - entries cached for a feed, without loading it.
function M.count(server_key, feed_url)
    clearLegacy()
    return DB.count(server_key, feed_url)
end

return M
