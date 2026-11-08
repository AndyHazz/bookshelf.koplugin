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
local BUILD  = bodyOf("_pageAheadBuild%(dir, base%)", "_pageAheadBuild")
local STEP   = bodyOf("_pageAheadStep%(job%)", "_pageAheadStep")
local COMPOSE = bodyOf("_pageAheadComposeStep%(job, real%)", "_pageAheadComposeStep")
local CANCEL = bodyOf("_pageAheadCancel%(%)", "_pageAheadCancel")
local BUSY   = bodyOf("_inputBusyFor%(quiet%)", "_inputBusyFor")
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
            if name == "lib/bookshelf_slice" then return require(name) end
            error("unexpected require " .. name)
        end,
        _gettime = function() return _G._TEST_NOW and _G._TEST_NOW() or 0 end,
        coroutine = coroutine,
        PAGE_AHEAD_QUIET_S = 1.0, BACKGROUND_QUIET_S = 1.0, PAGE_AHEAD_STEP_S = 0.05, PAGE_AHEAD_SLICE_S = 0.08, PAGE_AHEAD_DEPTH = _G._TEST_DEPTH or 1,
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
        BookshelfWidget = { _screenLike = function() return { free = function(b) freed[#freed + 1] = b end } end,
                            _rowLeaves = function() return {} end },
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
    s._isSpineMode = function() return false end
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
        if opts.sliced then
            -- Two rows' covers, each a decode that may pause the build.
            opts.compose_runs = (opts.compose_runs or 0) + 1
            require("lib/bookshelf_slice").check()
            opts.rows_built = (opts.rows_built or 0) + 1
            require("lib/bookshelf_slice").check()
            opts.rows_built = opts.rows_built + 1
        end
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
    s._pageAheadBuild  = method(BUILD, ", dir, base", "build")
    s._pageAheadStep   = method(STEP, ", job", "step")
    s._pageAheadComposeStep = method(COMPOSE, ", job, real", "compose")
    s._pageAheadCancel = method(CANCEL, "", "cancel")
    s._pageAheadRun    = method(RUN, "", "run")
    s._inputBusyFor    = method(BUSY, ", quiet", "busy")
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
        assert(before[k] ~= nil or k == "_page_ahead_fn" or k == "_page_gen" or k:match("^_pageAhead") or k == "_inputBusyFor", k .. " was left behind")
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

t.test("a page whose covers take longer than a step is built over several, the shelf untouched between", function()
    local PC = cacheStub()
    local opts = { sliced = true }
    local s = shelf(opts)
    local before = snapshot(s)
    local now = 0
    _G._TEST_NOW = function() now = now + 0.05; return now end   -- every clock read: 50 ms on
    local um = wire(s, PC, s)
    local steps, paused_seen = 0, false
    local function look()
        local job = s._page_ahead_job
        if job and job.compose then
            paused_seen = true
            eq(s._cursor, before._cursor, "a paused build left its cursor on the shelf")
            eq(s._spine_next_item, before._spine_next_item, "a paused build left its page state on the shelf")
        end
    end
    s:_pageAheadRun()
    look()
    while tick(um) do
        steps = steps + 1
        assert(steps < 40, "never finished")
        look()
    end
    _G._TEST_NOW = nil
    assert(paused_seen, "the build never paused between covers")
    eq(opts.compose_runs, 1, "the page was composed again from the start")
    eq(opts.rows_built, 2)
    eq(#PC.kept, 1, "the page was not kept once built")
    eq(PC.kept[1].state._spine_next_item, 17)
    for k, v in pairs(before) do
        if not k:match("^_page_ahead") then eq(s[k], v, k .. " was not put back") end
    end
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

t.test("nothing is built while the reader is busy: it waits for a quiet second", function()
    local PC = cacheStub()
    local s = shelf()
    local um = wire(s, PC, s)
    s._last_input_at = 0          -- the clock stub reads 0: input just now
    s:_pageAheadRun()
    eq(s._page_ahead_job, nil, "a step ran right after an input")
    eq(#um.queue, 1, "it was not put off until the reader stops")
    assert(RUN:find("local busy = self:_inputBusyFor(PAGE_AHEAD_QUIET_S)", 1, true))
    assert(src:find('UIManager.event_hook:registerWidget("InputEvent", self)', 1, true), "inputs are not heard")
end)

t.test("a turn onto a page half built ahead takes its rows instead of building them", function()
    local ADOPT = bodyOf("_pageAheadAdopt%(key%)", "_pageAheadAdopt")
    local put = {}
    local env = setmetatable({
        PAGE_STATE_FIELDS = { "_spine_next_item", "_shelf_minute_cells" },
        UIManager = { unschedule = function() end },
        require = function(n)
            if n == "lib/bookshelf_page_cache" then return { put = function(_pc, e) put[#put + 1] = e end } end
            return require(n)
        end,
    }, { __index = _G })
    local adopt = compile("local self, key = ...\n" .. ADOPT, env, "adopt")
    local s = { _pageCache = function() return "pc" end, _page_ahead_fn = function() end }
    s._page_ahead_job = { page = { key = "k9", rows = { "r1", "r2" } },
                          sim = { _spine_next_item = 17, _shelf_minute_cells = { chip = "x" } } }
    adopt(s, "other")
    eq(#put, 0, "a page for another key was taken")
    adopt(s, "k9")
    eq(#put, 1)
    eq(put[1].rows[1], "r1")
    eq(put[1].state._spine_next_item, 17, "the build's page state was left behind")
    eq(s._page_ahead_job, nil)
    assert(src:find("self:_pageAheadAdopt(pc_key)\n        pc_hit = PageCache.take(self:_pageCache(), pc_key)", 1, true),
        "a turn does not look at the page being built ahead")
end)

t.test("after a pause, the page after the next is built too, from where the next one ends", function()
    _G._TEST_DEPTH = 2
    local PC = cacheStub()
    local s = shelf()
    local cursors = {}
    local compose = s._pageCompose
    s._pageCompose = function(self, a, b)
        cursors[#cursors + 1] = self._cursor
        local p = compose(self, a, b)
        if p and p.key then p.key = "k" .. self._cursor end
        return p
    end
    run(s, PC, s)
    _G._TEST_DEPTH = nil
    eq(#PC.kept, 2, "only one page was built ahead")
    eq(cursors[1], 9); eq(cursors[2], 17, "the second page was not built from the first's end")
    eq(PC.kept[2].key, "k17")
    eq(s._cursor, 1, "the shelf was left on another page")
end)

t.test("a Spines list the build fetched again is kept, with the deal state it recorded", function()
    assert(COMPOSE:find("if c_new and c_new ~= c_old and (not c_old or c_new.key == c_old.key) then", 1, true),
        "the newer list was put back with the rest, and the next page laid out the whole shelf")
end)

t.test("a full garbage collect waits for the same pause, not the next swipe", function()
    local rec = bodyOf("_reclaimAfterTurn%(%)", "_reclaimAfterTurn")
    assert(rec:find("self:_collectWhenQuiet(orphans)", 1, true) and not rec:find('collectgarbage("collect")', 1, true),
        "the full collect runs straight after a turn")
    local cq = bodyOf("_collectWhenQuiet%(orphans%)", "_collectWhenQuiet")
    assert(cq:find("local busy = self:_inputBusyFor()", 1, true))
    assert(cq:find('done = collectgarbage("step", 64)', 1, true) and not cq:find('collectgarbage("collect")', 1, true),
        "the collect runs as one long pause")
    local R = io.open("lib/bookshelf_book_repository.lua"):read("*a")
    assert(R:find("if m and m.sgen == sgen and _light_meta_cache[m.key] == m.entry and m.entry then", 1, true),
        "every series box member resolves the light-record map afresh")
end)

t.test("the quiet counts from the end of the shelf's own work", function()
    local swap = bodyOf("_swapShelvesInPlace%(%)", "swap")
    assert(swap:find("if _wipe_dir then self:_noteBusy() end", 1, true), "a turn's own work eats into the quiet")
    eq(select(2, src:gsub("self._switching_shelf = true\n%s+self:_rebuild[%w]*%(%)\n%s+self:_noteBusy%(%)", "")), 4,
        "a shelf switch's own work eats into the quiet")
end)

t.test("a row's paint is cut into short steps: its books one at a time", function()
    local LEAVES = assert(src:match("\nfunction BookshelfWidget%._rowLeaves%(row%)\n(.-)\nend\n"))
    local leaves = compile("local row = ...\n" .. LEAVES, setmetatable({}, { __index = _G }), "leaves")
    local slotA = { book = {}, paintTo = function() end }
    local slotB = { entry = {}, paintTo = function() end, { book = {}, paintTo = function() end } }
    local row = { { { slotA }, { "plank" } }, slotB }
    local got = leaves(row)
    eq(#got, 2, "a book's own parts were painted as books too, or a book was missed")
    eq(got[1], slotA); eq(got[2], slotB)
    assert(STEP:find("until job.leaf >= #job.leaves or (_gettime() - t_slice) >= PAGE_AHEAD_SLICE_S", 1, true),
        "a row is still painted in one step")
    assert(RUN:find("pcall(self._spineCachedFetch, self, 400)", 1, true), "an expired list is fetched inside the build step")
end)

t.test("all the shelf's background work waits for quiet, not only the page built ahead", function()
    for _i, sig in ipairs({ "_chipPreloadStep%(%)", "_preloadStep%(%)", "_filePollTick%(%)" }) do
        local b = bodyOf(sig, sig)
        assert(b:find("_inputBusyFor(", 1, true), sig .. " runs while the reader swipes")
    end
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

t.test("the next page waits for a short pause; heavier background work for a longer one", function()
    -- A reader pausing naturally (2-3 s) often turned onto a page not built
    -- yet: the build waited for 1.5 s without input, and in Covers the cover
    -- warm-up before it waited as long again (PW5: ready 5.2-5.7 s after a
    -- turn). Its steps are short now; the redraw of finished extractions,
    -- the file poll and the collector keep the longer wait.
    local ahead = tonumber(src:match("local PAGE_AHEAD_QUIET_S = ([%d%.]+)"))
    local bg = tonumber(src:match("local BACKGROUND_QUIET_S = ([%d%.]+)"))
    assert(ahead and bg, "the two waits are not both declared")
    assert(ahead <= 0.75 and bg >= 1.5, "page ahead " .. tostring(ahead) .. ", background " .. tostring(bg))
    assert(BUSY:find("(quiet or BACKGROUND_QUIET_S)", 1, true), "the default wait is not the background one")
    assert(RUN:find("self:_inputBusyFor(PAGE_AHEAD_QUIET_S)", 1, true), "the page build waits as long as the background work")
    local pre = bodyOf("_preloadStep%(%)", "_preloadStep")
    assert(pre:find("self:_inputBusyFor(PAGE_AHEAD_QUIET_S)", 1, true), "the cover warm-up before it waits the long way")
end)

t.done()
