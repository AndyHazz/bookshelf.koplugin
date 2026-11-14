-- lib/bookshelf_plugin_button.lua
-- The icon on a card in the book popup's Actions tab for a button another
-- plugin adds through FileManager:addFileDialogButtons.
--
-- A button can choose its own icon with `bookshelf_icon`: ONE glyph of
-- KOReader's bundled symbols font, written as a UTF-8 string:
--
--     { text = _("Add to My Plugin"), bookshelf_icon = "\xEE\xA5\x91", callback = ... }
--
-- It is a field of its own, not `icon`, because KOReader's stock file dialog
-- reads `icon` as the NAME of an icon file and would look for a glyph by that
-- name. A button with no `bookshelf_icon`, or one that is not a single glyph,
-- gets the puzzle piece, as before.
--
-- After a button runs, the popup is redrawn (wrap below), so a button whose
-- label follows the book ("Add to X", then "Remove from X") shows its new state
-- at once.

local M = {}

M.DEFAULT = "\xEE\xAC\xB0" -- U+EB30 mdi-puzzle

-- One UTF-8 character outside ASCII: a lead byte that says how long it is,
-- then exactly that many continuation bytes. Plain text ("check", "A") is not
-- a glyph, so a name that was meant for KOReader's own icon lookup never draws
-- as letters on the card.
local function isGlyph(s)
    if type(s) ~= "string" then return false end
    local lead = s:byte(1)
    if not lead or lead < 0xC2 or lead > 0xF4 then return false end
    local want = lead >= 0xF0 and 4 or lead >= 0xE0 and 3 or 2
    if #s ~= want then return false end
    for i = 2, #s do
        local b = s:byte(i)
        if b < 0x80 or b > 0xBF then return false end
    end
    return true
end

-- icon(spec) -> the glyph to draw on the card for this button spec.
function M.icon(spec)
    local icon = type(spec) == "table" and spec.bookshelf_icon or nil
    if isGlyph(icon) then return icon end
    return M.DEFAULT
end

-- wrap(callback, modal, UIManager) -> the function to give the card as its tap.
-- It runs the plugin's callback as it is, then redraws the popup on the next
-- tick, if it is still showing. A callback that opened the reader has closed
-- the popup by then, and there is nothing to redraw.
function M.wrap(callback, modal, UIManager)
    if type(callback) ~= "function" then return callback end
    return function(...)
        local a, b = callback(...)
        if modal and modal.rebuildTab and UIManager:isWidgetShown(modal) then
            UIManager:nextTick(function()
                if UIManager:isWidgetShown(modal) then modal:rebuildTab() end
            end)
        end
        return a, b
    end
end

return M
