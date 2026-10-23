-- tests/_test_tall_ornament_top.lua
-- A piece on the first shelf may be made tall enough to stand up over the
-- shelf menu and the top panel (allowed on purpose). Two things follow: a
-- page turn must refresh as high as the pieces of BOTH pages reach, or the
-- old one stays on the panel; and a piece must not take taps meant for the
-- panel or the menu it stands over (maintainer, PW5).
package.path = "./?.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()
local w = io.open("lib/bookshelf_widget.lua"):read("*a")
local function fn(name)
    return w:match("\nfunction BookshelfWidget[:.]" .. name:gsub("[%.%:]", "%%%0") .. "%(.-\nend\n")
end

-- _ornReachTop, run for real against fake rows.
local function reachTop()
    local body = fn("_ornReachTop")
    assert(body, "_ornReachTop not found")
    local src = body:gsub("^\nfunction BookshelfWidget%._ornReachTop", "return function")
    local env = setmetatable({
        Screen = { scaleBySize = function(_, v) return v end },
        package = { loaded = { ["lib/bookshelf_ornaments"] = {
            -- The drawing starts 25% down its box.
            contentBox = function() return 0, 0.25, 1, 1 end,
        } } },
    }, { __index = _G })
    return assert(load(src, "reach", "t", env))()
end

local function piece(y, h) return { placement = { entry = {} }, dimen = { x = 0, y = y, w = 10, h = h } } end

t.test("the reach is the highest drawing on the rows, less the glow margin", function()
    local reach = reachTop()
    -- A row: a group holding a tile stack and two pieces.
    local row = { { { piece(400, 200) } }, piece(300, 400) }
    -- 300 + 0.25 * 400 = 400, less 8 for the glow.
    assert(reach({ row }) == 392, tostring(reach({ row })))
end)

t.test("no painted piece, no reach", function()
    local reach = reachTop()
    assert(reach({ { { placement = { entry = {} }, dimen = { w = 1, h = 1 } } } }) == nil, "an unpainted piece counted")
    assert(reach({ {} }) == nil)
end)

t.test("a page turn refreshes up to both pages' pieces", function()
    local swap = fn("_swapShelvesInPlace")
    assert(swap, "_swapShelvesInPlace not found")
    assert(swap:find("local old_reach = BookshelfWidget._ornReachTop({ self._inner_vgroup[d.shelf_top_idx] })", 1, true),
           "the leaving page's reach is not read before the swap")
    local _, n = swap:gsub("BookshelfWidget%._ornReachTop%({ rows%[1%] }%)", "")
    assert(n == 2, "the new page's reach is not used by both the wipe and the plain refresh")
    assert(swap:find("UIManager:setDirty(self, function()", 1, true),
           "the plain refresh does not decide its region after the paint")
end)

t.test("a piece takes no gesture above the top panel's bottom", function()
    assert(w:find("local top = shelf:_ornGestureTop()", 1, true) and w:find("return top ~= nil and pos.y < top", 1, true),
           "the blocked hook does not cover the panel and menu")
    local g = fn("_ornGestureTop")
    assert(g and g:find("d.wipe_rows_top - (d.hang_top_gap or 0)", 1, true), "the line is not the panel's bottom")
end)

t.done()
