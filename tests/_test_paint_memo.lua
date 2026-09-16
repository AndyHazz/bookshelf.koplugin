-- tests/_test_paint_memo.lua
-- The helpers that answer "what is behind the shelf and what colour is the
-- chrome" are asked from paint paths, many times per frame.
--
-- WHAT NEEDS PINNING. Each of these answers is fixed for the life of one
-- settings generation and one night-mode state, and every one of them was
-- doing a pcall(require ...) and a settings read per call. Counted on the
-- branch: groundIsPainted ~7 times and _manualDark ~17 times per rebuild,
-- footerPanelRect on EVERY paint of the footer (a filesystem stat inside a
-- paintTo, measured at 64ms a stat on a tired Kindle). So the rule: a helper
-- on this list memoises on Store.generation() and the night flag, and no
-- `pcall(require` survives inside its body.
--
-- Usage (from plugin root): lua tests/_test_paint_memo.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()

local function read(path)
    local f = io.open(path); assert(f, "could not read " .. path)
    local s = f:read("a"); f:close(); return s
end
local function body(src, header_pat)
    local b = src:match(header_pat .. ".-\nend\n")
    assert(b, "could not locate " .. header_pat)
    return (b:gsub("%-%-[^\n]*", ""))
end

t.test("the widget's ground questions all read one memo", function()
    local src = read("lib/bookshelf_widget.lua")
    for _, name in ipairs{ "hasWallpaper", "groundIsPainted", "_manualDark",
                           "wallpaperScrimStrength", "footerPanelRect" } do
        local b = body(src, "\nfunction BookshelfWidget:" .. name .. "%(")
        assert(b:find("_groundState", 1, true), name .. " does not go through the memo")
        assert(not b:find("pcall%(require"), name .. " still requires a module per call")
    end
end)

t.test("the memo's key covers everything its answers depend on", function()
    local src = read("lib/bookshelf_widget.lua")
    local b = body(src, "\nfunction BookshelfWidget:_groundState%(")
    local key = src:match("local function _groundKey%(.-\nend\n")
    assert(key, "no _groundKey")
    for _, dep in ipairs{ "generation%(%)", "night_mode", "_expanded", "width", "height" } do
        assert(key:find(dep), "the memo key ignores " .. dep)
    end
    assert(src:find("self%._ground_memo%s*=%s*nil"), "nothing resets the memo at a rebuild")
end)

t.test("the chip strip's palette helpers memoise", function()
    local src = read("lib/bookshelf_chip_bar.lua")
    for _, name in ipairs{ "_manualDarkChips", "_chipInk", "_stripGround", "_stripInk" } do
        local b = body(src, "\nlocal function " .. name .. "%(")
        assert(b:find("_memoised", 1, true), name .. " is recomputed on every call")
    end
    local m = body(src, "\nlocal function _memoised%(")
    assert(m:find("generation", 1, true) and m:find("night_mode", 1, true),
        "the chip memo is not keyed on the settings generation and night mode")
end)

t.test("the hero's ink memoises when it is not masked", function()
    local src = read("lib/bookshelf_hero_card.lua")
    local b = body(src, "\nlocal function _ink%(")
    assert(b:find("_masked_column", 1, true), "the mask flag must still win")
    assert(b:find("generation", 1, true), "_ink recomputes the theme ink on every call")
end)

t.test("the spine render key does not require a module per slot per paint", function()
    local src = read("lib/bookshelf_spine_shelf.lua")
    local b = body(src, "\nfunction SpineBookSlot:_renderKey%(")
    assert(not b:find("pcall%(require"), "_renderKey requires cover_progress per call")
    assert(b:find("_themeChar", 1, true), "the theme segment is not memoised")
end)

t.test("the cover tile's ground lookup does not require a module per paint", function()
    local src = read("lib/bookshelf_spine_widget.lua")
    local b = body(src, "\nlocal function _wallpaperModule%(")
    assert(b:find("_looked", 1, true) or b:find("_wpm_looked", 1, true),
        "_wallpaperModule requires the wallpaper module on every call")
end)

t.test("the first cover tap takes the in-place swap, not a rebuild", function()
    -- `if can_swap and prior_preview_fp then` sent the FIRST tap on every
    -- fresh shelf through a full _rebuild() (~0.9-1.3s on a PW5 at 300
    -- books), for every configuration. It was added to cure a missing first
    -- lift whose real cause was a positional row[2] read, since replaced by
    -- the _slots_by_fp registry, which handles a nil prior on its own.
    local src = read("lib/bookshelf_widget.lua"):gsub("%-%-[^\n]*", "")
    assert(src:find("if can_swap then", 1, true), "the in-place swap gate is gone")
    assert(not src:find("can_swap and prior_preview_fp"),
        "the first tap is gated back onto the rebuild path")
end)

t.test("a cover tile's shadow over a picture shades only its exposed margin", function()
    local src = read("lib/bookshelf_spine_widget.lua")
    local b = body(src, "\nfunction ShadowRect:paintTo%(")
    assert(b:find("shadeClipped", 1, true), "ShadowRect still blends the whole card rect")
    assert(src:find("exposed%s*=%s*SHADOW_OFFSET"), "ShadowRect is not told the card offset")
end)

t.test("the spine plan's per-entry debug line is built only when logging is on", function()
    -- logger.dbg is a no-op when off, but Lua evaluates its arguments first:
    -- a ten-field string.format per entry, ~1200 entries a plan, three plans
    -- a rebuild, for a line nobody reads.
    local src = read("lib/bookshelf_spine_shelf.lua")
    local at = src:find('"%[bookshelf perf%] spine plan: %%%-24s')
    assert(at, "the per-entry line is gone; drop this test")
    local before = src:sub(math.max(1, at - 400), at)
    assert(before:find("if _verbose then", 1, true), "the per-entry format runs unconditionally")
    assert(src:find("dbg%.is_on"), "_verbose does not read KOReader's debug switch")
end)

t.test("the spine plan keeps its entries between page turns", function()
    -- One entry per item the chip holds, rebuilt on every call, to show six.
    local src = read("lib/bookshelf_spine_shelf.lua")
    local plan = body(src, "\nfunction SpineShelf%.plan%(items, opts%)\n")
    assert(plan:find("_plan_cache", 1, true), "plan never consults the entries cache")
    assert(plan:find("_n_hydrated == 0", 1, true),
        "a plan that hydrated stubs must not be cached (it would freeze them)")
    local ib = body(src, "\nfunction SpineShelf%.invalidateBook%(")
    assert(ib:find("_plan_cache = nil", 1, true), "invalidateBook leaves stale entries")
    assert(src:find("function SpineShelf.dropPlanCache", 1, true), "no dropPlanCache")
    local w = read("lib/bookshelf_widget.lua")
    local rb = body(w, "\nfunction BookshelfWidget:_rebuild%(%)\n")
    assert(rb:find("dropPlanCache", 1, true), "a rebuild does not drop the plan cache")
end)

t.test("the pagination plan does not balance every row of the chip", function()
    -- balanceRows is a DP over rows x books; asked for all 415 rows of a
    -- 1234-book chip it took 585ms, for boundaries the pages never use.
    local w = read("lib/bookshelf_widget.lua")
    local pf = body(w, "\nfunction BookshelfWidget:_spinePageFirsts%(%)\n")
    assert(pf:find("balance%s*=%s*false"), "_spinePageFirsts still asks for a balanced plan")
    local src = read("lib/bookshelf_spine_shelf.lua")
    local plan = body(src, "\nfunction SpineShelf%.plan%(items, opts%)\n")
    assert(plan:find("opts%.balance ~= false"), "plan ignores balance = false")
end)

t.done()
