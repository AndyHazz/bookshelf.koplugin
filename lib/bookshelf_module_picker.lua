--- Module picker: card-grid chooser for the start menu's pluggable
--- micro-modules, on the shared LibraryModal chrome (same shell as the
--- icons library). One card per registered module; each card shows the
--- module's LIVE preview - the same widget the menu itself renders - with
--- the module title beneath, so the user sees what they're adding before
--- they pick it.
---
--- A FRESH preview widget is built on every cell render and owned by the
--- modal's widget tree (freed with it). Module render output must never be
--- shared across widget trees - same one-shot rule as Book cover_bb.

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local LibraryModal    = require("lib/bookshelf_library_modal")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Modules         = require("lib/bookshelf_start_menu_modules")
local BFont           = require("lib/bookshelf_fonts")
local logger          = require("logger")
local _               = require("lib/bookshelf_i18n").gettext

local Screen = Device.screen

local ModulePicker = {}

-- Render one module card for the grid: the live preview sits on the same
-- light-grey rounded card the start menu paints module rows on (visual
-- continuity: the card in the picker IS what lands in the menu), with the
-- title centred beneath.
--
-- Sizing contract: the card fills its grid slot EXACTLY (dimen.w × dimen.h),
-- so every card in the grid is the same size and the visible gap between
-- cards is precisely the modal's MARGIN (Screen:scaleBySize(10) — the same
-- pad convention the start menu uses) in both axes. Content is top-aligned:
-- the grey preview area is height-capped to the slot minus title chrome
-- (the preview keeps its natural height, centred inside it), and the title
-- sits at a fixed offset from the card's bottom edge, so titles align
-- across a row. The lone-module case (item.solo, single centred column)
-- keeps the old ~start-menu-panel width cap instead — a full-content-width
-- card there reads as a stretched empty box, and with one card there are
-- no inter-card gaps to keep even.
function ModulePicker._renderCell(item, dimen)
    local TextWidget = require("ui/widget/textwidget")
    local card_pad = Screen:scaleBySize(10)
    local border   = Size.border.thin
    local card_w = item.solo
        and math.min(dimen.w, Screen:scaleBySize(300)) or dimen.w
    local card_h = dimen.h
    local inner_w = card_w - 2 * (border + card_pad)
    local inner_h = card_h - 2 * (border + card_pad)
    local preview_w = inner_w - 2 * card_pad

    -- FRESH preview per render (never the menu's own instance): the same
    -- contract as bookshelf_start_menu._buildModuleRow, including the
    -- title-text fallback when render fails or returns nil.
    local def = Modules.get(item.key)
    local preview
    if def then
        local Store = require("lib/bookshelf_settings_store")
        local scale_pct = Store.read("start_menu_font_scale") or 100
        -- 3rd arg = preview hint: lets a module render a compact, fixed-size
        -- thumbnail for the chooser grid instead of its full configured form
        -- (e.g. the analogue clock forces its small face size so a large
        -- square doesn't overflow the fixed-height preview cell).
        local ok, widget = pcall(def.render, preview_w, scale_pct, true)
        preview = ok and widget or nil
        if not ok then
            logger.warn("[bookshelf] module picker preview render failed:",
                item.key, widget)
        end
    end
    if not preview then
        preview = TextWidget:new{
            text = item.title,
            face = (BFont:getFace("cfont", 15)),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }
    end
    local title_face, title_bold = BFont:getFace("cfont", 14, { bold = true })
    local title_w = TextWidget:new{
        text = item.title,
        face = title_face,
        bold = title_bold,
        fgcolor = Blitbuffer.COLOR_BLACK,
        max_width = inner_w,
    }
    local title_gap = Screen:scaleBySize(6)
    -- Grey preview area: all remaining inner height once the title row is
    -- reserved — uniform across the grid, independent of preview height.
    local grey_h = math.max(Screen:scaleBySize(40),
        inner_h - title_w:getSize().h - title_gap)
    local grey_card = FrameContainer:new{
        background = Modules.CARD_BG,
        radius     = Screen:scaleBySize(4),
        bordersize = 0,
        padding    = 0,
        -- Preview centred in the capped grey area at its natural height;
        -- the (inner_w - preview_w)/2 horizontal slack = card_pad, the
        -- same inset the start menu's module rows use.
        CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = grey_h },
            preview,
        },
    }
    local stack = VerticalGroup:new{
        align = "center",
        grey_card,
        VerticalSpan:new{ width = title_gap },
        title_w,
    }
    local card = FrameContainer:new{
        bordersize = border,
        radius = Size.radius.default,
        padding = card_pad,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        stack,
    }
    if item.solo then
        -- Centre the compact card in the (full-width) grid slot.
        return CenterContainer:new{
            dimen = Geom:new{ w = dimen.w, h = dimen.h },
            card,
        }
    end
    return card
end

--- Open the module picker. on_select(key) is called with the chosen
--- module key when the user taps a card. Caller is responsible for the
--- empty-registry case (Modules.keys() == {}).
function ModulePicker:show(on_select)
    local keys = Modules.keys()
    local items = {}
    for _i, key in ipairs(keys) do
        items[#items + 1] = { key = key, title = Modules.title(key) or key,
            solo = #keys == 1 }
    end
    local self_ref = self
    -- Columns: a lone module gets a single centred column (a sparse
    -- multi-column grid with one card top-left reads as broken); larger
    -- registries get the usual 2-portrait/3-landscape browse density.
    local function cols()
        if #items <= 1 then return 1 end
        return Screen:getWidth() > Screen:getHeight() and 3 or 2
    end
    local config = {
        title = _("Bookshelf micro-modules"),
        no_search = true, -- a handful of cards at most; search row is noise
        grid_cols = cols,
        cells_per_page = function() return cols() * 2 end,
        cell_renderer = ModulePicker._renderCell,
        on_cell_tap = function(item)
            if self_ref.modal then
                UIManager:close(self_ref.modal)
                self_ref.modal = nil
            end
            if on_select then on_select(item.key) end
        end,
        item_count = function() return #items end,
        item_at = function(idx) return items[idx] end,
        footer_actions = {
            { key = "close", label = _("Close"), on_tap = function()
                if self_ref.modal then
                    UIManager:close(self_ref.modal)
                    self_ref.modal = nil
                end
            end },
        },
    }
    self.modal = LibraryModal:new{ config = config }
    UIManager:show(self.modal)
end

return ModulePicker
