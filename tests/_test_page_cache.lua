-- tests/_test_page_cache.lua
-- The recent-pages cache (lib/bookshelf_page_cache): what a page turn back
-- reuses, and that nothing kept outlives its place in the cache unfreed.
package.path = "./?.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq
local PC = dofile("lib/bookshelf_page_cache.lua")

local function rows(tag, freed)
    local r = {}
    for i = 1, 2 do r[i] = { free = function() freed[#freed + 1] = tag .. i end } end
    return r
end

t.test("take returns a kept page once and removes it", function()
    local pc, freed = PC.new(), {}
    PC.put(pc, { key = "p1", rows = rows("a", freed) })
    local e = PC.take(pc, "p1")
    assert(e and e.rows, "a kept page was not returned")
    eq(PC.take(pc, "p1"), nil, "a taken page was still kept")
    eq(#freed, 0, "a taken page was freed")
end)

t.test("a miss is nil and keeps the rest", function()
    local pc = PC.new()
    PC.put(pc, { key = "p1", rows = {} })
    eq(PC.take(pc, "p2"), nil)
    eq(PC.size(pc), 1)
end)

t.test("past MAX the oldest page is freed; the same key replaces and frees", function()
    local pc, freed = PC.new(), {}
    for i = 1, PC.MAX + 1 do PC.put(pc, { key = "p" .. i, rows = rows("r" .. i, freed) }) end
    eq(PC.size(pc), PC.MAX)
    eq(table.concat(freed, ","), "r11,r12", "the oldest page was not freed")
    eq(PC.take(pc, "p1"), nil)
    PC.put(pc, { key = "p2", rows = rows("d", freed) })
    eq(table.concat(freed, ","), "r11,r12,r21,r22", "a replaced page was not freed")
end)

t.test("clear frees everything kept; switched off it keeps nothing", function()
    local pc, freed = PC.new(), {}
    PC.put(pc, { key = "p1", rows = rows("a", freed) })
    PC.clear(pc)
    eq(PC.size(pc), 0); eq(#freed, 2)
    PC.enabled = false
    PC.put(pc, { key = "p2", rows = rows("b", freed) })
    eq(PC.size(pc), 0, "a switched-off cache kept a page")
    eq(#freed, 4, "a page refused by a switched-off cache was not freed")
    PC.enabled = true
end)

t.test("an evicted or cleared page frees its kept pixels too", function()
    local pc, freed = PC.new(), {}
    local function px(tag) return { bb = { free = function() freed[#freed + 1] = tag end }, y0 = 0 } end
    for i = 1, PC.MAX + 1 do PC.put(pc, { key = "p" .. i, rows = {}, px = px("x" .. i) }) end
    eq(table.concat(freed, ","), "x1", "an evicted page kept its pixels")
    PC.clear(pc)
    eq(#freed, PC.MAX + 1)
end)

-- The widget's side of it (rig-verified pixel for pixel; these pin the
-- invariants that verification rests on).
local W = io.open("lib/bookshelf_widget.lua"):read("*a")
local function body(name)
    local i = assert(W:find("function BookshelfWidget:" .. name .. "(", 1, true), name)
    return W:sub(i, (W:find("\nfunction ", i + 10, true) or #W))
end

t.test("only a page turn reads or fills the cache; anything else clears it", function()
    assert(body("_rebuild"):find("self:_pageCacheClear()", 1, true), "a rebuild keeps stale pages")
    local swap = body("_swapShelvesInPlace")
    assert(swap:find("self:_pageCompose(_wipe_dir ~= nil, false)", 1, true)
        and body("_pageCompose"):find("local pc_key = turning and self:_pageCacheKey(items, d, n_shelves) or nil", 1, true),
        "a swap that is not a page turn can use the cache")
    assert(swap:find("if not pc_key then self:_pageCacheClear() end", 1, true),
        "a swap that is not a page turn leaves kept pages")
    assert(body("onCloseWidget"):find("self:_pageCacheClear()", 1, true), "closing keeps pages")
    assert(body("_refreshCoverFrame"):find("self:_pageCacheClear()", 1, true), "a cover redrawn in place keeps old pages")
end)

t.test("kept rows are not hung twice, and their page state comes back with them", function()
    local swap = body("_pageCompose")
    assert(swap:find("if d.row_pitch and not pc_hit then self:_hangUnder(", 1, true),
        "kept rows are hung again (their pieces move twice)")
    assert(swap:find("self:_pageStateRestore(pc_hit.state)", 1, true), "a kept page's state is not restored")
    for _i, f in ipairs({ "_spine_next_item", "_spine_next_skip", "_spine_rows", "_spine_page_books",
            "_spine_badges", "_key_orns", "_shelf_minute_cells" }) do
        assert(W:find('"' .. f .. '"', 1, true), f .. " is not part of a kept page's state")
    end
end)

t.test("a screen paint over the rows drops the page's kept pixels; the key holds the totals", function()
    assert(body("paintTo"):find("self:_pagePxStaleBy(bb)", 1, true), "an in-place repaint leaves stale pixels kept")
    local key = body("_pageCacheKey")
    for _i, f in ipairs({ "self._total_items", "self._total_pages", "Repo.dataGeneration",
            "Screen.night_mode", "self:_selectedFilepath()", "self._focus_zone" }) do
        assert(key:find(f, 1, true), "the key leaves out " .. f)
    end
end)

t.test("a page with a ticking module is kept only for the minute it was drawn in", function()
    local swap = body("_pageCompose")
    assert(swap:find("pc_hit.minute ~= math.floor(os.time() / 60)", 1, true),
        "a page with a clock is reused after its minute")
    assert(body("_pageMinute"):find("math.floor(os.time() / 60)", 1, true))
end)

t.test("a shelf switch keeps pages; any other rebuild clears them", function()
    local rb = body("_rebuild")
    assert(rb:find("local switching = self._switching_shelf\n    if switching then\n        self._switching_shelf = nil\n        self:_pageKeepLeaving()\n    else\n        self:_pageCacheClear()\n", 1, true),
        "a rebuild no longer tells a switch from a change")
    local n = select(2, W:gsub("self._switching_shelf = true\n", ""))
    eq(n, 4, "not every way to another shelf (tap, swipe, select, a sub-shelf) keeps its pages")
    assert(rb:find("PageCache.take(self:_pageCache(), pc_key)", 1, true), "a rebuild never takes a kept page")
    assert(rb:find("if not pc_hit then self:_hangUnder(", 1, true), "kept rows are hung again by a rebuild")
    local key = body("_pageCacheKey")
    for _i, f in ipairs({ "self._hero_dims.hero_h", "self._expanded", "self._chip_bar_hidden" }) do
        assert(key:find(f, 1, true), "the key leaves out " .. f .. " (the rows' hanging gaps)")
    end
end)

t.test("the page being left is taken out of the tree the rebuild frees", function()
    local code = assert(W:match("\nfunction BookshelfWidget:_pageKeepLeaving%(%)\n(.-)\nend\n"))
    local put = {}
    local env = setmetatable({
        require = function(name)
            if name == "ui/widget/verticalspan" then return { new = function(_s, o) return { span = true } end } end
            if name == "lib/bookshelf_page_cache" then return { put = function(_pc, e) put[#put + 1] = e end } end
            return require(name)
        end,
    }, { __index = _G })
    local f
    if setfenv then f = assert(loadstring("local self = ...\n" .. code)); setfenv(f, env)
    else f = assert(load("local self = ...\n" .. code, "keep", "t", env)) end
    local pxfreed = false
    local rowsA = { "rowA1", "rowA2" }
    local self_ = {
        _shelf_dims = { shelf_top_idx = 3 },
        _inner_vgroup = { "hero", "gap", "rowA1", "gap", "rowA2" },
        _page_cur = { key = "A1", rows = rowsA, px = { bb = { free = function() pxfreed = true end } } },
        _pageCache = function() return "pc" end,
    }
    f(self_)
    eq(#put, 1, "the page left was not kept")
    eq(put[1].rows, rowsA)
    eq(self_._inner_vgroup[3].span, true, "row 1 is still in the tree being freed")
    eq(self_._inner_vgroup[5].span, true, "row 2 is still in the tree being freed")
    eq(put[1].px, nil, "its screen's pixels were kept")
    eq(pxfreed, true)
    eq(self_._page_cur, nil)
end)

t.done()
