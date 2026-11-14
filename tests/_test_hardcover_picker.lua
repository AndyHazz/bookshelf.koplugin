-- tests/_test_hardcover_picker.lua
-- Bookshelf's own list for choosing a Hardcover book or edition
-- (lib/bookshelf_hardcover_picker), on the library modal the other pickers
-- use. With a sync plugin's client the list is that plugin's dialog; this one
-- is for Bookshelf's own client.
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t, eq = helpers.runner(), helpers.eq

package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
package.loaded["ffi/util"] = { template = function(s, ...)
    local a = { ... }
    return (s:gsub("%%(%d)", function(i) return tostring(a[tonumber(i)]) end))
end }
package.loaded["device"] = { screen = {
    getWidth = function() return 1236 end, getHeight = function() return 1648 end,
} }
local shown, closed, repaints, painted_note
package.loaded["ui/uimanager"] = {
    show = function(_s, w) shown = w end,
    close = function(_s, w)
        closed = w
        if w.config and w.config.on_closed then w.config.on_closed() end
    end,
    nextTick = function(_s, fn) fn() end,
    forceRePaint = function()
        repaints = repaints + 1
        painted_note = shown and shown.config.intro and shown.config.intro()
    end,
}
local cells
package.loaded["lib/bookshelf_space"] = { px = function(v) return v end }
package.loaded["lib/bookshelf_hardcover_picker_row"] = {
    -- A cell's height for its width: the cover's, a third of the width.
    cellHeight = function(w, share) return math.floor(w * (share or 1 / 3) * 1.5) end,
    coverSize = function(w, share)
        local cw = math.floor(w * (share or 0.32)); return cw, math.floor(cw * 1.5)
    end,
    render = function(item, dimen, opts)
        cells[#cells + 1] = { item = item, opts = opts or {} }
        return { cell = true }
    end,
}
-- Covers: which addresses are on disk, and the loader the picker drives.
local on_disk, wanted, loader_stopped, on_loaded, failed_urls
package.loaded["lib/bookshelf_hardcover_thumbs"] = {
    urlOf = function(rec) return type(rec.cached_image) == "table" and rec.cached_image.url or nil end,
    cached = function(url) return on_disk[url] end,
    newLoader = function(o)
        on_loaded = o.on_loaded
        return {
            want = function(_s, recs) wanted[#wanted + 1] = recs end,
            hasFailed = function(_s, url) return failed_urls[url] == true end,
            stop = function() loader_stopped = true end,
        }
    end,
}
package.loaded["lib/bookshelf_library_modal"] = {
    new = function(_s, o)
        -- The real modal lays itself out when it is made: what its intro
        -- says THEN is what is painted first (rig: a blank page).
        o.intro_at_new = o.config and o.config.intro and o.config.intro()
        o.refreshed = 0
        o.refresh = function(self) self.refreshed = self.refreshed + 1 end
        o.cells_refreshed = {}
        o.refreshCell = function(self, item) self.cells_refreshed[#self.cells_refreshed + 1] = item end
        o.page = 1
        return o
    end,
}

local Picker = dofile("lib/bookshelf_hardcover_picker.lua")

local BOOK = {
    book_id = 432300, title = "The Able McLaughlins", release_year = 1923,
    users_read_count = 3, pages = 268,
    book_series = { { position = 1, series = { name = "The McLaughlins" } } },
    contributions = { { author = { name = "Margaret Wilson" }, contribution = "Author" } },
}
local EDITION = {
    book_id = 432300, edition_id = 29308305, title = "The Able McLaughlins", release_year = "1923",
    edition_format = "Paperback", publisher = "Cherokee Pub. Co.", pages = 268, users_count = 22,
    language = { code2 = "en", language = "English" },
    contributions = BOOK.contributions,
}

local function reset()
    shown, closed, repaints, cells = nil, nil, 0, {}
    on_disk, wanted, loader_stopped, on_loaded, failed_urls = {}, {}, false, nil, {}
end

-- "the book cover thumbnails are quite small ... maybe a larger thumbnail
-- and a 4 row x 2 column layout with wrapping text" (maintainer).
t.test("the grid: 2 x 4 in portrait, 3 x 2 in landscape, cells as tall as their cover", function()
    reset()
    Picker.show{ title = "T", records = { BOOK }, on_pick = function() end }
    local cfg = shown.config
    eq(cfg.grid_cols, 2); eq(cfg.cells_per_page(), 8)
    -- Content 1000 wide: cells (1000 - 10) / 2 = 495, each 495 / 3 * 1.5 tall.
    local cell = math.floor(math.floor((1000 - 10) / 2) / 3 * 1.5)
    eq(cfg.area_height(1000, nil), 4 * cell + 3 * 10)
    eq(cfg.area_height(1000, 500), 500, "taller than the room on the screen")
    local scr = package.loaded["device"].screen
    local gw, gh = scr.getWidth, scr.getHeight
    scr.getWidth, scr.getHeight = gh, gw
    reset()
    Picker.show{ title = "T", records = { BOOK }, on_pick = function() end }
    eq(shown.config.grid_cols, 3); eq(shown.config.cells_per_page(), 6)
    scr.getWidth, scr.getHeight = gw, gh
end)

-- Rig, a small screen with a DPI override (bigger text): two columns left
-- the title three lines and the author "Ben...". One column then.
t.test("text too big for two columns: one column of wider cells", function()
    local Space = package.loaded["lib/bookshelf_space"]
    local px = Space.px
    Space.px = function(v) return v * 3 end          -- a big DPI override
    reset()
    Picker.show{ title = "T", records = { BOOK }, on_pick = function() end }
    eq(shown.config.grid_cols, 1)
    eq(shown.config.cells_per_page(), 4)
    local cell = math.floor(1000 * 0.2 * 1.5)        -- the narrower cover share
    eq(shown.config.area_height(1000, nil), 4 * cell + 3 * 30)
    shown.config.cell_renderer(BOOK, {})
    eq(cells[#cells].opts.cover_share, 0.2, "the cell was not told its cover is narrower")
    Space.px = px
end)

-- The counts are a line of their own, at the cell's foot (maintainer:
-- "bottom align the pages/reads in a lighter font ... on one line").
t.test("a book's row: title and year, then author and series; the counts apart", function()
    local label, sub, stats = Picker.describe(BOOK)
    eq(label, "The Able McLaughlins (1923)")
    eq(sub, "Margaret Wilson \xC2\xB7 The McLaughlins #1")
    eq(stats, "268 pages \xC2\xB7 3 reads")
end)

t.test("an edition's row: what tells editions apart; the counts apart", function()
    local label, sub, stats = Picker.describe(EDITION)
    eq(label, "The Able McLaughlins (1923)")
    eq(sub, "Paperback \xC2\xB7 Cherokee Pub. Co. \xC2\xB7 English")
    eq(stats, "268 pages \xC2\xB7 22 readers")
end)

t.test("big counts are short, so the line fits", function()
    local _l, _s, stats = Picker.describe({ title = "T", pages = 1210, users_read_count = 51200 })
    eq(stats, "1,210 pages \xC2\xB7 51k reads")
    _l, _s, stats = Picker.describe({ title = "T", users_read_count = 1250000 })
    eq(stats, "1.3M reads")
    _l, _s, stats = Picker.describe({ title = "T", users_read_count = 9999 })
    eq(stats, "9,999 reads")
end)

t.test("a sparse record still makes a row", function()
    local label, sub, stats = Picker.describe({ book_id = 1, title = "Bare" })
    eq(label, "Bare"); eq(sub, nil); eq(stats, nil)
    label = Picker.describe({ book_id = 1 })
    eq(label, "Untitled")
    -- Two authors are named, a third is "and others"; no series position.
    local _l, s = Picker.describe({ title = "T", contributions = {
        { author = { name = "A" } }, { author = { name = "B" } }, { author = { name = "C" } } },
        book_series = { { series = { name = "S" } } } })
    eq(s, "A, B and others \xC2\xB7 S")
    -- One reader, one page.
    local _s2, st
    _l, _s2, st = Picker.describe({ title = "T", pages = 1, users_read_count = 1 })
    eq(st, "1 page \xC2\xB7 1 read")
end)

t.test("the list shows the records, and marks the one linked now", function()
    reset()
    Picker.show{ title = "Select Hardcover edition", records = { BOOK, EDITION },
        active = { edition_id = 29308305 }, on_pick = function() end }
    local cfg = shown.config
    eq(cfg.title, "Select Hardcover edition")
    eq(cfg.item_count(), 2)
    eq(cfg.grid_cols, 2, "one column of short rows: the covers were tiny")
    eq(cfg.no_search, true, "editions are not searched")
    cfg.cell_renderer(cfg.item_at(1), {})
    cfg.cell_renderer(cfg.item_at(2), {})
    eq(cells[1].item.label, "The Able McLaughlins (1923)")
    eq(cells[1].item.stats, "268 pages \xC2\xB7 3 reads", "the counts did not reach the cell")
    eq(cells[1].opts.selected, false)
    eq(cells[2].opts.selected, true)
    -- By book when that is what is known.
    reset()
    Picker.show{ title = "T", records = { BOOK }, active = { book_id = 432300 }, on_pick = function() end }
    shown.config.cell_renderer(shown.config.item_at(1), {})
    eq(cells[1].opts.selected, true)
end)

t.test("a tap closes the list, then links, then tells the caller it closed", function()
    reset()
    local order = {}
    Picker.show{ title = "T", records = { BOOK, EDITION },
        on_pick = function(rec) order[#order + 1] = "pick " .. tostring(rec.edition_id) end,
        on_close = function() order[#order + 1] = "close" end }
    shown.config.on_cell_tap(shown.config.item_at(2))
    eq(closed, shown)
    eq(order[1], "pick 29308305"); eq(order[2], "close"); eq(#order, 2)
end)

-- Device report: "The select hardcover edition menu has no
-- back/close/select/cancel". A lone Close is what the library modal draws as
-- the title bar's X, and what Back on the keys runs.
t.test("the list can be closed: one Close action, which links nothing", function()
    reset()
    local picked, closes = false, 0
    Picker.show{ title = "Select Hardcover edition", records = { EDITION },
        on_pick = function() picked = true end, on_close = function() closes = closes + 1 end }
    local actions = shown.config.footer_actions
    assert(type(actions) == "table" and #actions == 1, "no way to close the list")
    eq(actions[1].key, "close"); eq(actions[1].label, "Close")
    actions[1].on_tap()
    eq(closed, shown)
    eq(picked, false); eq(closes, 1)
end)

-- Opened from the Hardcover menu: up at once, as a page of the menu, and
-- the lookup after it is on screen (maintainer: "it closes the modal and
-- there's a pause before anything happens").
t.test("load: the list is up at once and says so, then fills", function()
    reset()
    local loaded = false
    local over = { crumbs = "Hardcover \xE2\x80\xBA Select edition" }
    Picker.show{ title = "Select Hardcover edition", over = over,
        load = function() loaded = true; return { EDITION, BOOK } end,
        on_pick = function() end }
    eq(shown.config.over, over, "not a page of the menu")
    eq(shown.intro_at_new, "Asking Hardcover\xE2\x80\xA6", "the first layout had no Asking line")
    eq(painted_note, "Asking Hardcover\xE2\x80\xA6", "nothing was painted before the lookup")
    eq(loaded, true)
    eq(shown.config.item_count(), 2)
    eq(shown.config.intro(), nil)
    eq(wanted[#wanted][1], EDITION, "covers were not asked for once the list came")
end)

t.test("load: a failure or an empty answer is said in the list", function()
    reset()
    Picker.show{ title = "T", load = function() return nil, "Could not fetch Hardcover editions" end,
        on_pick = function() end }
    eq(shown.config.item_count(), 0)
    eq(shown.config.intro(), "Hardcover could not be reached: Could not fetch Hardcover editions")
    reset()
    Picker.show{ title = "T", load = function() return {} end, empty_text = "No editions on Hardcover.",
        on_pick = function() end }
    eq(shown.config.intro(), "No editions on Hardcover.")
    reset()
    Picker.show{ title = "T", load = function() error("boom") end, on_pick = function() end }
    assert(shown.config.intro():find("could not be reached", 1, true), "a throw left the list saying Asking")
end)

t.test("closing without a pick links nothing", function()
    reset()
    local picked, closes = false, 0
    Picker.show{ title = "T", records = { BOOK }, on_pick = function() picked = true end,
        on_close = function() closes = closes + 1 end }
    shown.config.on_closed()
    eq(picked, false); eq(closes, 1)
end)

t.test("a search replaces the list and goes back to the first page", function()
    reset()
    local asked
    Picker.show{ title = "T", records = { BOOK }, search_value = "Able",
        search = function(text) asked = text; return { EDITION, BOOK, BOOK } end,
        on_pick = function() end }
    local cfg = shown.config
    eq(cfg.no_search, nil)
    eq(shown.search_query, "Able", "the box does not start with what was searched")
    shown.page = 3
    cfg.on_search_submit("Rivers of London")
    eq(asked, "Rivers of London")
    eq(cfg.item_count(), 3); eq(cfg.item_at(1), EDITION)
    eq(shown.page, 1)
    assert(repaints >= 1, "no sign that a search is under way")
    eq(cfg.intro(), nil, "the 'Searching' line stayed up")
end)

t.test("a search that fails or finds nothing says so and keeps the list", function()
    reset()
    local reply
    Picker.show{ title = "T", records = { BOOK }, search = function() return reply end,
        on_pick = function() end }
    local cfg = shown.config
    reply = nil
    cfg.on_search_submit("x y")
    eq(cfg.item_count(), 1)
    eq(cfg.intro(), "Hardcover could not be searched. The list is unchanged.")
    reply = {}
    cfg.on_search_submit("x y")
    eq(cfg.item_count(), 1)
    eq(cfg.intro(), "Nothing on Hardcover matches \xE2\x80\x9Cx y\xE2\x80\x9D.")
    -- An emptied box is not a search.
    reply = { EDITION }
    cfg.on_search_submit(nil)
    eq(cfg.item_count(), 1)
end)

-- "We need lazy loaded cover images in the library picker, like the plugins
-- have" (maintainer).
local function withCover(id, url) return { book_id = id, title = "B" .. id, cached_image = { url = url } } end

t.test("covers: a row shows its cover when it is on disk, and a space for it when not", function()
    reset()
    local A, B = withCover(1, "https://a/1.jpg"), withCover(2, "https://a/2.jpg")
    on_disk["https://a/1.jpg"] = "/cache/1.img"
    Picker.show{ title = "T", records = { A, B }, on_pick = function() end }
    shown.config.cell_renderer(A, {}); shown.config.cell_renderer(B, {})
    eq(cells[1].item.cover_path, "/cache/1.img")
    eq(cells[2].item.cover_path, nil)
end)

-- PW5, a "Dracula" search: three cells stayed blank. Hardcover has no
-- picture for those books; the blank box read as one still loading.
t.test("covers: none on Hardcover, or a failed download, says No cover; loading does not", function()
    reset()
    local none = { book_id = 1, title = "No picture" }
    local bad = withCover(2, "https://a/bad.jpg")
    local coming = withCover(3, "https://a/3.jpg")
    failed_urls["https://a/bad.jpg"] = true
    Picker.show{ title = "T", records = { none, bad, coming }, on_pick = function() end }
    for _i, r in ipairs({ none, bad, coming }) do shown.config.cell_renderer(r, {}) end
    eq(cells[1].item.no_cover, true)
    eq(cells[2].item.no_cover, true)
    eq(cells[3].item.no_cover, nil, "a cover still coming was called missing")
end)

t.test("covers: the page on screen is asked for, and only that page", function()
    reset()
    local recs = {}
    for i = 1, 20 do recs[i] = withCover(i, "https://a/" .. i .. ".jpg") end
    Picker.show{ title = "T", records = recs, on_pick = function() end }
    local per = shown.config.cells_per_page()
    eq(#wanted, 1, "nothing asked for when the list opened")
    eq(#wanted[1], per); eq(wanted[1][1], recs[1])
    shown.page = 2
    shown.config.on_page_shown(2)
    eq(wanted[2][1], recs[per + 1])
    -- The last page is short.
    shown.page = 3
    shown.config.on_page_shown(3)
    eq(#wanted[3], 20 - 2 * per)
end)

t.test("covers: one that lands redraws its own row, not the list", function()
    reset()
    local A = withCover(1, "https://a/1.jpg")
    Picker.show{ title = "T", records = { A }, on_pick = function() end }
    local before = shown.refreshed
    on_loaded(A)
    eq(shown.cells_refreshed[1], A)
    eq(shown.refreshed, before, "the whole list was redrawn for one cover")
end)

t.test("covers: a search asks for the new list's first page", function()
    reset()
    local found = { withCover(7, "https://a/7.jpg") }
    Picker.show{ title = "T", records = { withCover(1, "https://a/1.jpg") },
        search = function() return found end, on_pick = function() end }
    shown.config.on_search_submit("something else")
    eq(wanted[#wanted][1], found[1])
end)

t.test("covers: closing the list stops the loader, and a late cover is ignored", function()
    reset()
    local A = withCover(1, "https://a/1.jpg")
    Picker.show{ title = "T", records = { A }, on_pick = function() end }
    shown.config.on_closed()
    eq(loader_stopped, true)
    local n = #shown.cells_refreshed
    on_loaded(A)
    eq(#shown.cells_refreshed, n, "a closed list was redrawn")
end)

t.test("no records and nothing to pick: an empty list still opens and closes", function()
    reset()
    local closes = 0
    Picker.show{ title = "T", records = {}, on_pick = function() end, on_close = function() closes = closes + 1 end }
    eq(shown.config.item_count(), 0)
    shown.config.on_closed()
    eq(closes, 1)
end)

t.done()
