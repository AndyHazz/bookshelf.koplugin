-- tests/_test_tall_screen.lua
-- Pure-Lua tests for tall-screen row-count helpers in bookshelf_widget.lua.
-- Usage (from plugin root): lua tests/_test_tall_screen.lua

-- ── Minimal class system ───────────────────────────────────────────────────
local function make_widget_class()
    local cls = {}
    cls.__index = cls
    function cls:extend(props)
        local sub = props or {}
        sub.__index = sub
        setmetatable(sub, { __index = cls })
        return sub
    end
    return cls
end

-- ── KOReader stubs ─────────────────────────────────────────────────────────
local widget_cls = make_widget_class()
package.loaded["ui/widget/container/inputcontainer"] = widget_cls
package.loaded["ui/widget/container/framecontainer"] = make_widget_class()
package.loaded["ui/widget/container/centercontainer"] = make_widget_class()
package.loaded["ui/widget/verticalgroup"]             = make_widget_class()
package.loaded["ui/widget/horizontalgroup"]            = make_widget_class()
package.loaded["ui/widget/textwidget"]                = make_widget_class()
package.loaded["ui/widget/textboxwidget"]             = make_widget_class()
package.loaded["ui/widget/verticalspan"]              = make_widget_class()
package.loaded["ui/geometry"]    = { new = function(_, t) return t or {} end }
package.loaded["ui/gesturerange"] = { new = function(_, t) return t or {} end }
package.loaded["ui/size"]        = { padding = { default = 4, large = 8, fullscreen = 16 } }
package.loaded["ui/font"]        = { getFace = function() return {} end }
package.loaded["ui/uimanager"]   = { setDirty = function() end, close = function() end,
                                     show = function() end, nextTick = function(_, fn) end }
package.loaded["ffi/blitbuffer"] = { COLOR_BLACK = 0 }
package.loaded["device"]         = {
    screen = {
        getWidth    = function() return 600 end,
        getHeight   = function() return 800 end,
        scaleBySize = function(_, n) return n end,
    },
    isKindle = function() return false end,
}
package.loaded["logger"]          = { dbg  = function() end, warn = function() end,
                                      err  = function() end, info = function() end }
package.loaded["bookshelf_i18n"]  = { gettext  = function(t) return t end,
                                      ngettext = function(s, p, n) return n == 1 and s or p end }
package.loaded["bookshelf_book_repository"] = {}
package.loaded["bookshelf_hero_card"]       = {}
package.loaded["bookshelf_chip_strip"]      = { new = function() return {} end }
package.loaded["bookshelf_shelf_row"]       = {}

_G.G_reader_settings = {
    readSetting = function() return nil end,
    saveSetting = function() end,
    isTrue      = function() return false end,
    flush       = function() end,
}

local BW = dofile("bookshelf_widget.lua")

-- ── Test harness ───────────────────────────────────────────────────────────
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

-- ── Helper to build a minimal mock BookshelfWidget ─────────────────────────
local function bw(width, height, expanded)
    return setmetatable(
        { width = width, height = height, _expanded = expanded or false },
        { __index = BW }
    )
end

-- ── _isTallScreen tests ────────────────────────────────────────────────────
test("_isTallScreen: Kindle Paperwhite (750x1024) is NOT tall", function()
    eq(bw(750, 1024):_isTallScreen(), false)
end)

test("_isTallScreen: Kindle Scribe (1404x1872) is NOT tall", function()
    eq(bw(1404, 1872):_isTallScreen(), false)
end)

test("_isTallScreen: Pixel 6 (1080x2400) IS tall", function()
    eq(bw(1080, 2400):_isTallScreen(), true)
end)

test("_isTallScreen: 16:9 phone (1080x1920) IS tall", function()
    eq(bw(1080, 1920):_isTallScreen(), true)
end)

test("_isTallScreen: exact threshold (650x1000 = 0.65) is NOT tall", function()
    -- strict less-than: ratio == 0.65 is not tall
    eq(bw(650, 1000):_isTallScreen(), false)
end)

-- ── _nShelves tests ────────────────────────────────────────────────────────
test("_nShelves: standard normal = 2", function()
    eq(bw(750, 1024, false):_nShelves(), 2)
end)

test("_nShelves: standard expanded = 3", function()
    eq(bw(750, 1024, true):_nShelves(), 3)
end)

test("_nShelves: tall normal = 3", function()
    eq(bw(1080, 2400, false):_nShelves(), 3)
end)

test("_nShelves: tall expanded = 4", function()
    eq(bw(1080, 2400, true):_nShelves(), 4)
end)

-- ── _nCols tests ───────────────────────────────────────────────────────────
test("_nCols: standard screen = 4", function()
    eq(bw(750, 1024):_nCols(), 4)
end)

test("_nCols: tall screen = 3", function()
    eq(bw(1080, 2400):_nCols(), 3)
end)

-- ── _pageSize tests ────────────────────────────────────────────────────────
test("_pageSize: standard screen = 8 (regardless of expanded)", function()
    eq(bw(750, 1024, false):_pageSize(), 8)
    eq(bw(750, 1024, true):_pageSize(),  8)
end)

test("_pageSize: tall screen = 9 (regardless of expanded)", function()
    eq(bw(1080, 2400, false):_pageSize(), 9)
    eq(bw(1080, 2400, true):_pageSize(),  9)
end)

-- ── _viewSize tests ────────────────────────────────────────────────────────
test("_viewSize: standard normal = 8", function()
    eq(bw(750, 1024, false):_viewSize(), 8)
end)

test("_viewSize: standard expanded = 12", function()
    eq(bw(750, 1024, true):_viewSize(), 12)
end)

test("_viewSize: tall normal = 9", function()
    eq(bw(1080, 2400, false):_viewSize(), 9)
end)

test("_viewSize: tall expanded = 12", function()
    eq(bw(1080, 2400, true):_viewSize(), 12)
end)

-- ── Report ─────────────────────────────────────────────────────────────────
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
