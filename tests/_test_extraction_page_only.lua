-- tests/_test_extraction_page_only.lua
-- Background extraction redraws the page on screen only for books on it.
--
-- On a PW5 with part of its library never extracted, most page turns in
-- Spines were followed by the page being rebuilt (0.5-1 s, the shelf not
-- answering taps meanwhile), again and again while BIM worked: the window a
-- Spines page is cut from (~90 books) was queued and watched as the page,
-- any of them finishing rebuilt the page on screen, the poll applied each
-- book as it found it, and every turn interrupted BIM to queue the next
-- window. Now: the page's own books are queued first and the rest behind
-- them; only one of the page's own finishing redraws it, at most once per
-- BIM_APPLY_GAP_S; the poll reads each book's state without its cover blob,
-- and so sees a book BIM gave up on (getBookInfo hides any row in progress).
--
-- Drives the real method bodies, lifted out of the widget source.
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq
local src = io.open("lib/bookshelf_widget.lua"):read("*a")

local function compile(code, env, name)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, name))
        _G.setfenv(f, env)
        return f
    end
    return assert(load(code, name, "t", env))
end

-- ── The kickoff: the page's own first ────────────────────────────────────────

local rows = {}
local busy = false
local BIM = {
    max_extract_tries = 3,
    getBookInfo = function(_self, fp) return rows[fp] end,
    isExtractingInBackground = function() return busy end,
}
package.loaded["bookinfomanager"] = BIM
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(_fp, what) if what == "mode" then return "file" end return { mode = "file" } end,
}

local KICK = assert(src:match("\nfunction BookshelfWidget:_kickOffMissingMetaExtractionNow%(items, slot_w, slot_h, hero_w, hero_h, shown_n%)\n(.-)\nend\n"),
    "_kickOffMissingMetaExtractionNow moved")
local kenv = setmetatable({
    Repo = {
        bimStatus = function(_b, fp) return rows[fp] end,
        currentFilepath = function() return nil end,
    },
    BookshelfWidget = { _coverNeedsResize = function() return false end },
    UIManager = { nextTick = function(_s, fn) fn() end },
    logger = { dbg = function() end, warn = function() end },
    _gettime = function() return 0 end,
}, { __index = _G })
local kickOff = compile("local self, items, slot_w, slot_h, hero_w, hero_h, shown_n = ...\n" .. KICK, kenv, "kick")

local function kickSelf()
    local s = { fired = nil, watched = nil, _isRemoteRecord = function() return false end }
    s._fireBimExtraction = function(self, files, label) self.fired = files; self.label = label end
    s._armExtractionPoll = function(self, files) self.watched = files end
    return s
end

local function books(n)
    local out = {}
    for i = 1, n do out[i] = { filepath = "/b/" .. i .. ".epub" } end
    return out
end

t.test("Spines: the page's own books first, the rest of the window behind them", function()
    rows, busy = {}, false
    local s = kickSelf()
    kickOff(s, books(10), 100, 150, 100, 150, 4)
    eq(#s.fired, 10)
    for i = 1, 10 do eq(s.fired[i].filepath, "/b/" .. i .. ".epub") end
    eq(#s.watched, 10, "the books further on are not watched (their records would stay stand-ins)")
    for i = 1, 4 do assert(s._bim_page_set["/b/" .. i .. ".epub"], "book " .. i .. " is not the page's") end
    eq(s._bim_page_set["/b/5.epub"], nil, "a book past the page's end counts as on it")
end)

t.test("a turn onto books already queued does not stop BIM", function()
    rows, busy = {}, true
    local s = kickSelf()
    s._bim_owned_extraction, s._bim_owned_has_covers = true, true
    s._bim_submitted_set = {}
    for i = 1, 10 do s._bim_submitted_set["/b/" .. i .. ".epub"] = true end
    kickOff(s, books(10), 100, 150, 100, 150, 4)
    eq(s.fired, nil, "BIM's job was interrupted for books it already had")
end)

t.test("nothing of the page's own to wait for: BIM's job is left alone", function()
    busy = true
    rows = {}
    for i = 1, 4 do rows["/b/" .. i .. ".epub"] = { has_meta = "Y", cover_fetched = "Y", has_cover = "Y", in_progress = 0 } end
    local s = kickSelf()
    s._bim_owned_extraction, s._bim_owned_has_covers = true, true
    kickOff(s, books(10), 100, 150, 100, 150, 4)
    eq(s.fired, nil, "stopped BIM for books past the page's end")
end)

t.test("a book BIM gave up on is not queued again", function()
    busy = false
    rows = { ["/b/1.epub"] = { in_progress = 3 } }   -- has_meta nil, three tries
    local s = kickSelf()
    kickOff(s, books(1), 100, 150, 100, 150, nil)
    eq(s.fired, nil, "re-queued on every page it shows on")
end)

t.test("Covers and List (no shown count): the page is every item", function()
    rows, busy = {}, false
    local s = kickSelf()
    kickOff(s, books(3), 100, 150, 100, 150, nil)
    for i = 1, 3 do assert(s._bim_page_set["/b/" .. i .. ".epub"]) end
end)

-- ── Applying what finished ──────────────────────────────────────────────────

local APPLY = assert(src:match("\nfunction BookshelfWidget:_applyExtractionReady%(%)\n(.-)\nend\n"), "_applyExtractionReady moved")
local GAP = tonumber(src:match("local BIM_APPLY_GAP_S = ([%d%.]+)"))

local function applySetup()
    local now = 100
    local um = { queue = {} }
    function um:scheduleIn(d, fn) self.queue[#self.queue + 1] = { d = d, fn = fn } end
    local light = {}
    local env = setmetatable({
        UIManager = um,
        _gettime = function() return now end,
        Repo = { lightMetaReady = function(p) light[#light + 1] = p end, currentFilepath = function() return nil end },
        require = function(name)
            if name == "lib/bookshelf_scaled_cover_cache" then return { drop = function() end } end
            return require(name)
        end,
        BIM_APPLY_GAP_S = GAP,
    }, { __index = _G })
    local apply = compile("local self = ...\n" .. APPLY, env, "apply")
    local s = { swaps = 0, armed = 0, _inner_vgroup = {}, _shelf_dims = {}, _expanded = true }
    s._isSpineMode = function() return false end
    s._swapShelvesInPlace = function(self) self.swaps = self.swaps + 1 end
    s._pageAheadArm = function(self) self.armed = self.armed + 1 end
    s._inputBusyFor = function() return -1 end
    s._applyExtractionReady = function(self) return apply(self) end
    return s, um, light, function(dt) now = now + dt end
end

local function ready(s, ...)
    local acc = s._bim_ready_acc or { paths = {}, covers = {} }
    for _i, fp in ipairs({ ... }) do acc.paths[fp] = true end
    s._bim_ready_acc = acc
end

t.test("a book finishing off the page refreshes its record, not the page", function()
    local s, _um, light = applySetup()
    s._bim_page_set = { ["/b/1.epub"] = true }
    ready(s, "/b/9.epub")
    s:_applyExtractionReady()
    eq(s.swaps, 0, "the page on screen was rebuilt for a book not on it")
    eq(#light, 1, "its record was not refreshed")
    eq(s.armed, 1, "the page built ahead was not built again")
end)

t.test("a book on the page redraws it; more within the gap wait and go together", function()
    assert(GAP and GAP >= 1, "no gap between applications")
    local s, um, _light, advance = applySetup()
    s._bim_page_set = { ["/b/1.epub"] = true, ["/b/2.epub"] = true, ["/b/3.epub"] = true }
    ready(s, "/b/1.epub")
    s:_applyExtractionReady()
    eq(s.swaps, 1, "the first book on the page did not show")
    advance(0.5); ready(s, "/b/2.epub"); s:_applyExtractionReady()
    advance(0.5); ready(s, "/b/3.epub"); s:_applyExtractionReady()
    eq(s.swaps, 1, "the page was rebuilt for each book as it landed")
    eq(#um.queue, 1, "one application waits, not one per book")
    advance(GAP)
    um.queue[1].fn()
    eq(s.swaps, 2)
    eq(s._bim_ready_acc, nil)
end)

t.test("a redraw waits for the reader to stop swiping", function()
    -- On a PW5 the poll's redraw (0.5-0.9 s) landed between swipes.
    local s, um = applySetup()
    s._inputBusyFor = function() return 1.2 end
    s._bim_page_set = { ["/b/1.epub"] = true }
    ready(s, "/b/1.epub")
    s:_applyExtractionReady()
    eq(s.swaps, 0, "the page was rebuilt mid-swipe")
    eq(#um.queue, 1)
    eq(um.queue[1].d, 1.2, "it does not wait for the quiet")
    s._inputBusyFor = function() return -1 end
    um.queue[1].fn()
    eq(s.swaps, 1)
end)

-- ── The poll reads the state, not the cover ─────────────────────────────────

t.test("the poll and the kickoff read the state without the cover blob", function()
    local poll = src:match("function BookshelfWidget:_pollExtraction%(.-\nend\n")
    assert(poll:find("Repo.bimStatus(BIM, f.filepath)", 1, true), "the poll reads whole rows")
    assert(KICK:find("Repo.bimStatus(BIM, fp)", 1, true), "the kickoff reads whole rows")
    local R = io.open("lib/bookshelf_book_repository.lua"):read("*a")
    local sql = assert(R:match('Repo._status_sql = (.-)\nfunction'))
    assert(not sql:find("cover_bb", 1, true), "the state read selects the cover")
    assert(not sql:find("in_progress=0", 1, true), "the state read hides rows in progress, as getBookInfo does")
end)

t.done()
