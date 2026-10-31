--[[
The Style menu for one module (the layout editor's Style button): its card (background, border,
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
    -- Reset a row of its own; Close is the title's X (withClose).
    buttons[#buttons + 1] = {
        { text = _("Reset"), callback = function()
            for _j, row in ipairs(rows) do Card.set(entry, row.key, nil) end
            changed()
        end },
    }
    local title = (def and def.title) or entry.module
    d = ButtonDialog:new(require("lib/bookshelf_module_kit").withClose{
        -- Named as the button that opens it (Style), the look it is for after.
        title = T(_("%1 · style for %2"), title, (sfx ~= "") and _("Dark") or _("Light")),
        title_align = "center",
        buttons = buttons,
    })
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

--- hasColours(entry) -> whether the module has colours to set here (a card,
--- or colours its spec declares): what the layout editor's Style button is
--- shown for.
function M.hasColours(entry)
    local def = entry and require("lib/bookshelf_start_menu_modules").get(entry.module)
    return #Card.rows(def) > 0
end

return M
