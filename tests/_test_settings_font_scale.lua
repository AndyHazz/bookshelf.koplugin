-- tests/_test_settings_font_scale.lua
-- Pure-Lua tests for the font-scale "nudge dialog" pickers in
-- bookshelf_settings.lua: _pickCoverBadgeFontScale, _pickExpandedShelfFontScale,
-- _pickFontScale, _pickHeroModuleFontScale, _pickChipFontScale,
-- _pickStackLabelFontScale, _pickStartMenuFontScale, _pickModalTabFontScale.
--
-- These all build a real ButtonDialog and call into UIManager/Focus, which
-- bookshelf_settings.lua has never had a stub harness for. ButtonDialog is
-- stubbed to just hand back the plain table it was constructed with (no
-- widget lifecycle), so the buttons' callbacks -- the actual nudge/clamp/
-- persist/revert/preview logic -- can be invoked directly and asserted on.

package.path = "./?.lua;./?/init.lua;" .. package.path

local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()
local eq = helpers.eq

-- ── Settings-store backing (same in-memory pattern as _test_settings_store) ──
local lua_store = { migrated = true }
package.loaded["datastorage"] = {
    getSettingsDir = function() return "/tmp/bookshelf-settings-font-scale-test" end,
}
package.loaded["logger"] = {
    dbg = function() end, info = function() end,
    warn = function() end, err = function() end,
}
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(_path, attr)
        if attr == "mode" then return "file" end
        return nil
    end,
}
package.loaded["luasettings"] = {
    open = function(_self, _path)
        return {
            readSetting = function(_, k) return lua_store[k] end,
            saveSetting = function(_, k, v) lua_store[k] = v end,
            delSetting  = function(_, k) lua_store[k] = nil end,
            flush       = function() end,
            isTrue      = function(_, k) return lua_store[k] == true end,
            nilOrTrue   = function(_, k)
                local v = lua_store[k]; return v == nil or v == true
            end,
        }
    end,
}
_G.G_reader_settings = {
    readSetting = function(_, k) return nil end,
    delSetting  = function(_, k) end,
    -- The colour rows ask for night_mode to decide which key suffix to write and
    -- which way round "% black" reads. Day mode keeps both straightforward.
    isTrue      = function(_, k) return false end,
}
local BookshelfSettings = dofile("lib/bookshelf_settings_store.lua")
package.loaded["lib/bookshelf_settings_store"] = BookshelfSettings

local function resetStore()
    for k in pairs(lua_store) do lua_store[k] = nil end
    lua_store.migrated = true
end

-- ── KOReader widget stubs bookshelf_settings.lua needs just to load ─────────
package.loaded["ui/widget/menu"]         = {}
package.loaded["ui/widget/notification"] = {}
package.loaded["ui/widget/spinwidget"]   = {}
package.loaded["ffi/util"]               = { template = function(s) return s end }
package.loaded["lib/bookshelf_i18n"]     = {
    gettext = function(s) return s end,
    ngettext = function(s, p, n) return n == 1 and s or p end,
}
package.loaded["lib/bookshelf_fonts"]    = {}

-- Real bookshelf_focus.lua has no requires of its own; Focus.reinit no-ops
-- when dialog.reinit is absent (our stub dialogs never set it), so loading
-- it for real needs no stubbing.
package.loaded["lib/bookshelf_focus"] = nil

-- UIManager: record calls instead of doing anything.
local ui_calls
package.loaded["ui/uimanager"] = {
    show     = function(_, w) ui_calls[#ui_calls + 1] = { op = "show", w = w } end,
    -- refreshtype/region are captured too: a close with no refreshtype reaches
    -- _refresh(nil), which KOReader DROPS, so an opaque full-screen widget must
    -- pass them explicitly or nothing is flushed to an e-ink panel.
    close    = function(_, w, refreshtype, region)
        ui_calls[#ui_calls + 1] = { op = "close", w = w,
                                    refreshtype = refreshtype, region = region }
    end,
    setDirty = function(_, w, kind) ui_calls[#ui_calls + 1] = { op = "setDirty", w = w, kind = kind } end,
}

-- ButtonDialog: hand back the plain constructor table untouched. No
-- .reinit/.movable fields, so Focus.reinit() and the `if dialog.movable`
-- guards both no-op exactly as they would for a dialog nobody ever dragged.
package.loaded["ui/widget/buttondialog"] = {
    new = function(_, o) return o end,
}

-- StartMenu / ReviewsModal: bespoke fakes wired up per-test below (the real
-- modules are full widget trees; bookshelf_settings.lua only ever touches
-- their `._live` preview handle and a couple of opener methods).
local StartMenuStub = { _live = nil }
package.loaded["lib/bookshelf_start_menu"] = StartMenuStub
local ReviewsModalStub = { _live = nil }
package.loaded["lib/bookshelf_reviews_modal"] = ReviewsModalStub

package.loaded["lib/bookshelf_settings"] = nil
local Settings = dofile("lib/bookshelf_settings.lua")

-- ── Test doubles ─────────────────────────────────────────────────────────────

local function makeTouchMenu()
    return { update_count = 0, updateItems = function(self) self.update_count = self.update_count + 1 end }
end

local function makeBw()
    return { rebuild_count = 0, _rebuild = function(self) self.rebuild_count = self.rebuild_count + 1 end }
end

local function makePreview()
    local p = { reload_count = 0, close_count = 0 }
    p._reload = function(self) self.reload_count = self.reload_count + 1 end
    p._close  = function(self) self.close_count = self.close_count + 1 end
    return p
end

-- self._plugin: hideMenu() returns a recording "restoreMenu" closure.
local function makePlugin(opts)
    opts = opts or {}
    local plugin = {
        restore_count = 0,
        reader_open_count = 0,
        ui = { document = opts.in_reader or nil },
    }
    plugin.hideMenu = function(self, _touchmenu_instance)
        return function() self.restore_count = self.restore_count + 1 end
    end
    plugin._openReaderStartMenu = function(self)
        self.reader_open_count = self.reader_open_count + 1
        StartMenuStub._live = makePreview()
    end
    return plugin
end

-- Find a button by its literal `text` field, scanning every row. All eight
-- pickers lay out { {-10,-5,val,+5,+10}, {Cancel,Default,Apply} } (or the
-- chip picker's {-10,-1,val,+1,+10}), but hunting by text rather than
-- position keeps these tests honest about *what* they're calling.
local function findButton(dialog, text)
    for _, row in ipairs(dialog.buttons) do
        for _, b in ipairs(row) do
            if b.text == text then return b end
        end
    end
    error("no button with text " .. tostring(text))
end

local function nudgeLabel(dialog)
    for _, row in ipairs(dialog.buttons) do
        for _, b in ipairs(row) do
            if b.enabled == false and b.text_func then return b.text_func() end
        end
    end
end

-- ── Shared spec covering the six plain "nudge -> rebuild" pickers ──────────

local PLAIN_PICKERS = {
    { fn = "_pickCoverBadgeFontScale",    key = "cover_badge_font_scale",    min = 50, max = 200, steps = { -10, -5, 5, 10 } },
    { fn = "_pickExpandedShelfFontScale", key = "expanded_shelf_font_scale", min = 50, max = 300, steps = { -10, -5, 5, 10 } },
    { fn = "_pickFontScale",              key = "font_scale",               min = 50, max = 200, steps = { -10, -5, 5, 10 } },
    { fn = "_pickHeroModuleFontScale",    key = "hero_module_font_scale",   min = 50, max = 200, steps = { -10, -5, 5, 10 } },
    { fn = "_pickChipFontScale",          key = "chip_font_scale",          min = 50, max = 300, steps = { -10, -1, 1, 10 } },
    { fn = "_pickStackLabelFontScale",    key = "stack_label_font_scale",   min = 50, max = 300, steps = { -10, -5, 5, 10 } },
}

for _, spec in ipairs(PLAIN_PICKERS) do
    t.test(spec.fn .. ": reads the stored value, defaults to 100", function()
        resetStore()
        ui_calls = {}
        local bw, tm = makeBw(), makeTouchMenu()
        Settings._bw, Settings._plugin = bw, makePlugin()
        Settings[spec.fn](Settings, tm)
        local dialog = ui_calls[#ui_calls].w
        eq(nudgeLabel(dialog), "100%")
    end)

    t.test(spec.fn .. ": nudging by each step persists the new value and rebuilds", function()
        resetStore()
        ui_calls = {}
        local bw, tm = makeBw(), makeTouchMenu()
        Settings._bw, Settings._plugin = bw, makePlugin()
        Settings[spec.fn](Settings, tm)
        local dialog = ui_calls[#ui_calls].w
        for _, step in ipairs(spec.steps) do
            local label = (step > 0 and "+" or "") .. tostring(step)
            local before = BookshelfSettings.read(spec.key, 100)
            findButton(dialog, label).callback()
            eq(BookshelfSettings.read(spec.key, 100), before + step, spec.fn .. " step " .. label)
        end
        assert(bw.rebuild_count > 0, spec.fn .. " never rebuilt the widget")
        assert(tm.update_count > 0, spec.fn .. " never refreshed the touch menu")
    end)

    t.test(spec.fn .. ": clamps at the floor and ceiling", function()
        resetStore()
        ui_calls = {}
        Settings._bw, Settings._plugin = makeBw(), makePlugin()
        Settings[spec.fn](Settings, makeTouchMenu())
        local dialog = ui_calls[#ui_calls].w
        local most_negative = findButton(dialog, tostring(spec.steps[1]))
        for _ = 1, 40 do most_negative.callback() end
        eq(BookshelfSettings.read(spec.key, 100), spec.min, spec.fn .. " floor")
        local most_positive = findButton(dialog, "+" .. tostring(spec.steps[#spec.steps]))
        for _ = 1, 40 do most_positive.callback() end
        eq(BookshelfSettings.read(spec.key, 100), spec.max, spec.fn .. " ceiling")
    end)

    t.test(spec.fn .. ": Default resets to 100 without waiting for Apply", function()
        resetStore()
        BookshelfSettings.save(spec.key, 150)
        ui_calls = {}
        Settings._bw, Settings._plugin = makeBw(), makePlugin()
        Settings[spec.fn](Settings, makeTouchMenu())
        local dialog = ui_calls[#ui_calls].w
        findButton(dialog, "Default").callback()
        eq(BookshelfSettings.read(spec.key, 100), 100)
    end)

    t.test(spec.fn .. ": Cancel reverts to the value the dialog opened with", function()
        resetStore()
        BookshelfSettings.save(spec.key, 130)
        ui_calls = {}
        local plugin = makePlugin()
        Settings._bw, Settings._plugin = makeBw(), plugin
        Settings[spec.fn](Settings, makeTouchMenu())
        local dialog = ui_calls[#ui_calls].w
        findButton(dialog, "+" .. tostring(spec.steps[#spec.steps])).callback()
        assert(BookshelfSettings.read(spec.key, 100) ~= 130, spec.fn .. " nudge had no effect to revert")
        findButton(dialog, "Cancel").callback()
        eq(BookshelfSettings.read(spec.key, 100), 130)
        eq(plugin.restore_count, 1, spec.fn .. " Cancel should restore the parent menu exactly once")
    end)

    t.test(spec.fn .. ": Apply keeps the nudged value and closes the dialog", function()
        resetStore()
        ui_calls = {}
        local plugin = makePlugin()
        Settings._bw, Settings._plugin = makeBw(), plugin
        Settings[spec.fn](Settings, makeTouchMenu())
        local dialog = ui_calls[#ui_calls].w
        findButton(dialog, "+" .. tostring(spec.steps[#spec.steps])).callback()
        local nudged = BookshelfSettings.read(spec.key, 100)
        findButton(dialog, "Apply").callback()
        eq(BookshelfSettings.read(spec.key, 100), nudged)
        eq(plugin.restore_count, 1, spec.fn .. " Apply should restore the parent menu exactly once")
        local closed = false
        for _, c in ipairs(ui_calls) do if c.op == "close" and c.w == dialog then closed = true end end
        assert(closed, spec.fn .. " Apply never closed the dialog")
    end)
end

-- ── _pickStartMenuFontScale: reader-vs-library live preview (issue #297) ───

t.test("_pickStartMenuFontScale: in library context, previews via self._bw", function()
    resetStore()
    ui_calls = {}
    StartMenuStub._live = nil
    local bw, plugin = makeBw(), makePlugin{ in_reader = false }
    bw._openStartMenu = function(self) self.opened = true end
    Settings._bw, Settings._plugin = bw, plugin
    Settings._pickStartMenuFontScale(Settings, makeTouchMenu())
    assert(bw.opened, "library context should open the preview via self._bw")
    eq(plugin.reader_open_count, 0)
end)

t.test("_pickStartMenuFontScale: in reader context, previews via self._plugin (#297)", function()
    resetStore()
    ui_calls = {}
    StartMenuStub._live = nil
    local bw, plugin = makeBw(), makePlugin{ in_reader = true }
    bw._openStartMenu = function(self) self.opened = true end
    Settings._bw, Settings._plugin = bw, plugin
    Settings._pickStartMenuFontScale(Settings, makeTouchMenu())
    assert(not bw.opened, "reader context must not open the library's start menu")
    eq(plugin.reader_open_count, 1)
end)

t.test("_pickStartMenuFontScale: does not re-open a preview that's already live", function()
    resetStore()
    ui_calls = {}
    StartMenuStub._live = makePreview()
    local bw, plugin = makeBw(), makePlugin{ in_reader = false }
    bw._openStartMenu = function(self) self.opened = true end
    Settings._bw, Settings._plugin = bw, plugin
    Settings._pickStartMenuFontScale(Settings, makeTouchMenu())
    assert(not bw.opened, "an already-live preview should be reused, not reopened")
end)

t.test("_pickStartMenuFontScale: nudging reloads the live preview, not a widget rebuild", function()
    resetStore()
    ui_calls = {}
    StartMenuStub._live = nil
    local bw, plugin = makeBw(), makePlugin{ in_reader = false }
    bw._openStartMenu = function() StartMenuStub._live = makePreview() end
    Settings._bw, Settings._plugin = bw, plugin
    Settings._pickStartMenuFontScale(Settings, makeTouchMenu())
    local dialog = ui_calls[#ui_calls].w
    local preview = StartMenuStub._live
    findButton(dialog, "+5").callback()
    eq(preview.reload_count, 1)
    eq(bw.rebuild_count, 0, "start-menu picker should not touch the shelf rebuild path")
end)

t.test("_pickStartMenuFontScale: Apply closes a preview we opened", function()
    resetStore()
    ui_calls = {}
    StartMenuStub._live = nil
    local bw, plugin = makeBw(), makePlugin{ in_reader = false }
    bw._openStartMenu = function() StartMenuStub._live = makePreview() end
    Settings._bw, Settings._plugin = bw, plugin
    Settings._pickStartMenuFontScale(Settings, makeTouchMenu())
    local dialog = ui_calls[#ui_calls].w
    local preview = StartMenuStub._live
    findButton(dialog, "Apply").callback()
    eq(preview.close_count, 1)
end)

t.test("_pickStartMenuFontScale: Apply leaves a pre-existing preview open (we didn't own it)", function()
    resetStore()
    ui_calls = {}
    local preexisting = makePreview()
    StartMenuStub._live = preexisting
    local bw, plugin = makeBw(), makePlugin{ in_reader = false }
    bw._openStartMenu = function(self) self.opened = true end
    Settings._bw, Settings._plugin = bw, plugin
    Settings._pickStartMenuFontScale(Settings, makeTouchMenu())
    local dialog = ui_calls[#ui_calls].w
    findButton(dialog, "Apply").callback()
    eq(preexisting.close_count, 0, "a preview we didn't open should not be closed on our way out")
end)

-- ── _pickModalTabFontScale: live tab-bar refresh + shelf rebuild ───────────

t.test("_pickModalTabFontScale: nudging refreshes a live, non-dismissed modal's tab bar", function()
    resetStore()
    ui_calls = {}
    local live = { _dismissed = false, refresh_count = 0 }
    live.refreshTabBar = function(self) self.refresh_count = self.refresh_count + 1 end
    ReviewsModalStub._live = live
    local bw = makeBw()
    Settings._bw, Settings._plugin = bw, makePlugin()
    Settings._pickModalTabFontScale(Settings, makeTouchMenu())
    local dialog = ui_calls[#ui_calls].w
    findButton(dialog, "+5").callback()
    eq(live.refresh_count, 1)
    assert(bw.rebuild_count > 0, "modal-tab picker should still dirty the shelf (the proven e-ink repaint path)")
end)

t.test("_pickModalTabFontScale: a dismissed modal's tab bar is not refreshed", function()
    resetStore()
    ui_calls = {}
    local live = { _dismissed = true, refresh_count = 0 }
    live.refreshTabBar = function(self) self.refresh_count = self.refresh_count + 1 end
    ReviewsModalStub._live = live
    Settings._bw, Settings._plugin = makeBw(), makePlugin()
    Settings._pickModalTabFontScale(Settings, makeTouchMenu())
    local dialog = ui_calls[#ui_calls].w
    findButton(dialog, "+5").callback()
    eq(live.refresh_count, 0)
end)

t.test("_pickModalTabFontScale: no live modal is a safe no-op for the tab-bar refresh", function()
    resetStore()
    ui_calls = {}
    ReviewsModalStub._live = nil
    Settings._bw, Settings._plugin = makeBw(), makePlugin()
    Settings._pickModalTabFontScale(Settings, makeTouchMenu())
    local dialog = ui_calls[#ui_calls].w
    findButton(dialog, "+5").callback() -- must not error with no live modal
    eq(BookshelfSettings.read("modal_tab_font_scale", 100), 105)
end)

-- ── _pickLauncherButtons: the canvas must flush what it covered on close ─────
-- The canvas is an opaque full-screen widget over the shelf. UIManager:close
-- with no refreshtype ends in _refresh(nil), which is dropped outright, so the
-- shelf was repainted into the framebuffer and never reached the panel: coming
-- back from the launcher settings left a stale screen on e-ink. Desktop SDL
-- flushes regardless, which is why only an argument check catches this.
local SW, SH = 1264, 1680
package.loaded["ui/geometry"] = { new = function(_, tab) return tab end }
package.loaded["device"] = { screen = {
    getWidth    = function() return SW end,
    getHeight   = function() return SH end,
    scaleBySize = function(_, n) return n end,
    -- false = greyscale, so the colour rows take the "% black" NUDGE path (the
    -- one being tested, and the one an e-ink Kindle actually gets) rather than
    -- the palette picker. Settings requires device lazily per function, so this
    -- is picked up even though the module was loaded before the stub existed.
    isColorEnabled = function() return false end,
} }
-- Only the canvas handle and the gating accessors are needed here; the real
-- glyph geometry is covered by _test_reader_launcher_overlay.lua.
package.loaded["lib/bookshelf_reader_buttons"] = {
    previewWidget = function()
        return { name = "launcher_canvas",
                 dimen = { x = 0, y = 0, w = SW, h = SH } }
    end,
    side        = function() return "left" end,
    showMenu    = function() return true end,
    showModules = function() return false end,
}

local function openLauncherCanvas()
    resetStore()
    ui_calls = {}
    Settings._bw, Settings._plugin = makeBw(), makePlugin()
    Settings:_pickLauncherButtons(makeTouchMenu())
    local canvas, dialog
    for _, c in ipairs(ui_calls) do
        if c.op == "show" then
            if c.w and c.w.buttons then dialog = c.w else canvas = canvas or c.w end
        end
    end
    assert(canvas and canvas.name == "launcher_canvas", "canvas was not shown")
    assert(dialog, "controls dialog was not shown")
    return canvas, dialog
end

local function closeCallFor(widget)
    for _, c in ipairs(ui_calls) do
        if c.op == "close" and c.w == widget then return c end
    end
    return nil
end

for _, exit in ipairs({ "Apply", "Cancel" }) do
    t.test("_pickLauncherButtons: " .. exit .. " flushes the full screen the canvas covered",
    function()
        local canvas, dialog = openLauncherCanvas()
        findButton(dialog, exit).callback()
        local c = closeCallFor(canvas)
        assert(c, "the canvas was never closed")
        assert(c.refreshtype, "canvas close must pass an explicit refreshtype;"
            .. " a nil one is dropped by UIManager and never reaches the panel")
        eq(c.refreshtype, "ui")
        assert(c.region and c.region.w == SW and c.region.h == SH, string.format(
            "the refresh region must cover the whole screen (got %s)",
            c.region and (c.region.w .. "x" .. c.region.h) or "nil"))
    end)
end

-- ── chip-bar colour nudges: light refresh + anchored below the strip ─────────
-- Two reports, one row: adjusting the selected-chip colours was very slow, and
-- the centred dialog covered the strip being adjusted. The colours only change
-- how one widget PAINTS, so they must not trigger the shelf's _rebuild()
-- (re-reads the library, re-renders covers -- on every -/+ press), and the dialog
-- must hang off the chip bar instead of over it.

-- _colorsSubItems pulls in the colour helpers, which the font-scale pickers above
-- never touch. cover_progress is a render module (blitbuffer, fonts, widgets) and
-- the colour rows use exactly two data functions from it, so it is stubbed rather
-- than dragged in. bookshelf_color is real data with no deps beyond a blitbuffer.
package.loaded["ffi/blitbuffer"] = {
    COLOR_WHITE = "white", COLOR_BLACK = "black",
    Color8      = function(n) return { grey = n } end,
    ColorRGB32  = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end,
}
package.loaded["lib/bookshelf_cover_progress"] = {
    modeSuffix   = function() return "" end,     -- day mode: unsuffixed keys
    rawColors    = function() return {} end,     -- nothing preset
    favoriteIcon = function() return "heart" end, -- one row's label depends on it
}

-- A bw with a live chip bar: records recolour() calls and reports a screen rect
-- the way a painted InputContainer does (dimen.x/y stamped by paintTo).
local CHIP_RECT = { x = 20, y = 300, w = 1224, h = 60 }
local function makeBwWithChipBar()
    local bw = makeBw()
    bw._chip_bar = {
        recolour_count = 0,
        dimen = { x = CHIP_RECT.x, y = CHIP_RECT.y, w = CHIP_RECT.w, h = CHIP_RECT.h },
        recolour = function(self)
            self.recolour_count = self.recolour_count + 1
            return { x = self.dimen.x, y = self.dimen.y,
                     w = self.dimen.w, h = self.dimen.h }
        end,
    }
    return bw
end

local function openChipColourDialog(row_label)
    resetStore()
    ui_calls = {}
    local bw, tm = makeBwWithChipBar(), makeTouchMenu()
    Settings._bw, Settings._plugin = bw, makePlugin()
    local row
    for _, item in ipairs(Settings:_colorsSubItems()) do
        if item.text_func and item.text_func():find(row_label, 1, true) then row = item end
    end
    assert(row, "no colour row matching " .. row_label)
    row.callback(tm)
    local dialog
    for _, c in ipairs(ui_calls) do
        if c.op == "show" and c.w and c.w.buttons then dialog = c.w end
    end
    assert(dialog, row_label .. ": no nudge dialog was shown")
    return dialog, bw, row, tm
end

for _, row_label in ipairs({ "Selected chip fill", "Selected chip text" }) do
    t.test(row_label .. ": nudging recolours the strip, never rebuilds the shelf",
    function()
        local dialog, bw = openChipColourDialog(row_label)
        findButton(dialog, "+10").callback()
        assert(bw._chip_bar.recolour_count > 0,
            "the strip must be rebuilt in place so the new colour is painted")
        eq(bw.rebuild_count, 0,
            "a colour change must NOT regrid the shelf -- that is the slowness")
    end)

    t.test(row_label .. ": the refresh is scoped to the strip's rect", function()
        local dialog, _bw = openChipColourDialog(row_label)
        findButton(dialog, "+10").callback()
        local scoped
        for _, c in ipairs(ui_calls) do
            if c.op == "setDirty" and type(c.kind) == "function" then
                local _mode, region = c.kind()
                if region and region.w == CHIP_RECT.w then scoped = region end
            end
        end
        assert(scoped, "expected a setDirty scoped to the chip bar's rect")
        eq(scoped.y, CHIP_RECT.y)
    end)

    t.test(row_label .. ": the dialog opens below the strip, not over it", function()
        local dialog = openChipColourDialog(row_label)
        assert(type(dialog.anchor) == "function",
            "dialog must anchor to the chip bar rather than centring")
        local rect, prefers_pop_down = dialog.anchor()
        eq(rect, { x = CHIP_RECT.x, y = CHIP_RECT.y, w = CHIP_RECT.w, h = CHIP_RECT.h })
        assert(prefers_pop_down == true,
            "must ask MovableContainer to open BELOW -- above the bar is the bar")
    end)

    t.test(row_label .. ": long-press clear also stays off the shelf rebuild", function()
        local _dialog, bw, row, tm = openChipColourDialog(row_label)
        local before = bw._chip_bar.recolour_count
        row.hold_callback(tm)
        assert(bw._chip_bar.recolour_count > before, "clearing must repaint the strip")
        eq(bw.rebuild_count, 0, "clearing must not regrid the shelf either")
    end)
end

t.test("chip bar font scale is anchored to the strip too", function()
    resetStore()
    ui_calls = {}
    local bw = makeBwWithChipBar()
    Settings._bw, Settings._plugin = bw, makePlugin()
    Settings:_pickChipFontScale(makeTouchMenu())
    local dialog = ui_calls[#ui_calls].w
    assert(type(dialog.anchor) == "function", "font-scale dialog must anchor to the bar")
    local rect, prefers_pop_down = dialog.anchor()
    eq(rect.y, CHIP_RECT.y)
    assert(prefers_pop_down == true, "opens below the bar")
    -- Resizing DOES change the layout, so this one still rebuilds the shelf.
    findButton(dialog, "+10").callback()
    assert(bw.rebuild_count > 0, "a font-size change must still rebuild the shelf")
end)

t.test("a colour nudge with no live chip bar falls back to a shelf rebuild", function()
    resetStore()
    ui_calls = {}
    local bw = makeBw()          -- no _chip_bar (bar hidden / shelf not built)
    Settings._bw, Settings._plugin = bw, makePlugin()
    local row
    for _, item in ipairs(Settings:_colorsSubItems()) do
        if item.text_func and item.text_func():find("Selected chip fill", 1, true) then
            row = item
        end
    end
    row.callback(makeTouchMenu())
    local dialog
    for _, c in ipairs(ui_calls) do
        if c.op == "show" and c.w and c.w.buttons then dialog = c.w end
    end
    findButton(dialog, "+10").callback()
    assert(bw.rebuild_count > 0,
        "with nothing to recolour in place, the shelf rebuild is the fallback")
end)

-- ── "Reset to default colors" must cover every colour row ───────────────────
-- The reset row carries a hand-written key list, so a new colour row silently
-- falls outside it -- which is what happened to the selected-chip pair (#294):
-- Reset left them set. Comparing the list against the pickColor call sites in
-- the source catches the next omission at test time rather than on a device.
t.test("Reset to default colors clears every key a colour row can write", function()
    local f = assert(io.open("lib/bookshelf_settings.lua", "r"))
    local src = f:read("*a")
    f:close()

    local written = {}
    for key in src:gmatch('pickColor%("([%w_]+)"') do written[key] = true end
    assert(next(written), "found no pickColor call sites -- has the helper moved?")

    local block = src:match("Reset to default colors.-local keys = {(.-)}")
    assert(block, "could not find the reset row's key list")
    local cleared = {}
    for key in block:gmatch('"([%w_]+)"') do cleared[key] = true end

    local missing = {}
    for key in pairs(written) do
        if not cleared[key] then missing[#missing + 1] = key end
    end
    table.sort(missing)
    assert(#missing == 0,
        "Reset to default colors does not clear: " .. table.concat(missing, ", "))
end)

t.test("Reset clears the night variant of every colour key too", function()
    local f = assert(io.open("lib/bookshelf_settings.lua", "r"))
    local src = f:read("*a")
    f:close()
    -- Day and night colours are stored under separate keys (base and
    -- base .. "_night"), so a reset that only clears one leaves the other mode
    -- looking untouched.
    local body = src:match("Reset to default colors.-markDirty%(%)")
    assert(body and body:find('BookshelfSettings.delete(k .. "_night")', 1, true),
        "reset must delete the _night variant alongside each base key")
end)

t.test("_pickLauncherButtons: Cancel restores every key it found unset", function()
    local _canvas, dialog = openLauncherCanvas()
    findButton(dialog, "-10").callback()          -- move it off the default
    assert(BookshelfSettings.read("reader_launcher_lift") ~= nil, "nudge did not persist")
    findButton(dialog, "Cancel").callback()
    eq(BookshelfSettings.read("reader_launcher_lift"), nil,
        "a key that was unset on open must be deleted again, not saved as 0")
end)

t.done()
