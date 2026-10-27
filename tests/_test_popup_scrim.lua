-- tests/_test_popup_scrim.lua
-- A picker opened over another popup fades what is under it (popup kit's
-- scrim), so the two read as layers. The scrim must sit just BELOW the popup
-- in the window stack: painted after what it fades and before the popup, and
-- left alone when only the popup repaints, so nothing is faded twice.
--
-- Usage (from plugin root): lua tests/_test_popup_scrim.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local kit = io.open("lib/bookshelf_popup_kit.lua"):read("*a")
local function fn(name)
    local body = kit:match("\nfunction Kit%." .. name .. "%(popup%)\n(.-)\nend\n")
    assert(body, "Kit." .. name .. " is gone")
    return body
end

local dirty, closed = {}, {}
local UI = { _window_stack = {},
    setDirty = function(_s, w, kind, region) dirty[#dirty + 1] = { w = w, kind = kind, region = region } end,
    close = function(self, w)
        closed[#closed + 1] = w
        for i, win in ipairs(self._window_stack) do
            if win.widget == w then table.remove(self._window_stack, i); break end
        end
    end }
package.loaded["ui/uimanager"] = UI
package.loaded["device"] = { screen = { getWidth = function() return 600 end,
                                        getHeight = function() return 800 end } }
local Scrim = { new = function(_s, o) o.is_scrim = true; return o end }
local Geom = { new = function(_s, o) return o end }
local function load_fn(name)
    return assert(load("local Scrim, Geom = ...; return function(popup)\n" .. fn(name) .. "\nend"))(Scrim, Geom)
end
local scrimUnder, dropScrim = load_fn("scrimUnder"), load_fn("dropScrim")

t.test("the scrim goes just under the popup and is the one thing marked to paint", function()
    local editor, popup = { name = "editor" }, { name = "popup" }
    UI._window_stack = { { widget = { name = "shelf" } }, { widget = editor }, { widget = popup } }
    dirty = {}
    scrimUnder(popup)
    eq(#UI._window_stack, 4)
    assert(UI._window_stack[3].widget.is_scrim, "the scrim is not just under the popup")
    eq(UI._window_stack[4].widget, popup)
    eq(#dirty, 1); assert(dirty[1].w.is_scrim)
    eq(dirty[1].region.w, 600); eq(dirty[1].region.h, 800)
end)

t.test("it goes when the popup does", function()
    local popup = { name = "popup" }
    UI._window_stack = { { widget = { name = "editor" } }, { widget = popup } }
    scrimUnder(popup)
    local scrim = popup._scrim
    dropScrim(popup)
    eq(closed[#closed], scrim); eq(popup._scrim, nil); eq(#UI._window_stack, 2)
    dropScrim(popup)   -- twice is harmless
end)

t.test("the picker fades what is under it while it is up", function()
    local lm = io.open("lib/bookshelf_library_modal.lua"):read("*a")
    assert(lm:find("function LibraryModal:onShow()\n    require(\"lib/bookshelf_popup_kit\").scrimUnder(self)", 1, true))
    assert(lm:find("function LibraryModal:onCloseWidget()\n    if self._scrim then require(\"lib/bookshelf_popup_kit\").dropScrim(self) end", 1, true))
end)

t.done()
