--[[
Start-menu module: today's / this week's reading time from KOReader's
statistics plugin database. See README.md in this directory for the
module spec contract.
]]
local _ = require("lib/bookshelf_i18n").gettext
local T = require("ffi/util").template

local function fmtDuration(secs)
    secs = tonumber(secs) or 0
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    if h > 0 then return T(_("%1h %2m"), h, string.format("%02d", m)) end
    return T(_("%1m"), m)
end

-- Focus-step rebuilds re-render module rows on every keystroke; a short
-- TTL keeps sqlite out of that path while staying fresh across reopens.
local STATS_TTL_S = 30
local _stats_cache -- { at = <epoch>, data = <queryStats result or false> }

-- Returns { today_secs, today_pages, week_secs } or nil. Never blocks long:
-- read-only open + 200ms busy timeout; any failure -> nil.
local function queryStats()
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
            local now = os.time()
            local t = os.date("*t", now)
            local day_start = os.time{ year = t.year, month = t.month,
                day = t.day, hour = 0, min = 0, sec = 0 }
            local week_start = day_start - ((t.wday + 5) % 7) * 86400 -- Monday
            local stmt = conn:prepare([[
                SELECT COALESCE(SUM(duration), 0),
                       COUNT(DISTINCT (id_book || ':' || page))
                FROM page_stat_data WHERE start_time >= ?]])
            local today = stmt:bind(day_start):step()
            stmt:clearbind():reset()
            local week = stmt:bind(week_start):step()
            stmt:close()
            out = {
                today_secs  = tonumber(today[1]) or 0,
                today_pages = tonumber(today[2]) or 0,
                week_secs   = tonumber(week[1]) or 0,
            }
        end)
        conn:close()
        if not ok_q then error(err) end
        return out
    end)
    if not ok then
        require("logger").warn("[bookshelf] start menu stats unavailable:", res)
        return nil
    end
    return res
end

local function readStats()
    if _stats_cache and os.time() - _stats_cache.at < STATS_TTL_S then
        return _stats_cache.data or nil
    end
    local result = queryStats()
    _stats_cache = { at = os.time(), data = result or false }
    return result
end

return {
    key   = "stats", -- stable id stored in user menus; never change it
    title = _("Reading stats"),
    summary = _("From KOReader statistics. Works offline."),
    -- Heading + prominent "today" duration + pages + this-week, built via the
    -- shared valueCard (matches reading_goal; the parent sizes the font).
    -- Reference for the optional aspect hint: in a WIDE cell, lay today's stats
    -- and this-week side by side instead of stacked. `shape` is the 6th render
    -- arg; fall back to deriving it so the start menu / picker still work.
    render = function(ctx)
        local width, scale_pct, _preview, avail_h, _refresh, shape = ctx.width, ctx.scale, ctx.preview, ctx.height, ctx.refresh, ctx.shape
        local Kit = require("lib/bookshelf_module_kit")
        local mw  = math.max(50, width)
        local s = readStats()
        if not s then
            local TextWidget = require("ui/widget/textwidget")
            return TextWidget:new{
                text = _("Stats unavailable"),
                face = Kit.face(15, scale_pct),
                fgcolor = Kit.COLOR_MUTED, max_width = mw,
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
                Kit.valueCard{ width = half, scale_pct = scale_pct,
                    heading = _("Reading stats"), value = fmtDuration(s.today_secs),
                    suffix = " " .. _("today"), sub = T(_("%1 pages"), s.today_pages) },
                HorizontalSpan:new{ width = gap },
                Kit.valueCard{ width = half, scale_pct = scale_pct,
                    heading = _("This week"), value = fmtDuration(s.week_secs) },
            }
        end
        return Kit.valueCard{
            width = mw, scale_pct = scale_pct,
            heading = _("Reading stats"),
            value   = fmtDuration(s.today_secs),
            suffix  = " " .. _("today"),
            sub     = T(_("%1 pages"), s.today_pages),
            context = T(_("This week: %1"), fmtDuration(s.week_secs)),
        }
    end,
    on_tap = function()
        local ok, Dispatcher = pcall(require, "dispatcher")
        if ok then Dispatcher:execute({ reading_progress = true }) end
    end,
}
