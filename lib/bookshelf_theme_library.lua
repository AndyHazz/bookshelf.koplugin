--[[
The Theme library: every theme the default or a shelf can wear, one card
each, on the shared LibraryModal (maintainer, 2026-10-07: "a consistent way to
show and pick themes"). ONE picker for every place a theme is chosen: the
Theme menu's This shelf row (the shelf on screen's), its Default theme row
(the default every shelf without its own wears) and shelf rows (each
shelf's), and Shelf style's Theme row.

A card: the theme's name, what it brings (the Theme menu rows' icons for the
parts it has, "<wallpaper> <plank> <cup> 55 <moon>", nothing for a part it
does not have), its theme.json description when there is one,
and its hero ornament at the right end (theme.json "hero", else its newest
piece switched on). A heavier frame on a light ground marks the choice in use. A tap chooses
and moves the mark, the shelf behind is rebuilt with a full refresh a moment
later (a run of taps is one rebuild, for the last), and the picker stays
open, as the plank and wallpaper pickers do; Close (or a tap outside, or
Back) when done. Reset, in the footer between Add theme pack and Close,
brings back the original of the theme marked, greyed unless that is a pack or
Plain the reader has edited (maintainer, 2026-10-09: it left the Theme menu
for here, where the themes are). A long-press on a pack's or Plain's card
offers the same for that card (TL.showReset).

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

-- A summary is icons, the ones the Theme menu's rows wear, so a card and the
-- row that edits that part look alike (maintainer, 2026-10-09, variant B). A
-- part a pack simply has is its icon alone (wallpaper, plank, colours, light
-- or dark); ornaments are the icon and how many; Custom theme's and Plain's
-- parts keep the names that tell something (the wallpaper, the plank). A part
-- a theme does not have is left out, icon and all, never "None" (maintainer,
-- 2026-10-09). Icon parts are set apart by space, not a dot: the icon itself
-- marks where each starts. A word in front of icons (Edited, Uses: Custom
-- theme) is set apart the same way: a dot against an icon sat oddly
-- (maintainer, 2026-10-10). A dot only between two words ("Uses: Macabre
-- · Edited").
local function Icons() return require("lib/bookshelf_menu_icons") end
local NB = "\xC2\xA0"
local function ic(glyph, text) return text and (glyph .. NB .. text) or glyph end
TL.ICON_SEP = NB .. NB .. "  "

-- ornamentsPart(n) -> the ornaments' part, nil for none.
local function ornamentsPart(n)
    if not n or n < 1 then return nil end
    -- The cup overhangs its advance (1036 of 946 units): a second no-break
    -- space so it sits as far from its count as the others from their words.
    return ic((O().COLLECTION_ICON or "") .. NB, tostring(n))
end

-- wallpaperName(name) -> a wallpaper as the menus name it: a file without its
-- extension, a pack's picture by its pack; nil for none.
local function wallpaperName(name)
    if type(name) ~= "string" or name == "" then return nil end
    local tp = TP()
    if tp.isPackName(name) then
        return T(_("%1 pack"), name:match("^theme%-pack\1([^\1]+)") or "?")
    end
    return name:match("^(.+)%.[^%.]+$") or name
end

-- summary(theme, spines) -> what that theme brings, one line, or nil when
-- it brings nothing to say: "mine", "plain" or a pack. Only the parts it has
-- (see Icons above), so a pack of ornaments only says "<cup> 27" and Plain
-- only its oak plank; light or dark only when its theme.json says. The
-- reader's own is summed up from their own settings.
-- spines == false (the shelf it is for is not on Spines): a pack that brings
-- ornaments and nothing else says they only show on Spines shelves, since on
-- that shelf choosing it changes nothing to be seen (maintainer, 2026-10-08:
-- Autumn on a Covers shelf). Not for a theme with other parts: those show.
-- A pack or Plain the reader has edited says Edited first: its edits show
-- wherever it does, until it is reset (spec, 2026-10-08). all: the ornament
-- scan the caller holds (pieces).
function TL.summary(theme, spines, all)
    local tp = TP()
    local I = Icons()
    local parts = {}
    local function add(x) if x then parts[#parts + 1] = x end end
    local edited = theme ~= nil and theme ~= tp.MINE and tp.hasEdits and tp.hasEdits(theme)
    if theme == nil or theme == tp.MINE then
        -- The wallpaper's own name, as the Wallpaper row gives it ("Leafy
        -- wallpaper", "Macabre pack"); "Your wallpaper" said nothing
        -- (maintainer, 2026-10-09).
        local wp = wallpaperName(tp.mineWallpaper(false, false))
        if wp then add(ic(I.WALLPAPER, wp)) end
        local pl = tp.minePlank()
        add(ic(I.PLANK, pl and tp.plankLabel(pl) or _("Plain color")))
        add(ornamentsPart(#(O().list() or {})))
    elseif theme == tp.PLAIN then
        add(ic(I.PLANK, _("Oak")))
    else
        local th = tp.theme(theme)
        if not th.exists then return nil end
        if th.wallpaper then add(I.WALLPAPER) end
        local np = #(th.planks or {})
        if np == 1 then add(I.PLANK) elseif np > 1 then add(ic(I.PLANK, tostring(np))) end
        if th.colours then add(I.COLORS) end
        local others = #parts
        local n = TL.pieces(theme, all)
        add(ornamentsPart(n))
        local shelf = th.manifest and th.manifest.shelf
        if shelf == "dark" then add(I.DARK) elseif shelf == "light" then add(I.LIGHT) end
        if spines == false and n > 0 and others == 0 and #parts == 1 then
            parts[1] = T(_("%1 (Spines shelves only)"), parts[1])
        end
    end
    local out = #parts > 0 and table.concat(parts, TL.ICON_SEP) or nil
    if edited then out = out and (_("Edited") .. TL.ICON_SEP .. out) or _("Edited") end
    -- Second value: the line starts with a word (Edited), so a word put in
    -- front of it is set apart by a dot, not by the icons' spacing.
    return out, edited and true or false
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
-- that is switched on. Custom theme: the most recent piece the reader has on
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
    local list = tp.choiceList(ctx.current, ctx.shelf ~= nil, scan)
    local out = {}
    for _i, c in ipairs(list) do
        local it = { value = c.value, same = c.same, missing = c.missing }
        if c.same and ctx.follow then
            -- A sub-shelf's: it follows its shelf of shelves, not the
            -- default (TP.followOf).
            it.title = ctx.follow.title
            it.shows = ctx.follow.shows
        elseif c.same then
            -- Reads as following, not as a second copy of the default's
            -- card (maintainer, 2026-10-08: "Same as library (My theme)"
            -- and "My theme" looked the same): the name says Default
            -- theme, the summary which theme that is now. "Default", not
            -- "library", which is this picker's own name (maintainer,
            -- 2026-10-09).
            it.title = tp.choiceLabel(nil)
            it.shows = tp.libraryTheme()
        else
            it.title = tp.themeName(c.value)
            it.shows = c.value
        end
        if not it.missing then
            local word_first
            it.summary, word_first = TL.summary(it.shows, ctx.spines, scan.all)
            if c.same then
                local follows = T(_("Uses: %1"), tp.themeName(it.shows))
                it.summary = it.summary and (follows .. (word_first and TL.SEP or TL.ICON_SEP) .. it.summary) or follows
            end
            local p = tp.packOf(it.shows)
            local m = p and tp.theme(p).manifest
            it.description = m and m.description or nil
        end
        out[#out + 1] = it
    end
    return out
end

-- cardTitle(item) -> a card's name, the built-in ones (Default theme,
-- Custom theme, Plain) marked "* ": set apart from the packs, and first in
-- A-Z (maintainer). On the card only; menus and dialogs keep the name.
TL.BUILTIN_MARK = "* "
function TL.isBuiltin(item)
    local tp = TP()
    return item.same or item.value == tp.MINE or item.value == tp.PLAIN
end
function TL.cardTitle(item)
    if TL.isBuiltin(item) then return TL.BUILTIN_MARK .. (item.title or "") end
    return item.title
end

-- The order switch on the strip (maintainer). Newest: by the pack folder's
-- time, which a copy onto the device sets.
function TL.orders()
    return {
        { key = "az",    label = _("A-Z") },
        { key = "added", label = _("Newest") },
        { key = "used",  label = _("Last used") },
    }
end

-- usedKey(item) -> the key a card's use is kept under: Default theme's is
-- TP.FOLLOW_USED (its value is nil).
function TL.usedKey(it) return it.same and TP().FOLLOW_USED or it.value end

-- when(used) -> TL.order's lookups: used[usedKey] (the picker's snapshot),
-- and each pack's added time, asked once. Default theme, Custom theme and
-- Plain have none (Default theme's value is nil: no table key).
function TL.when(used)
    local tp, added = TP(), {}
    return {
        used = function(it) return used[TL.usedKey(it)] end,
        added = function(it)
            local v = it.value
            if v == nil or TL.isBuiltin(it) then return nil end
            if added[v] == nil then added[v] = tp.addedAt and tp.addedAt(v) or false end
            return added[v] or nil
        end,
    }
end

-- order(items, by, when) -> the cards in that order, a copy. A-Z is the
-- list's own (TP.choiceList: the built-ins, then the packs by name).
-- Newest and Last used go by that alone, nothing kept at the top
-- (maintainer): when.added(item) / when.used(item) -> a time or nil; most
-- recent first, those with none after in the list's order (the built-ins,
-- never added, end Newest).
function TL.order(items, by, when)
    local out = {}
    for i, it in ipairs(items) do out[i] = it end
    local key = (by == "added" or by == "used") and when and when[by]
    if not key then return out end
    local t, at = {}, {}
    for i, it in ipairs(out) do t[it], at[it] = key(it) or 0, i end
    table.sort(out, function(a, b)
        if t[a] ~= t[b] then return t[a] > t[b] end
        return at[a] < at[b]
    end)
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
-- pack or Plain. Not Custom theme (the reader's own, no original), not Default
-- theme (it stands for another card), not a missing pack.
function TL.resettable(item)
    local tp = TP()
    return item ~= nil and not item.same and not item.missing
        and item.value ~= nil and item.value ~= tp.MINE
end

-- canReset(item): resettable, and there is something to reset: the reader
-- has edited it. What greys the footer's Reset and the long-press's.
function TL.canReset(item)
    return TL.resettable(item) and TP().hasEdits(item.value) and true or false
end

-- marked(items, current): the card of the choice in use, or nil (a
-- choice no card stands for). Unlike indexOf, never the first card instead.
function TL.marked(items, current)
    for _i, it in ipairs(items) do
        if TL.isCurrent(it, current) then return it end
    end
end

-- showReset(item, after): a card's long-press: an edited theme is asked
-- straight away whether to go back to its original (TP.confirmReset, the
-- question the footer's Reset asks, which names the theme); one as it came
-- gets a short note instead of a greyed button (STYLE.md). Kept beside the
-- footer's Reset as a shortcut to any card's, not only the marked one's
-- (maintainer, 2026-10-09). after(): once reset. Nothing for a card that
-- cannot be reset (resettable).
function TL.showReset(item, after)
    if not TL.resettable(item) then return nil end
    if TL.canReset(item) then
        TP().confirmReset(item.value, after)
        return true
    end
    local UIManager = require("ui/uimanager")
    local note = require("ui/widget/notification"):new{
        text = T(_("%1 has no changes to reset."), item.title),
    }
    UIManager:show(note)
    return note
end

-- ── The picker ──────────────────────────────────────────────────────────
-- Four cards a page, the picker no taller than they need and centred, so
-- more of the shelf is seen around it (maintainer, 2026-10-07: "shorter so
-- we can see more behind", then three; 2026-10-09: four).
TL.PER_PAGE = 4

-- A card's height: what it was when the picker filled about half the screen
-- (SHARE) with a card to every ~CARD_DP, sized by share of the screen as the
-- plank picker is, so it is the same shape at every DPI; PER_PAGE of them
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

-- areaHeight(_cw, room) -> the cards' area: PER_PAGE cards and the gaps
-- between, no more, so the picker is no taller than its cards. Fewer cards
-- a page (not shorter ones, down to 2) when that is more than the room the
-- modal has (LibraryModal config.area_height): a small screen whose strip
-- wraps to two rows. A card gives up to SQUEEZE of its height first, so
-- four that only just miss still fit (the editor's page on a PW5, with the
-- page row: maintainer). The cards keep their height otherwise; on the
-- editor's page the spare height goes above the page row (LibraryModal).
-- TL.perPage() is how many.
TL._per_page = nil
TL.SQUEEZE = 0.12
function TL.areaHeight(_cw, room)
    local h, g = TL.cardHeight(), gap()
    local function fits(n, ch) return not room or n * ch + (n - 1) * g <= room end
    local n = TL.PER_PAGE
    while n > 2 do
        if fits(n, h) then break end
        local squeezed = math.floor((room - (n - 1) * g) / n)
        if squeezed >= h * (1 - TL.SQUEEZE) then h = squeezed; break end
        n = n - 1
    end
    TL._per_page = n
    return n * h + (n - 1) * g
end
function TL.perPage() return TL._per_page or TL.PER_PAGE end

-- heroWidget(e, box_w, box_h) -> the hero as the collection previews it
-- (bookshelf_ornament_browser.preview), over the drop shadow the piece's
-- long-press menu draws (bookshelf_ornament_menu: Orn.shadowFor, offset
-- SHADOW_DP right and down, for the frame's night). The picture is shrunk by
-- the offset so the shadow stays inside box_w x box_h. The shadow is made
-- from the render the picture paints, so still one decode a hero.
function TL.heroWidget(e, box_w, box_h)
    local Geom   = require("ui/geometry")
    local Widget = require("ui/widget/widget")
    local Screen = require("device").screen
    local OM     = require("lib/bookshelf_ornament_menu")
    local d = Screen:scaleBySize(OM.SHADOW_DP)
    local pic = require("lib/bookshelf_ornament_browser").preview(e, math.max(1, box_w - d), math.max(1, box_h - d))
    if not pic then return nil end
    local orn = O()
    local w = Widget:new{ dimen = Geom:new{ w = pic.w + d, h = pic.h + d } }
    function w:getSize() return Geom:new{ w = pic.w + d, h = pic.h + d } end
    -- Looked up once, not on every paint (each card paints on every tap).
    local ok_n, NightSync = pcall(require, "lib/bookshelf_night_mode_sync")
    function w:paintTo(bb, x, y)
        self.dimen.x, self.dimen.y = x, y
        local night = false
        if ok_n and NightSync then
            local ok, v = pcall(NightSync.active)
            night = ok and v and true or false
        end
        local p = pic.placement
        local shadow = orn.shadowFor({ entry = p.entry, w = p.w, h = p.h }, night)
        if shadow then
            pcall(function() bb:alphablitFrom(shadow, x + d, y + d, pic.src_x, pic.src_y, pic.w, pic.h) end)
        end
        pic:paintTo(bb, x, y)
    end
    return w
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
    -- Little padding above and below: three lines have to fit, also inside
    -- the keys' focus ring, which takes its width off the card.
    -- Side padding as the editor's cards have, so the name does not touch
    -- the card's edge.
    local pad, pad_v = Space.px(12), Space.padding.small
    local gap = Space.padding.default
    -- No border in the sum: the kit's card (cardify) has none, and its "in
    -- use" outline is drawn over the card's edge. Counted, the card in use
    -- (a thicker border) came out narrower than the rest.
    local inner_w = dimen.w - 2 * pad
    local inner_h = dimen.h - 2 * pad_v
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
        local w = TextWidget:new{ text = text, face = require("lib/bookshelf_fonts"):getFace("cfont", size), bold = bold,
                                  fgcolor = color, max_width = text_w }
        local h = w:getSize().h
        if used > 0 and used + h > inner_h then return end
        used = used + h
        lines[#lines + 1] = w
    end
    line(TL.cardTitle(item), 18, ink, true)
    line(item.summary, 14, ink)
    line(item.description, 13, require("lib/bookshelf_popup_kit").DIM_ON_GREY)
    local e = (not item.missing) and TL.hero(item.shows, all) or nil
    local hero = e and TL.heroWidget(e, hero_w, inner_h)
    -- The kit's grey card; the one in use outlined (a heavier frame).
    return require("lib/bookshelf_popup_kit").cardify(FrameContainer:new{
        bordersize = 0, radius = require("lib/bookshelf_popup_kit").RADIUS, margin = 0,
        padding = 0, padding_left = pad, padding_right = pad, padding_top = pad_v, padding_bottom = pad_v,
        -- 0xEE: one exact e-ink level (238), so it does not speckle.
        background = current and Blitbuffer.Color8(0xEE) or Blitbuffer.COLOR_WHITE,
        HorizontalGroup:new{ align = "center",
            LeftContainer:new{ dimen = Geom:new{ w = text_w, h = inner_h }, lines },
            HorizontalSpan:new{ width = gap },
            CenterContainer:new{ dimen = Geom:new{ w = hero_w, h = inner_h },
                                 hero or HorizontalSpan:new{ width = 1 } },
        },
    }, { outline = current })
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
--   opts.follow    a sub-shelf's TP.followOf: its first card is "Same as
--                  <its shelf of shelves>" rather than Default theme
--   opts.choose    function(value): store it (cheap; the mark moves at once)
--   opts.apply     function(): the shelf behind rebuilt for the choice; run
--                  APPLY_DELAY after the last tap, then the whole screen is
--                  refreshed (a theme is the whole look), the picker over it
--   opts.on_closed once, however it closes (the caller's menu or dialog
--                  back), after a choice still waiting has been applied
-- The footer: Add theme pack..., Reset (the marked theme, TL.canReset),
-- Close.
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
    -- The order (TL.orders), kept for the session. Last used reads the
    -- times as the picker opens and as the switch is tapped, so choosing a
    -- theme does not move the card tapped. A theme in use with no time (worn
    -- before Last used was kept) comes after those chosen, before the rest.
    local used = {}
    local when = TL.when(used)
    local usedKey = TL.usedKey
    local function load(first)
        local items = TL.items{ shelf = opts.shelf, current = opts.current(), follow = opts.follow,
                                spines = spines, scan = scan }
        if first and tp.usedAt then
            local cur, lib = opts.current(), tp.libraryChoice and tp.libraryChoice()
            for _i, c in ipairs(items) do
                local k = usedKey(c)
                if k ~= nil then
                    local in_use
                    if c.same then in_use = cur == nil else in_use = c.value == cur or c.value == lib end
                    used[k] = tp.usedAt(k) or (in_use and 1 or nil)
                end
            end
        end
        self.items = TL.order(items, TL._order or "az", when)
    end
    load(true)
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
    -- The shelf behind shows each theme tapped with a plain ui refresh, which
    -- leaves the picker's unchanged pixels alone: a full one flashed the
    -- picker too, after the card's own outline (maintainer: one paint per
    -- tap). The full refresh that clears what the previews leave on e-ink
    -- is made once, as the picker closes (on_closed), and only if a theme
    -- was applied.
    local applied = false
    local function apply()
        if not waiting then return end
        waiting = false
        UIManager:unschedule(apply)
        if opts.apply then opts.apply() end
        -- No refresh of its own: the shelf's rebuild asks for one
        -- (BookshelfWidget:_syncShelfTheme).
        applied = true
    end
    -- reset(theme): once a theme's edits are gone, from the footer or a
    -- card's long-press. Its card loses Edited and the footer's Reset greys
    -- at once (the picker's own ui refresh, no flash on a PW5); the shelf
    -- behind follows when it shows that theme, as a tap does: one full
    -- refresh APPLY_DELAY later, never a second one before it.
    local function reset(theme)
        load()
        if modal then modal:refresh() end
        if tp.shelfTheme and tp.shelfTheme() == theme then
            UIManager:unschedule(apply)
            waiting = true
            UIManager:scheduleIn(TL.APPLY_DELAY, apply)
        end
    end
    local config = {
        title = opts.shelf and T(_("Theme: %1"), opts.shelf) or tp.choiceLabel(nil),
        -- opts.over: opened from the shelf editor, a page of it (its frame,
        -- its breadcrumb, Close as the back chevron); LibraryModal config.over.
        over = opts.over,
        no_search = true,
        -- The outline moving to the card is the tap's feedback.
        select_on_tap = true,
        grid_cols = function() return 1 end,
        cells_per_page = function() return TL.perPage() end,
        area_height = TL.areaHeight,
        cell_renderer = function(item, dimen)
            return TL._renderCard(item, dimen, TL.isCurrent(item, opts.current()), scan.all)
        end,
        on_cell_tap = function(item)
            if item.missing or TL.isCurrent(item, opts.current()) then return end
            opts.choose(item.value)
            if tp.markUsed then tp.markUsed(item.same and tp.FOLLOW_USED or item.value) end
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
        -- A pack or Plain: Reset to original, for that card.
        cell_long_tap = function(item)
            TL.showReset(item, function() reset(item.value) end)
        end,
        -- A-Z | Newest | Last used, at the left of the strip.
        chip_strip = function()
            local out = {}
            for _i, o in ipairs(TL.orders()) do
                out[#out + 1] = { key = o.key, label = o.label, is_active = o.key == (TL._order or "az") }
            end
            return out
        end,
        on_chip_tap = function(key)
            TL._order = key
            load(true)
        end,
        item_count = function() return #self.items end,
        item_at = function(i) return self.items[i] end,
        -- Add theme pack and Reset: the screen's own actions, on the strip
        -- under the title (STYLE.md); the footer keeps Close.
        header_actions = {
            -- At the left: with no chips, both at the right left the strip
            -- looking half empty (maintainer).
            { key = "add", label = tp.addThemeLabel(), at_left = true,
              on_tap = function() tp.showAddThemeInfo() end },
            -- The theme marked, whatever page is shown: the one in use where
            -- the picker was opened from (maintainer, 2026-10-09). Greyed for
            -- Custom theme and Default theme, and for a theme as original;
            -- asked first, as the long-press asks (TP.confirmReset).
            -- Says what it resets, now there is room (maintainer).
            { key = "reset", label = _("Reset edited theme"),
              enabled_when = function() return TL.canReset(TL.marked(self.items, opts.current())) end,
              on_tap = function()
                  local item = TL.marked(self.items, opts.current())
                  if not TL.canReset(item) then return end
                  tp.confirmReset(item.value, function() reset(item.value) end)
              end },
        },
        footer_rows = { {
            { key = "close", label = _("Close"), on_tap = close },
        } },
        on_closed = function()
            modal = nil
            apply()
            TL.previewing = false
            -- No flash after a theme was chosen: the shelf behind was redrawn
            -- as each was tapped, and the modal's close refreshes where it
            -- was (maintainer).
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
    -- Keys: no focus ring until the first key press, which shows it on the
    -- choice in use when that is on the page shown. Seeded at open, the ring
    -- sat on the first card while the choice was on another page, and read
    -- as the in-use mark (review, 2026-10-09).
    config.focus_on_key = function() return TL.indexOf(self.items, opts.current()) end
    -- Always opens on the first page, where Custom theme and Plain (and Default
    -- theme) are, wherever the choice in use is: its card is marked on its
    -- own page (maintainer, 2026-10-08: opened on Ukiyo-e's page, the
    -- built-ins were out of sight).
    modal = LibraryModal:new{ config = config, page = 1 }
    -- The shelf's own look-change refresh is a plain one while this is up
    -- (BookshelfWidget:_syncShelfTheme).
    TL.previewing = true
    own_defer = orn.beginDeferred ~= nil and not orn._defer
    if own_defer then orn.beginDeferred() end
    UIManager:show(modal)
    return modal
end

return TL
