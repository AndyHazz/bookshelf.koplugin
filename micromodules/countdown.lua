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

-- Whole-day difference (target - today). Both anchored at local noon so a DST
-- shift can't move the day boundary and miscount by one.
local function daysUntil(y, m, d)
    local target = os.time{ year = y, month = m, day = d, hour = 12 }
    local now = os.date("*t")
    now.hour, now.min, now.sec = 12, 0, 0
    return math.floor((target - os.time(now)) / 86400 + 0.5)
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
    key     = "countdown",
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
            return Kit.valueCard{ width = width, scale_pct = scale_pct,
                value = _("Today"), sub = label }
        end
        local abs     = math.abs(n)
        local dayword = (abs == 1) and _("day") or _("days")
        local T       = require("ffi/util").template
        local sub     = (n > 0) and T(_("until %1"), label)
                                or  T(_("since %1"), label)
        return Kit.valueCard{ width = width, scale_pct = scale_pct,
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
        dialog = ButtonDialog:new{
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
        }
        UIManager:show(dialog)
    end,
}
