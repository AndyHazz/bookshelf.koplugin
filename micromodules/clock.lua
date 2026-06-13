--[[
Start-menu module: a large digital clock.
See README.md in this directory for the module spec contract.

Big HH:MM line. The time format follows KOReader's 12/24-hour preference
by default — the same "twelve_hour_clock" G_reader_settings key the reader
footer and the touch menu read — but the module's own setting (long-press >
"Module settings…") can force 12- or 24-hour, stored under
micromodule_clock_format ("follow" | "12" | "24"; the module-settings
convention, see the README). Either way the string is formatted through
the canonical datetime.secondsToHour helper (which also carries the
translated AM/PM patterns). Locale date line beneath. No TTL cache:
os.date is effectively free, the menu is short-lived, and module rows
re-render on every focus-step rebuild anyway, so the time stays fresh
without one. No on_tap — display only.
]]
local _ = require("lib/bookshelf_i18n").gettext

local FMT_KEY = "micromodule_clock_format" -- "follow" (default) | "12" | "24"

local function readFormat()
    local Store = require("lib/bookshelf_settings_store")
    local v = Store.read(FMT_KEY, "follow")
    if v ~= "12" and v ~= "24" then v = "follow" end
    return v
end

-- Module settings dialog: a radio trio for the time format. Each pick
-- saves, reloads the menu beneath (the card re-renders in the new format)
-- and re-opens the dialog so the checkmark refreshes.
local function showSettings(ctx)
    local ButtonDialog = require("ui/widget/buttondialog")
    local UIManager    = require("ui/uimanager")
    local Store        = require("lib/bookshelf_settings_store")
    local dialog
    local function fmtBtn(label, mode)
        local active = readFormat() == mode
        return {
            text = (active and "\xE2\x9C\x93 " or "  ") .. label,
            callback = function()
                if readFormat() == mode then return end
                Store.save(FMT_KEY, mode)
                UIManager:close(dialog)
                if ctx and ctx.menu and ctx.menu._reload then ctx.menu:_reload() end
                showSettings(ctx)
            end,
        }
    end
    dialog = ButtonDialog:new{
        title        = _("Clock"),
        title_align  = "center",
        width_factor = 0.65,
        buttons      = {
            { fmtBtn(_("Follow KOReader"), "follow") },
            { fmtBtn(_("12-hour"), "12") },
            { fmtBtn(_("24-hour"), "24") },
        },
    }
    UIManager:show(dialog)
end

return {
    key   = "clock", -- stable id stored in user menus; never change it
    title = _("Clock"),
    render = function(width, scale_pct)
        local Blitbuffer    = require("ffi/blitbuffer")
        local Fonts         = require("lib/bookshelf_fonts")
        local TextWidget    = require("ui/widget/textwidget")
        local VerticalGroup = require("ui/widget/verticalgroup")
        local mw = math.max(50, width)
        local function sc(n) return math.max(1, math.floor(n * (scale_pct or 100) / 100 + 0.5)) end
        local now = os.time()
        local fmt = readFormat()
        local twelve
        if fmt == "12" then twelve = true
        elseif fmt == "24" then twelve = false
        else
            twelve = G_reader_settings
                and G_reader_settings:isTrue("twelve_hour_clock")
        end
        local time_str
        local ok_dt, datetime = pcall(require, "datetime")
        if ok_dt and type(datetime) == "table" and datetime.secondsToHour then
            time_str = datetime.secondsToHour(now, twelve)
        else
            time_str = os.date(twelve and "%I:%M %p" or "%H:%M", now)
        end
        -- Shrink-to-fit: "1:24 PM" at size 44 overflows a narrow panel and
        -- TextWidget would ellipsize it ("1:24…"). Measure the natural
        -- width first and scale the font down proportionally when needed.
        local time_size = sc(44)
        local face_t, bold_t = Fonts:getFace("cfont", time_size, {bold=true})
        local probe = TextWidget:new{
            text = time_str,
            face = face_t,
            bold = bold_t,
        }
        local natural_w = probe:getSize().w
        probe:free()
        if natural_w > mw then
            time_size = math.max(sc(20),
                math.floor(time_size * mw / natural_w))
            face_t, bold_t = Fonts:getFace("cfont", time_size, {bold=true})
        end
        return VerticalGroup:new{
            align = "left",
            TextWidget:new{
                text = time_str,
                face = face_t,
                bold = bold_t,
                fgcolor = Blitbuffer.COLOR_BLACK,
                max_width = mw,
            },
            TextWidget:new{
                text = os.date("%A %d %B", now),
                face = Fonts:getFace("cfont", sc(14), {italic=true}),
                fgcolor = Blitbuffer.COLOR_BLACK,
                max_width = mw,
            },
        }
    end,
    show_settings = showSettings,
}
