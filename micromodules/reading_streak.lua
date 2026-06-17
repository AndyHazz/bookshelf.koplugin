--[[
Start-menu module: reading streak.
Shows the current consecutive-day reading streak from KOReader's
statistics plugin database (statistics.sqlite3).

A "reading day" is any calendar day (local time) with at least one entry
in page_stat_data. The streak counts backwards from today, or from
yesterday if the user hasn't read yet today.

Result is cached for 30s so repeated re-renders stay cheap.

Settings (long-press the card > "Module settings…"; stored under the
micromodule_reading_streak_* keys — the module-settings convention):
  * tap: "reading_insights_popup" (default — opens the reading insights
    popup) or "stats_calendar_view" (opens the reading calendar view).
]]
local _ = require("lib/bookshelf_i18n").gettext
local T = require("ffi/util").template

local STREAK_TTL_S = 30
local TAP_KEY = "micromodule_reading_streak_tap" -- "reading_insights_popup" | "stats_calendar_view"

local function readTap()
    local Store = require("lib/bookshelf_settings_store")
    local v = Store.read(TAP_KEY, "reading_insights_popup")
    if v ~= "stats_calendar_view" then v = "reading_insights_popup" end
    return v
end
local _streak_cache -- { at = <epoch>, data = <result or false> }

-- Module settings dialog (long-press > "Module settings…"): one radio
-- group for the tap action. Each pick saves and reloads the menu beneath,
-- then re-opens the dialog so the checkmark refreshes — same pattern as
-- quote_of_day's settings.
local function showSettings(ctx)
    local ButtonDialog = require("ui/widget/buttondialog")
    local UIManager    = require("ui/uimanager")
    local Store        = require("lib/bookshelf_settings_store")
    local dialog
    local function radio(label, value)
        local active = readTap() == value
        return {
            text = (active and "\xE2\x9C\x93 " or "  ") .. label,
            callback = function()
                if readTap() == value then return end
                Store.save(TAP_KEY, value)
                UIManager:close(dialog)
                if ctx and ctx.menu and ctx.menu._reload then ctx.menu:_reload() end
                showSettings(ctx)
            end,
        }
    end
    local function header(label)
        return { text = label, enabled = false }
    end
    dialog = ButtonDialog:new{
        title        = _("Reading streak"),
        title_align  = "center",
        width_factor = 0.65,
        buttons      = {
            { header(_("Tap action")) },
            { radio(_("Reading insight"), "reading_insights_popup") },
            { radio(_("Reading calendar"), "stats_calendar_view") },
        },
    }
    UIManager:show(dialog)
end

-- Returns { current = N } or nil on error / missing DB.
local function queryStreak()
    local DataStorage = require("datastorage")
    local path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(path, "mode") ~= "file" then return nil end

    local ok, res = pcall(function()
        local SQ3 = require("lua-ljsqlite3/init")
        local conn = SQ3.open(path, "ro")
        local out
        local ok_q, err = pcall(function()
            conn:exec("PRAGMA busy_timeout=200;")

            -- All distinct reading days, as local-midnight epochs.
            local stmt = conn:prepare([[
                SELECT CAST(strftime('%s',
                       date(start_time, 'unixepoch', 'localtime'))
                    AS INTEGER) AS day_epoch
                FROM page_stat_data
                GROUP BY day_epoch
                ORDER BY day_epoch ASC
            ]])

            local days = {}
            local row = stmt:step()
            while row do
                days[#days + 1] = tonumber(row[1]) or 0
                row = stmt:step()
            end
            stmt:close()

            local ONE_DAY = 86400

            -- Today's epoch, using the exact same conversion as day_epoch
            -- above (date(...,'localtime') reinterpreted by strftime as
            -- UTC). Must match exactly, or equality checks below silently
            -- fail in non-UTC timezones.
            local today_stmt = conn:prepare([[
                SELECT CAST(strftime('%s',
                       date('now', 'localtime'))
                    AS INTEGER)
            ]])
            local today_row = today_stmt:step()
            local today_epoch = tonumber(today_row[1]) or 0
            today_stmt:close()
            local yesterday_epoch = today_epoch - ONE_DAY

            -- Count backwards from today/yesterday while days are consecutive.
            local current = 0
            if #days > 0 then
                local last_day = days[#days]
                if last_day == today_epoch or last_day == yesterday_epoch then
                    local expected = last_day
                    for i = #days, 1, -1 do
                        if days[i] == expected then
                            current  = current + 1
                            expected = expected - ONE_DAY
                        else
                            break
                        end
                    end
                end
            end

            -- Weekly streak: distinct ISO-ish weeks ('%Y-%W', local time)
            -- with at least one reading day, walked backwards the same way
            -- as the daily streak above.
            local week_stmt = conn:prepare([[
                SELECT DISTINCT strftime('%Y-%W', start_time, 'unixepoch', 'localtime') AS yw
                FROM page_stat_data
                ORDER BY yw DESC
            ]])
            local weeks = {}
            local week_row = week_stmt:step()
            while week_row do
                weeks[#weeks + 1] = week_row[1]
                week_row = week_stmt:step()
            end
            week_stmt:close()

            local function parseWeekYear(w)
                if not w then return nil end
                local y, wk = w:match("(%d+)-(%d+)")
                y, wk = tonumber(y), tonumber(wk)
                if not y or wk == nil then return nil end
                return y, wk
            end

            local function isConsecutiveWeek(newer, older)
                local ny, nw = parseWeekYear(newer)
                local oy, ow = parseWeekYear(older)
                if not ny or not oy then return false end
                if ny == oy and nw == ow + 1 then return true end
                -- Year rollover: week 0 of new year follows week 52+ of previous year.
                if ny == oy + 1 and nw == 0 and ow >= 52 then return true end
                return false
            end

            local current_week_str = conn:rowexec(
                "SELECT strftime('%Y-%W', 'now', 'localtime')")
            local last_week_str = conn:rowexec(
                "SELECT strftime('%Y-%W', 'now', '-7 days', 'localtime')")

            local current_weeks = 0
            if #weeks > 0 then
                local newest = weeks[1]
                if newest == current_week_str or newest == last_week_str then
                    current_weeks = 1
                    for i = 2, #weeks do
                        if isConsecutiveWeek(weeks[i - 1], weeks[i]) then
                            current_weeks = current_weeks + 1
                        else
                            break
                        end
                    end
                end
            end

            out = { current = current, current_weeks = current_weeks }
        end)
        conn:close()
        if not ok_q then error(err) end
        return out
    end)

    if not ok then
        require("logger").warn("[bookshelf] reading streak query failed:", res)
        return nil
    end
    return res
end

local function readStreak()
    if _streak_cache and os.time() - _streak_cache.at < STREAK_TTL_S then
        return _streak_cache.data or nil
    end
    local result = queryStreak()
    _streak_cache = { at = os.time(), data = result or false }
    return result
end

return {
    key   = "reading_streak", -- stable id stored in user menus; never change it
    title = _("Reading streak"),
    render = function(width)
        local Fonts         = require("lib/bookshelf_fonts")
        local TextWidget    = require("ui/widget/textwidget")
        local VerticalGroup = require("ui/widget/verticalgroup")
        local SM            = require("lib/bookshelf_start_menu_modules")

        local s = readStreak()
        local mw = math.max(50, width)

        local face_b, bold_b = Fonts:getFace("cfont", 15, {bold = true})
        local face_s = Fonts:getFace("cfont", 14)

        if not s then
            return VerticalGroup:new{
                align = "left",
                TextWidget:new{
                    text      = _("Reading streak"),
                    face      = face_b,
                    bold      = bold_b,
                    fgcolor   = SM.COLOR_MUTED,
                    max_width = mw,
                },
                TextWidget:new{
                    text      = _("Stats unavailable"),
                    face      = face_s,
                    fgcolor   = SM.COLOR_MUTED,
                    max_width = mw,
                },
            }
        end

        local day_text
        if s.current == 1 then
            day_text = T(_("%1 day"), s.current)
        else
            day_text = T(_("%1 days"), s.current)
        end

        local week_text
        if s.current_weeks == 1 then
            week_text = T(_("%1 week"), s.current_weeks)
        else
            week_text = T(_("%1 weeks"), s.current_weeks)
        end

        local count_text = day_text .. " \xc2\xb7 " .. week_text

        return VerticalGroup:new{
            align = "left",
            TextWidget:new{
                text      = _("Reading streak"),
                face      = face_b,
                bold      = bold_b,
                fgcolor   = SM.COLOR_MUTED,
                max_width = mw,
            },
            TextWidget:new{
                text      = count_text,
                face      = face_s,
                fgcolor   = SM.COLOR_PRIMARY,
                max_width = mw,
            },
        }
    end,
    show_settings = showSettings,
    on_tap = function()
        local ok, Dispatcher = pcall(require, "dispatcher")
        if ok then Dispatcher:execute({ [readTap()] = true }) end
    end,
}
