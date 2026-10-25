--[[
Micro-module: one of your shelves. Shows the books of a shelf (a tab, or a
sub-shelf) in that shelf's own style -- covers, or spines standing on a plank
-- with its source, filters and sort, as many as the cell holds. A folder
-- shelf shows the books under it, flattened. Edit the
shelf itself to change what it shows; this card only chooses which shelf.

An optional heading sits top left, the shelf's name unless renamed; a tap on
it opens that shelf. A tap on a book opens the book.

Shelves that hold groups (series, authors, genres, tags...) and shelves of
shelves aren't offered: they show stacks, not books. Nor are online (OPDS)
shelves: a card never fetches from the network on its own. List-style shelves show
as covers (a list of titles is no use in a small cell).

Drawn bare (no card): covers and planks stand on the wallpaper as they do on
the shelf, and the shelf's own widgets take the taps.
]]
local _ = require("lib/bookshelf_i18n").gettext
local T = require("ffi/util").template

-- Sources a card doesn't show: groups (stacks, not books), shelves of
-- shelves, and online catalogues (a card never fetches on its own).
local GROUP_KINDS = {
    series = true, authors = true, genres = true, tags = true,
    formats = true, ratings = true, languages = true, shelves = true,
    opds = true,
}

local function isBookShelf(tab)
    if type(tab) ~= "table" or type(tab.source) ~= "table" then return false end
    return not GROUP_KINDS[tab.source.kind]
end

-- The heading: the custom text, else the shelf's label as it is -- icons and
-- [icon=NAME] pictures included, drawn as the chip draws them.
local function headingText(custom, tab)
    if type(custom) == "string" and custom ~= "" then return custom end
    local label = tab and tab.label
    if type(label) == "string" and label ~= "" then return label end
    return _("Shelf")
end

-- A label for plain-text buttons (the shelf picker): [icon=NAME] pictures
-- can't be drawn there, so they go; icon glyphs stay. nil if nothing's left.
local function plainLabel(label)
    if type(label) ~= "string" then return nil end
    label = label:gsub("%[icon=[^%]]*%]", ""):gsub("^%s+", ""):gsub("%s+$", "")
    return label ~= "" and label or nil
end

--- Rows of books a body `avail_h` tall holds at no less than `min_row_h`
--- each: at least one, at most four.
local function rowsFor(avail_h, min_row_h)
    return math.max(1, math.min(4, math.floor((avail_h or 0) / math.max(1, min_row_h))))
end

--- The card's rows: its own Rows setting (1-6), else Auto: as many rows as
--- fit at `auto_row_h` (the main shelf's cover row, so a card looks like the
--- shelf it shows), else the old rule at `min_row_h`. The rows set the cover
--- size; the card's width then decides how many books a row holds.
local function cardRows(setting, avail_h, gap, auto_row_h, min_row_h)
    local n = tonumber(setting)
    if n then return math.max(1, math.min(6, math.floor(n))) end
    if auto_row_h and auto_row_h > 0 then
        local fit = math.floor(((avail_h or 0) + (gap or 0)) / (auto_row_h + (gap or 0)))
        return math.max(1, math.min(6, fit))
    end
    return rowsFor(avail_h, min_row_h or 100)
end

-- The main shelf's cover row height (cover plus the marks hanging above and
-- below it), or nil when the widget can't say.
local function shelfCoverRowH(bw)
    if not (bw and bw._currentSlotDims) then return nil end
    local ok, cw, ch = pcall(bw._currentSlotDims, bw)
    if not (ok and cw and ch) then return nil end
    local SpineWidget = require("lib/bookshelf_spine_widget")
    return ch + 2 * SpineWidget.badgeOverhang(cw)
end

-- The source to fetch a shelf's BOOKS from: a folder shelf's top level can be
-- all folders (Home on a fresh install is genre folders), and a card shows
-- books, so it takes the flattened twin -- every book under it, at any depth.
local function bookSource(source)
    if source.kind == "all" then return { kind = "library" } end
    if source.kind == "folder" then return { kind = "folder_flat", id = source.id } end
    return source
end

local function booksOnly(items)
    local out = {}
    for _i, it in ipairs(items or {}) do
        if type(it) == "table" and type(it.filepath) == "string" and it.kind ~= "folder" then
            out[#out + 1] = it
        end
    end
    return out
end

-- askForCovers(ctx, books, w, h): the shelf's own books have their covers
-- extracted by the shelf (BookshelfWidget:_kickOffMissingMetaExtraction,
-- after the paint, and a rebuild when they arrive); a book only this module
-- shows was never asked for, and stood as a title card until something else
-- (a tap putting it in the top panel) fetched its cover. w x h: the size
-- the module draws a cover at.
local function askForCovers(ctx, books, w, h)
    local bw = ctx and ctx.bw
    if ctx.preview or not (bw and bw._kickOffMissingMetaExtraction) or #books == 0 then return end
    pcall(bw._kickOffMissingMetaExtraction, bw, books, math.floor(w), math.floor(h))
end

local function tabFor(ctx)
    local id = ctx and ctx.config and ctx.config:get("tab_id")
    if not id then return nil end
    return require("lib/bookshelf_tab_model").getById(id)
end

-- previewTab(ctx) -> the shelf to show: the card's own, or, in the module
-- picker's preview before one is chosen, Home (else the first shelf of
-- books), so the preview shows what the module does instead of asking.
local function previewTab(ctx)
    local tab = tabFor(ctx)
    if tab or not (ctx and ctx.preview) then return tab end
    local TabModel = require("lib/bookshelf_tab_model")
    local home = TabModel.getById("all")
    if isBookShelf(home) then return home end
    for _i, t in ipairs(TabModel.load() or {}) do
        if isBookShelf(t) then return t end
    end
    return nil
end

-- A tap on a book opens it as a full screen shelf does (the tap-to-open
-- setting, the double tap, the cover-opening effect): lib/bookshelf_module_open.
local function tapKey(ctx, tab)
    return (ctx and ctx.entry and ctx.entry.id) or tab.id
end
local function bookTaps(ctx, tab)
    local Open, key = require("lib/bookshelf_module_open"), tapKey(ctx, tab)
    return function(book) Open.tap(ctx, key, book) end,
           function(book) Open.doubleTap(ctx, key, book) end,
           Open.staged(key, ctx)
end

-- Go to the shelf: close the full-screen view if it's open, then select it
-- (a sub-shelf selects its parent, the shelf it lives under).
-- ── The card's own shelf ────────────────────────────────────────────────────
-- A shelf made for this card (TabModel.newCardShelf): edited in the normal
-- shelf editor, shown here and nowhere on the main screen, removed with the
-- card (on_remove) or when the card is pointed at another shelf.

-- deleteCardShelf(id): remove a card's own shelf; never any other.
local function deleteCardShelf(id)
    local TabModel = require("lib/bookshelf_tab_model")
    local tabs = TabModel.load()
    for _i, t in ipairs(tabs) do
        if t.id == id then
            if not TabModel.isCardOnly(t) then return end
            TabModel.removeTree(tabs, id)
            TabModel.save(tabs)
            return
        end
    end
end

-- editCardShelf(ctx, id, opts): the shelf editor for this card's shelf. Each
-- change redraws the card (the reader is looking at it). opts.new: pick the
-- source first, and opts.on_discard if the reader backs out of a new one.
local function editCardShelf(ctx, id, opts)
    opts = opts or {}
    local function redraw()
        if ctx and ctx.menu and ctx.menu._reload then ctx.menu:_reload() end
    end
    require("lib/bookshelf_chip_editor"):editTab(id, {
        on_change = redraw,
        pick_source_first = opts.new or nil,
        on_discard = opts.on_discard,
    })
end

-- A cover narrower than this (dp) drops its badges, glyphs and progress bar.
local SMALL_COVER_W = 120
-- The row count Auto last chose, per shelf: a Rows nudge from Auto starts
-- there rather than at 1.
local auto_rows = {}

-- newCardShelf(ctx): make this card a shelf of its own and open its editor.
-- Backing out before choosing a source puts the card back as it was.
local function newCardShelf(ctx)
    local TabModel = require("lib/bookshelf_tab_model")
    local cfg = ctx.config
    local prev = cfg:get("tab_id")
    local tabs = TabModel.load()
    local nt = TabModel.newCardShelf(tabs)
    tabs[#tabs + 1] = nt
    TabModel.save(tabs)
    cfg:set("tab_id", nt.id)
    editCardShelf(ctx, nt.id, { new = true, on_discard = function()
        if prev then cfg:set("tab_id", prev) else cfg:delete("tab_id") end
    end })
end

local function openShelf(ctx, tab)
    -- A card's own shelf is not on the main screen: its heading opens its
    -- editor instead.
    if tab and require("lib/bookshelf_tab_model").isCardOnly(tab) then
        return editCardShelf(ctx, tab.id)
    end
    local bw = ctx and ctx.bw
    if not (bw and tab) then return end
    if bw._micro_fullscreen and bw._micro_fullscreen.onTapClose then
        bw._micro_fullscreen:onTapClose()
    end
    if bw._selectChip then bw:_selectChip(tab.parent or tab.id) end
end

-- shelfChoices(tabs, is_card_only) -> { { tab, text }, ... }: the shelves a
-- card can show, as the shelf menu has them: in its order, each sub-shelf
-- straight after its parent and named with it ("Shelf of shelves > Recently
-- read"), a hidden shelf marked. Listed flat by name, a sub-shelf (a Recent
-- shelf filtered to one folder) read as a second Recent with one book on it
-- (maintainer, PW5). Another card's own shelf belongs to that card.
local SEP = " \xE2\x80\xBA "
local function shelfChoices(tabs, is_card_only)
    local out, kids = {}, {}
    for _i, t in ipairs(tabs or {}) do
        if t.parent ~= nil then
            kids[t.parent] = kids[t.parent] or {}
            table.insert(kids[t.parent], t)
        end
    end
    local function walk(t, path, hidden)
        local name = plainLabel(t.label) or tostring(t.id)
        local full = path and (path .. SEP .. name) or name
        hidden = hidden or t.enabled == false
        if isBookShelf(t) and not (is_card_only and is_card_only(t)) then
            out[#out + 1] = { tab = t, text = hidden and T(_("%1 (hidden)"), full) or full }
        end
        for _i, c in ipairs(kids[t.id] or {}) do walk(c, full, hidden) end
    end
    for _i, t in ipairs(tabs or {}) do
        if t.parent == nil then walk(t, nil, false) end
    end
    return out
end

-- The shelves this card can show, as dialog rows; on_pick(tab).
local function shelfRows(close, on_pick)
    local rows = {}
    local TabModel = require("lib/bookshelf_tab_model")
    for _i, c in ipairs(shelfChoices(TabModel.load(), TabModel.isCardOnly)) do
        rows[#rows + 1] = {{ text = c.text, callback = close(function() on_pick(c.tab) end) }}
    end
    return rows
end

-- redrawCard(bw): show the module again after its shelf changed: in the
-- layout editor (where each module's picture is kept until it changes), the
-- editor's session; else the grid.
local function redrawCard(bw)
    local HeroModules = require("lib/bookshelf_hero_modules")
    local ed = bw and bw._module_editor
    if ed and ed.session then
        pcall(HeroModules._dropDimCache)
        ed.session:_render()
    elseif bw then
        HeroModules._rebuild(bw)
    end
end

-- addShelf(host_ctx, done): what a new Shelf module shows. A new shelf of
-- its own first -- making one was only in the module's settings after it had
-- been added -- then the shelves it can show. A new shelf goes to the shelf
-- editor at its source; the module is added once a source is picked, and
-- backing out of the editor before that adds nothing (the editor removes the
-- shelf). Later changes in the editor redraw the module.
local function addShelf(host_ctx, done)
    local UIManager    = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local TabModel     = require("lib/bookshelf_tab_model")
    local bw = host_ctx and host_ctx.bw
    local d
    local function close(fn) return function() UIManager:close(d); fn() end end
    local rows = {{ { text = _("Create new shelf\xE2\x80\xA6"), callback = close(function()
        local tabs = TabModel.load()
        local nt = TabModel.newCardShelf(tabs)
        tabs[#tabs + 1] = nt
        TabModel.save(tabs)
        local added = false
        require("lib/bookshelf_chip_editor"):editTab(nt.id, {
            pick_source_first = true,
            on_change = function(info)
                if info and info.source_changed and not added then
                    added = true
                    done({ tab_id = nt.id })
                elseif added then
                    redrawCard(bw)
                end
            end,
            on_discard = function() end,
        })
    end) } }}
    for _i, c in ipairs(shelfChoices(TabModel.load(), TabModel.isCardOnly)) do
        rows[#rows + 1] = {{ text = c.text, callback = close(function() done({ tab_id = c.tab.id }) end) }}
    end
    d = ButtonDialog:new{ title = _("Choose a shelf"), title_align = "center", width_factor = 0.7,
        buttons = rows }
    UIManager:show(d)
end

local function pickShelf(title, on_pick)
    local UIManager    = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local d
    local function close(fn) return function() UIManager:close(d); fn() end end
    d = ButtonDialog:new{ title = title, title_align = "center", width_factor = 0.7,
        buttons = shelfRows(close, on_pick) }
    UIManager:show(d)
end

local function showSettings(ctx)
    if not (ctx and ctx.config) then return end
    local UIManager    = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local cfg = ctx.config
    local dialog
    local function close(fn) return function() UIManager:close(dialog); if fn then fn() end end end
    local cur = tabFor(ctx)
    local own = cur and require("lib/bookshelf_tab_model").isCardOnly(cur) and cur or nil
    local function rowsText()
        local n = tonumber(cfg:get("rows"))
        return n and T(_("Rows: %1"), n) or _("Rows: Auto")
    end
    local function headingToggleText()
        return (cfg:get("heading", true) ~= false) and _("Hide heading") or _("Show heading")
    end
    -- Rewrite one button where it stands rather than reopening the dialog:
    -- a reopen flashes the whole screen on e-ink. The width passed back keeps
    -- the button's frame, so nothing moves under the finger.
    local function retext(id, text)
        local btn = dialog and dialog:getButtonById(id)
        if not btn then return end
        btn:setText(text, btn.width)
        UIManager:setDirty(dialog, function() return "ui", dialog.movable.dimen end)
    end
    -- Rows: Auto, 1 ... 6. The first nudge from Auto starts from the count
    -- on screen; below 1 is Auto again. The rows set the cover size.
    local function nudgeRows(delta)
        return function()
            local n = tonumber(cfg:get("rows"))
            if not n then
                local base = (cur and auto_rows[cur.id]) or 1
                cfg:set("rows", math.max(1, math.min(6, base + delta)))
            elseif n + delta < 1 then
                cfg:delete("rows")
            else
                cfg:set("rows", math.min(6, n + delta))
            end
            retext("rows", rowsText())
        end
    end
    dialog = ButtonDialog:new{
        title = _("Shelf"), title_align = "center", width_factor = 0.8,
        buttons = {
            -- Which shelf: a new one of the module's own, or one of the main
            -- screen's. Once it has its own, the first button edits that.
            {
                own and { text = _("Edit this shelf\xE2\x80\xA6"), callback = close(function()
                    editCardShelf(ctx, own.id)
                end) } or { text = _("Create new shelf\xE2\x80\xA6"), callback = close(function()
                    newCardShelf(ctx)
                end) },
                { text = _("Use existing shelf\xE2\x80\xA6"), callback = close(function()
                    pickShelf(_("Choose a shelf"), function(tab)
                        cfg:set("tab_id", tab.id)
                        -- The module's own shelf has no other use.
                        if own then deleteCardShelf(own.id) end
                    end)
                end) },
            },
            {
                { text = "\u{2212}", callback = nudgeRows(-1) },
                { id = "rows", text = rowsText(), enabled = false },
                { text = "+", callback = nudgeRows(1) },
            },
            {
                { text = _("Heading text\xE2\x80\xA6"), callback = close(function()
                    local InputDialog = require("ui/widget/inputdialog")
                    local input
                    input = InputDialog:new{
                        title = _("Heading"),
                        input = cfg:get("heading_text", "") or "",
                        input_hint = headingText(nil, tabFor(ctx)),
                        buttons = {{
                            { text = _("Cancel"), id = "close", callback = function() UIManager:close(input) end },
                            { text = _("Save"), is_enter_default = true, callback = function()
                                local v = input:getInputText()
                                UIManager:close(input)
                                cfg:set("heading_text", (v ~= "" and v) or nil)
                            end },
                        }},
                    }
                    UIManager:show(input)
                    input:onShowKeyboard()
                end) },
                { id = "heading", text = headingToggleText(), callback = function()
                    cfg:set("heading", cfg:get("heading", true) == false)
                    retext("heading", headingToggleText())
                end },
            },
        },
    }
    UIManager:show(dialog)
end

-- Covers: rows of them, as many per row as fit at the row's height.
local function coverBody(ctx, tab, w, h, gap)
    local Kit         = require("lib/bookshelf_module_kit")
    local Screen      = require("device").screen
    local SpineWidget = require("lib/bookshelf_spine_widget")
    local ShelfRow    = require("lib/bookshelf_shelf_row")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local Geom        = require("ui/geometry")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan  = require("ui/widget/verticalspan")
    local rows  = cardRows(ctx.config and ctx.config:get("rows"), h, gap,
        shelfCoverRowH(ctx.bw), Screen:scaleBySize(100))
    local row_h = math.floor((h - gap * (rows - 1)) / rows)
    auto_rows[tab.id] = rows
    local m     = SpineWidget.badgeOverhang(math.floor(row_h * 2 / 3))
    local cgap  = Screen:scaleBySize(10)
    local n     = Kit.coverFit(w, row_h, cgap, m)
    -- The cover as drawn: a row's height or its slot's width, whichever binds.
    local cover_w = math.min(math.floor(row_h * 2 / 3),
                             math.floor((w - (n - 1) * cgap) / math.max(1, n)))
    local small = cover_w < Screen:scaleBySize(SMALL_COVER_W)
    -- A slot's cover takes its height from the slot's WIDTH, so a row of
    -- few covers in a wide module gets slots no wider than the row's height
    -- allows -- or one cover across the whole width stands far taller than
    -- its row and spills out of the module. Centred in what is left.
    local row_w = math.min(w, n * math.floor((row_h - 2 * m) * 2 / 3) + (n - 1) * cgap)
    -- Full records, not light ones: a light record carries no cover, and
    -- every book came out as a plain title card. A screenful at most.
    local Repo  = require("lib/bookshelf_book_repository")
    local items = Repo.getBySource(bookSource(tab.source), tab.filter, tab.sort_priority, 0, rows * n * 2)
    local books = booksOnly(items)
    askForCovers(ctx, books, cover_w, cover_w * 3 / 2)
    local on_tap, on_open, staged = bookTaps(ctx, tab)
    local vg = VerticalGroup:new{ align = "left" }
    for r = 1, rows do
        local slice = {}
        for i = (r - 1) * n + 1, math.min(r * n, #books) do slice[#slice + 1] = books[i] end
        if #slice == 0 then break end
        if r > 1 then vg[#vg + 1] = VerticalSpan:new{ width = gap } end
        vg[#vg + 1] = VerticalSpan:new{ width = m }
        local row = ShelfRow.new{
            width = row_w, height = row_h - 2 * m, items = slice, n_slots = n, gap = cgap,
            on_book_tap = on_tap,
            on_book_open = on_open,
            selected_filepath = staged,
            label_mode = "none",
            -- Badges, glyphs and the progress bar crowd a small cover; below
            -- this they leave it alone.
            no_badges = small or nil,
        }
        if row_w < w then
            row = CenterContainer:new{ dimen = Geom:new{ w = w, h = row:getSize().h }, row }
        end
        vg[#vg + 1] = row
        vg[#vg + 1] = VerticalSpan:new{ width = m }
    end
    if #books == 0 then return nil end
    return vg
end

-- PlankScope: paints its child with the card shelf's own plank held (a
-- spine row also reads the plank while painting: the contact shade under a
-- cover darkens the design). Build is held separately (spineBody).
local PlankScope
local function plankScope(design, child)
    if design == nil then return child end
    if not PlankScope then
        local WidgetContainer = require("ui/widget/container/widgetcontainer")
        PlankScope = WidgetContainer:extend{}
        function PlankScope:paintTo(bb, x, y)
            local SpineShelf = require("lib/bookshelf_spine_shelf")
            SpineShelf.withPlank(self.design, function()
                WidgetContainer.paintTo(self, bb, x, y)
            end)
        end
    end
    return PlankScope:new{ design = design, dimen = child:getSize(), child }
end

-- The card shelf's own plank, or nil to stand on the main shelf's.
local function plankOf(tab)
    if tab.plank == nil then return nil end
    local ok, TP = pcall(require, "lib/bookshelf_theme_pack")
    if not (ok and TP and TP.plankForChoice) then return nil end
    return TP.plankForChoice(tab.plank)
end

-- Spines: standing on a plank, as many as the shelf's own spine sizes fit.
-- label: the heading, hung on the first row's plank the way the main shelf
-- labels a section, rather than set above the shelf.
local function spineBody(ctx, tab, w, h, gap, label)
    local Screen     = require("device").screen
    local Space      = require("lib/bookshelf_space")
    local SpineShelf = require("lib/bookshelf_spine_shelf")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan  = require("ui/widget/verticalspan")
    local rows  = cardRows(ctx.config and ctx.config:get("rows"), h, gap,
        nil, Screen:scaleBySize(130))
    local row_h = math.floor((h - gap * (rows - 1)) / rows)
    local Repo  = require("lib/bookshelf_book_repository")
    local items = Repo.getBySource(bookSource(tab.source), tab.filter, tab.sort_priority, 0, 40 * rows,
        { light_only = true })
    local books = booksOnly(items)
    if #books == 0 then return nil end
    -- A face-out cover stands about a row tall.
    askForCovers(ctx, books, row_h * 2 / 3, row_h)
    -- Its shelf's face-out choice, as the shelf itself plans with it ("all
    -- face out" showed mostly spines here without), and the books "recent N"
    -- counts from.
    local face_out = SpineShelf.faceOutFor(tab)
    local spec = SpineShelf.faceOutSpec(face_out)
    local opts = {
        content_w     = w - 2 * SpineShelf.endMargin(row_h),
        row_h         = row_h,
        face_out      = SpineShelf.faceOutFor(tab),
        face_recent_set = spec and spec.recent and SpineShelf.recentSetForItems(books, spec.recent) or nil,
        gap           = Space.px(SpineShelf.BOOK_GAP_DP),
        group_gap     = Space.px(SpineShelf.GROUP_GAP_DP),
        thickness_pct = tab.spine_thickness_pct,
        n_rows        = rows,
    }
    opts = require("lib/bookshelf_book_binding").applyOptions(opts, tab.id, nil)
    local design = plankOf(tab)
    local on_tap, on_open, staged = bookTaps(ctx, tab)
    local callbacks = { on_book_tap = on_tap, on_book_open = on_open }
    -- The plan and the rows read the plank (its drop and rise size them):
    -- built with this shelf's own held, and painted with it (plankScope).
    return SpineShelf.withPlank(design, function()
        local plan = SpineShelf.plan(books, opts)
        local vg = VerticalGroup:new{ align = "left" }
        for r = 1, rows do
            local row = plan.rows and plan.rows[r]
            if not row then break end
            if r > 1 then vg[#vg + 1] = VerticalSpan:new{ width = gap } end
            vg[#vg + 1] = SpineShelf.rowWidget{ plan = plan, row = row, width = w, height = row_h,
                gap = opts.gap, callbacks = callbacks, row_index = r,
                selected_filepath = staged,
                plank_label = (r == 1) and label or nil,
                -- Its plank stands on a card or on the main shelf, not on the
                -- page: the bevels cut back to what is behind.
                keep_ground = true,
                -- Its pieces are the module's, not the shelf's to pin.
                no_pin = true }
        end
        return plankScope(design, vg)
    end)
end

return {
    key   = "shelf",   -- stable id stored in user layouts; never change it
    title = _("Shelf"),
    summary = _("One of your shelves, in its own style. Works offline."),
    hero_only = true,
    bare = true,
    min_w = 2,

    render = function(ctx)
        local Kit = require("lib/bookshelf_module_kit")
        local mw  = math.max(50, ctx.width)
        local mh  = (ctx.height and ctx.height > 0) and ctx.height or math.floor(mw / 2)
        local tab = previewTab(ctx)
        if not (tab and isBookShelf(tab)) then
            return Kit.fitText{ text = _("Choose a shelf"), size = 15, scale_pct = ctx.scale,
                width = mw, fgcolor = Kit.COLOR_MUTED }
        end
        local Screen = require("device").screen
        local VerticalGroup = require("ui/widget/verticalgroup")
        local VerticalSpan  = require("ui/widget/verticalspan")
        local gap = Screen:scaleBySize(8)
        local out = VerticalGroup:new{ align = "left" }
        local body_h = mh
        local ViewMode = require("lib/bookshelf_view_mode")
        local spines = ViewMode.chipPin(tab.view_mode) == ViewMode.SPINES
        -- No heading in the module picker: its card is titled already, and
        -- a spine plank's label hung out of the preview's box.
        local show_heading = ctx.config:get("heading", true) ~= false and not ctx.preview
        if show_heading and not spines then
            local InputContainer = require("ui/widget/container/inputcontainer")
            local GestureRange   = require("ui/gesturerange")
            -- Drawn as the chip bar draws a label: text, icon glyphs and
            -- [icon=NAME] pictures, in the label's own case.
            local label = require("lib/bookshelf_chip_bar").buildLabel(
                headingText(ctx.config:get("heading_text"), tab),
                16, mw, Kit.COLOR_PRIMARY)   -- a font size: the face scales it
            local hd = InputContainer:new{ dimen = label:getSize(), label }
            hd.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = function() return hd.dimen end } } }
            function hd:onTap() openShelf(ctx, tab); return true end
            out[#out + 1] = hd
            out[#out + 1] = VerticalSpan:new{ width = gap }
            body_h = mh - label:getSize().h - gap
        end
        local body
        if spines then
            local label = show_heading and plainLabel(headingText(ctx.config:get("heading_text"), tab)) or nil
            body = spineBody(ctx, tab, mw, body_h, gap, label)
        else
            body = coverBody(ctx, tab, mw, body_h, gap)
        end
        if not body then
            local TextWidget = require("lib/bookshelf_colour_text")
            body = TextWidget:new{ text = _("No books on this shelf"),
                face = Kit.face(15, ctx.scale), fgcolor = Kit.COLOR_MUTED, max_width = mw }
        end
        out[#out + 1] = body
        return out
    end,

    -- Add flow: pick the shelf; cancelling aborts the add.
    on_add = function(host_ctx, done)
        addShelf(host_ctx, done)
    end,

    -- What the module's kept picture in the layout editor also depends on:
    -- its shelf (HeroModules._EditCell), which the module's entry does not
    -- change with.
    cache_key = function(entry)
        local tab = entry and entry.tab_id and require("lib/bookshelf_tab_model").getById(entry.tab_id)
        local ok, dump = pcall(require, "dump")
        return tab and ok and dump(tab) or ""
    end,

    show_settings = showSettings,

    -- The card is going: so is its own shelf (never one it only points at).
    on_remove = function(entry)
        if entry and entry.tab_id then deleteCardShelf(entry.tab_id) end
    end,
    _test = { isBookShelf = isBookShelf, headingText = headingText, rowsFor = rowsFor,
              cardRows = cardRows,
              booksOnly = booksOnly, plainLabel = plainLabel, bookSource = bookSource,
              shelfChoices = shelfChoices, previewTab = previewTab },
}
