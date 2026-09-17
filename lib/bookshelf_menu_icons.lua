-- bookshelf_menu_icons.lua
-- The glyphs the plugin puts in front of menu labels, in one place.
--
-- PRIVATE USE AREA ONLY (U+E000..U+F8FF). Two reasons, and the second is the
-- one that matters:
--
--   * Coverage. KOReader bundles nerdfonts/symbols.ttf, which covers exactly
--     that range, and lists it as font fallback 6 -- so a plain menu label
--     renders one of these with no per-item font face to set.
--   * Safety. Broadening the start-menu's icon handling to a non-PUA arrow
--     (U+21BB) segfaulted the render on a PW5, twice, with no Lua traceback.
--     The broadening was reverted rather than solved, and the cause was never
--     pinned. Do not reach outside the PUA for a nicer symbol.
--
-- The glyph always rides OUTSIDE the translatable string: a private-use
-- codepoint has no business travelling through a .po file, where it would be
-- invisible in most editors and lost by the first translator to retype a line.
--
-- Names here are the font's own glyph names, so a future editor can find them
-- again: `fontTools` over symbols.ttf, or the nerdfonts cheat sheet.
local M = {}

-- Not every menu row gets one. The Bookshelf toggle and About deliberately
-- have none: one switches a mode and the other is a dead end, so leaving them
-- plain is what makes the icons above them read as a group of destinations
-- rather than as decoration on every line (maintainer). _test_menu_icons
-- pins which entries carry an icon and which do not, in both directions.

M.RESET      = "\xEE\xB6\x8F"   -- U+ED8F  bomb
M.SHELF_SIZE = "\xEE\xB4\x95"   -- U+ED15  arrow-expand
M.SHELVES    = "\xEE\xA5\xB8"   -- U+E978  format-list-bulleted
M.APPEARANCE = "\xEE\xAB\x97"   -- U+EAD7  palette
M.HARDCOVER  = "\xEE\xB4\xBE"   -- U+ED3E  cloud-sync
M.SETTINGS   = "\xEF\x80\x93"   -- U+F013  cog
M.UPDATES    = "\xEE\xB6\xAE"   -- U+EDAE  update

-- label(glyph, text) -> the text with the glyph in front of it.
--
-- Two spaces, not one: at menu size the glyph sits tight against a capital
-- otherwise. Kept here so every caller spaces it the same way.
function M.label(glyph, text)
    if type(glyph) ~= "string" or glyph == "" then return text end
    return glyph .. "  " .. text
end

return M
