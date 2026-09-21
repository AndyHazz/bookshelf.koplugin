-- tests/_test_menu_search_shortcut.lua
-- "Menu search" works as a start-menu item.
--
-- THE REPORT (#438). "I'm trying to add the Menu search item (from the Help
-- menu) to my start menu, but tapping it from the start menu does nothing.
-- I've verified that System statistics from the same menu does work as a
-- start menu item."
--
-- THE CAUSE. KOReader's row is one line --
-- `UIManager:sendEvent(Event:new("ShowMenuSearch"))` in
-- frontend/ui/elements/common_info_menu_table.lua -- and the only handler in
-- the tree is TouchMenu:onShowMenuSearch, a method on a LIVE menu. It
-- searches that menu's own item_table and, on a result, calls self:openMenu()
-- to walk THAT menu to the entry. The feature has no standalone form; its
-- whole output is moving the real menu somewhere.
--
-- MenuShortcut.replay fires a captured leaf's callback with a shim, so the
-- event goes out with no TouchMenu anywhere, walks the window stack, finds
-- nobody and is dropped. Hence "does nothing" -- while System statistics
-- works from the same page because its callback shows a widget of its own.
--
-- Measured on the rig before the fix:
--     search dialog present = false   stack = 1:KOReader  2:bookshelf
-- and after:
--     search dialog present = true    stack = ... 3:<menu>  4:Search menu entry
--
-- Usage (from plugin root): lua tests/_test_menu_search_shortcut.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq
local src = io.open("lib/bookshelf_widget.lua"):read("*a")

-- The guard and the handler together: the flag is an upvalue of the handler,
-- so the two only mean anything as a pair.
local body = src:match("(local _in_menu_search = false\nfunction BookshelfWidget:onShowMenuSearch%(%)\n.-\nend)")
assert(body, "onShowMenuSearch moved or was renamed")

-- Build the handler over stubs. `resend` decides what the re-sent event does:
-- in the real world the freshly-opened TouchMenu eats it, but if the menu
-- failed to open it walks straight back to this handler, which is the case
-- the guard exists for.
local function build(opts)
    opts = opts or {}
    local log = { opened = 0, sent = 0 }
    local fm = opts.fm
    if fm == nil then
        fm = { menu = { onShowMenu = function() log.opened = log.opened + 1 end } }
    end
    local env = { pcall = pcall, type = type }
    env.UIManager = {
        sendEvent = function(_, ev)
            log.sent = log.sent + 1
            -- the "nobody opened a menu" case: the event comes back to us
            if opts.bounce then env.BookshelfWidget:onShowMenuSearch() end
        end,
    }
    env.require = function(name)
        if name == "ui/event" then
            return { new = function(_, n) return { name = n } end }
        end
        if name == "lib/bookshelf_reader_park" then
            return { runInFileManager = function(action) action(fm) end }
        end
        error("unexpected require: " .. tostring(name))
    end
    env.BookshelfWidget = {}
    assert(load(body, "handler", "t", env))()
    return env.BookshelfWidget, log
end

t.test("it opens KOReader's menu and then lets it have the event", function()
    local W, log = build()
    eq(W:onShowMenuSearch(), true, "the event is consumed")
    eq(log.opened, 1, "the file manager's menu is opened exactly once")
    eq(log.sent, 1, "and the search event is re-sent for it to handle")
end)

t.test("a menu that refuses to open does not loop forever", function()
    -- If onShowMenu puts nothing on the stack, our own re-sent event walks
    -- back down to this handler. Without the guard that is unbounded
    -- recursion; with it the second entry returns immediately and the event
    -- carries on down the stack to be dropped, which is the old behaviour.
    local W, log = build{ bounce = true }
    eq(W:onShowMenuSearch(), true, "the outer call still consumes the event")
    eq(log.opened, 1, "the menu is opened once, not once per bounce")
    eq(log.sent, 1, "and the event is re-sent once, not endlessly")
end)

t.test("the guard is released, so a second tap still works", function()
    -- A flag left set would make this fix work exactly once per session.
    local W, log = build()
    W:onShowMenuSearch()
    W:onShowMenuSearch()
    eq(log.opened, 2, "the second tap opens the menu too")
    eq(log.sent, 2, "and re-sends again")
end)

t.test("no file manager, or no menu on it, is survived quietly", function()
    local W1, log1 = build{ fm = false }
    eq(W1:onShowMenuSearch(), true, "still consumes rather than erroring")
    eq(log1.sent, 0, "and sends nothing it cannot be handled")

    local W2, log2 = build{ fm = { menu = {} } }
    eq(W2:onShowMenuSearch(), true, "a menu with no onShowMenu is survived")
    eq(log2.sent, 0, "and nothing is re-sent")
end)

t.done()
