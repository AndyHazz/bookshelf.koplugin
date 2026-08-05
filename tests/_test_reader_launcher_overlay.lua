-- tests/_test_reader_launcher_overlay.lua
-- The in-reader launcher glyphs must not move or resize when the full-screen
-- micro-module overlay opens over them.
--
-- The overlay paints an opaque white background over the whole reader, so it has
-- to REPAINT the launcher glyphs itself -- a second painter for geometry that
-- bookshelf_reader_buttons owns. It used to rebuild them from the padded tap rect
-- plus a hardcoded unscaled 32dp art box, which agrees with the real launcher
-- only while every positioning knob is at its default. Move the buttons to the
-- top (or scale them) and the glyphs visibly jumped as the grid opened.
--
-- These tests capture what the launcher's own paintTo draws (via a recording
-- blitbuffer) and assert the overlay's glyph boxes land on exactly that, plus
-- that the grid area runs to the far edge with no dead strip.
--
-- Usage: cd into the plugin dir, then `lua tests/_test_reader_launcher_overlay.lua`

package.path = "./?.lua;./?/init.lua;" .. package.path

local SW, SH = 1264, 1680

-- ── KOReader stubs ────────────────────────────────────────────────────────────
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

package.preload["ui/geometry"] = function()
    local G = {}
    function G:new(t)
        t = t or {}
        function t:copy() return { x = self.x, y = self.y, w = self.w, h = self.h,
                                   copy = self.copy } end
        return t
    end
    return G
end
package.preload["ui/size"] = function()
    return { padding = { fullscreen = 10, default = 5 }, border = { default = 1 } }
end
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_WHITE = "white", COLOR_BLACK = "black",
             Color8 = function(n) return { v = n } end }
end
package.preload["device"] = function()
    return {
        screen = {
            getWidth    = function() return SW end,
            getHeight   = function() return SH end,
            scaleBySize = function(_, n) return n end,   -- 1dp == 1px: readable maths
        },
        input = { group = { Back = "Back" } },
        hasKeys    = function() return false end,
        hasDPad    = function() return false end,
        isTouchDevice = function() return true end,
    }
end
package.preload["ui/uimanager"] = function()
    return { show = function() end, close = function() end, setDirty = function() end,
             nextTick = function(_, fn) fn() end }
end

-- Settings the launcher reads. Mutable per test.
local settings = {}
package.preload["lib/bookshelf_settings_store"] = function()
    return {
        read = function(k, d) local v = settings[k]; if v == nil then return d end; return v end,
        microFullscreenButton = function() return settings._micro_fs_button ~= false end,
    }
end

-- The overlay's grid renderer + model: only need to load, and to record the
-- geometry the overlay asks the grid to fill (that's the "no dead strip" check).
local build_args
package.preload["lib/bookshelf_hero_modules"] = function()
    return {
        build = function(_bw, content_w, grid_h, pad, opts)
            local w = make_widget_base():new{ _is_grid = true }
            build_args = { content_w = content_w, grid_h = grid_h, pad = pad,
                           opts = opts, widget = w }
            return w
        end,
        navMove = function() return nil end,
    }
end
package.preload["lib/bookshelf_fullscreen_modules_model"] = function()
    return { load = function() return {} end }
end
package.preload["lib/bookshelf_hero_card"] = function()
    return { buildStatusRow = function() return nil end }   -- no status row in reader
end

local FooterGeom    = require("lib/bookshelf_footer_geom")
local ReaderButtons = require("lib/bookshelf_reader_buttons")
local MicroFS       = require("lib/bookshelf_micro_fullscreen")
local t             = dofile("tests/_helpers.lua").runner()

-- ── helpers ───────────────────────────────────────────────────────────────────
-- Record every rect the launcher's own paintTo draws, so the tests compare
-- against real painted output rather than a re-derivation of the same maths.
local function recordLauncherPaint()
    local rects = {}
    local bb = { paintRect = function(_, x, y, w, h)
        rects[#rects + 1] = { x = x, y = y, w = w, h = h }
    end }
    local side = ReaderButtons.side()
    local grid_side = (side == "left") and "right" or "left"
    local lw = ReaderButtons:new{ side = side, grid_side = grid_side,
        show_hamburger = ReaderButtons.showMenu(),
        show_grid      = ReaderButtons.showModules() }
    -- Paint the two glyphs separately so each union is unambiguous.
    lw.show_grid = false
    lw:paintTo(bb, 0, 0)
    local bars = rects; rects = {}
    lw.show_hamburger, lw.show_grid = false, ReaderButtons.showModules()
    lw:paintTo(bb, 0, 0)
    return bars, rects
end

local function union(rects)
    if #rects == 0 then return nil end
    local x1, y1, x2, y2 = math.huge, math.huge, -math.huge, -math.huge
    for _, r in ipairs(rects) do
        x1 = math.min(x1, r.x);         y1 = math.min(y1, r.y)
        x2 = math.max(x2, r.x + r.w);   y2 = math.max(y2, r.y + r.h)
    end
    return { x = x1, y = y1, w = x2 - x1, h = y2 - y1 }
end

local function sameBox(a, b, what)
    assert(a and b, (what or "box") .. ": one side is missing")
    assert(a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h,
        string.format("%s: got %d,%d %dx%d  want %d,%d %dx%d",
            what or "box", a.x, a.y, a.w, a.h, b.x, b.y, b.w, b.h))
end

-- The reader's `bw` shim, as main.lua builds it.
local function readerShim()
    local side = ReaderButtons.side()
    local grid_side = (side == "left") and "right" or "left"
    return {
        FOOTER_HIT_EXTENSION = FooterGeom.hitExtension(),
        FOOTER_STROKE_W      = FooterGeom.barMetrics().bar_t,
        _hero_cells          = {},
        _reader_context      = true,
        _micromod_dimen      = ReaderButtons.gridOverlayRect(grid_side),
        _burger_dimen        = ReaderButtons.overlayRect(side),
        _startMenuPosition   = function()
            if not ReaderButtons.showMenu() then return "off" end
            return ReaderButtons.side()
        end,
    }
end

-- Pull the overlay's positioned children out of its OverlapGroup: the glyphs are
-- OffsetContainers, identified by the x_off/y_off they were built with.
local function overlayOffsets(ov)
    local out = {}
    for _, child in ipairs(ov[1] or {}) do
        if type(child) == "table" and child.x_off ~= nil then
            out[#out + 1] = { x = child.x_off, y = child.y_off }
        end
    end
    return out
end
local function offsetPresent(offs, box)
    for _, o in ipairs(offs) do
        if o.x == box.x and o.y == box.y then return true end
    end
    return false
end

-- Where the grid actually ENDED UP, read out of the built tree rather than
-- re-derived: its column is offset by y_off, then pushed down by any spacers
-- ahead of it (that spacer is what MOVES the grid clear of a top-anchored
-- launcher -- shortening grid_h alone would leave it under the buttons).
local function gridLayout(ov)
    assert(build_args and build_args.widget, "no grid was built")
    for _, child in ipairs(ov[1] or {}) do
        local col = type(child) == "table" and child.x_off ~= nil and child[1] or nil
        if type(col) == "table" then
            local y, found = child.y_off, false
            for _, item in ipairs(col) do
                if item == build_args.widget then found = true; break end
                if type(item) == "table" and item.width then y = y + item.width end
            end
            if found then return { top = y, h = build_args.grid_h } end
        end
    end
    error("could not locate the grid in the overlay's tree")
end

local function reset(over)
    settings = { reader_menu_button = true, reader_modules_button = true }
    for k, v in pairs(over or {}) do settings[k] = v end
    build_args = nil
end

local MARGIN = math.min(math.floor(10 * 2 * 0.8), math.floor(SW * 0.03))

-- ── the launcher's own paint matches its published paint spec ─────────────────
t.test("paintSpec describes exactly what the launcher paints (defaults)", function()
    reset()
    local bars, grid = recordLauncherPaint()
    local spec = ReaderButtons.paintSpec()
    sameBox(union(bars), { x = spec.bars.x, y = spec.bars.y,
                           w = spec.bars.w, h = spec.bars.h }, "bars")
    sameBox(union(grid), { x = spec.grid.x, y = spec.grid.y,
                           w = spec.grid.w, h = spec.grid.h }, "grid")
end)

t.test("paintSpec tracks every positioning knob (top, scale, lift, offset)", function()
    reset({ reader_launcher_top = true, reader_launcher_scale = 70,
            reader_launcher_lift = 20, reader_launcher_offset_x = 15 })
    local bars, grid = recordLauncherPaint()
    local spec = ReaderButtons.paintSpec()
    sameBox(union(bars), { x = spec.bars.x, y = spec.bars.y,
                           w = spec.bars.w, h = spec.bars.h }, "bars (adjusted)")
    sameBox(union(grid), { x = spec.grid.x, y = spec.grid.y,
                           w = spec.grid.w, h = spec.grid.h }, "grid (adjusted)")
    assert(spec.bars.h < FooterGeom.barMetrics().span,
        "a 70% launcher must report a shorter bar span than the unscaled footer")
    assert(spec.bars.y < math.floor(SH / 2), "top-anchored bars belong in the top half")
end)

t.test("a hidden button publishes no paint box (overlay keeps its fallback)", function()
    reset({ reader_modules_button = false })
    local spec = ReaderButtons.paintSpec()
    assert(spec.bars, "menu button is on, so its box must be published")
    assert(spec.grid == nil, "hidden modules button must not publish a paint box")
end)

-- ── the overlay repaints them in place ───────────────────────────────────────
t.test("overlay glyphs land on the launcher's painted boxes (adjusted launcher)", function()
    reset({ reader_launcher_top = true, reader_launcher_scale = 70,
            reader_launcher_lift = 20, reader_launcher_offset_x = 15 })
    local bars, grid = recordLauncherPaint()
    local shim = readerShim()
    local ov = MicroFS.open(shim, shim._micromod_dimen, 40)
    local offs = overlayOffsets(ov)
    local bars_box, grid_box = union(bars), union(grid)
    assert(offsetPresent(offs, bars_box), string.format(
        "hamburger must be repainted at %d,%d (the launcher's own position)",
        bars_box.x, bars_box.y))
    assert(offsetPresent(offs, grid_box), string.format(
        "close-X must replace the grid glyph at %d,%d", grid_box.x, grid_box.y))
    -- Guard the specific regression: the tap rect is padded, so centring the
    -- glyphs in it (what the overlay used to do) lands somewhere else entirely.
    local tap = ReaderButtons.tapRect(ReaderButtons.side())
    assert(tap.y ~= bars_box.y,
        "precondition: the padded tap rect must NOT coincide with the glyph box")
end)

t.test("overlay glyphs follow a right-side launcher", function()
    reset({ reader_launcher_side = "right", start_menu_position = "left" })
    local bars, grid = recordLauncherPaint()
    local shim = readerShim()
    local ov = MicroFS.open(shim, shim._micromod_dimen, 40)
    local offs = overlayOffsets(ov)
    local bars_box = union(bars)
    assert(bars_box.x > SW / 2, "reader side=right puts the hamburger on the right")
    assert(offsetPresent(offs, bars_box), "hamburger repainted on the right")
    assert(offsetPresent(offs, union(grid)), "close-X repainted on the left")
end)

-- ── the grid area clears the buttons and reaches the far edge ────────────────
t.test("top-anchored launcher: grid starts below the buttons and runs to the bottom",
function()
    reset({ reader_launcher_top = true })
    local edge, px = ReaderButtons.reservedBand()
    assert(edge == "top", "reservedBand must report the top edge")
    local shim = readerShim()
    local ov = MicroFS.open(shim, shim._micromod_dimen, 40)
    local g = gridLayout(ov)
    assert(g.top >= px, string.format(
        "grid top (%d) must clear the launcher band (%d)", g.top, px))
    assert(g.top + g.h == SH - MARGIN, string.format(
        "grid must reach the bottom margin -- no dead strip below it"
        .. " (ends at %d, screen bottom margin at %d)", g.top + g.h, SH - MARGIN))
end)

t.test("bottom-anchored launcher: grid keeps clear of the buttons at the bottom",
function()
    reset()
    local edge, px = ReaderButtons.reservedBand()
    assert(edge == "bottom", "reservedBand must report the bottom edge")
    local shim = readerShim()
    local ov = MicroFS.open(shim, shim._micromod_dimen, 40)
    local g = gridLayout(ov)
    assert(g.top == MARGIN, "nothing at the top to clear, so no spacer above the grid")
    assert(g.top + g.h == SH - (px + MARGIN), string.format(
        "grid bottom (%d) must stop a margin above the launcher band (%d)",
        g.top + g.h, SH - px))
end)

-- ── shelf context is untouched ───────────────────────────────────────────────
t.test("shelf context reserves the footer band, not the reader launcher's", function()
    -- Reader launcher pinned to the TOP: a shelf-opened overlay must ignore it
    -- entirely and still reserve its own bottom footer band.
    reset({ reader_launcher_top = true })
    local footer_h = 40
    local shelf_bw = {
        FOOTER_HIT_EXTENSION = FooterGeom.hitExtension(),
        FOOTER_STROKE_W      = FooterGeom.barMetrics().bar_t,
        _hero_cells          = {},
        _micromod_dimen      = { x = 1100, y = 1600, w = 120, h = 60 },
        _burger_dimen        = { x = 20,   y = 1600, w = 120, h = 60 },
        _startMenuPosition   = function() return "left" end,
    }
    local ov = MicroFS.open(shelf_bw, shelf_bw._micromod_dimen, footer_h)
    local g = gridLayout(ov)
    assert(g.top == MARGIN, "shelf overlay must not reserve anything at the top")
    assert(g.top + g.h == SH - (footer_h + MARGIN), string.format(
        "shelf overlay must reserve footer_h + margin at the bottom (got bottom %d)",
        g.top + g.h))
    -- ...and keep centring its glyphs in the real footer button frames.
    local offs = overlayOffsets(ov)
    assert(offsetPresent(offs, { x = 1100, y = 1600 }),
        "shelf close-X still hangs on the footer grid button's frame")
    assert(offsetPresent(offs, { x = 20, y = 1600 }),
        "shelf hamburger still hangs on the footer button's frame")
end)

t.done()
