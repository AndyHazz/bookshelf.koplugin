-- tests/_test_refresh_notice_wait.lua
-- Swipe-down refresh shows "Refreshing library..." and rebuilds. On a
-- Kindle Paperwhite 6 the notice often did not show, or showed cut in half
-- (issue 584). It is a MediaTek Kindle: KOReader sends a refresh there
-- without waiting for the panel to take it, and the rebuilt shelf was
-- written over the notice before the panel had read it. The refresh waits
-- for the panel to take the notice before the rebuild, as a pressed card
-- does (Kit.pressThen).
--
-- Usage (from plugin root): lua tests/_test_refresh_notice_wait.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

local src = io.open("lib/bookshelf_widget.lua"):read("*a")
local body = src:match("\n(function BookshelfWidget:_refreshLibrary%(%)\n.-\nend)\n")
assert(body, "_refreshLibrary moved")

local seq = {}
local UIManager = {
    show = function() seq[#seq + 1] = "show" end,
    setDirty = function() end,
    forceRePaint = function() seq[#seq + 1] = "flush" end,
    yieldToEPDC = function() seq[#seq + 1] = "yield" end,
    nextTick = function(_s, f) f() end,
    close = function() seq[#seq + 1] = "close" end,
}
local screen = {}
local mods = {
    ["ui/widget/infomessage"] = { new = function(_s, o) return o end },
    ["lib/bookshelf_book_repository"] = { invalidateWalkCache = function() seq[#seq + 1] = "wipe" end },
    ["lib/bookshelf_sources"] = { get = function() return nil end },
    ["device"] = { screen = screen },
}
-- The real waitForPanel, from the popup kit's source.
local kit_src = io.open("lib/bookshelf_popup_kit.lua"):read("*a")
local wait_body = kit_src:match("\n(function Kit%.waitForPanel%(%)\n.-\nend)\n")
assert(wait_body, "Kit.waitForPanel moved")
local Kit = {}
local kit_env = setmetatable({ Kit = Kit, require = function(n) return mods[n] or require(n) end },
    { __index = _G })
mods["ui/uimanager"] = UIManager
if _G.setfenv then
    local f = assert(_G.loadstring(wait_body)); _G.setfenv(f, kit_env); f()
else
    assert(load(wait_body, "wait", "t", kit_env))()
end
mods["lib/bookshelf_popup_kit"] = Kit

local env = setmetatable({
    UIManager = UIManager,
    _ = function(s) return s end,
    require = function(name) return mods[name] or require(name) end,
    BookshelfWidget = {},
}, { __index = _G })
local chunk = body .. "\nreturn BookshelfWidget"
local BW
if _G.setfenv then
    local f = assert(_G.loadstring(chunk)); _G.setfenv(f, env); BW = f()
else
    BW = assert(load(chunk, "refresh", "t", env))()
end
local widget = setmetatable({
    _opdsEffectiveTab = function() return nil end,
    _currentRegisteredSource = function() return nil end,
    _rebuild = function() seq[#seq + 1] = "rebuild" end,
}, { __index = BW })

local function run()
    for i = #seq, 1, -1 do seq[i] = nil end
    widget:_refreshLibrary()
    return table.concat(seq, ",")
end

t.test("the panel takes the notice before the rebuild paints over it", function()
    screen.marker = 7
    screen.mech_wait_update_submission = function(_fb, m) seq[#seq + 1] = "taken " .. m; return 0 end
    eq(run(), "show,flush,taken 7,wipe,rebuild,close")
    screen.marker, screen.mech_wait_update_submission = nil, nil
end)

t.test("a screen that cannot say still yields to the panel", function()
    eq(run(), "show,flush,yield,wipe,rebuild,close")
end)

t.done()
