-- Keyboard-navigation helpers for non-touch devices (issue #133).
--
-- The plugin's cycle/nudge dialogs (Edit layout, font/scale steppers, bulk
-- actions, hero line editor, colour pickers) refresh their button labels by
-- calling ButtonDialog:reinit() from a button callback. reinit() does
-- free()+init(); free() (WidgetContainer:free) does NOT clear self.layout, and
-- init() sets `self.layout = self.layout or self.buttontable.layout`. So on the
-- second init the stale, already-freed layout wins the `or` and the freshly
-- built buttontable.layout is thrown away. On touch devices this is invisible
-- (taps never consult self.layout), but on non-touch devices the FocusManager
-- then drives dead widgets: the d-pad cursor lands on nothing and the user is
-- locked out of the dialog (the #133 symptom: "no controls to move the
-- selection and accept"). Dialogs built with addWidget()/_added_widgets are
-- exempt -- their init() rebuilds self.layout unconditionally.
--
-- Focus.reinit() nils dialog.layout first, so init() adopts the fresh layout,
-- then refocuses on the next tick so the cursor highlight reappears on the new
-- button at the preserved self.selected position. Use it everywhere the plugin
-- would otherwise call dialog:reinit() directly.

local Focus = {}

-- Safe replacement for `dialog:reinit()` on focusable ButtonDialogs.
function Focus.reinit(dialog)
    if not (dialog and dialog.reinit) then return end
    -- Defeat the `self.layout or ...` short-circuit so init() takes the freshly
    -- built buttontable.layout instead of the stale, freed one.
    dialog.layout = nil
    dialog:reinit()
    -- Re-apply the focus highlight at the preserved cursor. nextTick=true so it
    -- paints after any repaint triggered by the callback (e.g. a live rebuild).
    -- refocusWidget no-ops the visual on touch devices by design.
    if dialog.refocusWidget then
        dialog:refocusWidget(true)
    end
end

return Focus
