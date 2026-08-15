-- tests/_live_opds_browse.lua
-- LIVE browse simulation against the public OPDS catalogues, driven from the
-- desktop. Hits the network - run MANUALLY, never from run.sh:
--
--   /usr/lib/koreader/luajit tests/_live_opds_browse.lua           (all)
--   /usr/lib/koreader/luajit tests/_live_opds_browse.lua gutenberg (one)
--   KEEP_DB=1 ... to leave the scratch database for inspection
--
-- WHY THIS EXISTS. Every OPDS bug this week was a protocol or logic problem -
-- a chain treated as finished when it was only lost, a window with entries and
-- no timestamp, a walk comparing against a target storage could not reach.
-- None of them were e-ink problems, and every one cost a deploy, a restart and
-- a hand-driven browse on the device to see. This drives the same paths
-- against the same servers in seconds, on a machine with a real keyboard.
--
-- What it drives is the REAL stack: Feed.fetch and mapEntries, the SQLite
-- window store, and the decision predicates the shelf uses (needsFetch, and
-- the read-ahead's request planning). What it cannot drive is the widget layer
-- - _opdsFetchMore needs Trapper and a coroutine - so the walk below is a
-- faithful reimplementation of that loop's SHAPE, not the loop itself. Treat a
-- pass here as "the protocol and storage agree", not "the shelf works".
local KO = os.getenv("KOREADER_DIR") or "/usr/lib/koreader"
local f = io.open(KO .. "/common/lua-ljsqlite3/init.lua", "r")
if not f then
    print("SKIP: no KOReader tree at " .. KO .. " (set KOREADER_DIR)")
    os.exit(0)
end
f:close()
package.path  = "./?.lua;./?/init.lua;" .. KO .. "/frontend/?.lua;"
             .. KO .. "/common/?.lua;" .. KO .. "/common/?/init.lua;"
             .. KO .. "/?.lua;" .. package.path
package.cpath = KO .. "/common/?.so;" .. KO .. "/libs/?.so;"
             .. KO .. "/?.so;" .. package.cpath
pcall(require, "ffi/loadlib")
package.loaded["logger"] = { dbg=function() end, info=function() end,
                             warn=function() end, err=function() end }
-- socketutil only reads Device.model for its User-Agent; stub it so this never
-- probes real hardware.
package.loaded["device"] = { model = "Linux" }

local DBDIR = (os.getenv("TMPDIR") or "/tmp") .. "/bookshelf_live_browse"
os.execute("rm -rf '" .. DBDIR .. "' && mkdir -p '" .. DBDIR .. "'")
package.loaded["datastorage"] = { getSettingsDir = function() return DBDIR end }
package.loaded["lib/bookshelf_settings_store"] = {
    read = function() return nil end, save = function() end,
    delete = function() end, flush = function() end,
}

local Feed   = require("lib/bookshelf_opds_feed")
local Window = require("lib/bookshelf_opds_window")

local CATALOGUES = {
    { key = "gutenberg", title = "Project Gutenberg",
      url = "https://m.gutenberg.org/ebooks.opds/?format=opds" },
    { key = "standard",  title = "Standard Ebooks",
      url = "https://standardebooks.org/feeds/opds" },
    { key = "manybooks", title = "ManyBooks",
      url = "http://manybooks.net/opds/index.php" },
    { key = "ia",        title = "Internet Archive",
      url = "https://bookserver.archive.org/" },
    { key = "textos",    title = "textos.info",
      url = "https://www.textos.info/catalogo.atom" },
    { key = "gallica",   title = "Gallica",
      url = "https://gallica.bnf.fr/opds" },
}

local VIEW        = 20    -- a plausible shelf page
local WALK_PAGES  = 4     -- how deep to page in the simulation
local problems    = 0
local function fail(fmt, ...)
    problems = problems + 1
    print("    PROBLEM: " .. string.format(fmt, ...))
end

-- One fetch + map + append, exactly as _storeFeedPage does it: map against the
-- url the body came FROM, file under the feed being read.
local function pull(server_key, feed_url, fetch_url)
    local body, err = Feed.fetch(fetch_url, nil, nil,
                                 { block_timeout = 10, total_timeout = 30 })
    if not body then return nil, tostring(err) end
    local catalog = Feed.parse(body)
    local mapped  = catalog and Feed.mapEntries(catalog, fetch_url, server_key)
    if not mapped then return nil, "unparseable" end
    local win = Window.load(server_key, feed_url)
    win.fetched_at = os.time()
    Window.appendPage(win, mapped)
    Window.save(server_key, feed_url, win)
    local stored = Window.load(server_key, feed_url)
    -- THE STORE MUST NOT LOSE WHAT THE PARSER FOUND.
    --
    -- This is the check that matters most, and the one this harness originally
    -- lacked: every other assertion below compares the store against itself,
    -- so a window that dropped its chain on the way to disk looked exactly
    -- like a feed that had genuinely ended, and the run reported all clear.
    -- It was hiding a real bug - a table in `search` aborting the whole
    -- metadata UPDATE - which cost next_url and items_per_page on every
    -- catalog that advertises search. Compare across the boundary, not within
    -- one side of it.
    if mapped.next_url and not stored.next_url then
        fail("%s: parser found a next link, the store lost it", feed_url)
    end
    if mapped.items_per_page and not stored.items_per_page then
        fail("%s: parser found itemsPerPage=%s, the store lost it",
             feed_url, tostring(mapped.items_per_page))
    end
    if mapped.search and not stored.search then
        fail("%s: parser found a search link, the store lost it", feed_url)
    end
    return stored, nil, mapped
end

-- The invariants every OPDS bug this week violated.
local function check(label, win)
    if (win.count or 0) > 0 and (win.fetched_at or 0) <= 0 then
        fail("%s: has %d entries but no fetch stamp (reads as never fetched)",
             label, win.count)
    end
    if win.complete and win.next_url then
        fail("%s: marked complete but still holds a next link", label)
    end
    -- The state that froze categories: entries, no next link, never seen to
    -- end. Legal, but it MUST still be fetchable or the feed is stuck.
    if (win.count or 0) > 0 and not win.next_url and not win.complete then
        if not Window.needsFetch(win, 0, (win.count or 0) + 1) then
            fail("%s: chain lost AND unfetchable - this feed can never grow",
                 label)
        end
    end
    local _page, total, open_ended = Window.slice(win, 0, VIEW)
    if total < (win.count or 0) then
        fail("%s: reports total %d below its own %d cached entries",
             label, total, win.count or 0)
    end
    if win.complete and open_ended then
        fail("%s: complete yet advertised as open-ended", label)
    end
end

local function browse(cat)
    print(("\n=== %s (%s)"):format(cat.title, cat.key))
    local sk = cat.key
    local root, err = pull(sk, cat.url, cat.url)
    if not root then print("    unreachable: " .. tostring(err)); return end
    print(("    root: %d entries, next=%s, total=%s, itemsPerPage=%s")
          :format(root.count or 0, tostring(root.next_url ~= nil),
                  tostring(root.total), tostring(root.items_per_page)))
    check("root", root)

    -- Drill into the first navigation entry, the way a tap does.
    local page = Window.slice(root, 0, root.count or 0)
    local nav
    for _i, rec in ipairs(page) do
        if rec.is_opds_nav and rec.opds and rec.opds.feed_url then nav = rec break end
    end
    if not nav then print("    (no navigation entry to drill into)"); return end
    local nav_label = nav.display_title or nav.title or "?"
    local child, cerr = pull(sk, nav.opds.feed_url, nav.opds.feed_url)
    if not child then
        fail("drill into %q failed: %s", nav_label, tostring(cerr))
        return
    end
    print(("    drill %-28s %d entries, next=%s, perPage=%s")
          :format('"' .. nav_label:sub(1, 26) .. '"', child.count or 0,
                  tostring(child.next_url ~= nil), tostring(child.items_per_page)))
    check("drill", child)

    -- Page through it, following the chain as the read-ahead does, and check
    -- that each step actually adds something.
    local url = child.next_url
    for i = 2, WALK_PAGES do
        if not url then print(("    page %d: chain ended"):format(i)) break end
        local before = child.count or 0
        local w, e = pull(sk, nav.opds.feed_url, url)
        if not w then fail("page %d fetch failed: %s", i, tostring(e)) break end
        child = w
        local added = (child.count or 0) - before
        print(("    page %d: +%d -> %d entries, next=%s")
              :format(i, added, child.count or 0, tostring(child.next_url ~= nil)))
        if added == 0 and child.next_url then
            fail("page %d added nothing yet claims another page follows " ..
                 "(a chain that cannot make progress)", i)
        end
        check("page " .. i, child)
        url = child.next_url
    end

    -- What the shelf would decide from here: does paging past what is cached
    -- ask for more, and what would the read-ahead spend to satisfy it?
    local held = child.count or 0
    local wants = Window.needsFetch(child, held, VIEW)
    local per   = child.items_per_page
    local plan  = per and math.ceil((VIEW * 5) / per) or "unknown"
    print(("    shelf view: holds %d, needsFetch past the end = %s, " ..
           "read-ahead plan = %s request(s)")
          :format(held, tostring(wants), tostring(plan)))
    if not wants and not child.complete then
        fail("would not fetch past the end, yet the feed was never seen to end")
    end
end

local only = arg and arg[1]
for _i, cat in ipairs(CATALOGUES) do
    if not only or only == cat.key then browse(cat) end
end
print(("\n%s  (%d problem%s)"):format(problems == 0 and "ALL CONSISTENT" or "PROBLEMS FOUND",
      problems, problems == 1 and "" or "s"))
if not os.getenv("KEEP_DB") then os.execute("rm -rf '" .. DBDIR .. "'")
else print("scratch db kept at " .. DBDIR) end
os.exit(problems == 0 and 0 or 1)
