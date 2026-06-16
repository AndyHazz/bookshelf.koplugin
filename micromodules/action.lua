--[[
Hero micro-module: a single action card. Stores its chosen action + label +
icon on its own hero entry (per-instance config; the hero sanitize preserves
the fields). Renders a large centred icon with the optional label beneath, and
on tap behaves exactly like the equivalent start-menu entry. See README.md for
the per-instance contract (the `entry` render arg, ctx.entry/ctx.save, on_add).
]]
local _ = require("lib/bookshelf_i18n").gettext

local DEFAULT_ICON = "\xEE\xAC\xB0" -- mdi-puzzle (shown until the user picks one)

-- Build the icon widget for an icon value: SVG/PNG via [icon=NAME], else a
-- glyph. `px` is the target square size. Mirrors the start-menu icon path.
local function buildIcon(icon_value, px, fg)
    local SMModel = require("lib/bookshelf_start_menu_model")
    local img = SMModel.imageIconName(icon_value)
    if img then
        local IconWidget = require("ui/widget/iconwidget")
        local iw = IconWidget:new{ icon = img, width = px, height = px, alpha = true }
        if iw.file and iw.file:find("icon-not-found", 1, true) then
            return nil
        end
        return iw
    end
    local Font       = require("ui/font")
    local TextWidget = require("ui/widget/textwidget")
    return TextWidget:new{
        text    = (icon_value and icon_value ~= "") and icon_value or DEFAULT_ICON,
        face    = Font:getFace("symbols", px),
        fgcolor = fg,
    }
end

return {
    key   = "action",
    title = _("Action"),
    summary = _("Launches a plugin or system action. Works offline."),

    -- entry (7th arg) carries this card's config: label, icon, and one of
    -- action|plugin|internal. nil in the picker preview -> a generic tile.
    render = function(width, scale_pct, preview, avail_h, _refresh, _shape, entry)
        local Kit            = require("lib/bookshelf_module_kit")
        local VerticalGroup  = require("ui/widget/verticalgroup")
        local VerticalSpan   = require("ui/widget/verticalspan")
        local mw  = math.max(50, width)
        local fg  = Kit.COLOR_PRIMARY

        local label = entry and entry.label
        local icon_value = entry and entry.icon
        if preview or not entry then
            label = label or _("Action")
            icon_value = icon_value or DEFAULT_ICON
        end

        -- Size the icon to fill the cell, tied to scale_pct so the parent fit
        -- engine can grow/shrink it: base fraction of the cell height (less when
        -- a label shares the cell), then scaled. Glyphs paint a touch larger
        -- than the requested face size; the hero ClipContainer backstops any
        -- overflow.
        local box_h = (avail_h and avail_h > 0) and avail_h or mw
        local has_label = type(label) == "string" and label ~= ""
        local frac = has_label and 0.46 or 0.60
        local icon_px = Kit.sc(scale_pct)(math.floor(box_h * frac))
        icon_px = math.max(16, math.min(icon_px, mw, box_h))

        local icon = buildIcon(icon_value, icon_px, fg)
        if not icon then
            -- icon-not-found -> the default glyph, so the card is never blank.
            icon = buildIcon(DEFAULT_ICON, icon_px, fg)
        end

        if not has_label then
            return icon
        end
        local gap = Kit.sc(scale_pct)(6)
        local label_w = Kit.fitText{
            text = label, size = 15, scale_pct = scale_pct,
            width = mw, max_h = math.max(1, box_h - icon_px - gap),
            fgcolor = fg, align = "center",
        }
        return VerticalGroup:new{
            align = "center",
            icon,
            VerticalSpan:new{ width = gap },
            label_w,
        }
    end,

    -- Interactive add: pick an action (sets label + action/plugin/internal),
    -- then pick an icon. done(fields) inserts the card; done(nil) cancels.
    on_add = function(_host_ctx, done)
        local Chooser      = require("lib/bookshelf_action_chooser")
        local UIManager    = require("ui/uimanager")
        local ButtonDialog = require("ui/widget/buttondialog")
        local dialog
        local function close(fn)
            return function() UIManager:close(dialog); if fn then fn() end end
        end
        dialog = ButtonDialog:new{
            title = _("Add action"), title_align = "center", width_factor = 0.65,
            buttons = Chooser.actionRows(close, function(fields)
                -- After the action is chosen, offer an icon (optional).
                local IconsLibrary = require("lib/bookshelf_icons_library")
                IconsLibrary:show(function(value)
                    if value and value ~= "" then fields.icon = value end
                    done(fields)
                end, { dynamic = false, svg = true })
            end),
        }
        UIManager:show(dialog)
    end,

    -- Tap: close the bookshelf then run the action (like the start menu).
    -- ctx.entry holds this card's action; ctx.bw is the bookshelf. For
    -- internal=close, Exec.dispatch performs the close itself, so don't double.
    on_tap = function(ctx)
        local entry = ctx and ctx.entry
        local bw = ctx and ctx.bw
        if not entry then return end
        local UIManager = require("ui/uimanager")
        if bw and bw.onClose and entry.internal ~= "close" then
            bw:onClose()
        end
        UIManager:nextTick(function()
            require("lib/bookshelf_action_exec").dispatch(entry, bw)
        end)
    end,

    -- Long-press settings: change the action, edit/clear the label (clear =
    -- icon-only), or change the icon. Each mutates ctx.entry then ctx.save().
    show_settings = function(ctx)
        local entry = ctx and ctx.entry
        if not entry or not ctx.save then return end
        local UIManager    = require("ui/uimanager")
        local ButtonDialog = require("ui/widget/buttondialog")
        local InputDialog  = require("ui/widget/inputdialog")
        local Chooser      = require("lib/bookshelf_action_chooser")
        local dialog
        local function close(fn)
            return function() UIManager:close(dialog); if fn then fn() end end
        end

        local rows = {
            { { text = _("Change action\xE2\x80\xA6"), callback = close(function()
                local d2
                local function c2(fn)
                    return function() UIManager:close(d2); if fn then fn() end end
                end
                d2 = ButtonDialog:new{
                    title = _("Change action"), title_align = "center",
                    width_factor = 0.65,
                    buttons = Chooser.actionRows(c2, function(fields)
                        -- Overwrite action discriminators + label; keep the icon.
                        entry.action   = fields.action
                        entry.plugin   = fields.plugin
                        entry.internal = fields.internal
                        entry.label    = fields.label
                        ctx.save()
                    end),
                }
                UIManager:show(d2)
            end) } },
            { { text = _("Label\xE2\x80\xA6"), callback = close(function()
                local input
                input = InputDialog:new{
                    title = _("Card label (empty = icon only)"),
                    input = entry.label or "",
                    buttons = { { {
                        text = _("Cancel"),
                        callback = function() UIManager:close(input) end,
                    }, {
                        text = _("Save"), is_enter_default = true,
                        callback = function()
                            local txt = input:getInputText()
                            entry.label = (txt and txt ~= "") and txt or nil
                            UIManager:close(input)
                            ctx.save()
                        end,
                    } } },
                }
                UIManager:show(input)
                input:onShowKeyboard()
            end) } },
            { { text = _("Icon\xE2\x80\xA6"), callback = close(function()
                local IconsLibrary = require("lib/bookshelf_icons_library")
                IconsLibrary:show(function(value)
                    entry.icon = (value and value ~= "") and value or nil
                    ctx.save()
                end, { dynamic = false, svg = true })
            end) } },
        }
        dialog = ButtonDialog:new{
            title = _("Action settings"), title_align = "center",
            width_factor = 0.75, buttons = rows,
        }
        UIManager:show(dialog)
    end,
}
