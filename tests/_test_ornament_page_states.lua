-- tests/_test_ornament_page_states.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["logger"] = { dbg = function() end, info = function() end,
                             warn = function() end, err = function() end }
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq
local src = io.open("lib/bookshelf_widget.lua"):read("*a")

local function method(name)
    local body = src:match("\n(function BookshelfWidget:" .. name .. "%(.-\nend)\n")
    assert(body, name .. " not found")
    local W = {}
    local env = setmetatable({ BookshelfWidget = W, require = require, logger = package.loaded["logger"] },
                             { __index = _G })
    local f
    if _G.setfenv then f = assert(loadstring(body)); setfenv(f, env)
    else f = assert(load(body, name, "t", env)) end
    f()
    return W[name]
end

local function stub(cursor, skip)
    package.loaded["lib/bookshelf_ornament_deck"] = nil
    local D = dofile("lib/bookshelf_ornament_deck.lua")
    package.loaded["lib/bookshelf_ornament_deck"] = D
    local self = { _cursor = cursor, _spine_fetch_cache = { page_orn = {} }, builds = 0 }
    self._spineSkip = function() return skip or 0 end
    self._nShelves = function() return 2 end
    self._ornSig = function() return "sig" end
    self._ornKey = method("_ornKey")
    self._spinePageFirsts = function(s, build, _dims)
        if build then
            s.builds = s.builds + 1
            s._spine_fetch_cache.page_orn["5:0"] = { n = 9, shelf = 4, bnd = 2, owed = {} }
        end
    end
    return self, D
end

t.test("the chip's first page starts from nothing, with no map build", function()
    local self = stub(1, 0)
    local st = method("_ornStartState")(self)
    eq(st.n, 0); eq(self.builds, 0)
end)

t.test("a known page's state is used without building the map", function()
    local self = stub(5, 0)
    self._spine_fetch_cache.page_orn["5:0"] = { n = 3, shelf = 2, bnd = 1, owed = {} }
    self._spine_fetch_cache.orn_sig = "sig"
    eq(method("_ornStartState")(self).n, 3); eq(self.builds, 0)
end)

t.test("an unknown page builds the map once and uses what it recorded", function()
    local self = stub(5, 0)
    self._spine_fetch_cache.orn_sig = "sig"
    eq(method("_ornStartState")(self).n, 9); eq(self.builds, 1)
end)

t.test("no map (a windowed source): the nearest earlier known page, never a crash", function()
    local self = stub(7, 0)
    self._spine_fetch_cache.orn_sig = "sig"
    self._spinePageFirsts = function() end
    self._spine_fetch_cache.page_orn["3:0"] = { n = 4, shelf = 2, bnd = 0, owed = {} }
    eq(method("_ornStartState")(self).n, 4)
end)

t.test("a borrowed state is kept: the page deals from it on every later render", function()
    -- PW5: page 6 dealt from one borrowed state while parked and from
    -- another half a minute after the book closed, so its pieces swapped on
    -- screen (maintainer). Once a page has borrowed, that is its state.
    local self = stub(7, 0)
    self._spine_fetch_cache.orn_sig = "sig"
    eq(method("_ornStartState")(self).n, 9, "test premise: the nearest earlier page (5:0) is borrowed")
    self._spine_fetch_cache.page_orn["6:0"] = { n = 4, shelf = 3, bnd = 1, owed = {} }
    eq(method("_ornStartState")(self).n, 9, "a later render borrowed a different state")
end)

t.test("a changed signature drops every state but the current page's, unless it was a shuffle", function()
    local self, D = stub(5, 0)
    self._spine_fetch_cache.page_orn = { ["5:0"] = { n = 3, shelf = 2, bnd = 1, owed = {} },
                                         ["9:0"] = { n = 7, shelf = 4, bnd = 1, owed = {} } }
    self._spine_fetch_cache.orn_sig, self._spine_fetch_cache.orn_epoch = "old", D.epoch()
    eq(method("_ornStartState")(self).n, 3, "a swap lost the current page's state")
    eq(self._spine_fetch_cache.page_orn["9:0"], nil, "a later page's stale state survived")
    self._spine_fetch_cache.orn_sig = "old"
    D.shuffle({ "a", "b" })
    self._spinePageFirsts = function() end
    eq(method("_ornStartState")(self).n, 0, "a shuffle kept the old layout")
end)

t.test("the render plans from the start state and records the next page's", function()
    local b = src:match("\nfunction BookshelfWidget:_buildSpineRows%(.-%)\n(.-)\nend\n")
    assert(b:find("opts.orn_state   = self:_ornStartState({ content_w = content_w, shelf_h = shelf_h })", 1, true))
    assert(b:find("c.page_orn[self:_ornKey(self._cursor + (plan.next_item - 1), plan.next_skip or 0)] = plan.orn_end", 1, true))
end)

t.test("the page map records every page's state", function()
    local b = src:match("\nfunction BookshelfWidget:_spinePageFirsts%(build, dims%)\n(.-)\nend\n")
    assert(b:find("for k, st in pairs(plan.page_orn or {}) do", 1, true))
end)

t.test("shuffle ornaments reshuffles the saved order and forgets every page", function()
    local b = src:match("\nfunction BookshelfWidget:onBookshelfShuffleOrnaments%(.-%)\n(.-)\nend\n")
    assert(b and b:find('require("lib/bookshelf_ornament_deck").shuffle(self.chip)', 1, true))
    assert(b:find("self:_dropOrnPages(false)", 1, true))
end)

t.test("a refetch of the same list keeps the page states; a changed list drops them", function()
    -- The fetch cache lives 30s. Dropping the states with it made every page
    -- turn after half a minute's reading rebuild the whole page map.
    local fetch = method("_spineCachedFetch")
    local list = { { filepath = "/a" }, { filepath = "/b" }, { filepath = "/c" } }
    local self = { chip = "all", _drilldown_path = nil, _cursor = 2 }
    self._fetchChipItems = function() local o = {} for i, x in ipairs(list) do o[i] = x end return o end
    self._spineItemsSig = method("_spineItemsSig")
    self._anchorSpineCursor = method("_anchorSpineCursor")
    self._setSpineCursor = self._setSpineCursor or function(s, c, k) s._cursor, s._skip = c, k or 0 end
    self._spineSkip = self._spineSkip or function(s) return s._skip or 0 end
    self._ornKey = self._ornKey or method("_ornKey")
    self._spineSkip = function() return 0 end
    self._ornKey = method("_ornKey")
    fetch(self, 400)
    local c = self._spine_fetch_cache
    c.page_orn, c.orn_sig, c.orn_epoch = { ["2:0"] = { n = 5, shelf = 2, bnd = 0, owed = {} },
                                           ["9:0"] = { n = 8, shelf = 4, bnd = 1, owed = {} } }, "s", 0
    c.at = 0                                     -- expired
    fetch(self, 400)
    assert(self._spine_fetch_cache ~= c, "test premise: the cache was not refetched")
    eq(self._spine_fetch_cache.page_orn["2:0"].n, 5, "the same list lost its page states")
    eq(self._spine_fetch_cache.orn_sig, "s")
    self._spine_fetch_cache.at = 0
    table.remove(list, 2)
    fetch(self, 400)
    -- A changed list (a book closed: its status, its progress) re-learns
    -- every page but the one on screen, which keeps dealing as it did: the
    -- shelf must not reshuffle under the reader (maintainer).
    local po = self._spine_fetch_cache.page_orn
    eq(po and po["2:0"] and po["2:0"].n, 5, "a changed list reshuffled the page on screen")
    eq(po and po["9:0"], nil, "a changed list kept another page's stale state")
end)

-- ── A reordered list keeps the page's first book ───────────────────────────
-- Home sorts by last opened: opening a book moves it to the front, and every
-- book before its old place shifts along one. The cursor is a POSITION, so
-- the page's first book changed under the reader a few seconds after a book
-- closed (maintainer: "keep the first book on the shelf stable").
local function anchorRun(before, after, cursor)
    local fetch = method("_spineCachedFetch")
    local list = {}
    for i, n in ipairs(before) do list[i] = { filepath = "/" .. n } end
    local self = { chip = "all", _cursor = cursor }
    self._fetchChipItems = function() local o = {} for i, x in ipairs(list) do o[i] = x end return o end
    self._spineItemsSig = method("_spineItemsSig")
    self._anchorSpineCursor = method("_anchorSpineCursor")
    self._setSpineCursor = self._setSpineCursor or function(s, c, k) s._cursor, s._skip = c, k or 0 end
    self._spineSkip = self._spineSkip or function(s) return s._skip or 0 end
    self._ornKey = self._ornKey or method("_ornKey")
    self._spineSkip = function(s) return s._skip or 0 end
    self._setSpineCursor = function(s, c, k) s._cursor, s._skip = c, k or 0 end
    self._ornKey = method("_ornKey")
    fetch(self, 400)
    local c = self._spine_fetch_cache
    c.page_orn, c.orn_sig = { [cursor .. ":0"] = { n = 5, shelf = 2, bnd = 0, owed = {} } }, "s"
    c.at = 0
    list = {}
    for i, n in ipairs(after) do list[i] = { filepath = "/" .. n } end
    fetch(self, 400)
    return self
end

t.test("reordered: the page keeps its first book", function()
    -- g (after the page) opened: it moves to the front, d shifts from 4 to 5
    local self = anchorRun({ "a", "b", "c", "d", "e", "f", "g", "h" },
                           { "g", "a", "b", "c", "d", "e", "f", "h" }, 4)
    eq(self._cursor, 5, "the page no longer starts at d")
    local po = self._spine_fetch_cache.page_orn
    eq(po and po["5:0"] and po["5:0"].n, 5, "the page's deal state did not move with it")
end)

t.test("reordered: the page's own first book opened, the page starts at the next one", function()
    local self = anchorRun({ "a", "b", "c", "d", "e", "f", "g", "h" },
                           { "d", "a", "b", "c", "e", "f", "g", "h" }, 4)
    eq(self._cursor, 5, "the page jumped with the book that moved to the front")
end)

t.test("reordered: a book opened from before the page leaves it where it was", function()
    local self = anchorRun({ "a", "b", "c", "d", "e", "f", "g", "h" },
                           { "b", "a", "c", "d", "e", "f", "g", "h" }, 4)
    eq(self._cursor, 4)
end)

t.test("a per-book change expires the fetch, and the same list keeps its page states", function()
    -- Review: closing a book (Repo.invalidateProgressCache) cleared the whole
    -- fetch cache, so every return to the shelf at page > 1 rebuilt the map.
    local fetch, expire = method("_spineCachedFetch"), method("_expireSpineFetch")
    local list = { { filepath = "/a" }, { filepath = "/b" } }
    local self = { chip = "all" }
    self._fetchChipItems = function() return { list[1], list[2] } end
    self._spineItemsSig = method("_spineItemsSig")
    self._anchorSpineCursor = method("_anchorSpineCursor")
    self._setSpineCursor = self._setSpineCursor or function(s, c, k) s._cursor, s._skip = c, k or 0 end
    self._spineSkip = self._spineSkip or function(s) return s._skip or 0 end
    self._ornKey = self._ornKey or method("_ornKey")
    fetch(self, 400)
    self._spine_fetch_cache.page_orn = { ["2:0"] = { n = 3, shelf = 2, bnd = 0, owed = {} } }
    expire(self)
    local before = self._spine_fetch_cache
    fetch(self, 400)
    assert(self._spine_fetch_cache ~= before, "an expired fetch was served")
    eq(self._spine_fetch_cache.page_orn["2:0"].n, 3, "the page states went with the expired fetch")
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    local hook = w:match("Repo%.on_book_invalidated = function%(fp%)(.-)\n    end\n")
    assert(hook and hook:find("bw:_expireSpineFetch()", 1, true), "a book's invalidation still drops the page states")
end)

t.test("an open-ended feed neither reads nor writes another chip's page states", function()
    -- Review: an OPDS window returns before replacing the fetch cache, so the
    -- deal states read and recorded were the previous chip's.
    local fetch = method("_spineCachedFetch")
    local self = { chip = "opds", _spine_fetch_cache = { key = "all|", items = {}, at = os.time(), page_orn = {} } }
    self._fetchChipItems = function() return { opds_open_ended = true } end
    self._spineItemsSig = method("_spineItemsSig")
    self._anchorSpineCursor = method("_anchorSpineCursor")
    self._setSpineCursor = self._setSpineCursor or function(s, c, k) s._cursor, s._skip = c, k or 0 end
    self._spineSkip = self._spineSkip or function(s) return s._skip or 0 end
    self._ornKey = self._ornKey or method("_ornKey")
    fetch(self, 400)
    eq(self._spine_fetch_live, false, "the open-ended fetch left the cache marked live")
    local st_self = stub(9, 0)
    st_self._spine_fetch_live = false
    st_self._spine_fetch_cache.page_orn["9:0"] = { n = 7, shelf = 1, bnd = 0, owed = {} }
    eq(method("_ornStartState")(st_self).n, 0, "a feed page read another chip's state")
    eq(st_self.builds, 0, "a feed page built another chip's page map")
    local b = src:match("\nfunction BookshelfWidget:_buildSpineRows%(.-%)\n(.-)\nend\n")
    assert(b:find("if c and self._spine_fetch_live ~= false and plan.orn_end and plan.next_item then", 1, true),
        "a feed page records its end state into another chip's cache")
end)

t.test("the deal-state signature changes when the enabled pieces change, not only their count", function()
    -- Review: one piece off and another on kept the count, so every recorded
    -- state survived a pool whose widths and page starts had changed.
    local sigf = method("_ornSig")
    local pool = { { name = "a" }, { name = "b" } }
    local saved = package.loaded["lib/bookshelf_ornaments"]
    package.loaded["lib/bookshelf_ornaments"] = { list = function() return pool end, frequency = function() return 1 end }
    local self = stub(1, 0)
    self._nShelves = function() return 2 end
    local s1 = sigf(self)
    pool = { { name = "a" }, { name = "c" } }        -- same count, a new list
    local s2 = sigf(self)
    package.loaded["lib/bookshelf_ornaments"] = saved
    assert(s1 ~= s2, "swapping which pieces are on kept the signature")
end)

t.done()
