--[[
The palette icon's menu for one micro-module: its card (background, border,
text) and the colours its spec declares (bookshelf_module_card), for the look
on screen -- light or dark, as the shelf is painting now.

Saved on the module through ctx.save (the module's own settings path), so the
look moves with it. The colour rows use the Colors menu's own picker, given
the module as its store in place of the theme. The menu stays open while you
change things: a row's label is rewritten in place (closing and reopening a
dialog per change flashes the whole screen).
]]
local Card = require("lib/bookshelf_module_card")
local _    = require("lib/bookshelf_i18n").gettext
local T    = require("ffi/util").template

local M = {}

-- The Colors menu field whose default tile a card row's picker offers.
local FIELD = { bg = "module_bg", border_color = "module_border", ink = "ink" }

--- show(ctx): ctx is the module's ctx (HeroModules._ctx): entry, save().
function M.show(ctx)
    local entry = ctx and ctx.entry
    if not entry then return end
    local UIManager    = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local Modules      = require("lib/bookshelf_start_menu_modules")
    local CP           = require("lib/bookshelf_cover_progress")
    local Settings     = require("lib/bookshelf_settings")
    local def = Modules.get(entry.module)
    local rows = Card.rows(def)
    if #rows == 0 then return end
    -- The look on screen: the picker's slot follows it too.
    CP.setEditSlot(nil)
    local sfx = CP.modeSuffix()

    local function label(row)
        local raw = Card.raw(entry, row.key)
        local value
        if row.kind == "toggle" then
            value = (raw == false) and _("Off") or _("On")
        elseif raw == nil and row.key == "ink" and Card.raw(entry, "bg") ~= nil then
            -- Auto only where the card has a background of its own; else
            -- the text is the shared ink (bookshelf_module_card).
            value = _("Auto")
        else
            value = Settings.valueText(raw, row.key)
        end
        return T(_("%1: %2"), row.text, value)
    end

    local d
    local function relabel()
        if not d then return end
        for _i, row in ipairs(rows) do
            local btn = d:getButtonById(row.key)
            if btn then btn:setText(label(row), btn.width) end
        end
        UIManager:setDirty(d, "ui")
    end
    local function changed()
        local Perf = require("lib/bookshelf_perf")
        Perf.start("module colours")
        local t = Perf.now()
        -- Kept in memory while the menu is up, written once as it closes.
        if ctx.saveDeferred then ctx.saveDeferred() else ctx.save() end
        Perf.part("save", t)
        t = Perf.now()
        relabel()
        Perf.part("relabel", t)
    end

    -- The picker's store: the module's colours, keyed as it keys them (the
    -- slot's suffix already on).
    local function put(k, v)
        if v == nil then
            if type(entry.colors) ~= "table" then return end
            entry.colors[k] = nil
            if next(entry.colors) == nil then entry.colors = nil end
            return
        end
        if type(entry.colors) ~= "table" then entry.colors = {} end
        entry.colors[k] = v
    end
    local function get(k) return type(entry.colors) == "table" and entry.colors[k] or nil end
    local store = {
        partRead     = get,
        partSnapshot = get,
        partSave     = put,
        partDelete   = function(k) put(k, nil) end,
        partRestore  = put,
    }

    local buttons = {}
    for _i, row in ipairs(rows) do
        buttons[#buttons + 1] = { {
            id = row.key, text = label(row), align = "left",
            callback = function()
                if row.kind == "toggle" then
                    -- Off, or back to the default (on): nothing stored.
                    -- (Not `on and false or nil`: that is always nil.)
                    if Card.raw(entry, row.key) == false then
                        Card.set(entry, row.key, nil)
                    else
                        Card.set(entry, row.key, false)
                    end
                    changed()
                    return
                end
                Settings:_pickColor(row.key, FIELD[row.key], 0, row.text, nil, changed, nil,
                    { store = store })
            end,
        } }
    end
    buttons[#buttons + 1] = {
        { text = _("Reset"), callback = function()
            for _j, row in ipairs(rows) do Card.set(entry, row.key, nil) end
            changed()
        end },
        { text = _("Close"), callback = function() UIManager:close(d) end },
    }
    local title = (def and def.title) or entry.module
    d = ButtonDialog:new{
        title = T(_("%1 · colors for %2"), title, (sfx ~= "") and _("Dark") or _("Light")),
        title_align = "center",
        buttons = buttons,
    }
    -- The changes made in memory (ctx.saveDeferred) go to the file once, as
    -- the menu closes, however it closes.
    local closed = d.onCloseWidget
    function d:onCloseWidget(...)
        pcall(function() require("lib/bookshelf_settings_store").flush() end)
        if closed then return closed(self, ...) end
    end
    UIManager:show(d)
    return d
end

--- titleRow(title, face, w, entry, show_parent, on_tap) -> a menu's title
--- with the palette icon at its right, when the module has colours to set (a
--- card, or colours its spec declares); else the plain title. The icon opens
--- this menu, as the coffee cup in the ornament menu's title opens the
--- collection (maintainer). An equal blank on the left keeps the title
--- centred.
function M.titleRow(title, face, w, entry, show_parent, on_tap)
    local Modules    = require("lib/bookshelf_start_menu_modules")
    local TextWidget = require("lib/bookshelf_colour_text")
    local def = entry and Modules.get(entry.module)
    if #Card.rows(def) == 0 then
        return TextWidget:new{ text = title, face = face, max_width = w }
    end
    local Button          = require("ui/widget/button")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan  = require("ui/widget/horizontalspan")
    local Geom            = require("ui/geometry")
    local Screen          = require("device").screen
    local glyph = require("lib/bookshelf_menu_icons").COLORS
    -- The row keeps the height a 22 pt icon gave it, so the header bar does
    -- not grow; the icon itself is large, as a tap target (at 22 pt it was a
    -- speck in the corner), centred in that height and free to reach into
    -- the padding above and below (maintainer, PW5).
    local probe = Button:new{
        text = glyph, text_font_face = "symbols", text_font_size = 22, text_font_bold = false,
        bordersize = 0, padding = Screen:scaleBySize(4),
    }
    local row_h = probe:getSize().h
    if probe.free then probe:free() end
    local icon = Button:new{
        text = glyph,
        text_font_face = "symbols", text_font_size = 36, text_font_bold = false,
        bordersize = 0, padding = Screen:scaleBySize(4),
        show_parent = show_parent,
        callback = on_tap,
    }
    local iw, ih = icon:getSize().w, icon:getSize().h
    local holder = { dimen = Geom:new{ w = iw, h = row_h } }
    function holder:getSize() return { w = iw, h = row_h } end
    function holder:paintTo(bb, x, y)
        self.dimen = Geom:new{ x = x, y = y, w = iw, h = row_h }
        icon:paintTo(bb, x, y + math.floor((row_h - ih) / 2))
    end
    function holder:handleEvent(ev) return icon:handleEvent(ev) end
    function holder:free() if icon.free then icon:free() end end
    local tw = math.max(1, w - 2 * iw)
    local row = HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = iw },
        CenterContainer:new{
            dimen = Geom:new{ w = tw, h = row_h },
            TextWidget:new{ text = title, face = face, max_width = tw },
        },
        holder,
    }
    -- The icon itself, for a host that moves key focus onto it.
    row.palette_button = icon
    return row
end

return M
