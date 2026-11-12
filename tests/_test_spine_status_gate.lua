-- tests/_test_spine_status_gate.lua
-- Which surfaces get which read-status chrome (SpineWidget:_statusIndicators).
-- Usage: cd into the plugin dir, then `lua tests/_test_spine_status_gate.lua`.
--
-- The grid, the list row and the hero/stack covers are all the SAME widget,
-- told apart only by two flags. Issue #365 exists because that distinction
-- used to be ONE flag: the favourite badge hangs off show_fav_badge alone and
-- so had always rendered in list view, while every cue decide() produces hung
-- off show_progress and so never did. Splitting show_status out of
-- show_progress is easy to undo by accident -- a later caller that reaches for
-- show_progress "because it wants the badge" silently drags the top-edge bar
-- and the page-count pill onto a 30x45 thumbnail. These tests pin the split.
--
-- Same load-time stubs as _test_spine_widget_aspect.lua (the module pulls in a
-- lot of KOReader at require time), except decide() is made controllable.

package.path = "./?.lua;" .. package.path

local function make_widget_base()
    local W = {}
    W.__index = W
    function W:extend(o) o = o or {}; setmetatable(o, self); self.__index = self; return o end
    function W:new(o) o = o or {}; setmetatable(o, self); self.__index = self; if self.init then self:init() end; return o end
    function W:init() end
    return W
end

for _, name in ipairs({
    "ui/widget/widget",
    "ui/widget/overlapgroup",
    "ui/widget/container/framecontainer",
    "ui/widget/container/centercontainer",
    "ui/widget/container/bottomcontainer",
    "ui/widget/container/rightcontainer",
    "ui/widget/container/inputcontainer",
    "ui/widget/imagewidget",
}) do
    package.preload[name] = function() return make_widget_base() end
end
package.preload["ui/geometry"] = function()
    return { new = function(_, t) return setmetatable(t or {}, { __index = {} }) end }
end
package.preload["ui/gesturerange"] = function() return { new = function(_, t) return t end } end
package.preload["ui/size"] = function()
    return {
        padding = { small = 3, default = 5, large = 10, fullscreen = 15 },
        border  = { thin = 1, medium = 2 },
    }
end
package.preload["ui/bidi"] = function() return { mirroredUILayout = function() return false end } end
package.preload["ffi/blitbuffer"] = function()
    return {
        Color8      = function(n) return { v = n } end,
        ColorRGB32  = function(r,g,b,a) return { r=r, g=g, b=b, a=a } end,
        COLOR_WHITE = {}, COLOR_BLACK = {},
        gray        = function(n) return { gray = n } end,
        new         = function() return {} end,
    }
end
package.preload["ffi"] = function()
    return {
        typeof   = function() return {} end,
        istype   = function() return false end,
        metatype = function() end,
        cdef     = function() end,
        new      = function() return {} end,
    }
end
package.preload["ffi/util"] = function() return { template = function(s) return s end } end
package.preload["device"] = function()
    return {
        isAndroid = function() return false end,
        screen = {
            isColorEnabled = function() return false end,
            scaleBySize    = function(_, n) return n end,
        },
    }
end
_G.__test_settings = {}
package.preload["lib/bookshelf_settings_store"] = function()
    return {
        read = function(k, d)
            local v = _G.__test_settings[k]
            if v == nil then return d end
            return v
        end,
        isTrue = function(k) return _G.__test_settings[k] == true end,
    }
end
package.preload["lib/bookshelf_scaled_cover_cache"] = function()
    return { get = function() return nil end, put = function(_, _, bb) return bb end }
end
package.preload["lib/bookshelf_fonts"] = function()
    return { getFace = function() return {}, {} end }
end
_G.__decide_result = {}
_G.__decide_calls  = 0
package.preload["lib/bookshelf_cover_progress"] = function()
    return {
        badgeSize      = function(n) return n end,
        glyphRenderedH = function() return 0 end,
        resolvedColors = function() return {} end,
        decide         = function(_book, surface)
            _G.__decide_calls = _G.__decide_calls + 1
            _G.__decide_surface = surface
            return _G.__decide_result
        end,
    }
end
package.preload["lib/bookshelf_i18n"] = function() return { gettext = function(s) return s end } end

_G.G_reader_settings = {
    isTrue    = function() return false end,
    nilOrTrue = function() return true end,
}

local SpineWidget = require("lib/bookshelf_spine_widget")

local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

-- A fixture has to resolve methods on SpineWidget rather than be a bare table.
local function spine(flags)
    return setmetatable(flags or {}, { __index = SpineWidget })
end

-- Everything decide() can answer for a finished-and-faded on-hold book, so a
-- field that leaks through where it shouldn't is visible.
local function everything()
    return {
        bar          = true,
        bar_pct      = 42,
        glyph        = "complete_bookmark",
        on_hold      = true,
        on_hold_fade = true,
        page_count   = true,
    }
end

local function ask(flags)
    _G.__decide_result = everything()
    _G.__decide_calls  = 0
    return spine(flags):_statusIndicators()
end

-- ── The hero / folder / series stacks ──────────────────────────────────────

t.test("a cover with neither flag gets no status chrome", function()
    local ind = ask{}
    eq(ind.bar, false)
    eq(ind.glyph, nil, "the hero would paint a bookmark over its own overlay")
    eq(ind.on_hold, nil)
    eq(ind.on_hold_fade, nil)
end)

t.test("a cover with neither flag never asks decide()", function()
    -- Not a micro-optimisation: decide() falls back to Repo.readProgress for
    -- any book whose record has no status, which opens DocSettings. Asking on
    -- behalf of a surface that will discard the answer puts a sidecar read
    -- behind every hero and every stack cover.
    ask{}
    eq(_G.__decide_calls, 0, "a clean surface opened a sidecar for nothing")
end)

-- ── The grid ───────────────────────────────────────────────────────────────

t.test("show_progress passes decide() through untouched", function()
    local ind = ask{ show_progress = true }
    eq(ind.bar, true)
    eq(ind.bar_pct, 42)
    eq(ind.page_count, true)
    eq(ind.glyph, "complete_bookmark")
    eq(ind.on_hold, true)
    eq(ind.on_hold_fade, true)
end)

-- ── The list row (issue #365) ──────────────────────────────────────────────

t.test("show_status carries the badges and the fade", function()
    local ind = ask{ show_status = true }
    eq(ind.glyph, "complete_bookmark", "the completed badge was dropped")
    eq(ind.on_hold, true, "the pause badge was dropped")
    eq(ind.on_hold_fade, true, "the fade was dropped")
end)

t.test("show_status drops the bar and the page count", function()
    -- A hairline bar and an unreadable pill at ~30x45, both duplicating what
    -- the row's own token lines already say.
    local ind = ask{ show_status = true }
    eq(ind.bar, false, "the top-edge bar reached a list thumbnail")
    eq(ind.bar_pct, 0)
    eq(ind.page_count, false, "the page-count pill reached a list thumbnail")
end)

t.test("show_status still asks decide(), so settings are honoured", function()
    -- The whole request: the list covers follow the SAME on_hold_display /
    -- progress_badge_style / finished_fade_enabled keys the grid reads, with
    -- no toggle of their own.
    ask{ show_status = true }
    eq(_G.__decide_calls, 1)
end)

t.test("show_progress wins when a surface sets both", function()
    local ind = ask{ show_progress = true, show_status = true }
    eq(ind.bar, true, "the grid lost its bar to the narrower flag")
    eq(ind.page_count, true)
end)

-- ── Clearing the row edge (issue #365 follow-up) ──────────────────────────

t.test("a list badge is pulled up off the row edge", function()
    -- The grid hangs its badges past the cover and has room below to do it.
    -- A list card's bottom edge IS the row's, so the same placement put the
    -- completed tickbox's last rows on the divider and its bottom border
    -- disappeared.
    local w = spine{ show_status = true }
    assert(w:_listBadgeClearance(26) >= 3, "no clearance, so the border still goes")
end)

t.test("the clearance is small enough to keep the overhang", function()
    -- The grid's placement was very nearly right: only a row or two was being
    -- lost. Taking back much more would tuck the badge inside the cover, which
    -- is what the first two attempts at this did and what got rejected.
    local w = spine{ show_status = true }
    assert(w:_listBadgeClearance(26) <= 6,
        "took back too much: " .. w:_listBadgeClearance(26))
end)

t.test("the clearance scales with the badge, not with the device", function()
    -- Off the BADGE'S height, which is a number we already have and which the
    -- Cover badge size dialog moves. Anchoring to the artwork instead was
    -- tried and does not work: the only cheap source for where the cover ends
    -- is bookAspect's cover_sizetag, and it disagrees with what the renderer
    -- draws (Katabasis reports ~1.38, renders at ~1.50), which put the badge
    -- 19px too high and stopped it hanging below the cover at all.
    local w = spine{ show_status = true }
    assert(w:_listBadgeClearance(60) > w:_listBadgeClearance(20),
        "the clearance does not scale with the badge")
end)

t.test("a degenerate badge height still clears", function()
    local w = spine{ show_status = true }
    assert(w:_listBadgeClearance(0) >= 3)
    assert(w:_listBadgeClearance(nil) >= 3)
end)

t.test("the in-progress glyph still paints behind the cover", function()
    -- SOURCE-SHAPE. It is appended BEFORE `inner`, so the cover paints over
    -- it and only the overhang shows. Moving it in front was tried and
    -- rejected -- it is the overhang that is supposed to read, on the list
    -- exactly as on the grid -- so this pins the order against a well-meaning
    -- future fix for "the bookmark is hard to see".
    local src = {}
    for line in io.lines("lib/bookshelf_spine_widget.lua") do
        if not line:match("^%s*%-%-") then src[#src + 1] = line end
    end
    src = table.concat(src, "\n")
    local glyph_at = src:find("children[#children + 1] = glyph_frame", 1, true)
    local inner_at = src:find("children[#children + 1] = inner", 1, true)
    assert(glyph_at and inner_at, "the append sites moved or were renamed")
    assert(glyph_at < inner_at,
        "the in-progress glyph now paints in FRONT of the cover")
end)

-- ── The spine shelf's face-out books ───────────────────────────────────────
--
-- A face-out is the one cover on that shelf big enough to read, so unlike the
-- list thumbnail it DOES want the bar and the glyphs. What it does not want is
-- the two corner pills: the spines beside it already number their series on
-- the foot, and a book's length is its width there, so "#3" and "412p" repeat
-- what the shelf has said and break the skeuomorphism (user ruling, the same
-- one that took the favourite heart off a face-out).

t.test("suppress_number_badges drops the page-count pill", function()
    local ind = ask{ show_progress = true, suppress_number_badges = true }
    eq(ind.page_count, false)
end)

t.test("...and keeps everything a face-out is big enough to show", function()
    -- The reason this is not show_progress=false, which would take the lot.
    local ind = ask{ show_progress = true, suppress_number_badges = true }
    eq(ind.bar, true, "a part-read face-out still shows how far in it is")
    eq(ind.bar_pct, 42)
    eq(ind.glyph, "complete_bookmark")
    eq(ind.on_hold, true)
    eq(ind.on_hold_fade, true)
end)

t.test("the grid is untouched by the flag it does not set", function()
    local ind = ask{ show_progress = true }
    eq(ind.page_count, true, "the pills left the grid as well")
end)

t.test("suppressing does not mutate decide()'s own table", function()
    -- decide() may hand back a table it keeps. Clearing the field in place
    -- would turn one face-out into a shelf-wide setting, and the next grid
    -- render would silently lose its pills.
    ask{ show_progress = true, suppress_number_badges = true }
    eq(_G.__decide_result.page_count, true, "decide()'s answer was edited in place")
end)

-- The series pill has no entry in decide()'s answer -- it is painted straight
-- from book.series_num -- so its gate can only be checked in the source.
t.test("the series pill is gated on the same flag", function()
    local src = assert(io.open("lib/bookshelf_spine_widget.lua")):read("*a")
    local cond = src:match("(if self%.show_progress and _showSeriesNum.-then)")
    assert(cond, "the series-number badge condition moved or was renamed")
    assert(cond:find("suppress_number_badges", 1, true),
        "the series pill still renders on a face-out")
end)

t.test("the face-out tile asks for both pills to go", function()
    local src = assert(io.open("lib/bookshelf_spine_shelf.lua")):read("*a")
    local tile = src:match("CoverTile:new{(.-)}")
    assert(tile, "the face-out tile construction moved")
    assert(tile:find("suppress_number_badges%s*=%s*true"),
        "the shelf stopped asking, so the pills are back")
end)

-- ── Per-surface switches (issue 597) ───────────────────────────────────────
--
-- The page pill on a face-out is now the reader's choice (Cover display >
-- Page badge > Show on spine shelves, off until chosen), so the tile says
-- which surface it is on and decide() answers for that surface. The series
-- pill stays off a face-out: suppress_number_badges still asks for that.

t.test("a tile on a spine shelf asks decide() about spine shelves", function()
    ask{ show_progress = true, marks_surface = "spines" }
    eq(_G.__decide_surface, "spines")
    ask{ show_progress = true }
    eq(_G.__decide_surface, nil, "every other tile asks about covers")
end)

t.test("on a spine shelf the page pill is the surface's decision", function()
    local ind = ask{ show_progress = true, suppress_number_badges = true,
                     marks_surface = "spines" }
    eq(ind.page_count, true, "decide() said yes for spines and the tile overruled it")
end)

t.test("the face-out tile says it is on a spine shelf", function()
    local src = assert(io.open("lib/bookshelf_spine_shelf.lua")):read("*a")
    local tile = src:match("CoverTile:new{(.-)}")
    assert(tile:find('marks_surface%s*=%s*"spines"'),
        "a face-out no longer follows the spine shelf switches")
end)

t.test("the favourite badge follows its switch for the tile's surface", function()
    local src = assert(io.open("lib/bookshelf_spine_widget.lua")):read("*a")
    assert(src:find('Marks.shown("favorite", self.marks_surface)', 1, true),
        "the favourite badge reads the covers setting on every surface")
end)

t.test("the series pill has a covers switch", function()
    local src = assert(io.open("lib/bookshelf_spine_widget.lua")):read("*a")
    local body = src:match("\nlocal function _showSeriesNum%(in_series%)\n(.-)\nend\n")
    assert(body and body:find('Marks.shown("series_num", "covers")', 1, true),
        "Show on covers does nothing for the series number")
end)

t.done()
