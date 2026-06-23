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

            -- Distinct ISO weeks (%Y-%W, Monday-first) derived from the day
            -- epochs IN LUA -- avoiding a second full scan of page_stat_data.
            -- day_epoch is the UTC ts of the localtime date, so
            -- os.date("!%Y-%W", day_epoch) yields the same label SQLite's
            -- strftime('%Y-%W', ...,'localtime') would. `days` is sorted, so all
            -- days of a week are contiguous; collapsing consecutive equal labels
            -- gives the distinct weeks in ascending order.
            local weeks = {}
            for i = 1, #days do
                local w = os.date("!%Y-%W", days[i])
                if weeks[#weeks] ~= w then weeks[#weeks + 1] = w end
            end

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

            -- Derived the same way (os.date) for internal consistency with the
            -- day-derived `weeks`, instead of two more SQLite rowexec calls.
            local current_week_str = os.date("!%Y-%W", today_epoch)
            local last_week_str    = os.date("!%Y-%W", today_epoch - ONE_DAY * 7)

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

-- Persisted last-good result (via the per-module store, a separate settings
-- file), so the first open of a SESSION shows the last-known streak instantly
-- while a fresh value is fetched in the background, instead of a placeholder.
local function persistStore()
    return require("lib/bookshelf_module_kit").moduleStore("reading_streak")
end
local function loadPersisted()
    local ok, c = pcall(function() return persistStore():get("cache") end)
    if ok and type(c) == "table" and type(c.data) == "table" then return c end
    return nil
end

local _querying = false

-- Run the (single-scan) query OFF the paint thread, refresh the caches, and ping
-- the host to re-render this card. Guarded so concurrent renders (hero grid +
-- start menu) can't fire it twice. This is what keeps a big statistics DB from
-- ever blocking the menu open (issue #194).
local function refreshInBackground(refresh)
    if _querying then return end
    _querying = true
    local UIManager = require("ui/uimanager")
    UIManager:scheduleIn(0, function()
        local result = queryStreak()
        _streak_cache = { at = os.time(), data = result or false }
        if type(result) == "table" then
            pcall(function() persistStore():set("cache", { at = os.time(), data = result }) end)
        end
        _querying = false
        if refresh then pcall(refresh) end
    end)
end

-- Non-blocking. Returns the best value available right now:
--   table -> a streak result (fresh or stale-but-shown);
--   false -> queried, statistics unavailable;
--   nil   -> nothing cached yet (loading) -- a fetch has been scheduled.
-- Always (re)schedules a background fetch when the in-memory cache is stale.
local function getStreak(refresh)
    if _streak_cache and os.time() - _streak_cache.at < STREAK_TTL_S then
        return _streak_cache.data
    end
    -- Cold in-memory cache: seed from the persisted store so we can show a value
    -- immediately (marked stale via at=0, so the fetch below still runs).
    if not _streak_cache then
        local p = loadPersisted()
        if p then _streak_cache = { at = 0, data = p.data } end
    end
    refreshInBackground(refresh)
    return _streak_cache and _streak_cache.data or nil
end

local function dayText(n)
    if n == 1 then return T(_("%1 day"), n)
    else return T(_("%1 days"), n) end
end

local function weekText(n)
    if n == 1 then return T(_("%1 week"), n)
    else return T(_("%1 weeks"), n) end
end

-- Build the streak card for a result table `s`: wide = two cards side by side,
-- otherwise one card with a "Best: …" context line.
local function buildCard(Kit, mw, scale_pct, shape, s)
    if shape == "wide" then
        local HorizontalGroup = require("ui/widget/horizontalgroup")
        local HorizontalSpan  = require("ui/widget/horizontalspan")
        -- Two columns sharing the cell width. The current-streak heading is
        -- "Streak" (not "Reading streak", which is too long for half the cell
        -- and truncated to an ellipsis) -- short enough to keep "streak" in the
        -- label so the pairing with "Best streak" reads as current-vs-best.
        -- Slightly wider inter-column gap for breathing room.
        local gap  = Kit.sc(scale_pct)(20)
        local half = math.floor((mw - gap) / 2)
        return HorizontalGroup:new{
            align = "top",
            Kit.valueCard{
                width     = half,
                scale_pct = scale_pct,
                heading   = _("Streak"),
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
end

return {
    key   = "reading_streak",
    title = _("Reading streak"),
    summary = _("From KOReader statistics. Works offline."),
    render = function(ctx)
        local width, scale_pct, preview, avail_h, shape =
            ctx.width, ctx.scale, ctx.preview, ctx.height, ctx.shape
        local Kit = require("lib/bookshelf_module_kit")
        local mw  = math.max(60, width)
        shape = shape or Kit.shape(width, avail_h)

        -- Picker preview: representative sample, never touch the DB.
        if preview then
            return buildCard(Kit, mw, scale_pct, shape,
                { current = 7, current_weeks = 1, best = 30, best_weeks = 4 })
        end

        -- Non-blocking: returns the cached value now and fetches off the paint
        -- thread, so a large statistics DB can't freeze the menu open (#194).
        local s = getStreak(ctx.refresh)
        if type(s) == "table" then
            return buildCard(Kit, mw, scale_pct, shape, s)
        end
        if s == false then
            -- queried: no statistics DB, or the query failed
            local TextWidget = require("ui/widget/textwidget")
            return TextWidget:new{
                text    = _("Stats unavailable"),
                face    = Kit.face(15, scale_pct),
                fgcolor = Kit.COLOR_MUTED,
                max_width = mw,
            }
        end
        -- nil: nothing cached yet (first-ever fetch in flight) -> brief placeholder
        return Kit.valueCard{
            width     = mw,
            scale_pct = scale_pct,
            heading   = _("Reading streak"),
            value     = "…",
        }
    end,
    show_settings = showSettings,
    on_tap = function()
        local ok, Dispatcher = pcall(require, "dispatcher")
        if ok then Dispatcher:execute({ [readTap()] = true }) end
    end,
}
