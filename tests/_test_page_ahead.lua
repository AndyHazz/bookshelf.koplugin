-- tests/_test_page_ahead.lua
-- The next page, built ahead (BookshelfWidget:_pageAheadRun): once a page has
-- settled, the page a turn would show next is built and painted offscreen and
-- kept in the page cache, so the turn takes it as it takes a page turned back
-- to. The build runs the turn's own steps on the live shelf, so everything it
-- sets has to go back afterwards: the shelf must be exactly as it was, with
-- only the cache holding the new page. Rig-verified pixel for pixel against
-- turns built on the spot (plugins/aheaddrv, Spines, Covers and List).
--
-- Driven against the real method body, extracted by name and run under a stub
-- self, as _test_preload_arming does.
package.path = "./?.lua;./?/init.lua;" .. package.path

local H   = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq
local src = io.open("lib/bookshelf_widget.lua"):read("*a")

local function bodyOf(sig, name)
    local body = src:match("\nfunction BookshelfWidget:" .. sig .. "\n(.-)\nend\n")
    assert(body, "could not find BookshelfWidget:" .. name .. " - renamed?")
    return body
end

local function compile(code, env, name)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, name))
        _G.setfenv(f, env)
        return f
    end
    return assert(load(code, name, "t", env))
end

local RUN    = bodyOf("_pageAheadRun%(%)", "_pageAheadRun")
local SAFE   = bodyOf("_pageAheadSafe%(%)", "_pageAheadSafe")
local BUILD  = bodyOf("_pageAheadBuild%(dir%)", "_pageAheadBuild")
local STEP   = bodyOf("_pageAheadStep%(job%)", "_pageAheadStep")
local CANCEL = bodyOf("_pageAheadCancel%(%)", "_pageAheadCancel")
-- The two local helpers, as written.
local FIELDS = assert(src:match("\n(local function _takeFields%(self%).-\nend\nlocal function _putFields%(self, t%).-\nend)\n"),
    "_takeFields/_putFields moved")

local function cacheStub()
    local PC = { enabled = true, kept = {}, freed = {} }
    function PC.put(_pc, e) PC.kept[#PC.kept + 1] = e end
    function PC._free(e) PC.freed[#PC.freed + 1] = e end
    return PC
end

local function env(PC, top)
    local freed = {}
    local e = {
        pairs = pairs, ipairs = ipairs, type = type, tostring = tostring, pcall = pcall,
        error = error, math = math, string = string, table = table,
        require = function(name)
            if name == "lib/bookshelf_page_cache" then return PC end
            if name == "lib/bookshelf_tab_model" then
                return { getById = function() return { source = { kind = "all" } } end }
            end
            if name == "lib/bookshelf_sources" then return { get = function() return nil end } end
            error("unexpected require " .. name)
        end,
        _gettime = function() return 0 end,
        logger = { dbg = function() end, warn = function() end },
        UIManager = { getTopmostVisibleWidget = function() return top end,
                      scheduleIn = function(um, _d, fn) um.queue[#um.queue + 1] = fn end,
                      unschedule = function(um, fn)
                          for i = #um.queue, 1, -1 do if um.queue[i] == fn then table.remove(um.queue, i) end end
                      end,
                      queue = {} },
        Screen = {
            getWidth = function() return 100 end, getHeight = function() return 200 end,
            bb = { getWidth = function() return 100 end, getHeight = function() return 200 end,
                   getType = function() return 1 end },
        },
        Blitbuffer = { new = function() return { free = function(b) freed[#freed + 1] = b end } end },
    }
    e._G = e
    local h = compile(FIELDS .. "\nreturn _takeFields, _putFields", e, "fields")
    e._takeFields, e._putFields = h()
    return e, freed
end

-- A shelf on page 1 whose turn moves the cursor, pushes spine history in
-- place and sets page fields, as the real steps do.
local function shelf(opts)
    opts = opts or {}
    local s = {
        _first_paint_done = true, _inner_vgroup = {}, _shelf_dims = { footer_overlap_idx = 1 },
        _overlap_group = { "old footer" }, width = 100, height = 200, chip = "home",
        _cursor = 1, page = 1, _spine_hist = { { c = 0, s = 0 } }, _spine_next_item = 9,
        _page_ahead_dir = 1,
    }
    local placed
    s._pageForwardPossible = function() return true end
    s._pageBackPossible = function() return false end
    s._ornScanWindow = function() end
    s._opdsEffectiveTab = function() return nil end
    s._advanceCursor = function(self, dir)
        table.insert(self._spine_hist, { c = self._cursor, s = 0 })
        self._cursor = self._cursor + 8 * dir
    end
    s._syncPageFromCursor = function(self) self.page = 2 end
    s._pageCompose = function(self, turning, ahead)
        assert(turning and ahead, "built ahead as a page turn that never takes from the cache")
        self._spine_next_item = 17           -- what a build sets on the shelf
        self._page_items = { "b9" }
        if opts.cached then return { cached = true } end
        return { d = self._shelf_dims, n_shelves = 2, items = { "b9" }, rows = { "row9a", "row9b" }, key = "k9" }
    end
    s._footerAnchor = function() return "new footer" end
    s._pagePlace = function(self, _d, _n, _items, rows, footer)
        placed = { rows = rows }
        self._overlap_group[1] = footer
        return { rows = { "row1a", "row1b" }, gaps = {}, footer = "old footer" }
    end
    s._pageUnplace = function(self, _d, _n, old) self._overlap_group[1] = old.footer; placed = nil end
    s.paintTo = function(self)
        if opts.paint_fails then error("boom") end
        self._clip_rects = nil                -- paint consumes these
    end
    s._pagePxCapture = function() return { bb = "px", y0 = 0 } end
    s._pageStateSnapshot = function(self) return { _spine_next_item = self._spine_next_item } end
    s._pageMinute = function() return nil end
    s._pageCache = function() return "pc" end
    s._pageAheadArm = function() end
    s._clip_rects = { "pending" }
    return s, function() return placed end
end

local function wire(s, PC, top)
    local e = env(PC, top)
    local function method(code, args, name)
        local f = compile("local self" .. args .. " = ...\n" .. code, e, name)
        return function(...) return f(...) end
    end
    s._pageAheadSafe   = method(SAFE, "", "safe")
    s._pageAheadBuild  = method(BUILD, ", dir", "build")
    s._pageAheadStep   = method(STEP, ", job", "step")
    s._pageAheadCancel = method(CANCEL, "", "cancel")
    s._pageAheadRun    = method(RUN, "", "run")
    s._page_gen = 0
    return e.UIManager
end

-- One step, as the event loop would run it; false once nothing is scheduled.
local function tick(um)
    local fn = table.remove(um.queue, 1)
    if not fn then return false end
    fn()
    return true
end

local function run(s, PC, top)
    local um = wire(s, PC, top)
    s:_pageAheadRun()
    local n = 0
    while tick(um) do n = n + 1; assert(n < 20, "never finished") end
    return um
end

local function snapshot(s)
    local out = {}
    for k, v in pairs(s) do out[k] = v end
    return out
end

t.test("the page beyond is kept in the cache under its turn's key", function()
    local PC = cacheStub()
    local s = shelf()
    run(s, PC, s)
    eq(#PC.kept, 1)
    eq(PC.kept[1].key, "k9")
    eq(PC.kept[1].rows[1], "row9a")
    eq(PC.kept[1].state._spine_next_item, 17, "the page's own state goes with it")
    eq(PC.kept[1].px.bb, "px")
end)

t.test("the shelf is left exactly as it was", function()
    local PC = cacheStub()
    local s, placedNow = shelf()
    local before = snapshot(s)
    local hist = s._spine_hist
    run(s, PC, s)
    for k, v in pairs(before) do
        if k ~= "_page_ahead_fn" and k ~= "_page_ahead_job" then eq(s[k], v, k .. " was not put back") end
    end
    for k in pairs(s) do
        assert(before[k] ~= nil or k == "_page_ahead_fn" or k == "_page_gen" or k:match("^_pageAhead"), k .. " was left behind")
    end
    eq(#hist, 1, "the spine history was pushed in place")
    eq(s._overlap_group[1], "old footer", "the page's own footer was left in place")
    eq(placedNow(), nil, "the page built ahead was left in the rows")
end)

t.test("a failed paint keeps nothing and frees what it built", function()
    local PC = cacheStub()
    local s = shelf({ paint_fails = true })
    local before = snapshot(s)
    run(s, PC, s)
    eq(#PC.kept, 0)
    eq(#PC.freed, 1)
    eq(PC.freed[1].rows[1], "row9a")
    eq(s._cursor, before._cursor)
    eq(s._overlap_group[1], "old footer")
end)

t.test("a page already kept is not built again", function()
    local PC = cacheStub()
    local s = shelf({ cached = true })
    run(s, PC, s)
    eq(#PC.kept, 0)
    eq(s._cursor, 1)
end)

t.test("nothing is built under another window, or past the last page", function()
    local PC = cacheStub()
    local s = shelf()
    run(s, PC, { "a menu" })
    eq(#PC.kept, 0, "built under a menu")
    s = shelf()
    s._pageForwardPossible = function() return false end
    run(s, PC, s)
    eq(#PC.kept, 0, "built past the last page")
end)

t.test("never for a feed's or another plugin's page (no network the reader did not ask for)", function()
    assert(SAFE:find('if self._opds_open_ended or self:_opdsEffectiveTab() then return false end', 1, true))
    assert(SAFE:find('kind == "opds" or (kind and require("lib/bookshelf_sources").get(kind))', 1, true))
end)

t.test("in steps, the shelf as it was between them, and a turn drops a page half built", function()
    local PC = cacheStub()
    local s = shelf()
    local um = wire(s, PC, s)
    local before = snapshot(s)
    s:_pageAheadRun()                 -- the rows are built
    assert(s._page_ahead_job, "no job after the build step")
    eq(s._cursor, before._cursor, "the cursor moved between steps")
    eq(s._spine_next_item, before._spine_next_item, "the build's state was left on the shelf")
    eq(#um.queue, 1, "the next step was not scheduled")
    tick(um)                           -- row 1 painted alone
    eq(#PC.kept, 0)
    s._page_gen = s._page_gen + 1      -- a turn
    tick(um)
    eq(#PC.kept, 0, "a page half built before a turn was kept")
    eq(#PC.freed, 1, "its rows were not freed")
    eq(s._page_ahead_job, nil)
    eq(#um.queue, 0)
end)

t.test("every page turn arms it; spines at once, covers once their covers are warm", function()
    local sched = bodyOf("_schedulePreload%(direction%)", "_schedulePreload")
    assert(sched:find("self:_pageAheadArm(direction)", 1, true))
    local step = bodyOf("_preloadStep%(%)", "_preloadStep")
    assert(step:find("self:_pageAheadArm(self._preload_dir)", 1, true))
    assert(bodyOf("_cancelPreload%(%)", "_cancelPreload"):find("self:_pageAheadCancel()", 1, true))
    assert(bodyOf("_swapShelvesInPlace%(%)", "swap"):find("if not _wipe_dir then self:_pageAheadArm(self._page_ahead_dir or 1) end", 1, true),
        "a swap that is not a turn leaves no page built ahead")
    -- What drops a page half built: a turn, a rebuild, the cache cleared.
    for _i, f in ipairs({ "_swapShelvesInPlace%(%)", "_rebuild%(%)", "_pageCacheClear%(%)" }) do
        assert(bodyOf(f, f):find("self:_pageGenBump()", 1, true), f .. " leaves a half-built page standing")
    end
end)

t.done()
