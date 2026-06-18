--[[
Start-menu module: reading streak.
Shows the current consecutive-day and best reading streak from KOReader's
statistics plugin database (statistics.sqlite3).
]]
local _ = require("lib/bookshelf_i18n").gettext
local T = require("ffi/util").template

local STREAK_TTL_S = 30
local TAP_KEY = "micromodule_reading_streak_tap"

local function readTap()
    local Store = require("lib/bookshelf_settings_store")
    local v = Store.read(TAP_KEY, "stats_calendar_view")
    if v ~= "stats_calendar_view" then v = "reading_insights_popup" end
    return v
end
local _streak_cache

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

-- Returns { current, current_weeks, best, best_weeks } or nil
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

            -- Napi széria
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

            local today_stmt = conn:prepare([[
                SELECT CAST(strftime('%s',
                       date('now', 'localtime'))
                    AS INTEGER)
            ]])
            local today_row = today_stmt:step()
            local today_epoch = tonumber(today_row[1]) or 0
            today_stmt:close()
            local yesterday_epoch = today_epoch - ONE_DAY

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

            local best = 0
            if #days > 0 then
                local run = 1
                best = 1
                for i = 2, #days do
                    if days[i] == days[i-1] + ONE_DAY then
                        run = run + 1
                        if run > best then best = run end
                    else
                        run = 1
                    end
                end
            end

            local week_stmt = conn:prepare([[
                SELECT DISTINCT strftime('%Y-%W', start_time, 'unixepoch', 'localtime') AS yw
                FROM page_stat_data
                ORDER BY yw ASC
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

            local function isConsecutiveWeek(older, newer)
                local oy, ow = parseWeekYear(older)
                local ny, nw = parseWeekYear(newer)
                if not ny or not oy then return false end
                if ny == oy and nw == ow + 1 then return true end
                if ny == oy + 1 and nw == 0 and ow >= 52 then return true end
                return false
            end

            local current_week_str = conn:rowexec(
                "SELECT strftime('%Y-%W', 'now', 'localtime')")
            local last_week_str = conn:rowexec(
                "SELECT strftime('%Y-%W', 'now', '-7 days', 'localtime')")

            local best_weeks = 0
            if #weeks > 0 then
                local run = 1
                best_weeks = 1
                for i = 2, #weeks do
                    if isConsecutiveWeek(weeks[i-1], weeks[i]) then
                        run = run + 1
                        if run > best_weeks then best_weeks = run end
                    else
                        run = 1
                    end
                end
            end

            local current_weeks = 0
            if #weeks > 0 then
                local newest = weeks[#weeks]
                if newest == current_week_str or newest == last_week_str then
                    current_weeks = 1
                    for i = #weeks - 1, 1, -1 do
                        if isConsecutiveWeek(weeks[i], weeks[i+1]) then
                            current_weeks = current_weeks + 1
                        else
                            break
                        end
                    end
                end
            end

            out = {
                current       = current,
                current_weeks = current_weeks,
                best          = best,
                best_weeks    = best_weeks,
            }
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

local function dayText(n)
    if n == 1 then return T(_("%1 day"), n)
    else return T(_("%1 days"), n) end
end

local function weekText(n)
    if n == 1 then return T(_("%1 week"), n)
    else return T(_("%1 weeks"), n) end
end

return {
    key   = "reading_streak",
    title = _("Reading streak"),
    summary = _("From KOReader statistics. Works offline."),
    render = function(width, scale_pct, _preview, avail_h, _refresh, shape)
        local Kit = require("lib/bookshelf_module_kit")
        local mw  = math.max(60, width)

        local s = readStreak()
        if not s then
            local TextWidget = require("ui/widget/textwidget")
            return TextWidget:new{
                text    = _("Stats unavailable"),
                face    = Kit.face(15, scale_pct),
                fgcolor = Kit.COLOR_MUTED,
                max_width = mw,
            }
        end

        shape = shape or Kit.shape(width, avail_h)

        if shape == "wide" then
            local HorizontalGroup = require("ui/widget/horizontalgroup")
            local HorizontalSpan  = require("ui/widget/horizontalspan")
            local gap  = Kit.sc(scale_pct)(12)
            local half = math.floor((mw - gap) / 2)
            return HorizontalGroup:new{
                align = "top",
                Kit.valueCard{
                    width     = half,
                    scale_pct = scale_pct,
                    heading   = _("Reading streak"),
                    value     = tostring(s.current),
                    suffix    = " " .. (s.current == 1 and _("day") or _("days")),
                    sub       = weekText(s.current_weeks),
                },
                HorizontalSpan:new{ width = gap },
                Kit.valueCard{
                    width     = half,
                    scale_pct = scale_pct,
                    heading   = _("Best streak"),
                    value     = tostring(s.best),
                    suffix    = " " .. (s.best == 1 and _("day") or _("days")),
                    sub       = weekText(s.best_weeks),
                },
            }
        end

        return Kit.valueCard{
            width     = mw,
            scale_pct = scale_pct,
            heading   = _("Reading streak"),
            value     = tostring(s.current),
            suffix    = " " .. (s.current == 1 and _("day") or _("days")),
            sub       = weekText(s.current_weeks),
            context   = T(_("Best: %1 · %2"), dayText(s.best), weekText(s.best_weeks)),
        }
    end,
    show_settings = showSettings,
    on_tap = function()
        local ok, Dispatcher = pcall(require, "dispatcher")
        if ok then Dispatcher:execute({ [readTap()] = true }) end
    end,
}
