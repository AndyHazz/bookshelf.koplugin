--[[
Hero-area micro-module grid. Renders the user's hero module list
(bookshelf_hero_modules_model) into the bounded space the hero card would
otherwise occupy (content_w × hero_h), as an auto-laid-out grid of bordered
cards.

Each card carries a hairline border + rounded corners matching the book
covers (Screen:scaleBySize(1) border, scaleBySize(4) radius) rather than the
flat grey background-fill the start-menu module rows use: the start menu has
its own panel border to sit inside, but the hero grid floats directly on the
page, so the cards need their own edge.

A FRESH module preview widget is built on every call and owned by the
returned widget tree (freed with it). Module render output must never be
shared across widget trees — same one-shot rule as Book cover_bb and the
module picker.

Layout: a single row while the modules fit at a sensible minimum cell width;
otherwise it wraps to more rows. The hero slot is wide and short, so a single
row of taller cells reads better than stacking — multiple rows only kick in
when there are more modules than fit one row.
]]
local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Modules         = require("lib/bookshelf_start_menu_modules")
local HeroModel       = require("lib/bookshelf_hero_modules_model")
local BFont           = require("lib/bookshelf_fonts")
local BookshelfSettings = require("lib/bookshelf_settings_store")
local logger          = require("logger")
local _               = require("lib/bookshelf_i18n").gettext

local Screen = Device.screen

local HeroModules = {}

-- Card surface: the same grey fill the start-menu module rows use, so the
-- modules that paint a grey text backing (quote / random book) blend into
-- the card. The hero cards additionally carry a hairline border (below) the
-- start-menu rows don't, since the grid floats on the page with no enclosing
-- panel. Falls back to white where blitbuffer is unavailable (test runner).
local HERO_CARD_BG = Modules.CARD_BG or Blitbuffer.COLOR_WHITE

-- Full rebuild + repaint after a module tap or edit. Bumps the module
-- generation so per-open caches (e.g. quote_of_day's "every open" refresh,
-- random_unread's re-roll) produce fresh content on the rebuild.
function HeroModules._rebuild(bw)
    Modules.bumpGeneration()
    if bw and bw._rebuild then bw:_rebuild() end
    if bw then UIManager:setDirty(bw, "ui") end
end

-- The ctx the micro-modules expect: ctx.bw is the live bookshelf widget,
-- ctx.menu is a thin shim exposing _reload (modules call ctx.menu:_reload()
-- after settings changes / keep_open taps). Here _reload rebuilds the hero.
function HeroModules._ctx(bw)
    local shim = { bw = bw }
    function shim:_reload() HeroModules._rebuild(bw) end
    return { bw = bw, menu = shim }
end

function HeroModules._tap(bw, entry)
    local def = Modules.get(entry.module)
    if not def or type(def.on_tap) ~= "function" then return end
    local ctx = HeroModules._ctx(bw)
    local keep = def.keep_open
    if type(keep) == "function" then
        local ok, r = pcall(keep, ctx)
        keep = ok and r or false
    end
    pcall(def.on_tap, ctx)
    -- keep_open modules (re-roll / cycle) re-render in place via a reload;
    -- one-shot modules (open a book) leave the rebuild to whatever they did.
    if keep then ctx.menu:_reload() end
end

function HeroModules._hold(bw, entry)
    local ok, Edit = pcall(require, "lib/bookshelf_hero_modules_edit")
    if ok and Edit then Edit.show(bw, entry) end
end

-- One module card: a rounded grey panel (no border) with the module's fresh
-- preview centred inside. inner = cell - 2*card_pad, so the frame comes out
-- exactly cell_w × cell_h and the grid tiles without rounding drift. The
-- module is handed inner_h as a 4th render arg so height-aware modules (the
-- quote) can fill the cell instead of clamping to a fixed line count; modules
-- that ignore it render at their natural height, centred.
function HeroModules._makeCell(bw, entry, cell_w, cell_h, scale_pct)
    local radius   = Screen:scaleBySize(4)
    -- Padding scales with the (cell-derived) font scale: bigger / squarer
    -- cells get more breathing room, small cells stay tight. Floored at 6px.
    local card_pad = Screen:scaleBySize(math.max(6, math.floor(8 * (scale_pct or 100) / 100 + 0.5)))
    local inner_w  = math.max(1, cell_w - 2 * card_pad)
    local inner_h  = math.max(1, cell_h - 2 * card_pad)

    local def = Modules.get(entry.module)
    local content
    if def then
        local ok, widget = pcall(def.render, inner_w, scale_pct, false, inner_h)
        if ok then
            content = widget
        else
            logger.warn("[bookshelf] hero module render failed:", entry.module, widget)
        end
    end
    if not content then
        content = TextWidget:new{
            text    = (def and def.title) or entry.module,
            face    = BFont:getFace("cfont", 15),
            fgcolor = Modules.COLOR_MUTED or Blitbuffer.COLOR_GRAY_5,
        }
    end

    local frame = FrameContainer:new{
        background = HERO_CARD_BG,
        bordersize = 0,
        radius     = radius,
        padding    = card_pad,
        margin     = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = inner_h },
            content,
        },
    }
    local cell = InputContainer:new{ dimen = frame:getSize(), frame }
    if Device:isTouchDevice() then
        cell.ges_events = {
            Tap  = { GestureRange:new{ ges = "tap",  range = cell.dimen } },
            Hold = { GestureRange:new{ ges = "hold", range = cell.dimen } },
        }
    end
    function cell:onTap() HeroModules._tap(bw, entry); return true end
    function cell:onHold() HeroModules._hold(bw, entry); return true end
    return cell
end

-- Empty list: a single full-hero bordered prompt. Tap or hold opens "Add".
function HeroModules._emptyState(bw, content_w, hero_h)
    local border   = Screen:scaleBySize(1)
    local radius   = Screen:scaleBySize(4)
    local card_pad = Screen:scaleBySize(8)
    local inner_w  = math.max(1, content_w - 2 * (border + card_pad))
    local inner_h  = math.max(1, hero_h   - 2 * (border + card_pad))
    local frame = FrameContainer:new{
        background = HERO_CARD_BG,
        bordersize = border,
        radius     = radius,
        padding    = card_pad,
        margin     = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = inner_h },
            TextWidget:new{
                text    = _("Hold to add micro-modules"),
                face    = BFont:getFace("cfont", 16),
                fgcolor = Modules.COLOR_MUTED or Blitbuffer.COLOR_GRAY_5,
            },
        },
    }
    local cell = InputContainer:new{ dimen = frame:getSize(), frame }
    if Device:isTouchDevice() then
        cell.ges_events = {
            Tap  = { GestureRange:new{ ges = "tap",  range = cell.dimen } },
            Hold = { GestureRange:new{ ges = "hold", range = cell.dimen } },
        }
    end
    local function add()
        local ok, Edit = pcall(require, "lib/bookshelf_hero_modules_edit")
        if ok and Edit then Edit.showAdd(bw, nil) end
    end
    function cell:onTap() add(); return true end
    function cell:onHold() add(); return true end
    return cell
end

-- Build the hero micro-module grid sized to content_w × hero_h.
function HeroModules.build(bw, content_w, hero_h, PAD)
    local items = HeroModel.load()
    if #items == 0 then
        return HeroModules._emptyState(bw, content_w, hero_h)
    end
    -- Balanced near-square grid: cols = ceil(sqrt(n)) sets the row count,
    -- rows = ceil(n/cols). Items are spread as evenly as possible across the
    -- rows (n=5 → 3+2, n=7 → 3+2+2, n=8 → 3+3+2), and EACH row's cards expand
    -- to fill the full width — so a shorter row gets wider cards rather than
    -- narrow centred ones.
    local gap    = PAD
    local n      = #items
    local cols   = math.max(1, math.ceil(math.sqrt(n)))
    local rows   = math.ceil(n / cols)
    local cell_h = math.floor((hero_h - gap * (rows - 1)) / rows)
    -- Even per-row counts: the first (n % rows) rows get one extra card.
    local base   = math.floor(n / rows)
    local extra  = n % rows

    -- Responsive font scale: one uniform scale for the whole grid, driven by
    -- the most-constrained cell dimension — the narrowest cell's width (the
    -- fullest row) or the row height, whichever is smaller. Big cells get
    -- bigger text (fills the space, no tiny text in a huge box), squashed
    -- cells shrink it (no overflow). Modules already size their fonts to
    -- scale_pct, so this makes every text module responsive for free; the
    -- analogue clock additionally fills the cell via the height arg below.
    local maxc       = base + (extra > 0 and 1 or 0)  -- widest row's columns
    local min_cell_w = math.floor((content_w - gap * (maxc - 1)) / maxc)
    local basis      = math.min(min_cell_w, cell_h)
    local scale_pct  = math.max(75, math.min(220,
        math.floor(basis / Screen:scaleBySize(150) * 100 + 0.5)))

    -- Record time-sensitive cells (clocks) so the minute heartbeat can
    -- re-render JUST those in place — rebuilding the whole grid each minute
    -- would re-roll random_unread (25s TTL) etc. Each record locates the cell
    -- by its parent row + index so tickClocks can swap it.
    bw._hero_clock_cells = {}

    local vg = VerticalGroup:new{ align = "center" }
    local idx = 1
    for r = 1, rows do
        local in_row    = base + (r <= extra and 1 or 0)
        local row_cell_w = math.floor((content_w - gap * (in_row - 1)) / in_row)
        local hg = HorizontalGroup:new{ align = "center" }
        for c = 1, in_row do
            if c > 1 then hg[#hg + 1] = HorizontalSpan:new{ width = gap } end
            local entry = items[idx]
            hg[#hg + 1] = HeroModules._makeCell(bw, entry, row_cell_w, cell_h, scale_pct)
            local def = Modules.get(entry.module)
            if def and def.wants_minute_tick then
                bw._hero_clock_cells[#bw._hero_clock_cells + 1] = {
                    group = hg, idx = #hg, entry = entry,
                    w = row_cell_w, h = cell_h, scale = scale_pct,
                }
            end
            idx = idx + 1
        end
        vg[#vg + 1] = hg
        if r < rows then vg[#vg + 1] = VerticalSpan:new{ width = gap } end
    end
    return vg
end

-- Re-render just the time-sensitive (clock) cells in place and scope the
-- refresh to them. Driven by the bookshelf's minute heartbeat while the grid
-- is the hero. Returns false (no-op) when the grid has no clock cell, so the
-- heartbeat doesn't ghost-refresh a grid that doesn't need it. Modules are NOT
-- re-rendered wholesale (and generation is NOT bumped), so random_unread /
-- quote / etc. keep their current pick — only the clocks advance.
function HeroModules.tickClocks(bw)
    local cells = bw and bw._hero_clock_cells
    if not cells or #cells == 0 then return false end
    local scope
    local swapped = 0
    for _i, rec in ipairs(cells) do
        local hg = rec.group
        local old = hg and hg[rec.idx]
        -- Guard: only swap if the slot still holds a cell (the tree could have
        -- been rebuilt out from under us between heartbeat fires).
        if old then
            local newcell = HeroModules._makeCell(bw, rec.entry, rec.w, rec.h, rec.scale)
            hg[rec.idx] = newcell
            if hg.resetLayout then hg:resetLayout() end
            swapped = swapped + 1
            local d = old.dimen
            if d then
                if not scope then
                    scope = d:copy()
                else
                    local x1 = math.min(scope.x, d.x)
                    local y1 = math.min(scope.y, d.y)
                    local x2 = math.max(scope.x + scope.w, d.x + d.w)
                    local y2 = math.max(scope.y + scope.h, d.y + d.h)
                    scope.x, scope.y, scope.w, scope.h = x1, y1, x2 - x1, y2 - y1
                end
            end
            if old.free then
                UIManager:nextTick(function() pcall(function() old:free() end) end)
            end
        end
    end
    if swapped == 0 then return false end
    if scope then
        UIManager:setDirty(bw, function() return "ui", scope end)
    else
        UIManager:setDirty(bw, "ui")
    end
    return true
end

return HeroModules
