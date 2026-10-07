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

local UIManager  = require("ui/uimanager")
local CoverLabel = require("lib/bookshelf_cover_label")
local Editor     = require("lib/bookshelf_line_editor")
local _          = require("lib/bookshelf_i18n").gettext

-- The list's value, for the same reason: a typing burst collapses to one
-- rebuild, a pause shows the result.
local PREVIEW_DELAY = 0.45

local CoverLabelEditor = {}

-- The fields the preview hands the shelf: a COPY, never the editor's live
-- draft, so the override the widget holds cannot change under it.
local function snapshot(draft)
    return CoverLabel.normalise(draft)
end

-- show(bw, settings_module, touchmenu_instance)
--
-- `bw` is the live BookshelfWidget and may be nil (no preview then, everything
-- else works).
function CoverLabelEditor.show(bw, settings_module, touchmenu_instance)
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
        if bw and bw._previewCoverLabel then
            previewing = true
            bw:_previewCoverLabel(snapshot(draft))
        end
    end
    local function previewSoon(draft)
        cancelPending()
        local line = snapshot(draft)
        pending = function()
            pending = nil
            if bw and bw._previewCoverLabel then
                previewing = true
                bw:_previewCoverLabel(line)
            end
        end
        UIManager:scheduleIn(PREVIEW_DELAY, pending)
    end

    local line = CoverLabel.line()
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
        title     = _("Text below covers"),
        line      = line,
        defaults  = CoverLabel.defaultLine(),
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
            CoverLabel.save(draft)
            -- Drop the override and rebuild from what was just saved.
            if bw and bw._previewCoverLabel then bw:_previewCoverLabel(nil) end
        end,
        on_cancel  = function()
            cancelPending()
            if previewing and bw and bw._previewCoverLabel then
                bw:_previewCoverLabel(nil)
            end
        end,
    }
end

return CoverLabelEditor
