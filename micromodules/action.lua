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
-- glyph. `box` is the target square the visible icon should fit inside.
-- Mirrors the start-menu icon path.
local function buildIcon(icon_value, box, fg)
    local SMModel = require("lib/bookshelf_start_menu_model")
    local img = SMModel.imageIconName(icon_value)
    if img then
        -- SVG/PNG: width/height are exact, so the icon fills the box precisely.
        local IconWidget = require("ui/widget/iconwidget")
        local iw = IconWidget:new{ icon = img, width = box, height = box, alpha = true }
        if iw.file and iw.file:find("icon-not-found", 1, true) then
            return nil
        end
        return iw
    end
    -- Glyph: a symbols glyph paints larger than its nominal face size by a
    -- glyph-specific amount (the puzzle placeholder otherwise balloons past the
    -- card edge). Fit it by measuring once at face=box and correcting the face
    -- so the visible ink lands inside the box square.
    local Font       = require("ui/font")
    local TextWidget = require("ui/widget/textwidget")
    local text = (icon_value and icon_value ~= "") and icon_value or DEFAULT_ICON
    local function glyph(px)
        return TextWidget:new{
            text = text, face = Font:getFace("symbols", px), fgcolor = fg,
        }
    end
    local w = glyph(box)
    local sz = w:getSize()
    local big = math.max(sz.w, sz.h)
    if big > box then
        -- visible size scales ~linearly with face px, so face*box/big lands it.
        w = glyph(math.max(8, math.floor(box * box / big + 0.5)))
    end
    return w
end

return {
    key   = "action",
    title = _("Action"),
    summary = _("Launches a plugin or system action. Works offline."),
    -- A centred icon reads best as a square; the hero grid packs square-aspect
    -- modules tightly (more per row) instead of stretching them into wide cells.
    aspect = "square",
    -- Hero-area only: an action card launches something and makes no sense as a
    -- start-menu row (the start menu already lists actions natively), so the
    -- module picker hides it unless it's opened from the hero.
    hero_only = true,
    -- An action card is a button, so it gets the instant pressed-border tap
    -- feedback; passive modules (clock, quote, ...) don't (they'd flash a border
    -- for a tap that only re-rolls or does nothing).
    tap_feedback = true,

    -- entry (7th arg) carries this card's config: label, icon, and one of
    -- action|plugin|internal. nil in the picker preview -> a generic tile.
    render = function(ctx)
        local width, scale_pct, preview, avail_h, _refresh, _shape, entry = ctx.width, ctx.scale, ctx.preview, ctx.height, ctx.refresh, ctx.shape, ctx.entry
        local Kit             = require("lib/bookshelf_module_kit")
        local VerticalGroup   = require("ui/widget/verticalgroup")
        local VerticalSpan    = require("ui/widget/verticalspan")
        local CenterContainer = require("ui/widget/container/centercontainer")
        local Geom            = require("ui/geometry")
        local mw  = math.max(50, width)
        local fg  = Kit.COLOR_PRIMARY
        local sc  = Kit.sc(scale_pct)

        local label = entry and entry.label
        local icon_value = entry and entry.icon
        if preview then
            -- The picker prints its own "Action" title beneath the cell, so
            -- render the icon ONLY here (an in-card label would duplicate it),
            -- centred in the preview area with the same margin the live card uses.
            icon_value = icon_value or DEFAULT_ICON
            label = nil
        elseif not entry then
            label = label or _("Action")
            icon_value = icon_value or DEFAULT_ICON
        end
        local has_label = type(label) == "string" and label ~= ""

        -- Even margin on every side, like the analogue clock's face box: the
        -- icon is the largest square that fits the cell minus that padding (and
        -- minus the label when present), so it never bleeds to the edge.
        local pad = sc(12)
        local gap = sc(6)
        local box_h = (avail_h and avail_h > 0) and avail_h or mw

        -- Build the label FIRST so we can reserve its ACTUAL rendered height.
        -- Reserving the font size alone (sc(15)) under-counted the line height
        -- (~1.3x), so the content measured taller than the cell and the hero's
        -- clip cropped the label's lower edge. Cap it to ~40% of the cell so a
        -- short, wide cell keeps room for the icon (fitText ellipsis-clamps).
        local label_widget, reserve = nil, 0
        if has_label then
            label_widget = Kit.fitText{
                text = label, size = 15, scale_pct = scale_pct,
                width = mw - 2 * pad,
                max_h = math.max(sc(16), math.floor(box_h * 0.4)),
                fgcolor = fg, align = "center",
            }
            reserve = label_widget:getSize().h + gap
        end

        local icon_box = math.min(mw - 2 * pad, box_h - 2 * pad - reserve)
        if preview then
            -- No height hint in the picker; cap to half the card width so the
            -- icon stays comfortably inside the roughly-square preview area.
            icon_box = math.min(icon_box, math.floor(mw * 0.5))
        end
        icon_box = math.max(16, icon_box)

        local icon = buildIcon(icon_value, icon_box, fg)
            or buildIcon(DEFAULT_ICON, icon_box, fg) -- never blank

        local content = VerticalGroup:new{ align = "center" }
        content[#content + 1] = VerticalSpan:new{ width = pad }
        content[#content + 1] = icon
        if has_label then
            content[#content + 1] = VerticalSpan:new{ width = gap }
            content[#content + 1] = label_widget
        end
        content[#content + 1] = VerticalSpan:new{ width = pad }

        -- mw-wide CenterContainer so the icon centres horizontally and the pad
        -- spans give the top/bottom margin (mirrors analogue_clock).
        return CenterContainer:new{
            dimen = Geom:new{ w = mw, h = content:getSize().h },
            content,
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

    -- Tap: run the action via the shared dispatcher, exactly like tapping the
    -- same entry in the start menu. The start menu closes only its own popup,
    -- NOT the bookshelf; the hero has no popup to close, so it must not tear the
    -- bookshelf down either. Only internal="close" closes it (Exec.dispatch does
    -- that itself). In-place actions (night mode, wifi, frontlight) and plugin
    -- launches leave the bookshelf open, which is what the user expects from a
    -- toggle on the home screen. nextTick lets the tap event finish first.
    on_tap = function(ctx)
        local entry = ctx and ctx.entry
        local bw = ctx and ctx.bw
        if not entry then return end
        require("ui/uimanager"):nextTick(function()
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
