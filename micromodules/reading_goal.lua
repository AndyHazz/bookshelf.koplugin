--[[
Start-menu module: reading goals — Goodreads-style reading challenge.
See README.md in this directory for the module spec contract.

Supports four goal types that cycle on tap:
  • daily   — time in minutes  (default 30)
  • weekly  — time in hours    (default 5 h)
  • monthly — books finished   (default 3)
  • yearly  — books finished   (default 24)

Each goal can be independently activated/deactivated. Tap cycles through
the active goals (keep_open = true); small dot indicators (● ○) show
position. Time data comes from statistics.sqlite3, book counts come from
ReadHistory + Repo.readProgress. Everything is TTL-cached at 30 s.
]]
local _ = require("lib/bookshelf_i18n").gettext
local T = require("ffi/util").template

-- ─── Settings keys ───────────────────────────────────────────────────────────
local KEY_ACTIVE  = "micromodule_reading_goal_active"   -- table
local KEY_DAILY   = "micromodule_reading_goal_daily"    -- minutes (int)
local KEY_WEEKLY  = "micromodule_reading_goal_weekly"   -- minutes (int, displayed as hours)
local KEY_MONTHLY = "micromodule_reading_goal_monthly"  -- books   (int)
local KEY_YEARLY  = "micromodule_reading_goal_yearly"   -- books   (int)

local GOAL_ORDER = { "daily", "weekly", "monthly", "yearly" }

local DEFAULTS = {
    active  = { daily = true, weekly = true, monthly = true, yearly = true },
    daily   = 30,    -- 30 min
    weekly  = 300,   -- 5 h
    monthly = 3,
    yearly  = 24,
}

-- ─── Settings readers ────────────────────────────────────────────────────────

local function store() return require("lib/bookshelf_settings_store") end

local function readActive()
    local t = store().read(KEY_ACTIVE, DEFAULTS.active)
    if type(t) ~= "table" then return DEFAULTS.active end
    -- guarantee at least one is on
    local any = false
    for _, g in ipairs(GOAL_ORDER) do
        if t[g] then any = true; break end
    end
    if not any then t.daily = true end
    return t
end

local function readDaily()
    local v = tonumber(store().read(KEY_DAILY, DEFAULTS.daily)) or DEFAULTS.daily
    return math.max(1, v)
end

local function readWeekly()
    local v = tonumber(store().read(KEY_WEEKLY, DEFAULTS.weekly)) or DEFAULTS.weekly
    return math.max(1, v)
end

local function readMonthly()
    local v = tonumber(store().read(KEY_MONTHLY, DEFAULTS.monthly)) or DEFAULTS.monthly
    return math.max(1, v)
end

local function readYearly()
    local v = tonumber(store().read(KEY_YEARLY, DEFAULTS.yearly)) or DEFAULTS.yearly
    return math.max(1, v)
end

-- ─── View cycling ────────────────────────────────────────────────────────────

local _current_view -- "daily" | "weekly" | "monthly" | "yearly" | nil

local function getActiveList()
    local a = readActive()
    local out = {}
    for _, g in ipairs(GOAL_ORDER) do
        if a[g] then out[#out + 1] = g end
    end
    if #out == 0 then out = { "daily" } end
    return out
end

local function getCurrentView()
    local active = getActiveList()
    if _current_view then
        for _, g in ipairs(active) do
            if g == _current_view then return _current_view end
        end
    end
    _current_view = active[1]
    return _current_view
end

local function cycleView()
    local active = getActiveList()
    local cur = getCurrentView()
    for i, g in ipairs(active) do
        if g == cur then
            _current_view = active[(i % #active) + 1]
            return
        end
    end
    _current_view = active[1]
end

-- ─── Data queries ────────────────────────────────────────────────────────────

local DATA_TTL = 30
local _data_cache -- { at = <epoch>, data = <table|false> }

-- Count books with status "finished" whose last access was within the period.
local function countFinishedBooks(period_start)
    local ok_rh, rh = pcall(require, "readhistory")
    if not ok_rh or not rh or not rh.hist then return 0 end
    local Repo = require("lib/bookshelf_book_repository")
    local count = 0
    for _, entry in ipairs(rh.hist) do
        local fp = entry.file
        if fp then
            local t = entry.time or 0
            if t >= period_start then
                local ok, _pct, status = pcall(Repo.readProgress, fp)
                if ok and status == "finished" then
                    count = count + 1
                end
            end
        end
    end
    return count
end

-- Single query for time-based goals (daily + weekly).
local function queryTimeData()
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
            local day_start = os.time{
                year = t.year, month = t.month, day = t.day,
                hour = 0, min = 0, sec = 0 }
            local week_start = day_start - ((t.wday + 5) % 7) * 86400

            -- Today
            local s1 = conn:prepare(
                "SELECT COALESCE(SUM(duration),0) FROM page_stat_data WHERE start_time>=?")
            local r1 = s1:bind(day_start):step()
            s1:close()
            local today_secs = tonumber(r1[1]) or 0

            -- This week
            local s2 = conn:prepare(
                "SELECT COALESCE(SUM(duration),0) FROM page_stat_data WHERE start_time>=?")
            local r2 = s2:bind(week_start):step()
            s2:close()
            local week_secs = tonumber(r2[1]) or 0

            out = { today_secs = today_secs, week_secs = week_secs }
        end)
        conn:close()
        if not ok_q then error(err) end
        return out
    end)
    if not ok then
        require("logger").warn("[bookshelf] reading goal time query failed:", res)
        return nil
    end
    return res
end

local function queryAllData()
    local now = os.time()
    if _data_cache and (now - _data_cache.at) < DATA_TTL then
        return _data_cache.data or nil
    end
    local time_data = queryTimeData()
    if not time_data then
        _data_cache = { at = now, data = false }
        return nil
    end

    -- Book counts for monthly / yearly
    local t = os.date("*t", now)
    local month_start = os.time{
        year = t.year, month = t.month, day = 1,
        hour = 0, min = 0, sec = 0 }
    local year_start = os.time{
        year = t.year, month = 1, day = 1,
        hour = 0, min = 0, sec = 0 }

    local month_books = countFinishedBooks(month_start)
    local year_books  = countFinishedBooks(year_start)

    local data = {
        today_secs  = time_data.today_secs,
        week_secs   = time_data.week_secs,
        month_books = month_books,
        year_books  = year_books,
    }
    _data_cache = { at = now, data = data }
    return data
end

-- ─── Helpers ─────────────────────────────────────────────────────────────────

local function fmtDuration(secs)
    secs = math.max(0, tonumber(secs) or 0)
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    if h > 0 and m > 0 then return string.format("%dh %02dm", h, m) end
    if h > 0 then return string.format("%dh", h) end
    return string.format("%dm", m)
end

local function fmtTargetHours(min)
    local h = math.floor(min / 60)
    local m = min % 60
    if h > 0 and m > 0 then return string.format("%dh %02dm", h, m) end
    if h > 0 then return string.format("%dh", h) end
    return string.format("%dm", m)
end

local MONTH_NAMES = {
    _("Jan"), _("Feb"), _("Mar"), _("Apr"), _("May"), _("Jun"),
    _("Jul"), _("Aug"), _("Sep"), _("Oct"), _("Nov"), _("Dec")
}

-- ─── Settings dialog ─────────────────────────────────────────────────────────

local function showSettings(ctx)
    local ButtonDialog = require("ui/widget/buttondialog")
    local UIManager    = require("ui/uimanager")
    local S = store()
    local dialog

    local function reload()
        _data_cache = nil
        UIManager:close(dialog)
        if ctx and ctx.menu and ctx.menu._reload then ctx.menu:_reload() end
        showSettings(ctx)
    end

    -- ── Active-goals toggle row ──
    local active = readActive()
    local function goalToggle(label, goal)
        local on = active[goal] == true
        return {
            text = (on and "\xE2\x9C\x93 " or "  ") .. label,
            callback = function()
                local a = readActive()
                a[goal] = not a[goal]
                -- ensure at least one stays active
                local any = false
                for _, g in ipairs(GOAL_ORDER) do
                    if a[g] then any = true; break end
                end
                if not any then a[goal] = true end
                S.save(KEY_ACTIVE, a)
                reload()
            end,
        }
    end

    -- ── Daily target row ──
    local function dailyBtn(label, min)
        local cur = readDaily()
        return {
            text = (cur == min and "\xE2\x9C\x93 " or "  ") .. label,
            callback = function()
                if readDaily() == min then return end
                S.save(KEY_DAILY, min)
                reload()
            end,
        }
    end

    -- ── Weekly target row ──
    local function weeklyBtn(label, min)
        local cur = readWeekly()
        return {
            text = (cur == min and "\xE2\x9C\x93 " or "  ") .. label,
            callback = function()
                if readWeekly() == min then return end
                S.save(KEY_WEEKLY, min)
                reload()
            end,
        }
    end

    -- ── Monthly target row ──
    local function monthlyBtn(n)
        local cur = readMonthly()
        return {
            text = (cur == n and "\xE2\x9C\x93 " or "  ") .. tostring(n),
            callback = function()
                if readMonthly() == n then return end
                S.save(KEY_MONTHLY, n)
                reload()
            end,
        }
    end

    -- ── Yearly target row ──
    local function yearlyBtn(n)
        local cur = readYearly()
        return {
            text = (cur == n and "\xE2\x9C\x93 " or "  ") .. tostring(n),
            callback = function()
                if readYearly() == n then return end
                S.save(KEY_YEARLY, n)
                reload()
            end,
        }
    end

    local function customTargetBtn(title, unit_text, read_fn, save_fn)
        return {
            text = _("Custom..."),
            callback = function()
                UIManager:close(dialog)
                local InputDialog = require("ui/widget/inputdialog")
                local input_dlg
                input_dlg = InputDialog:new{
                    title = title .. " (" .. unit_text .. ")",
                    input_type = "number",
                    input = tostring(read_fn()),
                    buttons = {
                        {
                            {
                                text = _("Cancel"),
                                callback = function()
                                    UIManager:close(input_dlg)
                                    showSettings(ctx)
                                end,
                            },
                            {
                                text = _("Save"),
                                is_enter_default = true,
                                callback = function()
                                    local v = tonumber(input_dlg:getInputText())
                                    if v and v > 0 then
                                        save_fn(v)
                                    end
                                    UIManager:close(input_dlg)
                                    reload()
                                end,
                            },
                        }
                    },
                }
                UIManager:show(input_dlg)
                input_dlg:onShowKeyboard()
            end,
        }
    end

    dialog = ButtonDialog:new{
        title        = _("Reading goals"),
        title_align  = "center",
        width_factor = 0.85,
        buttons      = {
            -- row 1: active goals
            { { text = _("Active goals"), enabled = false } },
            { goalToggle(_("Daily"),   "daily"),
              goalToggle(_("Weekly"),  "weekly"),
              goalToggle(_("Monthly"), "monthly"),
              goalToggle(_("Yearly"),  "yearly"), },
            -- row 2: daily target (minutes)
            { { text = _("Daily (minutes)"), enabled = false } },
            { dailyBtn("15",  15), dailyBtn("30",  30),
              dailyBtn("45",  45), dailyBtn("60",  60),
              dailyBtn("90",  90),
              customTargetBtn(_("Daily goal"), _("minutes"), readDaily, function(v) S.save(KEY_DAILY, v) end) },
            -- row 3: weekly target (hours)
            { { text = _("Weekly (hours)"), enabled = false } },
            { weeklyBtn("1h",  60),  weeklyBtn("2h", 120),
              weeklyBtn("3h", 180),  weeklyBtn("5h", 300),
              weeklyBtn("7h", 420),  weeklyBtn("10h", 600),
              customTargetBtn(_("Weekly goal"), _("hours"), function() return math.floor(readWeekly()/60) end, function(v) S.save(KEY_WEEKLY, v * 60) end) },
            -- row 4: monthly target (books)
            { { text = _("Monthly (books)"), enabled = false } },
            { monthlyBtn(1), monthlyBtn(2), monthlyBtn(3),
              monthlyBtn(4), monthlyBtn(5), monthlyBtn(8),
              customTargetBtn(_("Monthly challenge"), _("books"), readMonthly, function(v) S.save(KEY_MONTHLY, v) end) },
            -- row 5: yearly target (books)
            { { text = _("Yearly (books)"), enabled = false } },
            { yearlyBtn(6),  yearlyBtn(12), yearlyBtn(24),
              yearlyBtn(36), yearlyBtn(52),
              customTargetBtn(_("Yearly challenge"), _("books"), readYearly, function(v) S.save(KEY_YEARLY, v) end) },
        },
    }
    UIManager:show(dialog)
end

-- ─── Render ──────────────────────────────────────────────────────────────────

return {
    key   = "reading_goal",
    title = _("Reading goals"),
    keep_open = true,  -- tap cycles goals without closing menu

    render = function(width, scale_pct)
        local Blitbuffer      = require("ffi/blitbuffer")
        local Fonts           = require("lib/bookshelf_fonts")
        local TextWidget      = require("ui/widget/textwidget")
        local VerticalGroup   = require("ui/widget/verticalgroup")
        local VerticalSpan    = require("ui/widget/verticalspan")
        local HorizontalGroup = require("ui/widget/horizontalgroup")
        local Widget          = require("ui/widget/widget")
        local Geom            = require("ui/geometry")
        local mw = math.max(50, width)
        local function sc(n)
            return math.max(1, math.floor(n * (scale_pct or 100) / 100 + 0.5))
        end
        local BLACK     = Blitbuffer.COLOR_BLACK
        local DARK_GRAY = Blitbuffer.COLOR_DARK_GRAY

        local data = queryAllData()
        if not data then
            return TextWidget:new{
                text = _("Stats unavailable"),
                face = Fonts:getFace("cfont", sc(15)),
                fgcolor = DARK_GRAY, max_width = mw,
            }
        end

        local view   = getCurrentView()
        local active = getActiveList()

        -- ── Compute display values per goal type ──
        local header_text, big_text, suffix, pct, context_text
        local t = os.date("*t")

        if view == "daily" then
            local target = readDaily()
            local today_min = math.floor(data.today_secs / 60)
            local met = today_min >= target
            header_text  = _("Daily goal")
            big_text     = tostring(today_min)
            suffix       = " / " .. tostring(target) .. " min"
            if met then suffix = suffix .. " \xE2\x9C\x93" end
            pct          = math.min(1, data.today_secs / math.max(1, target * 60))
            local left   = math.max(0, target - today_min)
            context_text = met and _("Goal met!") or T(_("%1 min left"), left)

        elseif view == "weekly" then
            local target = readWeekly()
            local target_secs = target * 60
            local met = data.week_secs >= target_secs
            header_text  = _("Weekly goal")
            big_text     = fmtDuration(data.week_secs)
            suffix       = " / " .. fmtTargetHours(target)
            if met then suffix = suffix .. " \xE2\x9C\x93" end
            pct          = math.min(1, data.week_secs / math.max(1, target_secs))
            local left_s = math.max(0, target_secs - data.week_secs)
            context_text = met and _("Goal met!")
                or T(_("%1 left"), fmtDuration(left_s))

        elseif view == "monthly" then
            local target = readMonthly()
            local met = data.month_books >= target
            header_text  = T(_("%1 challenge"), MONTH_NAMES[t.month] or "")
            big_text     = tostring(data.month_books)
            suffix       = " / " .. tostring(target) .. " "
                .. (target == 1 and _("book") or _("books"))
            if met then suffix = suffix .. " \xE2\x9C\x93" end
            pct          = math.min(1, data.month_books / math.max(1, target))
            local left   = math.max(0, target - data.month_books)
            context_text = met and _("Goal met!")
                or T(_("%1 to go"), left)

        elseif view == "yearly" then
            local target = readYearly()
            local met = data.year_books >= target
            header_text  = T(_("%1 challenge"), tostring(t.year))
            big_text     = tostring(data.year_books)
            suffix       = " / " .. tostring(target) .. " "
                .. (target == 1 and _("book") or _("books"))
            if met then suffix = suffix .. " \xE2\x9C\x93" end
            pct          = math.min(1, data.year_books / math.max(1, target))
            local months_left = 12 - t.month
            context_text = met and _("Goal met!")
                or T(_("%1 months left"), months_left)
        end

        -- ── Build the widget tree ──
        local group = VerticalGroup:new{ align = "left" }

        -- Header
        local face_h, bold_h = Fonts:getFace("cfont", sc(15), {bold = true})
        group[#group + 1] = TextWidget:new{
            text = header_text, face = face_h, bold = bold_h,
            fgcolor = BLACK, max_width = mw,
        }

        -- Big progress number + suffix (baseline-aligned)
        local face_big, bold_big = Fonts:getFace("cfont", sc(20), {bold = true})
        local face_suf = Fonts:getFace("cfont", sc(14))
        local num_tw = TextWidget:new{
            text = big_text, face = face_big, bold = bold_big,
            fgcolor = BLACK, max_width = mw,
        }
        local suf_tw = TextWidget:new{
            text = suffix, face = face_suf,
            fgcolor = BLACK,
            max_width = math.max(10, mw - num_tw:getSize().w),
        }
        local dy = math.max(0, num_tw:getBaseline() - suf_tw:getBaseline())
        group[#group + 1] = HorizontalGroup:new{
            align = "top",
            num_tw,
            VerticalGroup:new{
                align = "left",
                VerticalSpan:new{ width = dy },
                suf_tw,
            },
        }

        -- Progress bar (full width)
        group[#group + 1] = VerticalSpan:new{ width = sc(4) }
        local bar_h = sc(6)
        local bar_w = mw
        local fill_w = math.max(0, math.min(bar_w, math.floor(bar_w * (pct or 0))))
        local Bar = Widget:extend{}
        function Bar:init()   self.dimen = Geom:new{ w = bar_w, h = bar_h } end
        function Bar:getSize() return Geom:new{ w = bar_w, h = bar_h } end
        function Bar:paintTo(bb, x, y)
            self.dimen = Geom:new{ x = x, y = y, w = bar_w, h = bar_h }
            bb:paintRect(x, y, bar_w, bar_h, Blitbuffer.Color8(0xCC))
            if fill_w > 0 then
                bb:paintRect(x, y, fill_w, bar_h, BLACK)
            end
        end
        group[#group + 1] = Bar:new{}

        -- Context line
        group[#group + 1] = VerticalSpan:new{ width = sc(3) }
        local face_ctx = Fonts:getFace("cfont", sc(13), {italic = true})

        group[#group + 1] = TextWidget:new{
            text = context_text, face = face_ctx,
            fgcolor = BLACK, max_width = mw,
        }

        return group
    end,

    on_tap = function(ctx)
        cycleView()
    end,

    show_settings = showSettings,
}
