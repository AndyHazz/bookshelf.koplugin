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

-- The hero shows goals paired (2 per view) when the cell is tall enough; the
-- start menu shows one per view. _current_view is the ANCHOR goal — the first
-- goal of the visible view. A "view" is the chunk of `per_view` active goals
-- aligned to the chunk boundary containing the anchor. _last_per_view is set by
-- render() so on_tap's cycleView (which has no render context) steps by the
-- right chunk size — pairs in the hero, singles in the start menu.
local _current_view    -- anchor goal key | nil
local _last_per_view = 1

local function getActiveList()
    local a = readActive()
    local out = {}
    for _, g in ipairs(GOAL_ORDER) do
        if a[g] then out[#out + 1] = g end
    end
    if #out == 0 then out = { "daily" } end
    return out
end

-- Index of the anchor goal within the active list; normalises _current_view
-- into the list (1) when unset or stale (the anchored goal was deactivated).
local function anchorIndex(active)
    if _current_view then
        for i, g in ipairs(active) do
            if g == _current_view then return i end
        end
    end
    _current_view = active[1]
    return 1
end

local function getCurrentView()
    anchorIndex(getActiveList())
    return _current_view
end

-- Goals shown in the current view: the chunk of `per_view` active goals aligned
-- to a chunk boundary containing the anchor — so with all four active and
-- per_view=2 the views are daily+weekly then monthly+yearly, whichever of a
-- pair happens to be the anchor.
local function getViewGoals(per_view)
    per_view = math.max(1, per_view or 1)
    local active = getActiveList()
    local idx = anchorIndex(active)
    local start = idx - ((idx - 1) % per_view)
    local out = {}
    for i = start, math.min(start + per_view - 1, #active) do
        out[#out + 1] = active[i]
    end
    return out
end

-- Advance to the next view (next chunk), wrapping. Steps by the per_view of the
-- last render, so a hero tap moves a pair at a time and a start-menu tap one.
local function cycleView()
    local per_view = math.max(1, _last_per_view or 1)
    local active = getActiveList()
    local idx = anchorIndex(active)
    local start = idx - ((idx - 1) % per_view)
    local next_start = start + per_view
    if next_start > #active then next_start = 1 end
    _current_view = active[next_start]
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

-- Compute the display fields (header / big number / suffix / progress / context)
-- for one goal type against the current stats. `t` is os.date("*t").
local function computeGoal(goal, data, t)
    local header_text, big_text, suffix, pct, context_text
    if goal == "daily" then
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

    elseif goal == "weekly" then
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

    elseif goal == "monthly" then
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

    elseif goal == "yearly" then
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
    return header_text, big_text, suffix, pct, context_text
end

-- Build one goal's widget block: header, big progress number + baseline-aligned
-- suffix, a full-width progress bar, and a context line. `sc` is the caller's
-- font-scale helper; `mw` the inner width. Returned widget owns a fresh tree.
local function buildGoalBlock(goal, mw, scale_pct, data, t)
    local Blitbuffer = require("ffi/blitbuffer")
    local Widget     = require("ui/widget/widget")
    local Geom       = require("ui/geometry")
    local Kit        = require("lib/bookshelf_module_kit")
    local sc = Kit.sc(scale_pct)
    -- BLACK is the progress-bar FILL (a drawing colour, not text).
    local BLACK = Blitbuffer.COLOR_BLACK

    local header_text, big_text, suffix, pct, context_text = computeGoal(goal, data, t)

    -- Full-width progress bar: a custom Widget (reading_goal's signature look),
    -- passed to valueCard as its `bar`. bar_w = mw fills the card; the offscreen
    -- ClipContainer keeps it inside the cell.
    local bar_h  = sc(6)
    local bar_w  = mw
    local fill_w = math.max(0, math.min(bar_w, math.floor(bar_w * (pct or 0))))
    local Bar = Widget:extend{}
    function Bar:init()   self.dimen = Geom:new{ w = bar_w, h = bar_h } end
    function Bar:getSize() return Geom:new{ w = bar_w, h = bar_h } end
    function Bar:paintTo(bb, x, y)
        self.dimen = Geom:new{ x = x, y = y, w = bar_w, h = bar_h }
        bb:paintRect(x, y, bar_w, bar_h, Blitbuffer.Color8(0xCC))
        if fill_w > 0 then bb:paintRect(x, y, fill_w, bar_h, BLACK) end
    end

    return Kit.valueCard{
        width = mw, scale_pct = scale_pct,
        heading = header_text, value = big_text, suffix = suffix,
        bar = Bar:new{}, context = context_text,
    }
end

return {
    key   = "reading_goal",
    title = _("Reading goals"),
    summary = _("From your reading stats. Works offline."),
    keep_open = true,  -- tap cycles goals without closing menu

    render = function(ctx)
        local width, scale_pct, preview, avail_h = ctx.width, ctx.scale, ctx.preview, ctx.height
        local Fonts         = require("lib/bookshelf_fonts")
        local TextWidget    = require("ui/widget/textwidget")
        local VerticalGroup = require("ui/widget/verticalgroup")
        local VerticalSpan  = require("ui/widget/verticalspan")
        local SM            = require("lib/bookshelf_start_menu_modules")
        local mw = math.max(50, width)
        local function sc(n)
            return math.max(1, math.floor(n * (scale_pct or 100) / 100 + 0.5))
        end

        local data = queryAllData()
        if not data then
            return TextWidget:new{
                text = _("Stats unavailable"),
                face = Fonts:getFace("cfont", sc(15)),
                fgcolor = SM.COLOR_MUTED, max_width = mw,
            }
        end

        local t = os.date("*t")
        local gap = sc(12)

        -- Pair goals (2 per view) when a single goal block uses less than 65%
        -- of the cell height — i.e. there's room for a second one (the host's
        -- auto-fit shrinks the paired card a little if needed). Below that, one
        -- goal per view (the start menu passes no avail_h; a short cell stays
        -- single). The gate only gets easier as the scale drops, so per_view
        -- stays stable (never flips 2->1) across the host's fit iterations.
        local per_view = 1
        if avail_h and avail_h > 0 and not preview and #getActiveList() >= 2 then
            local probe = buildGoalBlock(getCurrentView(), mw, scale_pct, data, t)
            local h1 = probe:getSize().h
            if probe.free then probe:free() end
            if h1 < 0.65 * avail_h then per_view = 2 end
        end
        _last_per_view = per_view  -- on_tap's cycleView steps by this

        local goals = getViewGoals(per_view)
        if #goals <= 1 then
            return buildGoalBlock(goals[1] or getCurrentView(), mw, scale_pct, data, t)
        end
        local container = VerticalGroup:new{ align = "left" }
        for i, g in ipairs(goals) do
            if i > 1 then container[#container + 1] = VerticalSpan:new{ width = gap } end
            container[#container + 1] = buildGoalBlock(g, mw, scale_pct, data, t)
        end
        return container
    end,

    on_tap = function(ctx)
        cycleView()
    end,

    show_settings = showSettings,
}
