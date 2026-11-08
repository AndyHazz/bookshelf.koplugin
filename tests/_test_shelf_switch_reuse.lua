-- tests/_test_shelf_switch_reuse.lua
-- A shelf switch reuses what does not change with the shelf:
--   * the book card (the hero follows the book, not the shelf), when what it
--     shows is unchanged (_heroSig / _heroReuse);
--   * the Spines whole-list fetch of shelves switched away from, kept beside
--     the one on screen under the same expiry (_spine_fetch_others);
--   * the whole-shelf paint goes offscreen and is copied to the screen
--     (_paintWhole): a PW5's framebuffer is slow to read, and alpha blending
--     reads it.
-- Rig-verified: whole screen identical (frozen clock) across cache off/on.
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq
local W = io.open("lib/bookshelf_widget.lua"):read("*a")

local function body(name)
    local i = assert(W:find("function BookshelfWidget:" .. name .. "(", 1, true), name)
    return W:sub(i, (W:find("\nfunction ", i + 10, true) or #W))
end

local function compile(code, env)
    if setfenv then
        local f = assert(loadstring(code)); setfenv(f, env); return f
    end
    return assert(load(code, "chunk", "t", env))
end

-- ── The book card ────────────────────────────────────────────────────────────

local REUSE = assert(W:match("\nfunction BookshelfWidget:_heroReuse%(sig%)\n(.-)\nend\n"))
local function reuse(self_, sig)
    local env = setmetatable({
        HERO_KEPT_MAX = 3,
        require = function(n)
            if n == "ui/widget/verticalspan" then return { new = function() return { span = true } end } end
            return require(n)
        end,
    }, { __index = _G })
    return compile("local self, sig = ...\n" .. REUSE, env)(self_, sig)
end

t.test("the card on screen is taken over when built for the same thing", function()
    local card = { card = true }
    local parent = { card }
    local s = { _hero_card = card, _hero_parent = parent, _hero_sig = "A" }
    eq(reuse(s, "A"), card)
    eq(parent[1].span, true, "the card is still in the tree the rebuild frees")
end)

t.test("a card for another look is kept, and taken again on switching back", function()
    local cardA = { card = "A" }
    local parent = { cardA }
    local s = { _hero_card = cardA, _hero_parent = parent, _hero_sig = "A" }
    eq(reuse(s, "B"), nil, "a card for another look was used")
    eq(parent[1].span, true, "the card left in the tree is freed with it")
    local cardB = { card = "B" }
    s._hero_card, s._hero_parent, s._hero_sig = cardB, { cardB }, "B"
    eq(reuse(s, "A"), cardA, "the first look's card was not kept")
    eq(s._hero_card, cardA)
end)

t.test("past the limit the oldest kept card is freed", function()
    local freed = {}
    local s = { _hero_kept = {} }
    for i = 1, 4 do
        local c = { free = function() freed[#freed + 1] = i end }
        s._hero_card, s._hero_parent, s._hero_sig = c, { c }, "S" .. i
        reuse(s, "none")
    end
    eq(#s._hero_kept, 3)
    eq(freed[1], 1, "the oldest card was kept past the limit")
end)

t.test("only a switch reuses it, only the book card, and the signature holds what it shows", function()
    local rb = body("_rebuild")
    assert(rb:find("hero = switching and self:_heroReuse(sig) or nil", 1, true), "a rebuild that is not a switch reuses the card")
    assert(rb:find("self:_pageCacheClear()\n        -- ...and the book cards kept for switching back (_heroReuse).\n        self:_heroKeptClear()", 1, true),
        "a rebuild that is not a switch keeps cards that may be stale")
    assert(body("onCloseWidget"):find("self:_heroKeptClear()", 1, true), "closing keeps the cards")
    local sig = body("_heroSig")
    for _i, f in ipairs({ "self._preview_book", "Repo.currentFilepath", "Repo.dataGeneration",
            "Screen.night_mode", "TP.lookKey", "hero_h" }) do
        assert(sig:find(f, 1, true), "the card's signature leaves out " .. f)
    end
end)

-- ── The Spines lists of other shelves ────────────────────────────────────────

t.test("every expiry reaches the other shelves' lists too", function()
    assert(body("_expireSpineFetch"):find("for i = 1, #others do others[i].at = -math.huge end", 1, true))
    eq(select(2, W:gsub("if others then for i = 1, #others do others%[i%]%.at = 0 end end", "")), 2,
        "a source change or new dates leave other lists")
    assert(W:find("self._spine_fetch_cache = nil\n            self._spine_fetch_others = nil", 1, true),
        "the collation toggle leaves other shelves' lists in the old order")
    assert(body("_spineCachedFetch"):find("elseif o.key ~= cur.key and #kept < 3 then", 1, true), "the kept lists are not bounded")
end)

t.test("switching back takes the shelf's own list; another's is kept beside it", function()
    local src = assert(W:match("\nfunction BookshelfWidget:_spineCachedFetch%(n%)\n(.-)\nend\n"))
    local fetch = assert(load("return function(self, n)\n" .. src .. "\nend", "f", "t",
        { os = os, tostring = tostring, type = type }))()
    local w = { chip = "a", _drilldown_path = {}, fetches = 0 }
    function w:_fetchChipItems() self.fetches = self.fetches + 1; return { self.chip } end
    function w:_spineItemsSig(items) return tostring(#items) end
    function w:_prepareSpineItems(items) return items end
    fetch(w); eq(w.fetches, 1)
    w.chip = "b"; fetch(w); eq(w.fetches, 2)
    w.chip = "a"; eq(fetch(w)[1], "a"); eq(w.fetches, 2, "switching back fetched the whole list again")
    w.chip = "b"; eq(fetch(w)[1], "b"); eq(w.fetches, 2)
    for _i, k in ipairs({ "c", "d", "e" }) do w.chip = k; fetch(w) end
    w.chip = "a"; fetch(w)
    eq(w.fetches, 6, "more than three other lists were kept")
end)

-- ── The whole-shelf paint ────────────────────────────────────────────────────

t.test("a whole paint to the screen goes offscreen first, wearing the night flag", function()
    local p = body("paintTo")
    eq(select(2, p:gsub("self:_paintWhole%(bb, x, y%)", "")), 2, "a whole paint still goes straight to the screen")
    local whole = body("_paintWhole")
    assert(whole:find("if bb ~= Screen.bb or BookshelfWidget._paint_direct then", 1, true))
    assert(whole:find("BookshelfWidget._screenLike, W, H", 1, true))
    local like = W:match("function BookshelfWidget._screenLike%(w, h%)(.-)\nend\n")
    assert(like and like:find("setInverse(inv)", 1, true), "night mode painted un-inverted offscreen")
end)

t.test("page counts a paint writes are marked, and the planner plans without them", function()
    local CP = io.open("lib/bookshelf_cover_progress.lua"):read("*a")
    assert(CP:find('if book._page_src == nil then book._page_src = "paint" end', 1, true),
        "a paint's count reads as BIM's own on the next plan")
    local SS = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")
    assert(SS:find('local pages = (src._page_src ~= "paint") and src.page_count or nil', 1, true),
        "the planner sizes a book from a paint's count")
    assert(SS:find('if pc and (not src.page_count or src._page_src == "paint") then', 1, true),
        "a paint's count stops the planner reading the book's own")
end)

t.test("the background warm-up reaches the shelves inside a shelf of shelves", function()
    local q = body("_queueWarmForVisible")
    assert(q:find('local sk = "sub:" .. tostring(c.id)', 1, true), "a shelf of shelves' shelves are left cold")
    local step = body("_chipPreloadStep")
    assert(step:find("pcall(self._subShelfCoverFps, self, tab, 4)", 1, true)
        and step:find("pcall(self._subShelfMemberFps, self, tab)", 1, true),
        "the warm-up does not read what a shelf's tile reads")
    assert(body("_subShelfCoverFps"):find("{ light_only = true }", 1, true), "tile covers build whole records")
end)

t.test("a shelf of shelves' own shelves warm one per step BEFORE it, and only after a long pause", function()
    -- On a PW5 the shelf of shelves' chip, warmed first, read all seven of
    -- its shelves cold in one 2.4 s step a swipe could not get past.
    local Q = assert(W:match("\nfunction BookshelfWidget:_queueWarmForVisible%(%)\n(.-)\nend\n"))
    local scheduled = 0
    local tabs = {
        sos = { id = "sos", shelves = true },
        a = { id = "a" }, b = { id = "b" }, plain = { id = "plain" },
    }
    local env = setmetatable({
        BookshelfSettings = { nilOrTrue = function() return true end },
        UIManager = { scheduleIn = function() scheduled = scheduled + 1 end },
        CHIP_PRELOAD_DELAY_S = 1,
        require = function(n)
            if n == "lib/bookshelf_tab_model" then
                return {
                    getById = function(id) return tabs[id] end,
                    isShelves = function(t) return t.shelves end,
                    childrenOf = function(id) if id == "sos" then return { tabs.a, tabs.b } end return {} end,
                }
            end
            return require(n)
        end,
    }, { __index = _G })
    local s = { chip = "plain", _drilldown_path = {} }
    function s:_visibleWarmKeys() return { "plain", "sos" } end
    function s:_chipPreloadStep() end
    compile("local self = ...\n" .. Q, env)(s)
    eq(table.concat(s._chip_preload_keys, " "), "sub:a sub:b sos",
        "the shelf of shelves warms before its shelves (all of them cold, in one step)")
    eq(scheduled, 1)
    local quiet = tonumber(W:match("local CHIP_PRELOAD_QUIET_S = ([%d%.]+)"))
    assert(quiet and quiet > tonumber(W:match("local PAGE_AHEAD_QUIET_S = ([%d%.]+)")),
        "a whole-shelf fetch waits no longer than a sliced page build")
    assert(body("_chipPreloadStep"):find("self:_inputBusyFor(CHIP_PRELOAD_QUIET_S)", 1, true))
end)

t.test("a grouped shelf compiles its filter once per pass, not once per group", function()
    local R = io.open("lib/bookshelf_book_repository.lua"):read("*a")
    local f = assert(R:match("\n_shapeHasFilteredBook = function%(shape, filter%)\n(.-)\nend\n"))
    assert(f:find("if memo and memo.filter == filter and now - memo.at <= 1 then", 1, true))
end)

t.done()
