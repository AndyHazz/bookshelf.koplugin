-- tests/_test_cover_progress.lua
-- Pure-Lua unit tests for bookshelf_cover_progress.decide(book).
-- Usage: cd into the plugin dir, then `lua tests/_test_cover_progress.lua`.

-- decide() is a pure function and should not require any KOReader modules
-- transitively. If a future change adds such a dep, stub it here.

package.path = "./?.lua;" .. package.path

-- Stub KOReader widget base and Geom so the module-level requires in
-- bookshelf_cover_progress.lua don't fail when run outside KOReader.
local function make_widget_base()
    local W = {}
    W.__index = W
    function W:extend(o)
        o = o or {}
        setmetatable(o, self)
        self.__index = self
        return o
    end
    function W:new(o)
        o = o or {}
        setmetatable(o, self)
        self.__index = self
        if self.init then self:init() end
        return o
    end
    function W:init() end
    return W
end
package.preload["ui/widget/widget"] = function() return make_widget_base() end
package.preload["ui/widget/textwidget"] = function()
    return { new = function(_, t) return t end }
end
package.preload["ui/font"] = function()
    return { getFace = function() return {} end }
end
package.preload["ui/geometry"] = function()
    return {
        new = function(_, t)
            return setmetatable(t or {}, { __index = {} })
        end,
    }
end

package.preload["ffi/blitbuffer"] = function()
    return {
        Color8       = function(n) return { _kind = "Color8", v = n } end,
        ColorRGB32   = function(r,g,b,a) return { _kind = "ColorRGB32", r=r, g=g, b=b, a=a } end,
        COLOR_WHITE  = { _kind = "Color8", v = 0xFF },
        COLOR_BLACK  = { _kind = "Color8", v = 0x00 },
    }
end
package.preload["ui/widget/overlapgroup"] = function()
    return { new = function(_, t) return t end }
end
package.preload["ui/widget/container/centercontainer"] = function()
    return { new = function(_, t) return t end }
end
package.preload["device"] = function()
    return { screen = { isColorEnabled = function() return false end } }
end

-- Per-element toggles: stub G_reader_settings so each can be set per test.
local _settings = {}
_G.G_reader_settings = {
    readSetting = function(_, key) return _settings[key] end,
    isTrue      = function(_, key) return _settings[key] == true end,
    isFalse     = function(_, key) return _settings[key] == false end,
}
local function setAll(v)
    _settings.bookshelf_progress_bar_enabled      = v
    _settings.bookshelf_progress_bookmark_enabled = v
    _settings.bookshelf_progress_badge_enabled    = v
end

local CP = require("bookshelf_cover_progress")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else   fail = fail + 1
           io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n")
    end
end
local function eq(a, e, msg)
    if a ~= e then
        error((msg or "") .. " expected=" .. tostring(e) .. " got=" .. tostring(a), 2)
    end
end

-- Helper to build a stub book.
local function book(status, pct)
    return { status = status, book_pct = pct }
end

-- All toggles off -------------------------------------------------------------

test("decide: all toggles OFF returns no indicators regardless of status", function()
    setAll(false)
    local r = CP.decide(book("reading", 0.5))
    eq(r.bar, false)
    eq(r.glyph, nil)
end)

-- Status: reading -------------------------------------------------------------

test("decide: reading with pct=0.5 shows bar at 0.5 and in_progress glyph", function()
    setAll(true)
    local r = CP.decide(book("reading", 0.5))
    eq(r.bar, true)
    eq(r.bar_pct, 0.5)
    eq(r.glyph, "in_progress")
end)

test("decide: reading with pct=nil hides bar but shows in_progress glyph", function()
    setAll(true)
    local r = CP.decide(book("reading", nil))
    eq(r.bar, false)
    eq(r.glyph, "in_progress")
end)

test("decide: reading with pct=1 still shows in_progress glyph (status wins)", function()
    setAll(true)
    local r = CP.decide(book("reading", 1.0))
    eq(r.bar, true)
    eq(r.bar_pct, 1.0)
    eq(r.glyph, "in_progress")
end)

-- Status: complete ------------------------------------------------------------

test("decide: complete hides bar regardless of pct, shows complete glyph", function()
    setAll(true)
    local r = CP.decide(book("complete", 0.42))
    eq(r.bar, false)
    eq(r.glyph, "complete")
end)

test("decide: complete with pct=1 hides bar (no redundant 100% bar)", function()
    setAll(true)
    local r = CP.decide(book("complete", 1.0))
    eq(r.bar, false)
    eq(r.glyph, "complete")
end)

-- Status: abandoned -----------------------------------------------------------

test("decide: abandoned looks like reading (bar + in_progress glyph)", function()
    setAll(true)
    local r = CP.decide(book("abandoned", 0.3))
    eq(r.bar, true)
    eq(r.bar_pct, 0.3)
    eq(r.glyph, "in_progress")
end)

-- Status: new / nil -----------------------------------------------------------

test("decide: status=new shows nothing", function()
    setAll(true)
    local r = CP.decide(book("new", nil))
    eq(r.bar, false)
    eq(r.glyph, nil)
end)

test("decide: nil status shows nothing", function()
    setAll(true)
    local r = CP.decide(book(nil, nil))
    eq(r.bar, false)
    eq(r.glyph, nil)
end)

test("decide: nil book shows nothing (defensive)", function()
    setAll(true)
    local r = CP.decide(nil)
    eq(r.bar, false)
    eq(r.glyph, nil)
end)

-- Default toggle (each defaults true when unset) ------------------------------

test("decide: toggles default to true when key absent", function()
    _settings.bookshelf_progress_bar_enabled      = nil
    _settings.bookshelf_progress_bookmark_enabled = nil
    _settings.bookshelf_progress_badge_enabled    = nil
    local r = CP.decide(book("reading", 0.5))
    eq(r.bar, true)
    eq(r.glyph, "in_progress")
end)

-- Per-element independence ----------------------------------------------------

test("decide: bar disabled alone -> still shows in-progress glyph", function()
    setAll(true)
    _settings.bookshelf_progress_bar_enabled = false
    local r = CP.decide(book("reading", 0.5))
    eq(r.bar, false)
    eq(r.glyph, "in_progress")
end)

test("decide: bookmark disabled alone -> still shows bar", function()
    setAll(true)
    _settings.bookshelf_progress_bookmark_enabled = false
    local r = CP.decide(book("reading", 0.5))
    eq(r.bar, true)
    eq(r.glyph, nil)
end)

test("decide: badge disabled alone -> complete book shows nothing", function()
    setAll(true)
    _settings.bookshelf_progress_badge_enabled = false
    local r = CP.decide(book("complete", 1.0))
    eq(r.bar, false)
    eq(r.glyph, nil)
end)

-- Report ---------------------------------------------------------------------

print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
