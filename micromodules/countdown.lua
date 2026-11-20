--[[
Countdown micro-module: shows "<N> days until <Label>" for a date you set, and
flips to "<N> days since <Label>" once the date has passed.

Per-instance: add it multiple times, each with its own date + label (stored on
the card's entry via ctx.config). Configured on add (date picker -> label) and
editable via long-press -> Module settings. No network.

Only gettext is required at load; every KOReader widget is required inside a
function so the file loads cleanly in standalone Lua (the contract test).
]]
local _ = require("lib/bookshelf_i18n").gettext

-- "YYYY-MM-DD" -> y, m, d numbers (or nil if absent/malformed).
local function parseDate(s)
    if type(s) ~= "string" then return nil end
    local y, m, d = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if not y then return nil end
    return tonumber(y), tonumber(m), tonumber(d)
end

local function fmtDate(y, m, d)
    return string.format("%04d-%02d-%02d", y, m, d)
end

-- Days since 1970-01-01 for a calendar date, by arithmetic alone (the civil
-- day count from Howard Hinnant's date algorithms). Not via a timestamp: on a
-- 32-bit device (Kobo, older Kindles) time_t ends in 2038, so a later target
-- came back as -1 and the count ran from 1970 instead (issue 616).
local function dayNumber(y, m, d)
    if m <= 2 then y = y - 1 end
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local mp = (m + 9) % 12
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

-- Whole-day difference (target - today). Calendar dates, not timestamps, so
-- neither a DST shift nor the 2038 limit can move it. `today` (a date table)
-- is for tests; it defaults to the local date now.
local function daysUntil(y, m, d, today)
    today = today or os.date("*t")
    return dayNumber(y, m, d) - dayNumber(today.year, today.month, today.day)
end

-- Date picker (defaults to `initial` or today) -> on_pick("YYYY-MM-DD").
local function pickDate(initial, ok_text, on_pick, on_cancel)
    local UIManager      = require("ui/uimanager")
    local DateTimeWidget = require("ui/widget/datetimewidget")
    local y, m, d = parseDate(initial)
    if not y then local t = os.date("*t"); y, m, d = t.year, t.month, t.day end
    UIManager:show(DateTimeWidget:new{
        year = y, month = m, day = d,
        ok_text = ok_text,
        title_text = _("Countdown date"),
        callback = function(t) on_pick(fmtDate(t.year, t.month, t.day)) end,
        cancel_callback = function() if on_cancel then on_cancel() end end,
    })
end

-- Label input -> on_done(label). Empty label falls back to "Countdown".
local function pickLabel(initial, ok_text, on_done, on_cancel)
    local UIManager   = require("ui/uimanager")
    local InputDialog = require("ui/widget/inputdialog")
    local input
    input = InputDialog:new{
        title = _("Countdown label"),
        input = initial or "",
        input_hint = _("e.g. Holiday"),
        buttons = {{
            { text = _("Cancel"), callback = function()
                UIManager:close(input); if on_cancel then on_cancel() end
            end },
            { text = ok_text, is_enter_default = true, callback = function()
                local txt = input:getInputText()
                UIManager:close(input)
                on_done((txt and txt ~= "") and txt or _("Countdown"))
            end },
        }},
    }
    UIManager:show(input)
    input:onShowKeyboard()
end

return {
    -- Test hooks: the date maths is pure (calendar day numbers, so neither
    -- DST nor the 2038 limit can miscount); the registry ignores underscore keys.
    _parseDate = parseDate,
    _fmtDate   = fmtDate,
    _daysUntil = daysUntil,
    key     = "countdown",
    -- Text: unreadable one grid column wide (truncates or breaks words).
    min_w = 2,
    title   = _("Countdown"),
    summary = _("From a date you set. Works offline."),

    render = function(ctx)
        local Kit = require("lib/bookshelf_module_kit")
        local width, scale_pct, preview = ctx.width, ctx.scale, ctx.preview
        local date  = ctx.config:get("target_date")
        local label = ctx.config:get("label", _("Countdown"))

        -- Picker preview (no real config yet): a representative sample.
        if preview and not date then
            return Kit.valueCard{ width = width, scale_pct = scale_pct,
                value = "42", suffix = " " .. _("days"), sub = _("until …") }
        end

        local y, m, d = parseDate(date)
        if not y then
            -- No / malformed date: a muted hint (set it via long-press settings).
            return Kit.fitText{ text = _("Set a date"), size = 16,
                scale_pct = scale_pct, width = math.max(50, width),
                fgcolor = Kit.COLOR_MUTED }
        end

        local n = daysUntil(y, m, d)
        if n == 0 then
            return Kit.valueCard{ width = width, scale_pct = scale_pct, height = ctx.height,
                value = _("Today"), sub = label }
        end
        local abs     = math.abs(n)
        local dayword = (abs == 1) and _("day") or _("days")
        local T       = require("ffi/util").template
        local sub     = (n > 0) and T(_("until %1"), label)
                                or  T(_("since %1"), label)
        return Kit.valueCard{ width = width, scale_pct = scale_pct, height = ctx.height,
            value = tostring(abs), suffix = " " .. dayword, sub = sub }
    end,

    -- Add flow: pick a date, then a label. Cancelling either aborts the add.
    on_add = function(_host_ctx, done)
        pickDate(nil, _("Next"), function(date)
            pickLabel(nil, _("Add"),
                function(label) done({ target_date = date, label = label }) end,
                function() done(nil) end)
        end, function() done(nil) end)
    end,

    -- Long-press -> Module settings: change the date or the label.
    show_settings = function(ctx)
        if not ctx or not ctx.config then return end
        local UIManager    = require("ui/uimanager")
        local ButtonDialog = require("ui/widget/buttondialog")
        local dialog
        local function close(fn)
            return function() UIManager:close(dialog); if fn then fn() end end
        end
        dialog = ButtonDialog:new(require("lib/bookshelf_module_kit").withClose{
            title = _("Countdown"), title_align = "center", width_factor = 0.7,
            buttons = {
                {{ text = _("Change date\xE2\x80\xA6"), callback = close(function()
                    pickDate(ctx.config:get("target_date"), _("Set date"),
                        function(date) ctx.config:set("target_date", date) end)
                end) }},
                {{ text = _("Change label\xE2\x80\xA6"), callback = close(function()
                    pickLabel(ctx.config:get("label", ""), _("Save"),
                        function(label) ctx.config:set("label", label) end)
                end) }},
            },
        })
        UIManager:show(dialog)
    end,
}
