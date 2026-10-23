--[[
bookshelf_book_highlights.lua -- a book's highlights, shown in KOReader's own
bookmark browser: how many there are (the book modal's Edit tab offers the
button only when there are some), and opening the browser on the book. The
quote module's "Show in bookmarks" tap opens it through here too.

Highlights are KOReader's annotations with text; page bookmarks carry none.
A legacy-only sidecar (no annotations array) counts none: the browser reads
only the modern array and would come up empty.
]]

local M = {}

-- count(fp) -> how many annotations the book has -- highlights, notes and
-- page bookmarks, as KOReader's list shows them (0 without a sidecar).
function M.count(fp)
    if type(fp) ~= "string" then return 0 end
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if not (ok_ds and DocSettings and DocSettings.hasSidecarFile) then return 0 end
    if not DocSettings:hasSidecarFile(fp) then return 0 end
    local ok, ds = pcall(DocSettings.open, DocSettings, fp)
    if not (ok and ds) then return 0 end
    local ok_a, annotations = pcall(ds.readSetting, ds, "annotations")
    if not (ok_a and type(annotations) == "table") then return 0 end
    local n = 0
    for _i, a in ipairs(annotations) do
        if type(a) == "table" then n = n + 1 end
    end
    return n
end

-- parentUI() -> the UI the browser hangs off: the file manager, or, when
-- the shelf is up over a book still open in the reader (no file manager
-- then), the reader -- KOReader opens the browser from both. nil with
-- neither, and the callers do nothing rather than hand it a nil parent.
function M.parentUI()
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    if ok_fm and FileManager and FileManager.instance then return FileManager.instance end
    local ok_r, ReaderUI = pcall(require, "apps/reader/readerui")
    if ok_r and ReaderUI and ReaderUI.instance then return ReaderUI.instance end
    return nil
end

-- showBrowser(fp) -> KOReader's BookmarkBrowser, open on this book, or nil.
-- The files list is a SET keyed by path: getBookList iterates
-- `for file in pairs(files)` and uses the key.
function M.showBrowser(fp)
    if type(fp) ~= "string" then return nil end
    local ok_bb, BookmarkBrowser = pcall(require, "ui/widget/bookmarkbrowser")
    if not (ok_bb and BookmarkBrowser) then return nil end
    local parent_ui = M.parentUI()
    if not parent_ui then return nil end
    BookmarkBrowser:show({ [fp] = true }, parent_ui)
    return BookmarkBrowser
end

-- ─── The book modal's Highlights tab ───────────────────────────────────────
-- Our own list rather than the bookmark browser's: that one is a paged Menu
-- whose page footer can't be turned off and which ignores the modal's font
-- size (maintainer: scroll it like the other tabs, at the modal's size).
-- Rows read like KOReader's -- its type glyphs, the text, the page -- and a
-- tap opens a panel in KOReader's own manner: the text in full, its note,
-- and View in book.

-- KOReader's own type glyphs (ReaderBookmark.display_prefix): a highlight,
-- a highlight with a note, a page bookmark.
M.PREFIX = { highlight = "\u{2592}\u{2002}", note = "\u{F040}\u{2002}",
             bookmark = "\u{F097}\u{2002}" }

-- list(fp) -> the book's annotations in book order, as KOReader's list has
-- them: { { type, text, note, chapter, page, pos0, pageno, datetime }, ... },
-- type "highlight", "note" (a highlight with a note) or "bookmark" (a page
-- bookmark). Typed as KOReader types them (ReaderBookmark.getBookmarkType):
-- by the highlight style, `drawer`, not by text -- a page bookmark in a
-- reflowed book carries text of its own ("in <chapter>").
function M.list(fp)
    local out = {}
    if type(fp) ~= "string" then return out end
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if not (ok_ds and DocSettings and DocSettings.hasSidecarFile) then return out end
    if not DocSettings:hasSidecarFile(fp) then return out end
    local ok, ds = pcall(DocSettings.open, DocSettings, fp)
    if not (ok and ds) then return out end
    local ok_a, annotations = pcall(ds.readSetting, ds, "annotations")
    if not (ok_a and type(annotations) == "table") then return out end
    local ok_s, SafeText = pcall(require, "lib/bookshelf_text_safe")
    local function safe(t) return (ok_s and SafeText and SafeText.safe) and SafeText.safe(t) or t end
    for _i, a in ipairs(annotations) do
        if type(a) == "table" then
            local text = (type(a.text) == "string" and a.text ~= "") and safe(a.text) or nil
            local note = (type(a.note) == "string" and a.note ~= "") and safe(a.note) or nil
            out[#out + 1] = {
                type     = (not a.drawer and "bookmark") or (note and "note") or "highlight",
                text     = text,
                note     = note,
                chapter  = (type(a.chapter) == "string" and a.chapter ~= "") and safe(a.chapter) or nil,
                page     = a.page,
                pos0     = a.pos0,
                pageno   = tonumber(a.pageno) or (type(a.page) == "number" and a.page) or nil,
                datetime = type(a.datetime) == "string" and a.datetime or nil,
                drawer   = a.drawer,
                color    = a.color,
            }
        end
    end
    return out
end

-- iconColour(h, colour_screen) -> the colour a row's type glyph is drawn
-- in: a highlight's own colour on a colour screen (maintainer: the colour on
-- the square, not behind the line), else nil (the text's ink). On a
-- greyscale screen a yellow square would only come out as a faint grey.
function M.iconColour(h, colour_screen)
    if not (colour_screen and h.drawer and h.type ~= "bookmark") then return nil end
    local ok, c = pcall(function()
        local ReaderHighlight = require("apps/reader/modules/readerhighlight")
        local name = h.color or G_reader_settings:readSetting("highlight_color") or "yellow"
        return ReaderHighlight:getHighlightColor(name)
    end)
    return ok and c or nil
end

-- openAt(bw, fp, h): open the book at a highlight. The reader opens first and
-- jumps once the document is ready (after_open_callback). A rolling book
-- navigates by xpointer: a legacy sidecar's numeric page falls back to pos0.
function M.openAt(bw, fp, h)
    if not (fp and h) then return end
    local function jump(ui)
        local target = h.page
        if ui.rolling and type(target) ~= "string" then
            target = type(h.pos0) == "string" and h.pos0 or nil
        elseif ui.paging and type(target) ~= "number" then
            target = nil
        end
        if not target then return end -- open without the jump
        pcall(function()
            ui.link:addCurrentLocationToStack()
            ui.bookmark:gotoBookmark(target, h.pos0)
        end)
    end
    if bw and bw._openBook then
        bw:_openBook({ filepath = fp }, jump)
    else
        require("apps/reader/readerui"):showReader(fp, nil, nil, nil, jump)
    end
end

-- rowText(h) -> what a row says: the highlighted text, or for a page
-- bookmark (no text) its chapter -- else nothing, as in KOReader's list: the
-- page number beside it says the rest.
function M.rowText(h)
    return h.text or h.chapter or ""
end

-- detailText(h, _) -> the panel's text: where it is, the highlight, its note.
function M.detailText(h, _)
    _ = _ or function(t) return t end
    local where = {}
    if h.chapter then where[#where + 1] = h.chapter end
    if h.pageno then where[#where + 1] = (_("Page %1"):gsub("%%1", tostring(h.pageno))) end
    if h.datetime then where[#where + 1] = h.datetime:match("^%d%d%d%d%-%d%d%-%d%d") or h.datetime end
    local parts = {}
    if #where > 0 then parts[#parts + 1] = table.concat(where, " \xC2\xB7 ") end
    parts[#parts + 1] = (M.PREFIX[h.type] or M.PREFIX.highlight) .. M.rowText(h)
    if h.note then parts[#parts + 1] = h.note end
    return table.concat(parts, "\n\n")
end

-- showDetail(bw, fp, h, modal): the panel a tapped row opens.
function M.showDetail(bw, fp, h, modal)
    local UIManager = require("ui/uimanager")
    local TextViewer = require("ui/widget/textviewer")
    local _ = require("lib/bookshelf_i18n").gettext
    local tv
    tv = TextViewer:new{
        title = h.type == "bookmark" and _("Bookmark") or _("Highlight"),
        text = M.detailText(h, _),
        add_default_buttons = false,
        buttons_table = { {
            { text = _("View in book"), callback = function()
                UIManager:close(tv)
                if modal then UIManager:close(modal) end
                M.openAt(bw, fp, h)
            end },
            { text = _("Close"), callback = function() UIManager:close(tv) end },
        } },
    }
    UIManager:show(tv)
end

-- buildTab(bw, fp, modal, w, h) -> the tab's body: a row per highlight in a
-- scroll view, at the modal's font size; nil when there are none.
function M.buildTab(bw, fp, modal, avail_w, avail_h)
    local list = M.list(fp)
    if #list == 0 then return nil end
    local Blitbuffer      = require("ffi/blitbuffer")
    local Font            = require("ui/font")
    local Geom            = require("ui/geometry")
    local Screen          = require("device").screen
    local TextBoxWidget   = require("ui/widget/textboxwidget")
    local TextWidget      = require("lib/bookshelf_colour_text")
    local VerticalGroup   = require("ui/widget/verticalgroup")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan  = require("ui/widget/horizontalspan")
    local VerticalSpan    = require("ui/widget/verticalspan")
    local LineWidget      = require("ui/widget/linewidget")
    local FrameContainer  = require("ui/widget/container/framecontainer")
    local InputContainer  = require("ui/widget/container/inputcontainer")
    local GestureRange    = require("ui/gesturerange")
    local SnugScroll      = require("lib/bookshelf_snug_scroll")
    local Space           = require("lib/bookshelf_space")
    local font_size = (modal and modal.font_size) or 20
    local face  = Font:getFace("cfont", font_size)
    local small = Font:getFace("cfont", math.max(12, math.floor(font_size * 0.8 + 0.5)))
    local lpad  = (modal and modal._side_pad) or Space.px(20)
    local bar_w = SnugScroll.widen(Screen:scaleBySize(3))
    local inner_w = avail_w - 2 * lpad - bar_w
    local gap = Space.px(12)
    local muted = Blitbuffer.COLOR_DARK_GRAY
    local _ = require("lib/bookshelf_i18n").gettext
    -- At most `lines` lines, ending in an ellipsis when it runs over; a
    -- shorter text keeps its own height.
    local function clamped(text, f, w, lines, fg)
        local tb = TextBoxWidget:new{ text = text, face = f, width = w, fgcolor = fg }
        local max_h = lines * (tb.line_height_px or f.size)
        if tb:getSize().h <= max_h then return tb end
        tb:free()
        return TextBoxWidget:new{ text = text, face = f, width = w, fgcolor = fg,
            height = max_h, height_overflow_show_ellipsis = true }
    end
    local colour_screen = Screen.isColorEnabled and Screen:isColorEnabled() or false
    local vg = VerticalGroup:new{ align = "left" }
    for i, h in ipairs(list) do
        local page = h.pageno and TextWidget:new{ text = tostring(h.pageno), face = small, fgcolor = muted }
        -- The type glyph in a column of its own, so it can take the
        -- highlight's colour and the text wraps under the text.
        local icon = TextWidget:new{ text = M.PREFIX[h.type] or M.PREFIX.highlight, face = face,
            fgcolor = M.iconColour(h, colour_screen) }
        local text_w = inner_w - icon:getSize().w - (page and (page:getSize().w + gap) or 0)
        local body = VerticalGroup:new{ align = "left",
            clamped(M.rowText(h), face, text_w, 4),
        }
        if h.note then
            body[#body + 1] = VerticalSpan:new{ width = Space.px(4) }
            body[#body + 1] = clamped(h.note, small, text_w, 2, muted)
        end
        local line = HorizontalGroup:new{ align = "top", icon, body }
        if page then
            line[#line + 1] = HorizontalSpan:new{ width = gap }
            line[#line + 1] = page
        end
        local row = FrameContainer:new{
            bordersize = 0, margin = 0,
            padding_left = lpad, padding_right = lpad,
            padding_top = Space.px(10), padding_bottom = Space.px(10),
            line,
        }
        local tap = InputContainer:new{ dimen = Geom:new{ w = avail_w - bar_w, h = row:getSize().h }, row }
        tap.ges_events = { Tap = { GestureRange:new{ ges = "tap",
            range = function() return tap.dimen end } } }
        function tap:onTap()
            M.showDetail(bw, fp, h, modal)
            return true
        end
        vg[#vg + 1] = tap
        if i < #list then
            vg[#vg + 1] = LineWidget:new{ background = Blitbuffer.COLOR_LIGHT_GRAY,
                dimen = Geom:new{ w = avail_w - bar_w, h = Screen:scaleBySize(1) } }
        end
    end
    return SnugScroll:new{
        dimen = Geom:new{ w = avail_w, h = avail_h },
        scroll_bar_width = bar_w,
        show_parent = modal,
        vg,
    }
end

return M
