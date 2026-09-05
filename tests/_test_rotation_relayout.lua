-- tests/_test_rotation_relayout.lua
-- Rotating from a start-menu system action has to relayout the open shelf.
--
-- The shelf is a TOP-LEVEL widget on the UIManager stack, not a child of the
-- `ui` (FileManager / ReaderUI) the plugin hangs off. KOReader's DeviceListener
-- dispatches rotation with `self.ui:handleEvent(Event:new("SetRotationMode"))`,
-- which walks only that tree -- so the shelf never hears it and stays laid out
-- for the old geometry. Reproduced on a PW5 through the real path (start menu
-- closes, then bookshelf_action_exec dispatches toggle_rotation): Screen
-- reported 1648x1236 while the framebuffer still held the portrait layout, and
-- it stayed that way until something was tapped.
--
-- SOURCE-SHAPE, deliberately: driving this needs a UIManager window stack, a
-- FileManager and a live shelf, and the emulator CANNOT reproduce the bug at
-- all -- on desktop an orientation change also arrives as a broadcast
-- ScreenResize, which the widget already handles, so it relaid out correctly
-- there with the fix reverted. Only the device shows it, so what is pinned
-- here is the wiring the device proved necessary.
package.path = "./?.lua;./?/init.lua;" .. package.path

local t = dofile("tests/_helpers.lua").runner()
local main = io.open("main.lua"):read("*a")

t.test("both geometry events relayout the open shelf", function()
    for _, ev in ipairs({ "onSetRotationMode", "onScreenResize" }) do
        local body = main:match("\nfunction Bookshelf:" .. ev .. "%(%)\n(.-)\nend\n")
        assert(body, "Bookshelf:" .. ev .. " is gone or was renamed")
        assert(body:match("_relayoutLiveShelf"),
            ev .. " must relayout the shelf; the event never reaches it on its own")
    end
end)

t.test("the relayout goes through the widget's resize path, not its rotation one", function()
    local body = main:match("\nfunction Bookshelf:_relayoutLiveShelf%(%)\n(.-)\nend\n")
    assert(body, "Bookshelf:_relayoutLiveShelf is gone or was renamed")
    -- onSetRotationMode compares the MODE, and by the time this runs `ui` has
    -- already applied it, so the widget would find them equal and do nothing.
    -- onScreenResize compares geometry, which really has changed.
    assert(body:match("bw:onScreenResize%(%)"),
        "must call the widget's onScreenResize")
    assert(not body:match("bw:onSetRotationMode"),
        "onSetRotationMode would compare against the already-applied mode and bail")
end)

t.test("it only touches a shelf that is actually on screen", function()
    local body = main:match("\nfunction Bookshelf:_relayoutLiveShelf%(%)\n(.-)\nend\n")
    assert(body:match("_live_widget"),
        "must use the canonical live widget, not a per-instance handle")
    assert(body:match("UIManager:isWidgetShown"),
        "a rotation in the reader, with no shelf up, must not rebuild one")
    assert(body:match("pcall"),
        "a relayout failure must not take the rotation down with it")
end)

t.done()
