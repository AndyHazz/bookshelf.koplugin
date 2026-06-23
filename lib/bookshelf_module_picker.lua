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
local ClipContainer   = require("lib/bookshelf_clip_container")
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
-- Static "Network required / Data provided by: • domain" panel shown in place
-- of a live preview for network-required modules (def.network = {domains}). The
-- whole block is left-aligned and centred in the grey area by the card. No
-- render/fetch happens here — the live module appears once it's on the page.
function ModulePicker._networkInfo(def, w)
    local TextWidget = require("ui/widget/textwidget")
    local muted = Modules.COLOR_MUTED or Blitbuffer.COLOR_DARK_GRAY
    local hf, hb = BFont:getFace("cfont", 15, { bold = true })
    local g = VerticalGroup:new{ align = "left" }
    g[#g + 1] = TextWidget:new{ text = _("Network required"),
        face = hf, bold = hb, fgcolor = Blitbuffer.COLOR_BLACK, max_width = w }
    g[#g + 1] = VerticalSpan:new{ width = Screen:scaleBySize(4) }
    -- Secondary text bumped from 11 to 13: the muted source line was hard to
    -- read at the smaller size on e-ink.
    g[#g + 1] = TextWidget:new{ text = _("Data provided by:"),
        face = BFont:getFace("cfont", 13), fgcolor = muted, max_width = w }
    for _i, domain in ipairs(def.network) do
        g[#g + 1] = TextWidget:new{ text = "\xE2\x80\xA2 " .. domain,
            face = BFont:getFace("cfont", 13), fgcolor = muted, max_width = w }
    end
    return g
end

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

    -- Title row + grey-area height computed up front so the preview render below
    -- can be told the height to fit (avail_h) and truncate to it at a readable
    -- size, rather than render tall and lean on the clip (issue #183).
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
    local reserved = title_w:getSize().h + title_gap
    local grey_h = math.max(Screen:scaleBySize(40), inner_h - reserved)

    -- FRESH preview per render (never the menu's own instance): the same
    -- contract as bookshelf_start_menu._buildModuleRow, including the
    -- title-text fallback when render fails or returns nil.
    local def = Modules.get(item.key)
    local preview
    if def and def.network then
        -- Network-required module: do NOT live-render it here — that would fire
        -- the module's fetch inside the chooser grid (the old auto-fetch hazard,
        -- and it can't show real data offline anyway). Show a static panel naming
        -- the data sources; the live module renders once it's added to the page.
        preview = ModulePicker._networkInfo(def, preview_w)
    elseif def then
        local Store = require("lib/bookshelf_settings_store")
        local scale_pct = Store.read("start_menu_font_scale") or 100
        -- 3rd arg preview=true: render a compact, fixed-size thumbnail (e.g. the
        -- analogue clock forces its small face). 4th arg avail_h=grey_h: the
        -- cell height to fit, so a text module truncates to it (issue #183)
        -- instead of overflowing. shape "square" (preview cells are squares).
        local ok, widget = pcall(def.render, {
            width = preview_w, height = grey_h, scale = scale_pct,
            preview = true, refresh = nil, shape = "square", entry = nil,
            surface = "picker", bw = nil, menu = nil,
            config = require("lib/bookshelf_module_kit").entryConfig(nil, nil),
        })
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
    local grey_card = FrameContainer:new{
        background = Modules.CARD_BG,
        radius     = Screen:scaleBySize(4),
        bordersize = 0,
        padding    = 0,
        -- Preview centred in the capped grey area; ClipContainer bounds it to
        -- inner_w × grey_h so a tall module (e.g. a long Quote of the day at
        -- natural height) is clipped to the cell instead of spilling over the
        -- title and neighbouring cells (issue #183). A preview that fits is
        -- still centred; the (inner_w - preview_w)/2 horizontal slack = card_pad.
        ClipContainer:new{
            w = inner_w, h = grey_h, bg = Modules.CARD_BG,
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
--- module key when the user taps a card. opts.for_hero shows hero-only
--- modules (the Action card); the start-menu picker omits opts and hides
--- them. Caller is responsible for the empty-registry case.
function ModulePicker:show(on_select, opts)
    opts = opts or {}
    -- hero_only modules only make sense in the hero grid; hide them from the
    -- start-menu picker unless this picker was opened for the hero.
    local keys = {}
    for _i, key in ipairs(Modules.keys()) do
        local def = Modules.get(key)
        if opts.for_hero or not (def and def.hero_only) then
            keys[#keys + 1] = key
        end
    end
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
        -- Taller grid area (default 5) so each card has room for the preview,
        -- title AND the data-source summary line without squeezing the preview.
        -- Still 2 rows per page; this just makes those rows taller.
        rows_per_page = 6,
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
