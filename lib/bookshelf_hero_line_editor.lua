-- bookshelf_hero_line_editor.lua
-- Per-region line editor for the hero card. Live preview is driven by
-- an in-memory `draft` table — settings are NOT written on every edit
-- (that would flush to disk on every keystroke and chew Kindle flash).
-- Settings are persisted only on Save; Cancel restores from the
-- entry-time snapshot as a safety net in case anything else wrote.

local InputDialog = require("ui/widget/inputdialog")
local UIManager   = require("ui/uimanager")
local Regions     = require("lib/bookshelf_hero_regions")
local FontList    = require("fontlist")
local Screen      = require("device").screen
local _           = require("lib/bookshelf_i18n").gettext

-- Cycle helper. Returns the next entry in `list` after `current`, wrapping
-- around. If current is not found, returns list[1].
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
            d:reinit()
            UIManager:setDirty(d, "ui")
        end
    end
    local function nudge(delta)
        current = math.max(min, math.min(max, current + delta))
        on_change(current)
        refresh_dialog()
    end
    d = ButtonDialog:new{
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
    -- Fallback: native KOReader FontList.
    local Menu   = require("ui/widget/menu")
    local Screen = require("device").screen
    local items  = { { text = _("(Default)"), callback = function() safe_select(nil) end } }
    for _i, file in ipairs(FontList:getFontList() or {}) do
        items[#items + 1] = { text = file, callback = function() safe_select(file) end }
    end
    local mw = math.floor(Screen:getWidth() * 0.85)
    local mh = math.floor(Screen:getHeight() * 0.7)
    local menu
    menu = Menu:new{
        title      = _("Pick font"),
        item_table = items,
        is_popout  = true,
        width      = mw,
        height     = mh,
    }
    local x = math.floor((Screen:getWidth() - mw) / 2)
    local y = math.floor((Screen:getHeight() - mh) / 2)
    UIManager:show(menu, nil, nil, x, y)
end

local HeroBar = require("lib/bookshelf_hero_bar")

-- Returns true iff the current dialog text contains the %bar token.
local function hasBarToken(dialog)
    if not dialog then return false end
    local t = dialog:getInputText() or ""
    return t:find("%%bar") ~= nil
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

-- Soft-imports bookends's icon library and shows the picker. Returns
-- false if bookends is missing (caller can hide the button entirely).
local function showIconsLibrary(dialog)
    local ok, IconsLibrary = pcall(require, "menu.icons_library")
    if not ok or not IconsLibrary or not IconsLibrary.show then return false end
    IconsLibrary:show(function(value)
        if dialog and dialog.addTextToInput then
            pcall(function() dialog:addTextToInput(value) end)
        end
    end)
    return true
end

local function bookendsIconsAvailable()
    local ok, IconsLibrary = pcall(require, "menu.icons_library")
    return ok and IconsLibrary and IconsLibrary.show ~= nil
end

local LineEditor = {}

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

-- show(region_key, bw, settings_module, touchmenu_instance)
--   region_key        — one of Regions.ORDER
--   bw                — live BookshelfWidget (live preview target). May be nil.
--   settings_module   — Settings handle (for the token picker fallback path).
--   touchmenu_instance — the FM TouchMenu we were launched from. The editor
--                       hides it on open so the user can see the live hero,
--                       and re-shows it on Save/Cancel.
function LineEditor.show(region_key, bw, settings_module, touchmenu_instance)
    local restoreMenu = hideParentMenu(touchmenu_instance)
    local snapshot = Regions.snapshot(region_key)
    local current  = Regions.read()[region_key]

    -- In-memory draft. Mutated on every keystroke / button tap; written
    -- to settings only on Save.
    local draft = {
        template  = current.template,
        font_face = current.font_face,
        font_size = current.font_size,
        bold      = current.bold,
        uppercase = current.uppercase,
        alignment = current.alignment,
        bar_height= current.bar_height,
        bar_style = current.bar_style,
    }

    local dialog

    -- Build a fully-populated regions table for the renderer: the four
    -- inactive regions come from Regions.read() (i.e. stored values), the
    -- active region is the current draft. No settings write happens here.
    local function previewRegions()
        local regions = Regions.read()
        regions[region_key] = draft
        return regions
    end

    local function applyLivePreview()
        if bw and bw._swapHeroRightColumnInPlace then
            bw:_swapHeroRightColumnInPlace(previewRegions())
        end
    end

    local function commitText()
        local text = dialog and dialog:getInputText() or draft.template
        draft.template = text or ""
    end

    local function buildButtons()
        local rows = {}

        -- Row 1: text style controls.
        local style_row = {
            {
                text_func = function() return draft.bold and (_("Bold") .. " \xE2\x9C\x93") or _("Bold") end,
                callback  = function()
                    if dialog then dialog:onCloseKeyboard() end
                    draft.bold = not draft.bold
                    applyLivePreview()
                    if dialog then dialog:reinit() end
                end,
            },
            {
                text_func = function() return _("Size") .. ": " .. (draft.font_size or "") end,
                callback  = function()
                    if dialog then dialog:onCloseKeyboard() end
                    showSizeNudge(
                        draft.font_size or Regions.DEFAULTS[region_key].font_size,
                        Regions.DEFAULTS[region_key].font_size,
                        function(val) draft.font_size = val; applyLivePreview() end,
                        function() if dialog then dialog:reinit() end end)
                end,
            },
            {
                text_func = function() return draft.font_face and _("Font \xE2\x9C\x93") or _("Font\xE2\x80\xA6") end,
                callback  = function()
                    if dialog then dialog:onCloseKeyboard() end
                    showFontPicker(draft.font_face, Regions.DEFAULTS[region_key].font_face,
                        function(file)
                            draft.font_face = file
                            applyLivePreview()
                            if dialog then dialog:reinit() end
                        end)
                end,
            },
        }
        -- Description has no case toggle (would be hostile on a long blurb).
        if region_key ~= "description" then
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

        -- Row 2: progress-region-only bar controls.
        if region_key == "progress" then
            local bar_row = {
                {
                    text_func = function()
                        if not hasBarToken(dialog) then return _("Bar style") end
                        return _("Bar: ") .. (draft.bar_style or "bordered")
                    end,
                    enabled_func = function() return hasBarToken(dialog) end,
                    callback = function()
                        if dialog then dialog:onCloseKeyboard() end
                        local styles = HeroBar.availableStyles()
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
            rows[#rows + 1] = bar_row
        end

        -- Row 3: action row.
        local action_row = {
            {
                text     = _("Cancel"),
                id       = "close",
                callback = function()
                    Regions.restore(region_key, snapshot)
                    if bw and bw._swapHeroRightColumnInPlace then
                        bw:_swapHeroRightColumnInPlace(Regions.read())
                    end
                    UIManager:close(dialog)
                    restoreMenu()
                end,
            },
            {
                text     = _("Tokens\xE2\x80\xA6"),
                callback = function()
                    if dialog then dialog:onCloseKeyboard() end
                    if settings_module and settings_module._pickToken then
                        settings_module:_pickToken(dialog)
                    end
                end,
            },
        }
        if bookendsIconsAvailable() then
            action_row[#action_row + 1] = {
                text     = _("Icons\xE2\x80\xA6"),
                callback = function()
                    if dialog then dialog:onCloseKeyboard() end
                    showIconsLibrary(dialog)
                end,
            }
        end
        action_row[#action_row + 1] = {
            text     = _("Default"),
            callback = function()
                local d = Regions.DEFAULTS[region_key]
                draft.template  = d.template
                draft.font_face = d.font_face
                draft.font_size = d.font_size
                draft.bold      = d.bold
                draft.uppercase = d.uppercase
                draft.alignment = d.alignment
                draft.bar_height= d.bar_height
                draft.bar_style = d.bar_style
                if dialog and dialog.setInputText then dialog:setInputText(d.template) end
                applyLivePreview()
                if dialog then dialog:reinit() end
            end,
        }
        action_row[#action_row + 1] = {
            text             = _("Save"),
            is_enter_default = true,
            callback         = function()
                commitText()
                Regions.write(region_key, draft)
                UIManager:close(dialog)
                restoreMenu()
            end,
        }
        rows[#rows + 1] = action_row
        return rows
    end

    dialog = InputDialog:new{
        title           = _(Regions.LABELS[region_key] or region_key),
        input           = draft.template,
        allow_newline   = true,
        -- Reserve roughly two lines of space for the input area. Templates
        -- like the default subtitle (with a long [if:series]…[/if] block)
        -- often run past one line, and the auto-fit single-line layout
        -- forces the user to horizontal-scroll while editing — frustrating
        -- on a touch keyboard. Two lines tall by default; the dialog still
        -- expands further if the input wraps to more lines.
        text_height     = Screen:scaleBySize(60),
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
end

return LineEditor
