-- bookshelf_widget_book_popup.lua
-- The shelf's book popup: its header (cover, title, pills), the Edit, Cover
-- and Reviews tabs, the description, and the rating and review setters they
-- call.
--
-- These are BookshelfWidget's own methods, kept in a file of their own (as
-- lib/bookshelf_widget_opds.lua is). The module returns an installer:
-- lib/bookshelf_widget.lua calls it once with the class, and every method
-- below is defined on that class exactly as if it were written there (`self`
-- is the shelf widget). The bodies sit at the left margin for that reason.
local InputContainer  = require("ui/widget/container/inputcontainer")
local BookshelfSettings = require("lib/bookshelf_settings_store")
local TextSegments    = require("lib/bookshelf_text_segments")
local FrameContainer  = require("ui/widget/container/framecontainer")
local VerticalGroup   = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local CenterContainer = require("ui/widget/container/centercontainer")
local TextWidget      = require("lib/bookshelf_colour_text")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local Size            = require("ui/size")
local Space           = require("lib/bookshelf_space")
local Font            = require("ui/font")
local BFont           = require("lib/bookshelf_fonts")
local UIManager       = require("ui/uimanager")
local Blitbuffer      = require("ffi/blitbuffer")
local Device          = require("device")
local Screen          = Device.screen
local _               = require("lib/bookshelf_i18n").gettext
local Repo            = require("lib/bookshelf_book_repository")
local logger          = require("logger")
local T               = require("ffi/util").template
local PopupKit        = require("lib/bookshelf_popup_kit")

return function(BookshelfWidget)

-- _buildBookMenuHeader(book) -- header widget for the long-press menu,
-- shown above the action buttons via ButtonDialog:addWidget(). Replaces
-- the plain text title with a cover thumbnail (when available) next to
-- a stacked title / author / series text block. Falls back to text-only
-- when there's no cover_bb (BIM unavailable, file just imported, etc).
--
-- The cover_bb is sourced from a fresh Repo.buildBookMeta() call so it's
-- a one-time-use bb -- ImageWidget frees it after first paint, which
-- means the bb in `book` itself (potentially shared with other UI) is
-- never touched. Same disposable-bb invariant as the hero card.
-- Pick the book-detail header's thumbnail, and say WHO OWNS IT.
--
-- Returns (bb, disposable). `disposable = true` means the caller owns the bb
-- and is responsible for freeing it exactly once; `false` means some cache
-- owns it, and freeing it would corrupt every later paint of that cover.
-- Getting that pair wrong is silent until a cover turns to garbage, which is
-- why the choice lives in one named place instead of inline in the header.
--
-- Sources, in cost order:
--   1. external cover (Hardcover / user-picked)  -- ImageSource cache owns it
--   2. fresh.cover_bb                            -- one-shot, caller owns it
--   3. the scaled-cover cache                    -- the cache owns it
--   4. a fresh decode                            -- caller owns it
--
-- 3 exists because buildBookMeta asks BIM for the cover blob only when the
-- scaled-cover cache does NOT already hold the book. That skip is deliberate
-- (the shelf renders from that cache anyway), but it is true for every book
-- currently on screen -- which is every book this header can be opened from --
-- so source 2 is normally nil and without 3/4 the header lost its thumbnail
-- entirely.
--
-- 3 is guarded on width: a narrower cached bb would have to be UPSCALED, and
-- MuPDF upscale corrupts on Kindle.
local function _headerThumbBB(filepath, fresh, thumb_w)
    local ext_cover = fresh and fresh.cover_image_path
    if ext_cover then
        -- The header-sized copy, kept on disk (lib/bookshelf_derived_cache):
        -- an external cover is a full-size picture, and decoding it was ~40%
        -- of opening the book popup on the PW5, every session. A fresh bb,
        -- so the caller owns it (true).
        local Derived = require("lib/bookshelf_derived_cache")
        local stamp = thumb_w and Derived.stamp(ext_cover)
        local key = stamp and ("hthumb:" .. thumb_w .. "|" .. stamp)
        local kept = key and Derived.bb(key)
        if kept then return kept, true end
        local ok_img, ImageSource = pcall(require, "lib/bookshelf_image_source")
        local bb = ok_img and ImageSource.loadImageNative(ext_cover) or nil
        if bb then
            local sw = key and bb.getWidth and bb:getWidth() or 0
            local sh = key and bb.getHeight and bb:getHeight() or 0
            if key and sw > thumb_w and sh > 0 then
                local th = math.max(1, math.floor(thumb_w * sh / sw + 0.5))
                local ok_s, small = pcall(function()
                    return require("ui/renderimage"):scaleBlitBuffer(bb, thumb_w, th)
                end)
                if ok_s and small then
                    Derived.putBB(key, small)
                    return small, true
                end
            end
            return bb, false
        end
    end
    if fresh and fresh.cover_bb then return fresh.cover_bb, true end
    if not filepath then return nil end
    local ok_scc, SCC = pcall(require, "lib/bookshelf_scaled_cover_cache")
    local cached = ok_scc and SCC and SCC.get and SCC:get(filepath) or nil
    local cw = cached and (cached.w or (cached.getWidth and cached:getWidth()))
    if cached and cw and thumb_w and cw >= thumb_w then return cached, false end
    local ok_bb, bb = pcall(Repo.getCoverBB, filepath)
    if ok_bb and bb then return bb, true end
    return nil
end

-- _headerCardBook(book, fresh) -> the record the book menu's cover card draws.
-- A plain spine's page record is light: it carries no has_cover, and the card
-- reads that as "no cover" and draws the text placeholder (575). The menu's
-- own full record answers it; the shelf's record keeps everything else, and
-- is copied rather than changed.
function BookshelfWidget._headerCardBook(book, fresh)
    if book.has_cover ~= nil or type(fresh) ~= "table" or fresh == book then
        return book
    end
    local b = {}
    for k, v in pairs(book) do b[k] = v end
    b.has_cover = fresh.has_cover
    if b.cover_image_path == nil then b.cover_image_path = fresh.cover_image_path end
    return b
end

function BookshelfWidget:_buildBookMenuHeader(book, override_width, pill_specs, bookmark_action, opts)
    if not book or not book.filepath then return nil end
    -- rich = the book-detail popup's header: +2pt detail fonts, a page count,
    -- "Last read" wording, and the folder path with the filename. The long-press
    -- menu (opts nil) keeps the compact original.
    local rich = opts and opts.rich or false
    -- band: the book menu's header ground (bookshelf_reviews_modal), which
    -- the text boxes paint behind their text, as they would white.
    local band = opts and opts.band or nil
    local Font           = require("ui/font")
    local ImageWidget    = require("ui/widget/imagewidget")
    local HorizontalGroup_   = require("ui/widget/horizontalgroup")
    local HorizontalSpan_    = require("ui/widget/horizontalspan")
    local VerticalGroup_     = require("ui/widget/verticalgroup")
    local VerticalSpan_      = require("ui/widget/verticalspan")
    local TextBoxWidget_     = require("ui/widget/textboxwidget")
    local TextWidget_        = require("lib/bookshelf_colour_text")

    -- Caller can pass override_width (e.g. the collection manager, which
    -- nests inside the book menu and needs a narrower header).
    -- Match the dialog's added-widget width (= the button-table width) so
    -- the header fills exactly the button area -- neither narrower (margins
    -- around the cover) nor wider (margins around the buttons, which would
    -- grow the whole dialog). The book menu passes that width as
    -- override_width; the fallback mirrors ButtonDialog's own default width
    -- so a no-override caller still fits.
    local header_w = override_width
        or math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.9)
    -- Cover thumbnail is the visual anchor of the header; size it large
    -- enough that the title block on a real cover is legible, but not
    -- so large the menu starts to dominate the screen. Height is
    -- derived from the actual cover aspect once we've fetched the bb
    -- (a few lines down) so the FrameContainer matches the painted
    -- image exactly -- no horizontal or vertical letterboxing.
    -- The popup's (rich) cover follows the screen's size, not the UI scale;
    -- the compact header keeps its scaled size.
    local thumb_w  = rich and math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.15)
        or Screen:scaleBySize(110)
    local thumb_h  = math.floor(thumb_w * 1.5)  -- default 2:3 if no cover
    -- Cover<->text gap = the shelf's inter-column book gap, so the menu
    -- matches the main grid. The header's outer inset is supplied by the
    -- DIALOG's title_padding (the book menu sets it to this same gap), so we
    -- add NO frame inset here -- stacking a frame inset on the dialog's own
    -- padding was the doubling.
    local gap_w    = self:_bookGap(math.min(
        math.floor(Space.padding.fullscreen * 2 * 0.8),
        math.floor(Screen:getWidth() * 0.03)))

    -- Rebuild the book record so we get an independent cover_bb that
    -- ImageWidget can own + free (cover_bb is one-shot per the
    -- feedback_image_disposable_shared_book memory; reusing the bb on
    -- `book` here would tear out from under whoever painted last).
    -- Wrap the ImageWidget in a thin FrameContainer so the cover has a
    -- 1dp border; without it pale covers (white sky, light typography)
    -- bleed straight into the dialog's white background and the
    -- thumbnail loses its rectangular shape.
    -- The rich header's card draws its cover from the cover cache: no cover
    -- decoded here for it (one per popup), only if the card fails (below).
    local fresh = Repo.buildBookMeta(book.filepath, rich and { want_cover = false } or nil) or book
    local thumb_widget

    -- Which bb, and who owns it: see _headerThumbBB. External and cached
    -- covers come back non-disposable and must NOT reach owned_cover_bb below.
    -- A tap on the cover opens it full screen. The embedded bb is one-shot, so
    -- this reloads the cover for ImageViewer. The external cover comes from
    -- ImageSource's cache, so the viewer must NOT free it.
    local fp = book.filepath
    -- The external cover _headerThumbBB loads first. (This read a local
    -- of that helper, out of scope here, so the tap never found it.)
    local ext_for_viewer = fresh and fresh.cover_image_path
    local title_for_viewer = book.title or book.filename or ""
    local function previewCover()
        if ext_for_viewer then
            local ok_img, ImageSource = pcall(require, "lib/bookshelf_image_source")
            -- Native load: ImageViewer fits it to the screen preserving
            -- aspect. A fixed w*h resize here stretched the cover.
            local pv_bb = ok_img and ImageSource.loadImageNative(ext_for_viewer) or nil
            if pv_bb then
                UIManager:show(require("ui/widget/imageviewer"):new{
                    image            = pv_bb,
                    image_disposable = false,  -- ImageSource cache owns it
                    title_text       = title_for_viewer,
                    fullscreen       = true,
                })
                return
            end
        end
        -- Embedded cover: load the FULL-resolution cover straight from the
        -- document, exactly like KOReader's native Book information > Cover
        -- image (filemanagerbookinfo:getCoverImage, which also picks up a
        -- DocSettings custom cover). The BIM cover_bb used as the fallback
        -- below is a grid-sized THUMBNAIL -- feeding it to ImageViewer
        -- upscales blurry, even at "original size" (#228). Guarded with a
        -- pcall + the thumbnail fallback so an older build still shows
        -- something.
        local ok_bi, BookInfo = pcall(require, "apps/filemanager/filemanagerbookinfo")
        if ok_bi and BookInfo and BookInfo.getCoverImage then
            local ok_bb, full_bb = pcall(function()
                return BookInfo:getCoverImage(nil, fp, false)
            end)
            if ok_bb and full_bb then
                UIManager:show(require("ui/widget/imageviewer"):new{
                    image            = full_bb,
                    image_disposable = true,  -- getCoverPageImage bb is ours
                    title_text       = title_for_viewer,
                    fullscreen       = true,
                })
                return
            end
        end
        local preview = Repo.buildBookMeta(fp)
        if not preview or not preview.cover_bb then return end
        UIManager:show(require("ui/widget/imageviewer"):new{
            image            = preview.cover_bb,
            image_disposable = true,
            title_text       = title_for_viewer,
            fullscreen       = true,
        })
    end

    -- What is handed back for the modal to free: usually nothing (the popup's
    -- cover is the shelf's own card, below, which keeps its scaled bb in the
    -- cover cache, and the compact header's bb is ImageWidget's to free). The
    -- modal keeps the rich header for its life and paints it again, so a
    -- one-shot bb there (the card failed to build) is not ImageWidget's to
    -- free after a paint: the modal frees it as it closes.
    local owned_cover_bb

    if rich then
        -- The popup draws the cover the way the shelf does (SpineWidget:
        -- corners, border and shadow as the reader set them), as the hero
        -- does, rather than a square-bordered thumbnail. Its width follows
        -- the screen, not the UI scale, so a large scale setting no longer
        -- grows the header and pushes the actions below it out of view
        -- (issues 442, 553). A 2:3 card, like the shelf's.
        local ok_sw, SpineWidget = pcall(require, "lib/bookshelf_spine_widget")
        if ok_sw and SpineWidget then
            local ok_card, card = pcall(function()
                return SpineWidget:new{
                    book   = BookshelfWidget._headerCardBook(book, fresh),
                    width  = thumb_w,
                    height = thumb_h,
                    on_tap = function() previewCover() end,
                    suppress_favorite_badge = true,
                }
            end)
            if ok_card then thumb_widget = card end
        end
    end

    local thumb_bb, thumb_disposable
    if not thumb_widget then
        if rich then fresh = Repo.buildBookMeta(book.filepath) or fresh end
        thumb_bb, thumb_disposable = _headerThumbBB(book.filepath, fresh, thumb_w)
        if rich and thumb_disposable then
            owned_cover_bb, thumb_disposable = thumb_bb, false
        end
    end
    if thumb_bb then
        -- Resize the container to the cover's true aspect ratio so the
        -- image fills the frame with no letterboxing. The bb is a
        -- blitbuffer with .w/.h fields; falling back to 2:3 if either
        -- is missing keeps the layout sane for malformed covers.
        local bw = thumb_bb.w or (thumb_bb.getWidth and thumb_bb:getWidth())
        local bh = thumb_bb.h or (thumb_bb.getHeight and thumb_bb:getHeight())
        if bw and bh and bw > 0 then
            thumb_h = math.floor(thumb_w * (bh / bw))
        end
        local thumb_frame = FrameContainer:new{
            bordersize = Size.border.thin,
            padding    = 0,
            margin     = 0,
            ImageWidget:new{
                image            = thumb_bb,
                image_disposable = thumb_disposable,
                width            = thumb_w,
                height           = thumb_h,
                scale_factor     = 0,
            },
        }
        thumb_widget = InputContainer:new{
            dimen = Geom:new{
                w = thumb_w + 2 * Size.border.thin,
                h = thumb_h + 2 * Size.border.thin,
            },
            thumb_frame,
        }
        thumb_widget.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = thumb_widget.dimen } },
        }
        thumb_widget.onTap = function()
            previewCover()
            return true
        end
    end

    -- Bookmark link (#67): "N bookmark(s) ›" in the header's top-right
    -- corner, opening KOReader's bookmark browser. A text link rather than
    -- a bare icon -- clearer, and the count says what's there. Built only
    -- when bookmark_action is passed (book has annotations + browser
    -- available). Reserve its width off the text column so a long title
    -- doesn't run under it.
    local bm_link, bm_reserve = nil, 0
    if bookmark_action then
        local n = bookmark_action.count
        local bm_text = n == 1 and _("1 bookmark") or T(_("%1 bookmarks"), n)
        local bm_face, bm_bold = BFont:getFace("cfont", 16, { bold = true })
        -- The chevron is a real glyph (U+E841 mdi-chevron-right) from the
        -- symbols/nerdfont face -- NOT an ASCII ">" -- so it's its own widget:
        -- the count label's cfont doesn't carry that PUA codepoint.
        local bm_row = HorizontalGroup_:new{
            align = "center",
            TextWidget_:new{ text = bm_text, face = bm_face, bold = bm_bold },
            HorizontalSpan_:new{ width = Space.padding.small },
            TextWidget_:new{ text = "\xEE\xA1\x81", face = BFont:getFace("symbols", 20) },
        }
        local bm_frame = FrameContainer:new{
            bordersize = 0,
            margin     = 0,
            padding    = 0,
            bm_row,
        }
        local bm_sz = bm_frame:getSize()
        bm_link = InputContainer:new{
            dimen = Geom:new{ w = bm_sz.w, h = bm_sz.h },
            bm_frame,
        }
        bm_link.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = bm_link.dimen } },
        }
        bm_link.onTap = function() bookmark_action.on_tap(); return true end
        bm_reserve = bm_sz.w + Space.padding.default
    end
    -- No frame inset: header_w (the dialog's added-widget width) is already
    -- inset from the button rows by the dialog's title_padding. The content
    -- fills it edge to edge; only the TITLE row reserves space for the
    -- bookmark link (below), overlaying the title's right-hand whitespace.
    -- The thumbnail's REAL width: its 1dp frame adds 2 * Size.border.thin to
    -- thumb_w, and leaving that out made the header that much wider than
    -- asked -- widening the whole book popup, so every tab stopped short of
    -- its right border and a tab's scrollbar floated off it (4px at 480dpi).
    local thumb_real_w = thumb_widget and thumb_widget:getSize().w or 0
    local text_w = thumb_widget and (header_w - thumb_real_w - gap_w) or header_w

    -- Top of text column: title (bold) + author + one-line metadata
    -- strip (format · size · added · last opened) + filename. Series
    -- info is no longer rendered here -- it lives as a tappable pill
    -- in the nav strip below.
    local top_stack = VerticalGroup_:new{ align = "left" }
    local mtitle_face, mtitle_bold = BFont:getFace("smalltfont", rich and 26 or 22, { bold = true })
    top_stack[#top_stack + 1] = TextBoxWidget_:new{
            bgcolor = band,
        text  = book.title or book.filename or _("(no title)"),
        face  = mtitle_face,
        bold  = mtitle_bold,
        -- Title wraps before the top-right bookmark link (bm_reserve = 0
        -- when there's no link, so this is the full width otherwise).
        width = text_w - bm_reserve,
    }
    if book.author and book.author ~= "" then
        local mauthor_face, mauthor_bold = BFont:getFace("cfont", rich and 22 or 18)
        top_stack[#top_stack + 1] = TextBoxWidget_:new{
            bgcolor = band,
            text  = book.author,
            face  = mauthor_face,
            bold  = mauthor_bold,
            width = text_w,
        }
    end

    -- Metadata + filename block: cheap-to-fetch supporting detail in a
    -- compact bottom slice of the top stack. Each chunk skipped when
    -- its source is unavailable.
    local meta_face, meta_bold = BFont:getFace("cfont", rich and 18 or 14)
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    local size_bytes, mtime
    if ok_lfs and lfs and lfs.attributes then
        -- One stat for both fields: attributes(path) returns the full
        -- record, so asking twice with mode strings doubles the syscall.
        local attr = lfs.attributes(book.filepath)
        if attr then
            size_bytes = attr.size
            mtime      = attr.modification
        end
    end
    local function _fmt_size(bytes)
        if not bytes or bytes <= 0 then return nil end
        if bytes < 1024              then return string.format("%d B", bytes) end
        if bytes < 1024 * 1024       then return string.format("%d KB", math.floor(bytes / 1024 + 0.5)) end
        return string.format("%.1f MB", bytes / 1024 / 1024)
    end
    local function _fmt_short_date(ts)
        if not ts or ts <= 0 then return nil end
        return os.date("%d %b %Y", ts)
    end
    -- ReadHistory lookup for "last opened" timestamp -- KOReader's
    -- canonical source for "when did the user last touch this book"
    -- (Repo.readProgress returns rating + status but not last_opened).
    local function _last_opened(fp)
        local ok_rh, rh = pcall(require, "readhistory")
        if not (ok_rh and rh and rh.hist) then return nil end
        for _i, item in ipairs(rh.hist) do
            if item.file == fp then return item.time end
        end
        return nil
    end
    -- A small leading glyph from the symbols (nerdfont) face. The glyph is
    -- centred within ONE text-line's height (FA icons sit centred in a tall em
    -- box, so a raw top-align drops them below the text's cap line); the row is
    -- top-aligned, so a wrapping value keeps the glyph beside the first line.
    local CenterContainer_ = require("ui/widget/container/centercontainer")
    local function _icon_row(glyph, text, one_line)
        local icon = TextWidget_:new{ text = glyph,
            face = BFont:getFace("symbols", 15) }
        -- CenterContainer below centers on the glyph's full reported em-box,
        -- but this Nerd Font's calendar/file glyphs still sit visibly lower
        -- within that box than meta_face's own ink does within its box (measured
        -- ~4px low on a PW5) -- nudge the paint position up to compensate.
        -- getSize() is untouched, so the gap/width math below (which reads it)
        -- doesn't shift.
        local icon_nudge_up = Screen:scaleBySize(2)
        local orig_icon_paintTo = icon.paintTo
        function icon:paintTo(bb, x, y)
            orig_icon_paintTo(self, bb, x, y - icon_nudge_up)
        end
        local gap    = Space.px(6)
        local line_h = TextWidget_:new{ text = "Ag", face = meta_face }:getSize().h
        local icon_box = CenterContainer_:new{
            dimen = Geom:new{ w = icon:getSize().w, h = line_h },
            icon,
        }
        local avail = text_w - icon:getSize().w - gap
        local txt
        if one_line then
            -- One line, its start cut away rather than wrapped: a long path
            -- took three lines and squeezed the tabs below (maintainer).
            local function fits(t)
                local w = TextWidget_:new{ text = t, face = meta_face, bold = meta_bold }
                local ok = w:getSize().w <= avail
                w:free()
                return ok
            end
            txt = TextWidget_:new{
                text  = require("lib/bookshelf_text_fit").pathOneLine(text, fits),
                face  = meta_face,
                bold  = meta_bold,
                max_width = avail,
            }
        else
            txt = TextBoxWidget_:new{
                bgcolor = band,
                text  = text,
                face  = meta_face,
                bold  = meta_bold,
                width = avail,
            }
        end
        return HorizontalGroup_:new{ align = "top",
            icon_box, HorizontalSpan_:new{ width = gap }, txt }
    end

    local added_str = _fmt_short_date(mtime)
    local last_str  = _fmt_short_date(_last_opened(book.filepath))

    -- Format · size · pages. In the compact header the dates ride along on this
    -- same row (the original one-line strip). The rich popup header leads with
    -- where the reader is in the book instead, then the file's details.
    local meta_parts = {}
    if book.format then meta_parts[#meta_parts + 1] = book.format end
    local size_str = _fmt_size(size_bytes)
    if size_str then meta_parts[#meta_parts + 1] = size_str end
    if rich then
        local pages = tonumber(book.page_count)  -- nil for un-rendered EPUBs
        if pages and pages > 0 then
            meta_parts[#meta_parts + 1] = T(_("%1 pages"), pages)
        end
        if added_str then meta_parts[#meta_parts + 1] = _("Added") .. " " .. added_str end
    else
        if added_str then meta_parts[#meta_parts + 1] = _("Added") .. " " .. added_str end
        if last_str  then meta_parts[#meta_parts + 1] = _("Read") .. " " .. last_str end
    end

    -- Reading line (rich popup header only): the status, how far in, and when
    -- it was last read -- what the shelf's own badges and the hero say about
    -- the book, and what a reader looks for first. A slim bar below it while
    -- the book is under way.
    local reading_pct
    if rich then
        local ok_bl, BookList = pcall(require, "ui/widget/booklist")
        local status = ok_bl and BookList and BookList.getBookStatus
            and BookList.getBookStatus(book.filepath) or nil
        local pct, _st, _rating, page_count, page_num = Repo.readProgress(book.filepath)
        pct = tonumber(pct)
        local parts = {}
        if status == "complete" then
            parts[#parts + 1] = _("Finished")
        elseif status == "abandoned" then
            parts[#parts + 1] = _("On hold")
            if pct and pct > 0 then parts[#parts + 1] = T(_("%1% read"), math.floor(pct * 100 + 0.5)) end
            reading_pct = pct
        elseif pct and pct > 0 then
            parts[#parts + 1] = T(_("%1% read"), math.floor(pct * 100 + 0.5))
            page_num, page_count = tonumber(page_num), tonumber(page_count)
            if page_num and page_count and page_count > 0 then
                parts[#parts + 1] = T(_("page %1 of %2"), page_num, page_count)
            end
            reading_pct = pct
        elseif last_str and status ~= "new" then
            -- Opened, no progress yet: "Unopened" beside a last-read date
            -- said two things at once.
            parts[#parts + 1] = _("Not started")
        else
            parts[#parts + 1] = _("Unopened")
        end
        if last_str and status ~= "new" then
            parts[#parts + 1] = T(_("Last read %1"), last_str)
        end
        local rface, rbold = BFont:getFace("cfont", 20, { bold = true })
        top_stack[#top_stack + 1] = VerticalSpan_:new{ width = Space.px(6) }
        top_stack[#top_stack + 1] = TextBoxWidget_:new{
            bgcolor = band,
            text  = table.concat(parts, "  \xC2\xB7  "),  -- middle-dot
            face  = rface,
            bold  = rbold,
            width = text_w,
        }
        if reading_pct then
            local ProgressWidget = require("ui/widget/progresswidget")
            top_stack[#top_stack + 1] = VerticalSpan_:new{ width = Space.px(6) }
            top_stack[#top_stack + 1] = ProgressWidget:new{
                width      = math.floor(text_w * 0.6),
                height     = Space.px(8),
                percentage = math.max(0, math.min(1, reading_pct)),
                margin_h   = 0, margin_v = 0,
                radius     = 0,
                bordersize = Size.border.thin,
                bordercolor = Blitbuffer.COLOR_BLACK,
                fillcolor  = Blitbuffer.COLOR_BLACK,
                ticks      = nil,
            }
            top_stack[#top_stack + 1] = VerticalSpan_:new{ width = Space.px(4) }
        end
    end

    if #meta_parts > 0 then
        top_stack[#top_stack + 1] = TextBoxWidget_:new{
            bgcolor = band,
            text  = table.concat(meta_parts, "  \xC2\xB7  "),  -- middle-dot
            face  = meta_face,
            bold  = meta_bold,
            fgcolor = rich and (band and require("lib/bookshelf_popup_kit").DIM_ON_GREY or Blitbuffer.COLOR_DARK_GRAY) or nil,
            width = text_w,
        }
    end

    -- Filename. The compact (long-press menu) header shows the basename only --
    -- the directory is reachable via the Folder pill. The rich (book-detail
    -- popup) header includes the folder path (relative to home_dir when under
    -- it, else the full path) and a leading file glyph.
    local fname = (book.filepath or ""):match("([^/]+)$") or book.filepath or ""
    if rich and book.filepath then
        local shown = book.filepath
        local ok_gs, gs = pcall(function() return G_reader_settings end)
        local home = ok_gs and gs and require("lib/bookshelf_home_dir").get()
        if type(home) == "string" then
            home = home:gsub("/+$", "")
            if home ~= "" and shown:sub(1, #home + 1) == home .. "/" then
                shown = shown:sub(#home + 2)  -- strip "home_dir/"
            end
        end
        fname = shown
    end
    if rich then
        top_stack[#top_stack + 1] = _icon_row("\xEF\x80\x96", fname, true)  -- U+F016 file
    else
        top_stack[#top_stack + 1] = TextBoxWidget_:new{
            bgcolor = band,
            text  = fname,
            face  = meta_face,
            bold  = meta_bold,
            width = text_w,
        }
    end

    -- Bottom-aligned pill strip: tappable nav facets (series, author,
    -- collections, genres, folder, rating). Each pill is a small
    -- bordered rounded rectangle, packed into rows that wrap to
    -- text_w. Pill text is rendered UPPERCASED (small-caps style) --
    -- KOReader's TextWidget has no small-caps font variant, so the
    -- uppercase fallback is the convention. TextSegments.upper is
    -- UTF-8-aware (Lua's :upper() leaves accented letters untouched,
    -- so "videojáték" would render "VIDEOJáTéK" -- issue #130).
    -- Padding is symmetric on
    -- both axes for a balanced look. Built only when the caller passes
    -- pill_specs -- the collection-manager call site for instance
    -- passes nil because it doesn't want nav-into-self affordances.
    local pill_group = VerticalGroup_:new{ align = "left" }
    if pill_specs and #pill_specs > 0 then
        local pill_face, pill_bold = BFont:getFace("cfont", 13, { bold = true })
        local pill_pad_h  = Space.padding.default  -- L/R inner padding
        local pill_pad_v  = Space.padding.small    -- T/B inner padding
        local pill_gap    = Space.padding.default  -- between pills
        local MAX_PILL_ROWS = 2  -- bounds the header height when the
                                 -- caller pours dozens of pills at us;
                                 -- the overflow collapses into a single
                                 -- "+N" pill so the visible row count
                                 -- never grows past this cap.

        -- #177: cap a single pill's label so a very long tag truncates
        -- (one line, ellipsis) inside text_w instead of spilling off-screen.
        local pill_label_max = math.max(1, text_w - 2 * pill_pad_h - 2 * Size.border.thin)

        -- Build all pill widgets first so we know their widths up
        -- front (the packing pass needs them to greedily wrap).
        -- extra_pad widens a pill's L/R padding (and so its tap target) without
        -- touching the others -- used for the small "+N" overflow pill.
        local function _buildPill(label_text, on_tap_cb, extra_pad)
            local label_w = TextWidget_:new{
                text = TextSegments.upper(label_text or ""),
                face = pill_face,
                bold = pill_bold,
                max_width = pill_label_max,
            }
            -- Explicit white bg so the tap-feedback inversion has
            -- something to flip to black. Matches the hero pill builder.
            local frame = FrameContainer:new{
                bordersize     = Size.border.thin,
                background     = Blitbuffer.COLOR_WHITE,
                radius         = Space.radius.button,
                padding_left   = pill_pad_h + (extra_pad or 0),
                padding_right  = pill_pad_h + (extra_pad or 0),
                padding_top    = pill_pad_v,
                padding_bottom = pill_pad_v,
                margin         = 0,
                label_w,
            }
            local frame_size = frame:getSize()
            local pill = InputContainer:new{
                dimen = Geom:new{ w = frame_size.w, h = frame_size.h },
                frame,
            }
            pill.ges_events = {
                Tap = { GestureRange:new{ ges = "tap", range = pill.dimen } },
            }
            pill.onTap = function()
                -- Same instant-feedback pattern as the hero pill builder
                -- (BookshelfWidget:_buildPillGroup): invert, repaint into
                -- the fb, force a refresh-queue drain, then run the
                -- callback. Without the forceRePaint the highlight only
                -- queues and the callback's rebuild wipes it before any
                -- pixels reach the panel.
                if on_tap_cb and frame and frame.dimen then
                    frame.background = frame.background:invert()
                    label_w.fgcolor  = label_w.fgcolor:invert()
                    UIManager:widgetRepaint(frame, frame.dimen.x, frame.dimen.y)
                    UIManager:setDirty(nil, "ui", frame.dimen)
                    UIManager:forceRePaint()
                    on_tap_cb()
                elseif on_tap_cb then
                    on_tap_cb()
                end
                return true
            end
            return pill, frame_size.w
        end

        local pill_widgets = {}
        for _i, spec in ipairs(pill_specs) do
            local on_tap = spec.on_tap  -- per-iteration capture
            local pill, pw = _buildPill(spec.label, on_tap)
            pill_widgets[#pill_widgets + 1] = { widget = pill, w = pw }
        end

        -- Pack pills into rows (greedy, width-bounded). Stop once we
        -- hit MAX_PILL_ROWS; anything left becomes a "+N" pill that
        -- gets squeezed into the last row, dropping trailing pills if
        -- it doesn't fit.
        local rows = {}                 -- array of { pill_entries }
        local cur_row = {}
        local cur_w   = 0
        local stopped_at = nil          -- index of first pill that
                                        -- didn't fit (nil if all fit)
        for i, p in ipairs(pill_widgets) do
            local need = (cur_w == 0) and p.w or (cur_w + pill_gap + p.w)
            if need > text_w and cur_w > 0 then
                rows[#rows + 1] = cur_row
                if #rows >= MAX_PILL_ROWS then
                    stopped_at = i
                    cur_row = {}
                    cur_w   = 0
                    break
                end
                cur_row = {}
                cur_w   = 0
            end
            cur_row[#cur_row + 1] = p
            cur_w = (#cur_row == 1) and p.w or (cur_w + pill_gap + p.w)
        end
        if #cur_row > 0 and #rows < MAX_PILL_ROWS then
            rows[#rows + 1] = cur_row
            cur_row = nil
        end

        -- If we stopped early, append a "+N" pill. Tapping it opens the combined
        -- book-detail popup (every facet, still tappable, above the description).
        -- All "+N" widgets here share one callback.
        if stopped_at then
            local more_cb = function() self:_showBookDetail(book, { active = "tags" }) end
            local more_extra = Screen:scaleBySize(8)
            local hidden = #pill_widgets - stopped_at + 1
            local more_pill, more_w = _buildPill("+" .. hidden, more_cb, more_extra)
            -- Squeeze into the last row, evicting trailing pills if
            -- needed to make room.
            local last_row = rows[#rows]
            local last_w = 0
            for j, p in ipairs(last_row) do
                last_w = last_w + ((j == 1) and p.w or (pill_gap + p.w))
            end
            while #last_row > 0
                and (last_w + pill_gap + more_w) > text_w do
                local dropped = table.remove(last_row)
                hidden = hidden + 1
                last_w = last_w - dropped.w
                if #last_row > 0 then last_w = last_w - pill_gap end
                more_pill, more_w = _buildPill("+" .. hidden, more_cb, more_extra)
            end
            last_row[#last_row + 1] = { widget = more_pill, w = more_w }
        end

        -- Render rows into pill_group with vertical gaps between.
        for ri, row_pills in ipairs(rows) do
            local row_widget = HorizontalGroup_:new{ align = "center" }
            for j, p in ipairs(row_pills) do
                if j > 1 then
                    row_widget[#row_widget + 1] = HorizontalSpan_:new{
                        width = pill_gap,
                    }
                end
                row_widget[#row_widget + 1] = p.widget
            end
            if ri > 1 then
                pill_group[#pill_group + 1] = VerticalSpan_:new{
                    width = pill_gap,
                }
            end
            pill_group[#pill_group + 1] = row_widget
        end
    end

    -- Compose the text column so the top block anchors at the top of
    -- the thumbnail and the filepath block anchors at the bottom.
    -- VerticalSpan with the leftover height grows in the middle so
    -- total column height matches the thumbnail. Without the explicit
    -- flex span, the column would compress to its natural height and
    -- the filepath would sit immediately under the title block.
    local top_h     = top_stack:getSize().h
    local fp_h      = pill_group:getSize().h
    -- Minimum vertical gap between the filename line and the pill
    -- strip, so the pills don't crowd the metadata when the cover is
    -- tall enough to let flex_h collapse to zero. Only enforced when
    -- pills exist; pill-less headers (collection manager's manage
    -- mode etc.) don't pay the gap.
    local has_pills = pill_specs and #pill_specs > 0
    local min_gap   = has_pills and Space.padding.large or 0
    local target_h  = thumb_widget and thumb_h or (top_h + min_gap + fp_h)
    local flex_h    = math.max(min_gap, target_h - top_h - fp_h)
    local text_stack = VerticalGroup_:new{
        align = "left",
        top_stack,
        VerticalSpan_:new{ width = flex_h },
        pill_group,
    }

    local body
    if thumb_widget then
        -- text_stack now spans the cover's full height (top block of
        -- title/author/series, flex span, filepath at the bottom), so
        -- top-align is correct -- the column tops line up, the
        -- filepath sits flush with the cover's bottom edge.
        body = HorizontalGroup_:new{
            align = "top",
            thumb_widget,
            HorizontalSpan_:new{ width = gap_w },
            text_stack,
        }
    else
        body = text_stack
    end
    -- Vertical padding matches the existing horizontal frame padding so
    -- the cover doesn't sit flush against the dialog's top / bottom
    -- edges. ButtonDialog's title_group already contributes ~5dp of
    -- info_padding all around; this FrameContainer adds Size.padding.large
    -- on top + bottom so the cover gets a balanced visual frame
    -- (matching the left gap from dialog edge to cover).
    local header_frame = FrameContainer:new{
        bordersize = 0,
        margin     = 0,
        padding    = 0,
        body,
    }
    local result = header_frame
    if bm_link then
        -- Overlay the bookmark link in the top-right corner. RightContainer
        -- right-aligns it to the header width; the height-bounded dimen keeps
        -- it in the top band, and the link's own padding_top aligns it with
        -- the title. Same corner-anchoring idiom the hero card uses.
        local RightContainer = require("ui/widget/container/rightcontainer")
        local OverlapGroup   = require("ui/widget/overlapgroup")
        local hsize = header_frame:getSize()
        result = OverlapGroup:new{
            dimen = Geom:new{ w = hsize.w, h = hsize.h },
            header_frame,
            RightContainer:new{
                dimen = Geom:new{ w = hsize.w, h = bm_link:getSize().h },
                bm_link,
            },
        }
    end
    -- Expose the persistent cover bb (rich header only) so the caller frees it
    -- once the cached header is discarded.
    result._owned_cover_bb = owned_cover_bb
    -- Expose the cover thumb frame (stamps its painted dimen) so the detail
    -- popup can flex it open as tap feedback on its Open button.
    result._cover_thumb = thumb_widget and thumb_widget[1] or nil
    return result
end

-- _buildPillSpecs(book, collection_set, close_cb) -> { { label, on_tap }, ... }
--
-- Shared pill-strip data builder used by the book menu AND the
-- Collection Manager. The two contexts disagree on which collections
-- to show:
--   - Book menu: actual saved membership (ReadCollection:getCollectionsWithFile)
--   - Collection Manager: DRAFT membership (toggles in flight, not yet saved)
-- so the caller passes whichever set is appropriate as a {name = true}
-- table.
--
-- close_cb is invoked AFTER each pill's drill action so the parent
-- dialog dismisses on tap. Tappable pills include: author, series,
-- collections, deduped genres, and folder.
function BookshelfWidget:_buildPillSpecs(book, collection_set, close_cb, filter)
    if not book then return {} end
    local bw   = self
    -- #99: optional per-category filter for the hero tags line. nil shows
    -- every category (the long-press book menu's pill strip passes nil, so
    -- it is unaffected). A category is hidden only when filter sets it
    -- explicitly false.
    local function _show(cat)
        return (filter == nil) or (filter[cat] ~= false)
    end
    local ReadCollection = require("readcollection")
    local default_coll_name = ReadCollection.default_collection_name
    local function _wrap(drill_fn)
        return function()
            drill_fn()
            if close_cb then close_cb() end
        end
    end
    local function _navResetAndClose()
        bw._drilldown_path = {}
    end

    local pill_specs = {}

    -- 1. Author(s): one pill per co-author (book.authors, KOReader's own
    -- one-per-<dc:creator>-line split), not just book.author (= authors[1]),
    -- so a multi-author book doesn't silently lose every name but the
    -- first. Falls back to the single book.author field for older/simpler
    -- records that never populated the authors array. Display respects the
    -- "Author name formatting" setting so each pill matches the form used
    -- elsewhere (hero, Authors chip). Drilldown still keys on the RAW name
    -- so the lookup matches the group regardless of the display form.
    if _show("author") then
        local names = (type(book.authors) == "table" and #book.authors > 0)
            and book.authors
            or (book.author and book.author ~= "" and { book.author } or nil)
        if names then
            local fmt = BookshelfSettings.read("author_format") or "auto"
            local AuthorName
            if fmt ~= "auto" then
                local ok_a, mod = pcall(require, "lib/bookshelf_author_name")
                if ok_a then AuthorName = mod end
            end
            for _i = 1, #names do
                local author_name = names[_i]
                local display_author = author_name
                if AuthorName and AuthorName.formatted then
                    display_author = AuthorName.formatted(author_name, fmt)
                end
                pill_specs[#pill_specs + 1] = {
                    cat    = "author",
                    label  = display_author,
                    on_tap = _wrap(function()
                        local group = Repo.findGroup("author", author_name)
                        if not group then
                            group = { kind = "author", series_name = author_name,
                                      books = { book }, latest = 0 }
                        end
                        _navResetAndClose()
                        -- `whole`: the pill asks for all of it, not the
                        -- shelf's filtered slice (GitHub issue 480).
                        bw:_expandAuthor(group, true)
                    end),
                }
            end
        end
    end

    -- 2. Series -- appends " #N" when book.series_num is set so the
    -- pill reads "[Southern Reach #2]" rather than the bare series
    -- name. Tapping still drills into the series view; the number is
    -- decoration on the pill itself.
    if _show("series") and book.series_name and book.series_name ~= "" then
        local series_name  = book.series_name
        local series_label = series_name
        if book.series_num then
            series_label = series_label .. " #" .. tostring(book.series_num)
        end
        pill_specs[#pill_specs + 1] = {
            cat    = "series",
            label  = series_label,
            on_tap = _wrap(function()
                local group = Repo.findGroup("series", series_name)
                if not group then
                    group = { kind = "series", series_name = series_name,
                              books = { book }, latest = 0 }
                end
                _navResetAndClose()
                bw:_expandSeries(group, true)
            end),
        }
    end

    -- 3. Collections (one pill per, sorted by name for stable order).
    -- The built-in "favorites" collection is intentionally excluded here:
    -- favourites has its own dedicated ★ button + cover badge, so a pill
    -- for it would be a duplicate UI affordance for the same toggle.
    -- Favourites is kept in the pill strip even though it has a dedicated
    -- ★ toggle button: the pill's role is NAVIGATION (tap to jump to the
    -- full favourites view), distinct from the button's TOGGLE role.
    local coll_names = {}
    for n, v in pairs(collection_set or {}) do
        if v then coll_names[#coll_names + 1] = n end
    end
    table.sort(coll_names, function(a, b) return a:lower() < b:lower() end)
    for _i, coll_name in ipairs(_show("collections") and coll_names or {}) do
        local display = (coll_name == default_coll_name) and _("Favorites") or coll_name
        pill_specs[#pill_specs + 1] = {
            cat    = "collections",
            label  = display,
            coll   = coll_name,
            on_tap = _wrap(function()
                local rc = require("readcollection")
                local coll = rc.coll and rc.coll[coll_name]
                local books = {}
                if type(coll) == "table" then
                    for _file, item in pairs(coll) do
                        local fp = item.file or _file
                        if type(fp) == "string" then
                            books[#books + 1] = { filepath = fp }
                        end
                    end
                end
                _navResetAndClose()
                bw:_expandTag({ kind = "tag", series_name = coll_name,
                                books = books, latest = 0 }, true)
            end),
        }
    end

    -- 4. Genres -- deduped against series name and collections so the
    -- same string doesn't render twice.
    if _show("genres") and book.genres and #book.genres > 0 then
        local _seen = {}
        -- Only dedup against categories that are actually on screen: if
        -- series / collections are hidden, a genre that happens to match one
        -- isn't a visible duplicate, so let it show.
        if _show("series") and book.series_name and book.series_name ~= "" then
            _seen[book.series_name:lower()] = true
        end
        for _i, coll_name in ipairs(_show("collections") and coll_names or {}) do
            _seen[coll_name:lower()] = true
            -- Localised display too -- "Favourites" UI label could collide
            -- with a same-named genre.
            local display = (coll_name == default_coll_name) and _("Favorites") or coll_name
            _seen[display:lower()] = true
        end
        for _i, genre_name in ipairs(book.genres) do
            local key = (genre_name or ""):lower()
            if key ~= "" and not _seen[key] then
                _seen[key] = true
                pill_specs[#pill_specs + 1] = {
                    cat    = "genres",
                    label  = genre_name,
                    on_tap = _wrap(function()
                        local group = Repo.findGroup("genre", genre_name)
                        if not group then
                            group = { kind = "genre", series_name = genre_name,
                                      books = { book }, latest = 0 }
                        end
                        _navResetAndClose()
                        bw:_expandGenre(group, true)
                    end),
                }
            end
        end
    end

    -- 5. Folder (skip when book sits at home_dir's top level).
    local parent_dir = book.filepath and book.filepath:match("^(.*)/[^/]+$")
    local home_dir
    do
        local ok_gs, gs = pcall(function() return G_reader_settings end)
        if ok_gs and gs then
            home_dir = require("lib/bookshelf_home_dir").get()
            if type(home_dir) == "string" then
                home_dir = home_dir:gsub("/+$", "")
            end
        end
    end
    if _show("folder") and parent_dir and parent_dir ~= "" and parent_dir ~= home_dir then
        local folder_label = parent_dir:match("([^/]+)$") or parent_dir
        pill_specs[#pill_specs + 1] = {
            cat    = "folder",
            label  = folder_label,
            on_tap = _wrap(function()
                _navResetAndClose()
                bw:_expandFolder({ path = parent_dir, label = folder_label })
            end),
        }
    end

    return pill_specs
end

-- A section heading in the book popup's tabs: small uppercase text in dark
-- grey. It was a solid black bar, the heaviest thing on the screen, so the
-- headings outweighed the buttons they name; then a hairline, which ran to the
-- frame edges past controls that stop at the inset and so ended nowhere (book
-- popup redesign). Space now does the grouping. action (optional): a button
-- right-aligned in the heading row, which is row_w wide (default content_w
-- less the insets).
function BookshelfWidget:_sectionHeadingBar(text, content_w, font_size, inset)
    local FrameContainer = require("ui/widget/container/framecontainer")
    local TextWidget     = require("lib/bookshelf_colour_text")
    local face, bold = BFont:getFace("cfont", math.max(10, (font_size or 18) - 4), { bold = true })
    local label = TextWidget:new{ text = TextSegments.upper(text), face = face, bold = bold,
        fgcolor = Blitbuffer.COLOR_DARK_GRAY }
    local pad_top, pad_bottom = Space.px(22), Space.px(10)
    local widget = label
    return FrameContainer:new{
        bordersize  = 0, margin = 0,
        padding_left = inset, padding_right = inset,
        padding_top = pad_top, padding_bottom = pad_bottom,
        widget,
    }
end

-- _segmentedChips(items, active_key, on_pick, font_size, inset) -- a source
-- switch: the popup's rounded segmented control (lib/bookshelf_popup_kit) at
-- the source size, matching the Description and Reviews tabs' switches.
-- items = { {key=, label=}, ... }. Tapping an inactive cell fires
-- on_pick(key). Left-inset to align with the body text. Second return value:
-- the cells as one dpad row (see _buildPillGroup's focus_rows).
function BookshelfWidget:_segmentedChips(items, active_key, on_pick, font_size, inset)
    local FrameContainer = require("ui/widget/container/framecontainer")
    local seg, focus_rows = PopupKit.segmented{
        items = items, active = active_key, on_pick = on_pick,
        face = PopupKit.sourceFace(font_size), pad_v = PopupKit.SOURCE_PAD_V,
    }
    return FrameContainer:new{
        bordersize = 0, margin = 0,
        padding_left = inset, padding_right = inset,
        padding_top = 0, padding_bottom = Space.px(12),
        seg,
    }, focus_rows
end

-- _buildPillGroup(pill_specs, available_w, max_rows)
-- Render the same tappable pill strip used in the long-press book menu
-- as a self-contained widget that callers can drop into any layout.
-- Greedy width-bounded packing, capped at max_rows; overflow collapses
-- into a non-tappable "+N" pill. Returns a VerticalGroup (possibly
-- empty if pill_specs is empty / nil), plus a second return value:
-- focus_rows, the same row-wrapped pills (widgets only, left-to-right)
-- for callers that want dpad focus support -- see _buildPill's
-- onFocus/onUnfocus and FocusManager:mergeLayoutInVertical. Pure widget
-- builder — no state on self other than what the spec callbacks capture.
--
-- ink (optional): the strip is going over a painted ground (the dark
-- theme's page, or a wallpaper), so the pills carry no fill of their own
-- and draw border, label and underline in this colour. nil keeps the stock
-- white-filled pill for the popups, which sit on their own white panel.
-- The hero's column used to get this for free from a stencil over the
-- whole column, which turned a white fill into nothing and black into the
-- ink; the pills now say so themselves.
--
-- border (optional): the pill outline, Size.border.thin by default; the book
-- popup's Tags tab passes its button border so pills match its other controls.
function BookshelfWidget:_buildPillGroup(pill_specs, available_w, max_rows, base_size, align, gap, on_overflow, ink, border)
    local Font            = require("ui/font")
    local TextWidget_     = require("lib/bookshelf_colour_text")
    local FrameContainer_ = require("ui/widget/container/framecontainer")
    local HorizontalGroup_ = require("ui/widget/horizontalgroup")
    local HorizontalSpan_  = require("ui/widget/horizontalspan")
    local VerticalGroup_   = require("ui/widget/verticalgroup")
    local VerticalSpan_    = require("ui/widget/verticalspan")
    local InputContainer_  = require("ui/widget/container/inputcontainer")
    local GestureRange_    = require("ui/gesturerange")

    max_rows = max_rows or 2
    -- align controls horizontal placement of the pill block (#99). Rows
    -- align within the block; the block is then aligned within available_w
    -- by the wrapper at the end.
    local row_align = (align == "center" or align == "right") and align or "left"
    local pill_group = VerticalGroup_:new{ align = row_align }
    if not pill_specs or #pill_specs == 0 then return pill_group, {} end

    local pill_face, pill_bold = BFont:getFace("cfont", base_size or 14, { bold = true })
    -- A bit more than Size.padding.default: at default gave the label so
    -- little breathing room against the border it read as cramped.
    local pill_pad_h = Space.px(8)
    local pill_pad_v = Space.padding.small
    -- gap (optional) overrides the inter-pill / inter-row spacing; the tags
    -- sheet passes a larger value since it has room, while the space-tight
    -- hero/menu strips keep the default.
    local pill_gap   = gap or Space.padding.default
    -- #177: a single tag longer than the row would otherwise render at full
    -- natural width and spill off the screen edge (the packer only rejects a
    -- pill that isn't first in its row). Cap the label so one pill never exceeds
    -- available_w; TextWidget truncates with an ellipsis on one line (no wrap).
    local pill_border = border or Size.border.thin
    local pill_label_max = math.max(1, available_w - 2 * pill_pad_h - 2 * pill_border)

    -- extra_pad widens a pill's L/R padding (and so its tap target) without
    -- touching the others -- used to make the small "+N" overflow pill easier
    -- to hit. link_style renders an action (e.g. "Edit…") inline with the
    -- data pills but styled as a link -- no border, underlined label --
    -- so it reads as an action rather than another tag.
    -- trailing (optional) is a glyph after the label, inside the pill (the
    -- Tags tab's edit mode puts a remove cross there).
    local function _buildPill(label_text, on_tap_cb, extra_pad, on_hold_cb, link_style, trailing)
        local trail_w, trail_gap
        if trailing then
            trail_w = TextWidget_:new{ text = trailing, face = pill_face, bold = pill_bold,
                fgcolor = ink }
            trail_gap = Space.px(10)
        end
        -- Upper-case label: centre its capitals, not its line box
        -- (lib/bookshelf_cap_centre), as the shelf chips do.
        local label_w = require("lib/bookshelf_cap_centre").centre(TextWidget_:new{
            text = TextSegments.upper(label_text or ""),
            face = pill_face,
            bold = pill_bold,
            fgcolor = ink,  -- nil: TextWidget's own black
            max_width = math.max(1, pill_label_max
                - (trail_w and (trail_w:getSize().w + trail_gap) or 0)),
        })
        local content = label_w
        if trail_w then
            content = HorizontalGroup_:new{ align = "center",
                label_w, HorizontalSpan_:new{ width = trail_gap }, trail_w }
        end
        -- Explicit white bg so the tap-feedback inversion has something to
        -- invert to black (without this, the frame's transparent fill
        -- can't be flipped). Matches KOReader's Button feedback pattern.
        -- Over a ground there is deliberately NO fill, so what is behind
        -- the pill shows through; the tap feedback fills with the ink then.
        -- The border in the picked ink on every colour screen (Color.colourBorder).
        local frame = require("lib/bookshelf_color").colourBorder(FrameContainer_:new{
            bordersize     = link_style and 0 or pill_border,
            background     = (not ink) and Blitbuffer.COLOR_WHITE or nil,
            color          = ink,  -- nil: FrameContainer's own black
            radius         = Space.radius.button,
            padding_left   = pill_pad_h + (extra_pad or 0),
            padding_right  = pill_pad_h + (extra_pad or 0),
            padding_top    = pill_pad_v,
            padding_bottom = pill_pad_v,
            margin         = 0,
            content,
        })
        local frame_size = frame:getSize()
        -- link_style paints the underline as an overlay inside the frame's
        -- own bottom padding (the same padding a bordered pill already
        -- reserves) instead of wrapping label_w in a taller container --
        -- that would grow this pill past its siblings' height and shift
        -- its text upward once the row vertically centres pills of
        -- different heights. Fixed black, never inverted on tap: a bordered
        -- pill's own border (FrameContainer's `color` field) is likewise
        -- left untouched by the bg/fg invert below, so it blends into the
        -- black fill instead of reading as a cutout -- the underline should
        -- do the same rather than flip to a visible white notch.
        if link_style then
            local ul_h     = Size.line.medium
            local ul_w     = label_w:getSize().w
            local ul_x_off = pill_pad_h + (extra_pad or 0)
            local ul_y_off = frame_size.h - ul_h
            function frame:paintTo(bb, x, y)
                FrameContainer_.paintTo(self, bb, x, y)
                require("lib/bookshelf_color").paintRect(bb, x + ul_x_off, y + ul_y_off, ul_w, ul_h,
                    ink or Blitbuffer.COLOR_BLACK)
            end
        end
        local pill = InputContainer_:new{
            dimen = Geom:new{ w = frame_size.w, h = frame_size.h },
            frame,
        }
        -- A pill that does nothing (the Tags tab's others while one is being
        -- edited) is no stop for the keys (STYLE.md).
        pill._inert = not (on_tap_cb or on_hold_cb)
        pill.ges_events = {
            Tap = { GestureRange_:new{ ges = "tap", range = pill.dimen } },
        }
        if on_hold_cb then
            pill.ges_events.Hold = { GestureRange_:new{ ges = "hold", range = pill.dimen } }
            pill.onHold = function() on_hold_cb(); return true end
        end
        pill.onTap = function()
            -- Pre-callback tap feedback: invert the pill's bg/fg, paint
            -- the new state into the fb, drain the refresh queue with
            -- forceRePaint so the eink panel actually updates BEFORE
            -- the drilldown's rebuild runs. Modelled on KOReader's
            -- Button:_doFeedbackHighlight + forceRePaint pair
            -- (frontend/ui/widget/button.lua). The drilldown that
            -- follows rebuilds the widget tree, so no undo needed --
            -- the pill itself is gone by the next paint.
            if on_tap_cb and frame and frame.dimen then
                -- An unfilled pill over a ground has no background to invert:
                -- pressed, it fills with the ink and the label swaps to the
                -- ink's opposite so it stays legible ON that fill.
                frame.background = frame.background and frame.background:invert() or ink
                label_w.fgcolor  = label_w.fgcolor:invert()
                if trail_w then trail_w.fgcolor = trail_w.fgcolor:invert() end
                UIManager:widgetRepaint(frame, frame.dimen.x, frame.dimen.y)
                UIManager:setDirty(nil, "ui", frame.dimen)
                -- This is the critical bit -- without it, setDirty
                -- only QUEUES a refresh, and the queue doesn't drain
                -- until the next UIManager iteration. Meanwhile the
                -- callback below runs synchronously and queues its
                -- own paint, so the user never sees the highlight.
                UIManager:forceRePaint()
                on_tap_cb()
            elseif on_tap_cb then
                on_tap_cb()
            end
            return true
        end
        -- The keys' focus: the kit's ring along the pill's own edge
        -- (STYLE.md), not the pill inverted, which read as one chosen.
        require("lib/bookshelf_popup_kit").ringFocus(pill, 0, Space.radius.button)
        return pill, frame_size.w
    end

    -- Build all pills first so the packer knows widths up front.
    local pill_widgets = {}
    for _i, spec in ipairs(pill_specs) do
        local on_tap = spec.on_tap
        local pill, pw = _buildPill(spec.label, on_tap, nil, spec.on_hold, spec.link, spec.trailing)
        pill_widgets[#pill_widgets + 1] = { widget = pill, w = pw }
    end

    -- Greedy width-bounded pack into rows; stop at max_rows and track
    -- the first index that didn't fit.
    local rows = {}
    local cur_row, cur_w = {}, 0
    local stopped_at
    for i, p in ipairs(pill_widgets) do
        local need = (cur_w == 0) and p.w or (cur_w + pill_gap + p.w)
        if need > available_w and cur_w > 0 then
            rows[#rows + 1] = cur_row
            if #rows >= max_rows then
                stopped_at = i
                cur_row, cur_w = {}, 0
                break
            end
            cur_row, cur_w = {}, 0
        end
        cur_row[#cur_row + 1] = p
        cur_w = (#cur_row == 1) and p.w or (cur_w + pill_gap + p.w)
    end
    if #cur_row > 0 and #rows < max_rows then
        rows[#rows + 1] = cur_row
    end

    if stopped_at then
        -- The +N pill opens the overflow view (every pill, still tappable):
        -- on_overflow when the caller supplies one (e.g. the combined book-detail
        -- popup routes it to the full tags sheet on top of itself), else the bare
        -- tags sheet. All "+N" widgets share one callback over the full spec
        -- list, and get extra L/R padding for a bigger tap target.
        -- on_overflow opens the overflow view (the book-detail popup's Tags tab);
        -- nil leaves the "+N" non-tappable (no caller wants a bare list now).
        local more_cb = on_overflow
        local more_extra = Screen:scaleBySize(8)
        local hidden = #pill_widgets - stopped_at + 1
        local more_pill, more_w = _buildPill("+" .. hidden, more_cb, more_extra)
        local last_row = rows[#rows]
        local last_w = 0
        for j, p in ipairs(last_row) do
            last_w = last_w + ((j == 1) and p.w or (pill_gap + p.w))
        end
        while #last_row > 0
                and (last_w + pill_gap + more_w) > available_w do
            local dropped = table.remove(last_row)
            hidden = hidden + 1
            last_w = last_w - dropped.w
            if #last_row > 0 then last_w = last_w - pill_gap end
            more_pill, more_w = _buildPill("+" .. hidden, more_cb, more_extra)
        end
        last_row[#last_row + 1] = { widget = more_pill, w = more_w }
    end

    -- Focus rows mirror `rows`' wrapping exactly (one dpad row per visual
    -- row, widgets left-to-right) so a caller can hand this straight to
    -- FocusManager:mergeLayoutInVertical (via a `{layout=...}` wrapper)
    -- without re-deriving the pack. Most callers (hero pills, menu strips)
    -- ignore this second return value.
    local focus_rows = {}
    for ri, row_pills in ipairs(rows) do
        local row_widget = HorizontalGroup_:new{ align = "center" }
        local focus_row = {}
        for j, p in ipairs(row_pills) do
            if j > 1 then
                row_widget[#row_widget + 1] = HorizontalSpan_:new{ width = pill_gap }
            end
            row_widget[#row_widget + 1] = p.widget
            if not p.widget._inert then focus_row[#focus_row + 1] = p.widget end
        end
        if ri > 1 then
            pill_group[#pill_group + 1] = VerticalSpan_:new{ width = pill_gap }
        end
        pill_group[#pill_group + 1] = row_widget
        if #focus_row > 0 then focus_rows[#focus_rows + 1] = focus_row end
    end
    -- row_align (set above) aligns each row WITHIN the block when rows have
    -- unequal widths. Aligning the whole block within the hero column is the
    -- caller's job (the hero wraps this in a Left/Centre/Right container at
    -- the authoritative column width).
    return pill_group, focus_rows
end

-- _setBookRating(book, new_rating): persist the rating to the book's
-- DocSettings summary, refresh the per-file progress cache so reads
-- pick up the new value, and rebuild the hero so the star row updates.
-- new_rating is 1-5 or nil (to clear). Matches KOReader's BookStatusWidget
-- storage: summary.rating in the .sdr/metadata.X.lua sidecar.
-- _bookReview(book) / _setBookReview(book, text): the reader's own review,
-- KOReader's summary.note -- the field its book status page edits, so the
-- two stay one review (issues 238, 315). nil when there is none.
function BookshelfWidget:_bookReview(book)
    if not (book and book.filepath) or self:_isRemoteRecord(book) then return nil end
    local DocSettings = require("docsettings")
    if DocSettings.hasSidecarFile and not DocSettings:hasSidecarFile(book.filepath) then
        return nil
    end
    local ok_ds, ds = pcall(function() return DocSettings:open(book.filepath) end)
    local summary = ok_ds and ds and ds:readSetting("summary")
    local note = type(summary) == "table" and summary.note
    return (type(note) == "string" and note ~= "") and note or nil
end

function BookshelfWidget:_setBookReview(book, text)
    if not (book and book.filepath) or self:_isRemoteRecord(book) then return end
    local DocSettings = require("docsettings")
    local ok_ds, ds = pcall(function() return DocSettings:open(book.filepath) end)
    if not ok_ds or not ds then return end
    local summary = ds:readSetting("summary") or {}
    summary.note = (type(text) == "string" and text:match("%S")) and text or nil
    ds:saveSetting("summary", summary)
    ds:flush()
end

-- _editBookReview(book, on_saved): the dialog that writes the reader's own
-- review; on_saved runs after a save, to redraw whatever shows it.
function BookshelfWidget:_editBookReview(book, on_saved)
    local InputDialog = require("ui/widget/inputdialog")
    local dlg
    dlg = InputDialog:new{
        title         = _("My review"),
        input         = self:_bookReview(book) or "",
        scroll        = true,
        allow_newline = true,
        text_height   = Screen:scaleBySize(150),
        buttons = { {
            { text = _("Cancel"), id = "close",
              callback = function() UIManager:close(dlg) end },
            { text = _("Save"), is_enter_default = true,
              callback = function()
                  self:_setBookReview(book, dlg:getInputText())
                  UIManager:close(dlg)
                  if on_saved then on_saved() end
              end },
        } },
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

function BookshelfWidget:_setBookRating(book, new_rating, opts)
    if not book or not book.filepath then return end
    -- The hero's star row is reachable while a remote record is previewed.
    -- DocSettings:open + flush on an OPDS:// pseudo-path would CREATE a
    -- sidecar directory for a book that doesn't exist on this device.
    if self:_isRemoteRecord(book) then return end
    local DocSettings = require("docsettings")
    local ok_ds, ds = pcall(function() return DocSettings:open(book.filepath) end)
    if not ok_ds or not ds then return end
    local summary = ds:readSetting("summary") or {}
    summary.rating = new_rating  -- nil clears it
    ds:saveSetting("summary", summary)
    ds:flush()
    -- Update the in-memory book record so the immediate rebuild reflects
    -- the new value without waiting for a fresh BIM read.
    book.rating = new_rating
    -- Refresh the per-file progress cache (it caches rating alongside
    -- pct/status). Otherwise the next read would return the stale value.
    if Repo.invalidateProgressCache then
        Repo.invalidateProgressCache(book.filepath)
    end
    -- Rebuild the hero so the star row redraws with the new state.
    -- _swapHeroInPlace would be lighter but the rating row builds inside
    -- _renderRight which the in-place swap doesn't re-run.
    --
    -- opts.skip_rebuild lets the staged-Apply path defer the rebuild
    -- so a multi-step apply (rating + status + collections + ...) only
    -- pays for one _rebuild + setDirty at the end of the loop rather
    -- than one per mutation. The cover-tap rating change still gets
    -- the immediate rebuild because it calls without opts.
    if not (opts and opts.skip_rebuild) then
        self:_rebuild()
        UIManager:setDirty(self, "ui")
    end
end

-- _setBookRatingByPath(filepath, rating) — set a rating on a book by
-- filepath, without requiring the full Book table. Used by the bulk
-- actions module to apply a single rating across the selection.
-- Passes skip_rebuild = true so the bulk loop defers the single
-- _rebuild + setDirty to the caller after all mutations are done.
function BookshelfWidget:_setBookRatingByPath(filepath, rating)
    local fake_book = { filepath = filepath, rating = nil }
    self:_setBookRating(fake_book, rating, { skip_rebuild = true })
end

-- Open a scrollable viewer with the full book description. Same
-- TextViewer the updater uses for release notes -- KOReader's stock
-- modal for "here's some text, more than fits on screen, you can
-- scroll it." The description is run through cleanDescription to
-- strip HTML tags and decode entities; the viewer renders plain
-- text with paragraph breaks preserved.
-- _descriptionArgs(book) — build the ReviewsModal args (title + tabs/html_body
-- + on_tab_close) for a book's description(s), or nil when the book has no
-- usable description. Shared by _showFullDescription and the combined
-- book-detail popup (_showBookDetail).
function BookshelfWidget:_descriptionArgs(book)
    if not book then return nil end
    local Tokens = require("lib/bookshelf_tokens")
    -- Render a raw description (either source) to HTML. Two shapes:
    --   * EPUB / Calibre blurbs are HTML (<p>, <b>, <br>, …) -> keep the markup
    --     via the shared sanitiser (whitelisted tags, attributes stripped).
    --   * Hardcover blurbs are PLAIN TEXT with \n\n paragraph breaks and no
    --     tags -> the HTML renderer would collapse those newlines into a single
    --     block, so convert paragraph/line breaks to HTML instead.
    -- A real tag is "<" immediately followed by an (optional "/" then a) letter
    -- -- e.g. <p> or </p>. This deliberately does NOT match prose like "x < y"
    -- (space after "<"), so plain-text blurbs with a stray angle bracket still
    -- take the plain-text path.
    local function toHtml(raw)
        if type(raw) ~= "string" or raw == "" then return nil end
        local html
        if raw:find("</?%a") then html = Tokens.sanitiseReviewHtml(raw) end
        if not html or html:gsub("%s+", "") == "" then
            local text = Tokens.cleanDescription(raw) or ""
            if text == "" then return nil end
            local esc = text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
            html = "<p>" .. (esc:gsub("\n\n+", "</p><p>"):gsub("\n", "<br>")) .. "</p>"
        end
        return html
    end

    -- The book's OWN (embedded / Calibre) description and Hardcover's. enrichBook
    -- stashes file_description (the original, even when Hardcover's is the one
    -- shown) and hardcover_description_text. For an un-enriched book there's no
    -- Hardcover text and book.description is its own.
    local file_desc
    if book.file_description ~= nil then
        file_desc = book.file_description
    elseif not book.hardcover_description then
        file_desc = book.description
    end
    local file_html = toHtml(file_desc)
    local hc_html   = toHtml(book.hardcover_description_text
        or (book.hardcover_description and book.description) or nil)
    if not file_html and not hc_html then return nil end

    local title = book.title or _("Description")
    if book.author then title = title .. " — " .. book.author end

    local args = { title = title }
    if file_html and hc_html then
        -- Both available: an Embedded / Hardcover toggle (a chip bar at the top
        -- of the Description tab). Default to whichever the hero currently shows.
        args.tabs = {
            -- "Embedded" = the book file's own (KOReader/EPUB/Calibre) field;
            -- "Hardcover" = the fetched blurb.
            { label = _("Embedded"),  html = file_html },   -- 1 = book's own
            { label = _("Hardcover"), html = hc_html },      -- 2 = Hardcover
        }
        args.active_tab = book.hardcover_description and 2 or 1
        -- On close, adopt the chosen source: switching the chip and closing
        -- changes what the hero (and the book's other surfaces) use -- same
        -- effect as the per-book "Use Hardcover description" toggle. Only writes
        -- when the choice actually changed.
        args.on_tab_close = function(active_idx)
            local use_hc = (active_idx == 2)
            if use_hc ~= (book.hardcover_description == true) then
                local ok_hc, Hardcover = pcall(require, "lib/bookshelf_hardcover")
                if ok_hc and Hardcover and Hardcover.setUseDescription then
                    Hardcover.setUseDescription(book.filepath, use_hc)
                    self:_refreshHardcoverEnrichmentView(
                        "hardcover-use-description", book.filepath)
                end
            end
        end
    else
        -- Single source: show it, and note Hardcover-sourced descriptions.
        args.html_body = hc_html or file_html
        if hc_html and not file_html then args.subtitle = _("(from Hardcover)") end
    end
    return args
end

-- Tapping the description opens the unified book-detail popup (pills always on
-- top, description + reviews tabs below) -- the pills are shown here too, not
-- only via the "+N" overflow.
function BookshelfWidget:_showFullDescription(book)
    return self:_showBookDetail(book)
end

-- _commitBookStatus(book, status) — write a reading status ("new" | "reading" |
-- "abandoned" | "complete") to the book's DocSettings and bust the caches the
-- shelf + menu read. Immediate (no staging); the Edit tab uses it directly.
-- Mirrors the long-press menu's Apply-status step.
function BookshelfWidget:_commitBookStatus(book, status)
    if not (book and book.filepath and status) then return end
    -- If THIS book's reader is parked hot under the shelf, its in-memory
    -- DocSettings flush on the eventual real close would overwrite whatever
    -- we write here ('set to Unopened, the reading glyph stayed' - the
    -- parked flush restored status=reading afterwards). Finish the park
    -- first so its flush lands BEFORE ours; the park is only a resume
    -- optimisation for a book the user already closed.
    pcall(function()
        local Park = require("lib/bookshelf_reader_park")
        if Park.isParked() and Park.parkedFile() == book.filepath then
            Park.runInFileManager(function() end)
        end
    end)
    local DocSettings = require("docsettings")
    local ds = DocSettings:open(book.filepath)
    local summary = ds:readSetting("summary") or {}
    summary.status   = status
    summary.modified = os.date("%Y-%m-%d", os.time())  -- #66: stamp like KOReader
    ds:saveSetting("summary", summary)
    if status == "new" then
        ds:delSetting("percent_finished")
        ds:delSetting("last_xp")
        ds:delSetting("last_page")
    end
    ds:flush()
    Repo.invalidateProgressCache(book.filepath)
    Repo.invalidateBookCache("edit-status")
    local ok_bl, BookList = pcall(require, "ui/widget/booklist")
    if ok_bl and BookList and BookList.resetBookInfoCache then
        BookList.resetBookInfoCache(book.filepath)
    end
end

-- The book detail modal's scrolling tabs: flush-right bar, drawn as a rail
-- (lib/bookshelf_snug_scroll, shared with the Extract page counts dialog).
local SnugScroll = require("lib/bookshelf_snug_scroll")

-- Used by the Edit tab's infoRow (Hardcover row): a pre-built button,
-- centred in a cell row_h tall.
--
-- want_bottom_border: pass true when nothing below this row already closes
-- it off visually -- i.e. the next thing isn't another section's black
-- heading bar (whose top edge otherwise reads as this row's bottom border,
-- same reasoning as why the row has no top border of its own). Total
-- height always comes out to row_h either way, so callers don't need to
-- adjust their own sizing based on which case applies.
-- A minimal `{layout=...}` wrapper satisfying FocusManager:mergeLayoutInVertical's
-- contract (child.layout + child:disableFocusManagement) for a one-off custom
-- row that isn't itself a real FocusManager instance -- e.g. a single stock
-- Button, or a hand-built row of custom InputContainers (star ratings, tag
-- pills). disableFocusManagement is a no-op beyond recording the parent:
-- unlike a real FocusManager (ButtonTable), this wrapper never independently
-- owns a "currently selected" sub-widget to unfocus -- its rows are merged
-- straight into the caller's own layout and never interacted with directly.
local function focusRow(layout)
    return {
        layout = layout,
        disableFocusManagement = function(self, parent) self._parent = parent end,
    }
end

function BookshelfWidget:_actionButtonColumn(btn, box_w, row_h, want_bottom_border)
    local LineWidget = require("ui/widget/linewidget")
    local border_w = want_bottom_border and Size.line.medium or 0
    local cell_h = row_h - border_w
    local btn_cell = CenterContainer:new{
        dimen = Geom:new{ w = box_w, h = cell_h }, btn }
    if not want_bottom_border then return btn_cell end
    return VerticalGroup:new{ align = "left", btn_cell,
        LineWidget:new{ background = Blitbuffer.COLOR_GRAY,
            dimen = Geom:new{ w = box_w, h = border_w } } }
end

-- _buildBookEditTab(book, modal, avail_w, avail_h) — the Edit tab body:
-- immediate-commit book actions (no draft / Apply / Cancel) grouped under
-- section headings (Reading status / Ratings / Collections / Hardcover / File &
-- metadata / Plugin actions). In-place actions (status, rating, favourite,
-- remove-from-history) rebuild the shelf and refresh this tab via
-- modal:rebuildTab(); surface-opening actions (Show info, Manage collections,
-- Reset, Delete, Refresh, Link Hardcover, Select) close the popup first.
-- All text (buttons, headings, stars) scales with the modal's +/- font size.
-- Hardcover reviews aren't here -- they're the Reviews tab.
-- _fmtPubDate(date) -> a stored publish date as the book menu shows it:
-- 18 Feb 2016, Feb 2016 or 2016 (year-month-day, year-month, year), the
-- month in the interface language: the short form %published{format} falls
-- back to as well (lib/bookshelf_pubdate_format).
function BookshelfWidget._fmtPubDate(date)
    if not tostring(date or ""):match("^%d%d%d%d") then return date end
    return require("lib/bookshelf_pubdate_format").short(date)
end

function BookshelfWidget:_buildBookEditTab(book, modal, avail_w, avail_h)
    local bw = self
    local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
    local FrameContainer      = require("ui/widget/container/framecontainer")
    local ReadCollection      = require("readcollection")
    local TextWidget          = require("lib/bookshelf_colour_text")
    local TextBoxWidget       = require("ui/widget/textboxwidget")
    local InputContainer      = require("ui/widget/container/inputcontainer")
    local HorizontalGroup     = require("ui/widget/horizontalgroup")
    local HorizontalSpan      = require("ui/widget/horizontalspan")
    local VerticalSpan        = require("ui/widget/verticalspan")
    local GestureRange        = require("ui/gesturerange")

    -- Hydrate rating from the sidecar (shelf records skip it for speed).
    if book.rating == nil and book.filepath then
        local _pct, _st, fresh = Repo.readProgress(book.filepath)
        book.rating = fresh
    end

    local font_size = (modal and modal.font_size) or 20

    local function closeModal() if modal then UIManager:close(modal) end end
    local function refreshShelf() bw:_rebuild(); UIManager:setDirty(bw, "ui") end
    -- shelfSoon(): the shelf behind rebuilt 0.4 s after the last change, or
    -- as the popup closes if sooner, not before the popup can show a tap
    -- (a whole shelf, 200-600 ms on a PW5, came first; rapid star taps
    -- queued behind it). Kept on the popup: this tab is rebuilt per change.
    local function shelfSoon()
        if not modal then bw:_rebuild(); UIManager:setDirty(bw, "ui"); return end
        if not modal._shelf_fire then
            modal._shelf_fire = function()
                modal._shelf_owed = false
                bw:_rebuild(); UIManager:setDirty(bw, "ui")
            end
        end
        modal._shelf_owed = true
        UIManager:unschedule(modal._shelf_fire)
        UIManager:scheduleIn(0.4, modal._shelf_fire)
    end
    local function refreshInPlace()  -- commit done: this tab now, the shelf soon
        if modal and modal.rebuildTab then modal:rebuildTab() end
        shelfSoon()
    end

    -- ── Hardcover availability + cached rating (read-only) ───────────────────
    local _ok_hc, _HC = pcall(require, "lib/bookshelf_hardcover")
    local hc_available = _ok_hc and _HC and _HC.isAvailable and _HC.isAvailable()
    local hc_rating
    if hc_available and book.filepath then
        local link = _HC.getLink and _HC.getLink(book.filepath)
        local book_id = book.hardcover_book_id or (link and link.book_id)
        if book_id and _HC.getCachedRating then
            hc_rating = _HC.getCachedRating(book_id)
        end
    end

    -- ── Show info ────────────────────────────────────────────────────────────
    local show_info = { text = _("Show info"), callback = function()
        local lfs = require("libs/libkoreader-lfs")
        if lfs.attributes(book.filepath, "mode") ~= "file" then
            UIManager:show(require("ui/widget/infomessage"):new{
                text = _("File no longer exists. The bookshelf entry is stale."),
                timeout = 3 })
            return
        end
        closeModal()
        -- Book info needs a live FileManager: its bookinfo module carries
        -- the `ui` context getDocProps reads (self.ui.coverbrowser). While a
        -- reader is parked there is no FileManager, so finish the park first
        -- (close the book, FM reborn under the shelf) then show -- same move
        -- as the menu tap. A bare FileManagerBookInfo:new{} has no ui and
        -- crashes in getDocProps.
        require("lib/bookshelf_reader_park").runInFileManager(function(fm)
            fm = fm or require("apps/filemanager/filemanager").instance
            if fm and fm.bookinfo then
                fm.bookinfo:show(book.filepath)
            else
                -- Last resort (no FM at all -- shouldn't happen once the park
                -- has finished): a stub ui keeps getDocProps from indexing
                -- nil, so at least the info opens rather than crashing.
                require("apps/filemanager/filemanagerbookinfo"):new{ ui = {} }:show(book.filepath)
            end
        end)
    end }

    -- Favourite toggle keys off the default collection (Collections membership
    -- itself is shown/edited on the Tags tab, not here).
    local default_coll = ReadCollection.default_collection_name

    local BookList = require("ui/widget/booklist")

    -- ── Favourite / Remove from history ──────────────────────────────────────
    local remove_history = { text = _("Remove from history"), callback = function()
        pcall(function() require("readhistory"):removeItemByPath(book.filepath) end)
        Repo.invalidateBookCache("edit-remove-history")
        refreshInPlace()
        UIManager:show(require("ui/widget/notification"):new{
            text = _("Removed from history"), timeout = 1 })
    end }
    local function inFav()
        local s = ReadCollection:getCollectionsWithFile(book.filepath) or {}
        return s[default_coll] and true or false
    end
    local fav = {
        callback = function()
            if inFav() then
                pcall(function() ReadCollection:removeItem(book.filepath, default_coll) end)
            else
                pcall(function() ReadCollection:addItem(book.filepath, default_coll) end)
            end
            pcall(function() ReadCollection:write() end)
            pcall(function() Repo.invalidateFavoritesCache() end)
            refreshInPlace()
        end,
    }

    -- ── File & metadata ──────────────────────────────────────────────────────
    local filemanagerutil = require("apps/filemanager/filemanagerutil")
    local reset_btn = filemanagerutil.genResetSettingsButton(book.filepath, function()
        Repo.invalidateProgressCache(book.filepath)
        Repo.invalidateWalkCache()
        refreshShelf()
    end)
    reset_btn.text = _("Reset book data\xE2\x80\xA6")
    local orig_reset = reset_btn.callback
    reset_btn.callback = function() closeModal(); orig_reset() end

    local delete_btn = { text = "\xE2\x9C\x95 " .. _("Delete"), callback = function()  -- ✕
        closeModal()
        local function afterDelete()
            Repo.invalidateProgressCache(book.filepath)
            Repo.invalidateWalkCache()
            bw:_scrubFromDrilldown(book.filepath)
            refreshShelf()
        end
        -- Delete goes through the FileManager's own delete dialog (sidecar +
        -- history + collections cleanup). That needs a live FM, so finish the
        -- park first when a reader is parked -- same rule as Show info. The
        -- confirmbox below is a defensive last resort only (no FM at all).
        require("lib/bookshelf_reader_park").runInFileManager(function(fm)
            fm = fm or require("apps/filemanager/filemanager").instance
            if fm and fm.showDeleteFileDialog then
                fm:showDeleteFileDialog(book.filepath, afterDelete)
            else
                UIManager:show(require("ui/widget/confirmbox"):new{
                    text    = _("Delete file permanently?") .. "\n\n" .. book.filepath,
                    ok_text = _("Delete"),
                    ok_callback = function()
                        if os.remove(book.filepath) then
                            require("readhistory"):fileDeleted(book.filepath)
                            ReadCollection:removeItem(book.filepath)
                            afterDelete()
                        else
                            UIManager:show(require("ui/widget/infomessage"):new{
                                text = _("Failed to delete file."), icon = "notice-warning" })
                        end
                    end,
                })
            end
        end)
    end }

    local refresh_btn = { text = _("Refresh metadata"), callback = function()
        closeModal()
        local ok_bim, BIM = pcall(require, "bookinfomanager")
        if ok_bim and BIM and BIM.deleteBookInfo then
            pcall(function() BIM:deleteBookInfo(book.filepath) end)
        end
        -- And from the batch rows, or the extraction check still finds it.
        Repo.forgetBook(book.filepath)
        -- Asked for: the cover comes back too, plugin format or not.
        bw:_allowCoverFetch(book.filepath)
        pcall(function() require("lib/bookshelf_scaled_cover_cache"):drop(book.filepath) end)
        Repo.invalidateProgressCache(book.filepath)
        Repo.invalidateBookCache("refresh-metadata")
        if bw._hero_current_memo and bw._hero_current_memo.fp == book.filepath then
            bw._hero_current_memo = nil
        end
        bw:_rebuild(); UIManager:setDirty(bw, "ui")
        UIManager:show(require("ui/widget/notification"):new{
            text = _("Metadata refresh queued"), timeout = 2 })
    end }
    -- The reader's own publish date (%published, the Publication year sort):
    -- wins over every source; empty goes back to the book's own. Opened from
    -- the Publish date row below the actions.
    local pubdate_btn = { callback = function()
        local Published = require("lib/bookshelf_published")
        local function done()
            require("lib/bookshelf_sort_engine").clearPublishedMemo()
            Repo.invalidateBookCache("publication-date")
            bw:_rebuild(); UIManager:setDirty(bw, "ui")
            if modal and modal.rebuildTab then modal:rebuildTab() end
        end
        -- A date picker, not free text: the year, month and day spinners
        -- (a spinner's number can be tapped to type it). The extra button
        -- goes back to the book's own date, when the reader has set one.
        local cur = Published.info(book)
        local y, m, d = tostring(cur or ""):match("^(%d%d%d%d)%-?(%d*)%-?(%d*)$")
        local now = os.date("*t")
        local user_set = Published.userDate(book.filepath) ~= nil
        -- The way back names where it goes: the book's own date, which,
        -- with the reader's set, is read from the file now (one file, on
        -- this tap; the reader's date was stored in its place).
        local back_text
        if user_set then
            local own = Published.info(book, { ignore_user = true })
            if not own then
                local ok_r, read = pcall(function()
                    local P = require("lib/bookshelf_pubdate")
                    return P.read(book.filepath)
                end)
                own = ok_r and read or nil
            end
            back_text = own and T(_("Use the book's date (%1)"), BookshelfWidget._fmtPubDate(own))
                or _("Use the book's date (none)")
        end
        local DateTimeWidget = require("ui/widget/datetimewidget")
        local picker
        -- Opens on the date shown (the reader's, else the book's); a year
        -- alone opens on 1 January. No date at all: today.
        picker = DateTimeWidget:new{
            year = tonumber(y) or now.year, year_min = 1000, year_max = now.year + 1,
            month = tonumber(m) or (y and 1 or now.month),
            day = tonumber(d) or (y and 1 or now.day),
            title_text = _("Publish date"),
            ok_text = _("Set date"),
            extra_text = back_text,
            extra_callback = user_set and function()
                Published.setUserDate(book.filepath, nil)
                UIManager:close(picker)
                done()
            end or nil,
            callback = function(t)
                Published.setUserDate(book.filepath,
                    string.format("%04d-%02d-%02d", t.year, t.month, t.day))
                done()
            end,
        }
        UIManager:show(picker)
    end }
    local select_btn = { text = _("Select"), callback = function()
        closeModal()
        if not bw._selection:isActive() then bw._selection:enterMode() end
        bw._selection:add(book.filepath)
        bw:_rebuild(); UIManager:setDirty(bw, "ui")
    end }

    -- Move: disabled while this book is the open/parked document
    -- (moving the file under a live reader risks the close-time
    -- sidecar flush recreating data at the old path).
    local FileOpsMod = require("lib/bookshelf_file_ops")
    local move_in_use = FileOpsMod.inUsePaths()[book.filepath] and true or false
    local move_btn = {
        text    = _("Move\xE2\x80\xA6"),
        enabled = not move_in_use,
        callback = function()
            closeModal()
            require("lib/bookshelf_move_flow").moveBooks{
                bw    = bw,
                paths = { book.filepath },
            }
        end,
    }

    -- Third-party file-dialog buttons (e.g. Incognito). Run their specs RAW --
    -- exactly as the old long-press menu did -- rather than wrapping them to
    -- close the popup first; a plugin callback that opens the reader triggers our
    -- onShowingReader handler, which closes the popup cleanly.
    local plugin_rows = bw:_fileDialogPluginRows(book.filepath)

    local function favCardIcon(on)
        local star = require("lib/bookshelf_cover_progress").favoriteIcon() == "star"
        if star then return on and "\xEE\xAF\x8D" or "\xEE\xAF\x91" end   -- star / star-outline
        return on and "\xEE\xA7\x90" or "\xEE\xA7\x94"                    -- heart / heart-outline
    end

    -- ── Action tiles ─────────────────────────────────────────────────────────
    -- Most used first. Icons are the bundled symbols font's Material Design
    -- glyphs (PUA, so safe in any UI font).
    -- Each has a stable id for the reader's own order (long-press a card).
    local tile_specs = {
        -- The reader's own mark (Favorites icon: a heart unless they chose
        -- the star), filled when it is a favourite, outlined when not.
        { id = "favorite", text = _("Favorite"), icon = favCardIcon(inFav()),
          on = inFav(), callback = fav.callback },
        { id = "history", text = remove_history.text, icon = "\xEE\xA7\x99", callback = remove_history.callback }, -- history
        { id = "info",    text = show_info.text,   icon = "\xEE\xA7\xBC", callback = show_info.callback },   -- information-outline
        { id = "select",  text = select_btn.text,  icon = "\xEE\xA0\xB8", callback = select_btn.callback },  -- checkbox-multiple-marked-outline
        { id = "refresh", text = refresh_btn.text, icon = "\xEE\xAD\x8F", callback = refresh_btn.callback }, -- refresh
    }
    -- Curated shelves (issue 390), straight after Favorite: the way books get
    -- onto one. The chooser opens over this menu and stays while shelves are
    -- ticked; the card is lit when the book is on any of them. On a curated
    -- shelf the book stands on, a second card moves it along that shelf
    -- and from there any other ("Arrange": "Move on shelf" sat beside the
    -- file's own "Move...").
    do
        local CUI = require("lib/bookshelf_curated_ui")
        local Curated = require("lib/bookshelf_curated")
        local on_a_shelf = false
        for _i, sh in ipairs(CUI.shelves()) do
            if Curated.has(sh.list, book.filepath) then on_a_shelf = true; break end
        end
        table.insert(tile_specs, 2, { id = "shelf", text = _("Add to shelf"), icon = CUI.ICON_ADD,
            after = "favorite",   -- its place in an order saved before it existed
            on = on_a_shelf,
            callback = function()
                CUI.pick{ paths = { book.filepath }, after_id = bw.chip,
                    on_done = function(changed)
                        if not changed then return end
                        -- A spine shelf keeps its own list for a while.
                        if bw._expireSpineFetch then bw:_expireSpineFetch() end
                        refreshInPlace()
                    end }
            end })
        local here = bw._curatedList and bw:_curatedList()
        if here and Curated.has(here, book.filepath) then
            table.insert(tile_specs, 3, { id = "shelf_move", text = _("Arrange"), after = "shelf",
                icon = "\u{E8B5}",   -- cursor-move
                callback = function()
                    closeModal()
                    bw:_curatedMoveMenu(book)
                end })
        end
    end
    -- A record from a device library (Kindle #355, Kobo) is not a file the user
    -- put on the device: its path is the reader's own library entry, or a
    -- generated conversion of one. Delete would really remove the book from the
    -- Kindle, and Move would break the catalogue's idea of where it lives, so
    -- those actions go rather than being offered and failing.
    if not (book.is_kindle or book.is_kobo) then
        tile_specs[#tile_specs + 1] = { id = "move", text = move_btn.text, icon = "\xEE\xA5\x91", -- folder-move
            enabled = move_btn.enabled, callback = move_btn.callback }
        tile_specs[#tile_specs + 1] = { id = "reset", text = reset_btn.text, icon = "\xEE\x9D\xAE", -- backup-restore
            callback = reset_btn.callback }
        tile_specs[#tile_specs + 1] = { id = "delete", text = _("Delete"), icon = "\xEE\xA2\xBF", -- delete
            callback = delete_btn.callback }
    end

    -- Third-party actions join the grid after ours, as cards with the Action
    -- card's puzzle icon (they bring no icon of their own).
    for _ri, row in ipairs(plugin_rows or {}) do
        for _ci, spec in ipairs(row) do
            local enabled = spec.enabled
            if spec.enabled_func then enabled = spec.enabled_func() end
            local text = (spec.text_func and spec.text_func()) or spec.text or ""
            -- Keyed by the plugin's registration and the button's place in
            -- it, so a label that changes with the book ("Add to X" /
            -- "Remove from X") keeps its place and hidden flag, and two
            -- plugins' same label are two cards. A plugin added with no id:
            -- its label.
            local key = row._bs_id and (row._bs_id .. "#" .. _ci) or text
            tile_specs[#tile_specs + 1] = {
                id = "plugin:" .. key, text = text,
                icon = "\xEE\xAC\xB0", -- mdi-puzzle
                enabled = enabled ~= false, callback = spec.callback,
            }
        end
    end

    -- The reader's own order. A long-press on any card starts arranging:
    -- every card shows (hidden ones greyed), a tap picks one, and the strip
    -- above moves or hides it. The state lives on the modal, so it survives
    -- the tab's rebuilds; each change is saved as it happens, flushed on Done.
    local Arr = require("lib/bookshelf_book_actions_layout")
    local arranging = modal and modal._actions_edit
    local default_order = {}
    for i, a in ipairs(tile_specs) do default_order[i] = a.id end
    tile_specs = Arr.arrange(tile_specs, arranging or BookshelfSettings.read(Arr.KEY) or {})
    local all_tiles = tile_specs
    if not arranging then tile_specs = Arr.visible(tile_specs) end
    local function rebuildTab()
        if modal and modal.rebuildTab then modal:rebuildTab() end
    end
    local function keepArrangement(final)
        local val = { order = arranging.order, hidden = arranging.hidden }
        if final then BookshelfSettings.save(Arr.KEY, val)
        else BookshelfSettings.saveDeferred(Arr.KEY, val) end
    end
    local function startArranging(id)
        if not modal then return end
        local saved = BookshelfSettings.read(Arr.KEY) or {}
        local order, hidden = {}, {}
        for i, a in ipairs(all_tiles) do order[i] = a.id end
        for k, v in pairs(saved.hidden or {}) do hidden[k] = v end
        modal._actions_edit = { order = order, hidden = hidden, sel = id }
        rebuildTab()
    end
    local function pick(id)
        arranging.sel = id
        rebuildTab()
    end

    -- The popup's shared controls (lib/bookshelf_popup_kit): the button
    -- outline and corner, and a tap target with a dpad focus highlight.
    local tile_border, tile_radius, tapCell = PopupKit.BORDER, PopupKit.RADIUS, PopupKit.tapCell

    -- This is our own widget tree (not a ButtonDialog), so the body is a
    -- VerticalGroup we compose freely: small grey headings, and under each a
    -- control that draws its whole outline itself, inset from the frame.
    -- Thin scrollbar, minimal right reserve; SnugScroll.widen adds the couple
    -- of pixels that make it read as a bar beside the frame's border.
    local bar_w     = SnugScroll.widen(Screen:scaleBySize(3))
    local sb        = bar_w   -- SnugScroll reserves exactly the bar width (no gaps)
    local pad_top    = 0   -- first heading strip butts against the tab strip
    local pad_bottom = Space.px(20)
    -- Left inset = the modal's shared side pad, so heading text + info-row text
    -- line up with the tab strip and the description body.
    local inset      = (modal and modal._side_pad) or Space.px(28)

    -- pubText() -> the date %published and the Publication year sort use, as
    -- stored (18 Feb 2016, Mar 1869 or 1869), and where it came from, so a
    -- date the book's file gives (often the ebook's own release, not the
    -- work's) reads as that; or why there is none (and nil).
    local function pubText()
        local date, src = require("lib/bookshelf_published").info(book)
        if not date then
            if src == "pending" then return _("Checking the file\xE2\x80\xA6"), nil, false, src end
            return _("None in the file"), nil, false, src
        end
        local text = BookshelfWidget._fmtPubDate(date)
        return text, ({
            user      = _("set by you"),
            hardcover = _("from Hardcover"),
            calibre   = _("from calibre"),
            catalog   = _("from the catalog"),
            file      = _("from the file"),
        })[src], true
    end
    local pub_below = true

    local function buildBody(content_w)
        local function heading(text)
            -- The FULL tab width (not the scroll-reduced content_w): getSize
            -- ignores it, so it can't widen the layout, and the scroll crop
            -- trims any overhang.
            return bw:_sectionHeadingBar(text, avail_w, font_size, inset)
        end
        local function padded(widget, top, bottom)
            return FrameContainer:new{
                bordersize = 0, margin = 0,
                padding_left = inset, padding_right = inset,
                padding_top = top, padding_bottom = bottom,
                widget,
            }
        end
        local vg = VerticalGroup:new{ align = "left" }
        -- Every focusable section/row, in visual top-to-bottom order, so the
        -- modal's dpad nav can chain across ALL of them -- not just the
        -- first ButtonTable (each one already builds its own `.layout`,
        -- see ui/widget/buttontable.lua; one-off custom rows below get a
        -- `{layout=...}` wrapper to match that same shape).
        local focus_tables = {}

        -- 1. Reading status: one segmented control. It draws its own rounded
        -- outline and dividers, so it closes on itself instead of leaning on
        -- the frame edge or the next row to finish it (book popup redesign:
        -- the old full-width button grid left lines that ended nowhere).
        vg[#vg + 1] = heading(_("Reading status"))
        do
            local items = {
                { label = _("Unopened"), key = "new" },
                { label = _("Reading"),  key = "reading" },
                { label = _("On hold"),  key = "abandoned" },
                { label = _("Finished"), key = "complete" },
            }
            local seg, seg_focus = PopupKit.segmented{
                items = items, active = BookList.getBookStatus(book.filepath),
                face = Font:getFace("cfont", font_size), width = content_w - 2 * inset,
                on_pick = function(key)
                    bw:_commitBookStatus(book, key)
                    -- The header's reading line says the status too.
                    if modal and modal.dropHeader then modal:dropHeader() end
                    refreshInPlace()
                end,
            }
            focus_tables[#focus_tables + 1] = focusRow(seg_focus)
            vg[#vg + 1] = padded(seg, 0, 0)
        end

        -- 2. Ratings: editable "Your rating" stars and, inline, the read-only
        -- Hardcover rating (same star glyphs + spacing; a half star where the
        -- rating lands on a half) plus the numeric value.
        -- nf-fa-star / star_half_empty / star_o (the half matches the hero glyphs).
        local STAR_FULL, STAR_HALF, STAR_EMPTY = "\xEF\x80\x85", "\xEF\x84\xA3", "\xEF\x80\x86"
        -- In the three-column layout (below) the stars stand as tall as the
        -- publish date's button beside them, so the two read as one row: the
        -- size grows from the usual one until its row matches the button, as
        -- long as five stars still fit a column (a third with Hardcover's
        -- rating, a half without). Too narrow: the usual size.
        local star_size = font_size + 4
        do
            local cols_avail = content_w - 2 * inset
            local col_w = hc_rating and math.floor(cols_avail / 3) or math.floor(cols_avail / 2)
            local btn_h = TextWidget:new{ text = "Hg",
                face = BFont:getFace("cfont", font_size, { bold = true }) }:getSize().h
                + 2 * Space.padding.small + 2 * Size.border.thin
            -- Matched on the star's INK, not its line: a glyph's line box has
            -- room above and below it, so matching the box left the stars two
            -- thirds the button's height. The ink is the rendered glyph's own
            -- bitmap (RenderText:getGlyph).
            local RenderText = require("ui/rendertext")
            local pad = 2 * Space.px(3)   -- buildStar's padding, both sides
            for size = font_size + 4, font_size + 40 do
                local face = BFont:getFace("symbols", size)
                local g = TextWidget:new{ text = "\xEF\x80\x85", face = face }
                local gw = g:getSize().w
                g:free()
                -- A clear gap before the next column: two star rows side by
                -- side read as one long row without it.
                if (gw + pad) * 5 + Space.px(48) > col_w then break end
                star_size = size
                local ok_g, glyph = pcall(RenderText.getGlyph, RenderText, face, 0xF005)
                local ink = ok_g and glyph and glyph.bb and glyph.bb:getHeight() or 0
                if ink >= btn_h - 2 * Size.border.thin then break end
            end
        end
        -- A padded star glyph. With on_tap it's an interactive (tappable) star;
        -- without, just the padded glyph -- so interactive and read-only star rows
        -- get identical per-star spacing.
        local function buildStar(glyph, on_tap, on_hold)
            local tw = TextWidget:new{ text = glyph,
                face = BFont:getFace("symbols", star_size), fgcolor = Blitbuffer.COLOR_BLACK }
            local frame = FrameContainer:new{
                bordersize = 0, margin = 0, padding = Space.px(3), tw }
            if not on_tap then return frame end
            local fsz = frame:getSize()
            local star = InputContainer:new{ dimen = Geom:new{ w = fsz.w, h = fsz.h }, frame }
            star.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = star.dimen } } }
            star.onTap = function() on_tap(); return true end
            if on_hold then
                star.ges_events.Hold = { GestureRange:new{ ges = "hold", range = star.dimen } }
                star.onHold = function() on_hold(); return true end
            end
            -- The keys' focus: the kit's ring round the star (STYLE.md), not
            -- the star inverted, which read as a rating set.
            require("lib/bookshelf_popup_kit").ringFocus(star, 0, Space.px(4))
            return star
        end
        -- Rating labels match the body text size (the number, collection names).
        local lbl_face = BFont:getFace("cfont", font_size)
        local function lbl(text)
            return TextWidget:new{ text = text, face = lbl_face, fgcolor = Blitbuffer.COLOR_BLACK }
        end
        local cur = tonumber(book.rating) or 0
        if cur < 0 then cur = 0 elseif cur > 5 then cur = 5 end
        cur = math.floor(cur)
        -- The two rows' labels share one width, so the stars line up.
        local lbl_w = lbl(_("Your rating")):getSize().w
        if hc_rating then lbl_w = math.max(lbl_w, lbl(_("Hardcover")):getSize().w) end
        local LeftContainer = require("ui/widget/container/leftcontainer")
        local function lblCell(text)
            local t = lbl(text)
            return LeftContainer:new{ dimen = Geom:new{ w = lbl_w, h = t:getSize().h }, t }
        end
        -- "Your rating": label + tappable stars.
        local your_group = HorizontalGroup:new{ align = "center" }
        your_group[#your_group + 1] = lblCell(_("Your rating"))
        your_group[#your_group + 1] = HorizontalSpan:new{ width = Space.px(10) }
        local your_stars = {}
        for i = 1, 5 do
            local glyph = (i <= cur) and STAR_FULL or STAR_EMPTY
            local function setRating(newv)
                bw:_setBookRating(book, newv, { skip_rebuild = true }); book.rating = newv
                if modal and modal.rebuildTab then modal:rebuildTab() end
                shelfSoon()
            end
            local star = buildStar(glyph, function()
                setRating((i == cur) and nil or i)   -- tap current rating clears it
            end, cur > 0 and function()
                -- Long-press: clear the rating, after asking (a tap on the
                -- star of the rating set does too, but nothing says so).
                UIManager:show(require("ui/widget/confirmbox"):new{
                    text = _("Clear your rating?"),
                    ok_text = _("Clear"),
                    ok_callback = function() setRating(nil) end,
                })
            end or nil)
            your_group[#your_group + 1] = star
            your_stars[#your_stars + 1] = star
        end
        -- One dpad row, left-to-right across the 5 stars.
        focus_tables[#focus_tables + 1] = focusRow({ your_stars })

        local ratings_widget = your_group
        -- Hardcover's stars and its number, for the three-column layout.
        local hc_parts
        if hc_rating then
            -- The Hardcover stars tap through to the Reviews tab when present.
            local reviews_idx
            if modal and modal._tabs then
                for ti, t in ipairs(modal._tabs) do
                    if t.id == "reviews" and t.has_hardcover then reviews_idx = ti; break end
                end
            end
            -- Read-only stars built the same way as the user-rating stars (same
            -- per-star padding) so the two rows line up, with a half star where
            -- the rating falls on a half.
            local halves = math.floor(hc_rating * 2 + 0.5)  -- 0..10 half-units
            local hc_stars = HorizontalGroup:new{ align = "center" }
            for i = 1, 5 do
                local glyph = STAR_EMPTY
                if halves >= 2 * i then glyph = STAR_FULL
                elseif halves == 2 * i - 1 then glyph = STAR_HALF end
                hc_stars[#hc_stars + 1] = buildStar(glyph, nil)
            end
            local hc_stars_widget = hc_stars
            if reviews_idx and modal._switchTab then
                local fsz = hc_stars:getSize()
                local ic  = InputContainer:new{ dimen = Geom:new{ w = fsz.w, h = fsz.h }, hc_stars }
                ic.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = ic.dimen } } }
                ic.onTap = function()
                    -- Hardcover's stars open Hardcover's reviews, not yours.
                    local rt = modal._tabs[reviews_idx]
                    if rt and rt.sources then rt._active_source = 2 end
                    modal:_switchTab(reviews_idx); return true
                end
                -- Dpad/keyboard focus highlight: ic is a plain InputContainer
                -- (no stock `invert`, unlike FrameContainer), so paint then
                -- pixel-invert on top -- the same idiom as InvertedFrame
                -- elsewhere in this file.
                ic._focused = false
                function ic:paintTo(bb, x, y)
                    InputContainer.paintTo(self, bb, x, y)
                    if self._focused then bb:invertRect(x, y, self.dimen.w, self.dimen.h) end
                end
                ic.onFocus = function() ic._focused = true; return true end
                ic.onUnfocus = function() ic._focused = false; return true end
                hc_stars_widget = ic
                focus_tables[#focus_tables + 1] = focusRow({ { ic } })
            end
            local hc_group = HorizontalGroup:new{ align = "center",
                lblCell(_("Hardcover")),
                HorizontalSpan:new{ width = Space.px(10) },
                hc_stars_widget,
                HorizontalSpan:new{ width = Space.px(8) },
                TextWidget:new{ text = string.format("%.1f", hc_rating),
                    face = BFont:getFace("cfont", font_size), fgcolor = Blitbuffer.COLOR_BLACK },
            }
            -- Hardcover's under yours, always: the column beside them is the
            -- publish date's.
            ratings_widget = VerticalGroup:new{ align = "left",
                your_group, VerticalSpan:new{ width = Space.px(8) }, hc_group }
            hc_parts = { stars = hc_stars_widget, num = string.format("%.1f", hc_rating) }
        end

        -- The publish date beside the ratings: the date, where it came from,
        -- and Edit. Too narrow for two columns (a big zoom, a small screen):
        -- the ratings alone here and the date in a row of its own below the
        -- actions (pub_below).
        local pub_date_str, pub_from, pub_known, pub_src = pubText()
        -- Being read from the file now (queued as the tab asked): look again
        -- every couple of seconds while the menu is up, and show the date
        -- when it lands, rather than "Checking" until the menu is reopened.
        if pub_src == "pending" and modal and not modal._pub_watch then
            modal._pub_watch = true
            local tries = 0
            local function check()
                tries = tries + 1
                if not UIManager:isWidgetShown(modal) then modal._pub_watch = nil return end
                if require("lib/bookshelf_published").info(book) then
                    modal._pub_watch = nil
                    if modal.rebuildTab then modal:rebuildTab() end
                elseif tries < 15 then
                    UIManager:scheduleIn(2, check)
                else
                    modal._pub_watch = nil
                end
            end
            UIManager:scheduleIn(2, check)
        end
        -- Half and half, so the date's column starts under the status
        -- control's third cell (On hold) and the two line up.
        -- Ratings too wide for half (a smaller screen, Hardcover's row with
        -- its number): the date starts where they end, if it still fits.
        local col_gap = Space.px(16)
        local avail   = content_w - 2 * inset
        local left_w  = math.max(math.floor(avail / 2), ratings_widget:getSize().w + col_gap)
        local right_w = avail - left_w
        -- The date is the button (pencil after it, no Edit label): the same
        -- button as infoRow's, its height from a bold line plus the pill
        -- padding and border. No date: Set date, the reason under it.
        local edit_btn = PopupKit.button{
            text       = pub_known and pub_date_str or _("Set date"),
            face       = BFont:getFace("cfont", font_size),
            icon_glyph = "\xEE\xAB\xAA", -- nf-md-pencil, U+EAEA
            icon_face  = BFont:getFace("symbols", font_size),
            icon_after = true,
            height     = TextWidget:new{ text = "Hg",
                face = BFont:getFace("cfont", font_size, { bold = true }) }:getSize().h
                + 2 * Space.padding.small + 2 * Size.border.thin,
            on_tap     = pubdate_btn.callback,
        }
        -- tighten: pixels taken off the gap under the heading.
        local function colHeading(text, w, tighten)
            local face, bold = BFont:getFace("cfont", math.max(10, font_size - 4), { bold = true })
            local t = TextWidget:new{ text = require("lib/bookshelf_text_segments").upper(text),
                face = face, bold = bold, fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = w }
            return FrameContainer:new{ bordersize = 0, margin = 0, padding = 0,
                padding_top = Space.px(22),
                padding_bottom = math.max(0, Space.px(10) - (tighten or 0)), t }
        end
        local function widest(texts, face)
            local m = 0
            for _i, t in ipairs(texts) do
                local w = TextWidget:new{ text = t, face = face }
                m = math.max(m, w:getSize().w); w:free()
            end
            return m
        end
        local body_face = BFont:getFace("cfont", font_size)
        local btn_gap = Space.px(10)
        -- pubColumn(w) -> the publish date's column w wide: its heading, the
        -- date and its source, Edit flush right beside them (in line with the
        -- actions' right edge); nil when w is too narrow for them.
        local src_face = BFont:getFace("cfont", math.max(10, font_size - 3))
        local function pubColumn(w, drop)
            -- Under the button, in grey: where the date came from, or why
            -- there is none. The button decides the layout, not the note
            -- (which may wrap), so it is the same from book to book.
            local note = pub_known and pub_from or (not pub_known and pub_date_str) or nil
            if edit_btn:getSize().w > w then return nil end
            local col = VerticalGroup:new{ align = "left", colHeading(_("Publish date"), w) }
            if drop and drop > 0 then col[#col + 1] = VerticalSpan:new{ width = drop } end
            col[#col + 1] = edit_btn
            if note then
                col[#col + 1] = VerticalSpan:new{ width = Space.px(4) }
                col[#col + 1] = TextBoxWidget:new{ text = note,
                    face = src_face, fgcolor = Blitbuffer.COLOR_DARK_GRAY, width = w }
            end
            return col
        end
        local function row(cols, widths)
            local hg = HorizontalGroup:new{ align = "top" }
            for i, c in ipairs(cols) do
                hg[#hg + 1] = c
                if i < #cols then
                    hg[#hg + 1] = HorizontalSpan:new{ width = math.max(0, widths[i] - c:getSize().w) }
                end
            end
            return hg
        end

        -- 1. Three columns in thirds: your rating, Hardcover, the publish
        -- date, each heading with its stars (or button) right under it. No
        -- Hardcover rating: two halves. Stars wider than their column (a
        -- smaller screen, a big zoom) go on to 2.
        local third = math.floor(avail / 3)
        local your_row = HorizontalGroup:new{ align = "center" }
        for _i, st in ipairs(your_stars) do your_row[#your_row + 1] = st end
        -- Hardcover's number goes in its heading (HARDCOVER · 4.2), so its
        -- column holds only the stars, as wide as yours.
        local hc_row
        if hc_parts then
            hc_row = HorizontalGroup:new{ align = "center", hc_parts.stars }
        end
        -- Your rating first, then Hardcover's, then the publish date; no
        -- Hardcover rating: yours and the date in halves, the date over the
        -- status control's third cell (On hold).
        local your_w = hc_row and third or math.floor(avail / 2)
        local pub_w  = avail - (hc_row and 2 * third or your_w)
        local pub3 = (your_row:getSize().w + col_gap <= your_w)
            and (not hc_row or hc_row:getSize().w + col_gap <= third)
            and pubColumn(pub_w)
        if pub3 then
            pub_below = false
            -- The stars centred on the date's button, so the row reads level.
            local bh = edit_btn:getSize().h
            local function level(w)
                local sz = w:getSize()
                return CenterContainer:new{ dimen = Geom:new{ w = sz.w, h = bh }, w }
            end
            your_row = level(your_row)
            if hc_row then hc_row = level(hc_row) end
            local cols = { VerticalGroup:new{ align = "left",
                colHeading(_("Your rating"), your_w - col_gap), your_row } }
            local widths = { your_w }
            if hc_row then
                cols[#cols + 1] = VerticalGroup:new{ align = "left",
                    colHeading(_("Hardcover") .. " \xC2\xB7 " .. hc_parts.num, third - col_gap), hc_row }
                widths[#widths + 1] = third
            end
            cols[#cols + 1] = pub3
            vg[#vg + 1] = padded(row(cols, widths), 0, 0)
            focus_tables[#focus_tables + 1] = focusRow({ { edit_btn } })
        else
            -- 2. Two columns: the ratings with their labels, Hardcover's under
            -- yours, and the date half way across (On hold), or where the
            -- ratings end if they are wider than half.
            -- "Your rating" is centred on its stars, which stand taller than
            -- the text: the gap under RATINGS gives up the difference, so its
            -- words sit as far under it as the date does under PUBLISH DATE;
            -- what the gap cannot give, the date's column drops by.
            local lift = math.floor((your_group:getSize().h - lbl(_("Your rating")):getSize().h) / 2)
            local right = (ratings_widget:getSize().w + col_gap <= left_w)
                and pubColumn(right_w, math.max(0, lift - Space.px(10)))
            if right then
                pub_below = false
                local left = VerticalGroup:new{ align = "left",
                    colHeading(_("Ratings"), left_w, lift), ratings_widget }
                vg[#vg + 1] = padded(row({ left, right }, { left_w }), 0, 0)
                focus_tables[#focus_tables + 1] = focusRow({ { edit_btn } })
            else
                -- 3. Stacked: the ratings here, the date in its own row below
                -- the actions.
                vg[#vg + 1] = heading(_("Ratings"))
                vg[#vg + 1] = padded(ratings_widget, 0, 0)
            end
        end

        -- An info row styled like a File-&-metadata button row: the value on the
        -- left (inset to align with the headings), then a bordered ChipButton
        -- on the right -- same style as the Tags tab's Edit button (pencil glyph
        -- after the label). Used by the Hardcover row.
        local function infoRow(text, btn_label, cb, want_bottom_border)
            local btn_w = Screen:scaleBySize(150)
            local edit_face = BFont:getFace("cfont", font_size)
            -- Match the Tags-tab Edit button's height exactly (the Tags-tab
            -- pill height: bold cfont label + Size.padding.small + border.thin,
            -- top and bottom) so the two Edit buttons look identical.
            local pf = BFont:getFace("cfont", font_size, { bold = true })
            local btn_h = TextWidget:new{ text = "Hg", face = pf }:getSize().h
                + 2 * Space.padding.small + 2 * Size.border.thin
            local btn = PopupKit.button{
                text       = btn_label,
                face       = edit_face,
                icon_glyph = "\xEE\xAB\xAA", -- nf-md-pencil, U+EAEA
                icon_face  = BFont:getFace("symbols", font_size),
                icon_after = true,
                height     = btn_h,
                on_tap     = cb,
            }
            local btn_h = btn:getSize().h
            -- Left cell: the value text, inset on the left to align with headings.
            local left_w = math.max(Screen:scaleBySize(60), content_w - btn_w)
            local txt = TextBoxWidget:new{ text = text,
                face  = BFont:getFace("cfont", font_size),
                width = math.max(Screen:scaleBySize(40), left_w - inset - Space.px(8)) }
            -- Extra room OUTSIDE the button/text (not inside the button itself):
            -- same total top+bottom budget as Plugin actions' chip row
            -- (padded(rows_vg, 10, 20) below), so the two sections carry the
            -- same visual weight even though this row centres its content
            -- instead of stacking it top-down.
            local row_h = math.max(btn_h, txt:getSize().h)
                + Space.px(10) + Space.px(20)
            local top_pad = math.floor((row_h - txt:getSize().h) / 2)
            local left_cell = FrameContainer:new{
                bordersize = 0, margin = 0,
                padding_left = inset, padding_right = Space.px(8),
                padding_top = top_pad, padding_bottom = row_h - txt:getSize().h - top_pad,
                txt,
            }
            -- btn is a stock Button (native onFocus/onUnfocus) -- just needs
            -- registering as its own dpad row.
            focus_tables[#focus_tables + 1] = focusRow({ { btn } })
            return HorizontalGroup:new{ align = "top", left_cell,
                bw:_actionButtonColumn(btn, btn_w, row_h, want_bottom_border) }
        end

        -- 3. Actions: the home screen's Action card look, an icon over a
        -- short label on a light grey card, in an even grid. "On" (a
        -- favourite) fills the card black.
        local actions_from, actions_focus_from = #vg + 1, #focus_tables + 1
        vg[#vg + 1] = heading(_("Actions"))
        do
            local w   = content_w - 2 * inset
            local gap = Space.px(12)
            local icon_face  = BFont:getFace("symbols", font_size + 10)
            local label_face = Font:getFace("cfont", math.max(10, font_size - 3))
            local pad_v = Space.px(12)
            -- As many columns (4 at most) as leave every label two lines or
            -- fewer: a small screen or a big zoom drops to 3, then 2.
            local function innerW(c)
                return math.floor((w - (c - 1) * gap) / c) - 2 * tile_border - 2 * Space.px(6)
            end
            local function textH(text, tw)
                local tb = TextBoxWidget:new{ text = text, face = label_face, width = tw }
                local h = tb:getSize().h
                tb:free()
                return h
            end
            local cols = 4
            while cols > 2 do
                local iw, two = innerW(cols), 2 * textH("Ag", innerW(cols))
                local fits = true
                for _i, a in ipairs(tile_specs) do
                    if textH(a.text, iw) > two then fits = false; break end
                end
                if fits then break end
                cols = cols - 1
            end
            local tile_w = math.floor((w - (cols - 1) * gap) / cols)
            local inner_w = innerW(cols)
            -- Build the contents first: every tile in the grid takes the
            -- tallest one's height, so the rows line up.
            local built, content_h = {}, 0
            for _i, a in ipairs(tile_specs) do
                -- Arranging: every card plain (no "on" fill), hidden ones grey.
                local on = a.on and not arranging
                local fg = (arranging and a.hidden and Blitbuffer.COLOR_GRAY)
                    or (arranging and Blitbuffer.COLOR_BLACK)
                    -- Grey, not dark grey: that reads as black (STYLE.md).
                    or ((a.enabled == false) and Blitbuffer.COLOR_GRAY)
                    or (on and Blitbuffer.COLOR_WHITE) or Blitbuffer.COLOR_BLACK
                local icon = TextWidget:new{ text = a.icon, face = icon_face, fgcolor = fg }
                local label = TextBoxWidget:new{ text = a.text, face = label_face,
                    width = inner_w, alignment = "center", fgcolor = fg,
                    bgcolor = on and Blitbuffer.COLOR_BLACK or PopupKit.STRIP_BG }
                local content = VerticalGroup:new{ align = "center",
                    CenterContainer:new{ dimen = Geom:new{ w = inner_w, h = icon:getSize().h }, icon },
                    VerticalSpan:new{ width = Space.px(4) },
                    label,
                }
                built[#built + 1] = content
                content_h = math.max(content_h, content:getSize().h)
            end
            local tile_h = content_h + 2 * pad_v + 2 * tile_border
            local grid = VerticalGroup:new{ align = "left" }
            local line, line_cells
            for i, a in ipairs(tile_specs) do
                if (i - 1) % cols == 0 then
                    if line then
                        grid[#grid + 1] = line
                        grid[#grid + 1] = VerticalSpan:new{ width = gap }
                        focus_tables[#focus_tables + 1] = focusRow({ line_cells })
                    end
                    line, line_cells = HorizontalGroup:new{ align = "top" }, {}
                else
                    line[#line + 1] = HorizontalSpan:new{ width = gap }
                end
                -- The kit's card: a hairline shadow (the light grey alone is
                -- faint on e-ink with no border), shown pressed while its tap
                -- acts. The picked card, while arranging, is outlined.
                local frame = PopupKit.card{
                    padding_top = pad_v + tile_border,
                    on = a.on and not arranging,
                    width = tile_w, height = tile_h,
                    outline = arranging and arranging.sel == a.id,
                    CenterContainer:new{
                        dimen = Geom:new{ w = tile_w,
                                          h = built[i]:getSize().h },
                        built[i],
                    },
                }
                local id = a.id
                local cell
                -- A choice drawn again to show it (picking a card to move,
                -- Favorite on and off) acts at once, no pressed look first
                -- (STYLE.md); an action that opens something is pressed.
                if arranging then
                    cell = tapCell(frame, tile_w, tile_h, function() pick(id) end, true,
                        function() pick(id) end, true)
                else
                    cell = tapCell(frame, tile_w, tile_h, a.callback, a.enabled,
                        function() startArranging(id) end, id == "favorite")
                end
                line[#line + 1] = cell
                line_cells[#line_cells + 1] = cell
            end
            if line then
                grid[#grid + 1] = line
                focus_tables[#focus_tables + 1] = focusRow({ line_cells })
            end
            vg[#vg + 1] = padded(grid, 0, 0)
        end


        -- Arranging shows the Actions alone, right under the strip.
        if arranging then
            local only, only_focus = VerticalGroup:new{ align = "left" }, {}
            for i = actions_from, #vg do only[#only + 1] = vg[i] end
            for i = actions_focus_from, #focus_tables do only_focus[#only_focus + 1] = focus_tables[i] end
            return only, only_focus
        end

        -- 4. Publish date, when it did not fit beside the ratings: a row of
        -- its own, the date and its source, with Edit beside it.
        if pub_below then
            local d, from = pubText()
            vg[#vg + 1] = heading(_("Publish date"))
            vg[#vg + 1] = infoRow(from and (d .. " \xC2\xB7 " .. from) or d, _("Edit"), pubdate_btn.callback)
        end

        -- 5. Hardcover link (brand name -> heading not translated). Edition text
        -- + inline Edit/Link button, below File & metadata. (Collections live on
        -- the Tags tab, which has its own per-collection pills + Edit affordance
        -- -- no need to duplicate the same membership here in a second style.)
        if hc_available then
            local label = _HC.linkLabel and _HC.linkLabel(book.filepath)
            vg[#vg + 1] = heading("Hardcover")
            -- No bottom border needed here: whatever follows (Plugin
            -- actions' heading, or the unconditional closing rule() below
            -- if this is the last section) already closes this row off.
            vg[#vg + 1] = infoRow(
                label or _("Not linked"),
                label and _("Edit") or _("Link\xE2\x80\xA6"),
                function()
                    closeModal()
                    UIManager:nextTick(function() bw:_openHardcoverMenu(book) end)
                end)
        end

        return vg, focus_tables
    end

    -- Full width first; if the body overflows the tab height it will scroll, so
    -- rebuild scrollbar-width narrower to leave the bar its own strip.
    --
    -- Measured on a PW5 before changing this: the two builds are NOT equal
    -- cost. The first is ~112ms and the second only ~17ms, because the font
    -- faces and text measurements are cached by then. So the "wasted" build is
    -- 17ms, not 112ms, and building narrow-first to avoid it merely swaps
    -- which case pays: this tab FITS here (939px into 1089px), so wide-first
    -- is the single-build path and inverting it made the common case slower.
    -- Leave it alone.
    -- Arranging: the move / hide / Done controls on the tab's strip, which
    -- stays put above the scrolling body.
    local strip, strip_focus
    if arranging then
        local sel = arranging.sel
        local function move(d)
            if not sel then return end
            arranging.order = Arr.move(arranging.order, sel, d)
            keepArrangement(false); rebuildTab()
        end
        local hidden_now = sel and arranging.hidden[sel]
        -- Greyed where they can't act (STYLE.md): back at the first card,
        -- on at the last, Hide for the last card showing.
        local at
        for i, id in ipairs(arranging.order) do if id == sel then at = i end end
        local back = PopupKit.headerButton{ icon = "\xEE\xA1\x80", font_size = font_size, -- mdi-chevron-left
            icon_size = font_size, enabled = at ~= nil and at > 1, on_tap = function() move(-1) end }
        local fwd = PopupKit.headerButton{ icon = "\xEE\xA1\x81", font_size = font_size, -- mdi-chevron-right
            icon_size = font_size, enabled = at ~= nil and at < #arranging.order,
            on_tap = function() move(1) end }
        local hide = PopupKit.headerButton{ text = hidden_now and _("Show") or _("Hide"),
            font_size = font_size,
            enabled = sel ~= nil and (hidden_now or Arr.canHide(all_tiles, arranging.hidden, sel)) and true or false,
            on_tap = function()
                if not sel then return end
                if hidden_now then
                    arranging.hidden[sel] = nil
                elseif Arr.canHide(all_tiles, arranging.hidden, sel) then
                    arranging.hidden[sel] = true
                else
                    return
                end
                keepArrangement(false); rebuildTab()
            end }
        -- Reset: the default order with nothing hidden.
        local reset = PopupKit.headerButton{ text = _("Reset"), font_size = font_size,
            on_tap = function()
                local order = {}
                for i, id in ipairs(default_order) do order[i] = id end
                arranging.order, arranging.hidden = order, {}
                keepArrangement(false); rebuildTab()
            end }
        local done = PopupKit.headerButton{ text = _("Done"), font_size = font_size, inverted = true,
            on_tap = function()
                keepArrangement(true)
                modal._actions_edit = nil
                rebuildTab()
            end }
        local gap = Space.px(10)
        strip = PopupKit.headerRow{ width = avail_w, inset = inset,
            left = HorizontalGroup:new{ align = "center",
                back, HorizontalSpan:new{ width = gap }, fwd,
                HorizontalSpan:new{ width = gap }, hide },
            buttons = { reset, done } }
        strip_focus = focusRow({ { back, fwd, hide, reset, done } })
    end
    local body_h = avail_h - (strip and strip:getSize().h or 0)
    local body, focus_tables = buildBody(avail_w)
    if body:getSize().h + pad_top + pad_bottom > body_h then
        body, focus_tables = buildBody(avail_w - sb)
    end
    if strip_focus then table.insert(focus_tables, 1, strip_focus) end
    local padded_body = FrameContainer:new{
        bordersize = 0, margin = 0,
        padding_left = 0, padding_right = 0,
        padding_top = pad_top, padding_bottom = pad_bottom,
        body,
    }
    local scroll = SnugScroll:new{
        dimen = Geom:new{ w = avail_w, h = body_h },
        scroll_bar_width = bar_w,
        show_parent = modal,
        padded_body,
    }
    local out = strip and VerticalGroup:new{ align = "left", strip, scroll } or scroll
    -- Every section's focusable row(s), in visual order, so the modal's
    -- FocusManager can chain dpad nav across the whole tab (see
    -- ReviewsModal:_assemble's handling of an ARRAY focus_tables).
    out.focus_tables = focus_tables
    -- The scroll the keys bring a focused row into view in
    -- (ReviewsModal:_scrollFocusIntoView).
    out.focus_scroll = scroll
    return out
end

-- Native "★★★★☆ 3.6 · 54 ratings · 14 reviews  [reload Refresh]" header row for
-- the Reviews tab, sitting above its own HTML review list (_buildReviewsTab
-- below). The summary used to be part of that HTML with an inline "Refresh"
-- <a> link; moved out to a native row so Refresh gets real tap feedback
-- (pixel-inverts while the fetch is in flight) and its label can match the
-- summary text's own (zoom-adjustable) font size, using the same small-button
-- style as the Icons Library's search/close buttons (bookshelf_chip_button).
-- _reviewKeys(above, btn, on_chips, rest) -> the keys' rows of a review tab's
-- top: the source switch's cells (above.seg_rows), its button (Refresh,
-- Edit) on the same row when it sits on the chips' row (on_chips), else a
-- row of its own; then rest's rows. Fresh tables: merging into the popup's
-- layout takes them over.
local function _reviewKeys(above, btn, on_chips, rest)
    local rows, seg = {}, above and above.seg_rows and above.seg_rows[1]
    if seg then
        local r = {}
        for i, c in ipairs(seg) do r[i] = c end
        if on_chips and btn then r[#r + 1] = btn end
        rows[#rows + 1] = r
    end
    if btn and not (seg and on_chips) then rows[#rows + 1] = { btn } end
    for _i, r in ipairs(rest or {}) do rows[#rows + 1] = r end
    return rows
end

function BookshelfWidget:_buildReviewsHeader(tab, modal, avail_w, refreshReviews, above)
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local VerticalSpan   = require("ui/widget/verticalspan")
    local font_size = (modal and modal.font_size) or 20
    local inset = (modal and modal._side_pad) or Space.px(28)
    local content_w = avail_w - 2 * inset

    -- Same read-only star glyphs as the Edit tab's Hardcover rating row, but
    -- sized to match the per-review stars below (REVIEW_CSS's ".stars"
    -- rule, "font-size: 1.15em" of the HTML body's base size) rather than
    -- the Edit tab's own "+4" -- the two rows sit one above the other here,
    -- so a size mismatch reads as inconsistent glyph weight.
    local STAR_FULL, STAR_HALF, STAR_EMPTY = "\xEF\x80\x85", "\xEF\x84\xA3", "\xEF\x80\x86"
    local star_face = BFont:getFace("symbols", font_size * 1.15)
    local text_face = BFont:getFace("cfont", font_size)

    local left = HorizontalGroup:new{ align = "center" }
    local data = tab.data
    local rating = data and tonumber(data.rating)
    if rating and rating > 0 then
        local halves = math.floor(rating * 2 + 0.5)  -- 0..10 half-units
        for i = 1, 5 do
            local glyph = STAR_EMPTY
            if halves >= 2 * i then glyph = STAR_FULL
            elseif halves == 2 * i - 1 then glyph = STAR_HALF end
            -- No per-star padding here (unlike the Edit tab's tappable "Your
            -- rating" stars, which need the extra gap as a bigger touch
            -- target) -- read-only, so they sit flush like the per-review
            -- star rows in the HTML below.
            left[#left + 1] = TextWidget:new{
                text = glyph, face = star_face, fgcolor = Blitbuffer.COLOR_BLACK }
        end
        left[#left + 1] = HorizontalSpan:new{ width = Space.px(6) }
        left[#left + 1] = TextWidget:new{
            text = string.format("%.1f", rating), face = text_face, fgcolor = Blitbuffer.COLOR_BLACK }
    end
    local function addStat(text)
        if #left > 0 then
            left[#left + 1] = TextWidget:new{
                text = "  \xC2\xB7  ", face = text_face, fgcolor = Blitbuffer.COLOR_BLACK }
        end
        left[#left + 1] = TextWidget:new{ text = text, face = text_face, fgcolor = Blitbuffer.COLOR_BLACK }
    end
    if data and tonumber(data.ratings_count) and tonumber(data.ratings_count) > 0 then
        local n = tonumber(data.ratings_count)
        addStat(n == 1 and _("1 rating") or string.format(_("%d ratings"), n))
    end
    if data and tonumber(data.reviews_count) and tonumber(data.reviews_count) > 0 then
        local n = tonumber(data.reviews_count)
        addStat(n == 1 and _("1 review") or string.format(_("%d reviews"), n))
    end

    -- Refresh chip: sized to the summary text's own line height so it reads as
    -- part of the same line, greyed while a fetch is in flight (black would
    -- say it is on, STYLE.md). The
    -- reload glyph is a Nerd Font PUA icon (nf-md-reload, U+EB52) rendered
    -- through the bundled "symbols" face -- a plain circular arrow, cleaner
    -- at this size than the stock document+arrow SVG icon.
    local refresh_btn = PopupKit.headerButton{
        text      = _("Refresh"),
        icon      = "\xEE\xAD\x92", -- nf-md-reload
        font_size = font_size,
        enabled   = not tab.busy,
        on_tap    = function() if not tab.busy then refreshReviews() end end,
    }

    -- "Include spoilers": only when Hardcover has spoiler reviews for the book;
    -- off with every popup (tab.show_spoilers is never saved).
    local spoilers = data and type(data.spoiler_reviews) == "table" and #data.spoiler_reviews > 0
    local spoiler_cell
    if spoilers and tab.toggleSpoilers then
        local box = HorizontalGroup:new{ align = "center",
            TextWidget:new{ text = tab.show_spoilers and "\xEE\xA0\xB1" or "\xEE\xA0\xB0", -- checkbox marked / blank
                face = BFont:getFace("symbols", font_size + 4), fgcolor = Blitbuffer.COLOR_BLACK },
            HorizontalSpan:new{ width = Space.px(8) },
            TextWidget:new{ text = _("Include spoilers"), face = text_face, fgcolor = Blitbuffer.COLOR_BLACK },
        }
        local bs = box:getSize()
        -- A switch, drawn again to show it: at once (STYLE.md).
        spoiler_cell = PopupKit.tapCell(box, bs.w, bs.h, function() tab.toggleSpoilers() end,
            nil, nil, true)
    end
    -- withSpoilers(line): the line with the switch at its right end, or
    -- under it when they don't fit side by side.
    local function withSpoilers(line)
        if not spoiler_cell then return line end
        local lw, bw = line and line:getSize().w or 0, spoiler_cell:getSize().w
        if lw == 0 then
            return HorizontalGroup:new{ align = "center",
                HorizontalSpan:new{ width = math.max(0, content_w - bw) }, spoiler_cell }
        end
        if lw + Space.px(20) + bw <= content_w then
            return HorizontalGroup:new{ align = "center", line,
                HorizontalSpan:new{ width = content_w - lw - bw }, spoiler_cell }
        end
        return VerticalGroup:new{ align = "left", line,
            VerticalSpan:new{ width = Space.px(6) }, spoiler_cell }
    end
    local left_w, right_w = left:getSize().w, refresh_btn:getSize().w
    -- Under the source chips: Refresh joins the chips' own row, and stays
    -- there once the summary arrives -- the summary is a second line on the
    -- same strip. (The caller then skips its separate `above`.)
    local spoiler_rows = spoiler_cell and { { spoiler_cell } } or nil
    if above then
        local merged = self:_chipsWithButton(above, refresh_btn, avail_w, inset)
        if merged and left_w == 0 and not spoiler_cell then
            return merged, true, _reviewKeys(above, refresh_btn, true)
        end
        local seg = above.seg
        if merged and seg then
            local chips_row = HorizontalGroup:new{ align = "center", seg,
                HorizontalSpan:new{ width = content_w - seg:getSize().w - right_w }, refresh_btn }
            return PopupKit.withShadow(FrameContainer:new{
                bordersize = 0, margin = 0, width = avail_w,
                background = PopupKit.STRIP_BG,
                padding_left = inset, padding_right = inset,
                padding_top = Space.px(10), padding_bottom = Space.px(10),
                VerticalGroup:new{ align = "left",
                    chips_row, VerticalSpan:new{ width = Space.px(10) }, withSpoilers(left_w > 0 and left or nil) },
            }, avail_w), true, _reviewKeys(above, refresh_btn, true, spoiler_rows)
        end
    end
    local gap = Space.px(10)
    local row
    if left_w > 0 and left_w + gap + right_w <= content_w then
        row = HorizontalGroup:new{ align = "center",
            left, HorizontalSpan:new{ width = content_w - left_w - right_w }, refresh_btn }
    elseif left_w > 0 then
        -- Doesn't fit side by side (narrow screen / large zoom) -- stack.
        row = VerticalGroup:new{ align = "left",
            left, VerticalSpan:new{ width = Space.px(6) }, refresh_btn }
    else
        -- No rating data yet (still loading) -- just the button, flush right
        -- where it'll end up once the summary text appears.
        row = HorizontalGroup:new{ align = "center",
            HorizontalSpan:new{ width = math.max(0, content_w - right_w) }, refresh_btn }
    end
    -- The switch on its own line under the summary and Refresh.
    if spoiler_cell then
        row = VerticalGroup:new{ align = "left", row,
            VerticalSpan:new{ width = Space.px(10) }, withSpoilers(nil) }
    end

    return PopupKit.withShadow(FrameContainer:new{
        bordersize = 0, margin = 0, width = avail_w,
        background = PopupKit.STRIP_BG,
        padding_left = inset, padding_right = inset,
        padding_top = Space.px(10), padding_bottom = Space.px(10),
        row,
    }, avail_w), false, _reviewKeys(above, refresh_btn, false, spoiler_rows)
end

-- _buildReviewsTab: the Reviews tab's body -- the native header above, then
-- the review-list HTML in its own scroller sized to whatever height the
-- header leaves. A dedicated ScrollHtmlWidget rather than the modal's shared
-- one, so this tab's own native header can sit above it without disturbing
-- the shared scroller's fixed height used by the other (headerless) HTML tabs.
-- Its source switch, Refresh and Include spoilers take the keys.
function BookshelfWidget:_buildReviewsTab(tab, modal, avail_w, avail_h, refreshReviews, above)
    local header, merged, keys = self:_buildReviewsHeader(tab, modal, avail_w, refreshReviews, above)
    local body = self:_headedHtmlBody(modal, avail_w, avail_h, header, tab.html,
                                      (not merged) and above or nil)
    if keys and #keys > 0 then body.focus_tables = { focusRow(keys) } end
    return body
end

-- _chipsWithButton(above, btn, avail_w, inset): the Reviews tab's source
-- chips with the header's button (Edit / Refresh) at the right end of the
-- same row, so the pair costs one row rather than two. nil when they do not
-- fit side by side.
function BookshelfWidget:_chipsWithButton(above, btn, avail_w, inset)
    local seg = above.seg
    if not seg then return nil end
    if seg:getSize().w + Space.px(10) + btn:getSize().w > avail_w - 2 * inset then return nil end
    return PopupKit.headerRow{ width = avail_w, inset = inset, left = seg, buttons = { btn } }
end

-- _headedHtmlBody(modal, avail_w, avail_h, header, html, above): a native
-- header row, then `html` in its own scroller sized to what is
-- left. `above` (optional) sits over the header: the Reviews tab's source
-- chips. Shared by Hardcover's reviews and the reader's own.
function BookshelfWidget:_headedHtmlBody(modal, avail_w, avail_h, header, html, above)
    local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
    local top = above and VerticalGroup:new{ align = "left", above, header } or header
    local header_h = top:getSize().h
    -- No rule between the header and the text: the popup draws lines only in
    -- its frame. Most of the shared body top padding is redundant under the
    -- header, so shrink it to a small residual rather than dropping it to 0
    -- (_buildSourcedBody's padding-top override, same technique).
    local css = modal._css .. string.format("\nbody { padding-top: %dpx; }", Space.px(8))
    -- Through the modal's _scroller, NOT a raw ScrollHtmlWidget: the stock
    -- widget claims every south swipe even with nothing above the fold, so
    -- swipe-down-to-close (issue 338) worked on every tab except this one.
    local opts = {
        html_body         = html or "<p></p>",
        css               = css,
        default_font_size = Screen:scaleBySize((modal and modal.font_size) or 20),
        width             = avail_w,
        height            = math.max(Screen:scaleBySize(80), avail_h - header_h),
        dialog            = modal,
    }
    local scroller = (modal and modal._scroller) and modal:_scroller(opts)
                     or ScrollHtmlWidget:new(opts)
    return VerticalGroup:new{ align = "left", top, scroller }
end

-- _buildMyReviewBody(book, modal, avail_w, avail_h, above): the reader's own
-- review (issues 238, 315), KOReader's summary.note, with an Edit button in
-- the header row where Hardcover's has Refresh. With no review yet, a
-- "Write a review" button there instead. Read fresh on every build, so a save
-- followed by rebuildTab shows the new text.
function BookshelfWidget:_buildMyReviewBody(book, modal, avail_w, avail_h, above)
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local VerticalSpan   = require("ui/widget/verticalspan")
    local Tokens         = require("lib/bookshelf_tokens")
    local font_size = (modal and modal.font_size) or 20
    local inset = (modal and modal._side_pad) or Space.px(28)
    local content_w = avail_w - 2 * inset
    local text_face = BFont:getFace("cfont", font_size)
    local review = self:_bookReview(book)
    local function edit()
        self:_editBookReview(book, function()
            if modal and modal.rebuildTab then modal:rebuildTab() end
        end)
    end
    local btn = PopupKit.headerButton{
        text      = review and _("Edit") or _("Write a review"),
        icon      = "\xEE\xAB\xAA", -- nf-md-pencil, U+EAEA
        font_size = font_size,
        on_tap    = edit,
    }
    if not review then
        -- The header row alone: a grey note where the review will be, the
        -- button at the right end like every tab's own action.
        local col = VerticalGroup:new{ align = "left" }
        local on_chips = above and self:_chipsWithButton(above, btn, avail_w, inset)
        col[#col + 1] = on_chips or PopupKit.headerRow{ width = avail_w, inset = inset, buttons = { btn } }
        col[#col + 1] = FrameContainer:new{
            bordersize = 0, margin = 0,
            padding_left = inset, padding_right = inset,
            padding_top = Space.px(16), padding_bottom = 0,
            TextWidget:new{ text = _("No review yet."), face = text_face,
                fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = content_w },
        }
        local used = 0
        for _i, w in ipairs(col) do used = used + w:getSize().h end
        if used < avail_h then col[#col + 1] = VerticalSpan:new{ width = avail_h - used } end
        local body = FrameContainer:new{ bordersize = 0, margin = 0, padding = 0,
            background = Blitbuffer.COLOR_WHITE, col }
        -- The source switch above it is not drawn here when the button
        -- has its own row: only the button then.
        body.focus_tables = { focusRow(on_chips and _reviewKeys(above, btn, true) or { { btn } }) }
        return body
    end
    -- Edit on the chips' row when they fit side by side, else a row of its
    -- own under them; the source switch and Edit take the keys.
    local on_chips = above and self:_chipsWithButton(above, btn, avail_w, inset)
    local header = on_chips or PopupKit.headerRow{ width = avail_w, inset = inset, buttons = { btn } }
    local body = self:_headedHtmlBody(modal, avail_w, avail_h, header, Tokens.myReviewHtml(review),
                                      (not on_chips) and above or nil)
    body.focus_tables = { focusRow(_reviewKeys(above, btn, on_chips ~= nil)) }
    return body
end

-- _buildBookCoverTab — the Cover tab body: a toolbar (device picker + online
-- search) above a paginated grid of candidate covers. Local candidates are
-- cached on `state` for the modal's life; online ones live there after a search.
-- Tapping a cell applies it immediately (self:_applyCoverCandidate). Returns the
-- body with .focus_tables set for dpad nav. `state` is the cross-rebuild upvalue
-- from _showBookDetail; `modal` the live ReviewsModal (== show_parent).
function BookshelfWidget:_buildBookCoverTab(book, show_parent, avail_w, avail_h, state, modal)
    local VerticalGroup   = require("ui/widget/verticalgroup")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan  = require("ui/widget/horizontalspan")
    local VerticalSpan    = require("ui/widget/verticalspan")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local FrameContainer  = require("ui/widget/container/framecontainer")
    local TextWidget      = require("lib/bookshelf_colour_text")
    local CoverApply      = require("lib/bookshelf_cover_apply")
    local CoverGridCell   = require("lib/bookshelf_cover_grid_cell")
    local Pagination      = require("lib/bookshelf_pagination")
    local SpineWidget     = require("lib/bookshelf_spine_widget")
    local bw = self
    -- show_parent IS the live ReviewsModal (see ReviewsModal:_activeBody). The
    -- `modal` upvalue from _showBookDetail is still nil during the modal's first
    -- _assemble (it's assigned only after ReviewsModal:new returns), so prefer
    -- show_parent -- always the current instance.
    modal = modal or show_parent

    -- The body must fill the SAME region the other tabs do: full body height
    -- (avail_h) and the same left/right content inset (_side_pad). avail_w is the
    -- full modal width; other tabs inset their content by _side_pad. Matching it
    -- keeps the modal frame the same size across tabs -- otherwise a shorter/
    -- wider Cover body shrinks + recentres the whole modal and leaves the prior
    -- tab's pixels around it (the reported painting glitch).
    local side_pad  = (show_parent and show_parent._side_pad) or Space.px(28)
    local content_w = avail_w - 2 * side_pad

    local _gettime = require("lib/bookshelf_gettime")
    local t0 = _gettime()
    if not state.local_candidates then
        state.local_candidates = CoverApply.localCandidates(book)
        logger.dbg(string.format("[bookshelf perf] Cover tab: localCandidates %.0fms (%d)",
            (_gettime() - t0) * 1000, #state.local_candidates))
    end
    local candidates = {}
    local seen_local = {}
    for _i, c in ipairs(state.local_candidates) do
        candidates[#candidates + 1] = c
        if c.filesize then
            seen_local[table.concat({ c.width or "?", c.height or "?", c.filesize }, "\1")] = true
        end
    end
    if type(state.online_candidates) == "table" then
        for _i, c in ipairs(state.online_candidates) do
            -- Skip an online result that IS a local candidate (e.g. the cover
            -- just applied from this very search, now showing as "Current
            -- cover") so it doesn't appear twice.
            local key = c.filesize
                and table.concat({ c.width or "?", c.height or "?", c.filesize }, "\1")
            if not (key and seen_local[key]) then
                candidates[#candidates + 1] = c
            end
        end
    end
    local total = #candidates

    -- Toolbar: the two ways in as the tab's header buttons, at the right
    -- end of the first row like every tab's own actions.
    local base     = (modal and modal.font_size) or 18
    local device_btn = PopupKit.headerButton{ text = _("Choose from device"),
        icon = "\xEE\xA5\x8E", font_size = base, -- folder-image
        on_tap = function() bw:_pickBookCoverFromDevice(book, modal, state) end }
    local online_btn = PopupKit.headerButton{ text = _("Search online\xE2\x80\xA6"),
        icon = "\xEE\xB8\x8D", font_size = base, -- search-web
        on_tap = function() bw:_searchOnlineCovers(book, state, modal) end }
    local strip = PopupKit.headerRow{ width = avail_w, inset = side_pad,
        buttons = { device_btn, online_btn } }
    local toolbar_h = strip:getSize().h

    -- Grid geometry: 2-4 columns by width; rows to fill the height.
    local gap      = Space.px(10)
    local min_cell = Screen:scaleBySize(120)
    local n_cols   = math.max(2, math.min(4, math.floor((content_w + gap) / (min_cell + gap))))
    local cell_w   = math.floor((content_w - gap * (n_cols - 1)) / n_cols)

    local caption_font = math.max(10, math.min((modal and modal.font_size) or 13, 15))
    local cap_h  = CoverGridCell.captionHeight(caption_font)
    local ring   = SpineWidget.SELECTED_BORDER
    -- Non-cover part of a cell (caption + gap + ring headroom top/bottom).
    local chrome = Space.px(4) + cap_h + 2 * ring

    local top_pad     = 0              -- the strip sits right under the tab bar
    local tb_gap      = Space.px(12)    -- gap below the strip
    -- Space reserved below the grid for the pagination row plus a standard gap
    -- beneath it (matching the pagination spacing used elsewhere) so the page
    -- nav sits just off the modal's Close/Open footer, not jammed against it.
    local nav_bottom_pad = Space.padding.fullscreen
    local nav_reserve = Screen:scaleBySize(44) + nav_bottom_pad
    local grid_avail_h = math.max(1, avail_h - top_pad - toolbar_h - tb_gap - nav_reserve)
    -- Pack as many rows as fit while each cover stays at least ~1.05x its width
    -- tall (still portrait), so the grid FILLS the body instead of one tall row
    -- with dead space below. Capped by the candidate count so a handful of
    -- candidates don't leave an empty trailing row.
    local rows = 1
    for r = 1, 4 do
        local ch = math.floor((grid_avail_h - gap * (r - 1)) / r)
        if (ch - chrome) >= math.floor(cell_w * 1.05) then rows = r end
    end
    rows = math.min(rows, math.max(1, math.ceil(total / n_cols)))
    local cell_h = math.floor((grid_avail_h - gap * (rows - 1)) / rows)
    -- Cap cell height to a natural cover (2:3) so a single row of one or two
    -- candidates renders normal-sized covers, not full-body-height slabs. The
    -- unused space becomes the trailing fill spacer below.
    local cell_cap = math.floor(cell_w * 1.5) + chrome
    if cell_h > cell_cap then cell_h = cell_cap end

    local page_size   = n_cols * rows
    local total_pages = math.max(1, math.ceil(total / math.max(1, page_size)))
    if state.page > total_pages then state.page = total_pages end
    if state.page < 1 then state.page = 1 end

    local col = VerticalGroup:new{ align = "center" }
    col[#col + 1] = VerticalSpan:new{ width = tb_gap }

    -- D-pad rows, top to bottom: the two buttons, then each grid row. focusRow
    -- takes a list of ROWS: a flat list made every cover cell a row of its own,
    -- so focus sat on an unpainted child and Press crashed (GitHub issue 361).
    local focus_tables = { focusRow({ { device_btn, online_btn } }) }
    if total == 0 then
        col[#col + 1] = CenterContainer:new{
            dimen = Geom:new{ w = content_w, h = math.max(cell_h, Screen:scaleBySize(80)) },
            TextWidget:new{
                text = _("No covers stored yet. Use Search online or Choose from device."),
                face = BFont:getFace("cfont", 15),
                max_width = content_w - Space.px(20),
            },
        }
    else
        -- Build the grid as a FIXED-height block (rows * cell_h) so the
        -- pagination row below sits at the same Y on every page -- a final page
        -- with fewer rows pads the remainder rather than pulling the nav up.
        local grid = VerticalGroup:new{ align = "center" }
        local grid_h = 0
        local start_i = (state.page - 1) * page_size
        for r = 0, rows - 1 do
            local has_any = false
            for c = 0, n_cols - 1 do
                if candidates[start_i + r * n_cols + c + 1] then has_any = true break end
            end
            if not has_any then break end  -- remaining rows are the block padding
            local row_group = HorizontalGroup:new{ align = "top" }
            local row_layout = {}
            for c = 0, n_cols - 1 do
                local idx = start_i + r * n_cols + c + 1
                local cand = candidates[idx]
                if cand then
                    local cell = CoverGridCell.new{
                        width = cell_w, height = cell_h, candidate = cand,
                        font_size = caption_font,
                        on_tap = function(cc) bw:_applyCoverCandidate(book, cc, modal, state) end,
                    }
                    row_group[#row_group + 1] = cell
                    row_layout[#row_layout + 1] = cell
                else
                    row_group[#row_group + 1] = HorizontalSpan:new{ width = cell_w }
                end
                if c < n_cols - 1 then
                    row_group[#row_group + 1] = HorizontalSpan:new{ width = gap }
                end
            end
            if #grid > 0 then
                grid[#grid + 1] = VerticalSpan:new{ width = gap }; grid_h = grid_h + gap
            end
            grid[#grid + 1] = row_group; grid_h = grid_h + cell_h
            if #row_layout > 0 then focus_tables[#focus_tables + 1] = focusRow({ row_layout }) end
        end
        local grid_block_h = rows * cell_h + (rows - 1) * gap
        if grid_h < grid_block_h then
            grid[#grid + 1] = VerticalSpan:new{ width = grid_block_h - grid_h }
        end
        col[#col + 1] = grid
    end

    if total_pages > 1 then
        local nav = Pagination.buildNav{
            page = state.page, total_pages = total_pages, show_parent = show_parent,
            -- Text chevrons: this nav lives inside the book-detail modal, whose
            -- cropping_widget routes icon-button flash through the raw
            -- widgetInvert/invertRect path that segfaulted on a PocketBook
            -- InkPad framebuffer. Text buttons use the bounds-safe repaint path.
            text_chevrons = true,
            on_goto = function(target)
                state.page = target
                if modal and modal.rebuildTab then modal:rebuildTab() end
            end,
        }
        local nav_h = nav:getSize().h
        -- Bottom-anchor the nav: push any leftover grid slack ABOVE it so it
        -- always sits exactly nav_bottom_pad above the footer, instead of the
        -- trailing fill piling up below it when the covers don't fill the
        -- height (which was making the gap balloon).
        local used = toolbar_h   -- the strip above the column
        for _i, ch in ipairs(col) do used = used + (ch.getSize and ch:getSize().h or 0) end
        local slack = avail_h - used - nav_h - nav_bottom_pad
        if slack > 0 then col[#col + 1] = VerticalSpan:new{ width = slack } end
        col[#col + 1] = CenterContainer:new{
            dimen = Geom:new{ w = content_w, h = nav_h }, nav,
        }
        col[#col + 1] = VerticalSpan:new{ width = nav_bottom_pad }
    end

    -- Pad the column to the full body height so the modal frame matches the
    -- other tabs (they size their scroller to avail_h). Then inset horizontally
    -- by side_pad. The white background erases the whole region on every
    -- (re)assemble, so switching to/from this tab leaves no stale pixels.
    -- Sum children directly rather than calling col:getSize() mid-build --
    -- VerticalGroup caches its size/offsets on first getSize(), so measuring the
    -- group before appending the spacer would freeze the short height and ignore
    -- the pad (the VerticalGroup getSize caching gotcha).
    local used_h = toolbar_h   -- the strip above the column
    for _i, ch in ipairs(col) do
        used_h = used_h + (ch.getSize and ch:getSize().h or 0)
    end
    if used_h < avail_h then
        col[#col + 1] = VerticalSpan:new{ width = avail_h - used_h }
    end
    local framed = FrameContainer:new{
        bordersize = 0, margin = 0, padding = 0,
        padding_left = side_pad, padding_right = side_pad,
        background = Blitbuffer.COLOR_WHITE,
        col,
    }
    -- The controls strip runs edge to edge above the inset column.
    framed = VerticalGroup:new{ align = "left", strip, framed }
    logger.dbg(string.format("[bookshelf perf] Cover tab: build %.0fms (%d covers)",
        (_gettime() - t0) * 1000, total))
    framed.focus_tables = focus_tables
    -- Expose the grid's pagination so the modal's horizontal swipe pages the
    -- covers first and only cycles tabs once you're off the end (see
    -- ReviewsModal:onSwipe). Absent when there's a single page.
    if total_pages > 1 then
        framed._pager = {
            page = state.page,
            total_pages = total_pages,
            goto_page = function(target)
                state.page = target
                if modal and modal.rebuildTab then modal:rebuildTab() end
            end,
        }
    end
    return framed
end

-- Apply a tapped candidate as the book's cover (or revert to embedded), then
-- close + reopen the modal on the Cover tab so the (cached) header thumbnail and
-- the grid rings reflect the new active cover. Immediate-apply per the design.
-- `state` is the Cover tab's cross-rebuild table, threaded through the reopen.
function BookshelfWidget:_applyCoverCandidate(book, candidate, modal, state)
    if not (book and book.filepath and candidate) then return end
    local CoverApply = require("lib/bookshelf_cover_apply")
    local ok, err
    if candidate.kind == "embedded" then
        ok, err = CoverApply.revertToEmbedded(book.filepath)
        -- BIM's cached cover_bb may still hold the previously-applied cover:
        -- while a custom cover was active, a shelf re-extract cached IT (BIM
        -- extracts the active DocSettings custom cover). With the custom cover
        -- now removed, the render falls back to that stale cover_bb, so the
        -- header/hero keep showing the old cover after "revert to embedded".
        -- Force a fresh extraction (custom gone -> embedded) so cover_bb is
        -- correct before the reopened modal's buildBookMeta reads it. delete +
        -- extract mirrors the stale-sweep's proven re-extract pattern.
        if ok then
            pcall(function()
                local BIM = require("bookinfomanager")
                if BIM and BIM.extractBookInfo then
                    local sw = Screen:getWidth()
                    local cw = math.max(1, math.floor(sw * 0.5))
                    if BIM.deleteBookInfo then BIM:deleteBookInfo(book.filepath) end
                    Repo.forgetBook(book.filepath)
                    BIM:extractBookInfo(book.filepath,
                        { max_cover_w = cw, max_cover_h = math.floor(cw * 1.5) })
                end
            end)
        end
    elseif not candidate.local_path then
        self:_hardcoverToast(_("That cover is unavailable"))
        return
    else
        ok, err = CoverApply.apply(book.filepath, candidate.local_path,
                                   { label = candidate.source_label })
    end
    if not ok then
        self:_hardcoverToast(err and tostring(err) or _("Couldn't set the cover"))
        return
    end
    -- Stop Hardcover auto-injecting its own cover over a manual pick on linked
    -- books (flag-only; the sidecar file is already handled here).
    local ok_hc, Hardcover = pcall(require, "lib/bookshelf_hardcover")
    if ok_hc and Hardcover and Hardcover.isAvailable and Hardcover.isAvailable()
            and Hardcover.getLink and Hardcover.getLink(book.filepath)
            and Hardcover.markUseCover then
        pcall(Hardcover.markUseCover, book.filepath, false)
    end
    self:_refreshSingleBookCover(book.filepath, "cover-picker")

    -- Keep the grid order stable across the reopen. Re-deriving the local list
    -- inserts a new front-of-list "Current cover" (+ "Previous cover") and
    -- drops the applied online result from its slot, so the whole grid
    -- reshuffled on every apply. Instead, when the tapped candidate is one
    -- that's already on screen, reuse the cached lists and just move the active
    -- ring onto it -- dropping only entries whose file has since vanished (the
    -- removed custom cover after a revert) so no blank tile lingers. The fresh
    -- "Current cover"/"Previous cover" entries re-derive on the next open. An
    -- off-grid apply (device file picker) isn't in the lists, so fall back to
    -- re-deriving there or the new cover wouldn't appear at all.
    if type(state) == "table" then
        local function inList(list)
            if type(list) == "table" then
                for _i, c in ipairs(list) do if c == candidate then return true end end
            end
            return false
        end
        if inList(state.local_candidates) or inList(state.online_candidates) then
            local function reflag(list)
                if type(list) ~= "table" then return list end
                local kept = {}
                for _i, c in ipairs(list) do
                    if c.kind == "embedded" or CoverApply.fileSize(c.local_path) then
                        c.is_active = (c == candidate)
                        kept[#kept + 1] = c
                    end
                end
                return kept
            end
            state.local_candidates  = reflag(state.local_candidates)
            state.online_candidates = reflag(state.online_candidates)
        else
            state.local_candidates = nil  -- off-grid pick: re-derive so it shows
        end
    end
    local bw = self
    local fresh = Repo.buildBookMeta(book.filepath, { want_cover = true }) or book
    if modal then UIManager:close(modal) end
    UIManager:nextTick(function()
        bw:_showBookDetail(fresh, { active = "cover", cover_state = state })
    end)
    self:_hardcoverToast(candidate.kind == "embedded"
        and _("Reverted to embedded cover") or _("Cover updated"))
end

-- File picker (any image) -> apply as cover. Same PathChooser shape as
-- _pickFolderImage; routes through _applyCoverCandidate so refresh/reopen match.
function BookshelfWidget:_pickBookCoverFromDevice(book, modal, state)
    if not (book and book.filepath) then return end
    local PathChooser = require("ui/widget/pathchooser")
    local ImageSource = require("lib/bookshelf_image_source")
    local bw = self
    local start_path = require("lib/bookshelf_home_dir").get()
        or (book.filepath:match("^(.*)/[^/]+$")) or "/"
    UIManager:show(PathChooser:new{
        title            = _("Choose cover image"),
        path             = start_path,
        select_directory = false,
        select_file      = true,
        show_files       = true,
        file_filter      = function(file) return ImageSource.isImageFile(file) end,
        onConfirm        = function(image_path)
            bw:_applyCoverCandidate(book,
                { kind = "device", local_path = image_path, source_label = _("Device") },
                modal, state)
        end,
    })
end

-- "Search online" -> fetch candidates (Wi-Fi-gated, user-initiated), then drop
-- them into the grid. Wrapped in Trapper so per-source progress shows and the
-- user can cancel; never auto-fetches (privacy invariant).
function BookshelfWidget:_searchOnlineCovers(book, state, modal)
    local CoverFetch = require("lib/bookshelf_cover_fetch")
    local bw = self
    CoverFetch.runWhenOnline(function()
        local CoverSources = require("lib/bookshelf_cover_sources")
        local ok_t, Trapper = pcall(require, "ui/trapper")
        local function run()
            local results = CoverSources.searchOnline(book)
            state.online_candidates = results
            state.page = 1
            if modal and not modal._dismissed and modal.rebuildTab then
                modal:rebuildTab()
            end
            if not results or #results == 0 then
                bw:_hardcoverToast(_("No cover matches found"))
            end
        end
        if ok_t and Trapper and Trapper.wrap then
            Trapper:wrap(run)
        else
            run()
        end
    end, function(err)
        bw:_hardcoverToast(_("Cover search failed"))
        logger.warn("[bookshelf cover] online search error", tostring(err))
    end)
end

-- _showBookDetail(book, opts) — the combined book-detail popup, a tabbed window:
-- the book/Hardcover Description tab(s), a Hardcover Reviews tab when linked,
-- a Tags tab (all the author / series / collections / genres / folder pills,
-- tappable to drill in), and an Edit tab (the book actions, immediate-commit
-- -- replaces the long-press ButtonDialog menu) LAST, since it's reached for
-- less often than the others. One tab body is mounted at a time, so the
-- native scrollers never fight each other. Replaces the separate description
-- / reviews modals and the standalone tags sheet.
-- opts.active = "edit" | "tags" | "reviews" picks the starting tab (default:
-- description, else Edit); opts.on_close fires once on dismiss.
function BookshelfWidget:_showBookDetail(book, opts)
    opts = opts or {}
    if not book or not book.filepath then return end
    -- Remote (OPDS) records have no sidecar, no collections and no file to act
    -- on, so every tab here would be inert at best and a file op on a
    -- pseudo-path at worst (the Edit tab offers Delete). Long-press gets the
    -- same read-only viewer the tap path shows. Path-prefix match, so a
    -- hero-hydrated record with its flags stripped is caught too.
    if self:_isRemoteRecord(book) then
        if self:_sourceRemote(book) then self:_showSourceInfo(book) return end
        self:_showRemoteBookInfo(book)
        return
    end
    local ReadCollection = require("readcollection")
    local in_collections = ReadCollection.getCollectionsWithFile
        and ReadCollection:getCollectionsWithFile(book.filepath) or {}
    -- Favourites isn't editable through the Collection Manager (it has its
    -- own ★ toggle, see bookshelf_collection_manager's _orderedNames) and
    -- Save there doesn't preserve memberships outside its own list -- so
    -- don't show it as a collection pill in the Tags tab, where it would sit
    -- right above that Edit button.
    in_collections[ReadCollection.default_collection_name] = nil
    -- All categories (like the long-press menu); close_cb nil -- we close the
    -- popup explicitly so the drilldown tears the stack down before navigating.
    local pill_specs = self:_buildPillSpecs(book, in_collections, nil, nil)

    local modal  -- forward ref so a pill tap closes the popup before navigating

    -- Genre-source switching (Tags tab, Embedded/Hardcover chips) is cheap to
    -- preview live -- just a persisted preference write + a local pill-list
    -- swap -- but the shelf-wide consequences (which genre set this book
    -- contributes to elsewhere: the shelves it appears on, its hero tags)
    -- require invalidating the shared light-meta cache and a full shelf
    -- _rebuild. [bookshelf perf] logging showed that pair costing ~600-900ms,
    -- ~90% of a chip tap, entirely behind this modal while the user is just
    -- previewing sources. Deferred to modal close (Close or Open both route
    -- through onClose), and only paid if the source actually ended up
    -- different from what it was when the modal opened.
    local genre_source_at_open, genre_source_changed
    -- The Tags tab's edit mode, kept across its rebuildTab runs.
    local tags_editing = false

    local tabs = {}
    local edit_idx, tags_idx, desc_idx, reviews_idx, cover_idx, highlights_idx
    -- Cover tab's cross-rebuild state (current page, cached candidate lists).
    -- An upvalue so pagination taps and "Search online" survive the tab's
    -- rebuildTab (which re-invokes the widget_builder). An apply tears the modal
    -- down and reopens; opts.cover_state carries this table across that reopen
    -- so a completed online search isn't lost (re-searching would re-download
    -- every candidate just to try a second cover).
    local cover_tab_state = (type(opts.cover_state) == "table" and opts.cover_state)
        or { page = 1 }

    -- Edit tab spec: the book actions (the old long-press menu), immediate-
    -- commit, scrollable. show_parent is the live modal instance during
    -- build. Placed into `tabs` LAST (after Description/Reviews/Tags below)
    -- so it renders as the final tab, not the first.
    local edit_tab = {
        id = "edit",
        label = _("Edit"),
        widget_builder = function(avail_w, avail_h, show_parent)
            return self:_buildBookEditTab(book, show_parent, avail_w, avail_h)
        end,
    }

    -- Tags tab (appended LAST, after description + reviews): the pill set split
    -- into sections under the same black heading bars as the Edit tab (Author /
    -- Series / Collections / Genres / Folder), scrollable, each pill tappable
    -- (closes the popup then drills). Built lazily as a native widget body.
    local TAG_SECTIONS = {
        { cat = "author",      title = _("Author(s)") },
        { cat = "series",      title = _("Series") },
        { cat = "collections", title = _("Collections") },
        { cat = "genres",      title = _("Genres") },
        { cat = "folder",      title = _("Folder") },
    }
    local tags_tab
    if #pill_specs > 0 then
        tags_tab = {
            id = "tags",
            label = _("Tags"),
            widget_builder = function(avail_w, avail_h, show_parent)
                local FrameContainer = require("ui/widget/container/framecontainer")
                local HorizontalSpan = require("ui/widget/horizontalspan")
                -- Group the specs by category, wrapping each tap to close first.
                local by_cat = {}
                for _i, s in ipairs(pill_specs) do
                    local cat  = s.cat or "folder"
                    local orig = s.on_tap
                    by_cat[cat] = by_cat[cat] or {}
                    by_cat[cat][#by_cat[cat] + 1] = {
                        label  = s.label,
                        coll   = s.coll,
                        on_tap = orig and function()
                            if modal then UIManager:close(modal) end
                            orig()
                        end or nil,
                    }
                end
                local lpad  = (show_parent and show_parent._side_pad)
                    or Space.px(20)
                local bar_w = SnugScroll.widen(Screen:scaleBySize(3))   -- flush snug scrollbar
                local base  = (show_parent and show_parent.font_size) or 18
                local pills_w   = avail_w - 2 * lpad - bar_w
                -- Every section's focusable row(s), in visual top-to-bottom
                -- order -- pillsFrame and the Edit headings register into this
                -- as they're called, so each section's own call site doesn't
                -- need to change. See ReviewsModal:_assemble's handling of an
                -- ARRAY focus_tables (bookshelf_reviews_modal.lua).
                local focus_tables = {}
                local function pillsFrame(specs, top_pad, ink)
                    local pills, focus_rows = self:_buildPillGroup(specs, pills_w, 9999, base, "left",
                        Space.px(8), nil, ink, PopupKit.BORDER)
                    if focus_rows and #focus_rows > 0 then
                        focus_tables[#focus_tables + 1] = focusRow(focus_rows)
                    end
                    return FrameContainer:new{
                        bordersize = 0, margin = 0,
                        padding_left = lpad, padding_right = lpad,
                        padding_top = top_pad or 0,
                        -- The next heading brings its own space above it
                        -- (self:_sectionHeadingBar), so only a little here.
                        padding_bottom = Space.px(4),
                        pills,
                    }
                end
                -- One Edit button for the whole tab, at the right end of the
                -- first heading. Editing puts a cross in each tag that can be
                -- removed (tap removes it) and a "+ Add" after each editable
                -- group; tags that can't be edited here go grey. Done ends it.
                local function heading(title)
                    return self:_sectionHeadingBar(title, avail_w, base, lpad)
                end
                local function editStrip()
                    local btn = PopupKit.headerButton{
                        text      = tags_editing and _("Done") or _("Edit"),
                        icon      = (not tags_editing) and "\xEE\xAB\xAA" or nil, -- nf-md-pencil
                        font_size = base,
                        inverted  = tags_editing,
                        on_tap    = function()
                            tags_editing = not tags_editing
                            if modal and modal.rebuildTab then modal:rebuildTab() end
                        end,
                    }
                    focus_tables[#focus_tables + 1] = focusRow({ { btn } })
                    return PopupKit.headerRow{ width = avail_w, inset = lpad, buttons = { btn } }
                end
                -- Edit mode's version of a group: each removable tag gets a
                -- cross and removes itself on tap; "+ Add" goes last.
                local CROSS = "\xE2\x9C\x95" -- U+2715
                local function editSpecs(list, on_remove, on_add)
                    local out = {}
                    for _i = 1, #list do
                        local it = list[_i]
                        out[#out + 1] = { label = it.label, trailing = CROSS,
                            on_tap = function() on_remove(it) end }
                    end
                    out[#out + 1] = { label = "+ " .. _("Add"), on_tap = on_add }
                    return out
                end
                -- Tags that can't be edited here, while editing: grey, inert.
                local function inertSpecs(list)
                    local out = {}
                    for _i = 1, #(list or {}) do out[_i] = { label = list[_i].label } end
                    return out
                end
                -- A section's pills, or a grey note when it has none (e.g. "Not
                -- in any collection."), or nothing.
                local function pillsOrNote(specs, empty_msg)
                    if specs and #specs > 0 then return pillsFrame(specs) end
                    if empty_msg and empty_msg ~= "" then
                        return FrameContainer:new{
                            bordersize = 0, margin = 0,
                            padding_left = lpad, padding_right = lpad,
                            padding_top = 0, padding_bottom = Space.px(4),
                            TextBoxWidget:new{ text = empty_msg,
                                face = BFont:getFace("cfont", base),
                                fgcolor = Blitbuffer.COLOR_DARK_GRAY, width = pills_w },
                        }
                    end
                end
                -- Author(s) and Series side by side, each under its own
                -- heading, when both sit on one line and fit across; nil
                -- otherwise (they stack as the other sections do).
                local series_paired = false
                local function sideBySide(title_a, list_a, title_b, list_b)
                    if not (list_b and #list_b > 0) then return nil end
                    local gap = Space.px(40)
                    local ink = tags_editing and Blitbuffer.COLOR_GRAY or nil
                    local function block(title, list)
                        local pills, rows = self:_buildPillGroup(
                            tags_editing and inertSpecs(list) or list, pills_w, 9999, base, "left",
                            Space.px(8), nil, ink, PopupKit.BORDER)
                        if rows and #rows > 1 then return nil end
                        return VerticalGroup:new{ align = "left",
                            self:_sectionHeadingBar(title, pills_w, base, 0), pills }, rows
                    end
                    local a, rows_a = block(title_a, list_a)
                    local b, rows_b = block(title_b, list_b)
                    if not (a and b) or a:getSize().w + gap + b:getSize().w > pills_w then return nil end
                    local row = {}
                    for _i, w in ipairs(rows_a and rows_a[1] or {}) do row[#row + 1] = w end
                    for _i, w in ipairs(rows_b and rows_b[1] or {}) do row[#row + 1] = w end
                    if #row > 0 then focus_tables[#focus_tables + 1] = focusRow({ row }) end
                    return FrameContainer:new{
                        bordersize = 0, margin = 0,
                        padding_left = lpad, padding_right = lpad,
                        padding_top = 0, padding_bottom = Space.px(4),
                        HorizontalGroup:new{ align = "top", a, HorizontalSpan:new{ width = gap }, b },
                    }
                end
                -- The strip stays put above the scrolling sections, as on
                -- the other tabs.
                local strip = editStrip()
                local vg = VerticalGroup:new{ align = "left" }
                for _s = 1, #TAG_SECTIONS do
                    local sec = TAG_SECTIONS[_s]
                    if sec.cat == "genres" then
                        -- Genres are special: a source chip bar (Embedded /
                        -- Calibre / Hardcover) over the SELECTED source's genres.
                        -- Picking a source persists a per-book preference and
                        -- re-resolves genres app-wide.
                        local srcs = book.genre_sources or {}
                        local function has(k) return type(srcs[k]) == "table" and #srcs[k] > 0 end
                        -- Always render the Genres section (even with no genres in
                        -- any source) so its inline Edit button stays reachable to
                        -- add the first tag -- previously it was hidden entirely,
                        -- leaving no way to add tags to an untagged book.
                        do
                            local pref = BookshelfSettings.genreSource
                                and BookshelfSettings.genreSource(book.filepath)
                            local active = (pref and (has(pref) or pref == "embedded") and pref)
                                or (has("hardcover") and "hardcover")
                                or (has("calibre")  and "calibre")
                                or "embedded"
                            -- Captured once: the widget_builder re-runs on every
                            -- modal:rebuildTab() (each chip tap), so `active` itself
                            -- already reflects the latest pick by the second run --
                            -- genre_source_at_open must only ever be set from the
                            -- FIRST run to stay a true "at open" baseline.
                            if genre_source_at_open == nil then
                                genre_source_at_open = active
                            end
                            vg[#vg + 1] = heading(sec.title)
                            -- Embedded is always offered (it's the editable source);
                            -- Calibre / Hardcover only when that source has genres.
                            local SRC = {
                                { key = "embedded",  label = _("Embedded") },
                                { key = "calibre",   label = _("Calibre") },
                                { key = "hardcover", label = _("Hardcover") },
                            }
                            local items = {}
                            for _j = 1, #SRC do
                                if SRC[_j].key == "embedded" or has(SRC[_j].key) then
                                    items[#items + 1] = SRC[_j]
                                end
                            end
                            -- Pills for the active source's genres. When Embedded
                            -- is active they're editable: long-press removes a tag
                            -- and a trailing "+ Add" pill prompts for a new one.
                            -- Edits go to the shared KOReader Keywords override.
                            local editable = (active == "embedded")
                            -- The source-chip strip (Embedded/Calibre/Hardcover)
                            -- is built at the render tail below, because the Edit
                            -- button rides its row and needs editGenres (defined
                            -- further down) as its handler.
                            local function applyEdit(new_list)
                                Repo.setEmbeddedGenres(book.filepath, new_list)
                                book.genre_sources = book.genre_sources or {}
                                book.genre_sources.embedded = new_list
                                if active == "embedded" then
                                    book.genres = (#new_list > 0) and new_list or nil
                                end
                                self:_rebuild(); UIManager:setDirty(self, "ui")
                                if modal and modal.rebuildTab then modal:rebuildTab() end
                            end
                            local function withoutGenre(gname)
                                local new = {}
                                for _g2 = 1, #(srcs[active] or {}) do
                                    if srcs[active][_g2] ~= gname then new[#new + 1] = srcs[active][_g2] end
                                end
                                return new
                            end
                            local function addOne(name)
                                name = (name or ""):gsub("^%s+", ""):gsub("%s+$", "")
                                if name == "" then return end
                                local new = {}
                                local dup = false
                                for _g2 = 1, #(srcs[active] or {}) do
                                    new[#new + 1] = srcs[active][_g2]
                                    if srcs[active][_g2]:lower() == name:lower() then dup = true end
                                end
                                if not dup then new[#new + 1] = name end
                                applyEdit(new)
                            end
                            local function newTagDialog()
                                local InputDialog = require("ui/widget/inputdialog")
                                local idlg
                                idlg = InputDialog:new{
                                    title = _("New tag"), input = "",
                                    buttons = {{
                                        { text = _("Cancel"), id = "close",
                                          callback = function() UIManager:close(idlg) end },
                                        { text = _("Add"), is_enter_default = true,
                                          callback = function()
                                            local v = idlg:getInputText()
                                            UIManager:close(idlg); addOne(v)
                                          end },
                                    }},
                                }
                                UIManager:show(idlg)
                                idlg:onShowKeyboard()
                            end
                            -- Multi-select editor (mirrors the collections "Edit…"
                            -- model): the library's genre list UNION the book's
                            -- current tags, shown in the searchable grid picker
                            -- with the current tags pre-selected (inverted cells).
                            -- Tap toggles a cell, "New tag…" adds a novel one to
                            -- the selection, "Apply" commits the whole set in one
                            -- write. Falls back to free-text add if the modal
                            -- can't load.
                            local function editGenres()
                                local ok_lm, LibraryModal = pcall(require, "lib/bookshelf_library_modal")
                                if not (ok_lm and LibraryModal and LibraryModal.new) then
                                    newTagDialog(); return
                                end
                                local current = srcs[active] or {}
                                -- selection set: lowercase key -> canonical value.
                                local sel = {}
                                for _i = 1, #current do sel[current[_i]:lower()] = current[_i] end
                                -- candidates = current tags + library genres, deduped.
                                local choices, seen = {}, {}
                                local function addChoice(value, count)
                                    if not value or value == "" then return end
                                    local k = value:lower()
                                    if seen[k] then return end
                                    seen[k] = true
                                    choices[#choices + 1] = { value = value, label = value, count = count }
                                end
                                for _i = 1, #current do addChoice(current[_i]) end
                                local all = Repo.getGroupChoices and Repo.getGroupChoices("genre") or {}
                                for _i = 1, #all do addChoice(all[_i].value, all[_i].count) end
                                local function sortChoices()
                                    table.sort(choices, function(a, b)
                                        return (a.label or ""):lower() < (b.label or ""):lower() end)
                                end
                                sortChoices()
                                local query, visible = nil, choices
                                local function recompute()
                                    if not query or query == "" then visible = choices; return end
                                    visible = {}
                                    for _i = 1, #choices do
                                        if (choices[_i].label or ""):lower():find(query:lower(), 1, true) then
                                            visible[#visible + 1] = choices[_i]
                                        end
                                    end
                                end
                                local modal2
                                local function commit()
                                    -- Retained current tags keep their order; newly
                                    -- selected ones append in (sorted) candidate order.
                                    local final, kept = {}, {}
                                    for _i = 1, #current do
                                        local k = current[_i]:lower()
                                        if sel[k] then final[#final + 1] = current[_i]; kept[k] = true end
                                    end
                                    for _i = 1, #choices do
                                        local v = choices[_i].value
                                        if sel[v:lower()] and not kept[v:lower()] then
                                            final[#final + 1] = v; kept[v:lower()] = true
                                        end
                                    end
                                    UIManager:close(modal2)
                                    applyEdit(final)
                                end
                                local function promptNewTag()
                                    local InputDialog = require("ui/widget/inputdialog")
                                    local idlg
                                    idlg = InputDialog:new{
                                        title = _("New tag"), input = "",
                                        buttons = {{
                                            { text = _("Cancel"), id = "close",
                                              callback = function() UIManager:close(idlg) end },
                                            { text = _("Add"), is_enter_default = true,
                                              callback = function()
                                                local v = (idlg:getInputText() or "")
                                                    :gsub("^%s+", ""):gsub("%s+$", "")
                                                UIManager:close(idlg)
                                                if v ~= "" then
                                                    addChoice(v); sel[v:lower()] = v
                                                    sortChoices(); recompute()
                                                    if modal2 then modal2.page = 1; modal2:refresh() end
                                                end
                                              end },
                                        }},
                                    }
                                    UIManager:show(idlg)
                                    idlg:onShowKeyboard()
                                end
                                modal2 = LibraryModal:new{ config = {
                                    title = _("Edit tags"),
                                    search_placeholder = function() return _("Search\xE2\x80\xA6") end,
                                    on_search_submit = function(q)
                                        query = q; recompute()
                                        if modal2 then modal2.page = 1; modal2:refresh() end
                                    end,
                                    grid_cols = 2,
                                    cells_per_page = function()
                                        return Screen:getWidth() > Screen:getHeight() and 8 or 10
                                    end,
                                    item_count = function() return #visible end,
                                    item_at = function(idx) return visible[idx] end,
                                    cell_renderer = function(item, dimen)
                                        return require("lib/bookshelf_picker_cell").render(item, dimen,
                                            { selected = sel[(item.value or ""):lower()] ~= nil })
                                    end,
                                    -- A tick marks it at once (no pressed look first).
                                    select_on_tap = true,
                                    on_cell_tap = function(item)
                                        local k = (item.value or ""):lower()
                                        if sel[k] then sel[k] = nil else sel[k] = item.value end
                                        if modal2 then modal2:refresh() end
                                    end,
                                    -- Same layout as the collection editor: "+ New
                                    -- tag" on the strip, Cancel/Save in the footer.
                                    header_actions = { { label = "+ " .. _("New tag"), on_tap = promptNewTag } },
                                    footer_rows = {
                                        {
                                            { label = _("Cancel"),
                                              on_tap = function() UIManager:close(modal2) end },
                                            { label = _("Save"), primary = true, on_tap = commit },
                                        },
                                    },
                                } }
                                -- Cancel closes modal2 without ever calling applyEdit, so
                                -- nothing else clears the "Edit…" pill's tap-feedback invert
                                -- left over from opening this modal -- rebuild unconditionally
                                -- on any close (mirrors the collection editor's on_close),
                                -- not just the Save path.
                                local orig_on_close_widget = modal2.onCloseWidget
                                modal2.onCloseWidget = function(w)
                                    orig_on_close_widget(w)
                                    self:_rebuild(); UIManager:setDirty(self, "ui")
                                    if modal and modal.rebuildTab then modal:rebuildTab() end
                                end
                                UIManager:show(modal2)
                            end
                            -- Pin this genre as a nav chip (global -- surfaces
                            -- every book with the genre), mirroring the collection
                            -- "Pin to shelf menu". Splices the chip after the current
                            -- one and switches to it, like the stack-hold pin.
                            local function pinGenreChip(gname)
                                local TabModel = require("lib/bookshelf_tab_model")
                                local tabs = TabModel.load()
                                local n = 1
                                while true do
                                    local cand, taken = "custom_" .. n, false
                                    for _i = 1, #tabs do
                                        if tabs[_i].id == cand then taken = true; break end
                                    end
                                    if not taken then break end
                                    n = n + 1
                                end
                                local new_id = "custom_" .. n
                                TabModel.insertAfter(tabs, self.chip, {
                                    id = new_id, label = gname, icon = nil,
                                    source = { kind = "genre", id = gname },
                                    filter = {},
                                    -- Most-recently-opened first (same default as
                                    -- a pinned collection chip), not the Genres
                                    -- tab's surname/series ordering.
                                    sort_priority = { { key = "last_opened", reverse = true } },
                                    enabled = true,
                                })
                                TabModel.save(tabs)
                                if modal then UIManager:close(modal) end
                                self:_clearDpadFocus()
                                self._drilldown_path = {}
                                self.chip = new_id
                                self._cursor = 1
                                self:_syncPageFromCursor()
                                BookshelfSettings.saveDeferred("active_chip", new_id)
                                Repo.invalidateBookCache("create-chip")
                                self:_rebuild(); UIManager:setDirty(self, "ui")
                            end
                            -- Rename this book's copy of the tag (per-book: edits
                            -- the Embedded keywords -- genres aren't a global entity
                            -- to rename across books). Replaces in place; a rename
                            -- onto an existing tag just collapses into it.
                            local function renameTag(gname)
                                local InputDialog = require("ui/widget/inputdialog")
                                local idlg
                                idlg = InputDialog:new{
                                    title = _("Rename tag"), input = gname,
                                    input_hint = _("New name"),
                                    buttons = {{
                                        { text = _("Cancel"), id = "close",
                                          callback = function() UIManager:close(idlg) end },
                                        { text = _("Rename"), is_enter_default = true,
                                          callback = function()
                                            local newn = (idlg:getInputText() or "")
                                                :gsub("^%s+", ""):gsub("%s+$", "")
                                            UIManager:close(idlg)
                                            if newn == "" or newn == gname then return end
                                            local new, seen = {}, {}
                                            for _g2 = 1, #(srcs[active] or {}) do
                                                local g = srcs[active][_g2]
                                                local v = (g == gname) and newn or g
                                                if not seen[v:lower()] then
                                                    new[#new + 1] = v; seen[v:lower()] = true
                                                end
                                            end
                                            applyEdit(new)
                                          end },
                                    }},
                                }
                                UIManager:show(idlg)
                                idlg:onShowKeyboard()
                            end
                            -- Long-press menu, mirroring the collection editor's
                            -- hold menu. Editable (Embedded) source gets the full
                            -- 2x2 (Rename / Pin / Delete / Cancel); read-only
                            -- sources get Pin / Cancel only.
                            local function holdMenu(gname)
                                local ButtonDialog = require("ui/widget/buttondialog")
                                local hold_dialog
                                local function hclose() UIManager:close(hold_dialog) end
                                local function doDelete()
                                    hclose()
                                    local ConfirmBox = require("ui/widget/confirmbox")
                                    UIManager:show(ConfirmBox:new{
                                        text = T(_("Remove the tag \"%1\" from this book?"), gname),
                                        ok_text = _("Remove"),
                                        ok_callback = function() applyEdit(withoutGenre(gname)) end,
                                    })
                                end
                                local buttons
                                if editable then
                                    buttons = {
                                        { { text = _("Rename"),
                                            callback = function() hclose(); renameTag(gname) end },
                                          { text = _("Pin to shelf menu"),
                                            callback = function() hclose(); pinGenreChip(gname) end } },
                                        { { text = "\xE2\x9C\x95 " .. _("Delete"), callback = doDelete },
                                          { text = _("Cancel"), callback = hclose } },
                                    }
                                else
                                    buttons = {
                                        { { text = _("Pin to shelf menu"),
                                            callback = function() hclose(); pinGenreChip(gname) end },
                                          { text = _("Cancel"), callback = hclose } },
                                    }
                                end
                                hold_dialog = ButtonDialog:new{
                                    title = _("Edit tag: ") .. gname,
                                    title_align = "center",
                                    use_info_style = false,
                                    width = math.floor(Screen:getWidth() * 0.7),
                                    buttons = buttons,
                                }
                                require("lib/bookshelf_gesture_zones").passSwipesOn(hold_dialog)
                                UIManager:show(hold_dialog)
                            end
                            local gpills = {}
                            for _g = 1, #(srcs[active] or {}) do
                                local gname = srcs[active][_g]
                                gpills[#gpills + 1] = {
                                    label  = gname,
                                    on_tap = function()
                                        if modal then UIManager:close(modal) end
                                        local group = Repo.findGroup("genre", gname)
                                            or { kind = "genre", series_name = gname,
                                                 books = { book }, latest = 0 }
                                        self._drilldown_path = {}
                                        self:_expandGenre(group, true)
                                    end,
                                    on_hold = function() holdMenu(gname) end,
                                }
                            end
                            -- Source switch (Embedded/Calibre/Hardcover) as its
                            -- own row when there's more than one source.
                            if #items > 1 then
                                local chip_cb = function(key)
                                    -- The expensive part (light-meta invalidation + a full
                                    -- shelf _rebuild -- ~600-900ms, ~90% of a tap) is
                                    -- deferred to modal close (see genre_source_changed);
                                    -- only the cheap per-book caches refresh now.
                                    BookshelfSettings.setGenreSource(book.filepath, key)
                                    Repo.invalidateBookCache("genre-source")
                                    genre_source_changed = (key ~= genre_source_at_open)
                                    if modal and modal.rebuildTab then modal:rebuildTab() end
                                end
                                local source_chips, chips_focus_rows =
                                    self:_segmentedChips(items, active, chip_cb, base, lpad)
                                focus_tables[#focus_tables + 1] = focusRow(chips_focus_rows)
                                vg[#vg + 1] = source_chips
                            end
                            -- Editing: the Embedded source's tags are the
                            -- editable ones (and "+ Add" is the way to tag an
                            -- untagged book); Calibre / Hardcover go grey.
                            if tags_editing and editable then
                                vg[#vg + 1] = pillsFrame(editSpecs(gpills,
                                    function(it) applyEdit(withoutGenre(it.label)) end, editGenres))
                            elseif tags_editing then
                                if #gpills > 0 then
                                    vg[#vg + 1] = pillsFrame(inertSpecs(gpills), nil, Blitbuffer.COLOR_GRAY)
                                end
                            elseif #gpills > 0 then
                                vg[#vg + 1] = pillsFrame(gpills)
                            end
                        end
                    elseif sec.cat == "collections" then
                        -- Collections: the per-collection drill-in pills, then
                        -- a hairline + Edit button opening the collection
                        -- manager. Always shown (even with no memberships) so
                        -- the manager is reachable here -- this is the single
                        -- place collections are surfaced (the Edit tab no
                        -- longer duplicates them).
                        local specs = by_cat[sec.cat]
                        -- Refresh the membership in place: reassign the
                        -- captured pill_specs upvalue and rebuild the Tags
                        -- tab body (which re-reads it), so no flash from
                        -- closing/reopening the popup.
                        local function membershipChanged()
                            local rc = require("readcollection")
                            in_collections = (rc.getCollectionsWithFile
                                and rc:getCollectionsWithFile(book.filepath)) or {}
                            in_collections[rc.default_collection_name] = nil
                            pill_specs = self:_buildPillSpecs(book, in_collections, nil, nil)
                            self:_rebuild(); UIManager:setDirty(self, "ui")
                            if modal and modal.rebuildTab then modal:rebuildTab() end
                        end
                        -- Leave the everything-modal OPEN behind the
                        -- collection dialog.
                        local function editCollections()
                            require("lib/bookshelf_collection_manager").show{
                                book = book, bw = self, on_close = membershipChanged }
                        end
                        local function leaveCollection(it)
                            local rc = require("readcollection")
                            -- addRemoveItemMultiple sets the book's whole
                            -- membership, so start from all of it (Favorites
                            -- included) and drop just this one.
                            local keep = rc:getCollectionsWithFile(book.filepath) or {}
                            keep[it.coll] = nil
                            rc:addRemoveItemMultiple(book.filepath, keep)
                            rc:write()
                            membershipChanged()
                        end
                        vg[#vg + 1] = heading(sec.title)
                        if tags_editing then
                            vg[#vg + 1] = pillsFrame(editSpecs(specs or {}, leaveCollection, editCollections))
                        else
                            vg[#vg + 1] = pillsOrNote(specs, _("Not in any collection."))
                        end
                    else
                        local specs = by_cat[sec.cat]
                        local pair = sec.cat == "author" and specs and #specs > 0
                            and sideBySide(sec.title, specs, _("Series"), by_cat.series)
                        if pair then
                            vg[#vg + 1] = pair
                            series_paired = true
                        elseif specs and #specs > 0 and not (sec.cat == "series" and series_paired) then
                            vg[#vg + 1] = heading(sec.title)
                            if tags_editing then
                                vg[#vg + 1] = pillsFrame(inertSpecs(specs), nil, Blitbuffer.COLOR_GRAY)
                            else
                                vg[#vg + 1] = pillsFrame(specs)
                            end
                        end
                    end
                end
                local scroll = SnugScroll:new{
                    dimen = Geom:new{ w = avail_w,
                        h = math.max(1, avail_h - strip:getSize().h) },
                    scroll_bar_width = bar_w,
                    show_parent = show_parent,
                    vg,
                }
                local body = VerticalGroup:new{ align = "left", strip, scroll }
                body.focus_tables = focus_tables
                return body
            end,
        }
    end

    -- 2. Description tab. When both the embedded and Hardcover descriptions
    -- exist, the single tab carries both as toggleable "sources" (an
    -- Embedded/Hardcover chip bar inside it) instead of a second top-level
    -- Hardcover tab -- making it obvious both are descriptions and keeping the
    -- tab strip short. The chosen source persists on close (on_source_close).
    local desc_args = self:_descriptionArgs(book) or {}
    if desc_args.tabs then
        desc_idx = #tabs + 1
        tabs[desc_idx] = {
            id = "description", label = _("Description"),
            sources = {
                { label = desc_args.tabs[1].label, html = desc_args.tabs[1].html },
                { label = desc_args.tabs[2].label, html = desc_args.tabs[2].html },
            },
            active_source   = desc_args.active_tab or 1,
            on_source_close = desc_args.on_tab_close,
        }
    elseif desc_args.html_body then
        desc_idx = #tabs + 1
        tabs[desc_idx] = { id = "description", label = _("Description"),
            html = desc_args.html_body }
    end

    -- 3. Hardcover reviews tab, only when linked. Cache-first so the common case
    -- shows instantly; otherwise a "Loading" placeholder an async fetch fills in.
    local ok_hc, Hardcover = pcall(require, "lib/bookshelf_hardcover")
    local Tokens = require("lib/bookshelf_tokens")
    local link = ok_hc and Hardcover and Hardcover.getLink
        and Hardcover.getLink(book.filepath) or nil
    local book_id = book.hardcover_book_id or (link and link.book_id)
    -- Only when the plugin is live: with it uninstalled/disabled we suppress all
    -- Hardcover.app data, so no community-reviews tab even if reviews are cached.
    local has_reviews = (ok_hc and Hardcover and Hardcover.isAvailable
        and Hardcover.isAvailable() and book_id) and true or false
    -- No title: the popup header already shows the book title/author. The
    -- rating/counts summary is a native row (_buildReviewsHeader), not part
    -- of this HTML -- only the review list itself renders here.
    -- With "Include spoilers" ticked, the spoiler reviews join the list, most
    -- liked first like the rest.
    local function reviewsListHtml(result, with_spoilers)
        local list = result and result.reviews
        local spoilers = result and result.spoiler_reviews
        if with_spoilers and type(spoilers) == "table" and #spoilers > 0 then
            local all = {}
            for _i, r in ipairs(list or {}) do all[#all + 1] = r end
            for _i, r in ipairs(spoilers) do all[#all + 1] = r end
            table.sort(all, function(a, b)
                return (tonumber(a.likes_count) or 0) > (tonumber(b.likes_count) or 0)
            end)
            list = all
        end
        return Tokens.reviewsHtml{ reviews = list }
    end
    local reviews_tab  -- forward ref: refreshReviews mutates it, its
                        -- widget_builder (below) reads it back each rebuild.
    -- The ONLY thing that fetches reviews (a network call that prompts for WiFi
    -- when offline) is the header's Refresh button -- never opening the popup
    -- and never just viewing the Reviews tab. This keeps battery/network use to
    -- explicit user action; opening a linked book to read its description no
    -- longer prompts for WiFi (issue 253). Cached reviews still show offline.
    -- `modal` is assigned after this closure is created but before Refresh can
    -- invoke it (upvalue, read at call time).
    local function refreshReviews()
        if not reviews_tab then return end
        reviews_tab.busy = true
        if modal and modal._active_tab == reviews_idx and modal.rebuildTab then
            modal:rebuildTab()
            -- fetchReviewsOnline's network call runs on this same thread with
            -- no yield back to UIManager's event loop, so the queued "busy"
            -- repaint would otherwise never actually hit the screen before it
            -- returns (KOReader only drains the paint queue between events).
            -- Force it now so the black-fill feedback is visible immediately.
            -- Same pre-paint pattern as the chip-strip's flashPending().
            UIManager:forceRePaint()
        end
        Hardcover.fetchReviewsOnline(book_id, {}, function(ok, result)
            if modal._dismissed then return end
            reviews_tab.busy = false
            if ok and type(result) == "table" then
                reviews_tab.data = result
                reviews_tab.html = reviewsListHtml(result, reviews_tab.show_spoilers)
            else
                reviews_tab.html = "<p>" .. _("Reviews couldn't be fetched.") .. "</p>"
            end
            if modal._active_tab == reviews_idx and modal.rebuildTab then
                modal:rebuildTab()
            end
        end)
    end
    if has_reviews then
        local data, html
        local ok_cached, cached = Hardcover.fetchReviews(book_id, { cache_only = true })
        if ok_cached and type(cached) == "table" then
            data = cached
            html = reviewsListHtml(cached)
        else
            -- No cached reviews: invite an explicit fetch rather than loading
            -- automatically (that would hit the network on open -- issue 253).
            html = "<p>" .. _("Tap Refresh to load reviews.") .. "</p>"
        end
        -- Hardcover's state: its fetched data, list HTML and busy flag.
        -- show_spoilers starts off with every popup and is never saved.
        reviews_tab = { data = data, html = html, show_spoilers = false }
        reviews_tab.toggleSpoilers = function()
            reviews_tab.show_spoilers = not reviews_tab.show_spoilers
            if reviews_tab.data then
                reviews_tab.html = reviewsListHtml(reviews_tab.data, reviews_tab.show_spoilers)
            end
            if modal and modal.rebuildTab then modal:rebuildTab() end
        end
    end
    -- The Reviews tab: the reader's own review, and Hardcover's when linked,
    -- switched by the same chip bar the Description tab uses. With only one
    -- of them there is no chip bar (maintainer: "My review" belongs with the
    -- reviews, not in the Edit tab).
    local mine = not self:_isRemoteRecord(book)
    if mine or has_reviews then
        reviews_idx = #tabs + 1
        local tab = { id = "reviews", has_hardcover = has_reviews }
        if mine and has_reviews then
            tab.label = _("Reviews")
            tab.sources = { { label = _("My review") }, { label = "Hardcover" } }
            -- Open on your own review when there is one, else Hardcover's;
            -- asked for the reviews (the hero's Hardcover link), Hardcover's.
            tab.active_source = (opts.active ~= "reviews" and self:_bookReview(book)) and 1 or 2
        else
            tab.label = mine and _("My review") or _("Reviews")
        end
        tab.widget_builder = function(avail_w, avail_h, show_parent)
            local chips = tab.sources and show_parent and show_parent._buildSourceChips
                and show_parent:_buildSourceChips(tab) or nil
            local src = tab.sources and (tab._active_source or tab.active_source) or (mine and 1 or 2)
            if src == 1 and mine then
                return self:_buildMyReviewBody(book, show_parent, avail_w, avail_h, chips)
            end
            return self:_buildReviewsTab(reviews_tab, show_parent, avail_w, avail_h, refreshReviews, chips)
        end
        tabs[reviews_idx] = tab
    end

    -- Highlights, when the book has some: a scrolling list at the modal's
    -- font size, a tap opening the highlight with View in book
    -- (lib/bookshelf_book_highlights).
    local Highlights = require("lib/bookshelf_book_highlights")
    local hl_count = (not self:_isRemoteRecord(book)) and Highlights.count(book.filepath) or 0
    if hl_count > 0 then
        highlights_idx = #tabs + 1
        tabs[highlights_idx] = {
            id = "highlights", label = _("Highlights"),
            widget_builder = function(avail_w, avail_h, show_parent)
                return Highlights.buildTab(self, book.filepath, show_parent or modal, avail_w, avail_h)
            end,
        }
    end

    -- Tags next-to-last.
    if tags_tab then
        tags_idx = #tabs + 1
        tabs[tags_idx] = tags_tab
    end

    -- Edit next: the actions tab is reached for less often than Description/
    -- Reviews/Tags, so it sits toward the end of the strip rather than hogging
    -- the first (default-focus) slot.
    edit_idx = #tabs + 1
    tabs[edit_idx] = edit_tab

    -- Cover tab LAST: pick the book's cover from local sources / the device /
    -- an online search. Native, paginated grid. Being last keeps its own
    -- left/right swipe pagination out of the way of the tab-cycling swipe until
    -- you page off the end (see ReviewsModal:onSwipe).
    cover_idx = #tabs + 1
    tabs[cover_idx] = {
        id = "cover", label = _("Cover"),
        widget_builder = function(avail_w, avail_h, show_parent)
            return self:_buildBookCoverTab(book, show_parent, avail_w, avail_h,
                                           cover_tab_state, modal)
        end,
    }

    if #tabs == 0 then return end  -- no pills, no description, no reviews

    -- Active tab: edit / tags / reviews on request, else the description source
    -- the hero shows, else the Edit tab (always present).
    local active_tab
    if opts.active == "edit" and edit_idx then
        active_tab = edit_idx
    elseif opts.active == "tags" and tags_idx then
        active_tab = tags_idx
    elseif opts.active == "reviews" and reviews_idx then
        active_tab = reviews_idx
    elseif opts.active == "cover" and cover_idx then
        active_tab = cover_idx
    elseif opts.active == "highlights" and highlights_idx then
        active_tab = highlights_idx
    elseif desc_idx then
        active_tab = desc_idx  -- the chip bar defaults to the hero's source
    else
        active_tab = edit_idx or 1
    end

    local args = {
        tabs       = tabs,
        bw         = self,
        active_tab = active_tab,
        -- Flush the deferred genre-source invalidation (see
        -- genre_source_changed above) before the caller's own on_close --
        -- ReviewsModal:onClose runs this for BOTH the Close button and the
        -- Open button (Open routes through onClose first), so the shelf is
        -- caught up whichever way the popup closes.
        on_close   = function()
            -- A shelf rebuild still waiting for the taps to pause: now.
            if modal and modal._shelf_owed and modal._shelf_fire then
                UIManager:unschedule(modal._shelf_fire)
                modal._shelf_fire()
            end
            -- Closed while arranging the action cards (the X, Open): the
            -- arrangement so far is kept, as Done keeps it, and written now;
            -- each move was only in memory.
            local arr = modal and modal._actions_edit
            if arr then
                BookshelfSettings.save(require("lib/bookshelf_book_actions_layout").KEY,
                    { order = arr.order, hidden = arr.hidden })
                modal._actions_edit = nil
            end
            if genre_source_changed then
                Repo.invalidateLightMeta()
                self:_rebuild(); UIManager:setDirty(self, "ui")
            end
            -- Empty the Cover tab's transient working dir (online search
            -- downloads + any older per-book cruft) so it
            -- doesn't pile up in the settings folder (issue 267). Applied
            -- covers live in the book's .sdr and are untouched. Fires only on a
            -- real dismiss/Open, NOT on the apply flow's reopen (that goes
            -- through UIManager:close -> onCloseWidget, which doesn't run
            -- on_close), so the carried online candidates survive that trip.
            pcall(function() require("lib/bookshelf_cover_apply").resetWorkingCache() end)
            if opts.on_close then opts.on_close() end
        end,
        -- "Open" footer button opens the book in the reader (the popup closes
        -- first via onClose). _openBook handles stale files + the Kobo path.
        on_open    = function() self:_openBook(book) end,
        -- Cover + metadata header in place of a title bar. Rebuilt fresh on each
        -- layout by the modal (cover bb is one-shot); no pills here (Tags tab),
        -- no bookmark button.
        header_builder = function(avail_w, band)
            return self:_buildBookMenuHeader(book, avail_w, nil, nil, { rich = true, band = band })
        end,
    }
    -- The description-source choice (Embedded vs Hardcover) now persists via the
    -- Description tab's on_source_close (fired by the modal on dismiss), so no
    -- top-level on_tab_close mapping is needed here.

    local ReviewsModal = require("lib/bookshelf_reviews_modal")
    modal = ReviewsModal:new(args)
    UIManager:show(modal)
    -- No fetch on open: reviews load only when the user taps Refresh on the
    -- Reviews tab (see refreshReviews / issue 253). Cached reviews, if any,
    -- are already shown from the cache_only peek above.
end

-- Hardcover reviews now live as a tab in the unified book-detail popup, so this
-- just opens that popup on the Reviews tab. opts.on_close reopens the caller
-- (e.g. the book menu) on dismiss.
function BookshelfWidget:_showHardcoverReviews(book, opts)
    opts = opts or {}
    self:_showBookDetail(book, { active = "reviews", on_close = opts.on_close })
end

end
