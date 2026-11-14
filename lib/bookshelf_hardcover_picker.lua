-- bookshelf_hardcover_picker.lua
-- The list a reader picks a Hardcover book or edition from, when the client
-- is Bookshelf's own (lib/bookshelf_hardcover_client). On the library modal
-- every other Bookshelf picker uses, so it follows the theme. With a sync
-- plugin's client the list is that plugin's own dialog instead (see
-- _showPicker in lib/bookshelf_hardcover).
--
--   show{ title, records, active = { book_id = } | { edition_id = },
--         load = function() -> records | nil, err    -- instead of records:
--             the list is up at once saying "Asking Hardcover", and this
--             runs once that is on screen (it asks Hardcover, on this thread)
--         empty_text = what an empty answer says,
--         search = function(text) -> records | nil,   -- nil: not searchable
--         search_value = "the text first searched",
--         over = a LibraryModal config.over: a page of the menu it came
--             from, with its breadcrumb (PageDialog:over)
--         on_pick = function(record), on_close = function() }
--
-- A record is what the client hands back: a book, or an edition as a book
-- record with edition_id and the edition's own title, pages, year, format.

local T = require("ffi/util").template
local _ = require("lib/bookshelf_i18n").gettext

local M = {}

local SEP = " \xC2\xB7 "    -- middle dot

-- A text column narrower than this many widths of the title font, and the
-- grid drops a column.
M.MIN_TEXT_EMS = 8
-- The cover's share of a cell's width in one column.
M.ONE_COLUMN_COVER = 0.2

local function authors(rec)
    local names = {}
    for _i, c in ipairs(type(rec.contributions) == "table" and rec.contributions or {}) do
        local n = type(c) == "table" and type(c.author) == "table" and c.author.name
        if type(n) == "string" and n ~= "" then names[#names + 1] = n end
    end
    if #names == 0 then return nil end
    if #names <= 2 then return table.concat(names, ", ") end
    return T(_("%1, %2 and others"), names[1], names[2])
end

local function series(rec)
    local first = type(rec.book_series) == "table" and rec.book_series[1]
    local name = type(first) == "table" and type(first.series) == "table" and first.series.name
    if type(name) ~= "string" or name == "" then return nil end
    return first.position and (name .. " #" .. tostring(first.position)) or name
end

-- A count short enough for the cell's foot: 9,999 / 51k / 1.3M.
local function count(n)
    n = math.floor(n)
    if n >= 1000000 then
        -- Rounded by hand: "%.1f" gives 1.2 for 1,250,000 (a float a hair under).
        local tenths = math.floor(n / 100000 + 0.5)
        return tenths % 10 == 0 and string.format("%dM", tenths / 10)
            or string.format("%d.%dM", math.floor(tenths / 10), tenths % 10)
    elseif n >= 10000 then
        return string.format("%dk", math.floor(n / 1000 + 0.5))
    end
    local s = tostring(n)
    if n >= 1000 then s = s:sub(1, -4) .. "," .. s:sub(-3) end
    return s
end

-- describe(record) -> label, subtitle, stats (each nil when empty)
-- subtitle: who and which series (a book), or format, publisher and
-- language (an edition); stats: pages and how many read it, a line of its
-- own at the cell's foot.
function M.describe(rec)
    local label = type(rec.title) == "string" and rec.title ~= "" and rec.title or _("Untitled")
    if rec.release_year then label = label .. " (" .. tostring(rec.release_year) .. ")" end
    local parts = {}
    local function add(v) if v and v ~= "" then parts[#parts + 1] = v end end
    if rec.edition_id then
        -- Editions of one book share its author: what differs is the format,
        -- the publisher and the language.
        add(rec.edition_format)
        add(rec.publisher)
        add(type(rec.language) == "table" and rec.language.language or nil)
    else
        add(authors(rec))
        add(series(rec))
    end
    local stats = {}
    local pages = tonumber(rec.pages)
    if pages and pages > 0 then
        stats[#stats + 1] = pages == 1 and _("1 page") or T(_("%1 pages"), count(pages))
    end
    local n = tonumber(rec.edition_id and rec.users_count or rec.users_read_count)
    if n and n > 0 then
        if rec.edition_id then
            stats[#stats + 1] = n == 1 and _("1 reader") or T(_("%1 readers"), count(n))
        else
            stats[#stats + 1] = n == 1 and _("1 read") or T(_("%1 reads"), count(n))
        end
    end
    return label, #parts > 0 and table.concat(parts, SEP) or nil,
        #stats > 0 and table.concat(stats, SEP) or nil
end

local function isActive(rec, active)
    if type(active) ~= "table" then return false end
    if active.edition_id then
        return tostring(rec.edition_id) == tostring(active.edition_id)
    end
    if active.book_id then
        return tostring(rec.book_id or rec.id) == tostring(active.book_id)
    end
    return false
end

function M.show(spec)
    local UIManager = require("ui/uimanager")
    local Screen = require("device").screen
    local Row = require("lib/bookshelf_hardcover_picker_row")
    local Thumbs = require("lib/bookshelf_hardcover_thumbs")
    local LibraryModal = require("lib/bookshelf_library_modal")

    local records = type(spec.records) == "table" and spec.records or {}
    local note            -- a line over the list: searching, or why it is unchanged
    local picked
    local modal
    local closed = false

    -- Covers arrive after the list is up (lib/bookshelf_hardcover_thumbs):
    -- the loader fetches what the page on screen is missing, and each one
    -- that lands redraws its own row.
    local function redraw(rec)
        if not closed and modal then modal:refreshCell(rec) end
    end
    -- A failed one redraws too: its cell then says No cover.
    local loader = Thumbs.newLoader{ on_loaded = redraw, on_failed = redraw }
    -- Two columns of four in portrait, three of two in landscape: a cover a
    -- third of the cell wide beside text that wraps (maintainer: the covers
    -- were "quite small" in one column of 64dp rows).
    -- Fewer columns when the text column would be too narrow to read: KOReader
    -- scales everything by the screen, so this only bites with a DPI override
    -- (bigger text; rig: the title on three lines, the author "Ben..."). The
    -- modal's width as LibraryModal makes it: 85% of the screen, or of its
    -- short side as a page of the Hardcover menu.
    local function landscape() return Screen:getWidth() > Screen:getHeight() end
    local function textEms(c)
        local Space = require("lib/bookshelf_space")
        local sw, sh = Screen:getWidth(), Screen:getHeight()
        local gap = Space.px(10)
        local cw = math.floor((spec.over and math.min(sw, sh) or sw) * 0.85) - 2 * gap
        local cell = math.floor((cw - (c - 1) * gap) / c)
        local cover = Row.coverSize(cell)
        return (cell - cover - 3 * gap) / Space.px(17)
    end
    local function cols()
        local c = landscape() and 3 or 2
        while c > 1 and textEms(c) < M.MIN_TEXT_EMS do c = c - 1 end
        return c
    end
    local function rows() return landscape() and 2 or 4 end
    local function perPage() return cols() * rows() end
    -- One column: a narrower cover, or each cell is half cover.
    local function coverShare() return cols() == 1 and M.ONE_COLUMN_COVER or nil end
    local function wantPage()
        local per = perPage()
        local first = ((modal and modal.page or 1) - 1) * per + 1
        local page = {}
        for i = first, math.min(first + per - 1, #records) do page[#page + 1] = records[i] end
        loader:want(page)
    end

    local config = {
        title          = spec.title,
        intro          = function() return note end,
        grid_cols      = cols(),
        cells_per_page = perPage,
        -- The cells' own height, not the modal's 64dp rows; less when the
        -- screen (or the menu page it opens in) has less room.
        area_height    = function(cw, room)
            local gap = require("lib/bookshelf_space").px(10)
            local c, r = cols(), rows()
            local cell_w = math.floor((cw - (c - 1) * gap) / c)
            local want = r * Row.cellHeight(cell_w, coverShare()) + (r - 1) * gap
            if room and room < want then return room end
            return want
        end,
        on_page_shown  = function() wantPage() end,
        item_count     = function() return #records end,
        item_at        = function(idx) return records[idx] end,
        cell_renderer  = function(rec, dimen)
            local label, subtitle, stats = M.describe(rec)
            local url = Thumbs.urlOf(rec)
            local path = Thumbs.cached(url)
            -- No picture on Hardcover, or one that would not download: said
            -- so, where a blank box read as still loading (PW5).
            local none = not path and (url == nil or loader:hasFailed(url)) or nil
            return Row.render({ label = label, subtitle = subtitle, stats = stats,
                cover_path = path, no_cover = none }, dimen,
                { selected = isActive(rec, spec.active), cover_share = coverShare() })
        end,
        -- The list goes first, so the reader is not left looking at it while
        -- the link is made and the book's details are fetched; the caller
        -- hears it closed after that, and reopens on the new link.
        on_cell_tap    = function(rec)
            picked = rec
            UIManager:close(modal)
        end,
        -- One Close: the library modal draws a lone Close as the title
        -- bar's X, and Back on the keys runs it. Without it the list could
        -- only be left by picking something (device report).
        footer_actions = { {
            key = "close", label = _("Close"),
            on_tap = function() UIManager:close(modal) end,
        } },
        on_closed      = function()
            closed = true
            loader:stop()
            -- A tick later: this runs while the list is still on the window
            -- stack, and a pick paints "Linking" on the menu under it.
            UIManager:nextTick(function()
                if picked and spec.on_pick then spec.on_pick(picked) end
                if spec.on_close then spec.on_close() end
            end)
        end,
        over           = spec.over,
    }

    if spec.search then
        config.search_placeholder = function() return _("Search Hardcover\xE2\x80\xA6") end
        config.on_search_submit = function(q)
            if not q or q == "" then return end
            note = _("Searching Hardcover\xE2\x80\xA6")
            modal:refresh()
            -- The request runs on this thread; paint the line first.
            UIManager:forceRePaint()
            local ok, found = pcall(spec.search, q)
            if not ok or type(found) ~= "table" then
                note = _("Hardcover could not be searched. The list is unchanged.")
            elseif #found == 0 then
                note = T(_("Nothing on Hardcover matches \xE2\x80\x9C%1\xE2\x80\x9D."), q)
            else
                records = found
                note = nil
                modal.page = 1
            end
            modal:refresh()
            wantPage()
        end
    else
        config.no_search = true
    end

    -- Before the modal is made: it lays itself out then, and that layout is
    -- what is painted while the lookup runs (rig: a blank page).
    if spec.load then note = _("Asking Hardcover\xE2\x80\xA6") end
    modal = LibraryModal:new{ config = config, search_query = spec.search and spec.search_value or nil }
    if spec.load then
        UIManager:show(modal)
        UIManager:nextTick(function()
            if closed then return end
            -- On screen first: the lookup runs on this thread.
            UIManager:forceRePaint()
            local ok, found, err = pcall(spec.load)
            if closed then return end
            if not ok then found, err = nil, found end
            if type(found) ~= "table" then
                note = T(_("Hardcover could not be reached: %1"), tostring(err or _("no reply")))
            elseif #found == 0 then
                note = spec.empty_text or _("Nothing found on Hardcover.")
            else
                records, note = found, nil
            end
            modal.page = 1
            modal:refresh()
            wantPage()
        end)
        return true
    end
    UIManager:show(modal)
    wantPage()
    return true
end

return M
