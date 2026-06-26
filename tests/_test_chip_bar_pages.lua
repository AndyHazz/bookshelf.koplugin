-- tests/_test_chip_bar_pages.lua
-- Headless integration test for chip-bar pagination (infinite-chips). Drives a
-- real ChipBar with stubbed KOReader UI modules: narrow width + long labels
-- force overflow, and we assert the pagination wiring (chevrons appear, off-page
-- chips are not rendered, paging moves the window). Run: lua tests/_test_chip_bar_pages.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

-- Minimal class with new()->init() and extend(), for the widget base classes.
local function klass()
    local c = {}; c.__index = c
    function c:extend(t) t = t or {}; setmetatable(t, self); t.__index = t; return t end
    function c:new(o) o = o or {}; setmetatable(o, self); if o.init then o:init() end; return o end
    return c
end

package.loaded["ui/widget/container/inputcontainer"] = klass()
package.loaded["ui/widget/container/framecontainer"]  = klass()
package.loaded["ui/widget/container/centercontainer"] = klass()
package.loaded["ui/widget/overlapgroup"]              = klass()
package.loaded["ui/widget/horizontalgroup"]           = klass()
package.loaded["ui/widget/horizontalspan"]            = klass()
package.loaded["ui/widget/widget"]                    = klass()
package.loaded["ui/widget/linewidget"]                = klass()
package.loaded["ui/widget/iconwidget"]                = klass()
-- TextWidget: width proportional to text length so longer labels measure wider.
local TW = klass()
function TW:getSize() return { w = #(self.text or "") * 9, h = 16 } end
function TW:free() end
package.loaded["ui/widget/textwidget"]    = TW
package.loaded["ui/widget/textboxwidget"] = klass()
package.loaded["ui/geometry"]   = { new = function(_, t) return t or {} end }
package.loaded["ui/gesturerange"] = { new = function(_, t) return t or {} end }
package.loaded["ui/size"] = {
    padding = { default = 4, large = 8, small = 3, fullscreen = 16 },
    border  = { thin = 1, thick = 3 }, line = { medium = 1 },
}
package.loaded["ui/font"] = { getFace = function() return {} end }
package.loaded["ui/uimanager"] = { setDirty = function() end }
package.loaded["ffi/blitbuffer"] = { COLOR_BLACK = 0, COLOR_WHITE = 0xFF, gray = function(v) return v end }
package.loaded["device"] = { screen = { scaleBySize = function(_, n) return n end } }
package.loaded["lib/bookshelf_fonts"] = { getFace = function() return {}, false end }
package.loaded["lib/bookshelf_text_segments"] = {
    upper = function(s) return s end,
    labelSegments = function(s) return { { text = s or "", class = "text" } } end,
}
package.loaded["lib/bookshelf_settings_store"] = {
    read = function(_, default) return default end,   -- chip_font_scale -> nil -> 100
    isTrue = function() return false end,             -- chip_flex_widths off (equal-share)
    generation = function() return 0 end,
}

local ChipBar = dofile("lib/bookshelf_chip_bar.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end

-- chips: a leading action (current), N nav chips, a trailing action (search).
local function makeChips(labels)
    local chips = { { key = "current", nerd_glyph = "C", action = true } }
    for _i, l in ipairs(labels) do chips[#chips + 1] = { key = l, label = l } end
    chips[#chips + 1] = { key = "search", nerd_glyph = "S", action = true }
    return chips
end
local function bar(labels, width)
    return ChipBar:new{
        chips = makeChips(labels), active = labels[1], selected_key = labels[1],
        width = width, height = 40,
    }
end

test("few chips on a wide bar: single page, no chevrons", function()
    local b = bar({ "Home", "Recent" }, 2000)
    assert(b._pages.multi == false, "should be single page")
    assert(b._chip_dimens["__chip_nextpage"] == nil, "no next chevron")
    assert(b._chip_dimens["__chip_prevpage"] == nil, "no prev chevron")
    assert(b._chip_dimens["Home"] and b._chip_dimens["Recent"], "both chips rendered")
    assert(b:onSwipeStrip(nil, { direction = "west" }) == false, "swipe falls through when single page")
end)

test("many long labels on a narrow bar: paginates with chevrons", function()
    local b = bar({ "AUTHORS", "COLLECTIONS", "SCIENCE FICTION", "FAVOURITES", "HISTORY", "BIOGRAPHIES" }, 360)
    assert(b._pages.multi == true, "should paginate")
    assert(b._pages.num_pages >= 2, "expected >= 2 pages, got " .. b._pages.num_pages)
    assert(b._page == 1, "starts on the active chip's page (AUTHORS is on page 1)")
    assert(b._chip_dimens["__chip_nextpage"], "next chevron present on page 1")
    assert(b._chip_dimens["__chip_prevpage"] == nil, "no prev chevron on page 1")
    -- A chip on a later page must NOT be rendered (no hit-test entry).
    local last_label = "BIOGRAPHIES"
    assert(b._chip_dimens[last_label] == nil, "last-page chip should not render on page 1")
    -- The always-visible action chips stay rendered on every page.
    assert(b._chip_dimens["current"] and b._chip_dimens["search"], "action chips always visible")
end)

test("paging forward shows the prev chevron and a later chip", function()
    local b = bar({ "AUTHORS", "COLLECTIONS", "SCIENCE FICTION", "FAVOURITES", "HISTORY", "BIOGRAPHIES" }, 360)
    local p1_first = b._pages.pages[1].first
    b:_gotoPage(2)
    assert(b._page == 2, "moved to page 2")
    assert(b._chip_dimens["__chip_prevpage"], "prev chevron present on page 2")
    -- A page-1 chip is no longer rendered; a page-2 chip now is.
    local page1_label = b.chips[1 + p1_first].label  -- first nav chip (after `current`)
    assert(b._chip_dimens[page1_label] == nil, "page-1 chip dropped on page 2")
    local pg2 = b._pages.pages[2]
    local page2_label = b.chips[1 + pg2.first].label
    assert(b._chip_dimens[page2_label], "page-2 chip rendered on page 2")
end)

test("swipe west pages forward, east pages back, clamped", function()
    local b = bar({ "AUTHORS", "COLLECTIONS", "SCIENCE FICTION", "FAVOURITES", "HISTORY", "BIOGRAPHIES" }, 360)
    assert(b:onSwipeStrip(nil, { direction = "west" }) == true, "west consumed when multi-page")
    assert(b._page == 2, "west advanced to page 2")
    b:onSwipeStrip(nil, { direction = "east" })
    assert(b._page == 1, "east went back to page 1")
    b:onSwipeStrip(nil, { direction = "east" })  -- clamp at first page
    assert(b._page == 1, "clamped at page 1")
end)

test("warmKeys: single page returns all nav chips, excludes action chips", function()
    local b = bar({ "Home", "Recent" }, 2000)
    local set = {}; for _i, k in ipairs(b:warmKeys()) do set[k] = true end
    assert(set["Home"] and set["Recent"], "both nav chips warmable")
    assert(not set["current"] and not set["search"], "action chips never warmed")
end)

test("warmKeys: paginated returns current + next page only (page-bounded)", function()
    local b = bar({ "AUTHORS", "COLLECTIONS", "SCIENCE FICTION", "FAVOURITES", "HISTORY", "BIOGRAPHIES" }, 360)
    local function navKey(flexpos) return b.chips[b._flex_indices[flexpos]].key end
    local set = {}; for _i, k in ipairs(b:warmKeys()) do set[k] = true end
    assert(set[navKey(b._pages.pages[1].first)], "page-1 chip is warmable")
    if b._pages.num_pages >= 3 then
        assert(set[navKey(b._pages.pages[2].first)], "page-2 chip warmable (next-page bias)")
        assert(not set[navKey(b._pages.pages[3].first)], "page-3 chip NOT warmed from page 1")
    end
    -- After paging to the last page, its chips are warmable and there's no next.
    b:_gotoPage(b._pages.num_pages)
    local set2 = {}; for _i, k in ipairs(b:warmKeys()) do set2[k] = true end
    assert(set2[navKey(b._pages.pages[b._pages.num_pages].first)], "last-page chip warmable when on it")
end)

print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
