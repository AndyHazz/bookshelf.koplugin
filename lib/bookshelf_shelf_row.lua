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
local Blitbuffer      = require("ffi/blitbuffer")
local Screen          = require("device").screen
local SpineWidget     = require("lib/bookshelf_spine_widget")
local SeriesStack     = require("lib/bookshelf_series_stack")
local FolderStack     = require("lib/bookshelf_folder_stack")
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
    if opts.height then
        if slot_h > opts.height then
            slot_h = opts.height
            slot_w = math.floor(slot_h / 1.5)
        elseif slot_h < opts.height then
            slot_h = opts.height
            -- slot_w stays at natural — covers fill row width without gaps.
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
    local title_block_h = 0
    local title_face
    if opts.show_titles then
        title_face    = Font:getFace("infofont", 14)
        title_block_h = Size.padding.small + math.floor(title_face.size * 1.3)
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
            if not opts.show_titles then return widget end
            return VerticalGroup:new{
                align = "center",
                widget,
                VerticalSpan:new{ width = title_block_h },
            }
        end
        local non_book_h = opts.show_titles and cover_h or slot_h

        if item and item.kind == "folder" then
            -- Folder record (carries path / label / first_book)
            row[#row + 1] = wrap_for_title_alignment(FolderStack:new{
                folder      = item,
                width       = slot_w,
                height      = non_book_h,
                on_tap      = opts.on_folder_tap,
                on_hold     = opts.on_folder_hold,
                is_selected = opts.selected_filepath and item.first_book
                              and item.first_book.filepath == opts.selected_filepath,
            })
        elseif item and item.kind == "author" then
            -- Author group (SeriesStack visual, author name on the band)
            row[#row + 1] = wrap_for_title_alignment(SeriesStack:new{
                series      = item,
                width       = slot_w,
                height      = non_book_h,
                on_tap      = opts.on_author_tap,
                on_hold     = opts.on_author_hold,
                is_selected = opts.selected_filepath and item.books and item.books[1]
                              and item.books[1].filepath == opts.selected_filepath,
            })
        elseif item and item.kind == "genre" then
            -- Genre group (SeriesStack visual, genre name on the band)
            row[#row + 1] = wrap_for_title_alignment(SeriesStack:new{
                series      = item,
                width       = slot_w,
                height      = non_book_h,
                on_tap      = opts.on_genre_tap,
                on_hold     = opts.on_genre_hold,
                is_selected = opts.selected_filepath and item.books and item.books[1]
                              and item.books[1].filepath == opts.selected_filepath,
            })
        elseif item and item.kind == "tag" then
            -- Tag / collection group (SeriesStack visual, collection
            -- name on the band)
            row[#row + 1] = wrap_for_title_alignment(SeriesStack:new{
                series      = item,
                width       = slot_w,
                height      = non_book_h,
                on_tap      = opts.on_tag_tap,
                on_hold     = opts.on_tag_hold,
                is_selected = opts.selected_filepath and item.books and item.books[1]
                              and item.books[1].filepath == opts.selected_filepath,
            })
        elseif item and item.books then
            -- SeriesGroup (has a .books array; legacy detection — kind
            -- not always set on series records).
            row[#row + 1] = wrap_for_title_alignment(SeriesStack:new{
                series      = item,
                width       = slot_w,
                height      = non_book_h,
                on_tap      = opts.on_series_tap,
                on_hold     = opts.on_series_hold,
                is_selected = opts.selected_filepath and item.books and item.books[1]
                              and item.books[1].filepath == opts.selected_filepath,
            })
        elseif item then
            -- Single book record
            local spine = SpineWidget:new{
                book        = item,
                width       = slot_w,
                height      = cover_h,
                -- When titles are visible, the InputContainer wrapper below
                -- handles taps for the whole slot (cover + title) so the
                -- title area is also tappable; pass nil here so SpineWidget
                -- doesn't double-fire.
                on_tap      = (not opts.show_titles) and on_book_tap_stamped or nil,
                on_hold     = (not opts.show_titles) and opts.on_book_hold or nil,
                is_selected = opts.selected_filepath
                              and item.filepath == opts.selected_filepath,
                -- Grid covers are the only surface that gets progress
                -- indicators (top-edge bar + bottom-left bookmark glyph).
                -- Hero card, folder stacks, and series stacks reuse
                -- SpineWidget for the underlying cover but opt out.
                show_progress = true,
                -- Plumb expanded-mode flag so SpineWidget can lift the
                -- bookmark glyph fully inside the cover (avoiding clash
                -- with the title text below). Regular mode lets it dangle.
                show_titles   = opts.show_titles,
                -- Pass through the single-series context so SpineWidget
                -- can apply the user's "Show series #" preference -- the
                -- "Within series folder" option only renders the badge
                -- when in_series is true.
                in_series     = opts.in_series == true,
            }
            if opts.show_titles then
                local title_text = item.title or
                                   ((item.filepath or ""):match("([^/]+)$") or "")
                                       :gsub("%.[^.]+$", "")
                -- TextWidget (single-line) auto-truncates with ellipsis at
                -- max_width — exactly what we want here. TextBoxWidget would
                -- wrap to two lines for longer titles which crowds the grid.
                local title_widget = TextWidget:new{
                    text      = title_text,
                    face      = title_face,
                    max_width = slot_w,
                }
                local slot_dimen = Geom:new{ w = slot_w, h = slot_h }
                local stack = VerticalGroup:new{
                    align = "center",
                    spine,
                    VerticalSpan:new{ width = Size.padding.small },
                    title_widget,
                }
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
    -- Centre the row within the parent's budgeted width when slot_w was
    -- shrunk to preserve the 2:3 cover aspect (so the row width is now less
    -- than opts.width). Without centering, the row paints flush-left with
    -- the slack appearing as a right-side margin — uneven visually.
    local row_w = n_slots * slot_w + (n_slots - 1) * gap
    if opts.width and opts.width > row_w then
        return CenterContainer:new{
            dimen = Geom:new{ w = opts.width, h = slot_h },
            row,
        }
    end
    return row
end

return ShelfRow
