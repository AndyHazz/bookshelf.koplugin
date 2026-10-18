-- tests/_test_microfs_parked_forward.lua
-- #533: Action cards in the full-screen micro-modules view did nothing once a
-- book had been opened and closed. Closing a book parks the reader under the
-- shelf and KOReader has no FileManager then, but the view forwarded the
-- Dispatcher event its card sends (profile, quick menu, settings) to
-- FileManager.instance only, so the event was dropped. The shelf itself has
-- forwarded to the parked reader since hot parking landed; the view had an
-- older copy of that forward.
--
-- Usage: cd into the plugin dir, then `lua tests/_test_microfs_parked_forward.lua`

package.path = "./?.lua;./?/init.lua;" .. package.path

local function make_widget_base()
    local W = {}
    W.__index = W
    function W:extend(o) o = o or {}; setmetatable(o, self); self.__index = self; return o end
    function W:new(o)
        o = o or {}; setmetatable(o, self); self.__index = self
        if self.init then o:init() end
        return o
    end
    function W:init() end
    function W:getSize() return { w = 0, h = 0 } end
    function W:paintTo() end
    function W:handleEvent() return false end
    return W
end

for _, name in ipairs({
    "ui/widget/widget",
    "ui/widget/overlapgroup",
    "ui/widget/verticalgroup",
    "ui/widget/verticalspan",
    "ui/widget/container/framecontainer",
    "ui/widget/container/centercontainer",
    "ui/widget/container/widgetcontainer",
    "ui/widget/container/inputcontainer",
}) do
    package.preload[name] = function() return make_widget_base() end
end
package.preload["ui/geometry"] = function() return { new = function(_, t) return t or {} end } end
package.preload["ui/size"] = function()
    return { padding = { fullscreen = 10, default = 5 }, border = { default = 1 },
             line = { thin = 1, medium = 2, thick = 3 } }
end
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_WHITE = "white", COLOR_BLACK = "black",
             Color8 = function(n) return { v = n } end,
             gray = function(f) return { gray = f } end }
end
package.preload["device"] = function()
    return {
        screen = { getWidth = function() return 1264 end,
                   getHeight = function() return 1680 end,
                   scaleBySize = function(_, n) return n end },
        input = { group = { Back = "Back" } },
        hasKeys = function() return false end,
        hasDPad = function() return false end,
        isTouchDevice = function() return true end,
    }
end
package.preload["ui/uimanager"] = function()
    return { show = function() end, close = function() end, setDirty = function() end,
             nextTick = function(_, fn) fn() end }
end
package.preload["lib/bookshelf_settings_store"] = function()
    return { read = function(_k, d) return d end,
             microFullscreenButton = function() return true end }
end
package.preload["lib/bookshelf_hero_modules"] = function()
    return { build = function() return make_widget_base():new{} end,
             navMove = function() return nil end }
end
package.preload["lib/bookshelf_fullscreen_modules_model"] = function()
    return { load = function() return {} end }
end
package.preload["lib/bookshelf_hero_card"] = function()
    return { buildStatusRow = function() return nil end }
end
package.loaded["logger"] = package.loaded["logger"] or {
    dbg = function() end, info = function() end,
    warn = function() end, err = function() end }

-- The two hosts and the park state, switched per test.
local FM  = { instance = nil }
local RUI = { instance = nil }
local parked = false
package.loaded["apps/filemanager/filemanager"] = FM
package.loaded["apps/reader/readerui"] = RUI
package.loaded["lib/bookshelf_reader_park"] = {
    isParked = function() return parked end,
    finishToMenu = function() end,
}

local function host()
    local h = { got = {} }
    function h:handleEvent(ev) self.got[#self.got + 1] = ev.handler; return true end
    return h
end

local MicroFS = require("lib/bookshelf_micro_fullscreen")
local t = dofile("tests/_helpers.lua").runner()

-- The overlay instance without running init (no grid needed to forward).
local view = setmetatable({}, { __index = MicroFS })

t.test("a card's Dispatcher event reaches the parked reader when there is no FileManager", function()
    FM.instance, RUI.instance, parked = nil, host(), true
    local consumed = view:handleEvent({ handler = "onProfileExecute", args = { "Night" } })
    assert(RUI.instance.got[1] == "onProfileExecute",
        "the event never reached the parked reader")
    assert(consumed, "the forward should report the reader consumed it")
end)

t.test("with a FileManager the event still goes to it", function()
    FM.instance, RUI.instance, parked = host(), host(), false
    view:handleEvent({ handler = "onShowQuickMenu", args = {} })
    assert(FM.instance.got[1] == "onShowQuickMenu", "FileManager no longer gets the event")
    assert(#RUI.instance.got == 0, "a reader that is not parked must not get it")
end)

t.test("lifecycle events are never forwarded to the parked reader", function()
    FM.instance, RUI.instance, parked = nil, host(), true
    view:handleEvent({ handler = "onCloseWidget", args = {} })
    view:handleEvent({ handler = "onClose", args = {} })
    assert(#RUI.instance.got == 0,
        "forwarding onClose would close the parked book: " .. table.concat(RUI.instance.got, ","))
end)

t.test("the forward neutralises the reader's onClose (the #225 guard)", function()
    FM.instance, parked = nil, true
    local r = host()
    local closed = false
    function r.onClose() closed = true end
    function r:handleEvent(_ev) self:onClose(); return true end
    RUI.instance = r
    view:handleEvent({ handler = "onSwipe", args = { { ges = "swipe" } } })
    assert(not closed, "an incidental forward closed the parked book")
end)

t.done()
