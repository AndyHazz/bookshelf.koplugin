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
-- getHeight as well as scaleBySize: the template field caps its own height
-- against the panel, because InputDialog does not clamp a stated text_height.
-- 1648 is the PW5's, so the cap is a real number rather than a degenerate one.
package.loaded["device"] = { screen = {
    scaleBySize = function(_s, n) return n end,
    getHeight   = function() return 1648 end,
} }

local shown = {}
-- _window_stack is maintained for real: the stray-tap guard (issue #364) asks
-- UIManager who is on top, so a stub that only recorded shows could not tell
-- "the dialog is the top widget" from "a picker is stacked over it" -- which
-- is the entire distinction under test.
local UI
UI = {
    _window_stack = {},
    show     = function(_self, w)
        shown[#shown + 1] = w
        UI._window_stack[#UI._window_stack + 1] = { widget = w }
    end,
    close    = function(_self, w)
        w._closed = true
        for i = #UI._window_stack, 1, -1 do
            if UI._window_stack[i].widget == w then
                table.remove(UI._window_stack, i)
            end
        end
    end,
    setDirty = function() end,
}
package.loaded["ui/uimanager"] = UI
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
        t.taps_reaching_dialog = 0
        function t:getInputText() return self._text end
        function t:setInputText(s) self._text = s end
        function t:reinit() self.reinits = self.reinits + 1 end
        function t:onCloseKeyboard() self.closed_keyboard = self.closed_keyboard + 1 end
        -- Stands in for KOReader's InputDialog:onTap with the keyboard already
        -- hidden: a tap outside the frame becomes onCloseDialog, which fires
        -- the button carrying id="close" (inputdialog.lua:737-744). The
        -- editor's Cancel carries that id, so reaching here IS the bug.
        function t:onTap()
            self.taps_reaching_dialog = self.taps_reaching_dialog + 1
            for _r, row in ipairs(self.buttons or {}) do
                for _c, b in ipairs(row) do
                    if b.id == "close" then b.callback(); return true end
                end
            end
        end
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
    press(dialog, "Regular")   -- the style cycle's first state
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

t.test("the style button cycles all four weight/slant states", function()
    -- One button, not a Bold toggle plus an Italic toggle: this row has five
    -- slots and the four states are naturally ordered.
    local dialog, getSaved = open{ line = { template = "x" } }
    local function style() return button(dialog, "Regular") or
        button(dialog, "Bold") or button(dialog, "Italic") or
        button(dialog, "Bold italic") end
    assert(button(dialog, "Regular"), "a fresh line is not Regular")
    style().callback()
    assert(button(dialog, "Bold"), "Regular did not go to Bold")
    style().callback()
    assert(button(dialog, "Italic"), "Bold did not go to Italic")
    style().callback()
    assert(button(dialog, "Bold italic"), "Italic did not go to Bold italic")
    press(dialog, "Save")
    local d = getSaved()
    assert(d.bold == true and d.italic == true, "bold italic did not save both")
    -- ...and wraps back to Regular.
    local d2, getSaved2 = open{ line = { template = "x", bold = true, italic = true } }
    button(d2, "Bold italic").callback()
    press(d2, "Save")
    local s2 = getSaved2()
    assert(s2.bold == false and s2.italic == false, "the cycle did not wrap")
end)

t.test("a caller that cannot render italic keeps a plain Bold toggle",
function()
    -- No surface should offer a control that does nothing.
    local dialog, getSaved = open{ line = { template = "x" }, italic = false }
    assert(button(dialog, "Bold"), "the Bold toggle is missing")
    assert(button(dialog, "Regular") == nil, "the four-way cycle leaked in")
    press(dialog, "Bold")
    press(dialog, "Save")
    local d = getSaved()
    assert(d.bold == true)
    assert(d.italic == nil, "italic was set on a caller that cannot render it")
end)

t.test("case toggles, and alignment cycles through three", function()
    local dialog, getSaved = open{ line = { template = "x" } }
    press(dialog, "Aa")
    -- The alignment button is a glyph, so it is found by position: last button
    -- of the first row.
    local align = dialog.buttons[1][#dialog.buttons[1]]
    align.callback()  -- left -> center
    align.callback()  -- center -> right
    press(dialog, "Save")
    local d = getSaved()
    eq(d.uppercase, true)
    eq(d.alignment, "right")
    -- ...and wraps.
    local dialog2, getSaved2 = open{ line = { template = "x", alignment = "right" } }
    dialog2.buttons[1][#dialog2.buttons[1]].callback()
    press(dialog2, "Save")
    eq(getSaved2().alignment, "left", "alignment did not wrap")
end)

t.test("alignment goes dead on a line that has given its width away",
function()
    -- Alignment was reported as broken. It is not -- it was being set on lines
    -- carrying %spacer, where the two halves are already pinned to the edges
    -- and there is no slack left to move anything into. The control says so
    -- now, the same way the bar controls grey out with no %bar to configure.
    local function alignOf(dlg) return dlg.buttons[1][#dlg.buttons[1]] end

    local plain = open{ line = { template = "%title" } }
    assert(alignOf(plain).enabled_func() == true,
        "alignment was dead on an ordinary line")

    for _i, tpl in ipairs({ "%authors%spacer%book_pct", "%title %bar",
                            "%authors %spacer %bar{rel}" }) do
        local d = open{ line = { template = tpl } }
        assert(alignOf(d).enabled_func() == false,
            "alignment stayed live on: " .. tpl)
    end

    -- It follows the LIVE text, not the saved template: typing a spacer in
    -- must kill the control without closing and reopening the editor.
    local live = open{ line = { template = "%title" } }
    live:setInputText("%title%spacer%format")
    assert(alignOf(live).enabled_func() == false,
        "alignment ignored a spacer typed into the field")
end)

t.test("the case toggle can be suppressed, and only it", function()
    -- The hero's description region has no case toggle: uppercasing a long
    -- blurb is hostile.
    local dialog = open{ line = { template = "x" }, uppercase = false }
    assert(button(dialog, "Aa") == nil, "the case toggle survived uppercase=false")
    assert(button(dialog, "Regular"),
        "suppressing the case toggle removed the style button too")
    assert(button(dialog, "Save"))
end)

t.test("size, font and alignment can each be hidden, leaving the rest", function()
    -- The cover label draws one line in the strip's own face and size,
    -- centred: offering Size / Font / alignment there would be controls that
    -- do nothing. Each flag removes its own button and no other.
    local function alignOf(d)
        for _r, row in ipairs(d.buttons or {}) do
            for _c, b in ipairs(row) do
                if b.font_face == "symbols" then return b end
            end
        end
    end
    local full = open{ line = { template = "x", font_size = 14 } }
    assert(button(full, "Size: 14"), "the Size button is missing by default")
    assert(button(full, "Font\xE2\x80\xA6"), "the Font button is missing by default")
    assert(alignOf(full), "the alignment button is missing by default")

    local bare = open{ line = { template = "x", font_size = 14 },
                       size = false, font = false, alignment = false, italic = false }
    assert(button(bare, "Size: 14") == nil, "size=false left the Size button")
    assert(button(bare, "Font\xE2\x80\xA6") == nil, "font=false left the Font button")
    assert(alignOf(bare) == nil, "alignment=false left the alignment button")
    assert(button(bare, "Bold"), "hiding the others removed the Bold toggle")
    assert(button(bare, "Aa"), "hiding the others removed the case toggle")
    assert(button(bare, "Save") and button(bare, "Tokens\xE2\x80\xA6"),
        "hiding style controls touched the action row")
end)

t.test("the token picker is handed the caller's filter", function()
    local got_dialog, got_filter
    local settings = { _pickToken = function(_self, d, f) got_dialog, got_filter = d, f end }
    local function keep(_e) return true end
    local dialog = open{ line = { template = "x" }, settings_module = settings,
                         token_filter = keep }
    press(dialog, "Tokens\xE2\x80\xA6")
    assert(got_dialog == dialog, "the picker was not given the dialog to insert into")
    assert(got_filter == keep, "the caller's token filter did not reach the picker")
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
    -- The button names the style by its label (bookends' names), not its id.
    local style = button(dialog, "Bar: Bordered")
    assert(style, "the style button did not report the current style")
    style.callback()
    eq(button(dialog, "Bar: Solid") ~= nil, true)
    style.callback()
    eq(button(dialog, "Bar: Wave") ~= nil, true, "wavy must show as Wave")
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

t.test("the template field is four lines tall, capped against the panel",
function()
    -- The stubbed scaleBySize is the identity and the panel is 1648, so four
    -- lines is 4 * 30 = 120 and the cap is 329. The number matters less than
    -- the pair of properties: more than the two lines it shipped with, and
    -- bounded -- InputDialog uses a stated text_height as given, with no
    -- clamp of its own (inputdialog.lua:290), so an unbounded value pushes the
    -- buttons off a small panel once the keyboard is up.
    local dialog = open{ line = { template = "x" } }
    eq(dialog.text_height, 120)

    -- Same editor on a phone-sized panel: the cap bites and the field shrinks
    -- rather than eating the dialog.
    local screen = package.loaded["device"].screen
    local tall   = screen.getHeight
    screen.getHeight = function() return 400 end
    local small = open{ line = { template = "x" } }
    screen.getHeight = tall
    eq(small.text_height, 80, "the cap must bound the field on a short panel")
    assert(small.text_height >= 60,
        "never below the two lines the editor shipped with")
end)

-- ── Stray taps while a picker is stacked on top (issue #364) ───────────────

t.test("a tap the dialog owns still reaches it", function()
    -- The guard must not disarm the dialog's own tap handling, or tapping
    -- outside an editor with no picker open would stop closing it.
    local dialog, _getSaved, getCancelled = open{ line = { template = "x" } }
    dialog:onTap(nil, {})
    eq(dialog.taps_reaching_dialog, 1)
    eq(getCancelled(), 1, "an owned tap should still cancel the editor")
end)

t.test("a tap declined by a picker above does not cancel the editor", function()
    -- The reported sequence: Tokens… / Icons… opens a modal, an imprecise tap
    -- lands inside that modal but on no row, LibraryModal returns false, and
    -- KOReader's always-active walk hands it to the editor underneath -- which
    -- reads it as "tap outside my frame" and fires Cancel. The editor then
    -- vanishes behind the picker, restoreMenu puts the top menu back, and every
    -- later pick previews but can never be saved.
    local dialog, getSaved, getCancelled = open{ line = { template = "x" } }
    local picker = { name = "picker" }
    UI:show(picker)

    dialog:onTap(nil, {})
    eq(dialog.taps_reaching_dialog, 0, "the tap belonged to the picker")
    eq(getCancelled(), 0, "a stray tap cancelled the editor")
    assert(not dialog._closed, "a stray tap closed the editor")

    -- Picking a token after the stray tap must still be savable.
    UI:close(picker)
    dialog:setInputText("x%file_size")
    press(dialog, "Save")
    eq(getSaved().template, "x%file_size")
end)

t.test("the dialog's own keyboard on top does not disarm the guard", function()
    -- InputDialog is flagged is_always_active precisely so a tap that misses a
    -- key on its OWN keyboard -- a separate window above it -- still reaches
    -- it. The guard has to let that through or the board stops hiding.
    local dialog = open{ line = { template = "x" } }
    local keyboard = { name = "keyboard" }
    dialog._input_widget = { keyboard = keyboard }
    UI:show(keyboard)
    dialog:onTap(nil, {})
    eq(dialog.taps_reaching_dialog, 1, "the dialog's own keyboard blocked its taps")
end)

t.test("a toast above the dialog is looked past", function()
    -- Toasts sit on top by contract and never own an event, so a Notification
    -- must not make every tap look like it belongs to somebody else.
    local dialog, _getSaved, getCancelled = open{ line = { template = "x" } }
    UI:show({ name = "toast", toast = true })
    dialog:onTap(nil, {})
    eq(dialog.taps_reaching_dialog, 1, "a toast swallowed the dialog's taps")
    eq(getCancelled(), 1)
end)

t.done()
