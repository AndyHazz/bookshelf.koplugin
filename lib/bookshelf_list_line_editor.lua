-- bookshelf_list_line_editor.lua
-- List view's half of the line editor: which line of a list row is being
-- edited, where its value lives, and what "live preview" means for a shelf.
--
-- The dialog itself is lib/bookshelf_line_editor.lua, shared with the hero
-- card. This file is the adapter, and it is the exact counterpart of
-- lib/bookshelf_hero_line_editor.lua.
--
-- ── WHY THE PREVIEW IS DEBOUNCED HERE AND NOT ON THE HERO ──────────────────
--
-- The hero previews by swapping one column of one card. A list line changes
-- the ROW HEIGHT, which changes how many rows fit the band, which is a full
-- _rebuild -- covers, records, pagination, the lot. Doing that on every
-- keystroke would make typing a template feel like the device had died.
--
-- So text edits coalesce: each keystroke re-arms a short timer and only the
-- last one inside the window actually rebuilds. Button taps (bold, size, font,
-- alignment) preview IMMEDIATELY -- they are discrete, the user is waiting to
-- see the result, and there is no burst to coalesce.
--
-- The timer is cancelled on Save and on Cancel. A pending rebuild that fires
-- after the editor has closed would repaint the shelf with a draft the user
-- has just abandoned, and (worse) after the override was cleared it would
-- rebuild from settings a second time for no reason.

local UIManager = require("ui/uimanager")
local Lines     = require("lib/bookshelf_list_lines")
local Editor    = require("lib/bookshelf_line_editor")
local _         = require("lib/bookshelf_i18n").gettext

-- Long enough that a normal typing burst collapses to one rebuild, short
-- enough that pausing to look at the screen shows the result without the user
-- wondering whether it took. Eyeballed on a PW5.
local PREVIEW_DELAY = 0.45

local ListLineEditor = {}

-- label(index) -> "Line 1", localised.
function ListLineEditor.label(index)
    return string.format(_("Line %d"), index)
end

-- show(index, bw, settings_module, touchmenu_instance)
--
-- Opens the editor on line `index` of the saved list layout. `bw` is the live
-- BookshelfWidget and may be nil (no preview then, everything else works).
function ListLineEditor.show(index, bw, settings_module, touchmenu_instance)
    local layout = Lines.layout()
    local line   = layout.lines[index]
    if not line then return end

    -- The layout handed to the widget on every preview: the saved lines with
    -- this one replaced by the draft. Rebuilt per call rather than mutated in
    -- place, so the override the widget holds is never the editor's live table.
    local function previewLayout(draft)
        local lines = {}
        for i, l in ipairs(layout.lines) do lines[i] = l end
        lines[index] = draft
        return { show_cover = layout.show_cover, lines = lines }
    end

    local pending   -- the scheduled closure, so it can be unscheduled
    local function cancelPending()
        if pending then
            UIManager:unschedule(pending)
            pending = nil
        end
    end
    local function previewNow(draft)
        cancelPending()
        if bw and bw._previewListLines then
            bw:_previewListLines(previewLayout(draft))
        end
    end
    local function previewSoon(draft)
        cancelPending()
        pending = function()
            pending = nil
            if bw and bw._previewListLines then
                bw:_previewListLines(previewLayout(draft))
            end
        end
        UIManager:scheduleIn(PREVIEW_DELAY, pending)
    end

    -- Which of the two the editor gets: the generic editor calls on_preview
    -- for both keystrokes and button taps and cannot tell them apart, so the
    -- discrimination happens here on the ONE thing that distinguishes them --
    -- a keystroke can only ever have changed the template.
    local last_template = line.template
    local function onPreview(draft)
        if draft.template ~= last_template then
            last_template = draft.template
            previewSoon(draft)
        else
            previewNow(draft)
        end
    end

    Editor.edit{
        title    = ListLineEditor.label(index),
        line     = line,
        defaults = Lines.newLine(index),
        -- Every list line can carry a %bar, unlike the hero where only the
        -- progress region can: a hero region is a named slot with a job, and a
        -- list line is whatever the user puts on it.
        bar        = true,
        bar_styles = require("lib/bookshelf_hero_bar").availableStyles,
        settings_module    = settings_module,
        touchmenu_instance = touchmenu_instance,
        on_preview = onPreview,
        on_save    = function(draft)
            cancelPending()
            Lines.writeLine(index, draft)
            -- Clear the override and rebuild from what was just saved. Leaving
            -- the override in place would look identical right now and go
            -- stale the moment anything else changed the lines.
            if bw and bw._previewListLines then bw:_previewListLines(nil) end
            -- Nothing to settle. Editing a line changes what the row SAYS,
            -- not how tall it is: the height comes from the row count now, so
            -- the scale cannot be left sitting mid-run with a gap under the
            -- last row. The settle pass that used to run here went with the
            -- density model.
        end,
        on_cancel  = function()
            cancelPending()
            if bw and bw._previewListLines then bw:_previewListLines(nil) end
        end,
    }
end

return ListLineEditor
