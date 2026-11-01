-- tests/_test_page_dialog_tap_outside.lua
-- A tap outside a slider page closes it and keeps the value, as Done does
-- (maintainer: the shelf can be paged behind it to judge the change; the
-- rapid taps that fell through and closed it were a stock-dialog fault on
-- e-ink). The X and Back still put the value back.
-- Usage (from plugin root): lua tests/_test_page_dialog_tap_outside.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

local src = io.open("lib/bookshelf_page_dialog.lua"):read("*a")
local body = src:match("\n(function PageDialog:onTapClose%(.-\nend)\n")
assert(body, "no onTapClose")
local closed = {}
local env = setmetatable({
    PageDialog = {},
    UIManager = { close = function(_s, w) closed[#closed + 1] = w end },
}, { __index = _G })
assert(load(body, "onTapClose", "t", env))()
function env.PageDialog:_dismiss() closed[#closed + 1] = self; self.dismissed = true end

local function pt(x, y)
    return { x = x, y = y, notIntersectWith = function(p, r)
        return p.x < r.x or p.x >= r.x + r.w or p.y < r.y or p.y >= r.y + r.h end }
end
local function dialog(o)
    o = o or {}
    o.frame = { dimen = { x = 100, y = 100, w = 100, h = 100 } }
    return setmetatable(o, { __index = env.PageDialog })
end

t.test("a tap outside with on_tap_outside goes to that (which closes it), not on_close", function()
    closed = {}
    local kept = 0
    local d = dialog({ on_tap_outside = function() kept = kept + 1 end })
    d:onTapClose(nil, { pos = pt(10, 10) })
    eq(kept, 1); eq(d.dismissed, nil, "on_close (put the value back) ran")
end)

t.test("a tap on the page closes nothing", function()
    closed = {}
    local kept = 0
    local d = dialog({ on_tap_outside = function() kept = kept + 1 end })
    d:onTapClose(nil, { pos = pt(150, 150) })
    eq(kept, 0); eq(#closed, 0)
end)

t.test("without on_tap_outside a tap outside is the X, as before", function()
    closed = {}
    local d = dialog()
    d:onTapClose(nil, { pos = pt(10, 10) })
    eq(d.dismissed, true)
end)

t.test("the slider pages close on a tap outside, keeping the value", function()
    local s = io.open("lib/bookshelf_settings.lua"):read("*a")
    local b = s:match("\nfunction Settings:_nudgePage%(.-\nend\n")
    assert(b, "no _nudgePage")
    assert(not b:find("dismissable = false", 1, true), "a tap outside does nothing")
    assert(b:find("on_tap_outside = function() done(false) end", 1, true), "a tap outside is not Done")
end)

t.done()
