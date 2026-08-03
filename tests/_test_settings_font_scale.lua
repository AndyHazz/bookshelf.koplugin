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
    close    = function(_, w) ui_calls[#ui_calls + 1] = { op = "close", w = w } end,
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

t.done()
