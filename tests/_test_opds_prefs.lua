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
    eq(P.refreshAge(tab), P.REFRESH_DEFAULT, "default: swipe-down only")
    -- A positive fetched_at: NOW - DAY*365 goes negative, which trips the
    -- never-fetched guard instead of the age rule and passes for the wrong
    -- reason (as this line used to).
    --
    -- Nothing goes stale on age by default any more. A feed accumulates as it
    -- is paged and the last-page walk can fill it with hundreds of entries;
    -- the age refetch replaces all of that with a single batch, so an age
    -- default now discards work the reader deliberately did.
    eq(P.isStale(tab, NOW - DAY, NOW), false, "default: a day-old window is NOT stale on age")
    eq(P.isStale(tab, NOW - 60, NOW), false, "default: a minute-old window is still fresh")
    eq(P.autoCovers(tab), true, "covers always load: not a choice any more")
    eq(P.timeouts(tab).total_timeout, 30, "default: 30s total, KOReader's LARGE_TOTAL")
    -- 20, raised from 10 on a measurement: archive.org's ordinary browse
    -- feeds answer in 10.5s and its language facets not at all inside 10, so
    -- the old value failed a live catalog one second before it would have
    -- succeeded. The TOTAL is unchanged, so a dead server still fails in 30.
    eq(P.timeouts(tab).block_timeout, 20, "default: 20s to the first byte")
end

-- A nil tab must not throw: the fetch path can reach these before a chip is
-- resolved.
eq(P.autoCovers(nil), true, "nil tab: covers still load")
eq(P.refreshAge(nil), P.REFRESH_DEFAULT, "nil tab: still the default age")
eq(P.timeouts(nil).total_timeout, 30, "nil tab: default timeout")

-- Refresh age.
eq(P.refreshAge{ opds_refresh_age = HOUR }, HOUR, "stored hour honoured")
eq(P.refreshAge{ opds_refresh_age = DAY * 7 }, DAY * 7, "stored week honoured")
eq(P.refreshAge{ opds_refresh_age = 0 }, 0, "stored 'always' (0) honoured")
-- A value this build does not offer falls back to the default rather than
-- reaching the fetch path.
eq(P.refreshAge{ opds_refresh_age = 12345 }, P.REFRESH_DEFAULT, "unknown age falls back to the default")
eq(P.refreshAge{ opds_refresh_age = "an hour" }, P.REFRESH_DEFAULT, "non-numeric age falls back too")
-- "Only when I swipe down" is now an EXPLICIT value: nil means "unset", which
-- means the default, so the opt-out needs a value of its own or it could not
-- be expressed at all.
eq(P.refreshAge{ opds_refresh_age = P.REFRESH_NEVER }, P.REFRESH_NEVER, "the opt-out is storable")
eq(P.isStale({ opds_refresh_age = P.REFRESH_NEVER }, NOW - DAY, NOW), false,
   "opted out: a day-old window is never stale on age")
-- The default must be the FIRST option or an unset chip's row renders as
-- something the chip is not (labelFor falls back to OPTIONS[1]).
eq(P.REFRESH_OPTIONS[1].value, P.REFRESH_DEFAULT, "the default leads the option list")
eq(P.labelFor(P.REFRESH_OPTIONS, nil), P.REFRESH_OPTIONS[1].label_func(),
   "an unset chip reads as the default")
-- Swipe-down only. The five-minute default this replaced predates feeds that
-- accumulate: see the module header for why age expiry became the expensive
-- option rather than the safe one.
eq(P.REFRESH_DEFAULT, P.REFRESH_NEVER, "default is swipe-down only")
-- Every other choice is still offered, so the old behaviour is one tap away.
local offered = {}
for _i, o in ipairs(P.REFRESH_OPTIONS) do offered[o.value] = true end
eq(offered[300], true, "five minutes is still offered")
eq(offered[P.REFRESH_ALWAYS], true, "and so is refetching every time")

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
-- Covers and folder resolution are no longer configurable. A chip carrying a
-- stale opds_cover_mode / opds_resolve_nav from the version that offered them
-- must not be able to turn either back off.
eq(P.autoCovers{ opds_cover_mode = "tap" }, true, "a stale tap-only chip still loads covers")
eq(P.resolveNav{ opds_resolve_nav = nil }, true, "one-book folders always show as books")
eq(P.resolveNav{ opds_resolve_nav = "never" }, true, "a stale opt-out is ignored")
eq(P.resolveNav(nil), true, "nil tab resolves too")

eq(P.resolveNav{}, true, "an unset chip resolves one-book folders")

-- Timeouts: one pair for everyone now.
eq(P.timeouts{ opds_timeout = 10 }.total_timeout, 30,
   "a stale per-chip timeout no longer shortens the wait")
eq(P.timeouts{}.total_timeout, 30, "30s total for every catalog")
eq(P.timeouts{}.block_timeout, 20, "20s to the first byte")
ok(P.timeouts{}.block_timeout <= P.timeouts{}.total_timeout, "block <= total")
-- A caller must not be able to poison the shared pair for everyone else.
local first = P.timeouts{}
first.total_timeout = 999
eq(P.timeouts{}.total_timeout, 30, "timeouts() hands back a fresh table each call")

-- Pool width: the opening bid, measured. The pool narrows from here on
-- failure, so this is not a ceiling the client must respect blindly.
eq(P.concurrency(nil), P.CONCURRENCY, "no chip opens at the measured width")
eq(P.concurrency({}), P.CONCURRENCY, "nor does an unset one")
eq(P.concurrency{ opds_concurrency = 1 }, P.CONCURRENCY,
   "a stale per-chip width is ignored - the pool decides now")
ok(P.CONCURRENCY >= 6 and P.CONCURRENCY <= 12,
   "the opening width stays in the range the measurement covered")

-- Labels: every option renders, and an unknown value renders as the default.
for _name, opts in pairs{ refresh = P.REFRESH_OPTIONS } do
    for _i, opt in ipairs(opts) do
        local label = P.labelFor(opts, opt.value)
        ok(type(label) == "string" and label ~= "", _name .. " option has a label")
    end
    ok(P.labelFor(opts, "\1nonsense") == opts[1].label_func(),
        _name .. ": unknown value renders as the default option")
end

print(string.format("opds prefs: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
