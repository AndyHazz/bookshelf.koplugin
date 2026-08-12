-- tests/_test_opds_prefs.lua
-- Per-catalog OPDS settings: what an unset chip does (must be exactly what
-- the shelf did before these settings existed), and how a stored value
-- resolves.
--
-- The defaults matter more than the overrides here. Every one of these
-- settings exists to let a private-server owner opt OUT of behaviour tuned
-- for public catalogs, so a regression that changes what an UNSET chip does
-- would change the shelf for everyone who never opens this menu.
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["logger"] = { dbg=function() end, info=function() end,
                             warn=function() end, err=function() end }

local P = require("lib/bookshelf_opds_prefs")

local pass, fail = 0, 0
local function eq(got, want, label)
    if got == want then pass = pass + 1
    else fail = fail + 1; print("FAIL " .. label .. ": got " .. tostring(got) .. " want " .. tostring(want)) end
end
local function ok(cond, label)
    if cond then pass = pass + 1 else fail = fail + 1; print("FAIL " .. label) end
end

local HOUR, DAY = 3600, 86400
local NOW = 1000000

-- Defaults: an untouched chip, and a chip table that is missing entirely.
for _i, tab in ipairs{ {}, { label = "Gutenberg" } } do
    eq(P.refreshAge(tab), nil, "default: no age-based refresh")
    eq(P.isStale(tab, NOW - DAY * 365, NOW), false, "default: a year-old window is not stale")
    eq(P.coverMode(tab), P.COVER_TAP, "default: covers load on tap")
    eq(P.autoCovers(tab), false, "default: no automatic cover loading")
    eq(P.batchSize(tab, 24), 24, "default: batch follows the shelf's page size")
    eq(P.timeouts(tab).total_timeout, 30, "default: 30s total, KOReader's LARGE_TOTAL")
    eq(P.timeouts(tab).block_timeout, 10, "default: 10s block, KOReader's LARGE_BLOCK")
end

-- A nil tab must not throw: the fetch path can reach these before a chip is
-- resolved.
eq(P.coverMode(nil), P.COVER_TAP, "nil tab: covers on tap")
eq(P.autoCovers(nil), false, "nil tab: no auto covers")
eq(P.refreshAge(nil), nil, "nil tab: no age refresh")
eq(P.batchSize(nil, 30), 30, "nil tab: batch follows the shelf")
eq(P.timeouts(nil).total_timeout, 30, "nil tab: default timeout")

-- Refresh age.
eq(P.refreshAge{ opds_refresh_age = HOUR }, HOUR, "stored hour honoured")
eq(P.refreshAge{ opds_refresh_age = DAY * 7 }, DAY * 7, "stored week honoured")
eq(P.refreshAge{ opds_refresh_age = 0 }, 0, "stored 'always' (0) honoured")
-- A value this build does not offer falls back to the default rather than
-- reaching the fetch path.
eq(P.refreshAge{ opds_refresh_age = 12345 }, nil, "unknown age falls back to default")
eq(P.refreshAge{ opds_refresh_age = "an hour" }, nil, "non-numeric age falls back to default")

-- Staleness.
eq(P.isStale({ opds_refresh_age = HOUR }, NOW - HOUR - 1, NOW), true, "older than an hour is stale")
eq(P.isStale({ opds_refresh_age = HOUR }, NOW - HOUR + 1, NOW), false, "younger than an hour is fresh")
eq(P.isStale({ opds_refresh_age = HOUR }, NOW - HOUR, NOW), true, "exactly the age is stale (>=)")
eq(P.isStale({ opds_refresh_age = 0 }, NOW - 1, NOW), true, "'every time' is always stale")
eq(P.isStale({ opds_refresh_age = 0 }, NOW, NOW), true, "'every time' is stale even at zero age")
-- Never-fetched windows are the fetch path's job, not the expiry rule's --
-- calling them stale would turn one fetch into two.
eq(P.isStale({ opds_refresh_age = 0 }, 0, NOW), false, "never-fetched window is not 'stale'")
eq(P.isStale({ opds_refresh_age = HOUR }, nil, NOW), false, "missing fetched_at is not 'stale'")
-- Clock moved backwards, or settings copied from another device.
eq(P.isStale({ opds_refresh_age = DAY }, NOW + DAY, NOW), true, "future fetched_at reads as stale, not fresh forever")

-- Cover mode.
eq(P.coverMode{ opds_cover_mode = "auto" }, P.COVER_AUTO, "stored auto honoured")
eq(P.autoCovers{ opds_cover_mode = "auto" }, true, "auto means auto")
eq(P.coverMode{ opds_cover_mode = "sideways" }, P.COVER_TAP, "unknown cover mode falls back to tap")
-- No thumbnail-preference option: which url a record's cover is has to be one
-- answer shared by the covers module and the repo, and a per-chip preference
-- would split it (see the note in bookshelf_opds_prefs). If someone adds one,
-- they need to solve that first, so this fails loudly rather than silently.
for _i, opt in ipairs(P.COVER_OPTIONS) do
    ok(opt.value == nil or opt.value == P.COVER_AUTO,
        "cover options stay tap-or-auto, no url-preference variants")
end

-- Nav resolution. Off by default: this is one feed fetch PER TILE, and an
-- always-on version was removed for exactly that reason (see the note in
-- bookshelf_opds_prefs).
eq(P.resolveNav{}, false, "default: folders are left as folders")
eq(P.resolveNav(nil), false, "nil tab: no resolution")
eq(P.resolveNav{ opds_resolve_nav = "books" }, true, "stored opt-in honoured")
eq(P.resolveNav{ opds_resolve_nav = "sometimes" }, false,
    "an unknown value falls back to off, never to fetching per tile")
eq(P.resolveNav{ opds_resolve_nav = true }, false,
    "a non-string value falls back to off")

-- Batch size.
eq(P.batchSize({ opds_batch = 100 }, 24), 100, "stored batch overrides the shelf")
eq(P.batchSize({ opds_batch = 7 }, 24), 24, "unoffered batch falls back to the shelf")
eq(P.batchSize({ opds_batch = 0 }, 24), 24, "zero batch falls back rather than fetching nothing")
eq(P.batchSize({}, 0), 24, "a zero view size still yields a usable batch")
eq(P.batchSize({}, nil), 24, "a missing view size still yields a usable batch")

-- Timeouts. Block must never exceed total, or the pair is nonsense.
eq(P.timeouts{ opds_timeout = 10 }.total_timeout, 10, "short timeout honoured")
eq(P.timeouts{ opds_timeout = 60 }.total_timeout, 60, "long timeout honoured")
eq(P.timeouts{ opds_timeout = 45 }.total_timeout, 30, "unoffered timeout falls back to the default")
for _i, secs in ipairs{ 10, 30, 60 } do
    local t = P.timeouts{ opds_timeout = secs }
    ok(t.block_timeout <= t.total_timeout, "block <= total for " .. secs .. "s")
end
-- A caller must not be able to poison the shared pair for everyone else.
local first = P.timeouts{}
first.total_timeout = 999
eq(P.timeouts{}.total_timeout, 30, "timeouts() hands back a fresh table each call")

-- Labels: every option renders, and an unknown value renders as the default.
for _name, opts in pairs{ refresh = P.REFRESH_OPTIONS, cover = P.COVER_OPTIONS,
                          batch = P.BATCH_OPTIONS, timeout = P.TIMEOUT_OPTIONS } do
    for _i, opt in ipairs(opts) do
        local label = P.labelFor(opts, opt.value)
        ok(type(label) == "string" and label ~= "", _name .. " option has a label")
    end
    ok(P.labelFor(opts, "\1nonsense") == opts[1].label_func(),
        _name .. ": unknown value renders as the default option")
end

print(string.format("opds prefs: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
