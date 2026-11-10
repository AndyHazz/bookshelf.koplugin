-- bookshelf_widget_opds.lua
-- The shelf's OPDS side: fetching and paging a catalogue's feeds, the cover
-- pool, search, the remote book popup, downloads and streaming, the start
-- folder and the drill into a subcatalogue.
--
-- These are BookshelfWidget's own methods, kept in a file of their own. The
-- module returns an installer: lib/bookshelf_widget.lua calls it once with the
-- class, and every method below is defined on that class exactly as if it
-- were written there (`self` is the shelf widget, and BookshelfWidget.live is
-- the real class field). The bodies sit at the left margin for that reason.
local BookshelfSettings = require("lib/bookshelf_settings_store")
local FrameContainer  = require("ui/widget/container/framecontainer")
local VerticalGroup   = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local CenterContainer = require("ui/widget/container/centercontainer")
local TextWidget      = require("lib/bookshelf_colour_text")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local Geom            = require("ui/geometry")
local Size            = require("ui/size")
local Space           = require("lib/bookshelf_space")
local BFont           = require("lib/bookshelf_fonts")
local UIManager       = require("ui/uimanager")
local Device          = require("device")
local Screen          = Device.screen
local _               = require("lib/bookshelf_i18n").gettext
local Repo            = require("lib/bookshelf_book_repository")
local logger          = require("logger")
local T               = require("ffi/util").template
local _gettime        = require("lib/bookshelf_gettime")

return function(BookshelfWidget)

-- _markOpdsNav() - arm the one-shot "the user caused the rebuild that is
-- about to happen" flag. EVERY OPDS network call is gated on it: the shelf
-- rebuilds for plenty of reasons the user did not ask for (startup restore
-- with a persisted chip + cursor, the 5s sideload file-poll, a cover
-- landing, a settings change), and none of those may reach the network.
-- Armed by the navigation gestures only -- chip select, page turn, page
-- jump, swipe-down refresh -- and consumed by the next _opdsAfterPage.
function BookshelfWidget:_markOpdsNav()
    self._opds_nav_pending = true
end

-- _opdsEffectiveTab() -> tab-like | nil
-- WHICH OPDS feed is the shelf actually showing right now? Every network
-- helper below needs the same answer, and it is not simply "the active tab":
-- drilling into a navigation entry puts a different feed on screen while the
-- chip underneath is unchanged. Resolved in the precedence _fetchChipItems
-- itself uses -- drill tip first, chip second:
--
--   * tip.kind == "opds_nav" -> a synthesised stand-in for the subcatalog the
--     user drilled into. It carries exactly the three fields the helpers read
--     off a tab (source.id, source.feed_url, label), so _opdsFetchMore /
--     _opdsRefresh work against a drilled feed with no change of their own.
--   * any OTHER tip kind (search, folder, a group) -> nil. That view is a
--     library view reachable from any chip; the feed is not what is rendered,
--     so no OPDS work applies. Same answer the old inline drill guards gave.
--   * no tip at all -> the real tab, when its source is an OPDS one.
--
-- Factored into one function deliberately: three hand-rolled copies of this
-- precedence is how the "the drilled page doesn't fetch / refresh / show
-- covers" rounds happen.
function BookshelfWidget:_opdsEffectiveTab()
    local path = self._drilldown_path or {}
    local tip  = path[#path]
    if tip then
        if tip.kind ~= "opds_nav" then return nil end
        local pay = tip.payload or {}
        if not (pay.server_key and pay.feed_url) then return nil end
        return {
            label  = tip.label,
            source = { kind = "opds", id = pay.server_key,
                       feed_url = pay.feed_url },
        }
    end
    local TabModel = require("lib/bookshelf_tab_model")
    local tab = TabModel.getById(self.chip)
    if tab and tab.source and tab.source.kind == "opds" then return tab end
    return nil
end

-- _opdsBatchSize() -> how many entries one fetch should pull: one screenful.
--
-- Exactly the page being rendered, so the first paint comes as fast as the
-- layout allows. It used to be max(view, a per-chip number), which was the
-- wrong shape in both directions - a small number made every page turn wait
-- on a round trip, a large one made the FIRST page wait on all of them - and
-- was chosen against a page size that changes underneath it when the shelf
-- expands.
--
-- A background lookahead was built here and REVERTED, because there is no
-- quiet way to fetch a feed yet. _opdsFetchMore is the user-facing fetch: it
-- runs inside Trapper and shows a modal "Fetching..." that yields for input,
-- and its tail re-clamps self._cursor and rebuilds. Driving it from a
-- background prefetch therefore blocked input on a page the user had already
-- been given, showed the message a second time on the next swipe, and moved
-- the cursor under a swipe in flight - the page slipping one further than
-- asked for.
--
-- Doing it properly needs a silent fetch path: no Trapper, no progress line,
-- no cursor arithmetic, and an abandon-on-navigation token like the cover
-- chain's. That is a real piece of work on a function whose every branch is
-- load-bearing, not a flag.
function BookshelfWidget:_opdsBatchSize()
    return self:_viewSize() or 24
end

-- _opdsFeedRef(tab) -> server_key, feed_url  (nil when the tab is not a
-- resolvable catalog). One resolution shared by every caller that needs to
-- reach a chip's cached window; two copies of this drift the moment one of
-- them learns about a new source shape.
function BookshelfWidget:_opdsFeedRef(tab)
    if not (tab and tab.source and tab.source.id) then return nil end
    local ok_s, OpdsSource = pcall(require, "lib/bookshelf_opds_source")
    if not ok_s then return nil end
    local server = OpdsSource.getServer(tab.source.id)
    local feed_url = tab.source.feed_url or (server and server.url)
    if not feed_url then return nil end
    return tab.source.id, feed_url
end

-- want_count sentinel: "walk this feed until it actually ends".
--
-- Every other want is derived from a cursor and is therefore a guess at how
-- much the reader is about to need, which is why they are all capped. This one
-- is a question the reader asked outright by tapping "last page" on a feed of
-- unknown length, and a cap would answer it with a number that is not the
-- answer. math.huge rather than a magic integer so the walk's own
-- `count < want_count` test needs no special case.
local FETCH_ALL = math.huge

-- _opdsPrefsTab() -> the real CHIP behind the current view, or nil.
--
-- Not the same question as _opdsEffectiveTab, and the two must not be
-- confused. That one answers "which feed is on screen", and when the user has
-- drilled into a subcatalog it answers with a synthesised stand-in carrying
-- only label + source -- a table that has never been persisted and so holds
-- none of the chip's settings. This one answers "whose settings govern that
-- view", which is always the chip the drill started from: the catalog is what
-- was configured, and drilling into one of its subcatalogs does not leave it.
--
-- Returns nil for a non-OPDS chip, so every caller can hand the result
-- straight to bookshelf_opds_prefs (whose readers all treat nil as "defaults").
function BookshelfWidget:_opdsPrefsTab()
    local TabModel = require("lib/bookshelf_tab_model")
    local tab = TabModel.getById(self.chip)
    if tab and tab.source and tab.source.kind == "opds" then return tab end
    return nil
end

-- Fetch feed pages for an OPDS tab until the window covers want_count
-- entries (or the feed runs out), then rebuild. User-initiated only: chip
-- tap on an empty window, page-turn past the window, swipe-down refresh.
-- Trapper gives a cancellable progress line; runWhenOnline gates Wi-Fi
-- with a prompt, never silently.
--
-- replace = true (swipe-down refresh) fetches into a FRESH window instead of
-- extending the cached one, and only overwrites the persisted window once
-- the feed has actually given us entries. Resetting up front would empty the
-- chip the moment the user declined the Wi-Fi prompt -- runWhenOnline's
-- callback simply never fires -- leaving them worse off than before they
-- asked. No user action may leave the chip emptier than it started unless
-- the feed itself genuinely got smaller.
--
-- `tab` is a tab-LIKE, not necessarily a real one: only source.id,
-- source.feed_url and label are read off it. Inside a drilled navigation entry
-- the caller passes the stand-in _opdsEffectiveTab synthesises for the
-- subcatalog, and every line below works against it unchanged -- which is the
-- whole reason the drill needed no fetch machinery of its own.
-- on_done (optional): a ONE-SHOT continuation run at the very end of the tail,
-- after the rebuild and the cover pass, for a caller that has a decision to
-- make once the feed has actually landed (today: _expandOpdsNav deciding
-- between a book modal and a drill for a subcatalog nothing had fetched yet).
-- It never fires when the fetch never ran -- an unknown server, or a Wi-Fi
-- prompt the user declined, in which case runWhenOnline simply never calls
-- back -- which is the correct "stay put" in both cases. Nothing about the
-- marker discipline changes: the markers are already released above, and this
-- runs inside the same single synchronous run of the coroutine.
-- _opdsResetFlattenedChildren(server_key, win) -> how many were dropped
--
-- ISSUE 411. A category holding exactly one acquisition entry is rendered as
-- that book rather than as a folder ("folder of one"), which is what keeps
-- Gutenberg and ManyBooks usable -- they model every work as a subcatalog of
-- one. The decision is made from the CHILD feed, which is a separate cached
-- feed from the page being looked at.
--
-- That is the trap. Flattening removes the folder, and the drill-in is the
-- only route by which a child feed ever becomes the refresh target, so once a
-- tile has flattened nothing can reach its child feed again: a swipe-down
-- refreshes the feed on screen, the resolve pass skips anything already
-- fetched, and every other write is append-only. The tile stays the book it
-- was the day it was cached, for ever -- "refreshing does not revert it back
-- to a folder even if more entries are added back".
--
-- So an explicit refresh drops the child feeds its flattening decisions were
-- made from, and the resolve pass fetches them again on the next paint, which
-- is what a first visit already costs.
--
-- ONLY the ones that actually flattened. A folder that stayed a folder can
-- still be drilled into and refreshed there, so clearing its child as well
-- would be a round trip per tile for nothing. Same predicate as the render,
-- through Repo, so the two cannot disagree about what "one entry" means.
function BookshelfWidget:_opdsResetFlattenedChildren(server_key, win)
    if not (server_key and type(win) == "table") then return 0 end
    local n = 0
    pcall(function()
        local OpdsWindow = require("lib/bookshelf_opds_window")
        -- The OLD window: this runs before the parent is reset, which is the
        -- only moment the pre-refresh page is still readable.
        local page = OpdsWindow.slice(win, 0, win.count or 0) or {}
        for _i = 1, #page do
            local rec = page[_i]
            local url = rec and rec.is_opds_nav and rec.opds and rec.opds.feed_url
            if url and Repo.opdsLoneChildBook(server_key, url) then
                OpdsWindow.reset(server_key, url)
                n = n + 1
            end
        end
    end)
    return n
end

function BookshelfWidget:_opdsFetchMore(tab, want_count, replace, on_done)
    local OpdsSource = require("lib/bookshelf_opds_source")
    local OpdsFeed   = require("lib/bookshelf_opds_feed")
    local OpdsWindow = require("lib/bookshelf_opds_window")
    local CoverFetch = require("lib/bookshelf_cover_fetch")
    local Notification = require("ui/widget/notification")
    local Trapper    = require("ui/trapper")
    local server = OpdsSource.getServer(tab.source.id)
    if not server then return end
    local feed_url = tab.source.feed_url or server.url
    -- Bound the WALK, not the storage. "Go to last page" on a category
    -- advertising 10000 results computes a want of 10000 and the loop below
    -- would ask the server for page after page until its chain ran out -
    -- hundreds of round trips with a modal progress line up throughout. That
    -- happened on device.
    --
    -- Clamped here rather than at each caller because every caller derives
    -- want from a cursor, and a cursor can always be sent further than any one
    -- fetch should chase.
    --
    -- FETCH_ALL is the one exception, and it is exempt on purpose. It is not a
    -- cursor overshoot - it is the reader tapping "last page" on a feed of
    -- unknown length, which is a direct question ("where does this end?") that
    -- a cap can only answer wrongly. It is safe to leave unbounded precisely
    -- because it is explicit: the progress line counts up, a tap stops it
    -- within about a tenth of a second, and everything already fetched is
    -- kept, so the worst case of a long walk is that the reader ends it early.
    if want_count ~= FETCH_ALL then
        local _OW = require("lib/bookshelf_opds_window")
        want_count = math.min(want_count or 0, _OW.MAX_FETCH_ENTRIES)
    end
    -- Per-catalog socket budget, resolved once for the whole walk rather than
    -- per page: every page of one fetch belongs to the same catalog, and the
    -- chip cannot change under a running coroutine. Read off the CHIP, not the
    -- effective tab - a drilled subcatalog's stand-in carries no settings.
    local feed_timeouts = require("lib/bookshelf_opds_prefs")
        .timeouts(self:_opdsPrefsTab())
    -- Is `t` (an _opdsEffectiveTab result) the same feed this fetch is for?
    -- Compared on the RESOLVED url, not the raw field: a chip's own tab leaves
    -- source.feed_url nil and means "the server's root url", which is exactly
    -- what feed_url resolved to above, so a raw comparison would call the root
    -- feed a different feed from itself. Server id checked first, so falling
    -- back to the captured server's url is the right substitution.
    local function sameFeed(t)
        if not (t and t.source and t.source.id == tab.source.id) then return false end
        return (t.source.feed_url or server.url) == feed_url
    end
    CoverFetch.runWhenOnline(function()
        -- Liveness, same test the _opdsAfterPage / _opdsEnsureCovers deferrals
        -- make: the Wi-Fi prompt is modal and the user can answer it long after
        -- the shelf closed (or after a re-open replaced this widget). Every
        -- line below fetches, moves this widget's cursor and rebuilds it, so
        -- running it against a dead shelf is at best waste and at worst a
        -- Trapper progress line over whatever is on screen now.
        if BookshelfWidget.live ~= self then return end
        Trapper:wrap(function()
            -- Held for the whole fetch so any rebuild landing mid-fetch can't
            -- queue a second FETCH. It does NOT block the user: an explicit
            -- swipe-down refresh during a feed fetch is deliberately exempt
            -- (see _opdsRefresh, which reads only the download marker), and a
            -- navigation that lands here is queued rather than refused. A
            -- timestamp rather than a boolean:
            -- Trapper:info yields, so this body can't be pcall-wrapped (LuaJIT
            -- can't yield across a C-call boundary) and an error inside the
            -- coroutine would otherwise wedge the flag on for the rest of the
            -- session. It expires instead.
            --
            -- ...and WHICH feed the fetch is for, as the sameFeed predicate
            -- itself. _opdsAfterPage needs to tell "the feed on screen is
            -- already being fetched" (refuse, nothing to do) from "some OTHER
            -- feed is being fetched" (queue, see there) -- previously it could
            -- not, so a drill landing mid-fetch was refused as busy and left
            -- the user on an empty subcatalog, and an errored fetch blocked
            -- every feed for the full 120s. A predicate rather than the url
            -- string because the comparison is on the RESOLVED url: recomputing
            -- "the chip's root feed" at the far end would mean an
            -- OpdsSource.getServer -- a re-read and re-parse of the stock OPDS
            -- plugin's opds.lua -- on every page render.
            self._opds_fetch_started_at = os.time()
            self._opds_fetch_feed = sameFeed
            local _dbg_want = want_count
            -- Shape matches OpdsWindow.load's miss exactly, field for field:
            -- the two have to stay interchangeable since everything below
            -- treats `win` the same either way.
            -- "Replace" means the cached window may be WRONG rather than
            -- merely short, so it is emptied before the walk refills it.
            --
            -- It must still be a REAL handle. A window carries its own
            -- identity now (server_key + feed_url) and everything that writes
            -- reaches storage through it; the bare table this used to build
            -- had neither, so every append bound a nil key, SQLite rejected
            -- the row, and the walk fetched page after page into nothing. The
            -- shelf showed a progress message and then no change at all.
            -- REPLACE DOES NOT DESTROY THE CACHE UP FRONT.
            --
            -- It used to: reset, then walk. So a refresh that could not reach
            -- the server - offline, catalog down, a transient error - threw
            -- away a perfectly good cached feed and left the reader looking at
            -- "No books yet" over a shelf that had been full a second earlier.
            -- Refreshing is not a request to be shown nothing, and a cached
            -- feed is the only thing an OPDS chip HAS when offline.
            --
            -- Held until the first page actually lands instead (see
            -- pending_replace below), so the old window survives every way a
            -- refresh can fail.
            local pending_replace = replace or false
            local win = OpdsWindow.load(tab.source.id, feed_url)
            -- Follow the chain when we have it. When we do not AND the feed
            -- has never been seen to end, the chain is LOST rather than
            -- finished - start again from the top and re-walk. Dedupe is a
            -- unique index now, so re-treading known pages costs requests and
            -- adds nothing twice; the alternative is a category frozen at
            -- whatever it happens to hold, which is what a bug left behind on
            -- Internet Archive.
            --
            -- A replace always starts at the top, decided here rather than
            -- inferred from a window we have deliberately not cleared yet.
            local url
            if pending_replace then
                url = feed_url
            else
                url = OpdsWindow.fetchUrl(win, feed_url)
            end
            -- Consecutive unusable pages seen (parsed fine, zero usable
            -- records). Reset by any page that yields records; when it hits
            -- OpdsWindow.UNUSABLE_PAGE_LIMIT the category is judged unusable
            -- and the walk stops terminally.
            local unusable_streak = 0
            -- Did the walk end TERMINALLY (chain finished, or category judged
            -- unusable) rather than by error, cancel or want_count? Terminal
            -- ends mark the window complete, which clamps the promised page
            -- count to what is cached (OpdsWindow.slice).
            local terminal = false
            -- Every url fetched by THIS walk. A feed whose rel=next loops back
            -- on itself (Internet Archive's faceted feeds have returned a next
            -- pointing at the very page it came from) can never make progress:
            -- the refetched page dedupes to nothing, the window stops growing,
            -- and without this guard the walk refetched the same page once a
            -- second forever. Any url seen twice ends the chain terminally --
            -- everything reachable was already fetched the first time round.
            local seen_urls = {}
            -- What this walk can count as already held.
            --
            -- Not simply win.count while a replace is pending: those entries
            -- are about to be thrown away, so counting them against the target
            -- says the work is already done. That is exactly what happened -
            -- deferring the reset (below) left a category holding 25 entries
            -- measured against a batch of 24, the loop never ran, and
            -- swipe-down refresh silently did nothing at all. Zero until the
            -- old window is actually gone, then the real count.
            local function heldCount()
                return pending_replace and 0 or (win.count or 0)
            end
            -- Discard the tap that STARTED this fetch.
            --
            -- The progress message traps input so it can be dismissed, and it
            -- goes up within milliseconds of the tap that asked for the fetch -
            -- so on e-ink, where the release event arrives well after the
            -- widget exists, that same tap dismissed it. The walk was cancelled
            -- before its first page landed ("stopped by the reader at 0
            -- entries", twice in one session, neither of them the reader), the
            -- shelf rebuilt an empty window as "No books yet", and the next
            -- top-up quietly refilled it a second later. Drills got it worst:
            -- the tap on a category cancelled the very fetch it had just
            -- requested.
            --
            -- This is the same guard the stock widgets use as
            -- flush_events_on_show, and the same reason: 400ms for the refresh
            -- to actually land plus 400ms for a human to react to it.
            -- dismissableRunInSubprocess does not do it for a trap widget we
            -- pass in, so it is ours to do.
            if Device.input and Device.input.inhibitInputUntil then
                Device.input:inhibitInputUntil(true)
            end
            while url and heldCount() < want_count do
                if seen_urls[url] then
                    logger.dbg("[bookshelf perf] opds next-chain loop detected at", url)
                    win.next_url = nil
                    terminal = true
                    break
                end
                seen_urls[url] = true
                -- Report progress THROUGH the walk, not just that a walk is
                -- happening. One fetch can be many feed pages -- a catalog
                -- serving 25 records a page needs eleven of them to satisfy a
                -- batch of 200 -- and a line that reads "Fetching X…" on every
                -- one of them is indistinguishable from eleven separate
                -- fetches, which is exactly how it was read on device. The
                -- count is what makes one long operation legible as one.
                -- The second line is the point of making cancel responsive: an
                -- operation the reader is allowed to stop should say so. It
                -- matters most on exactly the walk that takes longest - "last
                -- page" on a feed of unknown length, which is unbounded and
                -- can run for a while before the chain gives out.
                --
                -- One function because it is needed twice: at the top of every
                -- page, and again after a "keep loading", where Trapper:confirm
                -- has replaced the progress message with its ConfirmBox and
                -- closed it. Retrying without putting it back would leave the
                -- reader watching a frozen shelf with nothing to tap.
                local function showProgress()
                    if heldCount() > 0 then
                        return self:_showFetchProgress(
                            T(_("Fetching %1… (%2 books)\n(Tap to cancel)"),
                              tab.label or server.title, heldCount()))
                    end
                    return self:_showFetchProgress(
                        T(_("Fetching %1…\n(Tap to cancel)"),
                          tab.label or server.title))
                end
                if not showProgress() then break end
                -- Gated per request, not just the entry feed_url: a
                -- rel=next link came from the server's XML and could in
                -- principle hop to a foreign host, and credentials must
                -- only ever travel to the catalog's own origin.
                local same_origin = OpdsFeed.sameOrigin(server.url, url)
                -- OFF THE MAIN LOOP, so that "tap to stop" is true.
                --
                -- Fetching in-process blocks UIManager for the whole request -
                -- three to four seconds a page against Internet Archive - and
                -- Trapper only samples input during the 0.1s window inside
                -- info(). So a tap almost always landed while the main loop was
                -- blocked and was never seen: the reported "tapping to cancel
                -- does nothing until you frantically tap everywhere", which is
                -- exactly what having one narrow window per multi-second page
                -- feels like.
                --
                -- dismissableRunInSubprocess forks the request and hands
                -- control back to UIManager every 125ms (backing off to 1s),
                -- so a tap is acted on within about that, and the shelf stays
                -- painted underneath rather than frozen.
                --
                -- A dismissal here cancels outright, with no "are you sure".
                -- Trapper's own info() path raises a Paused/Continue/Abort box
                -- because a stray tap could throw away a long job; nothing is
                -- thrown away here, since every page is written to the database
                -- as it lands and the tail below keeps the window and lands the
                -- reader on the last page that has books. Cheap to undo, so it
                -- does not deserve a confirmation.
                local fetch_user = same_origin and server.username or nil
                local fetch_pass = same_origin and server.password or nil
                local fetch_url  = url
                local body, err
                local cancelled = false
                repeat
                    local retry = false
                    if Trapper.dismissableRunInSubprocess then
                        -- The task's own returns come back SPREAD, not packed:
                        -- the helper ends with `return completed,
                        -- unpack(ret_values, ...)`. Reading it as a table
                        -- indexed a string, so both values came back nil and
                        -- every fetch reported a failure with no error - a
                        -- pair no path in OpdsFeed.fetch can return.
                        local completed, b, e = Trapper:dismissableRunInSubprocess(
                            function()
                                return OpdsFeed.fetch(fetch_url, fetch_user,
                                                      fetch_pass, feed_timeouts)
                            end,
                            -- Trap on the progress message already on screen,
                            -- so the reader taps the thing they can see. Nil
                            -- falls back to an invisible trap widget, which
                            -- still catches the tap.
                            Trapper.current_widget)
                        if completed then
                            body, err = b, e
                        else
                            -- ASK before throwing the walk away. Trapper's own
                            -- info() path does this and it was right to; what
                            -- was wrong was that a blocked main loop made the
                            -- tap itself unreliable, so the prompt was
                            -- unreachable rather than unwanted. Sampling every
                            -- 125ms fixes the reaching; a tap on a shelf is
                            -- cheap enough to be accidental, so it still has to
                            -- be meant. ConfirmBox flushes pending events on
                            -- show, so the dismissing tap cannot answer it.
                            cancelled = Trapper:confirm(
                                heldCount() > 0
                                    and T(_("Stop loading %1?\n%2 books so far."),
                                          tab.label or server.title, heldCount())
                                    or  T(_("Stop loading %1?"),
                                          tab.label or server.title),
                                _("Keep loading"), _("Stop"))
                            -- Kept going: the request was killed with the
                            -- dismissal, so this page has to be asked for
                            -- again. Costs one round trip and nothing else -
                            -- re-treading a page dedupes to nothing. It cannot
                            -- go round the outer loop instead: seen_urls has
                            -- already recorded this url, and re-entering would
                            -- read as a self-referential rel=next chain and end
                            -- the walk.
                            retry = not cancelled
                            if retry and not showProgress() then
                                cancelled = true
                                retry = false
                            end
                        end
                    else
                        -- Ancient KOReader without the helper: fetch in-process.
                        -- Correct, just unresponsive to a cancel mid-request.
                        body, err = OpdsFeed.fetch(fetch_url, fetch_user,
                                                   fetch_pass, feed_timeouts)
                    end
                until not retry
                if cancelled then
                    logger.dbg("[bookshelf perf] opds walk: stopped by the reader at",
                               (win.count or 0), "entries")
                    break
                end
                if not body then
                    Trapper:clear()
                    -- The toast says "Couldn't reach <server>" for everything
                    -- that isn't an auth rejection, which is the right thing to
                    -- tell a reader and useless in a bug report: a gateway
                    -- timeout from a catalog that is plainly up reads exactly
                    -- like a DNS failure. OpdsFeed.fetch already hands back the
                    -- HTTP status line as `err` (or "network unreachable" /
                    -- "empty response"), so log the pair rather than widening
                    -- the notification. dbg, not warn: an unreachable server is
                    -- a normal thing to hit offline, and the log is for the
                    -- session where someone is looking.
                    logger.dbg("[bookshelf] opds fetch failed:", url, err)
                    -- Remembered for the EMPTY STATE. A toast is gone in three
                    -- seconds and the shelf underneath it then says "No books
                    -- in Internet Archive yet", which is a sentence about the
                    -- reader's own library and wrong in every particular: the
                    -- books are on someone else's server, there is no "yet",
                    -- and nothing was counted because nothing was fetched.
                    -- Keyed by url so a failure on one feed cannot explain
                    -- another feed's emptiness.
                    self._opds_fail_url = url
                    self._opds_fail_err = err
                    UIManager:show(Notification:new{
                        text = err == "auth"
                            and T(_("Authentication failed for %1"), server.title)
                            or err == "format"
                            and T(_("%1 refused every format Bookshelf asked for"), server.title)
                            or err == "ratelimited"
                            and T(_("%1 is limiting requests. Wait a minute and try again."), server.title)
                            or T(_("Couldn't reach %1"), server.title),
                    })
                    break
                end
                -- The server answered, so whatever it last refused is history.
                if self._opds_fail_url == url then
                    self._opds_fail_url, self._opds_fail_err = nil, nil
                end
                local catalog = OpdsFeed.parse(body)
                local mapped = catalog and OpdsFeed.mapEntries(catalog, url, tab.source.id)
                -- Did the page carry any raw items at all? Separates a genuinely
                -- empty feed from one that HAS items this device just can't use.
                local raw_count = catalog and (
                    (catalog.publications and #catalog.publications or 0)
                    + (catalog.navigation and #catalog.navigation or 0)
                    + (catalog.entry and #catalog.entry or 0)) or 0
                logger.dbg("[bookshelf perf] opds page", url,
                    "records", mapped and #mapped.records or -1,
                    "raw", raw_count,
                    "next", tostring((mapped and mapped.next_url) ~= nil))
                if not mapped then
                    -- Parse failure (transient): an HTML error page from a
                    -- throttling server (IA does this mid-chain) is the common
                    -- cause. Leave next_url ALONE so the chain stays
                    -- retryable - a later page turn resumes from the last
                    -- good checkpoint and reaches this page again. Nilling it
                    -- here and then saving the window (which the tail below
                    -- does) permanently amputated every page behind the
                    -- failure: the reported "nothing loads after page 10 of
                    -- 15".
                    if (win.count or 0) == 0 then
                        Trapper:clear()
                        UIManager:show(Notification:new{
                            text = T(_("No books found in %1"), server.title),
                        })
                    end
                    break
                end
                if #mapped.records == 0 then
                    -- Parsed fine, but nothing on this page is usable. Do not
                    -- give up on the first one: a single mid-chain page of
                    -- unsupported entries (borrow-only, formats we can't
                    -- read) says nothing about the pages behind it, and
                    -- stopping here used to amputate them permanently. Skip
                    -- forward instead - up to UNUSABLE_PAGE_LIMIT consecutive
                    -- unusable pages, after which the category is judged
                    -- genuinely unusable (IA's all-borrow loan categories
                    -- advertise ~10000 items and every page maps to zero;
                    -- three in a row is enough to know the rest match).
                    unusable_streak = unusable_streak + 1
                    if mapped.next_url
                            and unusable_streak < OpdsWindow.UNUSABLE_PAGE_LIMIT then
                        url = mapped.next_url
                        -- No appendPage (nothing usable to add); loop again.
                    else
                        win.fetched_at = os.time()
                        win.next_url = nil
                        terminal = true
                        if (win.count or 0) == 0 then
                            Trapper:clear()
                            UIManager:show(Notification:new{
                                text = raw_count > 0
                                    and _("No downloadable titles in this category.")
                                    or T(_("No books found in %1"), server.title),
                            })
                        end
                        break
                    end
                else
                    -- The replacement has arrived, so now the old one can go.
                    -- Everything up to this line was reachable with the cached
                    -- window still intact, which is the point: a refresh that
                    -- never gets a page leaves the reader exactly where they
                    -- were rather than emptying the shelf.
                    if pending_replace then
                        -- The page's own flattening decisions were made from
                        -- OTHER feeds; drop those too or the refresh cannot
                        -- see them change (issue 411).
                        self:_opdsResetFlattenedChildren(tab.source.id, win)
                        OpdsWindow.reset(tab.source.id, feed_url)
                        win = OpdsWindow.load(tab.source.id, feed_url)
                        pending_replace = false
                    end
                    unusable_streak = 0
                    win.fetched_at = os.time()
                    OpdsWindow.appendPage(win, mapped)
                    url = win.next_url
                end
            end
            -- The chain ended by running out of next links (url == nil after a
            -- successful append), or a terminal stop above. NOT on error,
            -- cancel, or simply having covered want_count (url still set).
            if url == nil then terminal = true end
            if terminal then win.complete = true end
            Trapper:clear()
            -- A refresh that came back with nothing (server down, feed
            -- unreachable, user cancelled at the first page) keeps the
            -- window it already had.
            if not replace or (win.count or 0) > 0 then
                logger.dbg(string.format(
                    "[bookshelf perf] opds walk END: entries=%d next=%s terminal=%s "
                    .. "complete=%s want=%s", win.count or 0, tostring(win.next_url ~= nil),
                    tostring(terminal), tostring(win.complete), tostring(_dbg_want)))
                OpdsWindow.save(tab.source.id, feed_url, win)
            end
            -- No Repo.invalidateBookCache here: the OPDS branch of getBySource
            -- reads OpdsWindow (the settings store) on every call and never
            -- touches the walk / group / _bySource caches, so there is nothing
            -- stale to clear. Invalidating would only make the next tap on a
            -- LOCAL chip re-derive the whole library for free.

            -- Paging forward left the cursor one page PAST the window (that
            -- overshoot is what asked for this fetch). If the fetch did not
            -- actually reach it -- server down, auth rejected, user cancelled,
            -- or the feed simply ended -- pull the cursor back onto the last
            -- page with books BEFORE rebuilding. Otherwise the user is stranded
            -- on a blank page in front of a perfectly good cached window, and
            -- _persistNavState saves that cursor for next launch. Skipped when
            -- a refresh declined to save (win is the discarded fresh one, not
            -- what will be rendered).
            -- A DECLINED Wi-Fi prompt never gets here (runWhenOnline simply
            -- never calls back); that case is caught by _maxCursor withholding
            -- the headroom from the next passive clamp instead.
            --
            -- Gated on the shelf STILL showing this feed, re-resolved rather
            -- than assumed. runWhenOnline can sit on a Wi-Fi prompt for many
            -- seconds with the shelf fully interactive underneath it, so the
            -- user can back out of the drill (or drill somewhere else) before
            -- this tail runs. The fetch and the save above are keyed off the
            -- CAPTURED feed and stay correct either way -- but the cursor
            -- belongs to whatever is on screen NOW, and measuring it against
            -- THIS window's entry count would yank the user to page 1 of a view
            -- that was never short. The overshoot this pull-back exists to
            -- repair went away with the navigation that abandoned it.
            local still_here  = sameFeed(self:_opdsEffectiveTab())
            local entry_count = win.count or 0
            if still_here and (not replace or entry_count > 0)
                    and self._cursor > entry_count then
                local view = self:_viewSize()
                local pages = math.max(1, math.ceil(entry_count / view))
                self._cursor = (pages - 1) * view + 1
                self:_syncPageFromCursor()
            end
            -- Released BEFORE the rebuild, not after. A navigation that landed
            -- while this fetch held the marker left the nav arm SET rather
            -- than spending it (see _opdsAfterPage), specifically so this
            -- rebuild can start the fetch it was refused; with the marker
            -- still held it would be refused again and the user would sit on
            -- an empty subcatalog until they touched something. Nothing can
            -- interleave between these lines and the rebuild -- one
            -- synchronous run of the coroutine -- so the "no second fetch
            -- mid-fetch" guarantee the marker exists for is unaffected: a
            -- rebuild with no arm set returns at the top of _opdsAfterPage.
            self._opds_fetch_started_at = nil
            self._opds_fetch_feed = nil
            self:_rebuild()
            UIManager:setDirty(self, "ui")
            -- The cover pass for this page. This rebuild is passive in the
            -- ordinary case (nothing re-armed the nav flag), so it renders
            -- from cache and runs no cover pass of its own -- this is the
            -- single pass, and its token stays current through to the repaint.
            -- In the queued case above it has just scheduled the next fetch
            -- instead, and that fetch runs its own pass against the fuller
            -- page; this one still fills whatever is on screen right now, and
            -- a superseded batch only loses its repaint, never its downloads.
            self:_opdsEnsureCovers()
            -- Last, so the continuation decides against the window this fetch
            -- just saved and a view it has already rebuilt. Gated on liveness
            -- only. NOT on still_here: the whole point of this continuation is
            -- to act on the feed THIS fetch just loaded, which is a DIFFERENT
            -- feed from the one on screen when the tap fired (tapping an
            -- uncached category fetches the child feed while the parent is
            -- still shown, then drills in). still_here compares the on-screen
            -- feed to the fetched one, so it is always false here and
            -- suppressed the drill entirely -- the reported "have to tap the
            -- category twice" (first tap fetched, second drilled). The narrow
            -- case it guarded (user navigates away during a Wi-Fi prompt, then
            -- gets drilled) is rare and Back-recoverable; correctness of the
            -- common one-tap drill wins.
            if on_done and BookshelfWidget.live == self then
                on_done()
            end
        end)
    end)
end

-- _opdsWalkToEnd() - "last page" on a feed whose length nobody knows.
--
-- The footer can only offer a jump when there is a known last page to jump to.
-- On an OPDS feed there usually is not: totalResults is absent or a lie (see
-- OpdsWindow.slice), so the page count is a lower bound and the chevron used
-- to be disabled. Walking the chain is the only way to answer the question, so
-- that is what this does - unbounded, because a cap cannot answer "where does
-- it end", and stoppable, because an unbounded walk that could not be stopped
-- would be a trap.
--
-- Landing is the same for all three outcomes - reached the end, hit an error,
-- reader stopped it - because all three mean the same thing to someone looking
-- at a shelf: put me on the last page that has books.
function BookshelfWidget:_opdsWalkToEnd()
    local tab = self:_opdsEffectiveTab()
    if not tab or not tab.source or tab.source.kind ~= "opds" then return end
    local OpdsSource = require("lib/bookshelf_opds_source")
    local OpdsWindow = require("lib/bookshelf_opds_window")
    local server = OpdsSource.getServer(tab.source.id)
    if not server then return end
    local feed_url = tab.source.feed_url or server.url
    self:_opdsFetchMore(tab, FETCH_ALL, false, function()
        -- Counted back out of storage rather than captured before the walk:
        -- what landed is the only thing that decides where the reader goes,
        -- and the walk may have stopped anywhere.
        local n     = OpdsWindow.count(tab.source.id, feed_url)
        local view  = self:_viewSize() or 1
        local pages = math.max(1, math.ceil(n / view))
        self._cursor = (pages - 1) * view + 1
        self:_syncPageFromCursor()
        -- Armed, as every other page change arms it. _opdsAfterPage returns at
        -- its first line without it, so the page this lands on got no cover or
        -- nav-resolve pass at all: on a catalog that models each book as a
        -- one-entry subcatalog (Gutenberg does) the last page stayed a grid of
        -- unresolved folders until the reader paged away and back. There is no
        -- risk of it spending itself on a fetch - the walk it follows has just
        -- filled the window, so the page is usable and the silent branch takes
        -- it straight to the cover pass.
        self:_markOpdsNav()
        self:_swapShelvesInPlace()
    end)
end

-- Swipe-down on an OPDS view: re-fetch the feed from the start, replacing
-- the cached window only if the fetch succeeds (see _opdsFetchMore's
-- replace mode -- the old window survives a declined Wi-Fi prompt or a
-- dead server untouched).
--
-- `tab` is the tab-LIKE _opdsEffectiveTab hands back, so a swipe-down inside a
-- drilled navigation entry re-pulls THAT subcatalog, not the chip's root feed.
-- No liveness guard of its own: this runs synchronously off the gesture and
-- everything deferred past a Wi-Fi prompt happens inside _opdsFetchMore, which
-- carries the guard.
function BookshelfWidget:_opdsRefresh(tab)
    local OpdsSource = require("lib/bookshelf_opds_source")
    local server = OpdsSource.getServer(tab.source.id)
    if not server then return end
    -- The one path that reaches _opdsFetchMore without passing _opdsAfterPage's
    -- busy branch, so it needs its own check against a modal download holding
    -- Trapper. Reachable: the download's Trapper:info yields, and a swipe
    -- queued behind the blocking transfer is delivered in that window (the
    -- progress InfoMessage catches taps, not swipes), landing here while the
    -- download's coroutine is very much alive.
    --
    -- Deliberately narrower than _opdsFetchBusy: a swipe-down during a FEED
    -- fetch stays allowed exactly as it always has been -- that exemption is
    -- the whole point of the explicit refresh -- and _opdsFetchMore's own
    -- marker handling covers it. Narrower in WHICH marker it reads, not in how
    -- it reads it: _opdsDownloadBusy applies the same 120s expiry every other
    -- reader gets, so a wedged marker can't leave refresh permanently dead.
    if self:_opdsDownloadBusy() then
        UIManager:show(require("ui/widget/notification"):new{
            text = _("The catalog is busy. Try again in a moment."),
        })
        return
    end
    -- Deliberately does NOT arm the nav flag: this calls _opdsFetchMore
    -- directly, so the gate has nothing to gate, and leaving it disarmed keeps
    -- the fetch's own tail rebuild passive (one cover pass, no second fetch).
    self:_opdsFetchMore(tab, self:_opdsBatchSize(), true)
end

-- Gap between one background page fetch and the next. Not a throttle on the
-- server -- the fetches are serial anyway -- but the window in which UIManager
-- gets to process input, so a page turn lands promptly instead of queueing
-- behind the rest of the page's work. 0.2s is opds_plus's ImageLoader interval.
local OPDS_COVER_TICK = 0.2
-- Items to let land before repainting. Every repaint is a full _rebuild and,
-- on e-ink, a visible flash; painting per item costs more than it buys.
local OPDS_COVER_REBUILD_EVERY = 4

-- ...EXCEPT THE FIRST ONE. Waiting for a full batch means nothing appears
-- until the second round of fetches lands - measured at roughly 2.5s on device
-- with three workers at ~1.3s a cover - so a new page sat blank and then
-- filled all at once. The first cover is the one that says "this is working",
-- and it earns a repaint on its own; after that the batch cadence takes over
-- and the rest arrive together anyway.
-- Ramped, not a flat batch: 1, then 2, then the full cadence. The first cover
-- says "this is working", the next couple keep saying it while the pipeline
-- warms, and only once several are already on screen does batching take over
-- to stop a full _rebuild (measured 141-887ms) running per cover. A flat
-- cadence made a page arrive in one lump; a flat 1 would spend more of the UI
-- thread repainting than fetching ever did.
local function _opdsPaintThreshold(painted)
    painted = painted or 0
    if painted < 1 then return 1 end
    if painted < 3 then return 2 end
    return OPDS_COVER_REBUILD_EVERY
end

-- _storeChildFeed(server_key, feed_url, body) -> did anything get cached
-- Parse a nav tile's child feed and persist it as that feed's window. That is
-- the whole of "resolving" a folder: the repo's opds branch already flattens a
-- cached single-book child into the book at render time, so populating the
-- cache is all this has to do.
--
-- Returns false for a body that parsed to nothing usable, and stores nothing in
-- that case, so a throttled or error page leaves the tile unresolved and
-- retryable rather than caching an empty window that would read as "fetched,
-- genuinely empty" forever. Restored from 1477764^ unchanged; it was never the
-- part that failed.
local function _storeChildFeed(server_key, feed_url, body)
    if type(body) ~= "string" or body == "" then return false end
    local OpdsFeed   = require("lib/bookshelf_opds_feed")
    local OpdsWindow = require("lib/bookshelf_opds_window")
    local catalog = OpdsFeed.parse(body)
    local mapped = catalog and OpdsFeed.mapEntries(catalog, feed_url, server_key)
    if not (mapped and (#mapped.records > 0 or mapped.next_url)) then return false end
    local win = OpdsWindow.load(server_key, feed_url)
    win.fetched_at = os.time()
    OpdsWindow.appendPage(win, mapped)
    OpdsWindow.save(server_key, feed_url, win)
    return true
end

-- _storeFeedPage(server_key, store_url, fetched_url, body) -> did records land
-- Append the NEXT page of a feed to that feed's own window.
--
-- Sibling of _storeChildFeed, and separate from it for two reasons. The window
-- is keyed by the feed the user is LOOKING at (store_url) while the body came
-- from its rel=next (fetched_url), and mapEntries has to resolve relative
-- hrefs against the url the body actually came from - passing one for both
-- would either file the page under the wrong key or resolve its links against
-- the wrong base.
--
-- fetched_at is deliberately NOT touched. It records when this feed was last
-- REFRESHED, which is what the five-minute expiry reads; appending page seven
-- does not make page one any newer, and stamping it here would let a deep
-- crawl hold a stale first page fresh forever.
local function _storeFeedPage(server_key, store_url, fetched_url, body)
    if type(body) ~= "string" or body == "" then return false end
    local OpdsFeed   = require("lib/bookshelf_opds_feed")
    local OpdsWindow = require("lib/bookshelf_opds_window")
    local catalog = OpdsFeed.parse(body)
    local mapped = catalog and OpdsFeed.mapEntries(catalog, fetched_url, server_key)
    if not (mapped and (#mapped.records > 0 or mapped.next_url)) then return false end
    local win = OpdsWindow.load(server_key, store_url)
    local before = win.count or 0
    OpdsWindow.appendPage(win, mapped)
    OpdsWindow.save(server_key, store_url, win)
    return (win.count or 0) > before
end

-- _opdsNavResolveQueue(records, chip) -> { work items }, { skip set }
-- Nav tiles on this page whose child feed has never been fetched. The skip set
-- is those same tiles keyed by filepath, so the cover queue can leave them
-- alone: resolving one turns it into a book whose cover comes from the CHILD
-- feed, so fetching the tile's own thumbnail first is a download spent on a
-- tile that is about to stop existing.
--
-- Credentials are resolved here rather than at fetch time, and gated on
-- sameOrigin exactly as the feed fetch and the cover fetch are: a nav href came
-- out of the server's XML and could name any host.
local function _opdsNavResolveQueue(records, chip)
    local OpdsWindow = require("lib/bookshelf_opds_window")
    local OpdsSource = require("lib/bookshelf_opds_source")
    local OpdsFeed   = require("lib/bookshelf_opds_feed")
    local Prefs      = require("lib/bookshelf_opds_prefs")
    local timeouts   = Prefs.timeouts(chip)
    local queue, skip = {}, {}
    for _i, rec in ipairs(records) do
        if rec.is_opds_nav and rec.opds and rec.opds.feed_url
                and type(rec.filepath) == "string" then
            local sk = rec.filepath:match("^OPDS://([^/]+)/")
            if sk then
                -- fetched_at is the self-limiting signal: a resolved child
                -- window persists, so a multi-item folder is fetched once,
                -- stays a folder, and is never fetched again. Without it this
                -- would re-fetch every folder on every pass.
                -- A tile that TELLS US it holds more than one item cannot be
                -- the one-book folder this is looking for, so fetching it can
                -- never change how it renders. Internet Archive's category
                -- tiles declare ~10000 apiece, and resolving eight of them cost
                -- 13 seconds on device for no visual change whatsoever.
                -- Unknown count still gets fetched -- most catalogs say
                -- nothing, and those are exactly the ones worth asking.
                local declared = tonumber(rec.nav_item_count)
                local one_book_possible = not declared or declared <= 1
                local win = OpdsWindow.load(sk, rec.opds.feed_url)
                if one_book_possible and (win.fetched_at or 0) <= 0 then
                    local server = OpdsSource.getServer(sk)
                    if server then
                        local same = OpdsFeed.sameOrigin(server.url, rec.opds.feed_url)
                        queue[#queue + 1] = {
                            kind       = "resolve",
                            server_key = sk,
                            feed_url   = rec.opds.feed_url,
                            user       = same and server.username or nil,
                            password   = same and server.password or nil,
                            timeouts   = timeouts,
                        }
                        skip[rec.filepath] = true
                    end
                end
            end
        end
    end
    return queue, skip
end

-- _opdsResolvedCoverItem(server_key, feed_url) -> queue item | nil
-- The cover work a just-resolved folder created, ready to append to the queue
-- that is still running.
--
-- Resolving a one-book folder turns a tile into a BOOK, and that book has a
-- cover the queue was built before anyone knew about. The chain used to learn
-- this only at its very end, by re-arming and recomputing from the new page
-- shape - so on a catalog where every tile is a folder (Gutenberg's shape, and
-- ManyBooks'), not one cover could be fetched until the LAST resolve came
-- back. Twelve resolves at a second or two each is a shelf that stays blank
-- for the whole chain and then fills at once.
--
-- Appending here instead means the first resolve's cover is in flight while
-- the eleventh is still resolving: same requests, same order, but the page
-- starts filling seconds in. The tail re-arm stays as the backstop for
-- everything this cannot see (a resolved folder holding several books whose
-- own covers are wanted).
--
-- opdsLoneChildBook is the same predicate the render path flattens with, so
-- what gets queued here is exactly the record the next repaint will paint --
-- nil for a folder that turned out to hold more than one book, which correctly
-- stays a folder and has no cover of its own to fetch.
local function _opdsResolvedCoverItem(server_key, feed_url)
    local ok, lone = pcall(Repo.opdsLoneChildBook, server_key, feed_url)
    if not (ok and type(lone) == "table") then return nil end
    local OpdsCovers = require("lib/bookshelf_opds_covers")
    if not OpdsCovers.cachePath(lone) then return nil end
    if not OpdsCovers.needsFetch(lone) then return nil end
    return { kind = "cover", rec = lone }
end

-- Cover fill for an OPDS page. OFF by default and per catalog: the shelf does
-- NOT bulk-download remote cover images unless the chip asks it to.
--
-- Why the default is off. A full page of remote covers is a serial blocking
-- download; over a slow public catalog it made paging feel stuck, and the
-- covers themselves are often heavy. So the shelf shows the title+author
-- placeholder card and a cover is fetched only when a book is TAPPED
-- (_opdsFetchDetailCover, for the detail modal), which then also lands it on
-- that shelf cell on the next rebuild.
--
-- Why it is now switchable. That reasoning is about PUBLIC catalogs. On a
-- server on your own network the covers are a few milliseconds away and the
-- placeholders are just worse, and two users have now read tap-only covers as
-- the feature being broken. The batching, token and re-arm machinery below is
-- unchanged from when this ran unconditionally, so the opt-in path is the one
-- that was already proven on device rather than a fresh one.
-- Despite the name this drives ALL background page work, covers and nav-tile
-- resolution alike: one queue, one token, one abandon path, so the two can
-- never race each other or double the fetches in flight. Kept as the name every
-- render path already calls.
function BookshelfWidget:_opdsEnsureCovers()
    -- Effective, not active: a drilled navigation entry renders remote records
    -- exactly like the chip's root feed does, so its thumbnails have to fill
    -- too. Non-OPDS views resolve to nil and bail here as before.
    if not self:_opdsEffectiveTab() then return end
    -- The chip, not the effective tab: a drilled subcatalog's stand-in carries
    -- no settings (see _opdsPrefsTab), and the catalog's choice governs its
    -- subcatalogs too.
    local Prefs = require("lib/bookshelf_opds_prefs")
    local chip  = self:_opdsPrefsTab()
    local want_covers  = Prefs.autoCovers(chip)
    local want_resolve = Prefs.resolveNav(chip)
    if not (want_covers or want_resolve) then return end
    local records = self._page_items
    if not records then return end
    -- Offline (or Wi-Fi off): skip rather than let each miss block the main
    -- loop on a socket timeout. isConnected() answers true on platforms with
    -- no Wi-Fi toggle, so desktop builds still fill their thumbnails. Never
    -- prompts -- a passive cover fill must not raise a Wi-Fi dialog.
    local ok_net, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_net and NetworkMgr and NetworkMgr.isConnected
            and not NetworkMgr:isConnected() then
        return
    end
    -- "Missing" = has a thumbnail worth fetching (cachePath resolves - a
    -- deterministic name, no disk check) AND the repo did NOT already attach
    -- the record's OWN cover_image_path for it. The repo already did the one
    -- lfs stat per record this pass needs (OpdsCovers.cachedPath, inside
    -- getBySource); a second `not rec.has_cover` gate here would re-select
    -- every record on every pass, because the repo never sets has_cover for
    -- OPDS records (see the cover_image_path comment there) --
    -- rec.cover_image_path is the up-to-date signal instead.
    --
    -- rec.cover_borrowed is the exception: a nav tile with none of its own
    -- artwork yet borrows a child feed's cached cover so it isn't a bare
    -- placeholder (see the borrow in bookshelf_book_repository.lua's opds
    -- branch), but that borrow is not the tile's own download landing. Without
    -- also selecting borrowed records here, the borrow's non-nil
    -- cover_image_path would permanently look "already fetched" and the
    -- tile's own cover would never enter fetchMissing -- borrowed forever,
    -- never self-healing even once the tile's own artwork appears on disk.
    -- Once it does, the repo's own-cover check (which runs first and wins)
    -- fills cover_image_path from the tile's own cachedPath and leaves
    -- cover_borrowed unset, so this stops selecting it on the very next pass.
    local OpdsCovers = require("lib/bookshelf_opds_covers")
    -- The resolve queue is BUILT first, because it decides which tiles the
    -- cover queue must skip -- but COVERS RUN FIRST.
    --
    -- They used to run second, on the reasoning that resolution changes the
    -- page shape so covers should follow it. That reasoning is already
    -- satisfied by the skip set: a tile queued for resolution is excluded from
    -- the cover queue, so every cover in it is one the page wants whatever
    -- resolution does. Meanwhile the cost of going second was severe and
    -- measured: on a page of folder tiles the whole first chain was eight nav
    -- fetches at 1.0-3.6s each, nine seconds that landed ZERO covers, and only
    -- the re-armed second chain fetched any. The shelf sat blank throughout
    -- and then filled at once.
    --
    -- Covers first means something appears in about a second, and the folder
    -- resolution -- which changes tiles the user can already see and read --
    -- happens behind it.
    -- The skip set the builder also returns is deliberately NOT taken: nav
    -- tiles now get their own thumbnail fetched as well as being resolved
    -- (see the cover queue below for the measurement that changed this).
    local resolve_queue = {}
    if want_resolve then
        resolve_queue = _opdsNavResolveQueue(records, chip)
    end
    local queue = {}
    if want_covers then
        for _i, rec in ipairs(records) do
            if rec.is_remote and (not rec.cover_image_path or rec.cover_borrowed)
                    and OpdsCovers.cachePath(rec) then
                    -- NOT skipped when the tile is also queued for resolution.
                    --
                    -- It used to be, to avoid downloading a thumbnail that
                    -- resolution might supersede. Measured cost of that
                    -- optimisation on device: a ManyBooks-style catalog is
                    -- ENTIRELY nav tiles, so the skip emptied the cover queue,
                    -- and the shelf sat blank for the whole eight-second
                    -- resolve chain before the re-arm fetched anything at all.
                    --
                    -- Those tiles carry their own thumbnails, and on the
                    -- catalogs that present each book as a folder that
                    -- thumbnail IS the book's cover - so fetching it shows the
                    -- right image about a second in, and resolution then
                    -- changes what the tile IS behind an already-populated
                    -- shelf. The waste is one image per tile whose resolved
                    -- book turns out to have a different cover url, which is
                    -- cheap and cached either way.
                queue[#queue + 1] = { kind = "cover", rec = rec }
            end
        end
    end
    for _i, item in ipairs(resolve_queue) do queue[#queue + 1] = item end
    -- FIRST in the queue, not last.
    --
    -- Last was the intuitive order - the page in front of the user matters
    -- more than the one after it - and it meant the item never ran at all. On
    -- Internet Archive a cover takes 3-5 seconds, so a chain of ten covers
    -- outlives the reader: they page before the queue reaches its final item,
    -- the token bumps, and the pool kills a lookahead that never started. The
    -- log said so plainly - the decision to fetch was made three times and not
    -- one kind=page worker was ever launched - while the blocking fetch it
    -- exists to prevent ran five seconds later every time.
    --
    -- Ordering only bites when the queue is longer than the pool is wide, and
    -- at ten wide a page of covers plus this one item nearly all start in the
    -- first wave anyway. So the real cost of going first is at most one cover
    -- deferred by one wave, against a modal progress dialog avoided.
    local ahead = self:_opdsLookaheadItem()
    if ahead then table.insert(queue, 1, ahead) end
    -- Bumped BEFORE the empty early return, not after it: an earlier chain may
    -- still be in flight for a page the user has since left, and if this pass
    -- returns without moving the token that chain still matches on completion
    -- and repaints a page it knows nothing about. Harmless as repaints go, but
    -- the guard is meant to be exact -- reaching this line at all means "the
    -- current page's background work is now this pass's business".
    self._opds_cover_token = (self._opds_cover_token or 0) + 1
    if #queue == 0 then return end
    local token = self._opds_cover_token
    UIManager:scheduleIn(OPDS_COVER_TICK, function()
        -- Teardown guard: the widget can be closed inside the window, and a
        -- blocking fetch against a torn-down shelf is pure waste. Same liveness
        -- test onCloseWidget maintains for _cover_settle_cb.
        if BookshelfWidget.live ~= self then return end
        -- Superseded guard: if the user paged (or drilled) within the window,
        -- a newer pass has bumped the token and owns the page now.
        if token ~= self._opds_cover_token then return end
        -- want_covers travels with the chain: a resolve that lands mid-run
        -- wants to queue the resolved book's cover, and on a catalog set to
        -- tap-only covers it must not. So does the pool width, resolved off
        -- the chip here rather than read again deeper in - a drilled
        -- subcatalog's stand-in carries no settings.
        self:_opdsCoverPool(queue, token,
                            { creds = {}, landed = 0, painted = 0, resolved = 0,
                              want_covers = want_covers,
                              concurrency  = Prefs.concurrency(chip) })
    end)
end

-- How many background page fetches may be in flight at once is a PER-CATALOG
-- setting now (Prefs.concurrency / CONCURRENCY_OPTIONS, where the measurement
-- and the throttling history that set the default live). The chain carries the
-- resolved number on its state, so there is no second copy of it here to drift
-- out of step with the option list.
--
-- How far ahead of the cursor the cached window is kept, in screenfuls.
--
-- FIVE, raised from two once storage stopped costing anything. Appending a
-- page was 399ms of whole-store re-serialisation and is now about 1ms of
-- INSERT, so the only remaining cost of reading ahead is the round trip - and
-- that already happens in a forked worker that a page turn kills.
--
-- Why depth rather than bigger pages: the server decides page size and will
-- not be told otherwise. Measured - Gutenberg serves 25 and ignores count,
-- limit, length, per_page, page_size and items; Internet Archive returns
-- byte-identical responses for all of those and declares itemsPerPage 25 in
-- the feed itself. So the only lever the client has is how many pages it asks
-- for, and how quietly.
--
-- The walk stays sequential because it must: a page's url exists only in the
-- previous page's rel=next, so there is nothing to parallelise within one
-- feed. Each landed page queues the next, in the pool, until the depth is
-- satisfied.
local OPDS_LOOKAHEAD_VIEWS = 5
-- Ceiling on requests one lookahead run may spend, whatever the arithmetic
-- says. A server that serves two records a page would otherwise turn five
-- screens into fifty round trips; the reader gets what this buys and the rest
-- arrives on the next render.
local OPDS_LOOKAHEAD_MAX_REQUESTS = 6

-- _opdsLookaheadItem() -> a "page" work item, or nil.
--
-- The second attempt at keeping a screen in hand. The first drove
-- _opdsFetchMore, which is the USER-FACING fetch - Trapper, a modal progress
-- line that yields for input, and a tail that re-clamps the cursor - so it
-- blocked input on a page already delivered and moved the shelf under a swipe
-- in flight.
--
-- This one rides the cover pool instead, which is already everything a
-- background fetch has to be: the request happens in a forked child so the UI
-- thread never blocks, the parent only parses and appends, a page turn kills
-- the workers via the token, and nothing it does touches the cursor or shows
-- a widget. Appending to the window is invisible until the user pages into it.
--
-- Declines whenever the answer might be someone else's: no rel=next (the feed
-- is complete), the window is already deep enough, or a user-facing fetch
-- holds the marker.
function BookshelfWidget:_opdsLookaheadItem()
    local tab = self:_opdsEffectiveTab()
    if not tab then return nil end
    if self:_opdsFetchBusy() then return nil end
    local server_key, feed_url = self:_opdsFeedRef(tab)
    if not server_key then return nil end
    local ok_w, OpdsWindow = pcall(require, "lib/bookshelf_opds_window")
    if not ok_w then return nil end
    local win = OpdsWindow.load(server_key, feed_url)
    if not win then return nil end
    -- Follow the chain when we have it. When we do not AND the feed has never
    -- been seen to end, the chain is LOST rather than finished, so start again
    -- from the top - the same rule the user-facing walk uses. Dedupe is a
    -- unique index, so re-treading a known page adds nothing twice and
    -- restores the next link for the run after this one.
    --
    -- Returning nil here instead was a dead end: once the top-up went silent
    -- for any page that already had books on it, a feed with no next link had
    -- nothing left that would ever fetch for it, and paging past what it held
    -- showed "no books yet" forever.
    local fetch_url = OpdsWindow.fetchUrl(win, feed_url)
    if not fetch_url then return nil end
    -- A catalog that has just refused us gets no BACKGROUND traffic until its
    -- window reopens. The lookahead is worth up to OPDS_LOOKAHEAD_MAX_REQUESTS
    -- on its own, and a server capped at three (Calibre-Web Automated, issue
    -- 434) never recovers while we keep spending the window we are waiting on
    -- -- which is what turned one refusal into a permanently empty shelf.
    -- A user-initiated fetch is deliberately NOT gated: someone pulling to
    -- refresh has asked for one request, and it is how we find out the window
    -- has reopened.
    local ok_rl, paced = pcall(function()
        return require("lib/bookshelf_opds_feed").paceFor(fetch_url)
    end)
    if ok_rl and type(paced) == "number" and paced > 0 then
        logger.dbg(string.format(
            "[bookshelf perf] opds lookahead: declined, origin paced at %.1fs",
            paced))
        return nil
    end
    local have = win.count or 0
    local view = self:_viewSize() or 24
    local want = math.max(0, (self._cursor or 1) - 1)
                 + view * OPDS_LOOKAHEAD_VIEWS
    -- Cost the depth in REQUESTS, from the page size the server declared
    -- (itemsPerPage). It is the only thing the server lets us know about its
    -- pagination - it will not accept a page size, but it will tell us one -
    -- and without it a depth of five screens is an unknown number of round
    -- trips: four against a server serving 25, fifty against one serving two.
    --
    -- Capped so one run can never turn into a crawl. Whatever the cap leaves
    -- unfetched, the next render asks for again, so depth is still reached -
    -- just in bounded bites, with a page turn free to cancel between them.
    local per_page = win.items_per_page
    local plan = OPDS_LOOKAHEAD_MAX_REQUESTS
    if per_page and per_page > 0 and have < want then
        plan = math.min(plan, math.max(1, math.ceil((want - have) / per_page)))
    end
    logger.dbg(string.format(
        "[bookshelf perf] opds lookahead: have=%d want=%d cursor=%s view=%d "
        .. "per_page=%s plan=%d next=%s decision=%s",
        have, want, tostring(self._cursor), view, tostring(per_page), plan,
        tostring(win.next_url ~= nil), have >= want and "deep enough" or "FETCH"))
    if have >= want then return nil end
    local ok_s, OpdsSource = pcall(require, "lib/bookshelf_opds_source")
    if not ok_s then return nil end
    local server = OpdsSource.getServer(server_key)
    if not server then return nil end
    -- Credentials gated on same-origin exactly as the cover and resolve
    -- fetches are: a rel=next came out of the server's own feed and could
    -- name any host.
    local ok_f, OpdsFeed = pcall(require, "lib/bookshelf_opds_feed")
    local same = ok_f and OpdsFeed.sameOrigin(server.url, fetch_url)
    local Prefs = require("lib/bookshelf_opds_prefs")
    return {
        kind       = "page",
        plan       = plan,          -- requests this run may spend
        server_key = server_key,
        feed_url   = feed_url,        -- where the records are FILED
        fetch_url  = fetch_url,       -- where the body comes FROM
        user       = same and server.username or nil,
        password   = same and server.password or nil,
        timeouts   = Prefs.timeouts(self:_opdsPrefsTab()),
    }
end

-- How often the parent checks its workers. Short enough that a finished
-- download lands promptly, long enough that polling is not itself the cost.
local OPDS_POOL_POLL = 0.15

-- How many times a REFUSED item goes back on the queue before it is given up
-- on. A refusal is not a failure of the request -- the same url will work
-- shortly -- so it is worth re-queueing, at the paced rate. Bounded so a
-- server that refuses everything ends the run rather than cycling forever;
-- three is enough to ride out a burst against a small window without the
-- run outliving the page it belongs to.
local OPDS_REFUSED_RETRIES = 3

-- _opdsCoverPool(queue, token, state) - run the queue through forked workers
-- instead of one blocking fetch per tick.
--
-- Same contract as _opdsCoverStep, which it replaces when forking is available:
-- same queue of typed items, same token, same abandon-on-supersede, same
-- repaint cadence, same re-arm when something resolved. ONLY the fetching
-- moves off the UI thread - which is the whole point, because the fetching is
-- what was blocking it.
--
-- Each worker does exactly one item and reports through its pipe. A cover
-- worker writes the image to the cache path itself and pipes back only
-- "1"/"" - piping the bytes would mean holding a whole image in the parent to
-- write it out again. A resolve worker pipes its feed body, because the parent
-- is the one that must parse and store it (the child's memory is discarded).
--
-- Falls back to the sequential chain when forking is unavailable (Android) or
-- a fork fails mid-run, so no platform loses the feature.
function BookshelfWidget:_opdsCoverPool(queue, token, state)
    local ok_ffi, ffiutil = pcall(require, "ffi/util")
    if not (ok_ffi and ffiutil and ffiutil.runInSubProcess) then
        return self:_opdsCoverStep(queue, 1, token, state)
    end
    local OpdsCovers = require("lib/bookshelf_opds_covers")
    local OpdsFeed   = require("lib/bookshelf_opds_feed")
    -- The pool's width. Starts at the measured opening bid and NARROWS on
    -- failure: halve on any timeout or error, floor of 1, and never widen
    -- again for the life of this chain.
    --
    -- Measurement says 10 scales cleanly on a healthy catalog and 16 collapses
    -- (see Prefs.CONCURRENCY). But only one catalog was reachable to measure,
    -- and the one that ISN'T -- Internet Archive -- is the one with a
    -- throttling history: an always-wide pool was removed once (1477764)
    -- because public catalogs answered a burst with half-filled pages. A fixed
    -- number cannot be right for both, so the pool watches what it gets back
    -- instead of trusting the constant.
    --
    -- Narrowing only, deliberately. Recovering mid-chain would re-widen into a
    -- server that has just said no, and a chain is one page of covers - the
    -- next page opens at full width again, so a server that was briefly busy
    -- is not punished for the rest of the session.
    local cap = state.concurrency
                or require("lib/bookshelf_opds_prefs").CONCURRENCY
    local next_i, in_flight, fork_broken = 0, {}, false
    state.t_begin = state.t_begin or _gettime()
    state.t_fetch = state.t_fetch or 0
    state.t_paint = state.t_paint or 0
    state.n_fetch = state.n_fetch or 0

    -- How long to leave between launches, and when the next one may go. Zero
    -- for every healthy catalog. Seeded from what this origin has already
    -- taught us, so page two does not re-burst and learn it again -- which
    -- was the other half of why a capped server never recovered (issue 434).
    local pace, next_launch_at = 0, 0
    do
        local probe = queue[1]
        local u = probe and (probe.fetch_url or probe.feed_url or probe.cover_url)
        if u then pcall(function() pace = OpdsFeed.paceFor(u) or 0 end) end
        if pace > 0 then
            cap = 1
            logger.dbg(string.format(
                "[bookshelf perf] opds pool: origin known slow, opening at cap=1 pace=%.1fs",
                pace))
        end
    end

    local function stillCurrent()
        return BookshelfWidget.live == self and token == self._opds_cover_token
    end
    local function paint(why)
        if not stillCurrent() then return end
        local t0 = _gettime()
        self:_rebuild()
        UIManager:setDirty(self, "ui")
        local ms = (_gettime() - t0) * 1000
        state.t_paint = state.t_paint + ms
        logger.dbg(string.format(
            "[bookshelf perf] opds pool repaint: %s rebuild+dirty=%.0fms", why, ms))
    end
    -- A worker whose output we read while it was still alive must still be
    -- reaped, or it lingers as a zombie for the rest of the session.
    local function collectLater(pid)
        local c
        c = function()
            if not ffiutil.isSubProcessDone(pid) then
                UIManager:scheduleIn(1, c)
            end
        end
        UIManager:scheduleIn(1, c)
    end
    local function launch(item)
        local payload
        if item.kind == "resolve" or item.kind == "page" then
            -- Both are "fetch a feed body and hand it back for the parent to
            -- parse". The child's memory is discarded, so it cannot store
            -- anything itself.
            payload = function(_pid, fd)
                local body, err = OpdsFeed.fetch(item.fetch_url or item.feed_url,
                                                 item.user, item.password,
                                                 item.timeouts)
                -- A refused worker has to SAY it was refused. The child's
                -- memory is discarded, so the back-off it recorded dies with
                -- it, and an empty pipe is indistinguishable from a timeout
                -- or an error page -- which the parent answers by narrowing
                -- and carrying on, i.e. by spending more of the window the
                -- server just asked us to stop spending (issue 434).
                if not body and err == "ratelimited" then
                    ffiutil.writeToFD(fd, OpdsFeed.RATE_LIMIT_MARKER, true)
                    return
                end
                ffiutil.writeToFD(fd, body or "", true)
            end
        else
            -- Plan resolved in the PARENT so the child cannot disagree about
            -- which url this cover is, where it caches, or whether credentials
            -- may travel to it (see OpdsCovers.fetchPlan).
            local plan = OpdsCovers.fetchPlan(item.rec, state.creds)
            if not plan then return false end
            -- Where this cover comes from, kept on the ITEM so the collector
            -- can attribute a refusal to an origin. A cover item carries no
            -- fetch_url or feed_url -- only the plan knows the url, and the
            -- plan does not survive into the parent's collect loop, so
            -- without this a refused cover recorded a back-off against nil
            -- and the pause was never taken.
            item.cover_url = plan.url
            payload = function(_pid, fd)
                local CoverFetch = require("lib/bookshelf_cover_fetch")
                local got, err = CoverFetch.download(plan.url, plan.path, plan.user,
                                                     plan.password, plan.net_opts)
                -- Covers are where a capped server actually says no: a page
                -- of twenty books is twenty requests, against a root feed
                -- that is one. Reporting a refusal as a plain failure here
                -- left the back-off never triggered at all, so the run was
                -- narrowed rather than paused and the covers that had been
                -- refused were simply dropped (issue 434).
                if not got and err == "ratelimited" then
                    ffiutil.writeToFD(fd, OpdsFeed.RATE_LIMIT_MARKER, true)
                    return
                end
                ffiutil.writeToFD(fd, got and "1" or "", true)
            end
        end
        local pid, rfd = ffiutil.runInSubProcess(payload, true)
        -- fork_broken holds the queue index of the item that failed to
        -- launch: the fallback starts there, so it is fetched, not dropped.
        if not pid then fork_broken = next_i; return false end
        in_flight[#in_flight + 1] =
            { pid = pid, fd = rfd, item = item, t0 = _gettime() }
        return true
    end
    local function fill()
        -- `pace` is the gap a refused origin has earned. At pace 0 (every
        -- healthy catalog) this loop is exactly what it always was.
        if pace > 0 and _gettime() < next_launch_at then return end
        while #in_flight < cap
                and next_i < #queue and not fork_broken do
            next_i = next_i + 1
            local item = queue[next_i]
            -- Tested POSITIVELY on "cover", not as "anything that is not a
            -- resolve". The negative form silently swallowed every later item
            -- kind: a page item carries no .rec, needsFetch(nil) is false, and
            -- "not false" skipped it as already-cached. The lookahead decided
            -- to fetch on every page turn for a whole session and not one
            -- worker was ever launched. A new kind must never be droppable by
            -- a branch that predates it.
            if item.kind == "cover" and not OpdsCovers.needsFetch(item.rec) then
                -- Already on disk: costs nothing, and must not occupy a worker.
            else
                launch(item)
                if pace > 0 then
                    next_launch_at = _gettime() + pace
                    return          -- one per interval while an origin is slow
                end
            end
        end
    end

    local poll
    poll = function()
        if not stillCurrent() then
            -- Superseded or torn down: kill the workers rather than let them
            -- finish into a page nobody is looking at.
            --
            -- Killing is not collecting. terminateSubProcess sends SIGKILL and
            -- says so in its own comment: "Process will still have to be
            -- collected with calls to util.isSubProcessDone()". Without the
            -- collectLater below, every worker abandoned by a page turn stayed
            -- a ZOMBIE for the rest of the session - four of them were sitting
            -- on the test device, parented to the reader, after an evening's
            -- browsing. Each holds a PID slot and a kernel task struct, and
            -- nothing ever reaps them because this loop is the last thing that
            -- knew the pid.
            for _k, e in ipairs(in_flight) do
                pcall(ffiutil.terminateSubProcess, e.pid)
                if e.fd then pcall(ffiutil.readAllFromFD, e.fd) end
                collectLater(e.pid)
            end
            in_flight = {}
            return
        end
        local still = {}
        for _k, e in ipairs(in_flight) do
            local done     = ffiutil.isSubProcessDone(e.pid)
            local readable = e.fd and ffiutil.getNonBlockingReadSize(e.fd) ~= 0
            if done or readable then
                local out = e.fd and ffiutil.readAllFromFD(e.fd) or ""
                local ms = (_gettime() - e.t0) * 1000
                state.t_fetch = state.t_fetch + ms
                state.n_fetch = state.n_fetch + 1
                -- Refused outright: record the back-off the child could not,
                -- and stop the run. Narrowing is the wrong answer to a 429 --
                -- it keeps going, just more slowly, and every request still
                -- lands inside the window the server is waiting to clear.
                if out == OpdsFeed.RATE_LIMIT_MARKER then
                    -- Refused. SLOW DOWN, do not stop: the queue keeps
                    -- draining, so the covers on the page in front of the
                    -- reader still arrive, just further apart. Abandoning the
                    -- run instead left them stalled until something re-armed
                    -- the chain, and the machinery to un-stall it was more
                    -- code than the problem (issue 434).
                    local refused = e.item.fetch_url or e.item.feed_url
                                    or e.item.cover_url
                    pcall(function() OpdsFeed.notePaced(refused) end)
                    cap = 1
                    pcall(function() pace = OpdsFeed.paceFor(refused) or 0 end)
                    -- PUT IT BACK. Narrowing and pacing only slow down what
                    -- is still queued, and on a full-width pool there is
                    -- nothing left: the queue is one screen of covers, the
                    -- width is ten, so the whole page goes out at once and a
                    -- refused cover is simply lost. Measured on device, three
                    -- landed and seven vanished with the queue already empty
                    -- -- which is the "3 covers then stalls" that survived
                    -- two earlier attempts at this (issue 434).
                    --
                    -- Appending re-opens the loop, because next_i now trails
                    -- #queue again, and the item comes round at the paced
                    -- rate rather than immediately. Bounded, so a server that
                    -- refuses everything ends the run instead of cycling.
                    local tries = (e.item.tries or 0) + 1
                    if tries <= OPDS_REFUSED_RETRIES then
                        e.item.tries = tries
                        queue[#queue + 1] = e.item
                    else
                        logger.dbg("[bookshelf perf] opds pool: giving up on an item after "
                                   .. tries .. " refusals")
                    end
                    logger.dbg(string.format(
                        "[bookshelf perf] opds pool: refused, cap=1 pace=%.1fs requeued=%s",
                        pace, tostring(tries <= OPDS_REFUSED_RETRIES)))
                    out = ""
                end
                -- A worker that SUCCEEDED has to be recorded by the parent.
                -- OpdsFeed.fetch notes it, but that runs in the forked child
                -- whose memory is discarded, so the pacing registry never
                -- heard about any of the pool's successes and an origin that
                -- had been slowed down could never recover -- measured on the
                -- rig, the gap stayed at its 8s ceiling across two successful
                -- requeued fetches (issue 434).
                if out ~= "" and pace > 0 then
                    local ok_u = e.item.fetch_url or e.item.feed_url
                                 or e.item.cover_url
                    if ok_u then
                        pcall(function() OpdsFeed.noteReachable(ok_u) end)
                        pcall(function() pace = OpdsFeed.paceFor(ok_u) or 0 end)
                    end
                end
                -- A worker that came back with nothing is the server saying
                -- no: a timeout, a refused connection, an error page. Halve
                -- and keep going rather than finishing the queue at a width
                -- the server has already rejected.
                if out == "" and cap > 1 then
                    cap = math.max(1, math.floor(cap / 2))
                    logger.dbg("[bookshelf perf] opds pool: narrowing to", cap)
                end
                if e.item.kind == "page" then
                    -- The next page of the feed on screen. Nothing about the
                    -- CURRENT page changes, so this needs no repaint of its
                    -- own; it just means the page after this one is already
                    -- here when the user turns to it. The tail repaint picks
                    -- up the new page count.
                    if out ~= "" and _storeFeedPage(e.item.server_key,
                                                    e.item.feed_url,
                                                    e.item.fetch_url, out) then
                        state.paged = (state.paged or 0) + 1
                        -- Keep walking. The chain is sequential - the next
                        -- url only exists in the page that just landed - so
                        -- depth is reached one request at a time, each queued
                        -- into the pool that is already running. The
                        -- lookahead declines as soon as the window is deep
                        -- enough, which is what ends this.
                        -- Spend no more than this run was budgeted, so a
                        -- server with a tiny page size cannot turn one render
                        -- into a crawl.
                        local budget = e.item.plan or OPDS_LOOKAHEAD_MAX_REQUESTS
                        if (state.paged or 0) < budget then
                            local more = self:_opdsLookaheadItem()
                            if more then
                                queue[#queue + 1] = more
                                logger.dbg(string.format(
                                    "[bookshelf perf] opds pool: reading further ahead (%d/%d)",
                                    state.paged, budget))
                            end
                        end
                    end
                elseif e.item.kind == "resolve" then
                    if out ~= "" and _storeChildFeed(e.item.server_key,
                                                     e.item.feed_url, out) then
                        state.resolved = state.resolved + 1
                        -- Pipeline: this folder is a book now, so its cover
                        -- joins the queue this loop is still draining rather
                        -- than waiting for the whole chain's re-arm.
                        local extra = state.want_covers and _opdsResolvedCoverItem(
                            e.item.server_key, e.item.feed_url)
                        if extra then
                            queue[#queue + 1] = extra
                            logger.dbg(
                                "[bookshelf perf] opds pool: queued resolved cover, "
                                .. #queue .. " item(s) now")
                        end
                    end
                else
                    if out == "1" then state.landed = state.landed + 1 end
                end
                logger.dbg(string.format(
                    "[bookshelf perf] opds pool item: kind=%s %.0fms ok=%s",
                    e.item.kind or "cover", ms, tostring(out ~= "")))
                if not done then collectLater(e.pid) end
            else
                still[#still + 1] = e
            end
        end
        in_flight = still
        fill()
        if state.landed - state.painted >= _opdsPaintThreshold(state.painted) then
            local first = state.painted < 1
            state.painted = state.landed
            paint(first and "first-cover" or "cover-batch")
        end
        if #in_flight > 0 or (next_i < #queue and not fork_broken) then
            UIManager:scheduleIn(OPDS_POOL_POLL, poll)
            return
        end
        if fork_broken then
            -- Forking died mid-run: finish what is left the old way rather
            -- than dropping it, from the item whose launch failed (it may
            -- have been the last).
            local rest = {}
            for i = fork_broken, #queue do rest[#rest + 1] = queue[i] end
            return self:_opdsCoverStep(rest, 1, token, state)
        end
        -- Done.
        -- Sweep on ANY cover having landed, not just unpainted ones: the cache
        -- byte cap is a property of the chain, not of whether its last paint
        -- happened to be owed. Gating it on "unpainted" meant a chain whose
        -- covers were all painted mid-run never enforced the cap at all.
        -- Before the paint, so the shelf renders what survives the sweep.
        if state.landed > 0 then OpdsCovers.sweepCache() end
        if (state.landed > state.painted) or state.resolved > 0
                or (state.paged or 0) > 0 then
            paint("tail")
        end
        local total = (_gettime() - state.t_begin) * 1000
        local tf, tp, nf = state.t_fetch, state.t_paint, state.n_fetch
        logger.dbg(string.format(
            "[bookshelf perf] opds POOL DONE: items=%d fetched=%d landed=%d "
            .. "resolved=%d cap=%d | fetch=%.0fms (%.0fms avg, OFF-THREAD) "
            .. "paint=%.0fms | blocking=%.0fms of %.0fms wall (%.0f%%)",
            #queue, nf, state.landed, state.resolved, cap,
            tf, (nf > 0) and (tf / nf) or 0, tp, tp, total,
            (total > 0) and (tp / total * 100) or 0))
        if state.resolved > 0 then self:_opdsEnsureCovers() end
    end

    fill()
    if #in_flight == 0 and fork_broken then
        return self:_opdsCoverStep(queue, 1, token, state)
    end
    UIManager:scheduleIn(OPDS_POOL_POLL, poll)
end

-- _opdsCoverStep(queue, idx, token, state) - fetch ONE cover, then hand the
-- main loop back before taking the next.
--
-- Replaces a single blocking pass over the whole page. fetchMissing downloads
-- serially with a 20-second budget and nothing yields inside it, so on a slow
-- catalog the shelf froze in 20-second blocks: on Internet Archive, whose
-- cover server has been measured at 8 seconds a request, that is two or three
-- covers per freeze and a page turn that does not register until it ends. This
-- is opds_plus's ImageLoader shape (one image per tick, re-scheduled), which
-- is the model that reads as responsive rather than stuck.
--
-- What this does NOT fix: one cover is still a blocking download, so a single
-- 8-second request still holds the loop for 8 seconds. The per-request
-- timeouts (THUMB_BLOCK/THUMB_TOTAL, 5s/10s) are the ceiling on that. Fixing
-- it properly needs the download off the UI thread entirely, which the forked
-- subprocess pool in b73887b tried and lost to server throttling.
--
-- Guards are re-tested on EVERY tick, not once at the start. The entire point
-- is that the user can act between ticks, and paging is exactly what bumps the
-- token -- so an abandoned chain must notice at its next step rather than run
-- the queue out against a page nobody is looking at.
function BookshelfWidget:_opdsCoverStep(queue, idx, token, state)
    local OpdsCovers = require("lib/bookshelf_opds_covers")
    if BookshelfWidget.live ~= self then return end
    if token ~= self._opds_cover_token then return end
    local item = queue[idx]
    if not item then
        -- Chain complete. Paint whatever landed since the last repaint, and
        -- sweep BEFORE that paint so the shelf renders what is on disk after
        -- the sweep rather than briefly showing a cover the sweep just dropped
        -- (the ordering fetchMissing established).
        -- Sweep on ANY cover having landed (see the pool's tail for why).
        if state.landed > 0 then OpdsCovers.sweepCache() end
        local unpainted = (state.landed > state.painted) or state.resolved > 0
            or (state.paged or 0) > 0
        if unpainted then
            local t0 = _gettime()
            self:_rebuild()
            UIManager:setDirty(self, "ui")
            state.t_paint = (state.t_paint or 0) + (_gettime() - t0) * 1000
        end
        -- The verdict line: where the chain's wall time actually went, and how
        -- much of it blocked the UI thread. fetch >> paint means the downloads
        -- are the problem and belong off-thread; paint >> fetch means they do
        -- not and the repaint strategy is what needs changing.
        if (state.n_fetch or 0) > 0 or (state.t_paint or 0) > 0 then
            local total = (_gettime() - (state.t_begin or _gettime())) * 1000
            local tf, tp, nf = state.t_fetch or 0, state.t_paint or 0, state.n_fetch or 0
            logger.dbg(string.format(
                "[bookshelf perf] opds cover chain DONE: items=%d fetched=%d "
                .. "landed=%d resolved=%d | fetch=%.0fms (%.0fms avg) "
                .. "paint=%.0fms | blocking=%.0fms of %.0fms wall (%.0f%%)",
                #queue, nf, state.landed, state.resolved, tf,
                (nf > 0) and (tf / nf) or 0, tp, tf + tp, total,
                (total > 0) and ((tf + tp) / total * 100) or 0))
        end
        -- Resolution changed the page: folders became books, and those books
        -- have covers of their own that this queue never knew about. ONE re-arm
        -- recomputes from the new page shape and fetches them.
        --
        -- Terminates because both kinds of work are self-limiting: a resolved
        -- child window persists (fetched_at > 0), so the next pass finds nothing
        -- to resolve, and covers that landed are on disk, so needsFetch stops
        -- selecting them. Gated on resolved > 0 so a pass that only fetched
        -- covers does not re-arm at all.
        if state.resolved > 0 then self:_opdsEnsureCovers() end
        return
    end
    -- Per-item timing, split FETCH from REPAINT. The two call for opposite
    -- fixes: if the downloads dominate, moving them off the UI thread is the
    -- answer; if the repaints do, threading changes nothing and the fix is to
    -- stop calling a full _rebuild per batch. Guessing between those is how
    -- this loop has already been rewritten twice.
    local _t_start = _gettime()
    state.t_fetch  = state.t_fetch  or 0
    state.t_paint  = state.t_paint  or 0
    state.n_fetch  = state.n_fetch  or 0
    state.t_begin  = state.t_begin  or _t_start
    local function _paint(why)
        local t0 = _gettime()
        self:_rebuild()
        UIManager:setDirty(self, "ui")
        local ms = (_gettime() - t0) * 1000
        state.t_paint = state.t_paint + ms
        logger.dbg(string.format(
            "[bookshelf perf] opds cover repaint: %s rebuild+dirty=%.0fms", why, ms))
    end
    if item.kind == "resolve" then
        local OpdsFeed = require("lib/bookshelf_opds_feed")
        local _tf = _gettime()
        local body = OpdsFeed.fetch(item.feed_url, item.user, item.password,
                                    item.timeouts)
        local fetch_ms = (_gettime() - _tf) * 1000
        state.t_fetch = state.t_fetch + fetch_ms
        state.n_fetch = state.n_fetch + 1
        logger.dbg(string.format(
            "[bookshelf perf] opds resolve fetch: %.0fms ok=%s %s",
            fetch_ms, tostring(body ~= nil), tostring(item.feed_url)))
        if body and _storeChildFeed(item.server_key, item.feed_url, body) then
            state.resolved = state.resolved + 1
            -- Pipeline, as in the pool: the folder is a book now and its cover
            -- joins the queue still being walked, instead of waiting for the
            -- tail re-arm to discover it.
            local extra = state.want_covers and _opdsResolvedCoverItem(
                item.server_key, item.feed_url)
            if extra then queue[#queue + 1] = extra end
            -- Same cadence as covers, counted separately: resolving four
            -- folders is four tiles changing shape, worth a repaint, and
            -- mixing the two counters would delay whichever is in the minority.
            if state.resolved % OPDS_COVER_REBUILD_EVERY == 0 then
                _paint("resolve-batch")
            end
        end
    elseif item.kind == "page" then
        -- The next page of the feed on screen, as the pool reads it ahead
        -- (this chain is the pool's fallback, and gets its whole queue).
        -- No repaint of its own: the tail picks up the new page count.
        local OpdsFeed = require("lib/bookshelf_opds_feed")
        local _tf = _gettime()
        local body = OpdsFeed.fetch(item.fetch_url or item.feed_url, item.user,
                                    item.password, item.timeouts)
        state.t_fetch = state.t_fetch + (_gettime() - _tf) * 1000
        state.n_fetch = state.n_fetch + 1
        if body and _storeFeedPage(item.server_key, item.feed_url,
                                   item.fetch_url, body) then
            state.paged = (state.paged or 0) + 1
            -- Within this run's budget, as in the pool.
            local budget = item.plan or OPDS_LOOKAHEAD_MAX_REQUESTS
            if state.paged < budget then
                local more = self:_opdsLookaheadItem()
                if more then queue[#queue + 1] = more end
            end
        end
    else
        local rec = item.rec
        -- Already on disk: skip it within THIS tick rather than spending a tick
        -- to discover it. A page whose covers are all cached would otherwise
        -- take a fifth of a second per cell to walk. A Lua tail call, so a long
        -- run of cached records costs no stack.
        if not OpdsCovers.needsFetch(rec) then
            return self:_opdsCoverStep(queue, idx + 1, token, state)
        end
        local _tf = _gettime()
        local got = OpdsCovers.fetchOne(rec, state.creds)
        local fetch_ms = (_gettime() - _tf) * 1000
        state.t_fetch = state.t_fetch + fetch_ms
        state.n_fetch = state.n_fetch + 1
        logger.dbg(string.format(
            "[bookshelf perf] opds cover fetch: %.0fms ok=%s %s",
            fetch_ms, tostring(got), tostring(rec.filepath)))
        if got then
            state.landed = state.landed + 1
            -- Repaint every few covers rather than every one: a full _rebuild
            -- per cover costs more than it buys, and on e-ink every one of them
            -- is a visible flash.
            if state.landed - state.painted >= _opdsPaintThreshold(state.painted) then
                local _first = state.painted < 1
                state.painted = state.landed
                _paint(_first and "first-cover" or "cover-batch")
            end
        end
    end
    UIManager:scheduleIn(OPDS_COVER_TICK, function()
        self:_opdsCoverStep(queue, idx + 1, token, state)
    end)
end

-- _opdsAfterPage(items) - the one post-render hook for an OPDS chip, called
-- from both render paths (_rebuild and the _swapShelvesInPlace page-turn
-- fast path) with the page the repo just handed back. Two jobs:
--
--   * items.opds_needs_fetch: the requested slice ran past the cached window,
--     so pull more feed pages. This covers BOTH "first tap, empty cache"
--     (fetch page 1) and "paged past the window" (fetch the next feed page) --
--     the repo sets the flag for both.
--   * thumbnails for the visible page, off the paint path.
--
-- Both are gated on the one-shot _markOpdsNav flag, which this consumes: a
-- rebuild the user did not ask for renders from the cached window and makes
-- no network call of any kind. That gate doubles as the re-entry guard --
-- a fetch that fails leaves the window short, so opds_needs_fetch is STILL
-- set on the rebuild _opdsFetchMore ends with, and without the gate the hook
-- would spin forever against an unreachable server, one toast per turn. The
-- user re-arms it by turning the page, re-tapping the chip, or swiping down.
--
-- Exactly one path puts the flag back instead of spending it: a fetch for
-- another feed is in flight, so this one is queued rather than run (see the
-- busy branch below). That is a deferral of the user's own navigation, not a
-- flag surviving into an unrelated passive rebuild -- the in-flight fetch's
-- tail rebuild is what picks it up, moments later.
function BookshelfWidget:_opdsAfterPage(items)
    -- One-shot: consumed here whether or not it gets used, so it can never
    -- leak into a later passive rebuild (bar the one queue case above, which
    -- re-arms deliberately and is picked up by the very next rebuild).
    local user_nav = self._opds_nav_pending
    self._opds_nav_pending = nil
    if not user_nav then return end
    -- Which feed the page belongs to, resolved the same way _fetchChipItems
    -- picked what to render: a drilled navigation entry's subcatalog wins over
    -- the chip's own source, and any other drilldown tip (search results, a
    -- folder) means the page on screen isn't a feed's at all -- nil, nothing to
    -- do. Resolved AFTER the one-shot flag is consumed, never before: the
    -- consume must happen on every path through this function or a flag armed
    -- for a rebuild that turned out not to be a feed's would leak into the next
    -- passive one and spend itself on a fetch the user never asked for.
    local tab = self:_opdsEffectiveTab()
    if not tab then
        -- Not looking at a feed (a local chip, a search, a folder drill), so
        -- the next OPDS view is an entry again. Without this, switching to a
        -- local chip and back would read as "still in the same feed" and skip
        -- the age check the user asked for on opening it.
        self._opds_age_checked_key = nil
        return
    end
    -- 120s (see _opdsFetchBusy): comfortably longer than a slow feed page over
    -- 2G-ish Wi-Fi, short enough that a fetch killed by an error (which never
    -- reaches the tail that clears this) unblocks itself well before the user
    -- gives up and swipes down. Overlap protection only -- the explicit
    -- swipe-down refresh calls _opdsFetchMore directly and is never blocked.
    -- A modal download holds the same marker with _opds_fetch_feed left nil,
    -- so it reads here as "another feed is busy" -> the queue branch below.
    local busy = self:_opdsFetchBusy()
    -- ...and busy for WHICH feed. _opds_fetch_feed is the in-flight fetch's own
    -- sameFeed predicate (see _opdsFetchMore), so this compares on the resolved
    -- feed url without re-reading the stock plugin's server list here.
    local busy_this = busy and self._opds_fetch_feed ~= nil
                      and self._opds_fetch_feed(tab)
    -- Age-based refresh: the one automatic refetch the shelf performs, and the
    -- fix for a feed that was otherwise cached until the user found the
    -- swipe-down gesture (issue #321). Off unless the chip asks for it.
    --
    -- Scoped to ENTERING a feed rather than to every navigation gesture, which
    -- is what the setting's own wording ("every time I open it") promises. A
    -- page turn is a nav gesture too, and checking there would refetch from
    -- the top mid-catalog -- and against a server that is down, on every
    -- single turn, which is the retry spin the nav gate exists to stop. Leaving
    -- and coming back re-checks, so a failed refresh is retried when the user
    -- next asks for the feed and not before.
    --
    -- Still inside the user_nav gate above: a passive rebuild (file poll, a
    -- cover landing, startup restore) must never reach the network, and an
    -- expiry rule that fired on those would quietly undo that.
    if not busy and type(items) == "table" then
        local Prefs = require("lib/bookshelf_opds_prefs")
        local chip  = self:_opdsPrefsTab()
        if Prefs.refreshAge(chip) ~= nil then
            local OpdsSource = require("lib/bookshelf_opds_source")
            local OpdsWindow = require("lib/bookshelf_opds_window")
            local _sk, feed_url = self:_opdsFeedRef(tab)
            if feed_url then
                local key = tostring(tab.source.id) .. "|" .. feed_url
                local entering = self._opds_age_checked_key ~= key
                self._opds_age_checked_key = key
                local win = OpdsWindow.load(tab.source.id, feed_url)
                if entering and Prefs.isStale(chip, win.fetched_at, os.time()) then
                    -- replace = true, so the refetch REPLACES the stale window
                    -- rather than topping it up: the whole point is that what
                    -- is cached may be wrong, not merely short. _opdsFetchMore
                    -- keeps the old window if the refetch comes back empty, so
                    -- an expiry against a dead server does not blank the shelf.
                    UIManager:nextTick(function()
                        if BookshelfWidget.live ~= self then return end
                        self:_opdsFetchMore(tab, self:_opdsBatchSize(), true)
                    end)
                    return
                end
            end
        end
    end
    if type(items) == "table" and items.opds_needs_fetch then
        if busy_this then
            -- A fetch for THIS feed is already running and its tail rebuilds
            -- this page. Spending the arm is right here: re-arming would let
            -- that tail fire a second fetch for a feed that just finished one,
            -- which against an unreachable server is exactly the per-turn
            -- retry spin the arm exists to prevent.
            self:_opdsEnsureCovers()
            return
        end
        if busy then
            -- A fetch for a DIFFERENT feed holds the marker. Queue rather than
            -- race, so the automatic paths only ever have one feed fetch in
            -- flight (the explicit swipe-down refresh stays exempt, as it
            -- always has been): Trapper's progress widget is module-level
            -- singleton state (Trapper.current_widget, frontend/ui/trapper.lua).
            -- A second wrapped coroutine's info() closes the first's
            -- InfoMessage and installs its own -- whose dismiss_callback
            -- resumes the WRONG coroutine -- and either one's clear() then
            -- closes the other's widget. A coroutine left suspended that way
            -- never returns from Trapper:wrap's pcalled_func, so its
            -- UIManager:preventStandby() is never balanced by allowStandby():
            -- a device that will not sleep again this session. Not worth two
            -- progress lines.
            --
            -- Queueing means putting the one-shot arm BACK rather than
            -- spending it. The in-flight fetch releases the marker before its
            -- tail rebuild, so that rebuild reaches this function with the arm
            -- still set and no marker held, and starts the fetch there. Before
            -- this, the arm was consumed here and nothing rebuilt afterwards:
            -- a nav-tile tap that landed mid-fetch dead-ended on an empty
            -- subcatalog until the user paged or swiped.
            self._opds_nav_pending = user_nav
            self:_opdsEnsureCovers()
            return
        end
        -- LOUD ONLY WHEN THE SHELF WOULD OTHERWISE BE EMPTY.
        --
        -- _opdsFetchMore is the user-facing fetch: Trapper, a modal progress
        -- line that yields for input, and a tail that re-clamps the cursor.
        -- That is right when the reader is staring at nothing and waiting for
        -- this feed to arrive - a blank shelf with no explanation is worse
        -- than a message.
        --
        -- It is wrong when there are already books on screen. Then the reader
        -- has simply outrun the read-ahead, and interrupting a page they can
        -- already use, to tell them about one they have not asked for yet, is
        -- the "blocking Fetching message" complaint. The silent path handles
        -- it: _opdsEnsureCovers queues the same page fetch into the forked
        -- pool, which repaints when it lands and dies quietly if it does not.
        -- What the READER can see, not what the store holds. A window with
        -- entries can still render an empty page - the cursor sits past them
        -- after a deep restore - and calling that "usable" sent it down the
        -- silent path to stare at "no books yet".
        local have_something = false
        for _i = 1, #(self._page_items or {}) do
            if self._page_items[_i] then have_something = true break end
        end
        if have_something then
            logger.dbg("[bookshelf perf] opds top-up: silent (page already usable)")
            self:_opdsEnsureCovers()
            return
        end
        -- Same offset/limit _fetchChipItems asked the repo for, so want_count
        -- is exactly "enough entries to fill the page being rendered".
        local want = math.max(0, (self._cursor or 1) - 1) + self:_opdsBatchSize()
        UIManager:nextTick(function()
            -- Teardown guard, as in _opdsEnsureCovers: don't open a Wi-Fi
            -- prompt / Trapper progress line for a shelf that has gone away.
            if BookshelfWidget.live ~= self then return end
            self:_opdsFetchMore(tab, want)
        end)
        -- No cover pass here: the page is about to change under us and
        -- _opdsFetchMore runs one against the fuller page. Two passes would
        -- fight over _opds_cover_token -- the first batch's downloads land,
        -- then find their token superseded and skip the repaint.
        return
    end
    self:_opdsEnsureCovers()
end

-- ─── OPDS catalog search ─────────────────────────────────────────────────────
--
-- _opdsOpenSearchDialog(tab, prefill) - the shelf's search entry, pointed at
-- a catalog instead of the local library (see the chip strip's search leg
-- for the routing rule). `tab` is the tab-LIKE _opdsEffectiveTab hands
-- back, so this works from a drilled subcatalog exactly as it does from the
-- chip's root. `prefill` carries text the user already typed elsewhere
-- (the page-jump dialog's Search… button) so it isn't thrown away --
-- parity with `_openSearchDialog`, which already prefills.
--
-- Discovery happens HERE, before the keyboard opens, not on submit: a catalog
-- that cannot be searched should say so while the user's question is still
-- "can I search this?", rather than after they have typed one. Two places to
-- look, in order:
--
--   * the CURRENT feed's window (win.search, captured by mapEntries and
--     persisted by appendPage). A feed that advertises its own search link
--     wins -- on a Calibre-style templated href that link is the feed's own.
--   * the server ROOT window's, when the current feed carries none. Most
--     catalogs advertise the search link on their root document only, so a
--     drilled subcatalog would otherwise have nothing to search with even
--     though the catalog plainly supports it. Both windows are cache reads
--     (OpdsWindow never touches the network), so the fallback costs one
--     settings lookup, not a fetch.
--
-- Neither: say which of the two honest reasons applies. An unseen root window
-- (never fetched, or evicted by OpdsWindow's LRU) means we genuinely do not
-- know whether this catalog offers search, and the fix is to load it; a root
-- we HAVE seen that carries no link is a catalog that really does not offer
-- search, and no amount of waiting will change that.
function BookshelfWidget:_opdsOpenSearchDialog(tab, prefill)
    local OpdsSource   = require("lib/bookshelf_opds_source")
    local OpdsWindow   = require("lib/bookshelf_opds_window")
    local Notification = require("ui/widget/notification")
    local server = OpdsSource.getServer(tab.source.id)
    -- A chip pointing at a server the user deleted from the stock OPDS plugin.
    -- Silent, exactly as _opdsFetchMore / _opdsRefresh are: the view itself is
    -- already empty and a search-specific complaint would name the wrong
    -- problem.
    if not server then return end
    local feed_url = tab.source.feed_url or server.url
    local win  = OpdsWindow.load(tab.source.id, feed_url)
    local src  = win.search
    -- The root IS this window when the view is the chip's own feed; only a
    -- drilled subcatalog pays for the second load.
    local root = win
    if not src and feed_url ~= server.url then
        root = OpdsWindow.load(tab.source.id, server.url)
        src  = root.search
    end
    if not src then
        -- "Known" = we have actually seen this catalog's root document, so its
        -- links are a fact rather than an absence. Both signals, not just
        -- fetched_at: a window persisted before fetched_at was written would
        -- otherwise be misread as never fetched and the user told to load a
        -- catalog they are already looking at.
        local root_known = (root.fetched_at or 0) > 0
                           or (root.count or 0) > 0
        UIManager:show(Notification:new{
            text = root_known
                and _("This catalog does not offer search.")
                or  _("Load the catalog first, then search it."),
        })
        -- Don't dead-end. The user asked to search; this catalog can't be
        -- searched, but their own library always can -- and that is very often
        -- what they were after anyway. Same fall-through the split submit button
        -- below offers when the catalog CAN be searched.
        self:_openSearchDialog(prefill)
        return
    end
    -- Named for the CATALOG, not the drilled feed: the search runs against the
    -- whole catalog whenever the link came from its root, and telling the user
    -- they are searching "Science Fiction" when the results span everything
    -- would be the wrong promise. server.title is what the chip itself is
    -- labelled with, so the two agree.
    local who = server.title or tab.label or ""
    local InputDialog = require("ui/widget/inputdialog")
    local dlg
    -- Two submit buttons, because from an OPDS chip there are two reasonable
    -- things to search and only one of them used to be reachable. Wanting to
    -- check your own shelves while browsing a catalog is entirely normal ("do I
    -- already own this?"), and it used to mean: notice the dialog only searches
    -- the catalog, close it, switch chip, search again.
    --
    -- The catalog keeps the Enter key, so nothing changes for anyone who doesn't
    -- want the new path. The title says only "Search": with two scopes on offer,
    -- naming one of them in the title would misdescribe the dialog -- each
    -- button names its own scope instead.
    local function submit(fn)
        return function()
            -- Trimmed before it becomes a url: a trailing space percent-encodes
            -- to %20 and several catalogs answer that with zero results.
            local query = (dlg:getInputText() or ""):match("^%s*(.-)%s*$")
            UIManager:close(dlg)
            if query ~= "" then fn(query) end
        end
    end
    dlg = InputDialog:new{
        title = _("Search"),
        input = prefill or "",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id   = "close",
                    callback = function() UIManager:close(dlg) end,
                },
                {
                    text = _("Search my library"),
                    callback = submit(function(query) self:_searchAndDrill(query) end),
                },
            },
            {
                {
                    text             = T(_("Search %1"), who),
                    is_enter_default = true,
                    callback = submit(function(query)
                        self:_opdsSearch(tab, server, src, query)
                    end),
                },
            },
        },
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

-- _opdsSearch(tab, server, src, query) - turn the discovered search source
-- into a feed url and drill into it. The RESULTS are an ordinary opds_nav
-- frame: back-out, pagination, covers and downloads all already work against
-- one, so this function ends where every other OPDS navigation does and adds
-- no machinery of its own.
--
-- Two source shapes, one exit. type "osd" needs the network (the link points
-- at an OpenSearch description document that holds the actual template);
-- type "template" is a Calibre-style href that already carries
-- {searchTerms} and only needs the substitution. Both run inside ONE Trapper
-- wrap so there is a single marker discipline to read rather than two paths
-- to keep in step -- the template branch simply never calls Trapper:info, so
-- it costs a coroutine and nothing else.
--
-- The wrap holds the FEED marker pair for its whole life so nothing else can
-- start a wrapped coroutine underneath it (the Trapper singleton hazard the
-- long note in _opdsAfterPage describes), and clears BOTH on every exit that
-- set them. It does NOT fetch the results: it clears the markers and drills,
-- and the drill's rebuild schedules _opdsFetchMore on the next tick -- after
-- this coroutine has finished, so the two wraps never nest. That ordering is
-- the same one _opdsFetchMore's tail uses and for the same reason: with the
-- markers still held, the rebuild's fetch would be refused as busy and the
-- user would land on an empty results page.
function BookshelfWidget:_opdsSearch(tab, server, src, query)
    local OpdsFeed     = require("lib/bookshelf_opds_feed")
    local CoverFetch   = require("lib/bookshelf_cover_fetch")
    local Notification = require("ui/widget/notification")
    local Trapper      = require("ui/trapper")
    local feed_url = tab.source.feed_url or server.url
    -- The identity the marker publishes, built exactly as _opdsFetchMore
    -- builds its own (resolved url, server id first) so _opdsAfterPage can
    -- read it with no special case: while this runs, the feed the search was
    -- launched from is the one that counts as busy.
    local function sameFeed(t)
        if not (t and t.source and t.source.id == tab.source.id) then return false end
        return (t.source.feed_url or server.url) == feed_url
    end
    local busy_text = _("The catalog is busy. Try again in a moment.")
    if self:_opdsFetchBusy() then
        UIManager:show(Notification:new{ text = busy_text })
        return
    end
    local function resolve()
        Trapper:wrap(function()
            -- Re-tested FIRST, inside the wrap, for the reason
            -- _opdsRunDownload re-tests: the check above is a snapshot taken
            -- before the Wi-Fi prompt, which the user can leave open for as
            -- long as they like, and a feed fetch sitting in runWhenOnline
            -- holds no marker yet so that snapshot could not have seen it.
            -- Bails BEFORE setting anything: the markers belong to whoever is
            -- busy right now, and clearing them here would advertise a live
            -- coroutine as idle.
            if self:_opdsFetchBusy() then
                UIManager:show(Notification:new{ text = busy_text })
                return
            end
            self._opds_fetch_started_at = os.time()
            self._opds_fetch_feed = sameFeed
            local target
            if src.type == "osd" then
                Trapper:info(T(_("Searching %1…"), server.title or tab.label or ""))
                -- Credentials only ever travel to the catalog's own origin:
                -- the osd href came out of the server's XML and could name any
                -- host, same gate the feed fetch and the download apply.
                local same_origin = OpdsFeed.sameOrigin(server.url, src.href)
                local body, err = OpdsFeed.fetch(src.href,
                    same_origin and server.username or nil,
                    same_origin and server.password or nil)
                local template = body and OpdsFeed.parseOsd(body) or nil
                Trapper:clear()
                if not template then
                    self._opds_fetch_started_at = nil
                    self._opds_fetch_feed = nil
                    -- Same reason as the feed fetch's line: the toast collapses
                    -- every cause into one sentence. The third argument tells
                    -- the two halves of this branch apart -- a transport
                    -- failure carries its status from OpdsFeed.fetch, while a
                    -- document that arrived and did not parse has no err at all
                    -- and is a very different thing to chase.
                    logger.dbg("[bookshelf] opds fetch failed:", src.href,
                               err or "no search template in the response")
                    -- A document that came back but did not parse reports as
                    -- unreachable too: from here the two are the same failure
                    -- (no template, nothing to search with) and the user's
                    -- move is identical, so this reuses the messages the feed
                    -- fetch already speaks rather than minting a third.
                    UIManager:show(Notification:new{
                        text = err == "auth"
                            and T(_("Authentication failed for %1"), server.title)
                            or err == "format"
                            and T(_("%1 refused every format Bookshelf asked for"), server.title)
                            or err == "ratelimited"
                            and T(_("%1 is limiting requests. Wait a minute and try again."), server.title)
                            or  T(_("Couldn't reach %1"), server.title),
                    })
                    return
                end
                -- Resolved against the OSD DOCUMENT's own url before the
                -- query goes in, because that is what the template is
                -- relative to. Catalogs are free to advertise a relative one
                -- and some do: bookorbit's is "/api/v1/opds/catalog?q=
                -- {searchTerms}", which substitutes into something that is
                -- not a url at all, so the drill failed without a single
                -- request reaching the server and reported as unreachable
                -- (#322). An already-absolute template resolves to itself, so
                -- catalogs that were working are untouched.
                target = OpdsFeed.substituteQuery(
                    OpdsFeed.absolute(src.href, template), query)
            else
                -- No resolve here: a templated search link is captured by
                -- mapEntries, which already made it absolute against the feed
                -- it was found in.
                target = OpdsFeed.substituteQuery(src.href, query)
            end
            -- Released BEFORE the drill, never after: see the header.
            self._opds_fetch_started_at = nil
            self._opds_fetch_feed = nil
            -- The drill IS the user navigation that licenses the results
            -- fetch, armed like every other nav gesture.
            self:_markOpdsNav()
            self:_drillInto{
                kind    = "opds_nav",
                label   = T(_("Search: \"%1\""), query),
                payload = { server_key = tab.source.id, feed_url = target },
            }
        end)
    end
    if src.type == "osd" then
        -- Only the osd branch talks to the network here, so only it needs the
        -- Wi-Fi gate. The template branch drills straight in and the results
        -- fetch raises the prompt itself (_opdsFetchMore's own runWhenOnline),
        -- which keeps it to one prompt either way.
        CoverFetch.runWhenOnline(function()
            -- The Wi-Fi prompt is modal and can be answered long after the
            -- shelf closed or was replaced. Same liveness test every other
            -- deferred OPDS path makes.
            if BookshelfWidget.live ~= self then return end
            -- ...and the shelf can still be showing something else entirely:
            -- Wi-Fi off is the resting state on an e-reader, so the FIRST
            -- search of a session routinely waits on that prompt, with the
            -- shelf fully interactive underneath it. The user can back out of
            -- the drill, switch chips, even land on a local one before this
            -- runs, and a search drill pushed under THAT context is a results
            -- frame the user never asked for in a place it does not belong.
            -- Re-resolved rather than assumed, exactly as _opdsFetchMore's
            -- tail re-resolves before touching the cursor. Silent: the user
            -- navigated away, which is answer enough -- a toast about a search
            -- they abandoned would be noise.
            if not sameFeed(self:_opdsEffectiveTab()) then return end
            resolve()
        end)
    else
        resolve()
    end
end

-- ─── OPDS book detail modal ──────────────────────────────────────────────────
--
-- What "open" means for a remote catalog record. Reached from the tap path
-- (_openBook) and the long-press path (_showBookDetail): both bounce here
-- because there is no file behind an OPDS:// pseudo-path, so the tabbed
-- book-detail popup would be inert at best and destructive at worst (its Edit
-- tab offers Delete).
--
-- The chrome is a plain ButtonDialog: cover + title / author + the first few
-- lines of the feed's blurb as one added header widget, then a full-width row
-- per downloadable format. NOT the ReviewsModal engine the local book detail
-- uses -- its footer is a fixed row (Close / zoom / Open) with nowhere to put a
-- variable number of download buttons, so they would have had to live inside a
-- native tab: an extra tap to reach the only action the screen exists for, and
-- a composition this file has learned to be careful with (widgets that behave
-- standalone can misbehave inside a cropped modal -- see the text_chevrons
-- note). The blurb still gets the full ReviewsModal treatment (scrollable,
-- sanitised HTML, A-/A+ zoom) one tap away behind Description, built from the
-- same header builder so the two read as one surface.

-- Store key: OPDS pseudo-path -> the on-disk path a completed download landed
-- at. Small and flat (two short strings per downloaded book), so it stays in
-- the MAIN settings store rather than earning a subStoreFor route of its own:
-- it is READ on every OPDS page render (bookshelf_book_repository's opds
-- branch, for the downloaded decoration), where an already-open in-memory
-- table is exactly what's wanted, and WRITTEN only when a download completes --
-- so the main file's re-serialise is paid once per download, never per render.
-- The sub-stores exist for values that are large (opds_cache) or rewritten
-- constantly (hardcover_links); this is neither.
--
-- The key itself lives in bookshelf_opds_download (its other reader is the book
-- repository, which is nowhere near this file) -- one spelling, two callers.
local OPDS_DOWNLOADS_KEY = require("lib/bookshelf_opds_download").STORE_KEY
-- Sibling map (path -> catalog description); written here on download, read by
-- Repo.buildBookMeta so the downloaded book keeps the catalog's blurb.
local OPDS_DESC_KEY = require("lib/bookshelf_opds_download").DESC_STORE_KEY

-- Is ANY OPDS network job holding Trapper right now? Trapper's progress widget
-- is module-level singleton state, so a second wrapped coroutine started under
-- a live one closes the first's InfoMessage and leaves its coroutine suspended
-- forever -- preventStandby never balanced, a device that won't sleep again
-- this session (the long note in _opdsAfterPage's busy branch has the full
-- shape). Downloads are modal-driven and never touch the _markOpdsNav gate,
-- but they DO wrap Trapper, so they answer to the same rule.
--
-- TWO markers, not one. A feed fetch owns _opds_fetch_started_at (paired with
-- _opds_fetch_feed, its identity); a modal download owns
-- _opds_download_started_at. Each side clears only its own, because they can
-- legitimately be set in either order and a shared field means whichever
-- finishes first clears the other's claim -- leaving a live coroutine
-- advertising itself as idle, which is exactly the state this test exists to
-- prevent. A download deliberately publishes NO feed identity, so
-- _opdsAfterPage reads it as "someone else is busy" and queues the user's
-- navigation rather than spending it.
--
-- 120s, and timestamps rather than booleans, for the reason the feed marker is
-- set that way in the first place: a wrapped body can't be pcall'd (Trapper
-- yields, and LuaJIT can't yield across a C-call boundary), so an error inside
-- it must expire rather than wedge the flag on for the session.
local OPDS_BUSY_WINDOW = 120

function BookshelfWidget:_opdsFetchBusy()
    local now = os.time()
    local feed = self._opds_fetch_started_at
    if feed and (now - feed) < OPDS_BUSY_WINDOW then return true end
    return self:_opdsDownloadBusy()
end

-- Just the DOWNLOAD half of the test above, for the one caller that has to be
-- narrower (_opdsRefresh: a swipe-down during a FEED fetch stays allowed). It
-- exists so that caller cannot read the marker as a bare boolean: with a plain
-- truthiness test the two readers disagree the moment the marker wedges, and
-- swipe-down refresh would stay dead for the life of the widget -- "the catalog
-- is busy" with nothing actually busy -- while everything else recovered after
-- the window. Same expiry, one constant, one rule.
function BookshelfWidget:_opdsDownloadBusy()
    local dl = self._opds_download_started_at
    return (dl ~= nil) and (os.time() - dl) < OPDS_BUSY_WINDOW
end

-- _opdsDownloadedPath(book) -> path | nil
-- The file a previous download of this record left on disk, when it is still
-- there. Statted rather than trusted: the user can delete the book in the file
-- manager and the mapping has no way to hear about it, so the mapping alone is
-- a claim and the stat is the answer. Same rule the repo's `downloaded`
-- decoration follows -- one source of truth, two readers.
function BookshelfWidget:_opdsDownloadedPath(book)
    if not (book and type(book.filepath) == "string") then return nil end
    local map = BookshelfSettings.read(OPDS_DOWNLOADS_KEY)
    local dest = (type(map) == "table") and map[book.filepath] or nil
    if type(dest) ~= "string" or dest == "" then return nil end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then return nil end
    local ok_a, mode = pcall(lfs.attributes, dest, "mode")
    if ok_a and mode == "file" then return dest end
    return nil
end

-- Button label for one acquisition link. The feed's own link title wins when it
-- gave one ("EPUB (no images)" on Gutenberg) -- it is the only thing that tells
-- two same-format editions apart after the edition collapse merged them. With
-- no title, fall back to the extension the file will actually be saved with,
-- uppercased, taken from OpdsDownload.filenameFor rather than a second MIME
-- table here so the label can never disagree with the filename produced.
local function opdsAcquisitionLabel(book, acq)
    if type(acq.title) == "string" and acq.title ~= "" then
        -- Match the stock OPDS browser, which decodes an acquisition link's
        -- title before showing it. Some servers put the URL-escaped filename
        -- here, which otherwise leaks %E5%... into the Download button.
        return require("socket.url").unescape(acq.title)
    end
    local ok_d, D = pcall(require, "lib/bookshelf_opds_download")
    local name = ok_d and D.filenameFor(book, acq) or nil
    local ext = type(name) == "string" and name:match("%.([^.]+)$") or nil
    return ext and ext:upper() or nil
end

-- _buildRemoteBookHeader(book, header_w, opts) -> widget | nil
-- Cover + title + author for a remote record, optionally followed by the first
-- `opts.summary_lines` lines of the blurb. Shared by the ButtonDialog (as its
-- added widget) and the Description modal (as its header_builder), so the two
-- screens show the same book the same way.
--
-- The cover comes from the OPDS cover cache through ImageSource, whose bb is
-- CACHE-OWNED: image_disposable stays false and the widget never hands the bb
-- back as _owned_cover_bb (which ReviewsModal frees at close) -- freeing a
-- shared cache bb is the corruption the OPDS cover path was rebuilt to avoid.
function BookshelfWidget:_buildRemoteBookHeader(book, header_w, opts)
    opts = opts or {}
    if not book or type(header_w) ~= "number" or header_w <= 0 then return nil end
    local ImageWidget    = require("ui/widget/imagewidget")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local VerticalSpan   = require("ui/widget/verticalspan")

    -- Cover box, capped so it can't crowd the text column on a narrow screen.
    local thumb_w = math.min(Screen:scaleBySize(110), math.floor(header_w * 0.35))
    local thumb_h = math.floor(thumb_w * 1.5)
    local gap_w   = self:_bookGap(math.min(
        math.floor(Space.padding.fullscreen * 2 * 0.8),
        math.floor(Screen:getWidth() * 0.03)))

    -- Whatever is on disk right now: the repo attaches cover_image_path to the
    -- page record, but a re-show after the on-open fetch (below) is handed the
    -- same record the repo built BEFORE the file landed, so ask the cache too.
    local cover_path = book.cover_image_path
    if not cover_path then
        local ok_c, OpdsCovers = pcall(require, "lib/bookshelf_opds_covers")
        if ok_c then
            local ok_p, p = pcall(OpdsCovers.cachedPath, book)
            cover_path = ok_p and p or nil
        end
    end
    local cover_bb
    if cover_path then
        local ok_img, ImageSource = pcall(require, "lib/bookshelf_image_source")
        cover_bb = ok_img and ImageSource.loadImageNative(cover_path) or nil
    end

    local thumb
    if cover_bb then
        -- True aspect from the bb itself, so a non-2:3 cover isn't letterboxed
        -- or stretched (same derivation as the book menu header).
        local bw = cover_bb.w or (cover_bb.getWidth and cover_bb:getWidth())
        local bh = cover_bb.h or (cover_bb.getHeight and cover_bb:getHeight())
        if bw and bh and bw > 0 then thumb_h = math.floor(thumb_w * (bh / bw)) end
        thumb = FrameContainer:new{
            bordersize = Size.border.thin, padding = 0, margin = 0,
            ImageWidget:new{
                image            = cover_bb,
                image_disposable = false,   -- ImageSource's cache owns it
                width            = thumb_w,
                height           = thumb_h,
                scale_factor     = 0,
            },
        }
    else
        -- Placeholder: an empty bordered box with a centred book glyph, so the
        -- header keeps its shape while the cover is still on its way (or the
        -- feed never offered one). A Private-Use-Area codepoint from the
        -- bundled Nerd Font -- the only range that renders safely here.
        thumb = FrameContainer:new{
            bordersize = Size.border.thin, padding = 0, margin = 0,
            CenterContainer:new{
                dimen = Geom:new{ w = thumb_w, h = thumb_h },
                TextWidget:new{
                    text = "\xEF\x80\xAD",   -- U+F02D, nf-fa-book
                    face = BFont:getFace("symbols", 28),
                },
            },
        }
    end

    -- Text column. max_width/width must stay positive (a zero-width TextWidget
    -- is a crash, not a clip), so floor it rather than trusting the arithmetic.
    local text_w = math.max(Screen:scaleBySize(60),
        header_w - thumb_w - 2 * Size.border.thin - gap_w)
    local stack = VerticalGroup:new{ align = "left" }
    local t_face, t_bold = BFont:getFace("smalltfont", 22, { bold = true })
    stack[#stack + 1] = TextBoxWidget:new{
        text  = book.display_title or book.title or _("(no title)"),
        face  = t_face,
        bold  = t_bold,
        width = text_w,
    }
    if type(book.author) == "string" and book.author ~= "" then
        local a_face, a_bold = BFont:getFace("cfont", 18)
        stack[#stack + 1] = VerticalSpan:new{ width = Space.padding.small }
        stack[#stack + 1] = TextBoxWidget:new{
            text = book.author, face = a_face, bold = a_bold, width = text_w,
        }
    end

    local group = VerticalGroup:new{ align = "left",
        HorizontalGroup:new{ align = "top",
            thumb, HorizontalSpan:new{ width = gap_w }, stack },
    }

    -- Blurb preview. Plain text via the shared cleanDescription (feed summaries
    -- are usually HTML), capped to a fixed line count: the dialog's added
    -- widget sits OUTSIDE its scrollable button area, so an uncapped blurb
    -- would push the buttons off screen. height + height_adjust +
    -- height_overflow_show_ellipsis gives "at most N lines, shrink to fit,
    -- ellipsis when there's more" in one widget; the rest is behind
    -- Description.
    local max_lines = tonumber(opts.summary_lines) or 0
    local raw = book.opds and book.opds.summary
    if max_lines > 0 and type(raw) == "string" and raw ~= "" then
        local ok_tok, Tokens = pcall(require, "lib/bookshelf_tokens")
        local text = ok_tok and Tokens.cleanDescription(raw) or nil
        if type(text) == "string" and text ~= "" then
            local s_face, s_bold = BFont:getFace("cfont", 16)
            -- Throwaway probe purely to read the face's line height. Freed
            -- straight after: it shapes a real text run, and a book modal gets
            -- opened many times over a browsing session.
            local probe = TextBoxWidget:new{ text = "Ag", face = s_face, width = header_w }
            local line_h = probe.line_height_px or Screen:scaleBySize(20)
            probe:free()
            group[#group + 1] = VerticalSpan:new{ width = Space.px(10) }
            group[#group + 1] = TextBoxWidget:new{
                text   = text,
                face   = s_face,
                bold   = s_bold,
                width  = header_w,
                height = line_h * max_lines,
                height_adjust                 = true,
                height_overflow_show_ellipsis = true,
            }
        end
    end
    -- Nothing in here is interactive, and ButtonDialog puts every added widget
    -- into its dpad focus layout unless told otherwise -- without this, arrow
    -- navigation gets a dead row above the buttons that swallows a press.
    group.not_focusable = true
    return group
end

-- ReviewsModal args for a remote record's blurb, or nil when it has none.
-- _descriptionArgs is written against a Book's own description fields; a feed
-- record keeps its blurb under opds.summary instead, so hand the helper a
-- shallow stand-in rather than duplicating what it does -- sanitised markup for
-- an HTML blurb, paragraph-preserving escaping for a plain-text one, which is
-- exactly the pair of shapes OPDS summaries arrive in.
function BookshelfWidget:_remoteDescriptionArgs(book)
    local raw = book and book.opds and book.opds.summary
    if type(raw) ~= "string" or raw == "" then return nil end
    return self:_descriptionArgs{
        title = book.title, author = book.author, description = raw,
    }
end

-- The stock OPDS plugin's page streamer, or nil when that plugin is not
-- there. Its folder is on package.path once KOReader has loaded it; a build
-- that has it disabled still ships the file, so that is tried as well.
function BookshelfWidget._opdsPse()
    local _opds_pse = BookshelfWidget._opds_pse_mod
    if _opds_pse == nil then
        local ok, m = pcall(require, "opdspse")
        if not (ok and type(m) == "table") then
            local f = loadfile("plugins/opds.koplugin/opdspse.lua")
            ok, m = pcall(function() return f and f() end)
        end
        _opds_pse = (ok and type(m) == "table" and type(m.streamPages) == "function") and m or false
        BookshelfWidget._opds_pse_mod = _opds_pse
    end
    return _opds_pse or nil
end

-- The catalog a record came from, for registerRecordActions: its title and
-- URL, and its login only when every link the record carries is on the
-- catalog's own origin, so a feed naming another host never gets it.
function BookshelfWidget:_opdsRecordServer(book)
    local key = book and type(book.filepath) == "string"
        and book.filepath:match("^OPDS://([^/]+)/") or nil
    local server = key and require("lib/bookshelf_opds_source").getServer(key) or nil
    if type(server) ~= "table" then return nil end
    local OpdsFeed = require("lib/bookshelf_opds_feed")
    local hrefs = {}
    local o = book.opds or {}
    for _i, a in ipairs(type(o.acquisitions) == "table" and o.acquisitions or {}) do
        hrefs[#hrefs + 1] = a.href
    end
    if type(o.stream) == "table" then hrefs[#hrefs + 1] = o.stream.href end
    local same = #hrefs > 0
    for _i, h in ipairs(hrefs) do
        if not (type(h) == "string" and OpdsFeed.sameOrigin(server.url, h)) then same = false end
    end
    return { title = server.title, url = server.url,
             username = same and server.username or nil,
             password = same and server.password or nil }
end

-- Stream a record's pages. mode: "start" (page 1, or where Kavita says the
-- reader got to), "ask" (prompt for a page) or "resume" (the feed's lastRead).
-- Credentials go only to the catalog's own origin, as a download's do.
function BookshelfWidget:_opdsStream(book, mode, dialog)
    local stream = book and book.opds and book.opds.stream
    local PSE = BookshelfWidget._opdsPse()
    if type(stream) ~= "table" or not PSE then return end
    local OpdsSource = require("lib/bookshelf_opds_source")
    local OpdsFeed   = require("lib/bookshelf_opds_feed")
    local key = type(book.filepath) == "string"
        and book.filepath:match("^OPDS://([^/]+)/") or nil
    local server = key and OpdsSource.getServer(key) or nil
    local same_origin = (server and OpdsFeed.sameOrigin(server.url, stream.href)) or false
    local user     = same_origin and server.username or nil
    local password = same_origin and server.password or nil
    require("lib/bookshelf_cover_fetch").runWhenOnline(function()
        if dialog then UIManager:close(dialog) end
        PSE:streamPages(stream.href, stream.count, mode == "ask", user, password,
            mode == "resume" and stream.last_read or nil)
    end)
end

-- opts.no_cover_fetch: set on the ONE re-show the on-open cover fetch triggers,
-- so the reopened dialog can't start another (and can't loop against a server
-- that answers with something undecodable).
function BookshelfWidget:_showRemoteBookInfo(book, opts)
    opts = opts or {}
    if not book then return end
    local _perf_t0 = _gettime()
    local ButtonDialog = require("ui/widget/buttondialog")
    local acquisitions = (book.opds and type(book.opds.acquisitions) == "table")
        and book.opds.acquisitions or {}

    -- Runtime format filter. bookshelf_opds_feed's SUPPORTED_TYPE stays the
    -- parse-time filter it already is (what's worth keeping in the window);
    -- this is the narrower "can THIS build actually open it" question, which
    -- only DocumentRegistry can answer -- djvu, for instance, is in the feed
    -- map but needs a provider that not every build ships.
    local usable = {}
    local ok_reg, DocumentRegistry = pcall(require, "document/documentregistry")
    for _i, acq in ipairs(acquisitions) do
        if type(acq) == "table" and type(acq.href) == "string" and acq.href ~= "" then
            local ok_p, has = pcall(function()
                return ok_reg and DocumentRegistry:hasProvider(nil, acq.type)
            end)
            if ok_p and has then usable[#usable + 1] = acq end
        end
    end

    local dialog
    local buttons = {}

    -- Already downloaded (and still on disk): read it instead of fetching it
    -- again. The download rows stay below -- a re-download is how the user
    -- replaces a truncated or wrong-format copy.
    local have = self:_opdsDownloadedPath(book)
    if have then
        buttons[#buttons + 1] = { {
            text = _("Open"),
            callback = function()
                UIManager:close(dialog)
                self:_launchReader(have)
            end,
        } }
    end

    -- Ranked order, with the best-for-KOReader format called out. The ranking
    -- is pure and lives in OpdsDownload so it can be tested without a UI; here
    -- it only decides button order and, when the pick is unambiguous, splits
    -- the rows under "Recommended" / "Alternatives" headings (the download
    -- equivalent of the library edit tab's sections) rather than tagging one
    -- label.
    local ok_rank, OpdsDownload = pcall(require, "lib/bookshelf_opds_download")
    local ordered, rec_idx = usable, nil
    if ok_rank and OpdsDownload.rankAcquisitions then
        ordered, rec_idx = OpdsDownload.rankAcquisitions(usable)
    end
    -- A disabled, centred, bold row reads as a section heading in a
    -- ButtonDialog (it can't take focus or a tap).
    local function headingRow(label)
        return { { text = label, enabled = false,
                   align = "center", text_font_bold = true } }
    end
    local function downloadRow(acq)
        local label = opdsAcquisitionLabel(book, acq)
        local text = label and T(_("Download %1"), label) or _("Download")
        return { { text = text,
                   callback = function() self:_opdsStartDownload(book, acq, dialog) end } }
    end
    if rec_idx and ordered[rec_idx] and #ordered >= 2 then
        -- Confident pick with at least one other format: headed sections.
        buttons[#buttons + 1] = headingRow(_("Recommended"))
        buttons[#buttons + 1] = downloadRow(ordered[rec_idx])
        buttons[#buttons + 1] = headingRow(_("Alternatives"))
        for _i, acq in ipairs(ordered) do
            if _i ~= rec_idx then buttons[#buttons + 1] = downloadRow(acq) end
        end
    else
        -- One format, or no confident pick: a plain list, no headings.
        for _i, acq in ipairs(ordered) do
            buttons[#buttons + 1] = downloadRow(acq)
        end
    end
    -- Page streaming (OPDS-PSE): read a comic or manga a page at a time
    -- without downloading it, through the stock OPDS plugin's own viewer, with
    -- its buttons and wording (and so its translations).
    local stream = book.opds and type(book.opds.stream) == "table" and book.opds.stream or nil
    if stream and not BookshelfWidget._opdsPse() then stream = nil end
    if stream then
        buttons[#buttons + 1] = {
            { text = "\u{23EE} " .. _("Page stream"),
              callback = function() self:_opdsStream(book, "start", dialog) end },
            { text = _("Stream from page") .. " \u{23E9}",
              callback = function() self:_opdsStream(book, "ask", dialog) end },
        }
        if stream.last_read then
            buttons[#buttons + 1] = { {
                text = "\u{25B6} " .. _("Resume stream from page") .. " " .. stream.last_read,
                callback = function() self:_opdsStream(book, "resume", dialog) end,
            } }
        end
    end
    -- Buttons other plugins add for this record (registerRecordActions).
    local RecordActions = require("lib/bookshelf_record_actions")
    local plugin_buttons = RecordActions.buttonsFor(book, {
        server = self:_opdsRecordServer(book),
        close = function() if dialog then UIManager:close(dialog) end end,
    })
    for _i, b in ipairs(plugin_buttons) do buttons[#buttons + 1] = { b } end
    if #usable == 0 and not stream and #plugin_buttons == 0 then
        -- Note row in the established disabled-button style: the record is real
        -- and its blurb is worth reading, there is just nothing here this
        -- device can open.
        buttons[#buttons + 1] = { {
            text = _("No formats this device can open"), enabled = false,
        } }
    end

    local desc_args = self:_remoteDescriptionArgs(book)
    local last_row = {}
    if desc_args then
        last_row[#last_row + 1] = {
            text = _("Description"),
            callback = function()
                UIManager:close(dialog)
                desc_args.bw = self
                desc_args.header_builder = function(avail_w)
                    return self:_buildRemoteBookHeader(book, avail_w, { summary_lines = 0 })
                end
                UIManager:show(require("lib/bookshelf_reviews_modal"):new(desc_args))
            end,
        }
    end
    last_row[#last_row + 1] = {
        text = _("Close"),
        callback = function() UIManager:close(dialog) end,
    }
    buttons[#buttons + 1] = last_row

    dialog = ButtonDialog:new{ buttons = buttons }
    -- addWidget BEFORE show: it reinits the dialog, and reinit on a dialog that
    -- is already up rebuilds self.movable with its default drag/hold gestures
    -- (which then eat taps and wedge the touch state machine, with no
    -- traceback). Built-then-shown, that hazard doesn't exist.
    local header = self:_buildRemoteBookHeader(
        book, dialog:getAddedWidgetAvailableWidth(), { summary_lines = 5 })
    if header then dialog:addWidget(header) end
    logger.dbg(string.format(
        "[bookshelf perf] _showRemoteBookInfo: build=%.0fms %s",
        (_gettime() - _perf_t0) * 1000, tostring(book.title or book.filepath)))
    require("lib/bookshelf_gesture_zones").passSwipesOn(dialog)
    UIManager:show(dialog)

    if not opts.no_cover_fetch then
        self:_opdsFetchDetailCover(book, dialog)
    end
end

-- Fetch one remote book's cover into the disk cache, off the tap path.
-- Shared by the download modal (re-shows itself with the cover) and the hero
-- preview (repaints hero + shelf cell). opts.pre: extra liveness the caller
-- needs (e.g. "the dialog is still shown"), checked after the defer and again
-- when the fetch lands. opts.on_cached: runs when the cover file is on disk -
-- whether THIS fetch downloaded it or a concurrent pass cached it first.
function BookshelfWidget:_opdsFetchCover(book, opts)
    opts = opts or {}
    if not (book and book.opds) then return end
    local ok_c, OpdsCovers = pcall(require, "lib/bookshelf_opds_covers")
    if not ok_c then return end
    -- Match the SHELF's own cover pass exactly: it fetches via image_url OR
    -- thumbnail_url (OpdsCovers.cachePath / fetchMissing both key on
    -- coverUrl = image_url or thumbnail_url). Gating this modal fetch on
    -- image_url alone left a folder-of-one whose child carries only a
    -- thumbnail with a loaded cover on the shelf cell but a permanent
    -- book-glyph placeholder in the modal: a normal book tap hides the gap
    -- because the grid pass had already fetched and attached its cover before
    -- the tap, but the lone-child modal opens straight off the feed fetch,
    -- before any grid pass has run for that record, so it depends entirely on
    -- this fetch -- which then silently bailed. cachePath is non-nil exactly
    -- when there is a cover URL to fetch, and nil when there is none.
    -- One decision line per call: which guard ended it, or that a fetch is
    -- being scheduled. This is the "why did no toast appear" diagnostic.
    local function _bail(reason)
        logger.dbg("[bookshelf perf] _opdsFetchCover: skip (" .. reason .. ")",
            tostring(book.title or book.filepath))
    end
    if not OpdsCovers.cachePath(book) then _bail("no cover url") return end
    if OpdsCovers.cachedPath(book) then _bail("already cached") return end
    -- A feed fetch in flight is suspended at a Trapper yield with the main loop
    -- free, so a blocking image download scheduled underneath it would stall
    -- that fetch for as long as the image takes. Skip; the grid's own cover
    -- pass picks this record up on the next render anyway.
    if self:_opdsFetchBusy() then _bail("feed fetch busy") return end
    -- Never prompts: a passive-looking cover fill must not raise a Wi-Fi
    -- dialog (isConnected answers true on platforms with no Wi-Fi toggle, so
    -- desktop builds still fill).
    local ok_net, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_net and NetworkMgr and NetworkMgr.isConnected
            and not NetworkMgr:isConnected() then
        _bail("offline")
        return
    end
    local _perf_t_sched = _gettime()
    logger.dbg("[bookshelf perf] _opdsFetchCover: scheduling fetch"
        .. (opts.notice and " (with toast)" or ""),
        tostring(book.title or book.filepath))
    -- Feedback while the (blocking) download runs. Shown only once every
    -- synchronous guard has passed -- i.e. a fetch really is about to start --
    -- so a tap on an already-cached cover never flashes it. The 0.1s defer
    -- below is what lets it paint before fetchMissing freezes the loop. The
    -- timeout is a backstop; every exit below dismisses it explicitly.
    local notice
    if opts.notice then
        notice = require("ui/widget/notification"):new{
            text = opts.notice, timeout = 30,
        }
        UIManager:show(notice)
    end
    local function dismiss_notice()
        if notice then
            if UIManager:isWidgetShown(notice) then UIManager:close(notice) end
            notice = nil
        end
    end
    UIManager:scheduleIn(0.1, function()
        if BookshelfWidget.live ~= self then dismiss_notice() return end
        if opts.pre and not opts.pre() then dismiss_notice() return end
        -- fetchMissing blocks the main loop (10s worst case); one at a time.
        -- Queued schedule callbacks that fire while another fetch is mid-air
        -- bail here and rely on their next preview/modal open to retry.
        if self._opds_cover_fetch_busy then dismiss_notice() return end
        self._opds_cover_fetch_busy = true
        -- Paint BEFORE blocking. This callback is usually overdue by the time
        -- the tap handler's (heavy) rebuild returns, and UIManager runs due
        -- tasks before it repaints -- so without this the toast, the new hero
        -- and the selection ring all sat dirty-but-unpainted behind the old
        -- frame for the whole download (8s+ against a slow cover server, and
        -- the toast was then dismissed on completion without ever being
        -- seen). Same primitive Trapper:info uses for exactly this reason.
        UIManager:forceRePaint()
        local _perf_t_fetch = _gettime()
        logger.dbg(string.format(
            "[bookshelf perf] _opdsFetchCover: fetch start, sched_gap=%.0fms",
            (_perf_t_fetch - _perf_t_sched) * 1000))
        OpdsCovers.fetchMissing({ book }, function(fetched)
            self._opds_cover_fetch_busy = nil
            -- The fetch is over either way; the toast must not outlive it.
            dismiss_notice()
            logger.dbg(string.format(
                "[bookshelf perf] _opdsFetchCover: fetch done in %.0fms"
                .. " fetched=%s cached_now=%s",
                (_gettime() - _perf_t_fetch) * 1000,
                tostring(fetched),
                tostring(OpdsCovers.cachedPath(book) ~= nil)))
            if BookshelfWidget.live ~= self then return end
            if opts.pre and not opts.pre() then return end
            -- Cached NOW is the question, not whether THIS fetch downloaded
            -- it: a concurrent pass often lands the same cover first.
            if not OpdsCovers.cachedPath(book) then return end
            if opts.on_cached then opts.on_cached() end
        end)
    end)
end

-- The download modal's cover fetch: re-show the dialog once the cover is on
-- disk.
function BookshelfWidget:_opdsFetchDetailCover(book, dialog)
    self:_opdsFetchCover(book, {
        pre = function() return UIManager:isWidgetShown(dialog) end,
        on_cached = function()
            -- Discard the tap backlog before the geometry moves under it.
            -- fetchMissing is fully blocking (a synchronous download loop with
            -- a 10s total budget), so the main loop can be frozen with the
            -- modal on screen for seconds, and every tap the user made in that
            -- window is still queued. The re-shown dialog is a DIFFERENT
            -- height -- thumb_h switches from the 1.5 placeholder ratio to the
            -- cover's true aspect -- so those taps land on rows that have
            -- moved, and the rows they can land on include "Download <format>":
            -- an unrequested network transfer, not just a stray dismissal.
            -- Same primitive, and the same reason, as the Read-now ConfirmBox's
            -- flush_events_on_show (which is literally this one call).
            local Input = Device.input
            if Input and Input.inhibitInputUntil then
                Input:inhibitInputUntil(true)
            end
            -- Rebuild rather than patch: the cover is baked into the added
            -- header widget, and reinit on a shown ButtonDialog is the movable
            -- hazard noted above. Close and re-show with the fetch disarmed.
            UIManager:close(dialog)
            self:_showRemoteBookInfo(book, { no_cover_fetch = true })
        end,
    })
end

-- Pre-flight for one download: refuse politely when we can't do it, confirm an
-- overwrite, then hand off. Everything here is local (a settings read and one
-- stat); the network half is _opdsRunDownload.
function BookshelfWidget:_opdsStartDownload(book, acq, dialog)
    local Notification = require("ui/widget/notification")
    local D = require("lib/bookshelf_opds_download")
    if self:_opdsFetchBusy() then
        UIManager:show(Notification:new{
            text = _("The catalog is busy. Try again in a moment."),
        })
        return
    end
    -- nil means home_dir is unset: there is no folder the shelf actually scans,
    -- so a download would land somewhere the user would never see it. Name the
    -- problem rather than inventing a destination.
    -- Per-chip download folder (issue #319): read from the chip this book came
    -- from, NOT from _opdsEffectiveTab - that synthesises a bare tab while
    -- drilled into a nav feed, which carries no user settings. The originating
    -- chip is self.chip either way, so resolve the stored record by id and use
    -- its folder when it is an OPDS chip.
    local chip_dir
    do
        local ok_tm, TabModel = pcall(require, "lib/bookshelf_tab_model")
        local tab = ok_tm and TabModel.getById and TabModel.getById(self.chip)
        if tab and tab.source and tab.source.kind == "opds" then
            chip_dir = tab.download_dir
        end
    end
    local dir = D.destinationDir(function(key)
        return G_reader_settings:readSetting(key)
    end, chip_dir)
    if not dir then
        UIManager:show(Notification:new{
            text = _("Set a home folder in KOReader before downloading books."),
        })
        return
    end
    local util = require("util")
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    local function is_file(p)
        if not ok_lfs then return false end
        local ok_a, mode = pcall(lfs.attributes, p, "mode")
        return ok_a and mode == "file"
    end
    local map = BookshelfSettings.read(OPDS_DOWNLOADS_KEY)
    -- A record we have downloaded before keeps the name its file already has.
    -- filenameFor's output changed when the #336 author prefix landed, so
    -- deriving a fresh name here would hand an already-downloaded book a NEW
    -- path: no overwrite prompt, and two copies on disk. mappedDest is nil for
    -- anything we have no live file for, which is every first download.
    local dest = D.mappedDest(map, book.filepath, is_file, dir)
    local name
    if dest then
        name = dest:match("([^/]+)$")
    else
        local filename = D.filenameFor(book, acq)
        local key = type(book.filepath) == "string"
            and book.filepath:match("^OPDS://([^/]+)/") or nil
        local OpdsSource = require("lib/bookshelf_opds_source")
        local OpdsFeed = require("lib/bookshelf_opds_feed")
        local server = key and OpdsSource.getServer(key) or nil
        if server and server.raw_names then
            -- This is deliberately the stock browser's pre-download HEAD
            -- lookup: server names decide the *target path*, so it has to run
            -- before the overwrite prompt and before the GET opens a file.
            local same_origin = OpdsFeed.sameOrigin(server.url, acq.href)
            local server_name = D.serverFilename(acq.href, acq.type,
                same_origin and server.username or nil,
                same_origin and server.password or nil)
            if type(server_name) == "string" and server_name ~= "" then
                filename = server_name
            end
        end
        name = util.getSafeFilename(filename, dir)
        dest = (dir ~= "/" and dir or "") .. "/" .. name
        -- Don't offer to overwrite a file that belongs to a DIFFERENT catalog
        -- record: filenameFor is author + title + format and getSafeFilename
        -- doesn't uniquify, so two records carrying the same book land on one
        -- path, and overwriting would leave both opds_downloads keys pointing at
        -- it -- one record's Open row then launches the other's book. claimDest
        -- hands back a suffixed sibling in that case and the original path in
        -- every other, including this record re-downloading its own file (which
        -- is what the overwrite prompt below is actually for).
        dest = D.claimDest(dest, map, book.filepath, acq)
        name = dest:match("([^/]+)$") or name
    end
    local function go() self:_opdsRunDownload(book, acq, dest, dialog) end

    if is_file(dest) then
        UIManager:show(require("ui/widget/confirmbox"):new{
            text = T(_("%1 already exists. Download it again?"), name),
            ok_text = _("Overwrite"),
            ok_callback = go,
        })
        return
    end
    go()
end

-- The network half. Wi-Fi is gated by runWhenOnline (a prompt, never a silent
-- connect); the transfer itself runs inside Trapper so the progress line is a
-- real widget rather than a frozen screen.
--
-- Credentials only ever travel to the catalog's own origin. The acquisition
-- href came out of the server's own XML and could name any host, so the
-- same-origin test is this layer's job -- OpdsDownload.download sends whatever
-- it is handed, by design (see its header), exactly as the cover fetcher's
-- credential gate works.
function BookshelfWidget:_opdsRunDownload(book, acq, dest, dialog)
    local D            = require("lib/bookshelf_opds_download")
    local OpdsSource   = require("lib/bookshelf_opds_source")
    local OpdsFeed     = require("lib/bookshelf_opds_feed")
    local CoverFetch   = require("lib/bookshelf_cover_fetch")
    local Notification = require("ui/widget/notification")
    local Trapper      = require("ui/trapper")

    local key = type(book.filepath) == "string"
        and book.filepath:match("^OPDS://([^/]+)/") or nil
    local server = key and OpdsSource.getServer(key) or nil
    local same_origin = (server and OpdsFeed.sameOrigin(server.url, acq.href)) or false
    local user     = same_origin and server.username or nil
    local password = same_origin and server.password or nil
    local title    = book.display_title or book.title or ""
    local who      = (server and server.title) or title

    CoverFetch.runWhenOnline(function()
        -- The Wi-Fi prompt is modal and can be answered long after the shelf
        -- closed (or was replaced by a re-open). Same liveness test every other
        -- deferred OPDS path makes.
        if BookshelfWidget.live ~= self then return end
        Trapper:wrap(function()
            -- Re-test, FIRST, inside the wrap. The tap-time check in
            -- _opdsStartDownload is a snapshot taken before two waits that can
            -- run for as long as the user likes: the overwrite ConfirmBox, and
            -- runWhenOnline's Wi-Fi prompt. A feed fetch can be armed or can
            -- reach its own Trapper:wrap during either -- and while a feed
            -- fetch is itself sitting in runWhenOnline it holds NO marker yet,
            -- so the earlier check could not have seen it. Bail with the same
            -- message the tap-time refusal uses; the user retries in a moment.
            if self:_opdsFetchBusy() then
                UIManager:show(Notification:new{
                    text = _("The catalog is busy. Try again in a moment."),
                })
                return
            end
            -- Our OWN marker for the transfer (never the feed's -- see
            -- _opdsFetchBusy): it is what stops a feed fetch (page turn, chip
            -- tap) starting a second wrapped coroutine underneath this one,
            -- and it carries no feed identity, so _opdsAfterPage reads it as
            -- "someone else is busy" and QUEUES the user's navigation rather
            -- than spending it.
            self._opds_download_started_at = os.time()
            -- The transfer runs IN A SUBPROCESS (issue #377): in-process it
            -- blocked the whole UI behind Trapper:info until the socket gave
            -- up -- with a proxy misroute or a dead server that meant a
            -- frozen shelf. The fork writes dest itself; dismissing the trap
            -- SIGKILLs it, so a half-written file is removed here. Same
            -- pattern as the stock OPDS plugin ("tap to cancel").
            -- Returns packed in a table: the failure shape is (nil, err) and
            -- a leading nil through the subprocess serialiser would misalign
            -- the values.
            local completed, result = Trapper:dismissableRunInSubprocess(
                function()
                    local p, e, x = D.download(acq.href, dest, user, password)
                    return { path = p, err = e, extra = x }
                end,
                T(_("Downloading %1… (tap to cancel)"), title))
            local path  = type(result) == "table" and result.path or nil
            local err   = type(result) == "table" and result.err or nil
            local extra = type(result) == "table" and result.extra or nil
            Trapper:clear()
            self._opds_download_started_at = nil
            if not completed then
                -- The fork downloads into dest .. ".tmp" and renames on
                -- success; a SIGKILL leaves the temp, not dest.
                pcall(function() os.remove(dest .. ".tmp") end)
                pcall(function() os.remove(dest) end)
                UIManager:show(Notification:new{
                    text = _("Download cancelled"),
                })
                return
            end

            if not path then
                -- Once, before the branching, so every failure shape is
                -- represented: the three toasts below name the server but not
                -- the cause, and a download that dies on a 504 halfway through
                -- a catalog looks identical to one that never resolved. `extra`
                -- carries the redirect target on the downgrade branch and is
                -- nil elsewhere, so it rides along only when it says something.
                logger.dbg("[bookshelf] opds fetch failed:", acq.href, err, extra)
                if err == "downgrade" then
                    -- Warning-style (an InfoMessage with the notice icon, not a
                    -- toast): this is the one failure the user should be able
                    -- to act on, by telling the catalog's administrator.
                    UIManager:show(require("ui/widget/infomessage"):new{
                        text = T(_("Insecure redirect refused.\n\nThe server tried to send this download to a non-HTTPS address:\n\n%1\n\nMany apps refuse this because it could be a downgrade attack."),
                            tostring(extra or "")),
                        icon = "notice-warning",
                    })
                elseif err == "auth" then
                    UIManager:show(Notification:new{
                        text = T(_("Authentication failed for %1"), who),
                    })
                else
                    UIManager:show(Notification:new{
                        text = T(_("Couldn't reach %1"), who),
                    })
                end
                return
            end

            -- Landed. Record it before anything else can fail: the mapping is
            -- what the repo's downloaded decoration reads, and a file on disk
            -- the shelf doesn't know about is the worse of the two failures.
            local map = BookshelfSettings.read(OPDS_DOWNLOADS_KEY)
            if type(map) ~= "table" then map = {} end
            -- Retire entries whose file is gone, at the one moment we are
            -- already paying for a write. Nothing else ever removes one: the
            -- mapping deliberately gets no bookkeeping pass on move or delete
            -- (see the repo's downloaded comment), so without this it grows for
            -- the life of the install, and a dead value still counts as "taken"
            -- in claimDest's scan -- giving an unrelated record a spurious
            -- "(a1b2c3d4)" in its filename. One stat per entry, at an action
            -- boundary, and BEFORE the new entry goes in so this download's own
            -- destination is never a candidate.
            local ok_lfs2, lfs2 = pcall(require, "libs/libkoreader-lfs")
            if ok_lfs2 and lfs2 then
                D.pruneMap(map, function(p)
                    local ok_s, m = pcall(lfs2.attributes, p, "mode")
                    return ok_s and m == "file"
                end)
            end
            map[book.filepath] = path
            -- No explicit flush: Store.save already flushes (it ends in
            -- s:flush()), and a second call here bought a full re-serialise of
            -- the settings file per download for nothing. The action boundary
            -- is honoured -- just not twice.
            BookshelfSettings.save(OPDS_DOWNLOADS_KEY, map)

            -- Carry the catalog's description onto the downloaded file so the
            -- local library shows it too. Gutenberg's embedded EPUB
            -- description is routinely empty, so without this the book loses
            -- the blurb the moment it lands. Keyed by the on-disk path (read
            -- back in Repo.buildBookMeta); pruned with the same file-exists
            -- predicate as the downloads map so a deleted/replaced file leaves
            -- no dangling text. book.opds.summary is already just the Summary
            -- section (OpdsFeed.summaryText strips Gutenberg's other headings).
            local desc = book.description
                         or (book.opds and book.opds.summary) or nil
            if type(desc) == "string" and desc ~= "" then
                local dmap = BookshelfSettings.read(OPDS_DESC_KEY)
                if type(dmap) ~= "table" then dmap = {} end
                if ok_lfs2 and lfs2 then
                    D.pruneMap(dmap, function(p)
                        local ok_s, m = pcall(lfs2.attributes, p, "mode")
                        return ok_s and m == "file"
                    end)
                end
                dmap[path] = desc
                BookshelfSettings.save(OPDS_DESC_KEY, dmap)
            end
            -- The catalog's publication date too, for %published: calibre-web
            -- serves the file as it was added, so the date it shows in the
            -- catalog is often not inside the file (GitHub issue 566).
            if book.published then
                pcall(function()
                    local Published = require("lib/bookshelf_published")
                    local mtime = ok_lfs2 and lfs2 and lfs2.attributes(path, "modification")
                    Published.remember(path, book.published, mtime)
                    require("lib/bookshelf_book_facts_db").flushSoon()
                end)
            end
            -- A new file inside the library the shelf walks -- the local chips
            -- have to re-derive or the book simply isn't there.
            Repo.invalidateWalkCache()

            -- Shown-check first: the user can dismiss the dialog while the
            -- transfer runs, and closing an already-closed widget re-sends it
            -- CloseWidget (a second repaint of a rect nothing occupies).
            if dialog and UIManager:isWidgetShown(dialog) then
                UIManager:close(dialog)
            end

            -- Re-render the shelf HERE, on the transfer landing, rather than
            -- from one of the two answers below.
            --
            -- The page records under this prompt were built by the repo BEFORE
            -- the download, so the catalog cell still carries no `downloaded`
            -- flag (no tick), and the local chips have never seen the new file.
            -- Only a re-fetch fixes that, and it has to happen on EVERY way out
            -- of this prompt, not one of them:
            --
            --   * "Not now" used to own the refresh, and looked fine.
            --   * "Read" parks the shelf and hands the screen to ReaderUI. The
            --     way back is main.lua's _raiseInPlace, which reorders the
            --     window stack and repaints the widget it finds there -- it
            --     never re-fetches. So the shelf the user returns to is the one
            --     rendered before the download: the book they just read shows
            --     no downloaded tick, for the rest of the visit. It reappears
            --     later only by accident, on the next unrelated rebuild (the
            --     sideload file poll noticing the new file, a page turn, a chip
            --     tap), which reads as a tick that comes and goes.
            --
            -- Hoisting it also means one rebuild per download instead of one
            -- per download plus one per dismissal.
            --
            -- Same liveness guard the ok_callback below makes: with the shelf
            -- closed (or replaced by a re-open) mid-transfer, this would be
            -- rebuilding a dead widget.
            if BookshelfWidget.live == self then
                self:_rebuild()
                UIManager:setDirty(self, "ui")
            end

            UIManager:show(require("ui/widget/confirmbox"):new{
                text        = T(_("%1 downloaded. Read it now?"), title),
                ok_text     = _("Read"),
                -- Liveness guard: with the shelf gone (closed, or replaced by a
                -- re-open), _launchReader would be stamping pre-read state onto
                -- a dead widget.
                ok_callback = function()
                    if BookshelfWidget.live ~= self then return end
                    self:_launchReader(path)
                end,
                cancel_text = _("Not now"),
                -- The transfer blocked the main loop, so every tap the user
                -- made while waiting is still queued and would land on this box
                -- the moment it appears -- answering a question they have not
                -- read yet. confirmbox.lua documents this exact case as what
                -- the flag is for (Input:inhibitInputUntil on show).
                flush_events_on_show = true,
                -- No cancel_callback: the refresh it used to carry now runs
                -- above, before this box is shown, so every dismissal (Cancel,
                -- Read, or a tap outside the box) already has a current shelf
                -- underneath it.
            })
        end)
    end)
end

-- A previewed OPDS book earns its cover: the tap is the user gesture that
-- licenses this one fetch (nothing else prefetches). If the cover is
-- already on disk - e.g. a long-press download modal cached it without
-- rebuilding the shelf - attach it to the record right here, before the
-- caller's rebuild reads it, rather than fetching it again. Otherwise fetch
-- it: when it lands, patch the previewed record in place - _hydrateBook
-- returns remote records unchanged and Repo.buildBook is nil for
-- OPDS:// paths, so a rebuild reuses this same table and would otherwise
-- keep the placeholder - then one _refreshCoverFrame repaints hero AND
-- shelf cell (its rebuild re-slices, and opdsDecorate attaches the
-- cached cover to the cell's record independently).
-- Shared by _previewBook (normal-mode tap) and the expanded show_detail tap
-- (on_book_tap), both of which stage `book` as self._preview_book just
-- before calling this, so the pre/on_cached identity check below matches
-- either caller.
function BookshelfWidget:_opdsEnsurePreviewCover(book)
    if not (book and book.filepath) then return end
    if not self:_isRemoteRecord(book) then return end
    local ok_c, OpdsCovers = pcall(require, "lib/bookshelf_opds_covers")
    if not ok_c then return end
    local cp = OpdsCovers.cachedPath(book)
    if cp then
        -- Already on disk, but THIS record can predate the cache
        -- entry (sliced before the cover landed, or the download
        -- modal fetched it without rebuilding the shelf). Attach in
        -- place now - this trigger runs before the preview rebuild
        -- below, so the hero renders it with no extra refresh.
        logger.dbg("[bookshelf perf] _opdsEnsurePreviewCover: cached attach",
            tostring(book.title or book.filepath))
        book.cover_image_path = book.cover_image_path or cp
        if not book.cover_sizetag then
            local ok_is, ImageSource =
                pcall(require, "lib/bookshelf_image_source")
            if ok_is and ImageSource.imageSizeTag then
                book.cover_sizetag = ImageSource.imageSizeTag(cp)
            end
        end
    else
        self:_opdsFetchCover(book, {
            -- The cover download blocks the main loop for up to 10s, and the
            -- previewed hero alone (placeholder cover, feed description) can
            -- read as "nothing happened" on a slow catalog - say what's going
            -- on. Shown only when a fetch actually starts.
            --
            -- Names the cover, because the cover is all this fetches. The
            -- title, author and summary are already in the hero by the time
            -- this runs - they came with the feed - so "book information"
            -- described work that had visibly already happened.
            notice = _("Retrieving book cover\xE2\x80\xA6"),
            -- A later tap can supersede this preview before the fetch even
            -- starts (checked here, before fetchMissing) or while it's mid
            -- air (checked again below when it lands). Either way, a
            -- superseded preview's fetch is simply skipped: the disk cache
            -- still serves the cell on its next natural rebuild.
            pre = function()
                return self._preview_book ~= nil
                   and self._preview_book.filepath == book.filepath
            end,
            on_cached = function()
                local ok_c, OpdsCovers = pcall(require, "lib/bookshelf_opds_covers")
                if not ok_c then return end
                local cp = OpdsCovers.cachedPath(book)
                if cp and self._preview_book
                        and self._preview_book.filepath == book.filepath then
                    self._preview_book.cover_image_path = cp
                    if not self._preview_book.cover_sizetag then
                        local ok_is, ImageSource =
                            pcall(require, "lib/bookshelf_image_source")
                        if ok_is and ImageSource.imageSizeTag then
                            self._preview_book.cover_sizetag =
                                ImageSource.imageSizeTag(cp)
                        end
                    end
                    -- Same freeze + geometry shift as the modal's re-show:
                    -- fetchMissing held the loop, queued taps would land on
                    -- covers that moved when the cell takes its true aspect.
                    local Input = Device.input
                    if Input and Input.inhibitInputUntil then
                        Input:inhibitInputUntil(true)
                    end
                    self:_refreshCoverFrame(book.filepath)
                end
            end,
        })
    end
end

-- _opdsStartFeed(tab) / _setOpdsStartFeed(...) — a catalogue chip's START
-- FOLDER: which feed the chip opens on, rather than the server's root.
--
-- "add a feature to opds catalog settings that lets you pick the starting
-- folder ... on the shelf long press a folder to set as chip root folder
-- (would still need a way to go back up to higher levels)".
--
-- NO NEW SETTING. tab.source.feed_url already means exactly this and is
-- already resolved everywhere -- _opdsEffectiveTab reads
-- `tab.source.feed_url or server.url`, and the comment on sameFeed spells out
-- that nil means the server's root. A chip has simply never had a way to SET
-- it; only a drilled subcatalog's stand-in tab carried one. So this is a
-- gesture and a menu over machinery that was already in place, and clearing it
-- is the way back up: nil is the root.
function BookshelfWidget:_opdsStartFeed(tab)
    tab = tab or require("lib/bookshelf_tab_model").getById(self.chip)
    if not (tab and tab.source and tab.source.kind == "opds") then return nil end
    return tab.source.feed_url, tab.source.feed_label
end

-- Writes through TabModel, the same load / patch / save the chip editor's own
-- Save does. feed_url = nil clears it back to the server root.
function BookshelfWidget:_setOpdsStartFeed(feed_url, label)
    local TabModel = require("lib/bookshelf_tab_model")
    local tabs = TabModel.load()
    local found
    for _i, t in ipairs(tabs) do
        if t.id == self.chip and t.source and t.source.kind == "opds" then
            t.source.feed_url   = feed_url
            -- Carried alongside so the chip editor can NAME the start folder
            -- rather than showing a url, and so clearing it can say what it is
            -- clearing. Dropped with the url, never left behind.
            t.source.feed_label = feed_url and label or nil
            found = true
            break
        end
    end
    if not found then return false end
    TabModel.save(tabs)
    -- Re-select the chip rather than just rebuilding. Changing where a chip
    -- STARTS is the same event as arriving at it: the drilldown has to go
    -- (whatever the reader had drilled into was reached from the old root and
    -- may sit above the new one), the cursor has to go back to the first item,
    -- and the OPDS fetch gate has to be armed because this rebuild is the
    -- first render of a feed the chip has never shown. _selectChip is that
    -- whole sequence and is already the thing a chip tap runs.
    self:_selectChip(self.chip)
    return true
end

-- _openOpdsNavMenu(rec) — long-press on a catalogue subcatalog.
--
-- Long-press did nothing at all on these rows before: handlersFor answered nil
-- for an opds_nav hold and the cover grid's tile swallowed it with a bare
-- `return true`. So this is the first thing the gesture has ever done there,
-- and what it does is the start folder.
--
-- Two entries, and the second is the answer to "would still need a way to go
-- back up to higher levels": with a start folder set, the levels above it are
-- not reachable by drilling -- they are above the root -- so the way back is
-- to clear it. Offered from any row of the catalogue, which is where a reader
-- who wants out of a too-deep start will be standing.
function BookshelfWidget:_openOpdsNavMenu(rec)
    if rec and rec.source_nav then return end
    if not (rec and rec.opds and rec.opds.feed_url) then return end
    local tab = require("lib/bookshelf_tab_model").getById(self.chip)
    if not (tab and tab.source and tab.source.kind == "opds") then return end
    local current, current_label = self:_opdsStartFeed(tab)
    local label = rec.label or rec.display_title or rec.title or _("this folder")
    -- A page (STYLE.md): where the shelf starts now in the strip, then what
    -- can change it, each a card saying what it does.
    local dialog
    local function act(fn) return function() UIManager:close(dialog); fn() end end
    local summary, blocks = nil, {}
    if current == rec.opds.feed_url then
        -- Already the start folder: said in the strip, not as a greyed
        -- button (one that cannot change anything makes the reader wonder
        -- whether it worked).
        summary = T(_("This shelf already starts at \"%1\"."), label)
    else
        summary = current_label and T(_("This shelf starts at \"%1\"."), current_label)
            -- "catalog", not "catalogue": source strings are American and
            -- the British forms live in en_GB.po.
            or _("This shelf starts at the top of the catalog.")
        blocks[#blocks + 1] = { type = "option", icon = "\u{E9DB}",   -- home
            text = _("Start the shelf here"),
            desc = _("Opens at this folder instead of the catalog's top."),
            callback = act(function() self:_setOpdsStartFeed(rec.opds.feed_url, label) end) }
    end
    if current then
        blocks[#blocks + 1] = { type = "option", icon = "\u{ED22}",   -- format-vertical-align-top
            text = _("Back to the top"),
            desc = _("Opens at the top of the catalog again."),
            callback = act(function() self:_setOpdsStartFeed(nil, nil) end) }
    end
    dialog = require("lib/bookshelf_page_dialog").show{
        title = label,
        page  = function() return { strip = { { type = "summary", text = summary } }, blocks = blocks } end,
    }
end

-- _expandOpdsNav(rec, no_fetch) - tap handler for an OPDS navigation tile (a
-- subcatalog link within a remote feed), and the D-pad Enter on the same tile.
-- Ordinarily it drills in exactly as a folder does: push a path frame naming
-- the feed and let _fetchChipItems scope the shelf to it. The breadcrumb, the
-- east-swipe back-out and the page-1 "go up a level" all come for free from the
-- shared drill machinery.
--
-- ...but a "folder" holding exactly one book is not worth a shelf. Catalogs
-- like Project Gutenberg model every WORK as a subcatalog whose feed carries a
-- single acquisition entry, so drilling in landed the user on a one-tile shelf
-- they had to tap again and then back out of twice. The repo already flattens
-- those tiles once their child feed is cached (see the opds branch of
-- getBySource); this is the tap side of the SAME predicate --
-- Repo.opdsLoneChildBook, single-sourced deliberately, because a tile rendered
-- as a book that then drilled in like a folder would be worse than either.
--
-- So the tap is a decision over the child window, in three states:
--
--   * cached and it IS a folder of one -> open that book's own modal, and
--     nothing else. No _markOpdsNav: the arm is a one-shot licence for the NEXT
--     rebuild to reach the network, this path does not rebuild at all, and an
--     unspent arm would be picked up by whatever passive rebuild came next (a
--     cover landing, the 5s file poll) and spent on a fetch nobody asked for.
--   * cached and it is anything else (several books, subfolders, a feed with
--     more pages behind it) -> drill, armed, exactly as before.
--   * UNCACHED -> neither answer is knowable without asking the server, and the
--     tap is precisely the user action that licenses asking. Fetch the child
--     feed first, then re-run this decision against what landed.
--
-- The pre-fetch calls _opdsFetchMore DIRECTLY and arms nothing, the same shape
-- (and for the same reason) as _opdsRefresh: with no rebuild of ours to gate,
-- the arm would have nothing to gate and its tail rebuild stays passive. The
-- busy test is _opdsRefresh's rule widened to both markers -- a second Trapper
-- coroutine over a live one is the standby-leak hazard documented at
-- _opdsAfterPage's queue branch -- and applies ONLY to this branch: a cached
-- tile is pure local work, and refusing to open it during a download would be a
-- folder that cannot be opened for no reason.
--
-- no_fetch marks the re-entry from that fetch's completion callback, and is
-- what stops it looping. "The window is cached now" is NOT enough on its own:
-- a fetch that failed (server down, feed empty, user cancelled, Wi-Fi declined)
-- leaves the window exactly as uncached as it found it, having already shown
-- its own notification, and an unguarded re-entry would fetch again on every
-- round. One fetch per tap, then stay put.
--
-- The server key rides the synthetic filepath ("OPDS://<server_key>/nav/...")
-- rather than a field of its own, because that path is the one part of a
-- remote record guaranteed to survive a repo round trip (see
-- _isRemoteRecord). Both it and the feed_url are required: a frame missing
-- either would render an empty shelf with no way to fetch into it.
--
-- The frame is deliberately NOT persisted (_serializeDrillPath drops it), so
-- a relaunch lands the user back on the chip's root feed. Restoring it would
-- mean a network fetch at startup that nobody asked for.
function BookshelfWidget:_expandOpdsNav(rec, no_fetch)
    -- A registered source's folder (lib/bookshelf_sources fetch mode) draws as
    -- the same tile; it drills through its source instead.
    if rec and rec.source_nav then return self:_expandSourceNav(rec) end
    -- THE TWO SILENT RETURNS, now audible. A nav tile that does nothing when
    -- tapped is this function's known failure shape -- the cache-test comment
    -- below records an earlier one -- and both of these dropped the tap with
    -- no trace at all, which is a tap you cannot tell apart from a tap that
    -- never arrived. Cost is two string builds on a gesture, and only when the
    -- record is already malformed.
    if not (rec and rec.opds and rec.opds.feed_url) then
        logger.dbg(string.format(
            "[bookshelf perf] _expandOpdsNav: DROPPED, no feed_url (kind=%s "
            .. "fp=%s opds=%s)",
            tostring(rec and rec.kind), tostring(rec and rec.filepath),
            tostring(rec and rec.opds)))
        return
    end
    local server_key = type(rec.filepath) == "string"
                       and rec.filepath:match("^OPDS://([^/]+)/") or nil
    if not server_key then
        logger.dbg(string.format(
            "[bookshelf perf] _expandOpdsNav: DROPPED, filepath is not an "
            .. "OPDS key (fp=%s)", tostring(rec.filepath)))
        return
    end
    -- Say the tap landed, before doing anything that takes time. Not on the
    -- no_fetch re-entry: that one arrives after a fetch the reader already
    -- watched, and re-marking the tile there would only cost a second repaint.
    if not no_fetch then self:_markTapped(rec.filepath) end
    local _perf_t0 = _gettime()
    local feed_url = rec.opds.feed_url
    local label = rec.label or rec.display_title or rec.title
    -- fetched_at is the cache question, not #entries: a feed that legitimately
    -- came back empty has a stamp and no entries, and re-fetching that on every
    -- tap would be a round trip per tap against a server that already answered.
    -- OpdsWindow.load's miss shape stamps 0, so the two are never confusable.
    local OpdsWindow = require("lib/bookshelf_opds_window")
    local win = OpdsWindow.load(server_key, feed_url)
    -- Cached means "there is something to show", not "a timestamp exists".
    --
    -- Asking only about fetched_at was a silent dead end: the walk stamps the
    -- timestamp and appends the entries as separate steps, so a window can
    -- legitimately hold records with no stamp. This tap then dispatched a
    -- fetch, re-entered with no_fetch, failed the same test again and hit
    -- `return` - a tile that did NOTHING when tapped, over a feed with 26
    -- entries already cached. Seen on ManyBooks: Genres worked, Titles and
    -- Authors did not, and the only difference was the stamp.
    --
    -- Entries still win over the stamp for the empty case: a feed that
    -- genuinely came back empty has a stamp and no entries, and must not be
    -- re-fetched on every tap.
    local cached = (win.fetched_at or 0) > 0 or (win.count or 0) > 0
    logger.dbg(string.format(
        "[bookshelf perf] _expandOpdsNav: load=%.0fms cached=%s entries=%d %s",
        (_gettime() - _perf_t0) * 1000,
        tostring(cached), win.count or 0, tostring(feed_url)))
    if not cached then
        if no_fetch then return end
        if self:_opdsFetchBusy() then
            UIManager:show(require("ui/widget/notification"):new{
                text = _("The catalog is busy. Try again in a moment."),
            })
            return
        end
        -- want_count is a page's worth, not the one entry the decision needs:
        -- the likely outcome is a drill, and fetching less would land the user
        -- on a part-filled shelf that immediately fetched again.
        logger.dbg("[bookshelf perf] _expandOpdsNav: cache miss, dispatching feed fetch")
        self:_opdsFetchMore(
            { label = label,
              source = { kind = "opds", id = server_key, feed_url = feed_url } },
            self:_viewSize() or 24, false,
            function() self:_expandOpdsNav(rec, true) end)
        return
    end
    local lone = Repo.opdsLoneChildBook(server_key, feed_url)
    if lone then
        -- Same journey as a plain book tap: the first tap stages the
        -- flattened book in the hero (cover and description fetch included),
        -- and a second tap on the same tile opens the download modal. The
        -- lone child is a DIFFERENT record from the nav tile, so the
        -- "already previewed" test compares against the child's filepath.
        -- Micro-hero mode is excluded for the same reason as the book
        -- re-tap branch: the preview state is stale there, and the tap
        -- should swap the hero back to the book instead.
        if self._hero_mode ~= "micro" and self._preview_book
                and self._preview_book.filepath == lone.filepath then
            logger.dbg(string.format(
                "[bookshelf perf] _expandOpdsNav: lone re-tap -> modal, pre_modal=%.0fms",
                (_gettime() - _perf_t0) * 1000))
            self:_showRemoteBookInfo(lone)
            return
        end
        logger.dbg(string.format(
            "[bookshelf perf] _expandOpdsNav: lone flatten -> hero preview, pre_preview=%.0fms",
            (_gettime() - _perf_t0) * 1000))
        self:_previewBook(lone)
        return
    end
    -- The tap IS the user navigation that licenses a fetch: a subcatalog whose
    -- window is cached but short (a feed with more pages behind it) comes back
    -- flagged opds_needs_fetch from the rebuild _drillInto ends with, and
    -- _opdsAfterPage has to be allowed to act on it. Armed before the rebuild,
    -- like every other nav gesture (chip select, page turn, swipe-down).
    self:_markOpdsNav()
    self:_drillInto{
        kind    = "opds_nav",
        label   = label,
        payload = { server_key = server_key, feed_url = feed_url },
    }
end

end
