-- tests/_test_footer_hidden.lua
-- Settings > Behavior > Footer bar (maintainer): Show (default); Hide, the
-- shelf takes the space; Invisible buttons, the space and the buttons kept,
-- painted unseen (a button learns its hit box as it paints), and shown when
-- the keys move into the footer. Both hidden modes show the bar while
-- selecting (its X and bucket are the way out).
-- Usage (from plugin root): lua tests/_test_footer_hidden.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

local W = io.open("lib/bookshelf_widget.lua"):read("*a")

-- _paintUnseen(bb, x, y, w, h, paint): runs paint, then puts the rect back.
local body = W:match("\n(local function _paintUnseen%(.-\nend)\n")
assert(body, "no _paintUnseen")

-- A fake buffer: a grid of numbers, blitFrom copying rects.
local function buf(w, h, fill)
    local b = { w = w, h = h, px = {} }
    for i = 1, w * h do b.px[i] = fill end
    function b:getType() return 1 end
    function b:get(x, y) return self.px[y * self.w + x + 1] end
    function b:set(x, y, v) self.px[y * self.w + x + 1] = v end
    function b:blitFrom(src, dx, dy, sx, sy, w_, h_)
        for j = 0, h_ - 1 do for i = 0, w_ - 1 do self:set(dx + i, dy + j, src:get(sx + i, sy + j)) end end
    end
    function b:free() self.freed = true end
    return b
end
local made = {}
local env = setmetatable({
    require = function(n)
        if n == "lib/bookshelf_clip_bb" then return { real = function(b) return b end } end
        if n == "ffi/blitbuffer" then
            return { new = function(w, h) local b = buf(w, h, 0); made[#made + 1] = b; return b end }
        end
        return require(n)
    end,
}, { __index = _G })
local paintUnseen = assert(load(body .. "\nreturn _paintUnseen", "pu", "t", env))()

t.test("the footer paints (hit boxes set) and the screen under it comes back", function()
    local screen = buf(10, 10, 7)
    local painted = false
    local r = paintUnseen(screen, 0, 6, 10, 4, function()
        painted = true
        for y = 6, 9 do for x = 0, 9 do screen:set(x, y, 1) end end
        screen:set(0, 2, 1)   -- outside the footer: stays
        return "ret"
    end)
    eq(painted, true); eq(r, "ret")
    for y = 6, 9 do for x = 0, 9 do assert(screen:get(x, y) == 7, "footer pixel left at " .. x .. "," .. y) end end
    eq(screen:get(0, 2), 1)
    eq(made[#made].freed, true, "the copy is freed")
end)

local function fn(name)
    local b = W:match("\n(local function " .. name .. "%(.-\nend)\n")
    assert(b, name .. " moved")
    return b
end

t.test("three modes, Show by default; Hide gives the shelf the footer's space", function()
    local store = {}
    local fenv = setmetatable({
        BookshelfSettings = { read = function(k, d) if store[k] == nil then return d end return store[k] end },
        Screen = { scaleBySize = function(_s, v) return v end },
    }, { __index = _G })
    local chunk = fn("_footerMode") .. "\n" .. fn("_footerBarH") .. "\n" .. fn("_footerReserveH")
        .. "\nreturn _footerMode, _footerBarH, _footerReserveH"
    local mode, barH, reserveH = assert(load(chunk, "f", "t", fenv))()
    eq(mode(), "show"); eq(reserveH(), barH())
    store.footer_bar = "invisible"; eq(mode(), "invisible"); eq(reserveH(), barH(), "invisible keeps the space")
    store.footer_bar = "hide"; eq(mode(), "hide"); assert(reserveH() < barH() / 2, "hide keeps the space")
    store.footer_bar = "junk"; eq(mode(), "show")
end)

t.test("the footer row: empty when hidden, unseen when invisible, shown while selecting or focused", function()
    local row = W:match("\nfunction BookshelfWidget:_buildFooterRow%(.-\nend\n")
    assert(row:find('self._selection:isActive() or self._focus_zone == "footer"', 1, true), "no reveal")
    assert(row:find('mode == "hide" and not reveal', 1, true), "hide does not drop the row")
    assert(row:find('mode == "invisible" and not reveal', 1, true), "invisible is not painted unseen")
    assert(row:find("_paintUnseen(bb, x, y, self.width, footer_h", 1, true), "the row is not painted unseen")
    assert(W:find('require("lib/bookshelf_clip_bb").real(bb), 0, 0, x, y, w, h)', 1, true),
        "a clipped paint's stand-in is read directly")
    local lp = W:match("\nfunction BookshelfWidget:_layoutPrimitives%(.-\nend\n")
    assert(lp:find('_footerMode() == "hide"', 1, true), "the grid still budgets for a hidden footer")
end)

t.test("a revealed bar is refreshed whole (the outgoing hidden row is short)", function()
    local sw = W:match("\nfunction BookshelfWidget:_swapFooterInPlace%(.-\nend\n")
    assert(sw:find("math.max(old_row:getSize().h, _footerBarH())", 1, true), "the band follows the old row only")
end)

t.test("Behavior has Footer bar: Show, Hide, Invisible buttons", function()
    local S = io.open("lib/bookshelf_settings.lua"):read("*a")
    local beh = S:match("\nfunction Settings:_behaviourSubItems%(.-\nend\n")
    assert(beh and beh:find('_("Footer bar")', 1, true), "no Footer bar row")
    for _i, v in ipairs({ '"show"', '"hide"', '"invisible"', '_("Invisible buttons")' }) do
        assert(beh:find(v, 1, true), "missing " .. v)
    end
    local adv = S:match("\nfunction Settings:_advancedSubItems%(.-\nend\n")
    assert(not adv:find("footer", 1, true), "still in Advanced")
end)

t.done()
