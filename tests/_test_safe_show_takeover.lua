-- tests/_test_safe_show_takeover.lua
-- main.lua: Bookshelf:_safeShow must announce the onShow takeover.
--
-- #385 (the #110 flash class, back again). _safeShow is the reader -> "File
-- browser" route: close the document, show KOReader's FileManager, then raise
-- the shelf over it. showFileManager fires a Show event, and Bookshelf:onShow
-- catching that SYNCHRONOUSLY is the only thing that puts the shelf on top
-- before anything can paint the bare FileManager.
--
-- onShow's gate is positive -- it stands down unless a takeover was announced
-- (commit e39d639, so another home-screen plugin's Show is not hijacked) --
-- and on this route nobody was announcing it:
--   * onCloseDocument returns early on _suppress_close_document_show, which
--     _safeShow sets, and the announce sits BELOW that return;
--   * the FileManager's own init only announces on the session's FIRST
--     FileManager (_did_initial_takeover), never on a reader-close one.
-- So the FM sat alone on the window stack until the raise two statements
-- later. Rig-verified both ways: without the announce the stack after
-- showFileManager is [filemanager], with it [filemanager | bookshelf].
--
-- Usage (from plugin root): lua tests/_test_safe_show_takeover.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = dofile("tests/_helpers.lua")
local t = H.runner()

-- Pull the method's body out of main.lua and run it under a fabricated
-- environment: compiled standalone, every file-local upvalue it referenced
-- (UIManager, the takeover flags, ...) resolves as a global we can stub.
local src  = io.open("main.lua"):read("*a")
local body = src:match("\nfunction Bookshelf:_safeShow%(%)\n(.-)\nend\n")
assert(body, "could not find Bookshelf:_safeShow() in main.lua - renamed?")

local function compile(code, env)  -- LuaJIT 5.1 and Lua 5.4 disagree here
    if _G.setfenv then
        local f = assert(_G.loadstring(code, "_safeShow"))
        _G.setfenv(f, env)
        return f
    end
    return assert(load(code, "_safeShow", "t", env))
end

-- parked: what Park.park() answers, i.e. whether the hot-parking fast path
-- takes the call before the close route is reached.
local function runSafeShow(parked)
    local ticks = {}
    local env = {
        -- The flags under test start where main.lua starts them.
        _expect_onshow_takeover      = false,
        _suppress_close_document_show = false,
        _live_widget                  = { name = "bookshelf" },
        pairs = pairs, ipairs = ipairs, type = type, tostring = tostring,
        _ = function(s) return s end,
        G_reader_settings = { readSetting = function() return nil end },
        -- Skip the "Closing book…" notice: it is not what this pins.
        BookshelfSettings = { nilOrTrue = function() return false end },
        UIManager = {
            show = function() end,
            close = function() end,
            setDirty = function() end,
            forceRePaint = function() end,
            nextTick = function(_self, fn) ticks[#ticks + 1] = fn end,
            scheduleIn = function(_self, _s, fn) ticks[#ticks + 1] = fn end,
        },
        require = function(name)
            if name == "lib/bookshelf_reader_park" then
                return { park = function() return parked end }
            end
            error("unexpected require in _safeShow: " .. tostring(name))
        end,
    }
    local shown, raised, closed = 0, 0, 0
    local self = {
        show = function() shown = shown + 1 end,
        _raiseInPlace = function() raised = raised + 1 end,
        ui = {
            document = { file = "/books/a.epub" },
            onHome = function() end,
            onClose = function() closed = closed + 1 end,
            showFileManager = function() end,
        },
    }
    compile("local self = ... ; " .. body, env)(self)
    return env, ticks, { shown = shown, raised = raised, closed = closed }
end

t.test("safeShow: the close route announces the takeover before it runs", function()
    local env, ticks = runSafeShow(false)
    -- Announced BEFORE the queued work: the Show that onShow has to catch
    -- fires inside showFileManager, which runs on that tick.
    assert(env._expect_onshow_takeover == true,
        "the takeover was not announced, so onShow stands down and the bare "
        .. "FileManager is exposed until the raise (#385)")
    assert(env._suppress_close_document_show == true,
        "the close route still suppresses onCloseDocument's parallel show")
    assert(#ticks > 0, "the close route queues its close+showFM work")
end)

t.test("safeShow: hot parking takes the call without announcing anything", function()
    -- Parking leaves the book open and splices the shelf on top: no document
    -- close, no FileManager, so nothing to announce. Announcing anyway would
    -- leave the gate armed for an unrelated Show.
    local env, _ticks, calls = runSafeShow(true)
    assert(env._expect_onshow_takeover == false,
        "the parking fast path must not arm the takeover gate")
    assert(env._suppress_close_document_show == false,
        "the parking fast path closes no document")
    assert(calls.shown == 0 and calls.closed == 0,
        "parking returns before the close route entirely")
end)

t.done()
