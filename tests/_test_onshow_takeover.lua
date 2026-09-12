-- tests/_test_onshow_takeover.lua
-- main.lua: Bookshelf:onShow, the synchronous catch that puts the shelf on
-- top of KOReader's file manager before anything can paint it.
--
-- Issue 385. The reporter's own diagnostic trace settled it:
--
--     route: document closing
--     instant book close: true | start with: history
--        0ms onCloseDocument.enter | bookshelf > ReaderUI
--      645ms forceRePaint         | fullscreen
--
-- Their "Start with" is History, and onShow returned on its first line
-- because of it -- so the takeover never ran, the file manager stood alone,
-- and the repaint at 645ms is the flash. The shelf arrived later, on
-- onCloseDocument's next tick.
--
-- Where the shelf goes when a book CLOSES was decoupled from "Start with"
-- deliberately (issue #98): the reader-close destination is "whatever opened
-- the book", not a restart preference. onShow never got that memo. It does
-- not need the check either way now -- the announcement IS the gate, and only
-- a route that means to take this Show sets it. Cold boot still announces
-- only when Start with is Bookshelf.
--
-- Usage (from plugin root): lua tests/_test_onshow_takeover.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = dofile("tests/_helpers.lua")
local t = H.runner()

local src  = io.open("main.lua"):read("*a")
local body = src:match("\nfunction Bookshelf:onShow%(%)\n(.-)\nend\n")
assert(body, "could not find Bookshelf:onShow() in main.lua - renamed?")

local function compile(code, env)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, "onShow"))
        _G.setfenv(f, env)
        return f
    end
    return assert(load(code, "onShow", "t", env))
end

-- start_with: the user's setting. announced: whether a route asked for this
-- Show. shown: whether the shelf widget is already up.
local function runOnShow(start_with, announced, shelf_shown)
    local shown = 0
    local env = {
        _expect_onshow_takeover = announced,
        _live_widget = shelf_shown and { name = "bookshelf" } or nil,
        pairs = pairs, ipairs = ipairs, type = type, tostring = tostring,
        pcall = pcall, error = error, select = select,
        _flash = function() end,
        G_reader_settings = {
            readSetting = function(_s, k)
                if k == "start_with" then return start_with end
            end,
        },
        UIManager = { isWidgetShown = function() return shelf_shown == true end },
        require = function(name)
            if name == "lib/bookshelf_book_repository" then
                return { hasBookInfoManager = function() return true end }
            end
            error("unexpected require in onShow: " .. tostring(name))
        end,
    }
    local self = { show = function() shown = shown + 1 end, ui = {} }
    compile("local self = ... ; " .. body, env)(self)
    return shown, env
end

t.test("onShow: an announced takeover is taken", function()
    local shown = runOnShow("bookshelf", true, false)
    assert(shown == 1, "the announced takeover did not happen")
end)

t.test("onShow: an announced takeover is taken whatever Start with says", function()
    -- The reporter's configuration. Their book close announced the takeover;
    -- onShow refused it because their Start with is History, so the file
    -- manager was left on screen to be painted (#385).
    for _, sw in ipairs({ "history", "filemanager", "last", nil }) do
        local shown = runOnShow(sw, true, false)
        assert(shown == 1,
            "an announced takeover was refused because Start with was "
            .. tostring(sw) .. " -- the file manager is then left to paint")
    end
end)

t.test("onShow: an UNannounced Show is left alone", function()
    -- The gate's whole purpose: another home-screen plugin's Show, or the
    -- file manager a book was opened from, must not be hijacked.
    for _, sw in ipairs({ "bookshelf", "history" }) do
        local shown = runOnShow(sw, false, false)
        assert(shown == 0,
            "onShow hijacked a Show nobody announced (Start with " .. sw .. ")")
    end
end)

t.test("onShow: a shelf already on screen is not shown again", function()
    local shown = runOnShow("bookshelf", true, true)
    assert(shown == 0, "the shelf was already up; showing it again would flash")
end)

t.test("onShow: the announcement is consumed, so it arms exactly one Show", function()
    local _shown, env = runOnShow("bookshelf", true, false)
    assert(env._expect_onshow_takeover == false,
        "a live announcement would hijack the NEXT unrelated Show too")
end)

t.done()
