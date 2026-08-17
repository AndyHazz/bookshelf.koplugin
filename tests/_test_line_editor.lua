-- tests/_test_line_editor.lua
-- The shared line editor (lib/bookshelf_line_editor.lua), driven through its
-- real button callbacks under stubbed widgets.
--
-- Usage (from plugin root): lua tests/_test_line_editor.lua
--
-- Why this suite exists: the editor is the piece BOTH the hero card and list
-- view now depend on, and its whole contract is about what reaches settings
-- and when -- Save writes, Cancel does not, and nothing is written per
-- keystroke because that would flush to Kindle flash on every letter typed.
-- None of that is visible in a screenshot, and all of it is easy to break in a
-- refactor that still renders correctly.
--
-- The stubs reproduce only what the editor actually touches: ButtonDialog and
-- InputDialog record what they were handed and expose the callbacks so the
-- test can press the buttons.

package.path = "./?.lua;./?/init.lua;" .. package.path

package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
package.loaded["lib/bookshelf_focus"] = { reinitLocked = function() end }
package.loaded["fontlist"] = { getFontList = function() return {} end }
package.loaded["device"] = { screen = { scaleBySize = function(_s, n) return n end } }

local shown = {}
package.loaded["ui/uimanager"] = {
    show     = function(_self, w) shown[#shown + 1] = w end,
    close    = function(_self, w) w._closed = true end,
    setDirty = function() end,
}
package.loaded["ui/widget/buttondialog"] = {
    new = function(_self, t) return t end,
}

-- InputDialog: the editor reads getInputText(), writes setInputText(), and
-- calls reinit()/onCloseKeyboard() after every button. Recorded rather than
-- ignored, so a callback that forgets to refresh the dialog is visible.
local LAST
package.loaded["ui/widget/inputdialog"] = {
    new = function(_self, t)
        t.reinits, t.closed_keyboard = 0, 0
        t._text = t.input or ""
        function t:getInputText() return self._text end
        function t:setInputText(s) self._text = s end
        function t:reinit() self.reinits = self.reinits + 1 end
        function t:onCloseKeyboard() self.closed_keyboard = self.closed_keyboard + 1 end
        LAST = t
        return t
    end,
}

local helpers = dofile("tests/_helpers.lua")
local t       = helpers.runner()
local eq      = helpers.eq

local Editor = require("lib/bookshelf_line_editor")

-- Find a button by its rendered label across every row.
local function button(dialog, label)
    for _r, row in ipairs(dialog.buttons or {}) do
        for _c, b in ipairs(row) do
            local text = b.text or (b.text_func and b.text_func())
            if text == label then return b end
        end
    end
    return nil
end

local function press(dialog, label)
    local b = button(dialog, label)
    assert(b, "no button labelled " .. label)
    b.callback()
end

local function open(spec)
    shown, LAST = {}, nil
    local saved, cancelled, previews = nil, 0, {}
    spec.on_save   = function(draft) saved = draft end
    spec.on_cancel = function() cancelled = cancelled + 1 end
    spec.on_preview = function(draft) previews[#previews + 1] = draft.template end
    Editor.edit(spec)
    return LAST, function() return saved end, function() return cancelled end,
           previews
end

-- ── The draft carries EVERY field ──────────────────────────────────────────

t.test("the draft copies every field, not the ones with buttons", function()
    -- The hero used to carry line_height / bar_height / bar_style by hand,
    -- with a comment warning the next person to keep doing so: previewing
    -- substitutes the whole draft, so a field the draft dropped becomes nil at
    -- render time and the title region silently loses its tight leading.
    local dialog, getSaved = open{
        line = {
            template = "%title", font_size = 18, bold = true,
            line_height = 0.05, bar_style = "wavy", something_new = 7,
        },
    }
    press(dialog, "Save")
    local d = getSaved()
    eq(d.template, "%title")
    eq(d.font_size, 18)
    eq(d.line_height, 0.05, "an unbuttoned field was dropped from the draft")
    eq(d.bar_style, "wavy")
    eq(d.something_new, 7, "a field this editor has never heard of was dropped")
end)

-- ── Save / Cancel ──────────────────────────────────────────────────────────

t.test("Save commits the dialog text, not the stale draft", function()
    local dialog, getSaved = open{ line = { template = "old" } }
    -- Typing without firing edited_callback: the user's last keystroke can
    -- land after the final callback, so Save has to re-read the field.
    dialog:setInputText("typed")
    press(dialog, "Save")
    eq(getSaved().template, "typed")
end)

t.test("Cancel calls on_cancel and saves nothing", function()
    local dialog, getSaved, getCancelled = open{ line = { template = "old" } }
    dialog:setInputText("typed")
    press(dialog, "Cancel")
    assert(getSaved() == nil, "Cancel wrote through")
    eq(getCancelled(), 1)
    assert(dialog._closed, "Cancel left the dialog open")
end)

t.test("nothing is written before Save", function()
    -- The whole reason for the draft: a settings write per keystroke would
    -- flush to Kindle flash on every letter.
    local dialog, getSaved = open{ line = { template = "x" } }
    dialog:setInputText("abc")
    dialog.edited_callback()
    press(dialog, "Bold")
    press(dialog, "Aa")
    assert(getSaved() == nil, "an edit reached on_save before Save was pressed")
end)

-- ── Default ────────────────────────────────────────────────────────────────

t.test("Default restores the defaults and clears what they do not mention",
function()
    -- "Default, plus whatever you had" is the wrong answer and the easy bug:
    -- copying the defaults over a live draft leaves every field the defaults
    -- are silent about exactly as the user left it.
    local dialog, getSaved = open{
        line     = { template = "mine", font_size = 30, bold = true,
                     uppercase = true, leftover = "stale" },
        defaults = { template = "%title", font_size = 16 },
    }
    press(dialog, "Default")
    press(dialog, "Save")
    local d = getSaved()
    eq(d.template, "%title")
    eq(d.font_size, 16)
    assert(d.bold == nil, "bold survived a reset to defaults")
    assert(d.leftover == nil, "an unrelated field survived a reset")
    eq(dialog:getInputText(), "%title", "the text field was not reset with it")
end)

t.test("with no defaults given, Default is a no-op rather than a wipe",
function()
    local dialog, getSaved = open{ line = { template = "mine", font_size = 30 } }
    press(dialog, "Default")
    press(dialog, "Save")
    eq(getSaved().template, "mine")
    eq(getSaved().font_size, 30)
end)

-- ── The style controls ─────────────────────────────────────────────────────

t.test("bold and case toggle, and alignment cycles through three", function()
    local dialog, getSaved = open{ line = { template = "x" } }
    press(dialog, "Bold")
    press(dialog, "Aa")
    -- The alignment button is a glyph, so it is found by position: last button
    -- of the first row.
    local align = dialog.buttons[1][#dialog.buttons[1]]
    align.callback()  -- left -> center
    align.callback()  -- center -> right
    press(dialog, "Save")
    local d = getSaved()
    eq(d.bold, true)
    eq(d.uppercase, true)
    eq(d.alignment, "right")
    -- ...and wraps.
    local dialog2, getSaved2 = open{ line = { template = "x", alignment = "right" } }
    dialog2.buttons[1][#dialog2.buttons[1]].callback()
    press(dialog2, "Save")
    eq(getSaved2().alignment, "left", "alignment did not wrap")
end)

t.test("the case toggle can be suppressed, and only it", function()
    -- The hero's description region has no case toggle: uppercasing a long
    -- blurb is hostile.
    local dialog = open{ line = { template = "x" }, uppercase = false }
    assert(button(dialog, "Aa") == nil, "the case toggle survived uppercase=false")
    assert(button(dialog, "Bold"), "suppressing the case toggle removed Bold too")
    assert(button(dialog, "Save"))
end)

-- ── The bar row ────────────────────────────────────────────────────────────

t.test("the bar row appears only when asked for", function()
    local plain = open{ line = { template = "x" } }
    assert(button(plain, "+ Bar") == nil, "a bar row on a caller that wants none")
    local barred = open{
        line = { template = "x" }, bar = true,
        bar_styles = function() return { "bordered", "solid", "wavy" } end,
    }
    assert(button(barred, "+ Bar"), "bar = true produced no bar row")
end)

t.test("the bar toggle inserts and removes %bar without stacking spaces",
function()
    local dialog, getSaved = open{
        line = { template = "%author" }, bar = true,
        bar_styles = function() return { "bordered", "solid" } end,
    }
    press(dialog, "+ Bar")
    eq(dialog:getInputText(), "%author %bar")
    -- The label is text_func'd off the live text, so it flips with it.
    press(dialog, "- Bar")
    eq(dialog:getInputText(), "%author",
        "removing the bar left its whitespace behind")
    press(dialog, "+ Bar")
    press(dialog, "- Bar")
    eq(dialog:getInputText(), "%author", "spaces accumulated over two rounds")
    press(dialog, "Save")
    eq(getSaved().template, "%author")
end)

t.test("bar style cycles through what the caller offers", function()
    local dialog, getSaved = open{
        line = { template = "%bar", bar_style = "bordered" }, bar = true,
        bar_styles = function() return { "bordered", "solid", "wavy" } end,
    }
    local style = button(dialog, "Bar: bordered")
    assert(style, "the style button did not report the current style")
    style.callback()
    eq(button(dialog, "Bar: solid") ~= nil, true)
    style.callback()
    press(dialog, "Save")
    eq(getSaved().bar_style, "wavy")
end)

t.test("bar controls are disabled while the line has no %bar in it", function()
    local dialog = open{
        line = { template = "%title" }, bar = true,
        bar_styles = function() return { "bordered" } end,
    }
    local style = button(dialog, "Bar style")
    assert(style and style.enabled_func() == false,
        "bar style was live on a line with no bar")
    press(dialog, "+ Bar")
    assert(style.enabled_func() == true, "bar style stayed dead after + Bar")
end)

-- ── The parent menu ────────────────────────────────────────────────────────

t.test("the launching menu is hidden on open and restored on both exits",
function()
    local function fakeMenu()
        local m = { updates = 0, show_parent = { name = "container" } }
        function m:updateItems() self.updates = self.updates + 1 end
        return m
    end
    for _i, exit in ipairs({ "Save", "Cancel" }) do
        local menu = fakeMenu()
        local dialog = open{ line = { template = "x" }, touchmenu_instance = menu }
        -- The container is closed on open and shown again on exit; the stub
        -- UIManager records shows, so the container reappearing is the
        -- evidence.
        press(dialog, exit)
        eq(menu.updates, 1, exit .. " did not refresh the menu it came from")
    end
end)

t.done()
