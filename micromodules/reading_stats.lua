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
    summary = _("From KOReader statistics. Works offline."),
    -- render(width, scale_pct): fonts scale with the cell (the old fixed 14/15
    -- left big cells looking sparse). Heading + a prominent "today" duration
    -- (big number + baseline-aligned suffix, same treatment as the reading-goal
    -- card) + a pages sub-line + this-week context.
    render = function(width, scale_pct)
        local Fonts           = require("lib/bookshelf_fonts")
        local TextWidget      = require("ui/widget/textwidget")
        local VerticalGroup   = require("ui/widget/verticalgroup")
        local VerticalSpan    = require("ui/widget/verticalspan")
        local HorizontalGroup = require("ui/widget/horizontalgroup")
        local SM              = require("lib/bookshelf_start_menu_modules")
        local mw = math.max(50, width)
        local function sc(n) return math.max(1, math.floor(n * (scale_pct or 100) / 100 + 0.5)) end
        local s = readStats()
        if not s then
            return TextWidget:new{
                text = _("Stats unavailable"),
                face = Fonts:getFace("cfont", sc(15)),
                fgcolor = SM.COLOR_MUTED, max_width = mw,
            }
        end

        local group = VerticalGroup:new{ align = "left" }

        -- Heading
        local face_h, bold_h = Fonts:getFace("cfont", sc(15), {bold = true})
        group[#group + 1] = TextWidget:new{
            text = _("Reading stats"), face = face_h, bold = bold_h,
            fgcolor = SM.COLOR_MUTED, max_width = mw }

        -- Big today-duration + " today" suffix (baseline-aligned)
        local face_big, bold_big = Fonts:getFace("cfont", sc(22), {bold = true})
        local face_suf = Fonts:getFace("cfont", sc(13))
        local num_tw = TextWidget:new{
            text = fmtDuration(s.today_secs), face = face_big, bold = bold_big,
            fgcolor = SM.COLOR_PRIMARY, max_width = mw }
        local suf_tw = TextWidget:new{
            text = " " .. _("today"), face = face_suf,
            fgcolor = SM.COLOR_MUTED,
            max_width = math.max(10, mw - num_tw:getSize().w) }
        local dy = math.max(0, num_tw:getBaseline() - suf_tw:getBaseline())
        group[#group + 1] = HorizontalGroup:new{
            align = "top",
            num_tw,
            VerticalGroup:new{ align = "left",
                VerticalSpan:new{ width = dy }, suf_tw },
        }

        -- Pages today (muted sub-line)
        group[#group + 1] = TextWidget:new{
            text = T(_("%1 pages"), s.today_pages),
            face = Fonts:getFace("cfont", sc(13)),
            fgcolor = SM.COLOR_MUTED, max_width = mw }

        -- This week (context line)
        group[#group + 1] = VerticalSpan:new{ width = sc(4) }
        group[#group + 1] = TextWidget:new{
            text = T(_("This week: %1"), fmtDuration(s.week_secs)),
            face = Fonts:getFace("cfont", sc(14)),
            fgcolor = SM.COLOR_PRIMARY, max_width = mw }

        return group
    end,
    on_tap = function()
        local ok, Dispatcher = pcall(require, "dispatcher")
        if ok then Dispatcher:execute({ reading_progress = true }) end
    end,
}
