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

-- ── _opdsBatchSize: never below a page ───────────────────────────────────────
-- A batch smaller than the visible page would leave the page short on arrival
-- and re-enter the fetch path for the remainder: more round trips, not fewer.
local batch_body = extract("_opdsBatchSize%(%)")
local function batch_for(chip, view)
    local env = { require = require, math = math }
    local self_tbl = {
        _viewSize      = function() return view end,
        _opdsPrefsTab  = function() return chip end,
    }
    return compile("local self = ... ; " .. batch_body, env)(self_tbl)
end

eq(batch_for({}, 24), 24, "unset chip fetches exactly a page, as before the setting existed")
eq(batch_for(nil, 24), 24, "no chip at all still fetches a page")
eq(batch_for({ opds_batch = 100 }, 24), 100, "a chip override raises the batch")
eq(batch_for({ opds_batch = 50 }, 60), 60, "a batch below the page size is lifted to a page")
eq(batch_for({}, nil), 24, "a missing view size still yields a usable batch")
eq(batch_for({ opds_batch = 200 }, 12), 200, "the largest offered batch is honoured")

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

-- ── Invariant: automatic covers are opt-in ───────────────────────────────────
-- Bulk cover downloads over a slow public catalog are what made paging feel
-- stuck. The pass must bail before doing any work unless the chip asked.
local covers = extract("_opdsEnsureCovers%(%)")
if covers then
    local gate_at = covers:find("autoCovers", 1, true)
    local work_at = covers:find("_opdsCoverStep", 1, true)
    ok(gate_at ~= nil, "_opdsEnsureCovers consults the autoCovers setting")
    ok(work_at ~= nil, "_opdsEnsureCovers drives the stepwise cover chain")
    ok(gate_at and work_at and gate_at < work_at,
        "the autoCovers gate comes before any fetching")
    -- Read off the CHIP, not the effective tab: a drilled subcatalog's
    -- stand-in is synthesised and carries no settings, so consulting it would
    -- silently disable the setting one level into any catalog.
    ok(covers:find("_opdsPrefsTab", 1, true) ~= nil,
        "the cover gate reads the chip's settings, not the drill stand-in")
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
