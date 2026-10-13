--[[
The plank picker: the plank the Spines style stands its books on. The plain
colour, the built-in Oak, then each pack's planks, one per row and each shown
as the shelf paints it. Opened from the reader's own "Plank" row; a tap uses
that plank. It never switches a pack on or off: the collection's pack switches
shape ornaments only. On the ornament collection's screen (LibraryModal), like
the wallpaper picker.

The plain colour opens the plank colour dialog as well, so the colour can be
changed there and then.
]]
local ok_i, I18n = pcall(require, "lib/bookshelf_i18n")
local _ = (ok_i and I18n and I18n.gettext) or function(s) return s end

local PB = {}
PB.ALL, PB.BUILTIN = "__all", "__builtin"

local function TP() return require("lib/bookshelf_theme_pack") end

-- entries(chip) -> the options on that tab: All, Built-in (the colour and
-- Oak), or one pack's planks.
function PB.entries(chip)
    local out = {}
    for _i, o in ipairs(TP().plankOptions()) do
        local keep = chip == PB.ALL
            or (chip == PB.BUILTIN and o.kind ~= "pack")
            or (o.pack ~= nil and o.pack == chip)
        if keep then out[#out + 1] = o end
    end
    -- Under Oak and the colour, when that is all there is, a quiet line
    -- saying where more come from (a row that does nothing when tapped).
    if chip ~= nil and (chip == PB.ALL or chip == PB.BUILTIN) and PB.showsMoreHint() then
        out[#out + 1] = { kind = "hint" }
    end
    return out
end

-- choiceOf(o) -> the value choosePlank takes for that option.
function PB.choiceOf(o)
    if o.kind == "hint" then return nil end
    if o.kind == "colour" then return "colour" end
    if o.kind == "oak" then return "oak" end
    return o.plank.id
end

function PB.inUse(o)
    local c = PB.choiceOf(o)
    return c ~= nil and TP().plankChoice() == c
end

-- startPage(items, per_page) -> the page showing the plank in use, so the
-- picker opens on the current choice.
function PB.startPage(items, per_page)
    for i, o in ipairs(items) do
        if PB.inUse(o) then return math.ceil(i / math.max(1, per_page)) end
    end
    return 1
end

-- showsMoreHint() -> true when no pack has planks: most readers only ever
-- have Oak and the colour, so they get one quiet line saying where more come
-- from, and nothing else (maintainer).
function PB.showsMoreHint()
    for _i, o in ipairs(TP().plankOptions()) do
        if o.kind == "pack" then return false end
    end
    return true
end

-- Rendered previews, one per plank, width, card height and night mode: a
-- page is a handful of planks, and flicking between tabs shows the same ones
-- again. Only the preview that fits is kept; a design too tall for its card
-- is rendered again smaller and the oversized one freed at once, so the
-- cache never outgrows a page and never frees a preview still on screen (a
-- page holds at most 6, the cache 12).
local _previews, _order = {}, {}
local PREVIEW_KEEP = 12
local function render(design, w, row_h)
    local ok, bb = pcall(function()
        return require("lib/bookshelf_spine_shelf").plankPreview(design, w, row_h)
    end)
    return ok and bb or nil
end

-- _fit(o, w, row_h, box_h) -> bb, disposable: the option's preview at most
-- box_h tall, starting from a row row_h tall. disposable: the caller's to
-- free (the plain colour, which follows the setting and is never cached).
function PB._fit(o, w, row_h, box_h)
    local design = (o.kind ~= "colour") and o.plank or nil
    local night = require("device").screen.night_mode and "n" or "d"
    local key = design and table.concat({ design.middle or "?", w, box_h, night }, "|")
    if key and _previews[key] then return _previews[key], false end
    local bb = render(design, w, row_h)
    local tries = 0
    while bb and bb:getHeight() > box_h and row_h > 40 and tries < 4 do
        local h = bb:getHeight()
        pcall(function() bb:free() end)
        row_h = math.floor(row_h * box_h / h)
        bb = render(design, w, row_h)
        tries = tries + 1
    end
    if not bb then return nil end
    if not key then return bb, true end
    _previews[key] = bb
    _order[#_order + 1] = key
    while #_order > PREVIEW_KEEP do
        local old = table.remove(_order, 1)
        if _previews[old] then pcall(function() _previews[old]:free() end) end
        _previews[old] = nil
    end
    return bb, false
end

local function nameOf(o)
    if o.kind == "colour" then return _("Plain color") end
    if o.kind == "oak" then return _("Oak") end
    return (o.plank and o.plank.name) or o.pack
end

local function renderHint(dimen)
    local CenterContainer = require("ui/widget/container/centercontainer")
    local Font            = require("ui/font")
    local Geom            = require("ui/geometry")
    local TextBoxWidget   = require("ui/widget/textboxwidget")
    return CenterContainer:new{ dimen = Geom:new{ w = dimen.w, h = dimen.h },
        TextBoxWidget:new{ text = _("More planks come with packs: see Add ornaments in the Ornament collection."),
                           face = Font:getFace("cfont", 16), width = math.floor(dimen.w * 0.8),
                           alignment = "center" } }
end

local function renderCell(o, dimen)
    if o.kind == "hint" then return renderHint(dimen) end
    local Blitbuffer      = require("ffi/blitbuffer")
    local Font            = require("ui/font")
    local FrameContainer  = require("ui/widget/container/framecontainer")
    local Geom            = require("ui/geometry")
    local ImageWidget     = require("ui/widget/imagewidget")
    local Screen          = require("device").screen
    local Size            = require("ui/size")
    local Space           = require("lib/bookshelf_space")
    local TextWidget      = require("lib/bookshelf_colour_text")
    local VerticalGroup   = require("ui/widget/verticalgroup")
    local VerticalSpan    = require("ui/widget/verticalspan")
    local T               = require("ffi/util").template
    local pad = Space.padding.small
    local inner_w, inner_h = dimen.w - 2 * pad, dimen.h - 2 * pad
    local name = nameOf(o)
    if o.kind == "pack" then name = T(_("%1 (%2 pack)"), name, o.pack) end
    -- The title row, aligned left: the radio mark (filled for the plank in
    -- use) and the name.
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan  = require("ui/widget/horizontalspan")
    local LeftContainer   = require("ui/widget/container/leftcontainer")
    local Marks           = require("lib/bookshelf_marks")
    local radio = Marks.Radio:new{ checked = PB.inUse(o) }
    local gap = Space.padding.default
    local name_w = inner_w - radio:getSize().w - gap
    local row = HorizontalGroup:new{ align = "center", radio, HorizontalSpan:new{ width = gap },
        TextWidget:new{ text = name, face = Font:getFace("cfont", 18), bold = true, max_width = math.max(1, name_w) } }
    local lines = LeftContainer:new{ dimen = Geom:new{ w = inner_w, h = row:getSize().h }, row }
    local box_h = math.max(1, inner_h - lines:getSize().h - Space.padding.small)
    -- A row the height of a four-row shelf: the plank as most shelves show
    -- it. Smaller when the card is too short for it (plankPreview trims to
    -- what was painted: the plank and its shadow, and a design's snow or
    -- icicles), so it is never squashed or spilt onto the name.
    local SpineShelf = require("lib/bookshelf_spine_shelf")
    local row_h = math.floor(Screen:getHeight() / 4)
    local function plank_h(h) return SpineShelf.plankSurface(h) + SpineShelf.plankFace(h) end
    while row_h > 40 and plank_h(row_h) * 1.4 > box_h do row_h = math.floor(row_h * 0.9) end
    local bb, disposable = PB._fit(o, inner_w, row_h, box_h)
    local pic
    if bb then pic = ImageWidget:new{ image = bb, image_disposable = disposable } end
    -- The title row above its plank, the pair packed to the top of the card,
    -- so each name reads with the plank under it and not the next one.
    local TopContainer = require("ui/widget/container/topcontainer")
    return FrameContainer:new{
        bordersize = 0, padding = pad, margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        TopContainer:new{ dimen = Geom:new{ w = inner_w, h = inner_h },
            VerticalGroup:new{ align = "left",
                lines,
                VerticalSpan:new{ width = Space.padding.small },
                pic or VerticalSpan:new{ width = 1 },
            } },
    }
end

-- show(opts): the picker.
--   opts.chip        the tab to open on (a pack's name), else All
--   opts.on_change   after each choice, so the shelf behind catches up
--   opts.on_closed   once, however the picker closes (the caller brings its
--                    menu back); before pick_colour's dialog opens
--   opts.pick_colour function(before, on_done): the plank colour dialog, after
--                    the plain colour is chosen; before is the choice it
--                    replaced (the dialog's Revert puts it back), on_done
--                    reopens the picker when the dialog closes
function PB.show(opts)
    opts = opts or {}
    local LibraryModal = require("lib/bookshelf_library_modal")
    local UIManager    = require("ui/uimanager")
    local Screen       = require("device").screen
    local self = { chip = opts.chip or PB.ALL }
    local function items() return PB.entries(self.chip) end
    self.items = items()
    local modal
    local function close() if modal then UIManager:close(modal); modal = nil end end
    local function landscape() return Screen:getWidth() > Screen:getHeight() end
    local function chips()
        local out = {
            { key = PB.ALL, label = _("All"), is_active = self.chip == PB.ALL },
            { key = PB.BUILTIN, label = _("Built-in"), is_active = self.chip == PB.BUILTIN },
        }
        local seen = {}
        for _i, o in ipairs(TP().plankOptions()) do
            if o.kind == "pack" and not seen[o.pack] then
                seen[o.pack] = true
                out[#out + 1] = { key = o.pack, label = o.pack, is_active = self.chip == o.pack }
            end
        end
        return out
    end
    local config = {
        title = _("Plank"),
        no_search = true,
        grid_cols = function() return 1 end,
        -- Short, so the shelf shows around it and a tap can be seen there.
        -- Sized by share of the screen, not by count, so it is the same shape
        -- at every DPI: the grid about 30% of the height, a plank to every
        -- ~72dp of it.
        rows_per_page = function() return LibraryModal.rowsForShare(0.3) end,
        cells_per_page = function()
            local rows = LibraryModal.rowsForShare(0.3)
            if landscape() then rows = math.max(2, rows - 1) end   -- as the modal shaves
            local area = rows * Screen:scaleBySize(64)
            return math.max(2, math.floor(area / Screen:scaleBySize(72)))
        end,
        chip_strip = chips,
        on_chip_tap = function(k) self.chip = k; self.items = items() end,
        cell_renderer = renderCell,
        -- A tap uses the plank at once, on the shelf behind, and the picker
        -- stays open for the next (Close, or a tap outside it, when done).
        -- The plain colour closes the picker for its colour dialog.
        on_cell_tap = function(o)
            if o.kind == "hint" then return end
            local before = TP().plankChoice()
            TP().choosePlank(PB.choiceOf(o))
            self.changed = true
            if o.kind == "colour" then
                -- The colour dialog in its place, then back here on the same
                -- tab when it closes (reopen); the menu stays away meanwhile.
                self.reopening = true
                close()
                if opts.on_change then pcall(opts.on_change) end
                local function reopen()
                    local again = {}
                    for k, v in pairs(opts) do again[k] = v end
                    again.chip = self.chip
                    PB.show(again)
                end
                if opts.pick_colour then opts.pick_colour(before, reopen) else reopen() end
                return
            end
            if opts.on_change then pcall(opts.on_change) end
            if modal then modal:refresh() end
        end,
        item_count = function() return #self.items end,
        item_at = function(i) return self.items[i] end,
        footer_rows = { { { key = "close", label = _("Close"), on_tap = close } } },
        -- However it closes: one full refresh if the plank changed, to clear
        -- what the quick per-tap updates leave on e-ink.
        on_closed = function()
            if self.changed then UIManager:setDirty("all", "full") end
            -- Closed for the colour dialog: the reopened picker brings the
            -- menu back when it closes.
            if not self.reopening and opts.on_closed then pcall(opts.on_closed) end
        end,
    }
    modal = LibraryModal:new{ config = config,
                              page = PB.startPage(self.items, config.cells_per_page()) }
    UIManager:show(modal)
    return modal
end

return PB
