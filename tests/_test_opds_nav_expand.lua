-- tests/_test_opds_nav_expand.lua
-- The decision _expandOpdsNav makes when the user taps an OPDS navigation tile.
--
-- A catalog like Project Gutenberg models every work as a subcatalog holding
-- exactly one acquisition entry, so tapping a "folder" used to drill into a
-- shelf of one book, which the user then had to tap again and back out of
-- twice. The tile flattening in the repo already collapses those tiles once
-- their child feed is cached; this is the TAP side of the same predicate, plus
-- the case the flattening can never cover -- a child feed nothing has fetched
-- yet, where the tap is the user action that licenses the fetch.
--
-- What is asserted, in the four states a tap can land in:
--   cached + folder of one   -> the book's own modal, no drill, arm NOT spent
--   cached + anything else   -> drill exactly as before, arm armed
--   uncached                 -> fetch the child feed first, then decide again
--   uncached + fetch failed  -> stay put (the fetch showed its own notice)
--
-- Usage (from plugin root): lua tests/_test_opds_nav_expand.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

-- ── Minimal class system ───────────────────────────────────────────────────
local function make_widget_class()
    local cls = {}
    cls.__index = cls
    function cls:extend(props)
        local sub = props or {}
        sub.__index = sub
        setmetatable(sub, { __index = cls })
        return sub
    end
    return cls
end

-- ── Recorders the stubs write into ─────────────────────────────────────────
local shown = {}   -- every widget handed to UIManager:show

-- ── KOReader stubs (the load-time set the download-refresh suite installs) ──
local widget_cls = make_widget_class()
package.loaded["ui/widget/container/inputcontainer"]  = widget_cls
package.loaded["ui/widget/container/framecontainer"]  = make_widget_class()
package.loaded["ui/widget/container/centercontainer"] = make_widget_class()
package.loaded["ui/widget/verticalgroup"]             = make_widget_class()
package.loaded["ui/widget/horizontalgroup"]           = make_widget_class()
package.loaded["ui/widget/textwidget"]                = make_widget_class()
package.loaded["ui/widget/textboxwidget"]             = make_widget_class()
package.loaded["ui/widget/verticalspan"]              = make_widget_class()
package.loaded["ui/geometry"]     = { new = function(_, t) return t or {} end }
package.loaded["ui/gesturerange"] = { new = function(_, t) return t or {} end }
package.loaded["ui/size"] = {
    padding = { default = 4, large = 8, fullscreen = 16 },
    item    = { height_default = 30 },
    border  = { thin = 1 },
    line    = { medium = 1 },
}
package.loaded["ui/font"] = { getFace = function() return {} end }
package.loaded["ui/uimanager"] = {
    setDirty       = function() end,
    close          = function() end,
    show           = function(_, w) shown[#shown + 1] = w end,
    nextTick       = function(_, fn) if fn then fn() end end,
    scheduleIn     = function() end,
    unschedule     = function() end,
    isWidgetShown  = function() return false end,
}
package.loaded["ffi/blitbuffer"] = { COLOR_BLACK = 0, COLOR_WHITE = 0xFF,
                                     gray = function(v) return v end }
package.loaded["device"] = {
    screen = {
        getWidth    = function() return 1236 end,
        getHeight   = function() return 1648 end,
        scaleBySize = function(_, n) return n end,
    },
    isKindle = function() return false end,
}
package.loaded["logger"] = { dbg = function() end, warn = function() end,
                             err = function() end, info = function() end }
package.loaded["lib/bookshelf_settings_store"] = {
    read        = function(_, default) return default end,
    save        = function() end,
    delete      = function() end,
    flush       = function() end,
    isTrue      = function() return false end,
    nilOrTrue   = function() return true end,
    microInHero = function() return false end,
}
package.loaded["lib/bookshelf_i18n"] = {
    gettext  = function(t) return t end,
    ngettext = function(s, p, n) return n == 1 and s or p end,
}
package.loaded["lib/bookshelf_hero_card"] = {
    new = function() return {} end,
    buildStatusRow = function() return nil end,
}
package.loaded["lib/bookshelf_chip_bar"]  = { new = function() return {} end }
package.loaded["lib/bookshelf_shelf_row"] = {}
package.loaded["lib/bookshelf_cover_progress"] = {
    decide          = function() return { bar = false, bar_pct = 0, glyph = nil } end,
    resolvedColors  = function() return {} end,
    badgeSize       = function(n) return n end,
    glyphRenderedH  = function() return 0 end,
}
package.loaded["lib/bookshelf_spine_widget"] = {
    new                 = function() return {} end,
    setDraftMode        = function() end,
    trueAspectBoxHeight = function(_w, _b, max_h) return max_h end,
    downloadedTickOffset = function() return 0, 0 end,
}
package.loaded["ui/widget/notification"] = { new = function(_, s) return s end }
package.loaded["ui/widget/infomessage"]  = { new = function(_, s) return s end }

-- ── The two modules the decision actually consults ─────────────────────────
-- Both are captured by the widget at load time (Repo) or required per call
-- (OpdsWindow), so both are installed before the dofile below.
local lone_answer   -- what Repo.opdsLoneChildBook hands back
local lone_calls = 0
package.loaded["lib/bookshelf_book_repository"] = {
    invalidateWalkCache = function() end,
    opdsLoneChildBook = function(server_key, feed_url)
        lone_calls = lone_calls + 1
        if type(lone_answer) == "function" then return lone_answer(server_key, feed_url) end
        return lone_answer
    end,
}
local window_fetched_at = 0   -- 0 == the "never fetched" shape load() returns on a miss
package.loaded["lib/bookshelf_opds_window"] = {
    load = function(_server_key, _feed_url)
        return { entries = {}, total = nil, next_url = nil,
                 fetched_at = window_fetched_at }
    end,
}

_G.G_reader_settings = {
    readSetting = function() return nil end,
    saveSetting = function() end,
    isTrue      = function() return false end,
    flush       = function() end,
}

-- The widget's perf-log timer probes require("socket").gettime at load time.
-- Installed BEFORE the catch-all mock searcher below: the mock would answer
-- that probe with a function returning a mock TABLE, and every
-- "[bookshelf perf]" line doing (_gettime() - t0) would crash on it.
package.loaded["socket"] = { gettime = function() return os.clock() end }

-- Benign mock for every KOReader core dep the widget pulls in at load time but
-- this path never reads a real value from.
local function mock()
    local m = {}
    return setmetatable(m, {
        __index = function() return function() return mock() end end,
        __call  = function() return mock() end,
    })
end
table.insert(package.searchers or package.loaders, function(_name)
    return function() return mock() end
end)

local BW = dofile("lib/bookshelf_widget.lua")

local t = dofile("tests/_helpers.lua").runner()
local function eq(a, e, msg)
    if a ~= e then
        error((msg or "") .. " expected=" .. tostring(e) .. " got=" .. tostring(a), 2)
    end
end

-- A shelf stand-in recording the three things the decision can end in, plus the
-- fetch it can start. _markOpdsNav and _opdsFetchBusy are the REAL methods --
-- the arm/consume pairing is exactly what this suite is about.
local function shelf()
    local s = setmetatable({}, { __index = BW })
    s.drills   = {}
    s.modals   = {}
    s.fetches  = {}
    s.previews = {}
    s._drillInto = function(_self, entry) s.drills[#s.drills + 1] = entry end
    s._showRemoteBookInfo = function(_self, book) s.modals[#s.modals + 1] = book end
    s._previewBook = function(_self, book) s.previews[#s.previews + 1] = book end
    s._opdsFetchMore = function(_self, tab, want, replace, on_done)
        s.fetches[#s.fetches + 1] = { tab = tab, want = want,
                                      replace = replace, on_done = on_done }
    end
    s._viewSize = function() return 12 end
    return s
end

local NAV = {
    filepath = "OPDS://deadbeef/nav/urn:work:1",
    kind = "opds_nav", is_opds_nav = true, is_remote = true,
    title = "Moby Dick",
    opds = { feed_url = "http://host/work/1" },
}
local LONE = {
    filepath = "OPDS://deadbeef/urn:uuid:1", title = "Moby Dick", is_remote = true,
    description = "Call me Ishmael.",
    opds = { acquisitions = { { type = "application/epub+zip",
                                href = "http://host/1.epub" } } },
}

local function fresh()
    shown, lone_calls = {}, 0
    local s = shelf()
    BW.live = s
    return s
end

-- ── cached + folder of one: the book itself, not a shelf of one ────────────
-- Same journey as a plain book tap now: the first tap stages the flattened
-- book in the hero preview; a second tap on the same tile opens the modal.

t.test("a cached folder of one previews the book instead of drilling", function()
    window_fetched_at, lone_answer = 100, LONE
    local s = fresh()
    s:_expandOpdsNav(NAV)
    eq(#s.previews, 1, "preview count:")
    eq(s.previews[1], LONE, "the hero gets the record the repo decorated")
    eq(#s.modals, 0, "modal count:")
    eq(#s.drills, 0, "drill count:")
    eq(#s.fetches, 0, "fetch count:")
end)

t.test("a re-tap on the previewed folder of one opens the book's modal", function()
    window_fetched_at, lone_answer = 100, LONE
    local s = fresh()
    s._preview_book = LONE          -- the first tap already staged the hero
    s:_expandOpdsNav(NAV)
    eq(#s.modals, 1, "modal count:")
    eq(s.modals[1], LONE, "the modal gets the record the repo decorated")
    eq(#s.previews, 0, "no re-preview on the re-tap:")
    eq(#s.drills, 0, "drill count:")
end)

t.test("in micro-hero mode the re-tap swaps the hero back instead", function()
    window_fetched_at, lone_answer = 100, LONE
    local s = fresh()
    s._preview_book = LONE
    s._hero_mode = "micro"          -- preview state is stale in micro mode
    s:_expandOpdsNav(NAV)
    eq(#s.previews, 1, "preview count:")
    eq(#s.modals, 0, "modal count:")
end)

-- The arm is a ONE-SHOT licence for the next rebuild to hit the network. This
-- path does not rebuild at all, so arming would leave a live arm behind for
-- whatever passive rebuild came next (a cover landing, the file poll) to spend
-- on a fetch the user never asked for.
t.test("the book-preview path leaves the OPDS fetch arm untouched", function()
    window_fetched_at, lone_answer = 100, LONE
    local s = fresh()
    s:_expandOpdsNav(NAV)
    eq(s._opds_nav_pending, nil, "nav arm after the preview path:")
end)

-- ── cached + anything else: the drill, exactly as before ───────────────────

t.test("a cached multi-book subcatalog still drills in, arm armed", function()
    window_fetched_at, lone_answer = 100, nil
    local s = fresh()
    s:_expandOpdsNav(NAV)
    eq(#s.drills, 1, "drill count:")
    eq(s.drills[1].kind, "opds_nav", "drill frame kind:")
    eq(s.drills[1].payload.server_key, "deadbeef", "server key off the pseudo-path:")
    eq(s.drills[1].payload.feed_url, "http://host/work/1", "feed url:")
    eq(s.drills[1].label, "Moby Dick", "drill label:")
    eq(s._opds_nav_pending, true, "the drill arms the fetch gate:")
    eq(#s.modals, 0, "modal count:")
end)

-- ── uncached: the tap is what licenses the fetch ───────────────────────────

t.test("an uncached child feed is fetched before anything is decided", function()
    window_fetched_at, lone_answer = 0, LONE
    local s = fresh()
    s:_expandOpdsNav(NAV)
    eq(#s.fetches, 1, "fetch count:")
    local f = s.fetches[1]
    eq(f.tab.source.kind, "opds", "synthesised tab source kind:")
    eq(f.tab.source.id, "deadbeef", "synthesised tab server id:")
    eq(f.tab.source.feed_url, "http://host/work/1", "the CHILD feed, not the chip's:")
    eq(f.tab.label, "Moby Dick", "the tile's own label rides the progress line:")
    eq(f.replace, false, "extends the child window rather than replacing it:")
    eq(#s.drills, 0, "nothing drills before the feed has landed")
    eq(#s.modals, 0, "and nothing opens either")
    -- The fetch is called directly, so there is no rebuild for an arm to gate.
    eq(s._opds_nav_pending, nil, "the pre-fetch arms nothing:")
    -- No point asking a window nothing has ever fetched.
    eq(lone_calls, 0, "the lone-child predicate is not consulted while uncached:")
end)

t.test("the fetch continuation re-decides against the window it just saved", function()
    window_fetched_at, lone_answer = 0, LONE
    local s = fresh()
    s:_expandOpdsNav(NAV)
    assert(s.fetches[1] and s.fetches[1].on_done, "no completion callback was passed")
    window_fetched_at = 100        -- the fetch landed and saved a window
    s.fetches[1].on_done()
    eq(#s.previews, 1, "the folder of one now previews as its book:")
    eq(#s.fetches, 1, "and no second fetch is started:")
    eq(#s.drills, 0, "drill count:")
end)

t.test("a fetched multi-book child drills in from the continuation", function()
    window_fetched_at, lone_answer = 0, nil
    local s = fresh()
    s:_expandOpdsNav(NAV)
    window_fetched_at = 100
    s.fetches[1].on_done()
    eq(#s.drills, 1, "drill count:")
    eq(s._opds_nav_pending, true, "the drill still arms the fetch gate:")
    eq(#s.fetches, 1, "and no second fetch:")
end)

-- The re-entry guard. A failed fetch (server down, empty feed, user cancelled)
-- leaves the window exactly as uncached as it was, so an unguarded re-entry
-- would fetch again, and again, one toast per round.
t.test("a failed fetch stays put rather than looping", function()
    window_fetched_at, lone_answer = 0, LONE
    local s = fresh()
    s:_expandOpdsNav(NAV)
    -- window_fetched_at stays 0: nothing was saved.
    s.fetches[1].on_done()
    eq(#s.fetches, 1, "no second fetch after a failed one:")
    eq(#s.drills, 0, "no drill into a subcatalog we could not read:")
    eq(#s.modals + #s.previews, 0, "and no modal or preview:")
end)

-- ── busy: bail politely, don't queue a second Trapper coroutine ────────────

t.test("a tap during another catalog operation bails with a notice", function()
    window_fetched_at, lone_answer = 0, LONE
    local s = fresh()
    s._opds_download_started_at = os.time()
    s:_expandOpdsNav(NAV)
    eq(#s.fetches, 0, "fetch count while busy:")
    eq(#s.drills, 0, "drill count while busy:")
    eq(#shown, 1, "one notification shown:")
    eq(shown[1].text, "The catalog is busy. Try again in a moment.", "notice text:")
end)

-- A cached tile is pure local work and never queues anything, so the busy test
-- must not block it -- that would make a folder unopenable during a download.
t.test("a cached tile still opens while the catalog is busy", function()
    window_fetched_at, lone_answer = 100, LONE
    local s = fresh()
    s._opds_download_started_at = os.time()
    s:_expandOpdsNav(NAV)
    eq(#s.previews, 1, "preview count while busy:")
    eq(#shown, 0, "no busy notice for a decision that needs no network:")
end)

-- ── guards ─────────────────────────────────────────────────────────────────

t.test("a record with no feed url or no server key does nothing at all", function()
    window_fetched_at, lone_answer = 100, LONE
    local s = fresh()
    s:_expandOpdsNav(nil)
    s:_expandOpdsNav({ filepath = "OPDS://k/nav/x", opds = {} })
    s:_expandOpdsNav({ filepath = "/local/path", opds = { feed_url = "http://h/f" } })
    eq(#s.modals + #s.drills + #s.fetches, 0, "actions taken on a malformed tile:")
    eq(s._opds_nav_pending, nil, "and nothing armed:")
end)

t.done()
