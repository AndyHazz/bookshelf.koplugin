-- bookshelf_cover_label_editor.lua
-- The cover label's half of the line editor: where the Custom label's template
-- lives, which controls a label can honour, and what "live preview" means for
-- the strip under the covers.
--
-- The dialog is lib/bookshelf_line_editor.lua, shared with the hero card and
-- the list view. This is the third adapter, modelled on
-- lib/bookshelf_list_line_editor.lua; lib/bookshelf_cover_label.lua owns the
-- stored line and how a template becomes a label.
--
-- ── THE CONTROLS ───────────────────────────────────────────────────────────
--
-- A label is ONE line in the strip's own face, at the size Text size > Cover
-- labels sets for every label, centred under its cover. So the editor offers
-- what that line can actually do and nothing else:
--
--   kept    Bold (a plain toggle: the strip has no italic face to cycle to)
--           and the Aa/AA case toggle; Tokens… (filtered, see
--           CoverLabel.offersToken), Icons…, Default, Cancel, Save.
--   hidden  Size and Font (the strip's face and size belong to the Cover labels
--           setting, which every label shares), alignment (a label is centred
--           under its cover), and the %bar row.
--
-- ── PREVIEW ────────────────────────────────────────────────────────────────
--
-- The labels are built with the rows, so showing a draft is a rebuild, the
-- same as the list's lines. Keystrokes are debounced exactly as the list does
-- it (each one re-arms a short timer, the last one rebuilds); a button tap
-- previews at once. The timer is cancelled on Save and on Cancel so a late
-- rebuild cannot repaint an abandoned draft.
--
-- ── SAVE AND CANCEL ────────────────────────────────────────────────────────
--
-- Save writes the template AND makes Custom the mode: opening the editor from
-- the Custom row is how the reader chooses it. Cancel writes nothing, so a
-- reader who was on Title and backs out is still on Title; the preview
-- override is simply dropped.
--
-- ── GROUPS ─────────────────────────────────────────────────────────────────
--
-- The same editor edits the groups' Custom line (Show text below groups,
-- issue 486) when opened with groups = true: its own stored line, default
-- and Save (CoverLabel.groupLine / groupDefaultLine / saveGroup), and its own
-- preview override on the shelf (_previewGroupLabel). Everything else is the
-- books' editor, control for control.

local UIManager  = require("ui/uimanager")
local CoverLabel = require("lib/bookshelf_cover_label")
local Editor     = require("lib/bookshelf_line_editor")
local _          = require("lib/bookshelf_i18n").gettext

-- The list's value, for the same reason: a typing burst collapses to one
-- rebuild, a pause shows the result.
local PREVIEW_DELAY = 0.45

local CoverLabelEditor = {}

-- The two lines this editor edits: the books' and the groups'.
local BOOKS = {
    title    = function() return _("Text below covers") end,
    line     = function() return CoverLabel.line() end,
    defaults = function() return CoverLabel.defaultLine() end,
    save     = function(l) return CoverLabel.save(l) end,
    preview  = "_previewCoverLabel",
    template = CoverLabel.DEFAULT_TEMPLATE,
}
local GROUPS = {
    title    = function() return _("Show text below groups") end,
    line     = function() return CoverLabel.groupLine() end,
    defaults = function() return CoverLabel.groupDefaultLine() end,
    save     = function(l) return CoverLabel.saveGroup(l) end,
    preview  = "_previewGroupLabel",
    template = CoverLabel.GROUP_DEFAULT_TEMPLATE,
}
CoverLabelEditor._targets = { books = BOOKS, groups = GROUPS }

-- show(bw, settings_module, touchmenu_instance, groups)
--
-- `bw` is the live BookshelfWidget and may be nil (no preview then, everything
-- else works). `groups` true edits the groups' line instead of the books'.
function CoverLabelEditor.show(bw, settings_module, touchmenu_instance, groups)
    local target = groups and GROUPS or BOOKS
    -- The fields the preview hands the shelf: a COPY, never the editor's live
    -- draft, so the override the widget holds cannot change under it.
    local function snapshot(draft)
        return CoverLabel.normalise(draft, target.template)
    end
    local function preview(line)
        local fn = bw and bw[target.preview]
        if fn then fn(bw, line); return true end
        return false
    end
    local pending
    -- Whether the shelf is showing a draft. Cancel only has to rebuild when
    -- it is; backing straight out of the editor costs nothing.
    local previewing = false
    local function cancelPending()
        if pending then
            UIManager:unschedule(pending)
            pending = nil
        end
    end
    local function previewNow(draft)
        cancelPending()
        if preview(snapshot(draft)) then previewing = true end
    end
    local function previewSoon(draft)
        cancelPending()
        local line = snapshot(draft)
        pending = function()
            pending = nil
            if preview(line) then previewing = true end
        end
        UIManager:scheduleIn(PREVIEW_DELAY, pending)
    end

    local line = target.line()
    -- Keystrokes only ever change the template; the two buttons never do.
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
        title     = target.title(),
        line      = line,
        defaults  = target.defaults(),
        italic    = false,
        size      = false,
        font      = false,
        alignment = false,
        bar       = false,
        token_filter       = CoverLabel.offersToken,
        settings_module    = settings_module,
        touchmenu_instance = touchmenu_instance,
        on_preview = onPreview,
        on_save    = function(draft)
            cancelPending()
            target.save(draft)
            -- Drop the override and rebuild from what was just saved.
            preview(nil)
        end,
        on_cancel  = function()
            cancelPending()
            if previewing then preview(nil) end
        end,
    }
end

return CoverLabelEditor
