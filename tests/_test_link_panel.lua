-- tests/_test_link_panel.lua
-- QR codes in About (the user guide) and the add-pack panels (the shop), to
-- open a link on a phone from an e-reader with no browser (maintainer,
-- 2026-10-31).
--
-- Usage (from plugin root): lua tests/_test_link_panel.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

-- A blitbuffer that records what is painted.
local painted
package.loaded["ffi/blitbuffer"] = {
    TYPE_BB8 = 1, COLOR_WHITE = "white", COLOR_BLACK = "black",
    new = function(w, h)
        painted = { w = w, h = h, rects = {} }
        return { fill = function(_s, c) painted.fill = c end,
                 paintRect = function(_s, x, y, rw, rh, c)
                     painted.rects[#painted.rects + 1] = { x, y, rw, rh, c }
                 end }
    end,
}
package.loaded["device"] = { screen = { scaleBySize = function(_s, n) return n end } }
package.loaded["ui/uimanager"] = {}
package.loaded["lib/bookshelf_space"] = { px = function(n) return n end }
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
package.loaded["ui/widget/imagewidget"] = { new = function(_s, o) return o end }
-- A 21-module code: dark at its corners and the middle.
local grid = {}
for x = 1, 21 do
    grid[x] = {}
    for y = 1, 21 do grid[x][y] = -1 end
end
grid[1][1], grid[21][21], grid[11][11] = 1, 1, 1
package.loaded["ffi/qrencode"] = { qrcode = function() return true, grid end }

local LP = require("lib/bookshelf_link_panel")

t.test("whole pixels a module, a white quiet zone round it, black kept at night", function()
    local w = LP.qr("https://example.com", 130)
    -- 21 + 2 * 4 = 29 modules: 4 px each in 130, so 116 square.
    eq(w.width, 116); eq(painted.w, 116)
    eq(painted.fill, "white")
    eq(#painted.rects, 3)
    local r = painted.rects[1]
    eq(r[1], 16); eq(r[2], 16); eq(r[3], 4); eq(r[5], "black")   -- inside the quiet zone
    eq(w.original_in_nightmode, true, "night mode would invert the code")
end)

t.test("no encoder, no code: the link still shows", function()
    package.loaded["ffi/qrencode"] = { qrcode = function() return false, "too long" end }
    eq(LP.qr("x", 130), nil)
end)

t.test("About shows the user guide's code; both add panels the shop's", function()
    local s = io.open("lib/bookshelf_settings.lua"):read("*a")
    assert(s:find("LinkPanel.qr(DOCS_URL", 1, true), "About has no code for the user guide")
    for _i, f in ipairs({ "lib/bookshelf_theme_pack.lua", "lib/bookshelf_ornament_browser.lua" }) do
        assert(io.open(f):read("*a"):find('require("lib/bookshelf_link_panel").showShop{', 1, true),
            f .. ": no shop code")
    end
end)

-- On e-ink nothing shows until a refresh is queued, and UIManager:show with
-- no refresh type queues none: Add theme pack did nothing on the PW5 while
-- the rig, which shows the framebuffer, showed it (maintainer, 2026-10-31).
-- About only appeared because the closing menu refreshed the screen.
t.test("the panel refreshes the screen when it opens and when it closes", function()
    local src = io.open("lib/bookshelf_link_panel.lua"):read("*a")
    assert(src:find('function dialog:onShow()', 1, true), "nothing refreshes the panel on show")
    assert(src:find('function dialog:onCloseWidget()', 1, true), "nothing refreshes where it was on close")
    assert(select(2, src:gsub('return "ui", frame.dimen', "")) >= 2, "the refreshes are not the frame's")
end)

t.done()
