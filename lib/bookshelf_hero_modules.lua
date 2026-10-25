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
local Gestures = require("lib/bookshelf_gestures")
local CenterContainer = require("ui/widget/container/centercontainer")
local ClipContainer   = require("lib/bookshelf_clip_container")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local InputContainer  = require("ui/widget/container/inputcontainer")
local TextWidget      = require("lib/bookshelf_colour_text")
local UIManager       = require("ui/uimanager")
local Modules         = require("lib/bookshelf_start_menu_modules")
local HeroModel       = require("lib/bookshelf_hero_modules_model")
local Grid            = require("lib/bookshelf_module_grid")
local GridContainer   = require("lib/bookshelf_grid_container")
local Layout          = require("lib/bookshelf_module_layout")
local BFont           = require("lib/bookshelf_fonts")
local Breaker         = require("lib/bookshelf_module_breaker")
local BookshelfSettings = require("lib/bookshelf_settings_store")
local Space           = require("lib/bookshelf_space")
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

-- _moduleCardBg() -> the card fill, from the palette, falling back to what it
-- was before the setting existed.
--
-- SOLID, always. A semi-transparent card was tried and reverted: the widgets
-- inside a module blit opaque white buffers of their own, so over a tint every
-- line of text showed as a white box. A card cannot be less opaque than its
-- own contents, which is why the knob is a COLOUR and not an alpha.
--
-- Read per card rather than cached at load: the value follows the day/night
-- key, and a grid outlives a mode change without being rebuilt from here.
local function _moduleCardBg()
    local ok, CoverProgress = pcall(require, "lib/bookshelf_cover_progress")
    if not (ok and CoverProgress and CoverProgress.resolvedColors) then
        return HERO_CARD_BG
    end
    local ok_c, colors = pcall(CoverProgress.resolvedColors)
    if ok_c and colors and colors.module_bg then return colors.module_bg end
    return HERO_CARD_BG
end

-- _cardBorderInk() -> the hairline's colour.
--
-- FrameContainer defaults its border to BLACK, and on the light card that is
-- exactly right: a black hairline on 0xEE. Device night mode inverts the whole
-- frame and the same hairline arrives white, which is the look this is copying.
-- The shelf's OWN dark theme inverts nothing, so the border stayed black on a
-- near-black card and every edge disappeared -- the cards read as vague
-- lighter patches instead of objects, which is why true night mode looked
-- better than the theme meant to imitate it (maintainer).
--
-- COLOR_PRIMARY rather than a computed grey: on the light theme it IS black,
-- so this reproduces the old look exactly rather than approximating it.
--
-- The attribute is `color`. FrameContainer spells its border colour that way
-- ("color = Blitbuffer.COLOR_BLACK, -- border color"), and the obvious guess,
-- bordercolor, is simply an unread field on the table -- no error, no warning,
-- the border just stays black.
--
-- A reader's own pick (Micro-module border, issue 424) wins over both: the
-- hairline arrived with the wallpaper work, and on a plain page some prefer it
-- lighter than the ink.
local function _cardBorderInk()
    local ok, CoverProgress = pcall(require, "lib/bookshelf_cover_progress")
    if ok and CoverProgress and CoverProgress.resolvedColors then
        local ok_c, colors = pcall(CoverProgress.resolvedColors)
        if ok_c and colors and type(colors.module_border) ~= "nil" then
            return colors.module_border
        end
    end
    if type(Modules.COLOR_PRIMARY) ~= "nil" then return Modules.COLOR_PRIMARY end
    return Blitbuffer.COLOR_BLACK
end

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

-- _applyPalette(bw): point the module system's card colour and ink at the
-- ground this grid is drawn on. The palette is process-global (modules read it
-- at render time), and other hosts set their own: the start menu's white
-- panel, the reader. So it is set before EVERY render of a grid card, the
-- single-card re-renders included, not once per build.
--
-- Under the reader there is no shelf behind the grid (the full-screen view
-- paints white), so it takes the light defaults, not the theme of whichever
-- shelf was shown last.
function HeroModules._applyPalette(bw)
    if bw and bw._reader_context then
        if Modules.resetTheme then Modules.resetTheme() end
        return
    end
    -- Point the whole module system at the card colour BEFORE anything
    -- renders: the modules read it at render time, and the text they draw
    -- paints it as its own background. See Modules.setCardBg.
    if Modules.setCardBg then Modules.setCardBg(_moduleCardBg()) end
    -- ...and the ink that has to read on it. A card colour without a matching
    -- ink is half a theme: the cards went dark and their text stayed black
    -- (maintainer).
    if Modules.setInk then
        local ok_cp, CP = pcall(require, "lib/bookshelf_cover_progress")
        local ink, muted
        if ok_cp and CP and CP.ink then ink = CP.ink() end
        if ink then
            local ok_l, lum = pcall(function() return ink:getColor8().a end)
            if ok_l and type(lum) == "number" then
                -- A third of the way from the ink toward the card, which is
                -- what the light theme's 0x55 is between black and 0xEE.
                local card = (lum > 128) and 0x11 or 0xEE
                local m = math.floor(lum + (card - lum) / 3 + 0.5)
                muted = Blitbuffer.Color8(m)
            end
        end
        Modules.setInk(ink, muted)
    end
end

function HeroModules._swapCell(bw, rec)
    local hg  = rec and rec.group
    local old = hg and hg[rec.idx]
    if not old then return nil end
    local focused = rec.focusable and HeroModules._activeCursor(bw) == rec.entry.id
    HeroModules._applyPalette(bw)
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
-- adopt(entry, host): a module standing somewhere other than the top panel
-- or the full-screen view (a shelf) is that host's: host.save(entry) keeps
-- its settings, host.refresh() redraws it, host.hold(entry) opens its
-- editor, host.surface names where it is. Weak keys: entries are rebuilt with
-- every fetch, and the old ones simply go.
HeroModules._hosts = setmetatable({}, { __mode = "k" })
function HeroModules.adopt(entry, host)
    if type(entry) == "table" then HeroModules._hosts[entry] = host end
    return entry
end
function HeroModules._hostOf(entry)
    return type(entry) == "table" and HeroModules._hosts[entry] or nil
end

function HeroModules._ctx(bw, refresh, entry)
    local host = HeroModules._hostOf(entry)
    local reload = refresh or (host and host.refresh) or function() HeroModules._rebuild(bw) end
    local shim = { bw = bw }
    function shim:_reload() reload() end
    local ctx = { bw = bw, menu = shim, entry = entry, surface = (host and host.surface) or "hero" }
    -- Persist a per-instance change a module made to ctx.entry, then reload
    -- this cell (or rebuild the hero). No-op when the module has no entry or
    -- the entry vanished from the list.
    -- deferred: in memory only, for a run of changes whose caller flushes
    -- once at the end (the colour menu, as it closes): each write is the
    -- whole settings file, a third of a second a tap on a PW5.
    local function persist(deferred)
        if not entry then return end
        if host then host.save(entry); reload(); return end
        -- Save to the surface that owns this cell: the full-screen overlay edits
        -- its own list (bw._micro_fullscreen set), else the hero list.
        local Model = (bw and bw._micro_fullscreen)
            and require("lib/bookshelf_fullscreen_modules_model")
            or require("lib/bookshelf_hero_modules_model")
        local items = Model.load()
        local list, i = Model.findById(items, entry.id)
        if list and i then list[i] = entry end
        if deferred then Model.saveDeferred(items) else Model.save(items) end
        reload()
    end
    function ctx.save() persist(false) end
    function ctx.saveDeferred() persist(true) end
    ctx.config = require("lib/bookshelf_module_kit").entryConfig(entry, ctx.save)
    return ctx
end

-- tapped_region: the id of the module-declared tap region the gesture landed
-- in (see Kit.hitRegion), or nil for whole-cell activation - D-pad select,
-- taps outside every region, and modules that declare none all pass nil, so
-- on_tap must treat nil as the ordinary whole-card tap.
function HeroModules._tap(bw, entry, refresh, tapped_region)
    -- Settings > Behavior > Bookshelf gestures.
    if not Gestures.on("module_tap") then return end
    local def = Modules.get(entry.module)
    if not def or type(def.on_tap) ~= "function" then return end
    local ctx = HeroModules._ctx(bw, refresh, entry)
    ctx.tapped_region = tapped_region
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

-- Long-press a module: edit the layout with it selected. The host is the
-- full-screen view when it's open, else the top panel. pcall: in the reader
-- overlay bw is a minimal context shim, so an edit path that reaches for a
-- widget-only method must fail safe, not crash the reader.
function HeroModules._hold(bw, entry)
    if not Gestures.on("module_hold") then return end
    pcall(function()
        local Editor = require("lib/bookshelf_module_grid_editor")
        local host = bw._micro_fullscreen or HeroModules.heroEditHost(bw)
        Editor.open{ bw = bw, host = host, select_id = entry and entry.id }
    end)
end

-- The top panel as a layout-editor host (see bookshelf_module_grid_editor):
-- the editor's working copy is handed to the panel's build through
-- bw._module_edit and the panel is swapped in place.
function HeroModules.heroEditHost(bw)
    local host = {}
    function host.model() return HeroModel end
    function host.gridInfo() return bw._hero_grid_info end
    function host.render(_self, edit)
        bw._module_edit = edit
        if not (bw._swapMicroHeroInPlace and bw:_swapMicroHeroInPlace()) then
            if bw._rebuild then bw:_rebuild() end
            UIManager:setDirty(bw, "ui")
        elseif edit == nil then
            -- Out of edit mode: the editor faded the whole screen and its bars
            -- covered the shelf, and the swap repaints only the panel.
            UIManager:setDirty(bw, "ui")
        end
    end
    function host.footerRect()
        if not bw.footerPanelRect then return nil end
        local ok, x, y, w, h = pcall(function() return bw:footerPanelRect() end)
        if ok and x then return Geom:new{ x = x, y = y, w = w, h = h } end
    end
    return host
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

-- Fitted sizes, remembered per card and layout and kept across restarts. The
-- search below renders a card up to a dozen times to find its size (measured
-- on a PW5: each of 7 full-screen cards rendered 10 to 12 times, most of a
-- 0.5s open). A card whose cell, base scale and multiplier are unchanged is
-- rendered ONCE at the remembered size, and the result kept only if it comes
-- out exactly the size it did last time. Anything that changes what a card
-- draws -- a longer quote, a font, a theme, the card's own settings -- changes
-- that size, and the card is searched afresh. Layout changes change the key.
-- Kept in lib/bookshelf_module_cache, not the settings file.
local FIT_MEMO_KEY = "module_fit_memo"
local FIT_MEMO_CAP = 200
local _fit_memo, _fit_memo_n

local function _fitMemo()
    if not _fit_memo then
        local saved = require("lib/bookshelf_module_cache").read(FIT_MEMO_KEY)
        _fit_memo, _fit_memo_n = {}, 0
        if type(saved) == "table" then
            for k, v in pairs(saved) do
                if type(v) == "table" and tonumber(v.s) and tonumber(v.h) and tonumber(v.w) then
                    _fit_memo[k] = v
                    _fit_memo_n = _fit_memo_n + 1
                end
            end
        end
    end
    return _fit_memo
end

local function _fitMemoStore(key, rec)
    local memo = _fitMemo()
    if not memo[key] then
        _fit_memo_n = _fit_memo_n + 1
        -- Keys pile up as layouts come and go; past the cap start over rather
        -- than track ages. A dropped entry costs one search, nothing more.
        if _fit_memo_n > FIT_MEMO_CAP then
            _fit_memo, _fit_memo_n = {}, 1
            memo = _fit_memo
        end
    end
    memo[key] = rec
    -- The cache file, coalesced: never a settings write inside a paint.
    require("lib/bookshelf_module_cache").save(FIT_MEMO_KEY, memo)
end

-- Test seam: forget the in-memory copy so the next read comes from settings.
function HeroModules._resetFitMemo() _fit_memo, _fit_memo_n = nil, nil end

-- _surfaceOf(entry): where this cell is drawn. A module adopted by a host
-- (a shelf module: host.surface "shelf") says so itself; otherwise the grid
-- being built does. The shelf draws its modules outside any grid build, so
-- _build_surface alone named whichever grid was built last.
local function _surfaceOf(entry)
    local host = HeroModules._hostOf(entry)
    return (host and host.surface) or _build_surface
end

local function _renderFitted(def, inner_w, inner_h, base_scale, refresh, entry, user_mult, bw, colors, card)
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

    local function renderAt(s, clamp)
        -- Tap regions this render declares (ctx.set_tap_regions, optional):
        -- rects in the returned widget's own coordinate space. Attached to the
        -- widget itself so whichever render survives the fit/grow/clamp dance
        -- carries ITS OWN regions - the cell reads widget._tap_regions at tap
        -- time and the host does all screen-coordinate translation.
        local pending_regions
        local ctx = {
            width = inner_w, height = inner_h, scale = s, preview = false,
            refresh = refresh, shape = shape, entry = entry,
            surface = _surfaceOf(entry), bw = bw, menu = nil, config = cfg,
            -- The colours the spec declares (spec.colors), as the reader set
            -- them for the look on screen, else their defaults.
            colors = colors or {},
            -- The card the module stands on, as the reader set it with the
            -- palette icon (Card.ctxCard): a module that paints its own card
            -- uses this one when `custom`, so those settings reach every
            -- module (maintainer).
            card = card,
            set_tap_regions = function(r)
                pending_regions = type(r) == "table" and r or nil
            end,
            -- clamp (last-resort fit, #249): set only after the shrink loop
            -- bottomed out at the legibility floor with the content still
            -- overflowing. A module that can, should truncate its expendable
            -- part to ctx.height (e.g. quote_of_day ellipsises the quote so
            -- the attribution survives) instead of letting ClipContainer cut
            -- whatever happens to be at the bottom.
            clamp = clamp or nil,
        }
        local ok, widget = pcall(def.render, ctx)
        if not ok or not widget then return nil end
        if pending_regions then widget._tap_regions = pending_regions end
        local sz = widget.getSize and widget:getSize()
        return widget, (sz and sz.h) or 0, (sz and sz.w) or 0
    end

    user_mult = user_mult or 100
    local memo_key = entry and entry.id and table.concat({
        _surfaceOf(entry), tostring(def.key), tostring(entry.id),
        inner_w, inner_h, base, user_mult }, "|")
    local function free(x) if x and x.free then pcall(function() x:free() end) end end
    -- Where the search starts: the grid scale, or after a memo miss the size
    -- this card fitted at last time (m.r, before the multiplier), which is
    -- usually a step or two from the answer. A day's new quote searched from
    -- 100% every restart: 14 renders, 320ms of a 760ms open on a PW5.
    local start, start_rung = base, 1
    local widget, h, w
    if memo_key then
        local m = _fitMemo()[memo_key]
        if m then
            local mw, mh, mwid = renderAt(m.s, m.c or nil)
            if mw and mh == m.h and mwid == m.w then return mw end
            -- Only a size a search from the grid scale can reach: a rung of
            -- the 1.15 ladder it climbs (GROW_MAX_ITERS rungs at most), never
            -- one beyond. Anything else gives a card a size that depends on
            -- its history, so it searches in full.
            local ladder, cur = { base }, base
            for _i = 1, GROW_MAX_ITERS do
                local nxt = math.min(grow_cap, math.floor(cur * 1.15 + 0.5))
                if nxt <= cur then break end
                ladder[#ladder + 1], cur = nxt, nxt
            end
            local r, rung = tonumber(m.r), nil
            for i = 2, #ladder do if ladder[i] == r then rung = i end end
            if rung then
                if r == m.s and not m.c then
                    widget, h, w = mw, mh, mwid
                else
                    free(mw)
                    widget, h, w = renderAt(r)
                end
                start = r
                if widget and (h > inner_h or w > inner_w) then
                    -- Grew past its old size: the full search from the grid scale.
                    free(widget); widget, start, rung = nil, base, 1
                end
                -- Fits but fuller than the fill target: step back down the
                -- same 1.15 ladder the grow loop climbs, so the answer is the
                -- one a search from the grid scale would have reached.
                while widget and rung > 1 and h > FILL_TARGET * inner_h do
                    rung = rung - 1
                    free(widget)
                    start = ladder[rung]
                    widget, h, w = renderAt(start)
                end
                start_rung = rung
            else
                free(mw)
            end
        end
    end

    if not widget then
        start, start_rung = base, 1
        widget, h, w = renderAt(base)
    end
    if not widget then return nil end  -- render error: caller draws the fallback

    local result, result_scale, result_clamped
    if h <= inner_h and w <= inner_w then
        -- Fits at the grid scale. Markedly under-filled in HEIGHT? Grow the
        -- font to use the space, keeping the largest scale that still fits.
        -- Height is the gate, not width: a text card fills its width by design
        -- (TextBoxWidget reports the full inner_w), so the slack to reclaim is
        -- always vertical. Well-filled cards (height-aware clock/quote that
        -- already reach the target, dense text) don't grow.
        if start < grow_cap and h <= FILL_TARGET * inner_h then
            local best, cur = widget, start
            -- Rungs already climbed count against the limit, so a search that
            -- started part way up stops at the same top rung.
            for _i = 1, GROW_MAX_ITERS - (start_rung - 1) do
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
            result, result_scale = widget, start
        end
    else
        -- Overflows the grid scale: shrink. `best` keeps the latest (smallest)
        -- render so a module that never quite fits still returns a (clipped)
        -- widget, never nil; ClipContainer backstops any residual overflow. Step
        -- by scale/sqrt(overflow) — a text block's height grows ~with font area,
        -- so sqrt undoes most of the overshoot in one step.
        local best, best_scale, prev_h, scale = widget, start, h, start
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
        -- Still too tall after bottoming out? One clamped re-render (#249):
        -- lets the module truncate its expendable content to the cell height
        -- rather than have ClipContainer cut the bottom (which for a quote
        -- card is the title/author attribution). Modules that ignore
        -- ctx.clamp render identically and keep the old clipped behaviour.
        if h > inner_h then
            local cw = renderAt(result_scale, true)
            if cw then
                if result.free then pcall(function() result:free() end) end
                result = cw
                result_clamped = true
            end
        end
    end

    -- Issue #180: apply the user's "Hero micro-modules" size multiplier to the
    -- fitted scale. Default 100 = unchanged (the auto-fit result). Lower renders
    -- below the cell fill (smaller text, more whitespace — the requested "make
    -- them smaller"); higher grows past it (ClipContainer backstops overflow).
    local final_scale, final_clamp = result_scale, result_clamped
    if result and result_scale and user_mult ~= 100 then
        local adj = math.max(10, math.floor(result_scale * user_mult / 100 + 0.5))
        if adj ~= result_scale then
            -- Carry the clamp through so an upsized quote card still keeps
            -- its attribution (overflow from the multiplier is deliberate,
            -- but the module should keep choosing WHAT overflows).
            local rw, rh = renderAt(adj, result_clamped)
            -- The multiplier can overflow the cell on its own even when the
            -- auto-fit stage above never needed to clamp (issue #249: this is
            -- what let a >100% hero-module scale blow straight past the fit
            -- with no ellipsis protection at all, unlike the 100% path).
            -- Re-check at the FINAL size instead of only inheriting whatever
            -- the pre-multiplier stage decided.
            local rw_clamp = result_clamped
            if rw and rh and rh > inner_h and not result_clamped then
                local cw = renderAt(adj, true)
                if cw then
                    if rw.free then pcall(function() rw:free() end) end
                    rw, rw_clamp = cw, true
                end
            end
            if rw then
                if result.free then pcall(function() result:free() end) end
                result = rw
                final_scale, final_clamp = adj, rw_clamp
            end
        end
    end
    if memo_key and result and final_scale then
        local ok, sz = pcall(function() return result:getSize() end)
        if ok and sz and sz.h and sz.w then
            _fitMemoStore(memo_key, { s = final_scale, r = result_scale,
                                      c = final_clamp or nil, h = sz.h, w = sz.w })
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
    local Perf     = require("lib/bookshelf_perf")
    local t_cell   = Perf.now()
    local radius   = Space.px(4)
    -- Reserve the focus ring up front so a cell's content area is the same
    -- whether or not it's focused (no reflow as the cursor moves). Touch builds
    -- pass focusable=false, so they're byte-for-byte unchanged.
    local focus_b  = focusable and Screen:scaleBySize(2) or 0
    cell_w = math.max(1, cell_w - 2 * focus_b)
    cell_h = math.max(1, cell_h - 2 * focus_b)
    -- Padding scales with the (cell-derived) font scale: bigger / squarer
    -- cells get more breathing room, small cells stay tight. Floored at 6px.
    local card_pad = Space.px(math.max(6, math.floor(8 * (scale_pct or 100) / 100 + 0.5)))
    local def      = Modules.get(entry.module)
    -- A bare module (an ornament) has no card to keep its drawing off the edge
    -- of, so it takes the whole cell.
    if def and def.bare then card_pad = 0 end
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
    local host = HeroModules._hostOf(entry)
    local function refresh()
        if host and host.refresh then return host.refresh() end
        HeroModules._reloadCellById(bw, entry.id)
    end

    -- Inset text/flex modules from the cell's L/R edges so they read with even
    -- margins instead of hugging the sides: a text card fills its width but is
    -- centred vertically, so without this it has big top/bottom gaps and tight
    -- left/right. Square modules (clock/action) are icon-centred already and use
    -- the full cell. The ClipContainer below stays at inner_w, so the narrower
    -- render is centred horizontally — giving the L/R margin. Tunable.
    local is_sq      = def and (def.aspect == "square" or def.bare)
    local base_inset = Space.px(10)

    -- The module's own card look (bookshelf_module_card): its background,
    -- border and text where the reader set them, else the shared ones the
    -- host's palette already holds. Its own background and text are pointed
    -- at for its render only (the module's text paints the card colour as its
    -- own background) and the shared ones put back after.
    local Card = require("lib/bookshelf_module_card")
    local shared = { bg = Modules.CARD_BG or _moduleCardBg(), border = _cardBorderInk(),
                     ink = Modules.COLOR_PRIMARY, muted = Modules.COLOR_MUTED }
    local look = Card.look(entry, def, shared)
    local own_palette = look.bg ~= shared.bg or look.ink ~= shared.ink
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
                return _renderFitted(def, w, inner_h, scale_pct, refresh, entry, user_mult, bw, look.colors,
                    Card.ctxCard(entry, look))
            end)
        end
        if own_palette then
            Modules.setCardBg(look.bg)
            Modules.setInk(look.ink, look.muted)
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
        if own_palette then
            Modules.setCardBg(shared.bg)
            Modules.setInk(shared.ink, shared.muted)
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
            fgcolor = look.muted or Modules.COLOR_MUTED or Blitbuffer.COLOR_GRAY_5,
        }
    end

    -- ClipContainer (not CenterContainer): the parent renders the module
    -- into a bounded offscreen buffer so its draw can't escape the cell,
    -- however oversized it is. bg matches the card so the centred child's
    -- margin blends in. Held in a local so the tap handler below can
    -- translate a screen tap into module-local coordinates (clip.dimen +
    -- the recorded child centring offsets).
    -- Modules.CARD_BG, not a fresh resolve: build() set it from
    -- _moduleCardBg() before any cell was made, and reading it back is both
    -- cheaper (one table lookup against a pcall + a palette walk, per cell)
    -- and stricter -- the card cannot end up a different colour from the text
    -- drawn on it, which is the pairing the whole setting exists to keep.
    local card_bg = look.bg
    -- A bare module (an ornament) has no card: nothing is filled behind it,
    -- so the wallpaper shows round its drawing. It sizes itself to the cell,
    -- so it is centred as it is rather than clipped through the offscreen
    -- buffer, which would fill the cell first.
    local bare = def and def.bare
    if bare then card_bg = nil end
    -- in_place: painted straight onto its card, as a bare module is, for a
    -- module whose widgets place popups from their own position (offscreen,
    -- that position is the buffer's). It gives up the clip's containment.
    local in_place = bare or (def and def.in_place)
    local clip
    if in_place then
        clip = CenterContainer:new{ dimen = Geom:new{ w = inner_w, h = inner_h }, content }
    else
        clip = ClipContainer:new{
            w = inner_w,
            h = inner_h,
            bg = card_bg,
            -- A module's own buttons work in a card as in a bare module.
            pass_gestures = true,
            content,
        }
    end
    -- Hairline, where this used to be borderless. It costs nothing on a plain
    -- page and it keeps a card's edge readable when its fill happens to match
    -- what is behind it -- a wallpaper, or another card.
    --
    -- Taken OUT OF THE PADDING, not added to it. FrameContainer:getSize()
    -- counts border + padding + margin, so a border added on top widens every
    -- cell by 2*border and the row overflows content_w by 2*border per card --
    -- which reads as the grid having less air on the right than on the left,
    -- because the row is left-aligned and the overflow all lands at the far
    -- end. Eating the padding keeps the outer dimen at cell_w/cell_h exactly.
    -- The reader can switch it off per module (Card border).
    local card_border = (bare or not look.border_on) and 0 or Screen:scaleBySize(1)
    local frame = FrameContainer:new{
        background  = card_bg,
        bordersize  = card_border,
        color       = look.border,
        radius      = radius,
        padding     = math.max(0, card_pad - card_border),
        margin      = press_b, -- empty ring at rest; becomes the pressed border
        clip,
    }
    -- Wrap in a focus ring when navigable: border when focused, equal margin at
    -- rest, so the outer dimen stays cell_w/cell_h either way (the swap the chips
    -- and start-menu rows use). Keep `frame` pointing at the inner card so the
    -- press-feedback closure below still toggles the card's own border.
    local outer = frame
    if focus_b > 0 then
        outer = FrameContainer:new{
            background  = nil,
            bordersize  = focused and focus_b or 0,
            color       = _cardBorderInk(),
            margin      = focused and 0 or focus_b,
            radius      = radius,
            padding     = 0,
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
    function cell:onTap(_a, ges)
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
            -- card_border, NOT zero. Zero was right when this was written,
            -- because the card was borderless then; the hairline above was
            -- added afterwards and this reset was not updated with it, so the
            -- first tap ate the outline and only a panel rebuild put it back
            -- (issue 429). Nothing errors -- it is a valid number, just the
            -- wrong one.
            frame.bordersize = card_border
            frame.margin = press_b
        end
        -- Resolve the tap against the module's declared regions (if any):
        -- module-local = screen minus the clip's painted origin minus the
        -- centring offset it recorded at paint. The clip has always painted
        -- by the time a tap can land, so dimen/_child_dx are populated.
        local region_id
        if ges and ges.pos and content and content._tap_regions and clip.dimen then
            local Kit = require("lib/bookshelf_module_kit")
            region_id = Kit.hitRegion(content._tap_regions,
                ges.pos.x - clip.dimen.x - (clip._child_dx or 0),
                ges.pos.y - clip.dimen.y - (clip._child_dy or 0))
        end
        HeroModules._tap(bw, entry, refresh, region_id)
        return true
    end
    function cell:onHold()
        if host and host.hold then host.hold(entry) else HeroModules._hold(bw, entry) end
        return true
    end
    cell.perf_name = entry.module
    -- What it was made from, so it can be made again in place (_reloadShelfCell).
    cell._made = { entry = entry, w = cell_w, h = cell_h, scale = scale_pct,
                   focusable = focusable, focused = focused }
    Perf.part("cell " .. tostring(entry.module), t_cell)
    return cell
end

-- _reloadShelfCell(bw, id) -> true when the shelf module `id` was found on
-- the shelf as it is on screen, made again at the same size and repainted
-- over its own rect: one module, where its host's refresh rebuilds every row
-- (a Shelf module moving its lift to a face-out book: ~200 ms on the PW5).
function HeroModules._reloadShelfCell(bw, id)
    local root = bw and bw._inner_vgroup
    if not (root and id) then return false end
    local function find(node, depth)
        if type(node) ~= "table" or depth > 14 then return nil end
        for i, c in ipairs(node) do
            if type(c) == "table" then
                local m = rawget(c, "_made")
                if m and m.entry and m.entry.id == id then return node, i, c end
                local p, j, hit = find(c, depth + 1)
                if p then return p, j, hit end
            end
        end
    end
    local parent, idx, old = find(root, 0)
    if not (parent and old.dimen) then return false end
    local m = old._made
    HeroModules._applyPalette(bw)
    local fresh = HeroModules._makeCell(bw, m.entry, m.w, m.h, m.scale, m.focusable, m.focused)
    if not fresh then return false end
    parent[idx] = fresh
    if parent.resetLayout then parent:resetLayout() end
    local scope = old.dimen:copy()
    if old.free then UIManager:nextTick(function() pcall(function() old:free() end) end) end
    UIManager:setDirty(bw, function() return "ui", scope end)
    return true
end

-- Empty list: a single full-hero bordered prompt. Tap or hold opens "Add".
function HeroModules._emptyState(bw, content_w, hero_h)
    local border   = Screen:scaleBySize(1)
    local radius   = Space.px(4)
    local card_pad = Space.px(8)
    local inner_w  = math.max(1, content_w - 2 * (border + card_pad))
    local inner_h  = math.max(1, hero_h   - 2 * (border + card_pad))
    local frame = FrameContainer:new{
        background  = _moduleCardBg(),
        bordersize  = border,
        color       = _cardBorderInk(),
        radius      = radius,
        padding     = card_pad,
        margin      = 0,
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

--- Minimum width a flex cell needs before it will share a row.
---
--- twoColMinWidth() is scaleBySize(300), which scales with the screen -- and so
--- does the hero -- so it lands at ~53% of content_w at EVERY size measured
--- (412 of 776 at 824px wide, 618 of 1162 at 1236px). Two flex cells therefore
--- never fit, and the two-column path this constant is named for was
--- unreachable for them at the default size: every flex module got a full-width
--- row of its own, however little content it had (issue #359).
---
--- Capped at half the row so two can pair. Three still cannot, because 3 * half
--- exceeds content_w by construction -- so this admits a second column without
--- ever cramming a third, which is what the 300dp floor was protecting against.
function HeroModules._flexMinWidth(content_w, gap)
    local floor_w = require("lib/bookshelf_module_kit").twoColMinWidth()
    local half = math.floor(((content_w or 0) - (gap or 0)) / 2)
    if half < 1 then return floor_w end
    return math.min(floor_w, half)
end

-- The aspect-aware row packer the grid replaced, kept for one job: the
-- one-time migration snaps each module from the size this produced (see
-- Grid.snapLegacy). Returns { rows = { { {entry=, w=px}, ... }, ... }, cell_h }.
-- row_avail(r, rows), when given, narrows row r (the old in-grid chevrons).
function HeroModules._legacyPack(items, content_w, hero_h, gap, row_avail)
    -- Aspect-aware row packing. Modules opt into a square aspect (def.aspect ==
    -- "square": the clock face, action icons) so they pack as squares instead of
    -- stretching into wide rectangles. The rest are "flex" and fill the leftover
    -- width. Square modules compress to fit MORE per row down to a square (never
    -- narrower); they only expand past square to fill a row that would otherwise
    -- gap, and flex modules in a row absorb the slack so squares stay square.
    -- A flex card's minimum width: ~2 comfortable text columns on a portrait
    -- screen, so a third module wraps to the next row instead of squeezing three
    -- narrow, overflowing cells onto one row (#180 follow-up). Seeds the row
    -- count in packAt; a square card's target width is the row height.
    -- Shared with the start menu (Kit.shape's no-height path) so a card of a
    -- given width lays out the same whichever surface it is on. Required
    -- lazily here, like _renderFitted does, to keep the module-load cycle out
    -- of this file's top-level requires.
    -- See _flexMinWidth: capped at half the row so two flex cells can pair.
    local min_flex_w = HeroModules._flexMinWidth(content_w, gap)

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

    local out = {}
    for r, row in ipairs(rows_list) do
        local avail  = row_avail and row_avail(r, rows) or content_w
        local widths = rowWidths(row, avail)
        local cells  = {}
        for c, entry in ipairs(row) do cells[c] = { entry = entry, w = widths[c] } end
        out[r] = cells
    end
    return { rows = out, cell_h = cell_h }
end

-- Build the hero micro-module grid sized to content_w × hero_h.
function HeroModules.build(bw, content_w, hero_h, PAD, opts)
    opts = opts or {}
    _build_surface = opts.surface or "hero"
    -- The palette that matches the ground this grid sits on, before anything
    -- renders. See HeroModules._applyPalette.
    HeroModules._applyPalette(bw)
    -- Arm the light-touch home-screen crash marker before building the grid
    -- (issue #163). If a module hard-crashes during the hero paint, the sentinel
    -- file survives and the next launch comes up with the cover hero instead of
    -- re-crashing. The widget's paintTo removes it once the paint returns.
    pcall(Breaker.armFile, Breaker.heroMarkerPath())
    local surface = (opts.surface == "fullscreen") and "fullscreen" or "hero"
    local Model = (surface == "fullscreen")
        and require("lib/bookshelf_fullscreen_modules_model") or HeroModel
    local edit = opts.edit
    -- opts.items: the full-screen overlay passes its own list (it checks the
    -- d-pad cursor against it). The editor passes its working copy via edit.
    local items = (edit and edit.items) or opts.items or Model.load()
    if #items == 0 and not edit then
        bw._module_grid = nil
        return HeroModules._emptyState(bw, content_w, hero_h)
    end

    -- The cell grid. Full-screen: 6 columns in portrait with rows for the
    -- squarest cells, cell size kept in landscape. Top panel: its own smaller
    -- grid, two rows wherever the panel is tall enough.
    -- Half the margin between cards: the full margin read as a lot of air
    -- between modules once cells could be small (maintainer).
    local gap = math.max(1, math.floor(PAD / 2))
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local landscape = sw > sh
    local dims
    if surface == "fullscreen" then
        dims = Grid.dims("fullscreen", content_w, hero_h, gap,
            { landscape = landscape, short_side = math.min(sw, sh) })
    else
        dims = Grid.dims("panel", content_w, hero_h, gap,
            { min_row_h = Screen:scaleBySize(70) })
    end

    local boxes
    if edit then
        boxes = edit.boxes
    else
        -- The old packer laid out with the full PAD; migration replays it so.
        boxes = HeroModules._storedLayout(bw, Model, items, dims, landscape, surface,
            content_w, hero_h, PAD)
    end

    -- Pages: those holding a module (plus the editor's current page, which may
    -- be empty while you move things onto it). Resolve the current page to a
    -- real one: keep it, else the nearest used page below it, else the first.
    local pages = Grid.pages(boxes, edit and edit.page or nil)
    if #pages == 0 then pages = { 1 } end
    local want
    if edit then
        want = edit.page
    elseif surface == "fullscreen" then
        want = opts.page
    else
        want = bw._hero_page
    end
    want = want or pages[1]
    local page = pages[1]
    for _i, p in ipairs(pages) do
        if p == want then page = p; break end
        if p < want then page = p end
    end
    if surface == "hero" and not edit then
        bw._hero_page      = page
        bw._hero_page_list = pages
        bw._hero_pages     = #pages
    end

    -- Record each cell so it can be re-rendered in place later: _hero_cells
    -- (keyed by entry id) backs the per-module scoped refresh (tap reload +
    -- async); _hero_clock_cells is the subset wanting the minute heartbeat. A
    -- record locates the cell by its slot in the grid container so it can be
    -- swapped without rebuilding the grid (which would re-roll random_unread
    -- etc.). Only the current page's cells are recorded, so the heartbeat /
    -- refresh only ever touch on-screen modules.
    bw._hero_cells = {}
    bw._hero_clock_cells = {}
    bw._hero_minute_cells = {}
    -- Row/col map of entry ids for d-pad navigation (HeroModules.navMove).
    bw._hero_grid_rows = Grid.navRows(boxes, page)

    -- The grid's pixel size can come out a few px under the area (cells are
    -- whole pixels): centre it horizontally, top-align it.
    local grid_w = dims.cols * dims.cell_w + (dims.cols - 1) * gap
    local ox = math.max(0, math.floor((content_w - grid_w) / 2))
    local oy = 0
    local container = GridContainer:new{
        dimen = Geom:new{ w = content_w, h = hero_h },
        pos = {},
    }
    local by_id = {}
    for _i, it in ipairs(items) do by_id[it.id] = it end
    local scale_pct = 100
    for _i, b in ipairs(boxes) do
        local entry = (b.page == page) and by_id[b.id]
        if entry then
            local x, y, w, h = Grid.rect(dims, b)
            local focused = opts.focused_id ~= nil and entry.id == opts.focused_id
            if edit then
                -- In the layout editor a module is built only when its kept
                -- picture is missing (HeroModules._EditCell).
                local focusable = opts.focusable
                container[#container + 1] = HeroModules._EditCell:new{
                    id = entry.id, w = w, h = h, perf_name = entry.module,
                    sig = HeroModules._entrySig(entry),
                    build = function()
                        return HeroModules._makeCell(bw, entry, w, h, scale_pct, focusable, focused)
                    end,
                }
            else
                container[#container + 1] = HeroModules._makeCell(bw, entry, w, h, scale_pct,
                    opts.focusable, focused)
            end
            container.pos[#container] = { x = ox + x, y = oy + y }
            local rec = {
                group = container, idx = #container, entry = entry,
                w = w, h = h, scale = scale_pct,
                focusable = opts.focusable,
            }
            bw._hero_cells[entry.id] = rec
            local def = Modules.get(entry.module)
            if def and def.wants_minute_tick then
                bw._hero_clock_cells[#bw._hero_clock_cells + 1] = rec
            end
            if def and def.on_minute then
                bw._hero_minute_cells[#bw._hero_minute_cells + 1] = rec
            end
        end
    end
    if edit then
        -- What each module on the page is, for the editor's dimmed copies.
        local sigs = {}
        for _i, b in ipairs(boxes) do
            local entry = (b.page == page) and by_id[b.id]
            if entry then sigs[b.id] = HeroModules._entrySig(entry) end
        end
        HeroModules._editDecorations(container, dims, boxes, page, edit, ox, oy, sigs)
    end
    -- A long-press between the modules opens the layout editor too, not
    -- only one on a module (maintainer).
    if not edit then
        container.hold = function() HeroModules._hold(bw, nil) end
    end

    bw._module_grid = {
        surface = surface, dims = dims, pages = pages, page = page,
        container = container, landscape = landscape, ox = ox, oy = oy,
        boxes = boxes, key = Layout.key(landscape),
    }
    return container
end

-- Page-indicator dots for a w x h band: every page a ring, the current one
-- with a filled circle inset inside its ring; blank when there is only one
-- page. Records its screen rect and the dot rects so a host can map a tap to
-- a page (Grid.dotAt).
-- size / spacing (px) default to the top panel's small strip; the full-screen
-- footer passes bigger ones.
function HeroModules.pageDots(count, current, w, h, size, spacing)
    local Widget = require("ui/widget/widget")
    size    = size or Screen:scaleBySize(10)
    spacing = spacing or Screen:scaleBySize(24)
    local dots = Widget:new{ dimen = Geom:new{ w = w, h = h } }
    dots.rects   = (count > 1) and Grid.dotRects(count, w, h, size, spacing) or {}
    dots.spacing = spacing
    local ring  = math.max(1, math.floor(size / 8 + 0.5))
    local inset = ring + math.max(1, math.floor(size / 10 + 0.5))
    -- On the panel, not a card: Colors > Panel text (or a panel colour's
    -- own) where set.
    local ok_cp, CP = pcall(require, "lib/bookshelf_cover_progress")
    local panel_ink = ok_cp and CP and CP.panelInk and CP.panelInk() or nil
    local ink   = panel_ink or Modules.COLOR_PRIMARY or Blitbuffer.COLOR_BLACK
    function dots:paintTo(bb, x, y)
        self.dimen.x, self.dimen.y = x, y
        for i, d in ipairs(self.rects) do
            local dx, dy = x + d.x, y + d.y
            bb:paintBorder(dx, dy, d.w, d.h, ring, ink, math.floor(d.w / 2))
            if i == current then
                local inner = d.w - 2 * inset
                if inner > 0 then
                    bb:paintRoundedRect(dx + inset, dy + inset, inner, inner, ink,
                        math.floor(inner / 2))
                end
            end
        end
    end
    return dots
end

-- The current page's position in the page list (for pageDots).
function HeroModules.pageIndex(info)
    if not info then return 1 end
    for i, p in ipairs(info.pages or {}) do
        if p == info.page then return i end
    end
    return 1
end

-- Size for a module placed fresh (added, or with no position yet): in
-- proportion to the grid (Grid.defaultSize), squares (the clock face, action
-- icons) as squares, both raised to the module's declared min_w / min_h.
function HeroModules._sizeFor(entry, dims)
    local def = Modules.get(entry.module)
    local w, h = Grid.defaultSize(dims, def ~= nil and def.aspect == "square")
    -- The size the module says it starts at (spec start_w / start_h).
    if def and type(def.start_w) == "number" then w = math.max(1, math.floor(def.start_w)) end
    if def and type(def.start_h) == "number" then h = math.max(1, math.floor(def.start_h)) end
    if def and type(def.min_w) == "number" then w = math.max(w, def.min_w) end
    if def and type(def.min_h) == "number" then h = math.max(h, def.min_h) end
    return math.min(w, dims.cols), math.min(h, dims.rows)
end

-- The stored layout for this build, resolved onto `dims`. Placement work that
-- belongs in the store (a new module, the one-time upgrade, the first
-- landscape seed) is saved on the next tick -- never inside the build, which
-- runs on the paint path. Overflow onto a smaller grid is render-only.
function HeroModules._storedLayout(bw, Model, items, dims, landscape, surface,
                                   content_w, hero_h, gap)
    local migrated = BookshelfSettings.isTrue(Model.MIGRATED_KEY)
    local function legacy()
        -- The old layout, page by page as the old packer drew it (the top
        -- panel had per-module pages; the full-screen view was one page).
        local by_page, order = {}, {}
        for _i, it in ipairs(items) do
            local p = (surface == "hero") and math.max(1, math.min(tonumber(it.page) or 1, 4)) or 1
            if not by_page[p] then by_page[p] = {}; order[#order + 1] = p end
            local list = by_page[p]
            list[#list + 1] = it
        end
        table.sort(order)
        local out = {}
        for _i, p in ipairs(order) do
            local packed = HeroModules._legacyPack(by_page[p], content_w, hero_h, gap)
            for r, row in ipairs(packed.rows) do
                for _c, cell in ipairs(row) do
                    out[#out + 1] = { id = cell.entry.id, page = p, row = r,
                        px_w = cell.w, px_h = packed.cell_h }
                end
            end
        end
        return out
    end
    local boxes, changed = Layout.resolveFor(items, dims, {
        landscape = landscape,
        migrated  = migrated,
        legacy    = legacy,
        size_for  = function(it) return HeroModules._sizeFor(it, dims) end,
        page      = (surface == "hero") and bw._hero_page or nil,
    })
    if changed then
        UIManager:nextTick(function()
            Model.save(items)
            if not landscape and not migrated then
                BookshelfSettings.save(Model.MIGRATED_KEY, true)
            end
        end)
    end
    return boxes
end

-- Edit-mode drawing on top of the real-size grid: dashed outlines on empty
-- cells (under the cells), the other modules lightened and a thick outline
-- round the selected one (over them).
-- Fade a module that isn't selected toward its own card: lighter on a light
-- card, darker on a dark one (lightening a dark card left it flat grey).
function HeroModules._fade(bb, x, y, w, h, card_bg)
    -- getColor8() is FFI cdata on the device, so read .a inside the pcall.
    local ok, a = pcall(function() return card_bg:getColor8().a end)
    if ok and type(a) == "number" and a < 128 then
        bb:darkenRect(x, y, w, h, 0.5)
    else
        bb:lightenRect(x, y, w, h, 0.5)
    end
end

-- _entrySig(entry) -> a string that changes when the module's settings do,
-- and with whatever else its spec says it shows (spec cache_key(entry): the
-- Shelf module's shelf, which can change without the module's entry).
function HeroModules._entrySig(entry)
    local sig = tostring(entry)
    local ok, dump = pcall(require, "dump")
    if ok and type(dump) == "function" then
        local ok2, s = pcall(dump, entry)
        if ok2 then sig = s end
    end
    local def = entry and Modules.get(entry.module)
    if def and type(def.cache_key) == "function" then
        local ok3, extra = pcall(def.cache_key, entry)
        if ok3 and extra ~= nil then sig = sig .. "\0" .. tostring(extra) end
    end
    return sig
end

-- The layout editor dims every module but the selected one, and did so with
-- a blend on every paint: 330-390 ms of each select on a PW5 (perf log). A
-- module's dimmed look only changes with the module, its place or the time,
-- so the first is kept (per module id) and copied back after that. Dropped
-- when the editor opens and closes (_dropDimCache).
HeroModules._dim_cache = {}

function HeroModules._dropDimCache()
    for _id, rec in pairs(HeroModules._dim_cache) do
        if rec.bb then rec.bb:free() end
    end
    HeroModules._dim_cache = {}
    for _id, rec in pairs(HeroModules._paint_cache or {}) do
        if rec.bb then rec.bb:free() end
        for _i, e in ipairs(rec.extras or {}) do e.bb:free() end
    end
    HeroModules._paint_cache = {}
end

-- _dimCell(bb, id, sig, x, y, w, h): the module at that rect, dimmed: from
-- the kept copy when the module, its rect, the look and the minute are the
-- same, else blended and kept.
function HeroModules._dimCell(bb, id, sig, x, y, w, h)
    local key = table.concat({ tostring(sig), x, y, w, h, os.date("%H%M"),
        tostring(Modules.CARD_BG), tostring(bb:getType()) }, "|")
    local rec = id and HeroModules._dim_cache[id]
    if rec and rec.key == key then
        bb:blitFrom(rec.bb, x, y, 0, 0, w, h)
        return
    end
    -- Dimmed in a copy, then written back: a blend on a Kindle's
    -- framebuffer reads every pixel back from slow memory (see the editor's
    -- fade, Editor:_fadeAround).
    local ok = pcall(function()
        local c = Blitbuffer.new(w, h, bb:getType())
        c:blitFrom(require("lib/bookshelf_clip_bb").real(bb), 0, 0, x, y, w, h)
        HeroModules._fade(c, 0, 0, w, h, Modules.CARD_BG)
        bb:blitFrom(c, x, y, 0, 0, w, h)
        if id and sig then
            if rec and rec.bb then rec.bb:free() end
            HeroModules._dim_cache[id] = { key = key, bb = c }
        else
            c:free()
        end
    end)
    if not ok then HeroModules._fade(bb, x, y, w, h, Modules.CARD_BG) end
end

-- What the editor's modules drew past their cells in the grid's latest
-- paint (a Shelf module's heading): the layout editor keeps exactly these
-- clear of its fade. Started afresh as the grid paints (_editDecorations'
-- under), so a heading hidden since is not kept.
HeroModules._frame_overhangs = {}
function HeroModules._noteOverhang(r)
    local l = HeroModules._frame_overhangs
    l[#l + 1] = { x = r.x, y = r.y, w = r.w, h = r.h }
end

-- _copyOverhangs(bb, x, y, w, h) -> copies off `bb` of this paint's
-- overhangs touching that rect, each { copy, x, y, w, h }.
function HeroModules._copyOverhangs(bb, x, y, w, h)
    local out = {}
    for _i, r in ipairs(HeroModules._frame_overhangs) do
        if r.x < x + w and r.x + r.w > x and r.y < y + h and r.y + r.h > y then
            local bx, by = math.max(0, r.x), math.max(0, r.y)
            local bw = math.min(bb:getWidth() - bx, r.x + r.w - bx)
            local bh = math.min(bb:getHeight() - by, r.y + r.h - by)
            if bw > 0 and bh > 0 then
                local c = Blitbuffer.new(bw, bh, bb:getType())
                c:blitFrom(require("lib/bookshelf_clip_bb").real(bb), 0, 0, bx, by, bw, bh)
                out[#out + 1] = { copy = c, x = bx, y = by, w = bw, h = bh }
            end
        end
    end
    return out
end

-- _EditCell: a module in the layout editor. Every select, move or resize
-- rebuilt and repainted every module (on a PW5 the three-row Shelf module
-- alone painted for 745 ms each time), though while the editor is up a
-- module looks the same until it, its place or the minute changes. So the
-- first paint is kept, with anything it drew past its cell (the Shelf
-- module's heading, hooked over its plank), and put back after that; the
-- module is only built when the kept picture won't do. Nothing in the
-- editor takes input from a cell, so an unbuilt one costs nothing.
-- Dropped with the dimmed copies (_dropDimCache).
HeroModules._paint_cache = {}

HeroModules._EditCell = InputContainer:extend{
    id = nil, w = 0, h = 0, sig = nil, build = nil,
}

function HeroModules._EditCell:getSize()
    return Geom:new{ w = self.w, h = self.h }
end

function HeroModules._EditCell:_key(bb, x, y)
    local ok, CP = pcall(require, "lib/bookshelf_cover_progress")
    local look = ok and CP and CP.theme and table.concat({ tostring(CP.theme()) }, "") or ""
    return table.concat({ tostring(self.sig), x, y, self.w, self.h, os.date("%H%M"),
        tostring(Modules.CARD_BG), tostring(bb:getType()), look }, "|")
end

function HeroModules._EditCell:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.w, h = self.h }
    local on_screen = rawequal(bb, Screen.bb)
    local key = on_screen and self:_key(bb, x, y)
    local rec = key and HeroModules._paint_cache[self.id]
    if rec and rec.key == key then
        bb:blitFrom(rec.bb, x, y, 0, 0, self.w, self.h)
        for _i, e in ipairs(rec.extras) do
            bb:blitFrom(e.bb, e.x, e.y, 0, 0, e.w, e.h)
            HeroModules._noteOverhang(e)
        end
        return
    end
    if not self[1] then self[1] = self.build() end
    local ok_ss, SpineShelf = pcall(require, "lib/bookshelf_spine_shelf")
    local seq0 = ok_ss and SpineShelf.badgeSeq and SpineShelf.badgeSeq() or 0
    self[1]:paintTo(bb, x, y)
    if not on_screen then return end
    pcall(function()
        if rec then
            rec.bb:free()
            for _i, e in ipairs(rec.extras) do e.bb:free() end
        end
        local c = Blitbuffer.new(self.w, self.h, bb:getType())
        c:blitFrom(require("lib/bookshelf_clip_bb").real(bb), 0, 0, x, y, self.w, self.h)
        local extras = {}
        -- Drawn past the cell in this paint: a Shelf module's heading, below
        -- its plank.
        if ok_ss and SpineShelf.badgeRectsSince then
            for _i, r in ipairs(SpineShelf.badgeRectsSince(seq0, x, y, self.w, self.h)) do
                local inside = r.x >= x and r.y >= y and r.x + r.w <= x + self.w
                    and r.y + r.h <= y + self.h
                if not inside and r.w > 0 and r.h > 0 then
                    local e = Blitbuffer.new(r.w, r.h, bb:getType())
                    e:blitFrom(require("lib/bookshelf_clip_bb").real(bb), 0, 0, r.x, r.y, r.w, r.h)
                    extras[#extras + 1] = { bb = e, x = r.x, y = r.y, w = r.w, h = r.h }
                    HeroModules._noteOverhang(extras[#extras])
                end
            end
        end
        HeroModules._paint_cache[self.id] = { key = key, bb = c, extras = extras }
    end)
end

function HeroModules._editDecorations(container, dims, boxes, page, edit, ox, oy, sigs)
    local taken = {}
    for _i, b in ipairs(boxes) do
        if b.page == page then
            for r = b.row, b.row + b.h - 1 do
                for c = b.col, b.col + b.w - 1 do taken[r * 1000 + c] = true end
            end
        end
    end
    local dash = Screen:scaleBySize(6)
    local line = math.max(1, Screen:scaleBySize(1))
    local ink  = Blitbuffer.COLOR_DARK_GRAY
    local function dashedRect(bb, x, y, w, h)
        for i = 0, w - 1, dash * 2 do
            local len = math.min(dash, w - i)
            bb:paintRect(x + i, y, len, line, ink)
            bb:paintRect(x + i, y + h - line, len, line, ink)
        end
        for i = 0, h - 1, dash * 2 do
            local len = math.min(dash, h - i)
            bb:paintRect(x, y + i, line, len, ink)
            bb:paintRect(x + w - line, y + i, line, len, ink)
        end
    end
    function container.under(bb, x0, y0)
        HeroModules._frame_overhangs = {}
        for r = 1, dims.rows do
            for c = 1, dims.cols do
                if not taken[r * 1000 + c] then
                    local x, y, w, h = Grid.rect(dims, { col = c, row = r, w = 1, h = 1 })
                    dashedRect(bb, x0 + ox + x, y0 + oy + y, w, h)
                end
            end
        end
    end
    local thick = HeroModules.outlineOutset()
    function container.over(bb, x0, y0)
        for _i, b in ipairs(boxes) do
            if b.page == page then
                local x, y, w, h = Grid.rect(dims, b)
                x, y = x0 + ox + x, y0 + oy + y
                if b.id == edit.selected_id then
                    -- Rounded like the card it surrounds (_makeCell's radius),
                    -- grown by the outline's own width.
                    -- What hangs out of the card stays in front of its
                    -- outline: the Shelf module's heading, hooked over its
                    -- plank, had the outline run through it (maintainer).
                    -- Under the cards instead, a bare module's own ground
                    -- covered the outline on a dark theme. What the modules
                    -- drew past their cells in this paint, copied first and
                    -- put back over it.
                    local saved = HeroModules._copyOverhangs(bb,
                        x - thick, y - thick, w + 2 * thick, h + 2 * thick)
                    bb:paintBorder(x - thick, y - thick, w + 2 * thick, h + 2 * thick,
                        thick, HeroModules._outlineColor(), Space.px(4) + thick)
                    for _j, k in ipairs(saved) do
                        bb:blitFrom(k.copy, k.x, k.y, 0, 0, k.w, k.h)
                        k.copy:free()
                    end
                elseif edit.selected_id then
                    HeroModules._dimCell(bb, b.id, sigs and sigs[b.id], x, y, w, h)
                end
            end
        end
    end
end

-- outlineOutset() -> how far the layout editor's selection outline reaches
-- past the selected card. A repaint scoped to the panel takes it in
-- (BookshelfWidget:_swapMicroHeroInPlace).
function HeroModules.outlineOutset()
    return Screen:scaleBySize(4)
end

-- _outlineColor() -> the layout editor's selection outline: black, or white
-- on a dark theme the frame does not invert (night mode turns black white on
-- its own). Black vanished on a dark panel or wallpaper, and a borderless
-- module (the Shelf module) then showed no selection at all (maintainer).
function HeroModules._outlineColor()
    local ok, CP = pcall(require, "lib/bookshelf_cover_progress")
    if ok and CP and CP.theme then
        local want_dark, inverting = CP.theme()
        if want_dark ~= inverting then return Blitbuffer.COLOR_WHITE end
    end
    return Blitbuffer.COLOR_BLACK
end

-- Re-render just the time-sensitive (clock) cells in place and scope the
-- refresh to them. Driven by the bookshelf's minute heartbeat while the grid
-- is the hero. Returns false (no-op) when the grid has no clock cell, so the
-- heartbeat doesn't ghost-refresh a grid that doesn't need it. Modules are NOT
-- re-rendered wholesale (and generation is NOT bumped), so random_unread /
-- quote / etc. keep their current pick — only the clocks advance.
-- Run each visible card's on_minute(ctx) hook: a module that polls (a sensor
-- card) checks whether its data is due, and calls ctx.refresh() itself only
-- when something changed. Nothing is re-rendered here. Returns true when any
-- hook ran.
function HeroModules._tickMinuteHooks(bw)
    local cells = bw and bw._hero_minute_cells
    if not cells or #cells == 0 then return false end
    local Kit = require("lib/bookshelf_module_kit")
    for _i, rec in ipairs(cells) do
        local entry = rec.entry
        local def = entry and Modules.get(entry.module)
        if def and type(def.on_minute) == "function" then
            local id = entry.id
            pcall(def.on_minute, {
                entry = entry, config = Kit.entryConfig(entry, nil), bw = bw,
                surface = _build_surface,
                refresh = function() HeroModules._reloadCellById(bw, id) end,
            })
        end
    end
    return true
end

function HeroModules.tickClocks(bw)
    HeroModules._tickMinuteHooks(bw)
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
    -- The full-screen view's grid takes over the clock-cell list while it is
    -- open (its cells live in the overlay, on top of the shelf): repaint that.
    local target = bw._micro_fullscreen or bw
    if scope then
        UIManager:setDirty(target, function() return "ui", scope end)
    else
        UIManager:setDirty(target, "ui")
    end
    return true
end

return HeroModules
