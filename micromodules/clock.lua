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

--- Does a cell put the date beside the time? Only a clearly wide one (3x1,
--- 6x1 on the grid): the time string is wide itself, so a 2x1 still stacks.
--- No height (start menu, picker): stacked, as always.
local function sideBySide(width, avail_h)
    if not (width and avail_h and avail_h > 0) then return false end
    return width >= avail_h * 2.5
end

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
    local Kit          = require("lib/bookshelf_module_kit")
    local dialog
    local function fmtBtn(label, mode)
        return Kit.radioRow{
            label = label, active = readFormat() == mode,
            on_pick = function()
                Store.save(FMT_KEY, mode)
                Kit.settingsReopen(ctx, dialog, showSettings)
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
    -- Text: unreadable one grid column wide (truncates or breaks words).
    min_w = 2,
    title = _("Clock"),
    summary = _("Device clock. Works offline."),
    -- Time-sensitive: the hero grid re-renders this cell each minute so the
    -- time advances while the hero sits on screen. Ignored elsewhere.
    wants_minute_tick = true,
    render = function(ctx)
        local width, scale_pct = ctx.width, ctx.scale
        local Blitbuffer    = require("ffi/blitbuffer")
        local Fonts         = require("lib/bookshelf_fonts")
        local TextWidget    = require("lib/bookshelf_colour_text")
        local VerticalGroup = require("ui/widget/verticalgroup")
        local SM            = require("lib/bookshelf_start_menu_modules")
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
        local LocalDate = require("lib/bookshelf_localdate")
        local date_face = Fonts:getFace("cfont", sc(14), {italic=true})
        local function measure(face)
            return function(str)
                local p = TextWidget:new{ text = str, face = face }
                local w = p:getSize().w
                p:free()
                return w
            end
        end
        local time_w = TextWidget:new{ text = time_str, face = face_t, bold = bold_t,
            fgcolor = SM.COLOR_PRIMARY }
        if sideBySide(mw, ctx.height) then
            -- Wide: the time, then weekday over day and month beside it, the
            -- date as tall as a third of the time so the pair reads as one.
            local HorizontalGroup = require("ui/widget/horizontalgroup")
            local HorizontalSpan  = require("ui/widget/horizontalspan")
            local gap = sc(16)
            local side_w = math.max(1, mw - time_w:getSize().w - gap)
            local side_face = Fonts:getFace("cfont", math.max(sc(14), math.floor(time_size / 3)),
                {italic=true})
            local lines = { LocalDate.localize(os.date("%A", now)),
                            LocalDate.localize(os.date("%d %B", now)) }
            local m = measure(side_face)
            if math.max(m(lines[1]), m(lines[2])) > side_w then
                lines = { LocalDate.localize(os.date("%a", now)),
                          LocalDate.localize(os.date("%d %b", now)) }
            end
            local dates = VerticalGroup:new{ align = "left" }
            for _i, l in ipairs(lines) do
                dates[#dates + 1] = TextWidget:new{ text = l, face = side_face,
                    fgcolor = SM.COLOR_PRIMARY, max_width = side_w }
            end
            return HorizontalGroup:new{
                align = "center",
                time_w,
                HorizontalSpan:new{ width = gap },
                dates,
            }
        end
        time_w:free()
        return VerticalGroup:new{
            align = "left",
            TextWidget:new{
                text = time_str,
                face = face_t,
                bold = bold_t,
                fgcolor = SM.COLOR_PRIMARY,
                max_width = mw,
            },
            TextWidget:new{
                -- The longest date form that fits rather than a truncated one.
                text = LocalDate.fitted(now, measure(date_face), mw),
                face = date_face,
                fgcolor = SM.COLOR_PRIMARY,
                max_width = mw,
            },
        }
    end,
    show_settings = showSettings,
}
