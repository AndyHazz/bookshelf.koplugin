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
            local TextWidget = require("ui/widget/textwidget")
            return TextWidget:new{
                text = _("Battery level unavailable"),
                face = Kit.face(15, ctx.scale),
                fgcolor = Kit.COLOR_MUTED, max_width = mw,
            }
        end
        local value, suffix, sub = lines(s)
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
    _test = { read = read, lines = lines },
}
