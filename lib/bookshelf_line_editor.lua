-- bookshelf_line_editor.lua
-- The line editor, with no opinion about what it is editing.
--
-- ── WHY THIS EXISTS ────────────────────────────────────────────────────────
--
-- The hero card has had a per-region line editor since 3.x: a template field
-- with a live preview, a font picker, a bookends-style size nudge, weight and
-- case toggles, an alignment cycle, and the token / icon pickers. List view
-- now needs the SAME editor for its rows -- the maintainer's words: "I think
-- it will be best for the long run to use the bookends style row editors,
-- allowing far more choice over content, formatting, size."
--
-- The two surfaces edit the same shape (template + face + size + bold +
-- uppercase + alignment), so this is one editor with two callers, not two
-- editors that will drift. What differs between them is entirely:
--
--   * where the value comes from and goes back to  -> spec.line / spec.on_save
--   * what "live preview" means                    -> spec.on_preview
--   * which optional controls are on the button rows
--
-- all of which the caller supplies. Nothing in here knows what a hero region
-- or a list line is.
--
-- ── THE DRAFT ──────────────────────────────────────────────────────────────
--
-- Edits land on an in-memory draft, never on settings: a write per keystroke
-- would flush to disk on every letter typed and chew Kindle flash. Settings
-- are touched exactly once, in on_save.
--
-- The draft is a COPY OF EVERY FIELD on spec.line, not of the fields this
-- editor has buttons for. That distinction is load-bearing and was learned the
-- hard way on the hero: previewing substitutes the whole draft for the stored
-- value, so any field the draft failed to carry becomes nil at render time.
-- The hero's title region relies on line_height = 0.05 for its tight leading,
-- and dropping it produced visibly looser wrapping the moment the user toggled
-- bold. Copying wholesale makes that class of bug unreachable rather than
-- guarded against.
--
-- ── CANCEL ─────────────────────────────────────────────────────────────────
--
-- Cancel calls on_cancel and closes. Because nothing is written until Save,
-- on_cancel's only job is to undo the PREVIEW -- it does not have to restore
-- settings. The hero passes a restore anyway, as a safety net in case some
-- other surface wrote while the editor was open.

local InputDialog = require("ui/widget/inputdialog")
local UIManager   = require("ui/uimanager")
local Focus       = require("lib/bookshelf_focus")
local FontList    = require("fontlist")
local Screen      = require("device").screen
local _           = require("lib/bookshelf_i18n").gettext

local LineEditor = {}

-- Cycle helper. Returns the next entry in `list` after `current`, wrapping
-- around. If current is not found, returns list[1].
-- ── How tall the template field is ─────────────────────────────────────────
--
-- FOUR lines, not the two it shipped with. The maintainer's reason: "these
-- strings are getting longer and harder to understand, made harder by only
-- seeing two lines at a time" -- a default subtitle already carries a nested
-- [if:…] block, and inline style tags make them longer again. Seeing the whole
-- template at once is the difference between editing it and hunting through it.
--
-- The cap is not decoration. InputDialog only works out a safe height when
-- text_height is UNSET (inputdialog.lua:290: "if not self.text_height"); state
-- one and it is used as given, with no clamp, so an over-large request would
-- push the buttons off a 600x800 panel once the virtual keyboard is up. A
-- fifth of the panel leaves room for the title, the two button rows and the
-- keyboard on the smallest device the plugin runs on.
local INPUT_LINE_DP   = 30    -- what the shipped scaleBySize(60) called a line
local INPUT_LINES     = 4
local INPUT_MAX_SHARE = 0.2

local function inputHeight()
    local line = Screen:scaleBySize(INPUT_LINE_DP)
    local cap  = math.floor(Screen:getHeight() * INPUT_MAX_SHARE)
    return math.max(line * 2, math.min(line * INPUT_LINES, cap))
end

local function cycleNext(list, current)
    for i, v in ipairs(list) do
        if v == current then return list[(i % #list) + 1] end
    end
    return list[1]
end

local ALIGN_CYCLE  = { "left", "center", "right" }
-- Nerd Font / Symbols MDI glyphs for alignment. Same family as the
-- battery / wifi / nightmode icons so the row reads coherently.
--   U+E961 format-align-left   → \xEE\xA5\xA1
--   U+E95F format-align-center → \xEE\xA5\x9F
--   U+E962 format-align-right  → \xEE\xA5\xA2
local ALIGN_LABELS = {
    left   = "\xEE\xA5\xA1",
    center = "\xEE\xA5\x9F",
    right  = "\xEE\xA5\xA2",
}

-- showSizeNudge — bookends-style ±1 / ±5 nudge dialog for the font_size
-- field. Calls on_change(value) on each tap, on_close() when dismissed.
-- Pattern matches bookends's showNudgeDialog (main.lua:1909): a disabled
-- text_func button shows the live value, and dialog:reinit() rebuilds
-- the row so the value updates after every nudge — ButtonDialog has no
-- public setTitle, so the title stays static.
local function showSizeNudge(current, default, on_change, on_close, opts)
    -- opts (optional): { min, max, step_small, step_big, unit, title }
    -- Defaults match the original font-size nudge call site.
    opts = opts or {}
    local min        = opts.min or 8
    local max        = opts.max or 48
    local step_small = opts.step_small or 1
    local step_big   = opts.step_big or 5
    local unit       = opts.unit or " px"
    local title      = opts.title or _("Font size")
    local ButtonDialog = require("ui/widget/buttondialog")
    local d
    -- After reinit, dirty-mark the dialog so the e-ink panel refreshes
    -- its rect on the next paint cycle. Without this, on_change's
    -- region-scoped setDirty (which targets the hero strip only) leaves
    -- the dialog's rect untouched and the displayed value stays frozen.
    local function refresh_dialog()
        if d then
            Focus.reinitLocked(d)
            UIManager:setDirty(d, "ui")
        end
    end
    local function nudge(delta)
        current = math.max(min, math.min(max, current + delta))
        on_change(current)
        refresh_dialog()
    end
    d = ButtonDialog:new{
        -- dismissable=false + movable.ges_events wipe below: matches
        -- the lockdown applied to every nudge dialog in
        -- bookshelf_settings.lua (see _pickCoverBadgeFontScale for
        -- the rationale). Same reasoning: rapid taps near +/- shouldn't
        -- fall through to the modal background and dismiss mid-edit,
        -- and a long-press on a button shouldn't toggle the dialog to
        -- 70% alpha via MovableContainer.
        dismissable = false,
        title = title,
        buttons = {
            {
                { text = "-" .. tostring(step_big),   callback = function() nudge(-step_big)   end },
                { text = "-" .. tostring(step_small), callback = function() nudge(-step_small) end },
                { text_func = function() return tostring(current) .. unit end,
                  enabled = false },
                { text = "+" .. tostring(step_small), callback = function() nudge(step_small)  end },
                { text = "+" .. tostring(step_big),   callback = function() nudge(step_big)    end },
            },
            {
                { text = _("Default"), callback = function()
                    current = default
                    on_change(current)
                    refresh_dialog()
                end },
                { text = _("Close"), is_enter_default = true,
                  callback = function() UIManager:close(d); on_close() end },
            },
        },
    }
    if d.movable then d.movable.ges_events = {} end
    UIManager:show(d)
end

-- showFontPicker — uses the bookends picker (richer UI: previews each
-- family in its own typeface, dedupes weight variants) when bookends is
-- loaded. Falls back to a plain FontList Menu when it isn't.
--
-- The bookends class is the return value of bookends/main.lua, which the
-- KOReader plugin loader stashes on PluginLoader.enabled_plugins (it uses
-- dofile, NOT require, so package.loaded["main"] is empty). We grab the
-- class by name and invoke showFontPicker as a static call with an empty
-- self table — the function only uses self.frame for tap-outside dismissal,
-- a transient field that doesn't need a real Bookends instance.
local function showFontPicker(current_face, default_face, on_select)
    -- Bookends's picker injects "@family:serif" / "@family:fantasy" /
    -- "@family:cursive" sentinel rows that resolve via KOReader's CRengine
    -- font_family settings — that resolution only happens inside the
    -- Reader context, where bookshelf doesn't run. Filter those out at
    -- the callback boundary with a friendly message instead of letting
    -- the literal string flow through to Font:getFace and crash render.
    local function safe_select(file)
        if type(file) == "string" and file:match("^@family:") then
            local InfoMessage = require("ui/widget/infomessage")
            UIManager:show(InfoMessage:new{
                text = _("Font-family fonts (serif, sans-serif, etc.) only resolve inside the Reader view. Pick a specific font file instead."),
                timeout = 3,
            })
            return
        end
        on_select(file)
    end
    local ok_pl, PluginLoader = pcall(require, "pluginloader")
    if ok_pl and PluginLoader and PluginLoader.enabled_plugins then
        for _i, plugin in ipairs(PluginLoader.enabled_plugins) do
            if plugin.name == "bookends" and type(plugin.showFontPicker) == "function" then
                -- include_family = false suppresses the "@family:" sentinel
                -- rows that bookends would otherwise prepend. Newer bookends
                -- (feature/font-picker-opts → master) honours the option;
                -- older bookends ignores extra args, in which case safe_select
                -- catches any "@family:" tap with the toast fallback.
                local ok = pcall(plugin.showFontPicker, {}, current_face,
                    safe_select, default_face, { include_family = false })
                if ok then return end
                break -- bookends present but the call failed; fall through to fallback
            end
        end
    end
    -- Fallback: native KOReader FontList as a full-screen Menu. Modelled on
    -- KOReader's filemanagershortcuts menu: covers_fullscreen + is_borderless,
    -- shown without manual positioning so MenuItem tap ranges line up, and a
    -- close_callback so selecting (or tapping the title-bar close) dismisses it
    -- -- the generic Menu only closes via close_callback (onMenuSelect).
    local Menu   = require("ui/widget/menu")
    local items  = { { text = _("(Default)"), callback = function() safe_select(nil) end } }
    for _i, file in ipairs(FontList:getFontList() or {}) do
        items[#items + 1] = { text = file, callback = function() safe_select(file) end }
    end
    local menu
    menu = Menu:new{
        title             = _("Pick font"),
        item_table        = items,
        covers_fullscreen = true,
        is_borderless     = true,
        is_popout         = false,
    }
    menu.close_callback = function() UIManager:close(menu) end
    UIManager:show(menu)
end

-- Shows the bundled icons library picker. Dynamic %tokens stay available
-- here: the picked value lands in a token template, which IS expanded
-- through lib/bookshelf_tokens.lua at render time.
local function showIconsLibrary(dialog)
    local IconsLibrary = require("lib/bookshelf_icons_library")
    IconsLibrary:show(function(value)
        if dialog and dialog.addTextToInput then
            pcall(function() dialog:addTextToInput(value) end)
        end
    end)
end

-- Hide a TouchMenu while a transient dialog is open and return a closure
-- that re-shows it + refreshes its rows. Mirrors bookends's
-- DialogHelpers.hideParentMenu (bookends_dialog_helpers.lua:10-19): the
-- thing actually on the UIManager stack is `touchmenu_instance.show_parent`
-- (a CenterContainer wrapping the TouchMenu), not the TouchMenu itself.
local function hideParentMenu(touchmenu_instance)
    if not touchmenu_instance then return function() end end
    local container = touchmenu_instance.show_parent or touchmenu_instance
    UIManager:close(container, "ui")
    return function()
        UIManager:show(container)
        if touchmenu_instance.updateItems then
            touchmenu_instance:updateItems()
        end
    end
end

-- Returns true iff the current dialog text contains the %bar token.
local function hasBarToken(dialog)
    if not dialog then return false end
    local t = dialog:getInputText() or ""
    return t:find("%%bar") ~= nil
end

-- Either elastic token. Both make the line exactly as wide as its box, which
-- is what leaves an alignment nothing to move.
local function hasElasticToken(dialog)
    if not dialog then return false end
    local t = dialog:getInputText() or ""
    return t:find("%%bar") ~= nil or t:find("%%spacer") ~= nil
end

-- Insert / remove %bar from the dialog text. Collapses surrounding
-- whitespace so toggling on and off doesn't accumulate spaces.
local function toggleBarToken(dialog, draft, applyLivePreview)
    if not dialog then return end
    local text = dialog:getInputText() or ""
    if text:find("%%bar") then
        text = text:gsub("%s*%%bar%s*", " "):gsub("^%s+", ""):gsub("%s+$", "")
    else
        if text == "" then
            text = "%bar"
        else
            text = text .. " %bar"
        end
    end
    if dialog.setInputText then dialog:setInputText(text) end
    draft.template = text
    applyLivePreview()
end

-- ── The editor ─────────────────────────────────────────────────────────────
--
-- edit(spec) opens the dialog. Every field:
--
--   title         dialog title. Required in practice; falls back to "Edit".
--   line          the value being edited. Every field is copied to the draft.
--   defaults      what the Default button restores. Defaults to `line`, which
--                 makes Default a no-op rather than a field-wiper when a
--                 caller has nothing meaningful to restore to.
--   uppercase     show the Aa/AA case toggle (default true).
--   bar           show the %bar controls row (default false). Progress-shaped
--                 regions only.
--   bar_styles    function returning the cycle of bar style names. Required
--                 when bar is true.
--   settings_module  the Settings handle, for the "Tokens…" picker.
--   touchmenu_instance  the menu we were launched from; hidden while open so
--                 the live preview is visible, re-shown on Save/Cancel.
--   on_preview(draft)  called on every edit. Optional.
--   on_save(draft)     called once, on Save. Required to persist anything.
--   on_cancel()        called on Cancel, to undo the preview. Optional.
--
-- The draft handed to the callbacks is the editor's live table. Callers that
-- keep it past the call must copy it.
function LineEditor.edit(spec)
    spec = spec or {}
    local restoreMenu = hideParentMenu(spec.touchmenu_instance)
    local source   = spec.line or {}
    local defaults = spec.defaults or source

    -- Copy EVERY field, not the ones with buttons. See the header.
    local draft = {}
    for k, v in pairs(source) do draft[k] = v end

    local dialog

    local function applyLivePreview()
        if spec.on_preview then spec.on_preview(draft) end
    end

    local function commitText()
        local text = dialog and dialog:getInputText() or draft.template
        draft.template = text or ""
    end

    -- Reset to defaults. Clears first: a draft field that the defaults do not
    -- mention is a leftover of the value being replaced, and leaving it behind
    -- makes "Default" mean "default, plus whatever you had".
    local function resetToDefaults()
        for k in pairs(draft) do draft[k] = nil end
        for k, v in pairs(defaults) do draft[k] = v end
        if dialog and dialog.setInputText then
            dialog:setInputText(draft.template or "")
        end
        applyLivePreview()
        if dialog then dialog:reinit() end
    end

    local function buildButtons()
        local rows = {}

        -- Row 1: text style controls.
        local style_row = {
            {
                -- ONE button cycling Regular -> Bold -> Italic -> Bold italic,
                -- rather than a Bold toggle plus an Italic toggle. Two toggles
                -- would cost two of the five slots this row has, and the four
                -- states are naturally ordered -- the maintainer asked for "the
                -- style button" to cover them all.
                --
                -- Callers that cannot render italic pass italic = false and get
                -- the plain Bold toggle back, so no surface offers a control
                -- that does nothing.
                text_func = function()
                    if spec.italic == false then
                        return draft.bold and (_("Bold") .. " \xE2\x9C\x93")
                            or _("Bold")
                    end
                    if draft.bold and draft.italic then return _("Bold italic") end
                    if draft.bold   then return _("Bold")    end
                    if draft.italic then return _("Italic")  end
                    return _("Regular")
                end,
                callback  = function()
                    if dialog then dialog:onCloseKeyboard() end
                    if spec.italic == false then
                        draft.bold = not draft.bold
                    elseif not draft.bold and not draft.italic then
                        draft.bold = true
                    elseif draft.bold and not draft.italic then
                        draft.bold, draft.italic = false, true
                    elseif draft.italic and not draft.bold then
                        draft.bold, draft.italic = true, true
                    else
                        draft.bold, draft.italic = false, false
                    end
                    applyLivePreview()
                    if dialog then dialog:reinit() end
                end,
            },
            {
                text_func = function() return _("Size") .. ": " .. (draft.font_size or "") end,
                callback  = function()
                    if dialog then dialog:onCloseKeyboard() end
                    showSizeNudge(
                        draft.font_size or defaults.font_size,
                        defaults.font_size,
                        function(val) draft.font_size = val; applyLivePreview() end,
                        function() if dialog then dialog:reinit() end end)
                end,
            },
            {
                text_func = function() return draft.font_face and _("Font \xE2\x9C\x93") or _("Font\xE2\x80\xA6") end,
                callback  = function()
                    if dialog then dialog:onCloseKeyboard() end
                    showFontPicker(draft.font_face, defaults.font_face,
                        function(file)
                            draft.font_face = file
                            applyLivePreview()
                            if dialog then dialog:reinit() end
                        end)
                end,
            },
        }
        if spec.uppercase ~= false then
            style_row[#style_row + 1] = {
                text_func = function() return draft.uppercase and "AA" or "Aa" end,
                callback  = function()
                    if dialog then dialog:onCloseKeyboard() end
                    draft.uppercase = not draft.uppercase
                    applyLivePreview()
                    if dialog then dialog:reinit() end
                end,
            }
        end
        style_row[#style_row + 1] = {
            text_func = function() return ALIGN_LABELS[draft.alignment or "left"] or ALIGN_LABELS.left end,
            -- Dead while the line carries %spacer or %bar, and saying so.
            --
            -- Either token makes the line exactly as wide as its box -- the
            -- spacer pushes the two halves to the edges, the bar fills what is
            -- left -- so there is no slack for an alignment to move anything
            -- into. The setting was reported as "doesn't work", and it does
            -- work; it was being tried on lines that had already given their
            -- width away. Greying the control is the honest answer, and it
            -- matches how the bar controls already behave when there is no
            -- %bar to configure.
            enabled_func = function() return not hasElasticToken(dialog) end,
            -- Render with the Symbols Nerd Font face so the MDI alignment
            -- codepoints resolve. Default button face would render them as
            -- tofu (missing-glyph boxes). Size matches eyeballed alongside
            -- the Latin text buttons in the same row.
            font_face = "symbols",
            font_size = 22,
            callback  = function()
                if dialog then dialog:onCloseKeyboard() end
                draft.alignment = cycleNext(ALIGN_CYCLE, draft.alignment or "left")
                applyLivePreview()
                if dialog then dialog:reinit() end
            end,
        }

        rows[#rows + 1] = style_row

        -- Row 2: bar controls, for callers whose line can carry a %bar.
        -- Spacer is an edge-case token reachable via the Tokens picker, not
        -- surfaced as a button here -- adding a "+ Spacer" toggle to every
        -- editor made the row noisy out of proportion to how often anyone
        -- needs it.
        if spec.bar then
            rows[#rows + 1] = {
                {
                    text_func = function()
                        if not hasBarToken(dialog) then return _("Bar style") end
                        return _("Bar: ") .. (draft.bar_style or "bordered")
                    end,
                    enabled_func = function() return hasBarToken(dialog) end,
                    callback = function()
                        if dialog then dialog:onCloseKeyboard() end
                        local styles = spec.bar_styles and spec.bar_styles() or {}
                        draft.bar_style = cycleNext(styles, draft.bar_style or "bordered")
                        applyLivePreview()
                        if dialog then dialog:reinit() end
                    end,
                },
                {
                    text_func = function()
                        return hasBarToken(dialog) and _("- Bar") or _("+ Bar")
                    end,
                    callback = function()
                        if dialog then dialog:onCloseKeyboard() end
                        toggleBarToken(dialog, draft, applyLivePreview)
                        if dialog then dialog:reinit() end
                    end,
                },
                {
                    text_func = function()
                        if not hasBarToken(dialog) then return _("Bar height") end
                        return _("Height: ") .. tostring(draft.bar_height or 100) .. "%"
                    end,
                    enabled_func = function() return hasBarToken(dialog) end,
                    callback = function()
                        if dialog then dialog:onCloseKeyboard() end
                        -- Percentage of the rendered text height. 100% = bar
                        -- matches the text exactly. Range 30-200% covers
                        -- "thin underline" through "double-height block".
                        showSizeNudge(
                            draft.bar_height or 100,
                            100,
                            function(val) draft.bar_height = val; applyLivePreview() end,
                            function() if dialog then dialog:reinit() end end,
                            { min = 30, max = 200, step_small = 5, step_big = 20,
                              unit = "%", title = _("Bar height") })
                    end,
                },
            }
        end

        -- Row 3: action row.
        rows[#rows + 1] = {
            {
                text     = _("Cancel"),
                id       = "close",
                callback = function()
                    if spec.on_cancel then spec.on_cancel() end
                    UIManager:close(dialog)
                    restoreMenu()
                end,
            },
            {
                text     = _("Tokens\xE2\x80\xA6"),
                callback = function()
                    if dialog then dialog:onCloseKeyboard() end
                    if spec.settings_module and spec.settings_module._pickToken then
                        spec.settings_module:_pickToken(dialog)
                    end
                end,
            },
            {
                text     = _("Icons\xE2\x80\xA6"),
                callback = function()
                    if dialog then dialog:onCloseKeyboard() end
                    showIconsLibrary(dialog)
                end,
            },
            {
                text     = _("Default"),
                callback = resetToDefaults,
            },
            {
                text             = _("Save"),
                is_enter_default = true,
                callback         = function()
                    commitText()
                    if spec.on_save then spec.on_save(draft) end
                    UIManager:close(dialog)
                    restoreMenu()
                end,
            },
        }
        return rows
    end

    dialog = InputDialog:new{
        title           = spec.title or _("Edit"),
        input           = draft.template,
        allow_newline   = true,
        text_height     = inputHeight(),
        edited_callback = function()
            -- Fires DURING InputDialog:init (initTextBox calls edit_callback
            -- before InputDialog:new returns), so `dialog` upvalue is still
            -- nil on the very first invocation. Guard required.
            if not dialog then return end
            local live = dialog:getInputText()
            if live ~= nil then
                draft.template = live
                applyLivePreview()
            end
        end,
        buttons = buildButtons(),
    }
    UIManager:show(dialog)
    return dialog
end

-- Shared helpers, exported because several settings surfaces want the exact
-- same nudge dialog / font picker / menu-hiding as the editor itself.
LineEditor.showFontPicker = showFontPicker
LineEditor.showSizeNudge  = showSizeNudge
LineEditor.hideParentMenu = hideParentMenu
LineEditor.cycleNext      = cycleNext
LineEditor.ALIGN_LABELS   = ALIGN_LABELS
LineEditor.ALIGN_CYCLE    = ALIGN_CYCLE

return LineEditor
