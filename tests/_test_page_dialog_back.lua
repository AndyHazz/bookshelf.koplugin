-- tests/_test_page_dialog_back.lua
-- PageDialog's on_back: a page inside a menu (STYLE.md, Pages) goes back on
-- the Back key and the title's chevron, closing itself first; without
-- on_back the Back key is the X, as before.
-- Usage (from plugin root): lua tests/_test_page_dialog_back.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

local src = io.open("lib/bookshelf_page_dialog.lua"):read("*a")
local back = src:match("\n(function PageDialog:_back%(.-\nend)\n")
local onclose = src:match("\n(function PageDialog:onClose%(.-\nend)\n")
assert(back and onclose, "no _back / onClose")
local log = {}
local env = setmetatable({
    PageDialog = {},
    UIManager = { close = function(_s, w) log[#log + 1] = "close" end },
}, { __index = _G })
assert(load(back, "_back", "t", env))()
assert(load(onclose, "onClose", "t", env))()
function env.PageDialog:_dismiss() log[#log + 1] = "dismiss" end
local function dialog(o) return setmetatable(o or {}, { __index = env.PageDialog }) end

t.test("Back with on_back closes, then goes back", function()
    log = {}
    local d = dialog({ on_back = function() log[#log + 1] = "back" end })
    d:onClose()
    eq(table.concat(log, ","), "close,back")
end)

t.test("Back without on_back is the X", function()
    log = {}
    dialog():onClose()
    eq(table.concat(log, ","), "dismiss")
end)

t.test("the title gets the chevron and Back only with on_back", function()
    assert(src:find('left_icon = self.on_back and "chevron.left" or nil', 1, true), "no chevron")
    assert(src:find("if self.on_back then require(\"lib/bookshelf_popup_kit\").backLabel(title_bar) end", 1, true), "no Back label")
end)

t.done()
