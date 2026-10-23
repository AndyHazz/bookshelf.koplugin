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

-- count(fp) -> how many highlights the book has (0 without a sidecar).
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
        if type(a) == "table" and type(a.text) == "string" and a.text ~= "" then n = n + 1 end
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

-- buildList(fp, w, h) -> KOReader's own highlights list for the book, at
-- w x h for a tab, or nil when it can't be built (the caller then offers
-- showBrowser's button instead).
--
-- The bookmark browser's list is a stock Menu; only its show() makes it full
-- screen and puts it on the window stack. This does show()'s setup -- the
-- reader's bookmark-list settings (items per page, font size, lines, which
-- text, sorting, colours) -- then a Menu at the given size with no title bar,
-- and lets the browser fill it (getBookList, getItemTable through
-- updateBookmarkList) and handle a tap (showBookmarkDetails: KOReader's own
-- detail panel, with View in book and previous/next). It reads the browser's
-- internals, which a KOReader update may change: every step is guarded, and
-- any failure gives nil. Saved browser filters are not applied: the tab
-- shows the whole book.
function M.buildList(fp, w, h)
    if type(fp) ~= "string" or not (w and h) then return nil end
    local ok, list = pcall(function()
        local BB = require("ui/widget/bookmarkbrowser")
        local Menu = require("ui/widget/menu")
        local Blitbuffer = require("ffi/blitbuffer")
        local ReaderHighlight = require("apps/reader/modules/readerhighlight")
        local Screen = require("device").screen
        local ui = M.parentUI()
        if not ui then error("no file manager or reader to hang the list off") end
        BB.ui = ui
        ui.highlight = ui.highlight or ReaderHighlight -- for ReaderBookmark methods
        local G = G_reader_settings
        BB.items_per_page = G:readSetting("bookmarks_items_per_page")
            or G:readSetting("items_per_page") or Menu.items_per_page_default
        BB.items_font_size = G:readSetting("bookmarks_items_font_size")
            or G:readSetting("items_font_size") or Menu.getItemFontSize(BB.items_per_page)
        BB.items_text = G:readSetting("bookmarks_items_text_type") or "note"
        BB.items_max_lines = G:readSetting("bookmarks_items_max_lines")
        BB.multilines_show_more_text = G:isTrue("bookmarks_items_multilines_show_more_text")
        BB.line_color = G:isTrue("bookmarks_items_show_separator")
            and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_WHITE
        BB.sorting_mode = G:readSetting("bookmarks_items_sorting") or "page"
        BB.is_reverse_sorting = G:isTrue("bookmarks_items_reverse_sorting")
        BB.highlight_color_default = G:readSetting("highlight_color")
            or (Screen:isColorEnabled() and "yellow" or "gray")
        BB.bookmarks_items_show_color = G:isTrue("bookmarks_items_show_color")
        BB.bookmarks_items_color_default = G:isTrue("bookmarks_items_show_color_default")
            and ReaderHighlight:getHighlightColor(BB.highlight_color_default) or nil
        BB.books = BB:getBookList({ [fp] = true })
        if not BB.books or #BB.books == 0 then error("the browser found no annotations for the book") end
        BB.filter_table = { enabled_books_nb = #BB.books }
        BB.bm_list = Menu:new{
            width = w, height = h,
            no_title = true,
            is_borderless = true,
            is_popout = false,
            -- No Q/W/E... key hints down the side on a device with a keyboard:
            -- the tab is a list, not the browser's own screen.
            is_enable_shortcut = false,
            items_per_page = BB.items_per_page,
            items_font_size = BB.items_font_size,
            items_max_lines = BB.items_max_lines,
            multilines_show_more_text = BB.multilines_show_more_text,
            line_color = BB.line_color,
            onMenuSelect = function(_menu, item)
                -- The book's own row (the list's first) has nothing to show.
                if item and not item.file then BB:showBookmarkDetails(item) end
            end,
        }
        BB:updateBookmarkList()
        return BB.bm_list
    end)
    if ok and list then
        M._list = list
        return list
    end
    -- Why the tab fell back to its button, for a reporter's crash.log.
    pcall(function()
        require("logger").warn("[bookshelf] highlights list not built:", tostring(list))
    end)
    return nil
end

-- releaseList(): the tab is gone; the browser keeps no hold on its list (its
-- next show() starts afresh either way).
function M.releaseList()
    local ok, BB = pcall(require, "ui/widget/bookmarkbrowser")
    if ok and BB and M._list and BB.bm_list == M._list then
        BB.bm_list, BB.books, BB.filter_table = nil, nil, nil
    end
    M._list = nil
end

return M
