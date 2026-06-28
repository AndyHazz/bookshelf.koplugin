-- tests/_test_tall_screen.lua
-- Pure-Lua tests for tall-screen row-count helpers in bookshelf_widget.lua.
-- Usage (from plugin root): lua tests/_test_tall_screen.lua

-- After the lib/ reorg, internal requires resolve as "lib/bookshelf_X".
package.path = "./?.lua;./?/init.lua;" .. package.path

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
package.loaded["ui/widget/overlapgroup"]              = make_widget_class()
package.loaded["ui/widget/verticalgroup"]             = make_widget_class()
package.loaded["ui/widget/horizontalgroup"]            = make_widget_class()
package.loaded["ui/widget/textwidget"]                = make_widget_class()
package.loaded["ui/widget/textboxwidget"]             = make_widget_class()
package.loaded["ui/widget/verticalspan"]              = make_widget_class()
package.loaded["ui/geometry"]    = { new = function(_, t) return t or {} end }
package.loaded["ui/gesturerange"] = { new = function(_, t) return t or {} end }
-- Size.item.height_default is used by _layoutPrimitives() for the chip-bar
-- height. Use scaleBySize-style raw values (the test scaleBySize is identity).
package.loaded["ui/size"]        = {
    padding = { default = 4, large = 8, fullscreen = 16 },
    item    = { height_default = 30 },
    border  = { thin = 1 },
    line    = { medium = 1 },
}
package.loaded["ui/font"]        = { getFace = function() return {} end }
package.loaded["ui/uimanager"]   = { setDirty = function() end, close = function() end,
                                     show = function() end, nextTick = function(_, fn) end }
package.loaded["ffi/blitbuffer"] = { COLOR_BLACK = 0, COLOR_WHITE = 0xFF,
                                     gray = function(v) return v end }
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
-- BookshelfSettings stub: returns nil for every read (defaults apply).
package.loaded["lib/bookshelf_settings_store"] = {
    read   = function(_, default) return default end,
    save   = function() end,
    delete = function() end,
    flush  = function() end,
    isTrue = function() return false end,
    nilOrTrue = function() return true end,
}
package.loaded["lib/bookshelf_i18n"]         = { gettext  = function(t) return t end,
                                                  ngettext = function(s, p, n) return n == 1 and s or p end }
package.loaded["lib/bookshelf_book_repository"] = {}
package.loaded["lib/bookshelf_hero_card"]       = {
    new = function() return {} end,
    buildStatusRow = function() return nil end,
}
package.loaded["lib/bookshelf_chip_bar"]        = { new = function() return {} end }
package.loaded["lib/bookshelf_fonts"]           = {
    getFace = function(_, family, size, opts)
        return { family = family, size = size }, opts and opts.bold or false
    end,
}
package.loaded["lib/bookshelf_shelf_row"]       = {}
package.loaded["lib/bookshelf_spine_widget"]    = {}

_G.G_reader_settings = {
    readSetting = function() return nil end,
    saveSetting = function() end,
    isTrue      = function() return false end,
    flush       = function() end,
}

-- The widget dofile()'d below pulls in ~15 lib/bookshelf_* modules at load,
-- which transitively require many KOReader-bundled modules (libs/libkoreader-lfs,
-- ffi/utf8proc, etc.) that don't exist in plain lua. The explicit stubs above
-- cover the ones whose VALUES are read at load time (e.g. ui/size numbers); for
-- everything else, fall back to a benign mock so the requires succeed. The
-- row-count helpers under test never call into these, so the mock is inert.
-- package.loaded (the explicit stubs) and on-disk lib/* files both resolve
-- before this fallback, so it only catches unstubbed KOReader core deps.
local function mock()
    local m = {}
    return setmetatable(m, {
        __index = function() return function() return mock() end end,
        __call  = function() return mock() end,
    })
end
table.insert(package.searchers, function(_name)
    return function() return mock() end
end)

local BW = dofile("lib/bookshelf_widget.lua")

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
local function bw(width, height, expanded, simpleui_reserved)
    return setmetatable(
        {
            width = width,
            height = height,
            _expanded = expanded or false,
            _simpleui_bar_ctx = simpleui_reserved and { total_h = simpleui_reserved } or nil,
        },
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

test("_nShelves: SimpleUI normal keeps two visible rows", function()
    eq(bw(750, 1024, false, 160):_nShelves(), 2)
end)

test("_nShelves: SimpleUI expanded keeps three visible rows", function()
    eq(bw(750, 1024, true, 160):_nShelves(), 3)
end)

-- NOTE: these row/column expectations track the shipped responsive layout
-- (cover-size-driven columns, default medium = 4, independent of screen aspect;
-- _baseShelves fits rows under a regular hero; expanded fills to _maxRows).
-- They were recalibrated to the current widget after the test was restored to a
-- runnable state (it had been failing to load, so the old pre-rework numbers
-- went unverified for some time). _isTallScreen above is unchanged.
test("_nShelves: tall normal (Pixel 6 1080x2400) = 4", function()
    eq(bw(1080, 2400, false):_nShelves(), 4)
end)

test("_nShelves: tall expanded = 5 (expanded fills to _maxRows)", function()
    eq(bw(1080, 2400, true):_nShelves(), 5)
end)

test("_nShelves: phone-tall normal (Boox Palma 824x1648) = 3", function()
    eq(bw(824, 1648, false):_nShelves(), 3)
end)

test("_nShelves: phone-tall expanded (Boox Palma 824x1648) = 5", function()
    eq(bw(824, 1648, true):_nShelves(), 5)
end)

-- ── _nCols tests ───────────────────────────────────────────────────────────
test("_nCols: standard screen = 4", function()
    eq(bw(750, 1024):_nCols(), 4)
end)

test("_nCols: tall screen = 4 (portrait cols are aspect-independent)", function()
    -- Portrait column count comes from the cover-size default (medium = 4); the
    -- pre-rework model that reduced columns on tall screens is gone.
    eq(bw(1080, 2400):_nCols(), 4)
end)

-- ── _pageSize tests ──────────────────────────────────────────────────────────
-- _pageSize == _viewSize == _nShelves * _nCols in portrait, so it now varies
-- with expand state (it returns a fixed 5 only in landscape).
test("_pageSize: standard screen (750x1024) = 8 normal / 12 expanded", function()
    eq(bw(750, 1024, false):_pageSize(), 8)
    eq(bw(750, 1024, true):_pageSize(),  12)
end)

test("_pageSize: SimpleUI screen tracks restored visible rows", function()
    eq(bw(750, 1024, false, 160):_pageSize(), 8)
    eq(bw(750, 1024, true, 160):_pageSize(),  12)
end)

test("_pageSize: tall PW-aspect (1080x2400) = 16 normal / 20 expanded", function()
    eq(bw(1080, 2400, false):_pageSize(), 16)
    eq(bw(1080, 2400, true):_pageSize(),  20)
end)

test("_pageSize: phone-tall (Palma 824x1648) = 12 normal / 20 expanded", function()
    eq(bw(824, 1648, false):_pageSize(), 12)
    eq(bw(824, 1648, true):_pageSize(),  20)
end)

-- ── _viewSize tests ────────────────────────────────────────────────────────
test("_viewSize: standard normal = 8", function()
    eq(bw(750, 1024, false):_viewSize(), 8)
end)

test("_viewSize: standard expanded = 12", function()
    eq(bw(750, 1024, true):_viewSize(), 12)
end)

test("_viewSize: tall PW-aspect normal = 16 (4 shelves * 4 cols)", function()
    eq(bw(1080, 2400, false):_viewSize(), 16)
end)

test("_viewSize: tall PW-aspect expanded = 20 (5 shelves * 4 cols)", function()
    eq(bw(1080, 2400, true):_viewSize(), 20)
end)

test("_viewSize: phone-tall normal (Palma) = 12 (3 shelves * 4 cols)", function()
    eq(bw(824, 1648, false):_viewSize(), 12)
end)

test("_viewSize: phone-tall expanded (Palma) = 20 (5 shelves * 4 cols)", function()
    eq(bw(824, 1648, true):_viewSize(), 20)
end)

-- ── Report ─────────────────────────────────────────────────────────────────
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
