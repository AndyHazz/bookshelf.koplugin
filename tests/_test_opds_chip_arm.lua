-- tests/_test_opds_chip_arm.lua
-- The one-shot OPDS fetch arm on the two ways a user lands on a chip.
--
-- Device report: add a chip, point its Source at an OPDS catalog, Save --
-- and the shelf shows the empty state. Pulling down, or switching away and
-- back, fetches it fine.
--
-- Why: every OPDS network call is gated on _opds_nav_pending, a one-shot arm
-- the navigation gestures set and the next _opdsAfterPage consumes (see
-- _markOpdsNav). Landing on a chip by TAP or by _selectChip arms it. Landing
-- on one by EDITING it did not: the add-chip flow's own _selectChip arm is
-- spent on the placeholder source the new chip is born with ({kind = "all"}),
-- the source pick that makes it an OPDS chip is held in the editor's draft with
-- no shelf rebuild at all, and the rebuild that finally renders the feed is the
-- editor's on_change -- which armed nothing. Pull-down (_opdsRefresh) calls the
-- fetch directly and chip-switch re-arms, which is exactly why both worked.
--
-- What is asserted: the shelf's post-edit handler arms BEFORE it rebuilds, so
-- the rebuild it runs is the one that spends the arm, and _selectChip still
-- does the same -- the bug was two ways onto a chip disagreeing.
--
-- Usage (from plugin root): lua tests/_test_opds_chip_arm.lua

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

local dirty = 0

-- ── KOReader stubs (the load-time set the other widget suites install) ─────
local widget_cls = make_widget_class()
package.loaded["ui/widget/container/inputcontainer"]  = widget_cls
package.loaded["ui/widget/container/framecontainer"]  = make_widget_class()
package.loaded["ui/widget/container/centercontainer"] = make_widget_class()
package.loaded["ui/widget/verticalgroup"]             = make_widget_class()
package.loaded["ui/widget/horizontalgroup"]           = make_widget_class()
package.loaded["ui/widget/textwidget"]                = make_widget_class()
package.loaded["ui/widget/textboxwidget"]             = make_widget_class()
package.loaded["ui/widget/verticalspan"]              = make_widget_class()
package.loaded["ui/geometry"]     = { new = function(_, t) return t or {} end }
package.loaded["ui/gesturerange"] = { new = function(_, t) return t or {} end }
package.loaded["ui/size"] = {
    padding = { default = 4, large = 8, fullscreen = 16 },
    item    = { height_default = 30 },
    border  = { thin = 1 },
    line    = { medium = 1 },
}
package.loaded["ui/font"] = { getFace = function() return {} end }
package.loaded["ui/uimanager"] = {
    setDirty       = function() dirty = dirty + 1 end,
    close          = function() end,
    show           = function() end,
    nextTick       = function(_, fn) if fn then fn() end end,
    scheduleIn     = function() end,
    unschedule     = function() end,
    isWidgetShown  = function() return false end,
}
package.loaded["ffi/blitbuffer"] = { COLOR_BLACK = 0, COLOR_WHITE = 0xFF,
                                     gray = function(v) return v end }
package.loaded["device"] = {
    screen = {
        getWidth    = function() return 1236 end,
        getHeight   = function() return 1648 end,
        scaleBySize = function(_, n) return n end,
    },
    isKindle = function() return false end,
}
package.loaded["logger"] = { dbg = function() end, warn = function() end,
                             err = function() end, info = function() end }
local saved_chip
package.loaded["lib/bookshelf_settings_store"] = {
    read         = function(_, default) return default end,
    save         = function() end,
    saveDeferred = function(k, v) if k == "active_chip" then saved_chip = v end end,
    delete       = function() end,
    flush        = function() end,
    isTrue       = function() return false end,
    nilOrTrue    = function() return true end,
}
package.loaded["lib/bookshelf_i18n"] = {
    gettext  = function(t) return t end,
    ngettext = function(s, p, n) return n == 1 and s or p end,
}
package.loaded["lib/bookshelf_book_repository"] = {
    invalidateWalkCache = function() end,
}
package.loaded["lib/bookshelf_hero_card"] = {
    new = function() return {} end,
    buildStatusRow = function() return nil end,
}
package.loaded["lib/bookshelf_chip_bar"]  = { new = function() return {} end }
package.loaded["lib/bookshelf_shelf_row"] = {}
package.loaded["lib/bookshelf_cover_progress"] = {
    decide          = function() return { bar = false, bar_pct = 0, glyph = nil } end,
    resolvedColors  = function() return {} end,
    badgeSize       = function(n) return n end,
    glyphRenderedH  = function() return 0 end,
}
package.loaded["lib/bookshelf_spine_widget"] = {
    new                 = function() return {} end,
    setDraftMode        = function() end,
    trueAspectBoxHeight = function(_w, _b, max_h) return max_h end,
    downloadedTickOffset = function() return 0, 0 end,
}
package.loaded["ui/widget/notification"] = { new = function(_, s) return s end }
package.loaded["ui/widget/infomessage"]  = { new = function(_, s) return s end }

_G.G_reader_settings = {
    readSetting = function() return nil end,
    saveSetting = function() end,
    isTrue      = function() return false end,
    flush       = function() end,
}

local function mock()
    local m = {}
    return setmetatable(m, {
        __index = function() return function() return mock() end end,
        __call  = function() return mock() end,
    })
end
table.insert(package.searchers or package.loaders, function(_name)
    return function() return mock() end
end)

local BW = dofile("lib/bookshelf_widget.lua")

local t = dofile("tests/_helpers.lua").runner()
local function eq(a, e, msg)
    if a ~= e then
        error((msg or "") .. " expected=" .. tostring(e) .. " got=" .. tostring(a), 2)
    end
end

-- A shelf stand-in whose _rebuild records the arm AS THE REBUILD SEES IT. That
-- is the whole assertion: an arm set after the rebuild is an arm the rebuild
-- could not spend, and one left lying around for the next passive render.
local function shelf()
    local s = setmetatable({}, { __index = BW })
    s.rebuilds = 0
    s.arm_at_rebuild = {}
    s._rebuild = function()
        s.rebuilds = s.rebuilds + 1
        s.arm_at_rebuild[s.rebuilds] = s._opds_nav_pending
    end
    s._clearDpadFocus     = function() end
    s._syncPageFromCursor = function() end
    return s
end

local function fresh()
    dirty, saved_chip = 0, nil
    local s = shelf()
    BW.live = s
    return s
end

-- ── The fix: the shelf's post-chip-edit handler ────────────────────────────

t.test("a chip edit arms the OPDS fetch gate before it rebuilds", function()
    local s = fresh()
    s:_afterChipEdit()
    eq(s.rebuilds, 1, "rebuild count:")
    eq(s.arm_at_rebuild[1], true, "the arm as the rebuild saw it:")
end)

t.test("a chip edit repaints", function()
    local s = fresh()
    s:_afterChipEdit()
    eq(dirty, 1, "setDirty count:")
end)

-- The arm is one-shot and _opdsAfterPage consumes it on that very rebuild, so
-- nothing is left behind for the next passive render (a cover landing, the
-- file poll) to spend on a fetch the user did not ask for. Asserted through
-- the real _opdsAfterPage: a shelf on no OPDS feed at all still spends it.
t.test("the rebuild's page hook spends the arm even off an OPDS feed", function()
    local s = fresh()
    s._drilldown_path = {}
    s.chip = "all"
    s:_afterChipEdit()
    -- Stand in for the rebuild's own call, which the stub above skipped.
    s:_opdsAfterPage({})
    eq(s._opds_nav_pending, nil, "arm after the page hook:")
end)

-- ── The path that always worked, as the comparison ─────────────────────────

t.test("_selectChip arms the same gate the same way", function()
    local s = fresh()
    s:_selectChip("custom_3")
    eq(s.chip, "custom_3", "active chip:")
    eq(saved_chip, "custom_3", "persisted chip:")
    eq(s.rebuilds, 1, "rebuild count:")
    eq(s.arm_at_rebuild[1], true, "the arm as the rebuild saw it:")
end)

t.done()
