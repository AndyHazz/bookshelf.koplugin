--[[
Start-menu module: the battery level.
See README.md in this directory for the module spec contract.

Heading, KOReader's own battery glyph (the one the reader footer shows, so a
charging bolt reads the same everywhere) with the percentage, a level bar, and
the cover/case battery on devices that have one (Kindle Oasis cover, Kobo
PowerCover). Tap opens KOReader's battery statistics when that plugin is on.

Read from PowerD at render time. PowerD caches the capacity itself, so this
is cheap enough for the minute tick.
]]
local _ = require("lib/bookshelf_i18n").gettext
local T = require("ffi/util").template

-- read() -> { cap, charging, charged, symbol, aux_cap, aux_charging } or nil
-- when the device cannot say (no PowerD, or a capacity that is not a number).
local function read()
    local ok, PowerD = pcall(function() return require("device"):getPowerDevice() end)
    if not ok or not PowerD or not PowerD.getCapacity then return nil end
    local ok_c, cap = pcall(PowerD.getCapacity, PowerD)
    if not ok_c or type(cap) ~= "number" then return nil end
    local function call(name)
        if type(PowerD[name]) ~= "function" then return nil end
        local okv, v = pcall(PowerD[name], PowerD)
        return okv and v or nil
    end
    local s = {
        cap = math.max(0, math.min(100, math.floor(cap + 0.5))),
        charging = call("isCharging") and true or false,
        charged  = call("isCharged") and true or false,
    }
    if type(PowerD.getBatterySymbol) == "function" then
        local ok_s, sym = pcall(PowerD.getBatterySymbol, PowerD, s.charged, s.charging, s.cap)
        if ok_s and type(sym) == "string" then s.symbol = sym end
    end
    local dev = PowerD.device
    local has_aux = false
    if dev and type(dev.hasAuxBattery) == "function" then
        local ok_h, h = pcall(dev.hasAuxBattery, dev)
        has_aux = ok_h and h and true or false
    end
    if has_aux and call("isAuxBatteryConnected") then
        local aux = call("getAuxCapacity")
        if type(aux) == "number" then
            s.aux_cap = math.max(0, math.min(100, math.floor(aux + 0.5)))
            s.aux_charging = call("isAuxCharging") and true or false
        end
    end
    return s
end

--- How the card lays itself out for its cell: "upright" (a battery standing up,
--- the percentage under it) in square and tall cells, "sideways" (a battery on
--- its side, the figures beside it) in anything wider than tall, and "card"
--- (heading, figure, bar) with no height to go by (start menu, picker).
local function shapeOf(width, avail_h)
    if not (width and avail_h and avail_h > 0) then return "card" end
    if avail_h >= width * 0.9 then return "upright" end
    return "sideways"
end

-- A drawn battery w x h: a rounded outline, the terminal nub on top (upright)
-- or at the right (sideways), and the charge filled from the bottom or the
-- left, inset from the outline.
local function meter(w, h, fraction, upright)
    local Widget = require("ui/widget/widget")
    local Geom   = require("ui/geometry")
    local Kit    = require("lib/bookshelf_module_kit")
    local Color  = require("lib/bookshelf_color")
    local ink = Kit.COLOR_PRIMARY or require("ffi/blitbuffer").COLOR_BLACK
    local Meter = Widget:extend{}
    function Meter:getSize() return Geom:new{ w = w, h = h } end
    function Meter:paintTo(bb, x, y)
        self.dimen = Geom:new{ x = x, y = y, w = w, h = h }
        local t = math.max(2, math.floor(math.min(w, h) / 14))
        local gap = t
        local bx, by, bw, bh, nx, ny, nw, nh
        if upright then
            nh = math.max(t * 2, math.floor(h * 0.06))
            nw = math.floor(w * 0.4)
            nx, ny = x + math.floor((w - nw) / 2), y
            bx, by, bw, bh = x, y + nh, w, h - nh
        else
            nw = math.max(t * 2, math.floor(w * 0.06))
            nh = math.floor(h * 0.4)
            nx, ny = x + w - nw, y + math.floor((h - nh) / 2)
            bx, by, bw, bh = x, y, w - nw, h
        end
        bb:paintBorder(bx, by, bw, bh, t, ink, t * 2)
        Color.paintRect(bb, nx, ny, nw, nh, ink)
        local ix, iy = bx + t + gap, by + t + gap
        local iw, ih = bw - 2 * (t + gap), bh - 2 * (t + gap)
        if iw > 0 and ih > 0 then
            if upright then
                local fh = math.floor(ih * fraction + 0.5)
                if fh > 0 then Color.paintRect(bb, ix, iy + ih - fh, iw, fh, ink) end
            else
                local fw = math.floor(iw * fraction + 0.5)
                if fw > 0 then Color.paintRect(bb, ix, iy, fw, ih, ink) end
            end
        end
    end
    return Meter:new{}
end

-- lines(s) -> value, suffix, sub for the card; pure, so the test can pin the
-- wording without a device.
local function lines(s)
    local value = (s.symbol and s.symbol ~= "" and (s.symbol .. " ") or "") .. s.cap .. "%"
    local suffix
    if s.charged then suffix = " " .. _("charged")
    elseif s.charging then suffix = " " .. _("charging")
    else suffix = " " .. _("remaining") end
    local sub
    if s.aux_cap then
        sub = s.aux_charging and T(_("Cover: %1% (charging)"), s.aux_cap)
                             or T(_("Cover: %1%"), s.aux_cap)
    end
    return value, suffix, sub
end

return {
    key   = "battery", -- stable id stored in user menus; never change it
    title = _("Battery"),
    summary = _("From the device. Works offline."),
    -- The level changes while the hero sits on screen (charging especially).
    wants_minute_tick = true,
    render = function(ctx)
        local Kit = require("lib/bookshelf_module_kit")
        local mw  = math.max(50, ctx.width)
        local s = read()
        if not s then
            local TextWidget = require("lib/bookshelf_colour_text")
            return TextWidget:new{
                text = _("Battery level unavailable"),
                face = Kit.face(15, ctx.scale),
                fgcolor = Kit.COLOR_MUTED, max_width = mw,
            }
        end
        local value, suffix, sub = lines(s)
        local shape = shapeOf(mw, ctx.height)
        if shape ~= "card" then
            local TextWidget      = require("lib/bookshelf_colour_text")
            local VerticalGroup   = require("ui/widget/verticalgroup")
            local VerticalSpan    = require("ui/widget/verticalspan")
            local HorizontalGroup = require("ui/widget/horizontalgroup")
            local HorizontalSpan  = require("ui/widget/horizontalspan")
            local sc = Kit.sc(ctx.scale)
            local avail_h = ctx.height
            -- The drawn battery says what it is, so the figure is just the
            -- percentage, with KOReader's bolt only while charging.
            local pct = s.cap .. "%"
            if s.charging and s.symbol and s.symbol ~= "" then pct = s.symbol .. " " .. pct end
            if shape == "upright" then
                -- The battery takes about two thirds of the height, at 1:2;
                -- the percentage (with the charging state) sits under it.
                -- Shrunk rather than cut to fit a narrow cell.
                local text = pct
                local size = 22
                local face, bold = Kit.face(size, ctx.scale, { bold = true })
                local probe = TextWidget:new{ text = text, face = face, bold = bold }
                local tw = probe:getSize().w
                probe:free()
                -- Aim a little inside the width: the font's own rounding can
                -- otherwise land a pixel over and the label ellipsizes ("90...").
                local fit = math.floor(mw * 0.9)
                if tw > fit and tw > 0 then
                    face, bold = Kit.face(math.max(8, math.floor(size * fit / tw)), ctx.scale, { bold = true })
                end
                local label = TextWidget:new{ text = text, face = face, bold = bold,
                    fgcolor = Kit.COLOR_PRIMARY, max_width = mw }
                local mh = math.max(sc(30), math.floor(avail_h * 0.66) - label:getSize().h)
                local mwid = math.min(math.floor(mh / 2), math.floor(mw * 0.6))
                mh = mwid * 2
                return VerticalGroup:new{
                    align = "center",
                    meter(mwid, mh, s.cap / 100, true),
                    VerticalSpan:new{ width = sc(8) },
                    label,
                }
            end
            -- Sideways: the battery at half the height, 2:1, then the figure
            -- and what it means beside it.
            local bh = math.max(sc(20), math.floor(avail_h * 0.5))
            -- At most a third of the width, so the figures keep room beside it.
            bh = math.min(bh, math.floor(mw / 6))
            local bwid = bh * 2
            local face, bold = Kit.face(26, ctx.scale, { bold = true })
            local texts = VerticalGroup:new{
                align = "left",
                TextWidget:new{ text = pct, face = face, bold = bold,
                    fgcolor = Kit.COLOR_PRIMARY },
                TextWidget:new{ text = sub or (suffix:gsub("^%s+", "")),
                    face = Kit.face(14, ctx.scale), fgcolor = Kit.COLOR_MUTED },
            }
            return HorizontalGroup:new{
                align = "center",
                meter(bwid, bh, s.cap / 100, false),
                HorizontalSpan:new{ width = sc(16) },
                texts,
            }
        end
        return Kit.valueCard{
            width = mw, scale_pct = ctx.scale,
            heading = _("Battery"),
            value = value, suffix = suffix,
            bar = Kit.progressBar{ width = mw, height = Kit.sc(ctx.scale)(6),
                                   fraction = s.cap / 100 },
            sub = sub,
        }
    end,
    on_tap = function()
        local ok, Dispatcher = pcall(require, "dispatcher")
        if ok then Dispatcher:execute({ battery_statistics = true }) end
    end,
    _test = { read = read, lines = lines, shapeOf = shapeOf },
}
