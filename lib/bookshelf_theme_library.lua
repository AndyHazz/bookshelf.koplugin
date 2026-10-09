--[[
The Theme library: every theme the default or a shelf can wear, one card
each, on the shared LibraryModal (maintainer, 2026-10-07: "a consistent way to
show and pick themes"). ONE picker for every place a theme is chosen: the
Theme menu's This shelf row (the shelf on screen's), its Default theme row
(the default every shelf without its own wears) and shelf rows (each
shelf's), and Shelf style's Theme row.

A card: the theme's name, what it brings ("Wallpaper · Plank · 55 ornaments ·
Dark", only the parts it has), its theme.json description when there is one,
and its hero ornament at the right end (theme.json "hero", else its newest
piece switched on). A heavier frame on a light ground marks the choice in use. A tap chooses
and moves the mark, the shelf behind is rebuilt with a full refresh a moment
later (a run of taps is one rebuild, for the last), and the picker stays
open, as the plank and wallpaper pickers do; Close (or a tap outside, or
Back) when done. A long-press on a pack's or Plain's card offers Reset to
original, greyed while that theme is unedited (TL.showReset).

Cheap to open: the parts come from the theme scan (bookshelf_theme_pack) and
the ornament counts from the ornament scan (listAll: file headers, nothing
decoded); only the heroes on the page are rendered, through the ornaments'
own cache.
]]
local ok_i, I18n = pcall(require, "lib/bookshelf_i18n")
local _ = (ok_i and I18n and I18n.gettext) or function(s) return s end
local ok_u, FUtil = pcall(require, "ffi/util")
local T = (ok_u and FUtil and FUtil.template) or function(f, ...)
    local args = { ... }
    return (f:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
end

local TL = {}

-- Seams for the tests.
TL._tp, TL._orn = nil, nil
local function TP() return TL._tp or require("lib/bookshelf_theme_pack") end
local function O() return TL._orn or require("lib/bookshelf_ornaments") end

-- Between the parts of a summary: a middle dot, not part of any msgid.
TL.SEP = " \xC2\xB7 "

-- scan() -> { all, packs }: the ornament scan, taken ONCE per picker open
-- (show) or per items() and handed down to every card. listAll walks every
-- ornament folder before it can answer from its cache (~28ms on a PW5), and
-- asked per card part it was 18 walks for each open and each tap (measured
-- 2026-10-08). The picker holds it for its life: nothing it does adds or
-- removes a piece, and the next open (after the Theme menu's rescan) sees
-- what was copied in meanwhile.
function TL.scan()
    local all, packs = O().listAll()
    return { all = all or {}, packs = packs or {} }
end

-- pieces(pack, all) -> how many ornaments the pack holds, counted from the
-- ornament scan (all: the one the caller holds, else a scan now) once per
-- scan (listAll hands back the same table while nothing on disk changed).
local _counted_from, _counts
function TL.pieces(pack, all)
    all = all or O().listAll() or {}
    if _counted_from ~= all then
        local c = {}
        for _i, e in ipairs(all) do
            if e.pack then c[e.pack] = (c[e.pack] or 0) + 1 end
        end
        _counted_from, _counts = all, c
    end
    return _counts[pack] or 0
end

local function ornamentsPart(n)
    if n == 0 then return _("No ornaments") end
    if n == 1 then return _("1 ornament") end
    return T(_("%1 ornaments"), n)
end

-- summary(theme, spines) -> what that theme brings, one line: "mine",
-- "plain" or a pack. Only the parts a pack has, so a pack of ornaments only
-- says "27 ornaments" and nothing else; light or dark only when its
-- theme.json says. The reader's own is summed up from their own settings.
-- spines == false (the shelf it is for is not on Spines): a pack that brings
-- ornaments and nothing else says they only show on Spines shelves, since on
-- that shelf choosing it changes nothing to be seen (maintainer, 2026-10-08:
-- Autumn on a Covers shelf). Not for a theme with other parts: those show.
-- A pack or Plain the reader has edited says Edited first: its edits show
-- wherever it does, until it is reset (spec, 2026-10-08). all: the ornament
-- scan the caller holds (pieces).
function TL.summary(theme, spines, all)
    local tp = TP()
    local parts = {}
    local function add(s) parts[#parts + 1] = s end
    local edited = theme ~= nil and theme ~= tp.MINE and tp.hasEdits and tp.hasEdits(theme)
    if edited then add(_("Edited")) end
    if theme == nil or theme == tp.MINE then
        add(tp.mineWallpaper(false, false) and _("Your wallpaper") or _("No wallpaper"))
        local pl = tp.minePlank()
        add(pl and tp.plankLabel(pl) or _("Plain color"))
        add(ornamentsPart(#(O().list() or {})))
    elseif theme == tp.PLAIN then
        add(_("No wallpaper")); add(_("Oak")); add(_("No ornaments"))
    else
        local th = tp.theme(theme)
        if not th.exists then return nil end
        local first = #parts
        if th.wallpaper then add(_("Wallpaper")) end
        local np = #(th.planks or {})
        if np == 1 then add(_("Plank")) elseif np > 1 then add(T(_("%1 planks"), np)) end
        if th.colours then add(_("Colors")) end
        local others = #parts - first
        local n = TL.pieces(theme, all)
        if n > 0 then add(ornamentsPart(n)) end
        local shelf = th.manifest and th.manifest.shelf
        if shelf == "dark" then add(_("Dark")) elseif shelf == "light" then add(_("Light")) end
        if spines == false and n > 0 and others == 0 and #parts == first + 1 then
            parts[#parts] = T(_("%1 (Spines shelves only)"), parts[#parts])
        end
    end
    return table.concat(parts, TL.SEP)
end

-- spinesShown() -> is the shelf on screen on Spines: true or false, nil
-- when there is no shelf to ask (then no card says anything about it). The
-- Theme menu puts the shelf a picker is for on screen before opening it, and
-- Shelf style is opened over the shelf it edits.
function TL.spinesShown()
    local function ask(w)
        if type(w) ~= "table" or type(w._isSpineMode) ~= "function" then return nil end
        local ok, v = pcall(w._isSpineMode, w)
        if ok then return v and true or false end
        return nil
    end
    local S = package.loaded["lib/bookshelf_settings"]
    local v = ask(type(S) == "table" and S._bw or nil)
    if v ~= nil then return v end
    local ok, UIManager = pcall(require, "ui/uimanager")
    for _i, e in ipairs((ok and UIManager and UIManager._window_stack) or {}) do
        v = ask(e.widget)
        if v ~= nil then return v end
    end
    return nil
end

-- hero(theme) -> the ornament entry a theme's card shows, or nil. A pack:
-- its theme.json "hero" (a piece's file stem, any case) unless that piece is
-- switched off; else its most recently added or changed piece (file mtime)
-- that is switched on. My theme: the most recent piece the reader has on
-- (the collection, loose pieces included). Plain: none. Pieces switched off
-- are skipped (the starter cacti, maintainer 2026-10-07): for a pack or
-- Plain whose ornaments the reader has edited, those not in its edited set
-- (bookshelf_theme_pack EDITABLE THEMES). Cached per theme while the scan
-- and the switches are unchanged, so the files are stat'ed once, not per
-- paint. all: the ornament scan the picker holds (else a scan now).
TL._hero_cache = {}
function TL.hero(theme, all)
    local tp, orn = TP(), O()
    local mine = (theme == nil or theme == tp.MINE)
    local ed = (not mine) and tp.editsOf and tp.editsOf(theme) or nil
    local set = ed and type(ed.pieces) == "table" and ed.pieces or nil
    if theme == tp.PLAIN and not set then return nil end
    all = all or orn.listAll() or {}
    local pool = mine and (orn.list() or {}) or all
    local key = tostring(theme) .. "|" .. tostring(all) .. "|" .. tostring(orn.list()) .. "|" .. tostring(set)
    local hit = TL._hero_cache[key]
    if hit ~= nil then return hit or nil end
    local want
    if not mine then
        local m = tp.theme(theme).manifest
        want = m and m.hero and m.hero:lower()
    end
    local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")
    local function mtime(e)
        local t = lfs_ok and lfs and e.path and lfs.attributes(e.path, "modification")
        return tonumber(t) or 0
    end
    local best, best_t
    local function on(e)
        if mine then return not orn.isOff(e.name) end
        if set then return set[e.name] == true end
        return e.pack == theme
    end
    for _i, e in ipairs(pool) do
        if on(e) then
            if want and orn.displayName(e):lower() == want then best = e; break end
            local t = mtime(e)
            -- Newest first; a tie keeps the earlier by name (the list's order).
            if not best or t > best_t then best, best_t = e, t end
        end
    end
    TL._hero_cache[key] = best or false
    return best
end

-- items(ctx) -> the cards, in menu order. ctx.shelf: a shelf's picker
-- (Default theme first); ctx.current: the choice in use (a missing pack still
-- chosen is listed, marked, and cannot be chosen again); ctx.spines: is the
-- shelf it is for on Spines (summary); ctx.scan: the picker's ornament scan
-- (TL.scan; else one is taken here, once for every card).
--   { value, same, missing, title, shows, summary, description }
-- shows: the theme the card stands for (Default theme: the default's).
function TL.items(ctx)
    local tp = TP()
    local scan = ctx.scan or TL.scan()
    local list
    if ctx.shelf then
        list = tp.shelfChoices(ctx.current, scan)
    else
        list = {}
        local cur = ctx.current
        if tp.packOf(cur) and not tp.theme(cur).exists then
            list[1] = { value = cur, missing = true }
        end
        for _i, c in ipairs(tp.choices(scan)) do list[#list + 1] = c end
    end
    local out = {}
    for _i, c in ipairs(list) do
        local it = { value = c.value, same = c.same, missing = c.missing }
        if c.same then
            -- Reads as following, not as a second copy of the default's
            -- card (maintainer, 2026-10-08: "Same as library (My theme)"
            -- and "My theme" looked the same): the name says Default
            -- theme, the summary which theme that is now. "Default", not
            -- "library", which is this picker's own name (maintainer,
            -- 2026-10-09).
            it.title = _("Default theme")
            it.shows = tp.libraryTheme()
        else
            it.title = tp.themeName(c.value)
            it.shows = c.value
        end
        if not it.missing then
            it.summary = TL.summary(it.shows, ctx.spines, scan.all)
            if c.same then
                local follows = T(_("Uses: %1"), tp.themeName(it.shows))
                it.summary = it.summary and (follows .. TL.SEP .. it.summary) or follows
            end
            local p = tp.packOf(it.shows)
            local m = p and tp.theme(p).manifest
            it.description = m and m.description or nil
        end
        out[#out + 1] = it
    end
    return out
end

-- isCurrent(item, current) -> that card is the choice in use.
function TL.isCurrent(item, current)
    if item.same then return current == nil end
    return current ~= nil and item.value == current
end

-- indexOf(items, current) -> the card of the choice in use (1 if none).
function TL.indexOf(items, current)
    for i, it in ipairs(items) do
        if TL.isCurrent(it, current) then return i end
    end
    return 1
end

-- resettable(item): that card's theme can be reset to its original: a
-- pack or Plain. Not My theme (the reader's own, no original), not Default
-- theme (it stands for another card), not a missing pack.
function TL.resettable(item)
    local tp = TP()
    return item ~= nil and not item.same and not item.missing
        and item.value ~= nil and item.value ~= tp.MINE
end

-- showReset(item, after): a card's long-press: a small dialog titled with
-- the theme, holding Reset to original, greyed unless that theme has edits,
-- asked again before anything is lost (TP.confirmReset, the question the
-- Theme menu's Reset row asks), as a long-press on a Bookends preset opens
-- its Manage dialog (maintainer, 2026-10-09). after(): once reset. Nothing
-- for a card that cannot be reset (resettable).
function TL.showReset(item, after)
    if not TL.resettable(item) then return nil end
    local tp = TP()
    local UIManager = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local theme = item.value
    local d
    d = ButtonDialog:new{
        title = item.title,
        title_align = "center",
        buttons = { { {
            text = _("Reset to original"),
            enabled = tp.hasEdits(theme) and true or false,
            callback = function()
                UIManager:close(d)
                tp.confirmReset(theme, after)
            end,
        } } },
    }
    UIManager:show(d)
    return d
end

-- ── The picker ──────────────────────────────────────────────────────────
-- Three cards a page, the picker no taller than they need and centred, so
-- more of the shelf is seen around it (maintainer, 2026-10-07: "shorter so
-- we can see more behind").
TL.PER_PAGE = 3

-- A card's height: what it was when the picker filled about half the screen
-- (SHARE) with a card to every ~CARD_DP, sized by share of the screen as the
-- plank picker is, so it is the same shape at every DPI; three of them now
-- make the picker's whole height.
TL.SHARE, TL.CARD_DP = 0.55, 84

local function gap() return require("lib/bookshelf_space").px(10) end   -- LibraryModal's MARGIN

function TL.cardHeight()
    local LibraryModal = require("lib/bookshelf_library_modal")
    local Screen = require("device").screen
    local rows = LibraryModal.rowsForShare(TL.SHARE)
    if Screen:getWidth() > Screen:getHeight() then rows = math.max(2, rows - 1) end  -- as the modal shaves
    local g = gap()
    local area = rows * Screen:scaleBySize(64) + (rows - 1) * g
    local n = math.max(2, math.floor((area + g) / (Screen:scaleBySize(TL.CARD_DP) + g)))
    return math.floor((area - (n - 1) * g) / n)
end

-- areaHeight() -> the cards' area: PER_PAGE cards and the gaps between, no
-- more, so the picker is no taller than its cards.
function TL.areaHeight()
    return TL.PER_PAGE * TL.cardHeight() + (TL.PER_PAGE - 1) * gap()
end

-- _renderCard(item, dimen, current, all) -> the card: the name, the summary,
-- the description (if there is room), the hero on the right (all: the
-- picker's ornament scan, TL.hero). The choice in use is a heavier frame on
-- a light ground (maintainer, 2026-10-07: no radio mark, it did not look
-- good on a card).
function TL._renderCard(item, dimen, current, all)
    local Blitbuffer      = require("ffi/blitbuffer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local Font            = require("ui/font")
    local FrameContainer  = require("ui/widget/container/framecontainer")
    local Geom            = require("ui/geometry")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan  = require("ui/widget/horizontalspan")
    local LeftContainer   = require("ui/widget/container/leftcontainer")
    local Size            = require("ui/size")
    local Space           = require("lib/bookshelf_space")
    local TextWidget      = require("lib/bookshelf_colour_text")
    local VerticalGroup   = require("ui/widget/verticalgroup")
    local border = current and Size.border.thick or Size.border.thin
    -- Little padding above and below: three lines have to fit, also inside
    -- the keys' focus ring, which takes its width off the card.
    local pad, pad_v = Space.padding.default, Space.padding.small
    local gap = Space.padding.default
    local inner_w = dimen.w - 2 * (border + pad)
    local inner_h = dimen.h - 2 * (border + pad_v)
    -- The hero's box: square, the card's height, never more than a quarter
    -- of its width. Kept on every card, with or without a hero, so the names
    -- line up down the page.
    local hero_w = math.max(1, math.min(inner_h, math.floor(inner_w / 4)))
    local text_w = math.max(1, inner_w - hero_w - gap)
    local ink = item.missing and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_BLACK
    -- The name, then the summary, then the description, each one line (cut
    -- with an ellipsis), each only while it fits the card's height.
    local lines = VerticalGroup:new{ align = "left" }
    local used = 0
    local function line(text, size, color, bold)
        if not text or text == "" then return end
        local w = TextWidget:new{ text = text, face = Font:getFace("cfont", size), bold = bold,
                                  fgcolor = color, max_width = text_w }
        local h = w:getSize().h
        if used > 0 and used + h > inner_h then return end
        used = used + h
        lines[#lines + 1] = w
    end
    line(item.title, 18, ink, true)
    line(item.summary, 14, ink)
    line(item.description, 13, Blitbuffer.COLOR_DARK_GRAY)
    local e = (not item.missing) and TL.hero(item.shows, all) or nil
    local hero = e and require("lib/bookshelf_ornament_browser").preview(e, hero_w, inner_h)
    return FrameContainer:new{
        bordersize = border, radius = Space.radius.default, margin = 0,
        padding = 0, padding_left = pad, padding_right = pad, padding_top = pad_v, padding_bottom = pad_v,
        -- 0xEE: one exact e-ink level (238), so it does not speckle.
        background = current and Blitbuffer.Color8(0xEE) or Blitbuffer.COLOR_WHITE,
        HorizontalGroup:new{ align = "center",
            LeftContainer:new{ dimen = Geom:new{ w = text_w, h = inner_h }, lines },
            HorizontalSpan:new{ width = gap },
            CenterContainer:new{ dimen = Geom:new{ w = hero_w, h = inner_h },
                                 hero or HorizontalSpan:new{ width = 1 } },
        },
    }
end

-- How long after a tap the shelf behind is rebuilt: long enough for the
-- moved mark to show first, and for taps made while a rebuild ran to arrive
-- and be counted as one (only the last is built).
TL.APPLY_DELAY = 0.15

-- show(opts): the picker.
--   opts.shelf     a shelf's label: that shelf's picker (Default theme
--                  first, titled "Theme: <label>"); nil for the default's,
--                  titled "Default theme", what it sets (maintainer,
--                  2026-10-09)
--   opts.current   function() -> the choice in use (nil: Default theme)
--   opts.choose    function(value): store it (cheap; the mark moves at once)
--   opts.apply     function(): the shelf behind rebuilt for the choice; run
--                  APPLY_DELAY after the last tap, then the whole screen is
--                  refreshed (a theme is the whole look), the picker over it
--   opts.on_closed once, however it closes (the caller's menu or dialog
--                  back), after a choice still waiting has been applied
function TL.show(opts)
    local LibraryModal = require("lib/bookshelf_library_modal")
    local UIManager    = require("ui/uimanager")
    local tp = TP()
    -- A pack copied in (or deleted) since the last look is seen now.
    tp.rescan()
    local self = {}
    -- Asked once: the shelf behind keeps its style while the picker is open.
    local spines = TL.spinesShown()
    -- The ornaments, scanned once for the picker's life (TL.scan): every
    -- card, every page and every tap's relisting read this one.
    local scan = TL.scan()
    local function load()
        self.items = TL.items{ shelf = opts.shelf, current = opts.current(), spines = spines, scan = scan }
    end
    load()
    local modal
    -- Each tap's choice is kept in memory and the settings file written
    -- once, as the picker closes however it closes (on_closed), as the
    -- ornament collection does (Orn.beginDeferred): written per tap, the
    -- 125 KB file cost ~60ms of every tap on a PW5 (measured 2026-10-08).
    -- Not ours to end when something else began it; begun only as the
    -- picker is shown, so there is always a close to end it. A suspend or
    -- an autosave while it is open writes too (bookshelf_widget).
    local orn = O()
    local own_defer = false
    local function close() if modal then UIManager:close(modal) end end
    -- The shelf behind follows the cards: one rebuild for a run of taps
    -- (the last choice wins), and none left waiting when the picker closes.
    local waiting = false
    local function apply()
        if not waiting then return end
        waiting = false
        UIManager:unschedule(apply)
        if opts.apply then opts.apply() end
        UIManager:setDirty("all", "full")
    end
    local config = {
        title = opts.shelf and T(_("Theme: %1"), opts.shelf) or _("Default theme"),
        no_search = true,
        grid_cols = function() return 1 end,
        cells_per_page = function() return TL.PER_PAGE end,
        area_height = TL.areaHeight,
        cell_renderer = function(item, dimen)
            return TL._renderCard(item, dimen, TL.isCurrent(item, opts.current()), scan.all)
        end,
        on_cell_tap = function(item)
            if item.missing or TL.isCurrent(item, opts.current()) then return end
            opts.choose(item.value)
            -- Listed again: a missing pack that was the choice drops out.
            load()
            if modal then
                -- Keys: the focus stays on the card just chosen.
                if modal._dpad_idx then modal._dpad_idx = TL.indexOf(self.items, opts.current()) end
                modal:refresh()
            end
            UIManager:unschedule(apply)
            waiting = true
            UIManager:scheduleIn(TL.APPLY_DELAY, apply)
        end,
        -- A pack or Plain: Reset to original. Its card loses Edited, and the
        -- shelf behind follows when it shows that theme.
        cell_long_tap = function(item)
            TL.showReset(item, function()
                load()
                if modal then modal:refresh() end
                if tp.shelfTheme and tp.shelfTheme() == item.value then
                    UIManager:unschedule(apply)
                    waiting = true
                    UIManager:scheduleIn(TL.APPLY_DELAY, apply)
                end
            end)
        end,
        item_count = function() return #self.items end,
        item_at = function(i) return self.items[i] end,
        footer_rows = { {
            { key = "add", label = tp.addThemeLabel(), on_tap = function() tp.showAddThemeInfo() end },
            { key = "close", label = _("Close"), on_tap = close },
        } },
        on_closed = function()
            modal = nil
            apply()
            if own_defer then
                own_defer = false
                -- Once the close has painted: the write (~115ms on a PW5)
                -- then does not hold up the shelf coming back.
                if UIManager.tickAfterNext then
                    UIManager:tickAfterNext(function() orn.endDeferred() end)
                else
                    orn.endDeferred()
                end
            end
            if opts.on_closed then pcall(opts.on_closed) end
        end,
    }
    -- Always opens on the first page, where My theme and Plain (and Default
    -- theme) are, wherever the choice in use is: its card is marked on its
    -- own page (maintainer, 2026-10-08: opened on Ukiyo-e's page, the
    -- built-ins were out of sight).
    local at = TL.indexOf(self.items, opts.current())
    local per = math.max(1, config.cells_per_page())
    modal = LibraryModal:new{ config = config, page = 1 }
    -- Keys: the focus starts on the choice in use when it is on that page.
    if modal._dpad_idx then modal._dpad_idx = (at <= per) and at or 1; modal:refresh() end
    own_defer = orn.beginDeferred ~= nil and not orn._defer
    if own_defer then orn.beginDeferred() end
    UIManager:show(modal)
    return modal
end

return TL
