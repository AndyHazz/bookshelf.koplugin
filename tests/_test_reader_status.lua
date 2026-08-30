-- tests/_test_reader_status.lua
--
-- The in-reader status strip's REFRESH GATE.
--
-- The strip is a ReaderView view module, so it only repaints when ReaderView
-- repaints. Nothing about changing the frontlight does that, so the line sat on
-- its last-painted pixels until the next page turn while bookends' equivalent
-- token updated immediately. The shelf has always handled this
-- (BookshelfWidget:onFrontlightStateChanged invalidates the device-state cache
-- and asks for a repaint) but there is no BookshelfWidget in the reader, so
-- none of that ever ran there.
--
-- What is testable off-device is the gate: only ask for a repaint when the
-- line actually names a token the event changed. Reported on a PW5, 2026-08-30.
--
-- Usage (from plugin root): lua tests/_test_reader_status.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

-- ── KOReader seams the module touches at load ──────────────────────────────
package.loaded["device"] = {
    screen = {
        getWidth  = function() return 1248 end,
        getHeight = function() return 1648 end,
    },
}
package.loaded["ui/geometry"] = {
    new = function(_self, o) return o or {} end,
}
package.loaded["ui/size"] = { padding = { fullscreen = 15 } }
package.loaded["ui/widget/widget"] = {
    extend = function(_self, o)
        o = o or {}
        o.extend = function(s, t) t = t or {}; setmetatable(t, { __index = s }); return t end
        o.new    = function(s, t) t = t or {}; setmetatable(t, { __index = s }); return t end
        return o
    end,
}
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }

local STORE = {}
_G.G_reader_settings = {
    readSetting = function(_self, k) return STORE[k] end,
    saveSetting = function(_self, k, v) STORE[k] = v end,
    flush       = function() end,
    isTrue      = function(_self, k) return STORE[k] == true end,
}

local StatusLine   = require("lib/status_line")
local Regions      = require("lib/bookshelf_hero_regions")
local ReaderStatus = require("lib/bookshelf_reader_status")

local t = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq

-- Put a template on the status region and turn the strip on.
local function configure(template, opts)
    opts = opts or {}
    STORE[StatusLine.SHOW_IN_READER_KEY] = (opts.on ~= false)
    local entry = { template = template }
    if opts.disabled then entry.disabled = true end
    STORE[StatusLine.SETTINGS_KEY] = { status = entry }
    Regions.invalidateCache()
end

local FRONTLIGHT = { "light", "light_icon", "warmth" }
local BATTERY    = { "batt", "batt_icon" }

t.test("a line naming a frontlight token asks for the repaint", function()
    configure("%light_icon%light_pct")
    eq(ReaderStatus.usesTokens(FRONTLIGHT), true)
end)

t.test("a line naming none of them does not", function()
    configure("%time_12h  %disk")
    eq(ReaderStatus.usesTokens(FRONTLIGHT), false)
    eq(ReaderStatus.usesTokens(BATTERY), false)
end)

t.test("the shipped default line does use the frontlight tokens", function()
    -- It is "[if:light]  %light_icon%light_pct[/if]", so brightness changes
    -- must reach it out of the box. This is the case the bug was reported on.
    STORE[StatusLine.SHOW_IN_READER_KEY] = true
    STORE[StatusLine.SETTINGS_KEY] = nil
    Regions.invalidateCache()
    eq(ReaderStatus.usesTokens(FRONTLIGHT), true)
    eq(ReaderStatus.usesTokens(BATTERY), true)
end)

t.test("token names match on a boundary, not as a prefix", function()
    -- "%lightning" is not "%light". The shelf's _anyActiveRegionUses has this
    -- rule; the strip must not disagree with it.
    configure("%lightning")
    eq(ReaderStatus.usesTokens(FRONTLIGHT), false)
    configure("%light")
    eq(ReaderStatus.usesTokens(FRONTLIGHT), true, "a token at end-of-string counts")
end)

t.test("the switch being off means no repaint is ever requested", function()
    configure("%light_icon", { on = false })
    eq(ReaderStatus.usesTokens(FRONTLIGHT), false)
end)

t.test("a disabled status region means no repaint either", function()
    -- Nothing is drawn, so nothing needs refreshing.
    configure("%light_icon", { disabled = true })
    eq(ReaderStatus.usesTokens(FRONTLIGHT), false)
end)

t.test("a malformed token list is tolerated", function()
    configure("%light_icon")
    eq(ReaderStatus.usesTokens(nil), false)
    eq(ReaderStatus.usesTokens({}), false)
end)

t.done()
