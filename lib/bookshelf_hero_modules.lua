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
local ClipContainer   = require("lib/bookshelf_clip_container")
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
local Breaker         = require("lib/bookshelf_module_breaker")
local BookshelfSettings = require("lib/bookshelf_settings_store")
local _               = require("lib/bookshelf_i18n").gettext
local T               = require("ffi/util").template

local Screen = Device.screen

local HeroModules = {}

-- Card surface: the same grey fill the start-menu module rows use, so the
-- modules that paint a grey text backing (quote / random book) blend into
-- the card. The hero cards additionally carry a hairline border (below) the
-- start-menu rows don't, since the grid floats on the page with no enclosing
-- panel. Falls back to white where blitbuffer is unavailable (test runner).
local HERO_CARD_BG = Modules.CARD_BG or Blitbuffer.COLOR_WHITE

-- Full rebuild + repaint after a module tap or edit. Does NOT bump the module
-- generation: that counter keys the per-open caches several modules share
-- (quote_of_day, shelf_size, …), so bumping it here would re-roll the quote
-- (and re-tally shelf_size, …) every time ANY module is tapped — modules must
-- stay isolated. A module that wants to refresh on its own tap does so through
-- its own state (random_unread invalidates its pick cache, quote_of_day bumps
-- its own nonce, reading_goal saves its cycled goal); the rebuild then re-reads
-- each module, leaving the untapped ones unchanged. Generation is bumped only
-- on switching INTO micro mode (a "hero open" event), in the chip handler.
function HeroModules._rebuild(bw)
    -- If the full-screen overlay is open, a module add/edit/remove rebuilds IT
    -- (it registers itself on bw). The bookshelf hero behind is the book card in
    -- fullscreen placement, so it doesn't need rebuilding here.
    if bw and bw._micro_fullscreen and bw._micro_fullscreen.rebuildGrid then
        bw._micro_fullscreen:rebuildGrid()
        return
    end
    -- Prefer a hero-only in-place swap so a module tap/edit doesn't rebuild or
    -- flash the shelf below; fall back to a full rebuild if the grid isn't the
    -- live hero (e.g. not in micro mode).
    if bw and bw._swapMicroHeroInPlace and bw:_swapMicroHeroInPlace() then return end
    if bw and bw._rebuild then bw:_rebuild() end
    if bw then UIManager:setDirty(bw, "ui") end
end

-- Re-render rec's single cell in place (swap the widget in its row) and return
-- the OLD cell's painted dimen so the caller can scope the e-ink refresh to
-- just that cell. The cell is an InputContainer (carries a .dimen on paint),
-- so per-cell scoping works (unlike the grid VerticalGroup). Does NOT setDirty
-- — the caller refreshes (single cell, or a union for the clock tick).
-- The currently focused cell id, from whichever host owns the grid (the
-- full-screen overlay, else the bookshelf hero zone). Lets an in-place async
-- re-render keep the focus ring instead of dropping it.
function HeroModules._activeCursor(bw)
    if bw and bw._micro_fullscreen then return bw._micro_fullscreen._cursor_id end
    return bw and bw._hero_cell_cursor
end

function HeroModules._swapCell(bw, rec)
    local hg  = rec and rec.group
    local old = hg and hg[rec.idx]
    if not old then return nil end
    local focused = rec.focusable and HeroModules._activeCursor(bw) == rec.entry.id
    hg[rec.idx] = HeroModules._makeCell(bw, rec.entry, rec.w, rec.h, rec.scale,
        rec.focusable, focused)
    if hg.resetLayout then hg:resetLayout() end
    if old.free then
        UIManager:nextTick(function() pcall(function() old:free() end) end)
    end
    return old.dimen and old.dimen:copy()
end

-- Parent-owned "refresh this module" — re-render ONLY the given module's cell,
-- scoped to its rect. Keyed by entry id so a callback captured during an
-- earlier render (e.g. a module's async fetch) still finds the CURRENT cell
-- after rebuilds (or no-ops if the module was removed). This is the single
-- mechanism every module uses to update itself (tap reload + async); the
-- scoping lives here in the parent, not in the (often third-party) modules.
function HeroModules._reloadCellById(bw, id)
    local rec = id and bw and bw._hero_cells and bw._hero_cells[id]
    if not rec then return end
    local scope = HeroModules._swapCell(bw, rec)
    -- When the full-screen overlay hosts the grid, repaint IT (the cells live in
    -- the overlay, on top of the bookshelf); else repaint the bookshelf hero.
    local target = bw._micro_fullscreen or bw
    if scope then
        UIManager:setDirty(target, function() return "ui", scope end)
    else
        UIManager:setDirty(target, "ui")
    end
end

-- ctx for a module's on_tap/show_settings: ctx.menu:_reload() refreshes just
-- THIS module's cell (refresh), so a module's own reload stays isolated to its
-- card. When no per-cell refresh is supplied (the edit dialog adding/removing
-- modules, which changes the grid layout) it falls back to a full hero rebuild.
function HeroModules._ctx(bw, refresh, entry)
    local reload = refresh or function() HeroModules._rebuild(bw) end
    local shim = { bw = bw }
    function shim:_reload() reload() end
    local ctx = { bw = bw, menu = shim, entry = entry, surface = "hero" }
    -- Persist a per-instance change a module made to ctx.entry, then reload
    -- this cell (or rebuild the hero). No-op when the module has no entry or
    -- the entry vanished from the list.
    function ctx.save()
        if not entry then return end
        -- Save to the surface that owns this cell: the full-screen overlay edits
        -- its own list (bw._micro_fullscreen set), else the hero list.
        local Model = (bw and bw._micro_fullscreen)
            and require("lib/bookshelf_fullscreen_modules_model")
            or require("lib/bookshelf_hero_modules_model")
        local items = Model.load()
        local list, i = Model.findById(items, entry.id)
        if list and i then list[i] = entry end
        Model.save(items)
        reload()
    end
    ctx.config = require("lib/bookshelf_module_kit").entryConfig(entry, ctx.save)
    return ctx
end

function HeroModules._tap(bw, entry, refresh)
    local def = Modules.get(entry.module)
    if not def or type(def.on_tap) ~= "function" then return end
    local ctx = HeroModules._ctx(bw, refresh, entry)
    local keep = def.keep_open
    if type(keep) == "function" then
        local ok, r = pcall(keep, ctx)
        keep = ok and r or false
    end
    pcall(def.on_tap, ctx)
    -- keep_open modules (re-roll / cycle) re-render in place via the per-cell
    -- refresh; one-shot modules (open a book) leave the rebuild to what they did.
    if keep then ctx.menu:_reload() end
end

function HeroModules._hold(bw, entry)
    local ok, Edit = pcall(require, "lib/bookshelf_hero_modules_edit")
    -- pcall the show too: in the reader overlay bw is a minimal context shim, so
    -- an edit path that reaches for a widget-only method must fail safe, not
    -- crash the reader.
    if ok and Edit then pcall(Edit.show, bw, entry) end
end

-- Render a module to fit the cell: parent-enforced auto-fit. A module is asked
-- to render at the grid's scale; if its natural size overshoots the inner box,
-- the scale is stepped down and it is re-rendered until it fits (or a legibility
-- floor is hit, where ClipContainer is the hard backstop). Height is the binding
-- constraint in practice (text wraps to width but grows downward), so a module
-- that ignores avail_h and renders tall — trivia's question, reading_goal's
-- bar — gets shrunk to fit instead of cropped. Height-aware modules (quote,
-- clock) already fill avail_h and report ~inner_h, so they pass on the first
-- try with no wasted re-render. Modules size every element off scale_pct, so
-- one knob shrinks the whole card uniformly.
--
-- Stepping by scale/sqrt(overflow) (not a fixed decrement) lands near-fit fast:
-- a text block's height grows ~with font area (scale²), so the sqrt undoes most
-- of the overshoot in one step. Bounded to a few iterations as a belt-and-braces
-- guard against a module whose size doesn't track scale_pct monotonically.
local FIT_MAX_ITERS  = 5
local GROW_MAX_ITERS = 5
-- Comfortable fill target: grow an under-filled card until it reaches ~90% of a
-- cell dimension, leaving breathing room (not edge-to-edge).
local FILL_TARGET    = 0.90
-- Surface the current build renders for ("hero" | "fullscreen"), fed into each
-- module's ctx. Set at HeroModules.build entry; safe as a module-level local
-- because one build runs synchronously start to finish (no interleaving).
local _build_surface = "hero"

local function _renderFitted(def, inner_w, inner_h, base_scale, refresh, entry, user_mult, bw)
    local base  = base_scale or 100
    -- Absolute size range for any cell, independent of the (now fixed) base:
    -- shrink to 60% (legibility floor; ClipContainer backstops anything worse),
    -- grow to 220% so a sparse card in a roomy cell fills the space.
    local floor    = 60
    local grow_cap = 220

    -- Aspect hint (ctx.shape): "wide"/"tall"/"square" so a module can choose a
    -- LAYOUT, not just a font size. Optional — modules ignore it.
    local Kit   = require("lib/bookshelf_module_kit")
    local shape = Kit.shape(inner_w, inner_h)
    -- Per-instance config handle (read-only in render: no save passed). Built
    -- once, outside the grow/shrink loop.
    local cfg   = Kit.entryConfig(entry, nil)

    local function renderAt(s)
        local ctx = {
            width = inner_w, height = inner_h, scale = s, preview = false,
            refresh = refresh, shape = shape, entry = entry,
            surface = _build_surface, bw = bw, menu = nil, config = cfg,
        }
        local ok, widget = pcall(def.render, ctx)
        if not ok or not widget then return nil end
        local sz = widget.getSize and widget:getSize()
        return widget, (sz and sz.h) or 0, (sz and sz.w) or 0
    end

    local widget, h, w = renderAt(base)
    if not widget then return nil end  -- render error: caller draws the fallback

    local result, result_scale
    if h <= inner_h and w <= inner_w then
        -- Fits at the grid scale. Markedly under-filled in HEIGHT? Grow the
        -- font to use the space, keeping the largest scale that still fits.
        -- Height is the gate, not width: a text card fills its width by design
        -- (TextBoxWidget reports the full inner_w), so the slack to reclaim is
        -- always vertical. Well-filled cards (height-aware clock/quote that
        -- already reach the target, dense text) don't grow.
        if base < grow_cap and h <= FILL_TARGET * inner_h then
            local best, cur = widget, base
            for _i = 1, GROW_MAX_ITERS do
                local nxt = math.min(grow_cap, math.floor(cur * 1.15 + 0.5))
                if nxt <= cur then break end
                local gw, gh, gwid = renderAt(nxt)
                if not gw then break end
                -- Accept while height stays under the fill target and the card
                -- still fits the cell width (growth eventually wraps text and
                -- jumps the height — that's the stop signal).
                if gh <= FILL_TARGET * inner_h and gwid <= inner_w then
                    if best.free then pcall(function() best:free() end) end
                    best, cur = gw, nxt
                else
                    if gw.free then pcall(function() gw:free() end) end
                    break
                end
            end
            result, result_scale = best, cur
        else
            result, result_scale = widget, base
        end
    else
        -- Overflows the grid scale: shrink. `best` keeps the latest (smallest)
        -- render so a module that never quite fits still returns a (clipped)
        -- widget, never nil; ClipContainer backstops any residual overflow. Step
        -- by scale/sqrt(overflow) — a text block's height grows ~with font area,
        -- so sqrt undoes most of the overshoot in one step.
        local best, best_scale, prev_h, scale = widget, base, h, base
        for _i = 1, FIT_MAX_ITERS do
            if scale <= floor then break end
            local ratio = math.max(h / inner_h, w / inner_w)
            local nxt = math.floor(scale / math.sqrt(ratio))
            if nxt >= scale then nxt = scale - 5 end  -- always progress
            scale = math.max(floor, nxt)
            local sw, sh, swid = renderAt(scale)
            if not sw then break end
            if best.free then pcall(function() best:free() end) end
            best, best_scale, h, w = sw, scale, sh, swid
            -- Fits now, hit the floor, or shrinking stopped reducing height (a
            -- height-aware module fills avail_h whatever the scale): stop.
            if (h <= inner_h and w <= inner_w) or scale <= floor
                    or (prev_h and h >= prev_h) then
                break
            end
            prev_h = h
        end
        result, result_scale = best, best_scale
    end

    -- Issue #180: apply the user's "Hero micro-modules" size multiplier to the
    -- fitted scale. Default 100 = unchanged (the auto-fit result). Lower renders
    -- below the cell fill (smaller text, more whitespace — the requested "make
    -- them smaller"); higher grows past it (ClipContainer backstops overflow).
    user_mult = user_mult or 100
    if result and result_scale and user_mult ~= 100 then
        local adj = math.max(10, math.floor(result_scale * user_mult / 100 + 0.5))
        if adj ~= result_scale then
            local rw = renderAt(adj)
            if rw then
                if result.free then pcall(function() result:free() end) end
                result = rw
            end
        end
    end
    return result
end

-- One module card: a rounded grey panel (no border) with the module's fresh
-- preview centred inside. inner = cell - 2*card_pad, so the frame comes out
-- exactly cell_w × cell_h and the grid tiles without rounding drift. The
-- module is handed inner_h as a 4th render arg so height-aware modules (the
-- quote) can fill the cell instead of clamping to a fixed line count; modules
-- that ignore it render at their natural height, auto-fitted down (above) and
-- centred.
-- 2D grid navigation over a recorded row/col map (bw._hero_grid_rows: a list of
-- rows, each a list of entry ids). Returns the id to move to for the given
-- direction, or nil when the cursor is at the grid edge in that direction (the
-- caller decides what an edge means: the overlay stays put, the hero zone exits
-- to the chips/shelf). Up/Down keep the column where possible, clamping to the
-- shorter row. An unknown cursor lands on the first cell.
function HeroModules.navMove(rows, cur_id, dir)
    if not rows or #rows == 0 then return nil end
    local cr, cc
    for r, row in ipairs(rows) do
        for c, id in ipairs(row) do
            if id == cur_id then cr, cc = r, c; break end
        end
        if cr then break end
    end
    if not cr then return rows[1] and rows[1][1] or nil end
    if dir == "left" then
        if cc > 1 then return rows[cr][cc - 1] end
    elseif dir == "right" then
        if cc < #rows[cr] then return rows[cr][cc + 1] end
    elseif dir == "up" then
        if cr > 1 then local p = rows[cr - 1]; return p[math.min(cc, #p)] end
    elseif dir == "down" then
        if cr < #rows then local n = rows[cr + 1]; return n[math.min(cc, #n)] end
    end
    return nil
end

-- focusable: reserve a d-pad focus ring (border-swap, dimen-constant — matches
-- the start-menu rows and chip cursor). focused: draw it on this cell now.
function HeroModules._makeCell(bw, entry, cell_w, cell_h, scale_pct, focusable, focused)
    local radius   = Screen:scaleBySize(4)
    -- Reserve the focus ring up front so a cell's content area is the same
    -- whether or not it's focused (no reflow as the cursor moves). Touch builds
    -- pass focusable=false, so they're byte-for-byte unchanged.
    local focus_b  = focusable and Screen:scaleBySize(2) or 0
    cell_w = math.max(1, cell_w - 2 * focus_b)
    cell_h = math.max(1, cell_h - 2 * focus_b)
    -- Padding scales with the (cell-derived) font scale: bigger / squarer
    -- cells get more breathing room, small cells stay tight. Floored at 6px.
    local card_pad = Screen:scaleBySize(math.max(6, math.floor(8 * (scale_pct or 100) / 100 + 0.5)))
    local def      = Modules.get(entry.module)
    -- Only an action card (def.tap_feedback) gets the on-tap pressed border, so
    -- only it reserves the thin ring: at rest the ring is an empty margin (no
    -- border drawn); on tap the border flips on and the margin off, so the
    -- cell's outer size is unchanged and nothing shifts (the swap the chips
    -- use). Passive modules reserve nothing and use the full cell.
    local press_b  = (def and def.tap_feedback) and Screen:scaleBySize(1) or 0
    local inner_w  = math.max(1, cell_w - 2 * card_pad - 2 * press_b)
    local inner_h  = math.max(1, cell_h - 2 * card_pad - 2 * press_b)

    -- Parent-owned refresh handle for THIS module: re-renders just this cell,
    -- scoped. Passed to render() as the 5th arg so a module can refresh itself
    -- after async work (weather/daily_fun/trivia) instead of a full-screen
    -- setDirty; also drives the keep_open tap reload. Keyed by entry id, so it
    -- stays valid across rebuilds.
    local function refresh() HeroModules._reloadCellById(bw, entry.id) end

    -- Inset text/flex modules from the cell's L/R edges so they read with even
    -- margins instead of hugging the sides: a text card fills its width but is
    -- centred vertically, so without this it has big top/bottom gaps and tight
    -- left/right. Square modules (clock/action) are icon-centred already and use
    -- the full cell. The ClipContainer below stays at inner_w, so the narrower
    -- render is centred horizontally — giving the L/R margin. Tunable.
    local is_sq      = def and def.aspect == "square"
    local base_inset = Screen:scaleBySize(10)
    local text_w     = is_sq and inner_w or math.max(50, inner_w - 2 * base_inset)

    local content, errored
    if def then
        -- Render under pcall so a catchable Lua error degrades to a fallback
        -- card instead of taking down the home-screen build. _renderFitted
        -- measures (getSize) internally, so a layout/shaping error is caught
        -- here too. The uncatchable text-shaping segfault (issue #163) is
        -- prevented upstream by safeText; the file marker armed in build() is
        -- the recovery net if one still slips through during the hero paint.
        -- User size knob for hero micro-modules (issue #180), default 100 — a
        -- multiplier on the cell auto-fit, independent of the Hero card text size.
        local user_mult = BookshelfSettings.read("hero_module_font_scale", 100)
        local function renderAt(w)
            return Breaker.guard(function()
                return _renderFitted(def, w, inner_h, scale_pct, refresh, entry, user_mult, bw)
            end)
        end
        local ok, c = renderAt(text_w)
        content = ok and c or nil
        errored = not ok

        -- Equalise the card padding. A non-square module is centred vertically
        -- in a fixed-height cell, so short content leaves a large top/bottom gap
        -- while the L/R inset is fixed — the four card-edge margins never match
        -- (issue #185). Measure the rendered height, derive the per-side
        -- vertical slack, and widen the L/R inset to match it so all four gaps
        -- are equal; then re-render the content at that narrower width (its
        -- width feeds the module's own layout, so it must actually re-run).
        -- Capped at 8% of the cell per side (content stays >= ~84% width).
        -- A bigger cap balances the padding better on tall cells, but narrowing
        -- content too far truncates a module's long lines -- _renderFitted scales
        -- a short module UP to fill a tall cell, so headings/labels get wide, and
        -- the narrower we make the cell the sooner they ellipsis (e.g. the
        -- reading-streak "Reading streak" / "Best: ..." lines). 8% trades a little
        -- padding balance for no truncation. Only re-renders when there's real
        -- slack to reclaim, so height-filling modules pay nothing.
        if content and not is_sq then
            local ok_h, ch = pcall(function() return content:getSize().h end)
            if ok_h and type(ch) == "number" then
                local v_slack   = math.floor((inner_h - ch) / 2)
                local max_inset = math.floor(inner_w * 0.08)
                local inset     = math.max(base_inset, math.min(v_slack, max_inset))
                local target_w  = math.max(50, inner_w - 2 * inset)
                if target_w < text_w - Screen:scaleBySize(2) then
                    local ok2, c2 = renderAt(target_w)
                    if ok2 and c2 then content = c2 end
                end
            end
        end
    end
    if not content then
        local label = (def and def.title) or entry.module
        if errored then
            -- render threw a catchable Lua error: show it inline (retried on
            -- the next build) rather than rendering nothing.
            label = T(_("%1 (error)"), label)
        end
        content = TextWidget:new{
            text    = label,
            face    = BFont:getFace("cfont", 15),
            fgcolor = Modules.COLOR_MUTED or Blitbuffer.COLOR_GRAY_5,
        }
    end

    local frame = FrameContainer:new{
        background = HERO_CARD_BG,
        bordersize = 0,
        radius     = radius,
        padding    = card_pad,
        margin     = press_b, -- empty ring at rest; becomes the pressed border
        -- ClipContainer (not CenterContainer): the parent renders the module
        -- into a bounded offscreen buffer so its draw can't escape the cell,
        -- however oversized it is. bg matches the card so the centred child's
        -- margin blends in.
        ClipContainer:new{
            w = inner_w,
            h = inner_h,
            bg = HERO_CARD_BG,
            content,
        },
    }
    -- Wrap in a focus ring when navigable: border when focused, equal margin at
    -- rest, so the outer dimen stays cell_w/cell_h either way (the swap the chips
    -- and start-menu rows use). Keep `frame` pointing at the inner card so the
    -- press-feedback closure below still toggles the card's own border.
    local outer = frame
    if focus_b > 0 then
        outer = FrameContainer:new{
            background = nil,
            bordersize = focused and focus_b or 0,
            margin     = focused and 0 or focus_b,
            radius     = radius,
            padding    = 0,
            frame,
        }
    end
    local cell = InputContainer:new{ dimen = outer:getSize(), outer }
    if Device:isTouchDevice() then
        cell.ges_events = {
            Tap  = { GestureRange:new{ ges = "tap",  range = cell.dimen } },
            Hold = { GestureRange:new{ ges = "hold", range = cell.dimen } },
        }
    end
    function cell:onTap()
        -- Action cards (press_b > 0) get instant pressed-border feedback before
        -- the action runs (mirrors the chip flash): swap margin->border (outer
        -- size unchanged), repaint just this cell with the fast waveform, drain
        -- the queue so it lands now, then act. Reset to rest so a non-rebuilding
        -- action (e.g. toggling night mode) repaints clean; a keep_open reload
        -- rebuilds the cell anyway. Passive modules skip straight to the tap.
        if press_b > 0 then
            frame.bordersize = press_b
            frame.margin = 0
            UIManager:setDirty(bw, function() return "fast", self.dimen end)
            UIManager:forceRePaint()
            frame.bordersize = 0
            frame.margin = press_b
        end
        HeroModules._tap(bw, entry, refresh)
        return true
    end
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

-- A thin in-grid pager cell: a vertically-centred chevron in a w×h slot that
-- pages the module grid on tap. "prev" sits before the first module of the
-- first row, "next" after the last module of the last row.
function HeroModules._chevronCell(bw, dir, w, h)
    local glyph = (dir == "prev") and "\xE2\x9D\xAE" or "\xE2\x9D\xAF" -- ❮ / ❯
    local txt = TextWidget:new{
        text    = glyph,
        face    = BFont:getFace("cfont", 22),
        fgcolor = Modules.COLOR_MUTED or Blitbuffer.COLOR_GRAY_5,
    }
    local cell = InputContainer:new{
        dimen = Geom:new{ w = w, h = h },
        CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, txt },
    }
    if Device:isTouchDevice() then
        cell.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = cell.dimen } } }
    end
    function cell:onTap()
        HeroModules._gotoPage(bw, dir == "prev" and -1 or 1)
        return true
    end
    return cell
end

-- Change the current module page by delta (clamped), then re-render the hero.
-- No-op at the ends. Scoped to the hero region when the widget exposes a
-- hero-only rebuild; otherwise a full rebuild.
function HeroModules._gotoPage(bw, delta)
    -- Step through the navigable (non-empty) pages, not raw page numbers, so a
    -- gap in the user's assignments is skipped.
    local pages = bw._hero_page_list or { bw._hero_page or 1 }
    local cur   = bw._hero_page or pages[1]
    local idx   = 1
    for i, p in ipairs(pages) do if p == cur then idx = i; break end end
    local nidx = math.max(1, math.min(idx + delta, #pages))
    if nidx == idx then return end
    bw._hero_page = pages[nidx]
    -- Scoped to the hero + chips band (rebuilds the tree, refreshes just that
    -- region) so paging doesn't flash the shelves; full rebuild as a fallback.
    if bw._rebuildRefreshHeroAndChips then
        bw:_rebuildRefreshHeroAndChips()
    elseif bw._rebuild then
        bw:_rebuild()
    end
end

-- Build the hero micro-module grid sized to content_w × hero_h.
function HeroModules.build(bw, content_w, hero_h, PAD, opts)
    opts = opts or {}
    _build_surface = opts.surface or "hero"
    -- Arm the light-touch home-screen crash marker before building the grid
    -- (issue #163). If a module hard-crashes during the hero paint, the sentinel
    -- file survives and the next launch comes up with the cover hero instead of
    -- re-crashing. The widget's paintTo removes it once the paint returns.
    pcall(Breaker.armFile, Breaker.heroMarkerPath())
    -- opts.items: an explicit module list. The full-screen overlay passes ALL
    -- modules so they reflow across the screen, bypassing the hero's per-page
    -- assignment + in-grid chevrons. Default = the stored model (hero paging).
    local all_items = opts.items or HeroModel.load()
    if #all_items == 0 then
        return HeroModules._emptyState(bw, content_w, hero_h)
    end
    -- User-controlled pagination: each module carries an optional page number
    -- (entry.page, default 1, up to MAX_PAGES) set from its long-press menu. The
    -- grid shows the current page's modules, navigated by the in-grid chevrons /
    -- hero swipe. Only the current page is packed and built, so off-page modules
    -- never render or fetch. Within a page the grid still fills the hero (and so
    -- shrinks if you crowd one page — the cue to spread modules across pages).
    local MAX_PAGES = 4
    local CHEV_W    = Screen:scaleBySize(24)
    local function pageOf(it)
        local p = tonumber(it.page) or 1
        return math.max(1, math.min(p, MAX_PAGES))
    end
    local items, has_prev, has_next
    if opts.items then
        -- Reflow mode (full-screen overlay): all modules at once, no per-page
        -- assignment and no in-grid chevrons. (Footer paging for overflow is a
        -- follow-up; today they all share one screen-filling grid.)
        items = all_items
        has_prev, has_next = false, false
        bw._hero_page_list = { 1 }
        bw._hero_pages     = 1
    else
        -- The navigable pages are only those that actually hold a module — empty
        -- pages (gaps in the user's assignments) are skipped entirely, so paging
        -- never lands on a blank grid. Kept sorted ascending.
        local used = {}
        for _i, it in ipairs(all_items) do used[pageOf(it)] = true end
        local pages = {}
        for p = 1, MAX_PAGES do if used[p] then pages[#pages + 1] = p end end
        -- Resolve the current page to a real one: keep it if it still holds
        -- modules, else snap to the nearest used page at or below it.
        local want = bw._hero_page or pages[1]
        local page, idx = pages[1], 1
        for i, p in ipairs(pages) do
            if p == want then page, idx = p, i; break end
            if p < want then page, idx = p, i end -- track nearest-below
        end
        bw._hero_page      = page
        bw._hero_page_list = pages   -- absolute page numbers, used pages only
        bw._hero_pages     = #pages  -- count of NAVIGABLE pages
        items = {}
        for _i, it in ipairs(all_items) do
            if pageOf(it) == page then items[#items + 1] = it end
        end
        if #items == 0 then
            return HeroModules._emptyState(bw, content_w, hero_h)
        end
        has_prev = idx > 1
        has_next = idx < #pages
    end
    -- Aspect-aware row packing. Modules opt into a square aspect (def.aspect ==
    -- "square": the clock face, action icons) so they pack as squares instead of
    -- stretching into wide rectangles. The rest are "flex" and fill the leftover
    -- width. Square modules compress to fit MORE per row down to a square (never
    -- narrower); they only expand past square to fill a row that would otherwise
    -- gap, and flex modules in a row absorb the slack so squares stay square.
    local gap = PAD
    -- A flex card's minimum width: ~2 comfortable text columns on a portrait
    -- screen, so a third module wraps to the next row instead of squeezing three
    -- narrow, overflowing cells onto one row (#180 follow-up). Seeds the row
    -- count in packAt; a square card's target width is the row height.
    local min_flex_w = Screen:scaleBySize(300)

    local function isSquare(item)
        local def = Modules.get(item.module)
        return def ~= nil and def.aspect == "square"
    end

    -- Per-module size: a width weight the user nudges from the long-press menu
    -- (entry.size, default 0, clamped to SIZE_MIN..SIZE_MAX). It scales the
    -- module's preferred width, so growing one (e.g. the quote) makes it claim
    -- more of the row and push the others onto the next row. Size 0 reproduces
    -- today's layout exactly.
    local SIZE_MIN, SIZE_MAX = -2, 4
    local function factor(item)
        local s = tonumber(item.size) or 0
        if s < SIZE_MIN then s = SIZE_MIN elseif s > SIZE_MAX then s = SIZE_MAX end
        return 1 + 0.3 * s
    end

    -- Greedily pack items into rows at a given square width: a card joins the
    -- current row while it still fits content_w at its size-scaled preferred
    -- width (square -> sq_w, flex -> min_flex_w), else it starts a new row.
    local function packAt(sq_w)
        local out, cur, cur_w = {}, {}, 0
        for _i, item in ipairs(items) do
            local w   = math.floor((isSquare(item) and sq_w or min_flex_w) * factor(item))
            local add = w + (#cur > 0 and gap or 0)
            if #cur > 0 and cur_w + add > content_w then
                out[#out + 1] = cur
                cur, cur_w, add = {}, 0, w
            end
            cur[#cur + 1] = item
            cur_w = cur_w + add
        end
        if #cur > 0 then out[#out + 1] = cur end
        return out
    end

    -- Fixed point: rows -> cell_h -> square width -> rows. cell_h shrinks as rows
    -- grow, which lets more squares share a row, which can reduce rows; iterate a
    -- few times to settle. cell_h is always derived from the FINAL row count so
    -- the grid fills hero_h exactly wherever packing lands (no overflow risk).
    local function cellH(r) return math.max(1, math.floor((hero_h - gap * (r - 1)) / r)) end
    local rows_list = packAt(min_flex_w)
    for _iter = 1, 4 do
        local next_list = packAt(cellH(#rows_list))
        local settled = (#next_list == #rows_list)
        rows_list = next_list
        if settled then break end
    end

    local rows   = #rows_list
    local cell_h = cellH(rows)

    -- Per-row widths within `avail` (reduced when a chevron shares the row):
    -- squares sit at cell_h; flex cells split the remainder (rounding slack to
    -- the last flex cell so the row fills exactly). An all-square row fills the
    -- full width too (content stays centred within each cell).
    local function rowWidths(row, avail)
        local count = #row
        avail = avail - gap * (count - 1)
        local widths = {}
        local n_sq = 0
        for _i, item in ipairs(row) do if isSquare(item) then n_sq = n_sq + 1 end end
        if n_sq < count then
            -- Squares take a fixed size-scaled width (cell_h * factor); flex cells
            -- split the remainder weighted by their factor. Collectively cap the
            -- squares so the flex cells keep at least 1px each.
            local n_flex = count - n_sq
            local sq_total = 0
            for i, item in ipairs(row) do
                if isSquare(item) then
                    widths[i] = math.max(1, math.floor(cell_h * factor(item)))
                    sq_total = sq_total + widths[i]
                end
            end
            -- Cap squares so each flex cell keeps at least min_flex_w (not just
            -- 1px): otherwise a wide square (tall hero / size-nudged clock) eats
            -- the row and the flex text cells collapse to ~1px, rendering text one
            -- character per line. The square shrinks to make room instead.
            local sq_cap = math.max(0, avail - n_flex * min_flex_w)
            if sq_total > sq_cap and sq_total > 0 then
                local scaled = 0
                for i, item in ipairs(row) do
                    if isSquare(item) then
                        widths[i] = math.max(1, math.floor(widths[i] * sq_cap / sq_total))
                        scaled = scaled + widths[i]
                    end
                end
                sq_total = scaled
            end
            local rem  = math.max(n_flex, avail - sq_total)
            local wsum = 0
            for _i, item in ipairs(row) do
                if not isSquare(item) then wsum = wsum + factor(item) end
            end
            local used, last_flex = 0, nil
            for i, item in ipairs(row) do
                if not isSquare(item) then
                    widths[i] = math.max(1, math.floor(rem * factor(item) / wsum))
                    last_flex, used = i, used + widths[i]
                end
            end
            if last_flex then
                widths[last_flex] = math.max(1, widths[last_flex] + (avail - sq_total - used))
            end
        else
            -- All square: fill the FULL width (weighted by size), like every
            -- other row. Each module's content (clock face, icon) is sized by the
            -- cell height and centred, so a wider-than-square cell just gets even
            -- internal padding — no distortion. (Previously this capped each cell
            -- at MAX_SQ_RATIO*cell_h and centred the row, which left odd gaps
            -- either side of all-square rows while flex rows filled — looked
            -- inconsistent. Filling reads better and matches the other rows.)
            local wsum = 0
            for _i, item in ipairs(row) do wsum = wsum + factor(item) end
            local used = 0
            for i, item in ipairs(row) do
                widths[i] = math.max(1, math.floor(avail * factor(item) / wsum))
                used = used + widths[i]
            end
            widths[count] = widths[count] + (avail - used) -- slack to last; fill exactly
        end
        return widths
    end

    -- Single size mechanism: every cell starts at 100% and _renderFitted grows
    -- it to fill or shrinks it to fit, per cell (see that function).
    local scale_pct = 100

    -- Record each cell so it can be re-rendered in place later: _hero_cells
    -- (keyed by entry id) backs the per-module scoped refresh (tap reload +
    -- async); _hero_clock_cells is the subset wanting the minute heartbeat. A
    -- record locates the cell by its parent row + index so it can be swapped
    -- without rebuilding the grid (which would re-roll random_unread etc.).
    -- Only the current page's cells are recorded, so the heartbeat / refresh
    -- only ever touch on-screen modules.
    bw._hero_cells = {}
    bw._hero_clock_cells = {}
    -- Row/col map of entry ids for d-pad navigation (HeroModules.navMove). Only
    -- the module cells are recorded; chevrons are edge actions, not focus stops.
    bw._hero_grid_rows = {}

    local vg = VerticalGroup:new{ align = "center" }
    for r, row in ipairs(rows_list) do
        local nav_row = {}
        bw._hero_grid_rows[#bw._hero_grid_rows + 1] = nav_row
        -- Chevrons sit IN the grid: prev before the first module of the first
        -- row, next after the last module of the last row, each vertically
        -- centred in its row. They take a thin slot, so that row's modules
        -- distribute within the reduced width (no re-pack, just a touch narrower).
        local lead_chev = has_prev and r == 1
        local tail_chev = has_next and r == rows
        local reserved  = (lead_chev and (CHEV_W + gap) or 0)
                        + (tail_chev and (CHEV_W + gap) or 0)
        local mod_area  = content_w - reserved
        local widths    = rowWidths(row, mod_area)
        local row_used  = gap * (#row - 1)
        for _i, w in ipairs(widths) do row_used = row_used + w end
        -- Centre an under-full module run (a capped all-square row) within the
        -- module area so the cells sit in the middle; the grid stays content_w.
        local side = math.max(0, math.floor((mod_area - row_used) / 2))
        local hg = HorizontalGroup:new{ align = "center" }
        if lead_chev then
            hg[#hg + 1] = HeroModules._chevronCell(bw, "prev", CHEV_W, cell_h)
            hg[#hg + 1] = HorizontalSpan:new{ width = gap }
        end
        if side > 0 then hg[#hg + 1] = HorizontalSpan:new{ width = side } end
        for c, entry in ipairs(row) do
            if c > 1 then hg[#hg + 1] = HorizontalSpan:new{ width = gap } end
            local cell_w = widths[c]
            local focused = opts.focused_id ~= nil and entry.id == opts.focused_id
            hg[#hg + 1] = HeroModules._makeCell(bw, entry, cell_w, cell_h, scale_pct,
                opts.focusable, focused)
            if entry.id then nav_row[#nav_row + 1] = entry.id end
            local rec = {
                group = hg, idx = #hg, entry = entry,
                w = cell_w, h = cell_h, scale = scale_pct,
                focusable = opts.focusable,
            }
            if entry.id then bw._hero_cells[entry.id] = rec end
            local def = Modules.get(entry.module)
            if def and def.wants_minute_tick then
                bw._hero_clock_cells[#bw._hero_clock_cells + 1] = rec
            end
        end
        if side > 0 then hg[#hg + 1] = HorizontalSpan:new{ width = side } end
        if tail_chev then
            hg[#hg + 1] = HorizontalSpan:new{ width = gap }
            hg[#hg + 1] = HeroModules._chevronCell(bw, "next", CHEV_W, cell_h)
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
    for _i, rec in ipairs(cells) do
        local d = HeroModules._swapCell(bw, rec)  -- old cell's rect (or nil)
        if d then
            if not scope then
                scope = d
            else
                local x1 = math.min(scope.x, d.x)
                local y1 = math.min(scope.y, d.y)
                local x2 = math.max(scope.x + scope.w, d.x + d.w)
                local y2 = math.max(scope.y + scope.h, d.y + d.h)
                scope.x, scope.y, scope.w, scope.h = x1, y1, x2 - x1, y2 - y1
            end
        end
    end
    if scope then
        UIManager:setDirty(bw, function() return "ui", scope end)
    else
        UIManager:setDirty(bw, "ui")
    end
    return true
end

return HeroModules
