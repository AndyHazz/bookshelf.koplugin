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
    if h > 0 then return string.format("%dh %02dm", h, m) end
    return string.format("%dm", m)
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
    render = function(width)
        local Blitbuffer    = require("ffi/blitbuffer")
        local Fonts         = require("lib/bookshelf_fonts")
        local TextWidget    = require("ui/widget/textwidget")
        local VerticalGroup = require("ui/widget/verticalgroup")
        local s = readStats()
        if not s then
            return TextWidget:new{
                text = _("Stats unavailable"),
                face = Fonts:getFace("cfont", 15),
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
                max_width = math.max(50, width),
            }
        end
        local face_b, bold_b = Fonts:getFace("cfont", 15, {bold=true})
        local face_s = Fonts:getFace("cfont", 14)
        local mw = math.max(50, width)
        return VerticalGroup:new{
            align = "left",
            TextWidget:new{ text = _("Reading stats"), face = face_b,
                bold = bold_b, fgcolor = Blitbuffer.COLOR_BLACK, max_width = mw },
            TextWidget:new{
                text = T(_("Today: %1 \xC2\xB7 %2 pages"),
                    fmtDuration(s.today_secs), s.today_pages),
                face = face_s, fgcolor = Blitbuffer.COLOR_BLACK, max_width = mw },
            TextWidget:new{
                text = T(_("This week: %1"), fmtDuration(s.week_secs)),
                face = face_s, fgcolor = Blitbuffer.COLOR_BLACK, max_width = mw },
        }
    end,
    on_tap = function()
        local ok, Dispatcher = pcall(require, "dispatcher")
        if ok then Dispatcher:execute({ reading_progress = true }) end
    end,
}
