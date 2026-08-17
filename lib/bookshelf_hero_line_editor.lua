-- bookshelf_hero_line_editor.lua
-- The hero card's half of the line editor: which region is being edited,
-- where its value lives, and what "live preview" means for a hero.
--
-- Everything ELSE -- the dialog, the draft, the font picker, the size nudge,
-- the bold / case / alignment controls, the token and icon pickers, Save and
-- Cancel -- is lib/bookshelf_line_editor.lua, which list view uses too. This
-- file is the adapter that says "the thing being edited is Regions[key]".
--
-- The public surface is unchanged from when the whole editor lived here:
-- show(), plus showFontPicker / showSizeNudge / hideParentMenu, which several
-- settings surfaces call directly. They are re-exported rather than moved so
-- no call site had to change.

local Regions   = require("lib/bookshelf_hero_regions")
local HeroBar   = require("lib/bookshelf_hero_bar")
local Editor    = require("lib/bookshelf_line_editor")
local _         = require("lib/bookshelf_i18n").gettext

local LineEditor = {}

-- show(region_key, bw, settings_module, touchmenu_instance)
--   region_key        — one of Regions.ORDER
--   bw                — live BookshelfWidget (live preview target). May be nil.
--   settings_module   — Settings handle (for the token picker).
--   touchmenu_instance — the FM TouchMenu we were launched from. The editor
--                       hides it on open so the user can see the live hero,
--                       and re-shows it on Save/Cancel.
function LineEditor.show(region_key, bw, settings_module, touchmenu_instance)
    local snapshot = Regions.snapshot(region_key)
    local current  = Regions.read()[region_key]

    -- Build a fully-populated regions table for the renderer: the inactive
    -- regions come from Regions.read() (i.e. stored values), the active region
    -- is the current draft. No settings write happens here.
    local function preview(draft)
        if not (bw and bw._swapHeroRightColumnInPlace) then return end
        local regions = Regions.read()
        regions[region_key] = draft
        bw:_swapHeroRightColumnInPlace(regions)
    end

    Editor.edit{
        title    = _(Regions.LABELS[region_key] or region_key),
        line     = current,
        defaults = Regions.DEFAULTS[region_key],
        -- Description has no case toggle (would be hostile on a long blurb).
        uppercase  = region_key ~= "description",
        -- Only the progress region carries a bar.
        bar        = region_key == "progress",
        bar_styles = HeroBar.availableStyles,
        settings_module    = settings_module,
        touchmenu_instance = touchmenu_instance,
        on_preview = preview,
        on_save    = function(draft) Regions.write(region_key, draft) end,
        -- Nothing was written, so this only has to undo the preview. It
        -- restores the snapshot as well, as a safety net in case another
        -- surface wrote to this region while the editor was open.
        on_cancel  = function()
            Regions.restore(region_key, snapshot)
            if bw and bw._swapHeroRightColumnInPlace then
                bw:_swapHeroRightColumnInPlace(Regions.read())
            end
        end,
    }
end

-- Re-exported: the Bookshelf UI font picker in settings, the tags-region
-- submenu's font-size nudge (#99), and several dialogs that hide their parent
-- menu all reach for these by this name.
LineEditor.showFontPicker = Editor.showFontPicker
LineEditor.showSizeNudge  = Editor.showSizeNudge
LineEditor.hideParentMenu = Editor.hideParentMenu

return LineEditor
