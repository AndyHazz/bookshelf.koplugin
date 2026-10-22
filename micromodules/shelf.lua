--[[
Micro-module: one of your shelves. Shows the books of a shelf (a tab, or a
sub-shelf) in that shelf's own style -- covers, or spines standing on a plank
-- with its source, filters and sort, as many as the cell holds. Edit the
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

local function booksOnly(items)
    local out = {}
    for _i, it in ipairs(items or {}) do
        if type(it) == "table" and type(it.filepath) == "string" and it.kind ~= "folder" then
            out[#out + 1] = it
        end
    end
    return out
end

local function tabFor(ctx)
    local id = ctx and ctx.config and ctx.config:get("tab_id")
    if not id then return nil end
    return require("lib/bookshelf_tab_model").getById(id)
end

local function openBook(ctx, book)
    if not (book and book.filepath) then return end
    local bw = ctx and ctx.bw
    if bw and bw._micro_fullscreen and bw._micro_fullscreen.onTapClose then
        bw._micro_fullscreen:onTapClose()
    end
    if bw and bw._openBook then
        bw:_openBook(book)
    else
        require("apps/reader/readerui"):showReader(book.filepath)
    end
end

-- Go to the shelf: close the full-screen view if it's open, then select it
-- (a sub-shelf selects its parent, the shelf it lives under).
local function openShelf(ctx, tab)
    local bw = ctx and ctx.bw
    if not (bw and tab) then return end
    if bw._micro_fullscreen and bw._micro_fullscreen.onTapClose then
        bw._micro_fullscreen:onTapClose()
    end
    if bw._selectChip then bw:_selectChip(tab.parent or tab.id) end
end

-- The shelves this card can show, as dialog rows; on_pick(tab).
local function shelfRows(close, on_pick)
    local rows = {}
    for _i, tab in ipairs(require("lib/bookshelf_tab_model").load() or {}) do
        if isBookShelf(tab) then
            rows[#rows + 1] = {{ text = plainLabel(tab.label) or tab.id,
                callback = close(function() on_pick(tab) end) }}
        end
    end
    return rows
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
    local shown = cfg:get("heading", true) ~= false
    dialog = ButtonDialog:new{
        title = _("Shelf"), title_align = "center", width_factor = 0.7,
        buttons = {
            {{ text = _("Change shelf\xE2\x80\xA6"), callback = close(function()
                pickShelf(_("Choose a shelf"), function(tab) cfg:set("tab_id", tab.id) end)
            end) }},
            {{ text = shown and _("Hide heading") or _("Show heading"), callback = close(function()
                cfg:set("heading", not shown)
            end) }},
            {{ text = _("Heading text\xE2\x80\xA6"), callback = close(function()
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
            end) }},
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
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan  = require("ui/widget/verticalspan")
    local rows  = rowsFor(h, Screen:scaleBySize(100))
    local row_h = math.floor((h - gap * (rows - 1)) / rows)
    local m     = SpineWidget.badgeOverhang(math.floor(row_h * 2 / 3))
    local cgap  = Screen:scaleBySize(10)
    local n     = Kit.coverFit(w, row_h, cgap, m)
    local Repo  = require("lib/bookshelf_book_repository")
    local items = Repo.getBySource(tab.source, tab.filter, tab.sort_priority, 0, rows * n * 2,
        { light_only = true })
    local books = booksOnly(items)
    local vg = VerticalGroup:new{ align = "left" }
    for r = 1, rows do
        local slice = {}
        for i = (r - 1) * n + 1, math.min(r * n, #books) do slice[#slice + 1] = books[i] end
        if #slice == 0 then break end
        if r > 1 then vg[#vg + 1] = VerticalSpan:new{ width = gap } end
        vg[#vg + 1] = VerticalSpan:new{ width = m }
        vg[#vg + 1] = ShelfRow.new{
            width = w, height = row_h - 2 * m, items = slice, n_slots = n, gap = cgap,
            on_book_tap = function(book) openBook(ctx, book) end,
            on_book_open = function(book) openBook(ctx, book) end,
            label_mode = "none",
        }
        vg[#vg + 1] = VerticalSpan:new{ width = m }
    end
    if #books == 0 then return nil end
    return vg
end

-- Spines: standing on a plank, as many as the shelf's own spine sizes fit.
local function spineBody(ctx, tab, w, h, gap)
    local Screen     = require("device").screen
    local Space      = require("lib/bookshelf_space")
    local SpineShelf = require("lib/bookshelf_spine_shelf")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan  = require("ui/widget/verticalspan")
    local rows  = rowsFor(h, Screen:scaleBySize(130))
    local row_h = math.floor((h - gap * (rows - 1)) / rows)
    local Repo  = require("lib/bookshelf_book_repository")
    local items = Repo.getBySource(tab.source, tab.filter, tab.sort_priority, 0, 40 * rows,
        { light_only = true })
    local books = booksOnly(items)
    if #books == 0 then return nil end
    local opts = {
        content_w     = w - 2 * SpineShelf.endMargin(row_h),
        row_h         = row_h,
        gap           = Space.px(SpineShelf.BOOK_GAP_DP),
        group_gap     = Space.px(SpineShelf.GROUP_GAP_DP),
        thickness_pct = tab.spine_thickness_pct,
        n_rows        = rows,
    }
    opts = require("lib/bookshelf_book_binding").applyOptions(opts, tab.id, nil)
    local plan = SpineShelf.plan(books, opts)
    local callbacks = {
        on_book_tap  = function(book) openBook(ctx, book) end,
        on_book_open = function(book) openBook(ctx, book) end,
    }
    local vg = VerticalGroup:new{ align = "left" }
    for r = 1, rows do
        local row = plan.rows and plan.rows[r]
        if not row then break end
        if r > 1 then vg[#vg + 1] = VerticalSpan:new{ width = gap } end
        vg[#vg + 1] = SpineShelf.rowWidget{ plan = plan, row = row, width = w, height = row_h,
            gap = opts.gap, callbacks = callbacks, row_index = r }
    end
    return vg
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
        local tab = tabFor(ctx)
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
        if ctx.config:get("heading", true) ~= false then
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
        local ViewMode = require("lib/bookshelf_view_mode")
        local body
        if ViewMode.chipPin(tab.view_mode) == ViewMode.SPINES then
            body = spineBody(ctx, tab, mw, body_h, gap)
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
    on_add = function(_host_ctx, done)
        pickShelf(_("Choose a shelf"), function(tab) done({ tab_id = tab.id }) end)
    end,

    show_settings = showSettings,
    _test = { isBookShelf = isBookShelf, headingText = headingText, rowsFor = rowsFor,
              booksOnly = booksOnly, plainLabel = plainLabel },
}
