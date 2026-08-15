-- tests/_test_opds_catalog_settings.lua
-- The WIRING of the per-catalog settings into the shelf, as distinct from
-- resolving a stored value (that is _test_opds_prefs).
--
-- Two of these are invariants rather than behaviour, and are checked
-- structurally against the source. That is deliberate: both live inside
-- _opdsAfterPage / _opdsEnsureCovers, which need a coroutine, Trapper, a
-- network stack and the whole widget tree to run, and both are exactly the
-- kind of thing a later edit moves by accident. A structural check that fails
-- loudly beats no check at all, and each is extracted BY NAME so a rename
-- fails here rather than silently passing.
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["logger"] = { dbg=function() end, info=function() end,
                             warn=function() end, err=function() end }

local pass, fail = 0, 0
local function eq(got, want, label)
    if got == want then pass = pass + 1
    else fail = fail + 1; print("FAIL " .. label .. ": got " .. tostring(got) .. " want " .. tostring(want)) end
end
local function ok(cond, label)
    if cond then pass = pass + 1 else fail = fail + 1; print("FAIL " .. label) end
end

local src = io.open("lib/bookshelf_widget.lua"):read("*a")
local function extract(sig)
    local pat = "\nfunction BookshelfWidget:" .. sig .. "\n(.-)\nend\n"
    local body = src:match(pat)
    ok(body ~= nil, "BookshelfWidget:" .. sig .. " found")
    return body
end

local function compile(code, env)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, "chunk"))
        _G.setfenv(f, env)
        return f
    end
    return assert(load(code, "chunk", "t", env))
end

-- ── _opdsBatchSize: exactly one screenful ───────────────────────────────────
-- One screen, so the first paint comes as fast as the layout allows. What
-- makes that enough is the lookahead prefetch below; without it, one screen
-- would mean a round trip on every page turn.
local batch_body = extract("_opdsBatchSize%(%)")
local function batch_for(view)
    local self_tbl = { _viewSize = function() return view end }
    return compile("local self = ... ; " .. batch_body, { })(self_tbl)
end
eq(batch_for(24), 24, "a 24-slot shelf fetches 24")
eq(batch_for(10), 10, "a 10-slot shelf fetches 10")
eq(batch_for(nil), 24, "a missing view size still yields a usable batch")

-- ── Invariant: the lookahead never touches the user-facing fetch ────────────
-- _opdsFetchMore runs inside Trapper, shows a modal "Fetching..." that yields
-- for input, and its tail re-clamps the cursor and rebuilds. A lookahead built
-- on it blocked input on a page already delivered and moved the shelf under a
-- swipe in flight. The replacement rides the cover pool - forked request, no
-- widget, no cursor arithmetic - so the two must stay apart.
local ahead = extract("_opdsLookaheadItem%(%)")
if ahead then
    ok(ahead:find("_opdsFetchMore", 1, true) == nil,
        "the lookahead never calls the user-facing fetch")
    ok(ahead:find("Trapper", 1, true) == nil, "and never opens a progress line")
    ok(ahead:find("self._cursor =", 1, true) == nil,
        "and never MOVES the cursor - that was the page-slipping bug")
    -- "Stops on complete" and "a lost chain restarts from the top" used to be
    -- asserted by grepping this body for the literals that implemented them.
    -- Both rules now live in OpdsWindow.fetchUrl, shared with the fetch walk -
    -- they were duplicated here and drifted, which is what made a feed with a
    -- missing chain unfetchable. The BEHAVIOUR is tested properly in
    -- _test_opds_window (including a mutation check); what matters here is
    -- that the lookahead asks the shared helper rather than deciding again.
    ok(ahead:find("OpdsWindow.fetchUrl", 1, true) ~= nil,
        "it resolves its url through the shared helper, not its own copy")
    ok(ahead:find("if not fetch_url and not win.complete", 1, true) == nil,
        "and keeps no private copy of the rule to drift")
    ok(ahead:find("_opdsFetchBusy", 1, true) ~= nil,
        "it yields to a fetch the user is waiting on")
    ok(ahead:find("sameOrigin", 1, true) ~= nil,
        "credentials only travel to the server's own origin")
    ok(ahead:find("items_per_page", 1, true) ~= nil,
        "depth is costed against the page size the server declared")
end

-- ── Invariant: the progress line is for an EMPTY shelf only ─────────────────
-- A modal that yields for input is right when the reader is waiting on a blank
-- shelf, and wrong when there are already books on screen - interrupting a
-- page they can use, about one they have not asked for, is the whole
-- "blocking Fetching message" complaint. The empty case must reach
-- _opdsFetchMore; the usable case must reach the silent pool instead.
local after_page_src = extract("_opdsAfterPage%(items%)")
if after_page_src then
    local silent_at = after_page_src:find("have_something", 1, true)
    ok(silent_at ~= nil, "_opdsAfterPage distinguishes a usable page from an empty one")
    -- Judged on what is RENDERED. A window with entries can still render an
    -- empty page (the cursor sits past them after a deep restore), and calling
    -- that usable sent it down the silent path to stare at "no books yet".
    ok(after_page_src:find("self._page_items", 1, true) ~= nil,
        "and judges it on the rendered page, not the stored count")
    -- The FIRST _opdsFetchMore is the age refresh near the top, which is a
    -- different decision; the one this invariant is about is the top-up, so
    -- look for a loud call AFTER the silent check rather than before it.
    local loud_after = silent_at
        and after_page_src:find("_opdsFetchMore", silent_at, true)
    ok(loud_after ~= nil,
        "the empty case still reaches the user-facing fetch, after the silent check")
    local gate_at = after_page_src:find("if not user_nav then return end", 1, true)
    ok(gate_at and silent_at and gate_at < silent_at,
        "and all of it sits behind the user-initiated gate")
end

-- ── Invariant: age refresh only inside the user-initiated gate ───────────────
-- The shelf rebuilds for plenty of reasons nobody asked for (the 5s sideload
-- file poll, a cover landing, startup restore). An expiry rule that fired on
-- those would put the device on the radio behind the user's back, which is the
-- whole reason the nav gate exists. The check must sit AFTER the gate.
local after_page = extract("_opdsAfterPage%(items%)")
if after_page then
    local gate_at = after_page:find("if not user_nav then return end", 1, true)
    local age_at  = after_page:find("refreshAge", 1, true)
    ok(gate_at ~= nil, "_opdsAfterPage still has its user_nav gate")
    ok(age_at ~= nil, "_opdsAfterPage performs the age check")
    ok(gate_at and age_at and gate_at < age_at,
        "age refresh happens AFTER the user_nav gate, never on a passive rebuild")
    -- It must also refetch with replace = true: the cached window may be
    -- WRONG, not merely short, so topping it up would keep the stale records.
    local refetch = after_page:match("_opdsFetchMore%(tab, self:_opdsBatchSize%(%), (%a+)%)")
    eq(refetch, "true", "the age refresh REPLACES the window rather than topping it up")
end

-- ── Invariant: the cover pass still goes through the gate ───────────────────
-- autoCovers answers "always" now, but the pass must keep ASKING through it
-- rather than inlining the answer: it is the one place the decision lives, and
-- a future "not on mobile data" would land there. The ordering matters for the
-- same reason it always did - the question comes before any fetching.
local covers = extract("_opdsEnsureCovers%(%)")
if covers then
    local gate_at = covers:find("autoCovers", 1, true)
    -- The chain is driven by the fork POOL now, which falls back to the
    -- stepwise version itself; either name means work is being handed off.
    local work_at = covers:find("_opdsCoverPool", 1, true)
                    or covers:find("_opdsCoverStep", 1, true)
    ok(gate_at ~= nil, "_opdsEnsureCovers consults the autoCovers setting")
    ok(work_at ~= nil, "_opdsEnsureCovers drives the background fetch chain")
    ok(gate_at and work_at and gate_at < work_at,
        "the autoCovers gate comes before any fetching")
    -- Read off the CHIP, not the effective tab: a drilled subcatalog's
    -- stand-in is synthesised and carries no settings, so consulting it would
    -- silently disable the setting one level into any catalog.
    ok(covers:find("_opdsPrefsTab", 1, true) ~= nil,
        "the cover gate reads the chip's settings, not the drill stand-in")
end

-- ── Invariant: the pool's width comes from one place ────────────────────────
-- The pool used to carry its own module constant as well. Two copies of a
-- measured number is the shape that goes stale silently - the measurement gets
-- revised and the fetching keeps the old value.
if covers then
    ok(covers:find("Prefs.concurrency", 1, true) ~= nil,
        "_opdsEnsureCovers resolves the catalog's pool width")
    ok(covers:find("concurrency", 1, true) ~= nil
       and covers:find("_opdsCoverPool", 1, true) ~= nil,
        "and hands it to the chain")
end
ok(src:find("OPDS_FETCH_CONCURRENCY", 1, true) == nil,
    "no hardcoded concurrency constant is left in the widget")
local pool = extract("_opdsCoverPool%(queue, token, state%)")
if pool then
    ok(pool:find("state.concurrency", 1, true) ~= nil,
        "the pool reads the width off the chain's state")
end

-- ── Timeout plumbing ─────────────────────────────────────────────────────────
-- The pair the prefs hand out must be the shape the fetch accepts. These two
-- have to agree by name, and nothing else would catch a rename.
local Prefs = require("lib/bookshelf_opds_prefs")
local t = Prefs.timeouts{ opds_timeout = 10 }
ok(t.block_timeout ~= nil and t.total_timeout ~= nil,
    "prefs hand out the net_opts key names the fetch reads")
local feed_src = io.open("lib/bookshelf_opds_feed.lua"):read("*a")
ok(feed_src:find("opts.block_timeout", 1, true) ~= nil
   and feed_src:find("opts.total_timeout", 1, true) ~= nil,
    "OpdsFeed.fetch reads those same two keys")
-- A half-specified or inverted pair must be ignored rather than half-applied.
ok(feed_src:find("opts.block_timeout <= opts.total_timeout", 1, true) ~= nil,
    "fetch refuses a pair whose block timeout exceeds its total")
-- And the feed fetch must actually be handed the chip's pair.
ok(src:find("feed_timeouts", 1, true) ~= nil,
    "the widget threads a per-catalog timeout into the feed fetch")

print(string.format("opds catalog settings: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
