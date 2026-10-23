-- tests/_test_page_turn_flash.lua
-- Issue 529: "Use E-ink refresh rate for shelf pages" makes the shelf follow KOReader's
-- own Full refresh rate. Shelf page turns refresh in "ui" mode, which
-- KOReader never promotes to a flash, so "Every page" in KOReader still left
-- the shelf ghosting. The shelf now counts its own turns against that rate.
-- Run from the plugin root: lua tests/_test_page_turn_flash.lua
package.path = "./?.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()
local src = io.open("lib/bookshelf_widget.lua"):read("*a")

-- Pull _pageTurnFlashDue out by name; its upvalues become stubbable globals.
local body = src:match("\n(function BookshelfWidget%._pageTurnFlashDue%(%).-\nend)\n")
assert(body, "_pageTurnFlashDue moved")

local function load_due(opts)
    local BW = {}
    local env = setmetatable({
        BookshelfWidget = BW,
        BookshelfSettings = { isTrue = function(k)
            return k == "shelf_full_refresh" and opts.on or false end },
        Device = { hasEinkScreen = function() return opts.eink ~= false end },
        UIManager = { FULL_REFRESH_COUNT = opts.rate },
    }, { __index = _G })
    local chunk = assert((loadstring or load)(body, "due", "t", env))
    if setfenv then setfenv(chunk, env) end
    chunk()
    return function() return BW._pageTurnFlashDue() end
end

local function pattern(due, turns)
    local out = {}
    for i = 1, turns do out[i] = due() and "F" or "." end
    return table.concat(out)
end

t.test("off by default: never flashes", function()
    assert(pattern(load_due{ on = false, rate = 1 }, 4) == "....")
end)

t.test("Every page flashes every turn", function()
    assert(pattern(load_due{ on = true, rate = 1 }, 4) == "FFFF")
end)

t.test("every 6 pages flashes on the sixth turn", function()
    local p = pattern(load_due{ on = true, rate = 6 }, 12)
    assert(p == ".....F.....F", "got " .. p)
end)

t.test("Never and chapter-boundary rates never flash", function()
    assert(pattern(load_due{ on = true, rate = 0 }, 4) == "....")
    assert(pattern(load_due{ on = true, rate = -1 }, 4) == "....")
end)

t.test("an LCD screen never flashes", function()
    assert(pattern(load_due{ on = true, rate = 1, eink = false }, 3) == "...")
end)

t.test("a page turn uses the mode it picked, and a flash skips the wipe", function()
    local swap = src:match("function BookshelfWidget:_swapShelvesInPlace%(%)(.-)\nend\n")
    assert(swap, "_swapShelvesInPlace moved")
    local due = swap:find("_wipe_dir and BookshelfWidget._pageTurnFlashDue()", 1, true)
    local skip = swap:find("if flash then anim_steps = nil end", 1, true)
    local wipe = swap:find("if anim_steps then", 1, true)
    assert(due and skip and wipe and due < skip and skip < wipe,
        "the flash decision must come before the wipe")
    -- Directly, or returned from a refresh function (the rows' region is
    -- decided after the paint when a tall piece reaches above them).
    local _n = select(2, swap:gsub("UIManager:setDirty%(self, refresh_mode", ""))
             + select(2, swap:gsub("return refresh_mode, Geom:new", ""))
    assert(_n == 3, "every rows refresh should use refresh_mode, found " .. _n)
end)

t.done()
