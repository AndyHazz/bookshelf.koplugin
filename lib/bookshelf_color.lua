--[[
Central color-value helpers.

Every color setting in Bookshelf (text_color, symbol_color, bar_colors.{fill,
bg, track, tick, border, invert, metro_fill}) can be stored in one of three
shapes:

  - table with .hex = "#RRGGBB"    -- v4.3+ color-picker authoring
  - table with .grey = 0xNN        -- v2+ greyscale nudge (text/symbol)
  - raw byte 0..0xFF               -- legacy bar_colors shape (pre-v4)

parseColorValue folds all three into a Blitbuffer color object:
  * Color-enabled screens: hex → ColorRGB32, grey/byte → Color8.
  * Greyscale screens: hex → Color8 of the Rec.601 luminance (so presets
    authored on color devices still render sensibly on Kindle/older Kobo).

The hex → color conversion is memoised in a module-local table; toggling
KOReader's color-rendering mode at runtime must call flushCache() to drop
stale ColorRGB32 values cached from the previous mode (ColorRGB32 on a now-
greyscale screen would go through Blitbuffer's default 32→8 converter rather
than our Rec.601 luminance helper, which looks subtly different on photos).
]]

local Blitbuffer = require("ffi/blitbuffer")

local Color = {}

local _hex_cache = {}
local _last_color_mode = nil  -- tracks last seen is_color_enabled for auto-flush

-- Default hex for each field when the user taps "Default" in the picker.
-- nil means "clear the setting entirely" (fall back to the field's own
-- default-color logic in the render path).
local DEFAULT_HEX = {
    fill        = "#404040",  -- matches the 75%-black greyscale default
    bg          = "#BFBFBF",  -- matches the 25%-black greyscale default
    track       = "#404040",
    tick        = "#000000",
    border      = "#000000",
    invert      = "#FFFFFF",
    metro_fill  = "#000000",
    text_color  = nil,        -- "book text color" — clear rather than default
    symbol_color = nil,       -- "match text" — clear rather than default
    -- Cover-indicator colors (bookshelf-specific). bookmark matches
    -- progress_fill's default so the in-progress glyph keeps its pre-2.2.5
    -- "darkish" look when the field is unset. badge_fg / badge_bg match the
    -- hard-coded pill defaults (black text on a white fill) plus the
    -- halo'd-check defaults (black outline, white centre) — see
    -- bookshelf_cover_progress.M.buildOutlinedGlyphWidget.
    bookmark           = "#404040",
    complete_bookmark  = "#FFFFFF",  -- white centre on the finished badge
    favorite_star      = "#FFD700",  -- yellow on color panels; luminance on B&W
    badge_fg           = "#000000",
    badge_bg           = "#FFFFFF",
    border             = "#000000",  -- cover frame + pill / badge borders
    -- Folder overlay defaults match the color-mode appearance of the
    -- FolderCard module's CARDBOARD / CARDBOARD_EDGE constants. On B&W
    -- devices the picker is replaced by a % black nudge dialog so this
    -- hex is only ever shown as the picker's "default" swatch on color
    -- screens. Field names match rawColors().folder_bg / .folder_fg so
    -- the settings menu's pickColor helper can pass the same string to
    -- both lookups.
    folder_bg   = "#E7C9A9",
    folder_fg   = "#000000",
    -- Selected chip (#294). Defaults describe the appearance the invert
    -- produces today (black fill, paper-white label), so the picker opens on
    -- what the user is already looking at.
    chip_selected_bg = "#000000",
    chip_selected_fg = "#FFFFFF",
}

function Color.defaultHexFor(field) return DEFAULT_HEX[field] end

-- Is this hex string a real color (r != g or g != b), as opposed to a
-- neutral that would collapse to {grey=N}? Returns false on malformed input.
-- Used by hasColor() to avoid false-positives when a line contains
-- [c=#222]…[/c] — syntactically hex but visually pure grey.
function Color.isColorHex(hex)
    local norm = Color.normaliseHex(hex)
    if not norm then return false end
    local r = tonumber(norm:sub(2, 3), 16)
    local g = tonumber(norm:sub(4, 5), 16)
    local b = tonumber(norm:sub(6, 7), 16)
    return not (r == g and g == b)
end

-- Return a normalised storage-shape table for a hex value: {grey=N} when
-- the hex collapses to a neutral (r==g==b), otherwise {hex="#RRGGBB"}.
-- Returns nil if the hex is malformed. Keeps presets clean on cross-device
-- transfer: a user on a color device picking #404040 from the palette
-- stores it as {grey=0x40}, so the preset isn't flagged as "uses color"
-- by hasColor — same visual result on every device.
function Color.toStorageShape(hex)
    local norm = Color.normaliseHex(hex)
    if not norm then return nil end
    local r = tonumber(norm:sub(2, 3), 16)
    local g = tonumber(norm:sub(4, 5), 16)
    local b = tonumber(norm:sub(6, 7), 16)
    if r == g and g == b then
        return { grey = r }
    end
    return { hex = norm }
end

-- Accepts "#RGB", "#RRGGBB", or the same forms without the leading #.
-- Returns the canonical "#RRGGBB" upper-cased form, or nil if malformed.
-- CSS-short form expands per the usual rule: "#F0A" → "#FF00AA".
function Color.normaliseHex(raw)
    if type(raw) ~= "string" then return nil end
    local s = raw:match("^%s*(.-)%s*$")  -- trim
    if s:sub(1, 1) == "#" then s = s:sub(2) end
    if #s == 3 and s:match("^%x%x%x$") then
        local r, g, b = s:sub(1, 1), s:sub(2, 2), s:sub(3, 3)
        return ("#" .. r .. r .. g .. g .. b .. b):upper()
    elseif #s == 6 and s:match("^%x%x%x%x%x%x$") then
        return ("#" .. s):upper()
    end
    return nil
end

--- Parse a stored color value into a Blitbuffer color object.
--- Returns nil if v is nil, false if v is false (transparent).
function Color.parseColorValue(v, is_color_enabled)
    -- Defensive auto-flush: if is_color_enabled changed since the last call,
    -- cached Blitbuffer values from the old mode are stale — drop them.
    -- Belt-and-braces against the onColorRenderingUpdate event firing late or
    -- a future KOReader refactor moving the broadcast site.
    if _last_color_mode ~= nil and _last_color_mode ~= is_color_enabled then
        _hex_cache = {}
    end
    _last_color_mode = is_color_enabled

    -- Avoid `v == nil` / `v == false` — under LuaJIT, an ffi.metatype with
    -- an __eq metamethod (Blitbuffer.ColorRGB32 et al.) routes those through
    -- __eq and crashes trying to index the nil operand. Check type first.
    local t = type(v)
    if t == "nil" then return nil end
    if t == "boolean" then return false end

    if type(v) == "table" and v.hex then
        -- Normalise to #RRGGBB so short-form ("#F00") and long-form ("#FF0000")
        -- hit the same cache entry.
        local hex = Color.normaliseHex(v.hex)
        if not hex then return nil end
        local key = hex .. (is_color_enabled and ":c" or ":g")
        local cached = _hex_cache[key]
        if cached then return cached end
        local r = tonumber(hex:sub(2, 3), 16)
        local g = tonumber(hex:sub(4, 5), 16)
        local b = tonumber(hex:sub(6, 7), 16)
        local out
        if is_color_enabled then
            out = Blitbuffer.ColorRGB32(r, g, b, 0xFF)
        else
            -- Rec.601 luminance, rounded to 0..255.
            local lum = math.floor(0.299 * r + 0.587 * g + 0.114 * b + 0.5)
            out = Blitbuffer.Color8(lum)
        end
        _hex_cache[key] = out
        return out
    end

    if type(v) == "table" and v.grey then
        return Blitbuffer.Color8(v.grey)
    end

    if type(v) == "number" then
        if v >= 0xFF then return false end
        return Blitbuffer.Color8(v)
    end

    return nil
end

function Color.flushCache()
    _hex_cache = {}
    _last_color_mode = nil  -- reset so next parseColorValue re-seeds the mode
end

return Color
