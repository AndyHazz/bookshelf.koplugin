--[[
A micro-module's own card look, and the colours its spec declares.

Stored on the module (entry.colors), so the look moves with it between the top
panel, the full-screen view and the shelves. Every value has a light and a dark
slot, as the Colors rows do: key for the light look, key .. "_night" for the
dark one (CoverProgress.modeSuffix picks the slot the shelf on screen paints
from). The dark slot is stored pre-inverted for a frame that flips it, like
every palette colour, and read back through CoverProgress.resolvePicked.

Card keys:
  bg            the card's fill. Unset: Colors > Micro-module background.
  border        false switches the hairline off. Unset: on.
  border_color  the hairline's colour. Unset: Colors > Micro-module border.
  ink           the text. Unset: black or white, whichever reads on the
                card's own background (auto), or the shared ink when the
                card has no background of its own -- so a layout made before
                this looks the same.

A spec's own colours (spec.colors = { { id, text, default, default_dark } })
resolve the same way and reach the module as ctx.colors[id]. default and
default_dark are what the reader SEES on the light and dark looks.
]]
local M = {}

M.CARD_KEYS = { "bg", "border", "border_color", "ink" }
local RESERVED = { bg = true, border = true, border_color = true, ink = true }

local function CP() return require("lib/bookshelf_cover_progress") end

local function slot() return CP().modeSuffix() end

--- raw(entry, key) -> the value stored for the look on screen, or nil.
function M.raw(entry, key)
    local c = entry and entry.colors
    if type(c) ~= "table" then return nil end
    return c[key .. slot()]
end

--- set(entry, key, raw): store (nil clears) for the look on screen. An
--- emptied table is dropped, so an untouched module stays as it was saved.
function M.set(entry, key, raw)
    local k = key .. slot()
    if raw == nil then
        if type(entry.colors) ~= "table" then return end
        entry.colors[k] = nil
        if next(entry.colors) == nil then entry.colors = nil end
        return
    end
    if type(entry.colors) ~= "table" then entry.colors = {} end
    entry.colors[k] = raw
end

local function lum(c)
    local ok, a = pcall(function() return c:getColor8().a end)
    return ok and type(a) == "number" and a or nil
end

--- isDark(bg) -> true for a card dark enough to take white ink (autoInk's
--- own threshold); false for a light one or none.
function M.isDark(bg)
    if type(bg) == "nil" then return false end
    local l = lum(bg)
    return l ~= nil and l < 128
end

--- autoInk(bg) -> ink, muted: black or white, whichever reads on bg, and a
--- muted grey a third of the way from it toward the card (the light theme's
--- 0x55 between black and 0xEE). Judged in paint space: a night frame flips
--- card and ink together, so the contrast is the same on screen.
function M.autoInk(bg)
    local Blitbuffer = require("ffi/blitbuffer")
    local l = lum(bg) or 0xFF
    local ink = (l < 128) and 0xFF or 0x00
    local muted = math.floor(ink + (l - ink) / 3 + 0.5)
    return Blitbuffer.Color8(ink), Blitbuffer.Color8(muted)
end

-- A spec colour's stored shape for the slot on screen: default_dark is what
-- the reader sees, and the dark slot is stored pre-inverted.
local function specDefault(spec)
    if slot() ~= "" and spec.default_dark ~= nil then
        return require("lib/bookshelf_color").invertValue(spec.default_dark)
    end
    return spec.default
end

--- look(entry, def, base) -> { bg, border_on, border, ink, muted, own_bg,
--- colors }. base: the shared look { bg, border, ink, muted }, as the host
--- already resolved it.
function M.look(entry, def, base)
    base = base or {}
    local out = { bg = base.bg, border = base.border, ink = base.ink, muted = base.muted,
                  border_on = true, own_bg = false, colors = {} }
    local resolve = CP().resolvePicked
    local bg = M.raw(entry, "bg")
    if bg ~= nil then
        out.bg, out.own_bg = resolve(bg), true
        out.ink, out.muted = M.autoInk(out.bg)
    end
    local ink = M.raw(entry, "ink")
    if ink ~= nil then
        out.ink = resolve(ink)
        out.muted = select(2, M.autoInk(out.bg))
        local li, lb = lum(out.ink), lum(out.bg)
        if li and lb then
            out.muted = require("ffi/blitbuffer").Color8(math.floor(li + (lb - li) / 3 + 0.5))
        end
    end
    if M.raw(entry, "border") == false then out.border_on = false end
    local bc = M.raw(entry, "border_color")
    if bc ~= nil then out.border = resolve(bc) end
    if def and type(def.colors) == "table" then
        for _i, spec in ipairs(def.colors) do
            if type(spec) == "table" and spec.id then
                local raw = M.raw(entry, spec.id)
                if raw == nil then raw = specDefault(spec) end
                if raw ~= nil then out.colors[spec.id] = resolve(raw) end
            end
        end
    end
    return out
end

--- custom(entry) -> true when the reader set anything on this card (its
--- background, border, border colour or text) for the look on screen.
function M.custom(entry)
    for _i, k in ipairs(M.CARD_KEYS) do
        if M.raw(entry, k) ~= nil then return true end
    end
    return false
end

--- ctxCard(entry, look) -> ctx.card: the card a module stands on, for one
--- that paints its own (the Reading Log pack's framed cards). Colours in
--- paint space, like ctx.colors. custom: the reader set this card with the
--- palette icon, so a module with a card of its own should use this one.
function M.ctxCard(entry, look)
    look = look or {}
    return {
        custom    = M.custom(entry),
        bg        = look.bg,
        ink       = look.ink,
        muted     = look.muted,
        border_on = look.border_on ~= false,
        border    = look.border,
    }
end

--- rows(def) -> the colour menu's rows: { key, text, kind = "colour" |
--- "toggle", spec }. The card's four unless the module has no card (bare),
--- then the spec's own.
function M.rows(def)
    local _ = require("lib/bookshelf_i18n").gettext
    local rows = {}
    if not (def and def.bare) then
        rows[#rows + 1] = { key = "bg",           kind = "colour", text = _("Card background") }
        rows[#rows + 1] = { key = "border",       kind = "toggle", text = _("Card border") }
        rows[#rows + 1] = { key = "border_color", kind = "colour", text = _("Card border color") }
        rows[#rows + 1] = { key = "ink",          kind = "colour", text = _("Card text") }
    end
    if def and type(def.colors) == "table" then
        for _i, spec in ipairs(def.colors) do
            if type(spec) == "table" and spec.id then
                rows[#rows + 1] = { key = spec.id, kind = "colour", text = spec.text or spec.id, spec = spec }
            end
        end
    end
    return rows
end

--- validColors(v) -> true when a spec's colors field is usable: a list of
--- { id (string, not a card key), text }.
function M.validColors(v)
    if type(v) ~= "table" then return false end
    for _i, spec in ipairs(v) do
        if type(spec) ~= "table" or type(spec.id) ~= "string" or RESERVED[spec.id] then
            return false
        end
        if spec.text ~= nil and type(spec.text) ~= "string" then return false end
    end
    return true
end

return M
