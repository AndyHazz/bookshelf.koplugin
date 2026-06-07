-- bookshelf_shelf_row.lua
-- A single shelf: 4 horizontally-arranged spine slots + dotted base rule.
-- Each slot can be a SpineWidget (single book) or a SeriesStack (series group).
-- Empty slots render as blank spacers so the row always has a fixed width.
--
-- The dotted base rule is a custom-painted Widget subclass. Its paintTo method
-- walks pixel columns 3dp apart and draws a 1×thickness fillRect at each stop.
-- Pattern reference: bookends_overlay_widget.lua lines 176–185 (MultiLineWidget).

local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer  = require("ui/widget/container/framecontainer")
local InputContainer  = require("ui/widget/container/inputcontainer")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local Widget          = require("ui/widget/widget")
local GestureRange    = require("ui/gesturerange")
local Geom            = require("ui/geometry")
local Size            = require("ui/size")
local Font            = require("ui/font")
local BFont           = require("lib/bookshelf_fonts")
local Blitbuffer      = require("ffi/blitbuffer")
local SpineWidget     = require("lib/bookshelf_spine_widget")
local SeriesStack     = require("lib/bookshelf_series_stack")
local FolderStack     = require("lib/bookshelf_folder_stack")
local Repo            = require("lib/bookshelf_book_repository")
local BookshelfSettings = require("lib/bookshelf_settings_store")
local _               = require("lib/bookshelf_i18n").gettext
local logger          = require("logger")

-- Monotonic wall-clock for perf instrumentation. Matches the helper used
-- in bookshelf_widget.lua so the [bookshelf perf] timestamps share a clock.
local _gettime
do
    local ok, s = pcall(require, "socket")
    _gettime = (ok and s and type(s.gettime) == "function")
        and s.gettime
        or function() return os.time() end
end

local ShelfRow = {}

-- _renderDottedRule(width, thickness)
-- Returns a Widget subclass instance that paints a dotted horizontal rule via
-- bb:fillRect. Dot spacing is 3dp (1dp dot, 2dp gap). Uses COLOR_BLACK.
function ShelfRow._renderDottedRule(width, thickness)
    local DottedRule = Widget:extend{}

    function DottedRule:init()
        self.dimen = Geom:new{ w = width, h = thickness }
    end

    function DottedRule:paintTo(bb, x, y)
        -- Walk across the width placing 1×thickness filled rects every 3px.
        for px = 0, width - 1, 3 do
            bb:paintRect(x + px, y, 1, thickness, Blitbuffer.COLOR_BLACK)
        end
    end

    return DottedRule:new{}
end

-- ShelfRow.new(opts)
-- opts: {
--   width         number   total row width in pixels
--   height        number   slot height in pixels
--   items         table    list of up to 4 Book or SeriesGroup records (nil = empty slot)
--   gap           number   (optional) pixel gap between slots (default Size.padding.default)
--   on_book_tap   function (book) callback
--   on_book_hold  function (book) callback
--   on_series_tap function (series) callback
--   on_series_hold function (series) callback
--   selected_filepath string|nil  filepath of the spine that should
--                                 render with the selected (thicker)
--                                 border. Typically the previewed book.
-- }
function ShelfRow.new(opts)
    local n_slots = opts.n_slots or 4
    -- Generous gap between covers so the shelf doesn't read as cramped.
    -- Size.padding.fullscreen × 2 ≈ 30dp at native scaling.
    local gap     = opts.gap or Size.padding.fullscreen * 2
    local slot_w  = math.floor((opts.width - gap * (n_slots - 1)) / n_slots)
    -- Standard 2:3 book-cover aspect (slot_w * 1.5) so covers look like books.
    local slot_h  = math.floor(slot_w * 1.5)
    -- Honour the parent's budgeted row height (opts.height) when supplied.
    --   - If budget is SMALLER than natural: shrink the slot to fit AND
    --     recompute slot_w so the cover stays 2:3. (Tight layouts like
    --     expanded mode + small screens.)
    --   - If budget is LARGER than natural: GROW slot_h to fill the budget
    --     while keeping slot_w at natural — the row still spans content_w
    --     and the extra slot height goes to the cover (slightly fatter than
    --     natural aspect, but no horizontal whitespace and the row doesn't
    --     leave slack that would push pagination off its fixed y position).
    -- Aspect bounds so covers don't get extreme either way:
    --   * Shrink floor: stop shrinking once slot_w drops below 70% of
    --     natural (covers become hard to read). Below that, the row
    --     simply leaves vertical slack instead.
    --   * Stretch cap: allow at most 5% vertical overshoot (slot_h grows
    --     past natural, making covers slightly taller than 2:3). Beyond
    --     that the row keeps natural slot_h and leaves vertical slack.
    local SHRINK_FLOOR  = 0.70
    local STRETCH_CAP   = 1.05
    local natural_slot_h = slot_h
    if opts.height then
        if slot_h > opts.height then
            -- Budget tighter than natural: shrink both axes to preserve
            -- 2:3, but not below the shrink floor.
            local target_h = math.max(opts.height,
                math.floor(natural_slot_h * SHRINK_FLOOR))
            slot_h = target_h
            slot_w = math.floor(slot_h / 1.5)
        elseif slot_h < opts.height then
            -- Budget looser than natural: stretch slot_h vertically up to
            -- the cap. Beyond that, hold at the cap and let the row's
            -- height-vs-content delta become vertical slack.
            slot_h = math.min(opts.height,
                math.floor(natural_slot_h * STRETCH_CAP))
        end
    end

    -- If the covers got narrower than their natural slot (the shrink branch
    -- above), widen the inter-cover gap so the n covers still span opts.width
    -- evenly -- spreading the slack between covers rather than leaving it as a
    -- clumped margin at the sides (which the centring fallback used to do).
    if opts.width and n_slots > 1 then
        local row_w_now = n_slots * slot_w + (n_slots - 1) * gap
        if opts.width > row_w_now then
            gap = math.max(gap, math.floor((opts.width - n_slots * slot_w) / (n_slots - 1)))
        end
    end

    -- Titles-under-cover mode (used in expanded shelf): reserve a thin
    -- strip below each cover for the book title. Cover shrinks vertically
    -- only — slot_w stays the same so the row still fills content_w like
    -- the chip strip / pagination above and below. (Per "scale height,
    -- not width".)
    --
    -- Single line at 14pt — short titles fit, longer ones truncate with
    -- ellipsis at the right edge of the slot. Two-line wrap was tried and
    -- read as crowded; truncation keeps the grid scannable.
    -- Expanded shelf label-below-cover mode. Default "none" lets covers
    -- claim the full slot height. "title" / "author" / "series" reserve
    -- a strip below each cover for the corresponding metadata; missing
    -- data falls back to title (or the literal "None" for series).
    local label_mode = BookshelfSettings.read("expanded_shelf_label") or "none"
    if label_mode ~= "title" and label_mode ~= "author" and label_mode ~= "series" then
        label_mode = "none"
    end
    -- Two flags driven by the same `opts.show_titles` input — kept
    -- separate so the geometry stays consistent while the rendering
    -- adapts:
    --   show_titles    — alias kept for back-compat with downstream
    --                    SpineWidget / slot-tap code paths.
    --   draw_label     — actually paint a TextWidget in the strip.
    local show_titles = opts.show_titles or false
    local draw_label  = show_titles and label_mode ~= "none"

    -- Gap between cover bottom and the label text. Bumped from
    -- padding.small to padding.default so the dangling bookmark
    -- indicator at the cover's bottom-left doesn't sit on top of
    -- the title text. Cover height shrinks by the same delta so
    -- inter-row spacing is unchanged.
    local label_gap = Size.padding.default
    -- Expanded-shelf font scale: applied to the label face below
    -- covers (Title / Author / Series). 100% preserves prior
    -- behaviour. The reserved strip height scales with the font so
    -- larger scales push the cover height down accordingly.
    local label_scale = BookshelfSettings.read("expanded_shelf_font_scale") or 100
    local title_block_h = 0
    local title_face
    local title_bold
    -- Only reserve the strip when a label will actually be drawn. With
    -- label_mode = "none" the cover claims the full slot height — the
    -- stretch cap below keeps it from growing past ~5% of natural.
    if draw_label then
        local face_size = math.floor(14 * label_scale / 100 + 0.5)
        title_face, title_bold = BFont:getFace("infofont", face_size)
        title_block_h = label_gap + math.floor(face_size * 1.3)
    end
    local function _labelFor(item)
        local title_fallback = item.title or
            ((item.filepath or ""):match("([^/]+)$") or ""):gsub("%.[^.]+$", "")
        if label_mode == "author" then
            local a = item.author or item.authors
            if a and a ~= "" then
                -- Honour the "Author name formatting" setting so the
                -- expanded-shelf author label matches the form used on
                -- the hero, the long-press menu, and the Authors chip.
                local fmt = BookshelfSettings.read("author_format") or "auto"
                if fmt ~= "auto" then
                    local ok_a, _AN = pcall(require, "lib/bookshelf_author_name")
                    if ok_a and _AN and _AN.formatted then
                        return _AN.formatted(a, fmt)
                    end
                end
                return a
            end
        elseif label_mode == "series" then
            local sname = item.series_name
            if sname and sname ~= "" then
                local idx = item.series_num or item.series_index
                if idx then
                    return sname .. " #" .. tostring(idx)
                end
                return sname
            end
            -- Standalone book: render "None" so the row reads as a
            -- consistent series column rather than falling back to a
            -- mixed title-here / series-there grid.
            return _("None")
        end
        return title_fallback
    end
    local cover_h = slot_h - title_block_h
    local row     = HorizontalGroup:new{}

    -- Wrap on_book_tap so the SpineWidget direct-bind path (line ~210) also
    -- stamps a tap timestamp and forwards it as the second arg, matching the
    -- expanded-mode slot:onTap wrapper below. _previewBook on the widget side
    -- uses it to compute tap_gap (gesture → handler latency).
    local raw_on_book_tap = opts.on_book_tap
    local on_book_tap_stamped = raw_on_book_tap and function(b)
        local _t = _gettime()
        logger.dbg(string.format(
            "[bookshelf perf] spine onTap fired t=%.3f fp=%s",
            _t, tostring(b and b.filepath or "?")))
        raw_on_book_tap(b, _t)
    end or nil

    -- Raw selection count for a stack: number of its books currently
    -- in the selection set. Returns 0 when selection mode is off or no
    -- books overlap, so call sites can derive:
    --   * is_bulk_selected = (k > 0)              -> highlight + flag
    --   * selected_count   = (0 < k < #books)     -> "K/N" badge
    -- One sweep, two consumers — beats a separate early-exit "any
    -- selected?" probe for a stack that may already need a full walk.
    local function stack_sel_count(books)
        if not opts.selection or not opts.selection.isActive then return 0 end
        if not opts.selection:isActive() then return 0 end
        if not books or #books == 0 then return 0 end
        local k = 0
        for _i = 1, #books do
            local fp = books[_i].filepath
            if fp and opts.selection:contains(fp) then k = k + 1 end
        end
        return k
    end
    local function partial_count(k, total)
        if k > 0 and k < total then return k end
        return nil
    end

    -- stack_count_badge_mode: off / folders / groups / all. Default
    -- "groups" preserves pre-v2.2.2 behaviour. Resolved once per row
    -- build so the per-slot rendering reads from a local boolean
    -- instead of re-reading the setting per slot.
    local badge_mode = BookshelfSettings.read("stack_count_badge_mode")
    if not (badge_mode == "off" or badge_mode == "folders"
         or badge_mode == "groups" or badge_mode == "all") then
        badge_mode = "groups"
    end
    local show_folder_badge = (badge_mode == "folders" or badge_mode == "all")
    local show_group_badge  = (badge_mode == "groups"  or badge_mode == "all")

    -- stack_count_badge_format: when the badge is shown, "total" →
    -- "×N", "finished_total" → "F/N". Selection-partial "K/N" still
    -- wins above this. Finished is skipped entirely in selection mode
    -- (user-requested: F/N is an out-of-selection format) and when not
    -- needed so the cheap path stays cheap.
    local badge_format = BookshelfSettings.read("stack_count_badge_format")
    if badge_format ~= "finished_total" then badge_format = "total" end
    local sel_active_global = opts.selection and opts.selection.isActive
                              and opts.selection:isActive() or false
    local show_finished = (badge_format == "finished_total")
                          and not sel_active_global

    -- finished_count(books_or_paths, items_have_filepath): scans the
    -- list calling Repo.readProgress on each filepath and counts
    -- those whose status is "finished". Returns nil when show_finished
    -- is off so callers can pass the value straight to the widget
    -- without an extra guard. `is_paths` is true when each entry is a
    -- bare filepath string (folder case), false when each entry is a
    -- book record with .filepath (group case).
    --
    -- Used as a fallback path: groups now carry pre-computed
    -- finished_count_total in the hydrated item, so we read that
    -- directly when available. Folders still sweep their recursive
    -- paths via this helper.
    local function finished_count(list, is_paths)
        if not show_finished or not list then return nil end
        local f = 0
        for _i = 1, #list do
            local fp = is_paths and list[_i] or list[_i].filepath
            if fp then
                local _pct, status = Repo.readProgress(fp)
                if status == "finished" then f = f + 1 end
            end
        end
        return f
    end

    for i = 1, n_slots do
        -- Insert a gap spacer before every slot after the first.
        if i > 1 then
            row[#row + 1] = HorizontalSpan:new{ width = gap }
        end

        local item = opts.items and opts.items[i]
        -- Helper: when titles are shown (expanded mode), wrap a non-book
        -- widget so its visual occupies cover_h and a VerticalSpan below
        -- claims the title_block_h slot. Without this, group/folder
        -- widgets render at the full slot_h while books render at cover_h
        -- + title; the cover bottoms then misalign within a row that
        -- mixes types.
        local function wrap_for_title_alignment(widget)
            if not show_titles then return widget end
            return VerticalGroup:new{
                align = "center",
                widget,
                VerticalSpan:new{ width = title_block_h },
            }
        end
        local non_book_h = show_titles and cover_h or slot_h

        if item and item.kind == "folder" then
            -- Folder record (carries path / label / first_book).
            -- Three pieces of derived data: total recursive book count
            -- (for the optional badge), how many of those are in the
            -- current selection (for highlight + partial badge form),
            -- and a path → "should I look this up?" guard so plain
            -- browsing doesn't pay for the recursive walk lookup
            -- unless something needs it.
            local folder_fp = item.first_book and item.first_book.filepath
            local sel_active = opts.selection and opts.selection.isActive
                               and opts.selection:isActive() or false
            local need_lookup = item.path and
                                (show_folder_badge or sel_active)
            local folder_fpaths
            if need_lookup then
                folder_fpaths = Repo.getFolderBookPaths(item.path) or {}
            end
            local folder_book_count
            if show_folder_badge and folder_fpaths then
                folder_book_count = #folder_fpaths
            end
            local folder_k = 0
            if sel_active and folder_fpaths then
                for _i = 1, #folder_fpaths do
                    if opts.selection:contains(folder_fpaths[_i]) then
                        folder_k = folder_k + 1
                    end
                end
            end
            local folder_bulk = folder_k > 0
            local folder_cur  = opts.selected_filepath and folder_fp
                                and folder_fp == opts.selected_filepath or false
            local folder_finished
            if show_finished and show_folder_badge and folder_fpaths then
                folder_finished = finished_count(folder_fpaths, true)
            end
            row[#row + 1] = wrap_for_title_alignment(FolderStack:new{
                folder           = item,
                width            = slot_w,
                height           = non_book_h,
                on_tap           = opts.on_folder_tap,
                on_hold          = opts.on_folder_hold,
                is_selected      = folder_bulk or folder_cur,
                is_bulk_selected = folder_bulk,
                book_count       = folder_book_count,
                selected_count   = folder_book_count
                                   and partial_count(folder_k, folder_book_count)
                                   or nil,
                finished_count   = folder_finished,
            })
        elseif item and item.kind == "author" then
            -- Author group (SeriesStack visual, author name on the band)
            local author_fp = item.books and item.books[1] and item.books[1].filepath
            local author_k    = stack_sel_count(item.books)
            local author_bulk = author_k > 0
            local author_cur  = opts.selected_filepath and author_fp
                                and author_fp == opts.selected_filepath or false
            local author_finished, author_finished_total
            if show_finished and show_group_badge then
                -- Pre-computed at shape build → stack-wide stat that
                -- ignores the active filter (matches the "Finished of
                -- Total" framing the user requested). Falls back to a
                -- live sweep when the hydrated item didn't carry it.
                author_finished       = finished_count(item.books, false)
                author_finished_total = nil  -- live sweep gives filtered count; matches #item.books
            end
            row[#row + 1] = wrap_for_title_alignment(SeriesStack:new{
                series           = item,
                width            = slot_w,
                height           = non_book_h,
                on_tap           = opts.on_author_tap,
                on_hold          = opts.on_author_hold,
                is_selected      = author_bulk or author_cur,
                is_bulk_selected = author_bulk,
                selected_count   = partial_count(author_k, item.books and #item.books or 0),
                finished_count   = author_finished,
                finished_total   = author_finished_total,
                show_count_badge = show_group_badge,
            })
        elseif item and item.kind == "genre" then
            -- Genre group (SeriesStack visual, genre name on the band)
            local genre_fp = item.books and item.books[1] and item.books[1].filepath
            local genre_k    = stack_sel_count(item.books)
            local genre_bulk = genre_k > 0
            local genre_cur  = opts.selected_filepath and genre_fp
                               and genre_fp == opts.selected_filepath or false
            local genre_finished, genre_finished_total
            if show_finished and show_group_badge then
                genre_finished       = finished_count(item.books, false)
                genre_finished_total = nil
            end
            row[#row + 1] = wrap_for_title_alignment(SeriesStack:new{
                series           = item,
                width            = slot_w,
                height           = non_book_h,
                on_tap           = opts.on_genre_tap,
                on_hold          = opts.on_genre_hold,
                is_selected      = genre_bulk or genre_cur,
                is_bulk_selected = genre_bulk,
                selected_count   = partial_count(genre_k, item.books and #item.books or 0),
                finished_count   = genre_finished,
                finished_total   = genre_finished_total,
                show_count_badge = show_group_badge,
            })
        elseif item and item.kind == "tag" then
            -- Tag / collection group (SeriesStack visual, collection
            -- name on the band)
            local tag_fp = item.books and item.books[1] and item.books[1].filepath
            local tag_k    = stack_sel_count(item.books)
            local tag_bulk = tag_k > 0
            local tag_cur  = opts.selected_filepath and tag_fp
                             and tag_fp == opts.selected_filepath or false
            local tag_finished, tag_finished_total
            if show_finished and show_group_badge then
                tag_finished       = finished_count(item.books, false)
                tag_finished_total = nil
            end
            row[#row + 1] = wrap_for_title_alignment(SeriesStack:new{
                series           = item,
                width            = slot_w,
                height           = non_book_h,
                on_tap           = opts.on_tag_tap,
                on_hold          = opts.on_tag_hold,
                is_selected      = tag_bulk or tag_cur,
                is_bulk_selected = tag_bulk,
                selected_count   = partial_count(tag_k, item.books and #item.books or 0),
                finished_count   = tag_finished,
                finished_total   = tag_finished_total,
                show_count_badge = show_group_badge,
            })
        elseif item and item.kind == "language" then
            local lang_fp = item.books and item.books[1] and item.books[1].filepath
            local lang_k    = stack_sel_count(item.books)
            local lang_bulk = lang_k > 0
            local lang_cur  = opts.selected_filepath and lang_fp
                              and lang_fp == opts.selected_filepath or false
            local lang_finished, lang_finished_total
            if show_finished and show_group_badge then
                lang_finished       = finished_count(item.books, false)
                lang_finished_total = nil
            end
            row[#row + 1] = wrap_for_title_alignment(SeriesStack:new{
                series           = item,
                width            = slot_w,
                height           = non_book_h,
                on_tap           = opts.on_language_tap,
                on_hold          = opts.on_language_hold,
                is_selected      = lang_bulk or lang_cur,
                is_bulk_selected = lang_bulk,
                selected_count   = partial_count(lang_k, item.books and #item.books or 0),
                finished_count   = lang_finished,
                finished_total   = lang_finished_total,
                show_count_badge = show_group_badge,
            })
        elseif item and item.books then
            -- SeriesGroup (has a .books array; legacy detection — kind
            -- not always set on series records).
            local series_fp = item.books and item.books[1] and item.books[1].filepath
            local series_k    = stack_sel_count(item.books)
            local series_bulk = series_k > 0
            local series_cur  = opts.selected_filepath and series_fp
                                and series_fp == opts.selected_filepath or false
            local series_finished, series_finished_total
            if show_finished and show_group_badge then
                series_finished       = finished_count(item.books, false)
                series_finished_total = nil
            end
            row[#row + 1] = wrap_for_title_alignment(SeriesStack:new{
                series           = item,
                width            = slot_w,
                height           = non_book_h,
                on_tap           = opts.on_series_tap,
                on_hold          = opts.on_series_hold,
                is_selected      = series_bulk or series_cur,
                is_bulk_selected = series_bulk,
                selected_count   = partial_count(series_k, item.books and #item.books or 0),
                finished_count   = series_finished,
                finished_total   = series_finished_total,
                show_count_badge = show_group_badge,
            })
        elseif item then
            -- Single book record
            local book_bulk = opts.selection and item.filepath
                              and opts.selection:contains(item.filepath) or false
            local book_cur  = opts.selected_filepath and item.filepath
                              and item.filepath == opts.selected_filepath or false
            local spine = SpineWidget:new{
                book             = item,
                width            = slot_w,
                height           = cover_h,
                -- When titles are visible, the InputContainer wrapper below
                -- handles taps for the whole slot (cover + title) so the
                -- title area is also tappable; pass nil here so SpineWidget
                -- doesn't double-fire.
                on_tap           = (not show_titles) and on_book_tap_stamped or nil,
                on_hold          = (not show_titles) and opts.on_book_hold or nil,
                is_selected      = book_bulk or book_cur,
                is_bulk_selected = book_bulk,
                -- Grid covers are the only surface that gets progress
                -- indicators (top-edge bar + bottom-left bookmark glyph).
                -- Hero card, folder stacks, and series stacks reuse
                -- SpineWidget for the underlying cover but opt out.
                show_progress = true,
                -- Plumb expanded-mode flag so SpineWidget can lift the
                -- bookmark glyph fully inside the cover (avoiding clash
                -- with the title text below). Regular mode lets it dangle.
                show_titles   = show_titles,
                -- Pass through the single-series context so SpineWidget
                -- can apply the user's "Show series #" preference -- the
                -- "Within series folder" option only renders the badge
                -- when in_series is true.
                in_series     = opts.in_series == true,
            }
            if show_titles then
                -- Strip layout. When draw_label is true we add the
                -- usual gap + TextWidget. When false (label_mode =
                -- "none") we reserve the same total height with a
                -- single VerticalSpan, so covers don't grow when the
                -- user toggles into None.
                local slot_dimen = Geom:new{ w = slot_w, h = slot_h }
                local stack = VerticalGroup:new{
                    align = "center",
                    spine,
                }
                if draw_label then
                    local title_text = _labelFor(item)
                    -- TextWidget (single-line) auto-truncates with ellipsis at
                    -- max_width — exactly what we want here. TextBoxWidget would
                    -- wrap to two lines for longer titles which crowds the grid.
                    local title_widget = TextWidget:new{
                        text      = title_text,
                        face      = title_face,
                        bold      = title_bold,
                        max_width = slot_w,
                    }
                    stack[#stack + 1] = VerticalSpan:new{ width = label_gap }
                    stack[#stack + 1] = title_widget
                else
                    stack[#stack + 1] = VerticalSpan:new{ width = title_block_h }
                end
                local slot = InputContainer:new{ dimen = slot_dimen, stack }
                slot.ges_events = {
                    Tap  = { GestureRange:new{ ges = "tap",  range = slot_dimen } },
                    Hold = { GestureRange:new{ ges = "hold", range = slot_dimen } },
                }
                local on_tap_cb  = on_book_tap_stamped
                local on_hold_cb = opts.on_book_hold
                function slot:onTap()
                    if on_tap_cb then on_tap_cb(item) end
                    return true
                end
                function slot:onHold()
                    if on_hold_cb then on_hold_cb(item) end
                    return true
                end
                row[#row + 1] = slot
            else
                row[#row + 1] = spine
            end
        else
            -- Empty slot — a bare Widget with a sized dimen. FrameContainer
            -- crashes on getSize() when its self[1] child is nil, so we use
            -- the lighter-weight Widget directly. Widget:getSize() returns
            -- self.dimen, which gives the row a stable slot footprint.
            row[#row + 1] = Widget:new{
                dimen = Geom:new{ w = slot_w, h = slot_h },
            }
        end
    end

    -- Shelf base rule removed (read as visual noise rather than support).
    -- When slot_w was shrunk to preserve 2:3 under a tight height budget, the
    -- covers no longer span opts.width. Centring left clumped "empty space
    -- either side"; instead the row was rebuilt above with a WIDENED gap (see
    -- the gap recompute near slot_w finalisation) so the covers spread evenly
    -- across the full width. The CenterContainer is now only a safety net for
    -- the single-column case where there's no inter-cover gap to widen.
    local row_w = n_slots * slot_w + (n_slots - 1) * gap
    local result = row
    if opts.width and opts.width > row_w and n_slots <= 1 then
        result = CenterContainer:new{
            dimen = Geom:new{ w = opts.width, h = slot_h },
            row,
        }
    end
    -- Report the ACTUAL cover-area dimensions this row rendered into, so the
    -- preload can warm next-page covers at exactly the size the shelf uses --
    -- correct across DPI, expanded/collapsed, stretch/shrink, and label
    -- settings -- instead of re-deriving (and drifting from) this math. cover_h
    -- already accounts for the title strip and any stretch/shrink; warming at
    -- the cover AREA (which is >= the bordered cover image SpineWidget paints)
    -- guarantees ScaledCoverCache's "cached >= requested" check passes.
    result.cover_w = slot_w
    result.cover_h = cover_h
    return result
end

return ShelfRow
