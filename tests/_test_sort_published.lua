-- tests/_test_sort_published.lua
-- Sort by publication year (issue 580): the year %published shows, oldest
-- first; books with no known year at the end either way; the answers are
-- remembered per record and dropped when background reads bring new dates.
-- Run from the plugin root: lua tests/_test_sort_published.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["logger"] = { dbg = function() end, info = function() end,
                             warn = function() end, err = function() end }
package.preload["lib/bookshelf_author_name"] = function()
    return dofile("lib/bookshelf_author_name.lua")
end
local years, asked = {}, 0
package.loaded["lib/bookshelf_published"] = {
    forRecord = function(b) asked = asked + 1; return years[b.filepath] or "" end,
}
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq
local SortEngine = dofile("lib/bookshelf_sort_engine.lua")

local function order(list)
    local out = {}
    for i, b in ipairs(list) do out[i] = b.filepath end
    return table.concat(out, ",")
end
local function books() return {
    { filepath = "/new", title = "A" }, { filepath = "/none", title = "B" },
    { filepath = "/old", title = "C" }, { filepath = "/mid", title = "D" },
} end

t.test("the key is registered and offered in the picker", function()
    local k = SortEngine.KEYS.published
    assert(k and type(k.comparator) == "function", "no published key")
    local offered = false
    for _i, key in ipairs(SortEngine.ORDER) do if key == "published" then offered = true end end
    assert(offered, "not in ORDER, so the picker never shows it")
end)

t.test("oldest first; a book with no year goes to the end", function()
    years = { ["/new"] = "2020", ["/old"] = "1850", ["/mid"] = "1923" }
    SortEngine.clearPublishedMemo()
    eq(order(SortEngine.sort(books(), { { key = "published" } })), "/old,/mid,/new,/none")
end)

t.test("reversed: newest first, and still no year at the end", function()
    years = { ["/new"] = "2020", ["/old"] = "1850", ["/mid"] = "1923" }
    SortEngine.clearPublishedMemo()
    eq(order(SortEngine.sort(books(), { { key = "published", reverse = true } })), "/new,/mid,/old,/none")
end)

t.test("each record is asked once per sort, not on every comparison", function()
    years = { ["/new"] = "2020", ["/old"] = "1850", ["/mid"] = "1923" }
    SortEngine.clearPublishedMemo()
    asked = 0
    SortEngine.sort(books(), { { key = "published" } })
    assert(asked <= 4, "asked " .. asked .. " times for 4 books")
end)

t.test("a date read later is seen once the memo is cleared", function()
    years = {}
    SortEngine.clearPublishedMemo()
    local list = books()
    SortEngine.sort(list, { { key = "published" } })
    years = { ["/none"] = "1700" }
    SortEngine.clearPublishedMemo()
    SortEngine.sort(list, { { key = "published" } })
    eq(list[1].filepath, "/none")
end)

t.test("wiring: new dates clear the memo; a year-sorted shelf re-sorts, debounced", function()
    local pub = io.open("lib/bookshelf_published.lua"):read("*a")
    assert(pub:find('require("lib/bookshelf_sort_engine").clearPublishedMemo()', 1, true),
        "background dates must clear the sort's memo")
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    local body = w:match("\nfunction BookshelfWidget:_refreshPublished%(fps%)\n(.-)\nend\n")
    assert(body and body:find("self:_sortsByPublished()", 1, true), "no re-sort for a year-sorted shelf")
    assert(body:find('Repo.invalidateBookCache("published")', 1, true), "the sorted lists keep the old order")
end)

-- A first Decades shelf reads the whole library's dates, forty books a batch,
-- a batch every ~3 s on a PW5. Regrouping after each one rebuilt the shelf
-- dozens of times in a row; while reads continue it regroups at most every
-- RESORT_EVERY seconds, and once more when they finish.
t.test("a year-sorted shelf regroups at most every 15 s while dates are read, and once at the end", function()
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    local body = w:match("\nfunction BookshelfWidget:_refreshPublished%(fps%)\n(.-)\nend\n")
    assert(body, "_refreshPublished moved")
    local now, tasks = 0, {}
    local UI = {
        scheduleIn = function(_s, secs, fn) tasks[#tasks + 1] = { at = now + secs, fn = fn } end,
        unschedule = function(_s, fn)
            for i = #tasks, 1, -1 do if tasks[i].fn == fn then table.remove(tasks, i) end end
        end,
        setDirty = function() end,
    }
    local busy = true
    local env = setmetatable({
        UIManager = UI,
        Repo = { invalidateBookCache = function() end, findGroup = function() end },
        require = function(name)
            if name == "lib/bookshelf_published" then return { busy = function() return busy end } end
            return require(name)
        end,
    }, { __index = _G })
    local f = assert(load("return function(self, fps)\n" .. body .. "\nend", "rp", "t", env))()
    local rebuilds = 0
    local shelf = { _inner_vgroup = {}, _shelf_dims = {}, _drilldown_path = {},
        _sortsByPublished = function() return true end,
        _rebuild = function() rebuilds = rebuilds + 1 end }
    local function advance(to)
        while true do
            table.sort(tasks, function(a, b) return a.at < b.at end)
            local nxt = tasks[1]
            if not nxt or nxt.at > to then break end
            table.remove(tasks, 1)
            now = nxt.at
            nxt.fn()
        end
        now = to
    end
    -- 38 batches, one landing every 3.2 s: slower than the old 3 s debounce.
    for i = 1, 38 do
        advance(i * 3.2)
        busy = i < 38
        f(shelf, { "/b" .. i })
    end
    local during = rebuilds
    assert(during >= 7 and during <= 9, "regrouped " .. during .. " times in ~2 min of reads")
    advance(now + 2)
    eq(rebuilds, during + 1, "no regroup straight after the last batch")
    advance(now + 60)
    eq(rebuilds, during + 1, "regrouped again with nothing new")
end)

-- A spine never shows a publication date, so a date landing for a book on a
-- spine shelf repainted its spine for nothing: a metadata read, its look and
-- pixels dropped, and the page fetch expired, book by book as each batch of
-- dates came in (a flicker along the shelf on the PW5). The top panel can
-- show it (%published), so that still updates.
t.test("on a spine shelf a new date repaints the top panel only, never the spines", function()
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    local body = w:match("\nfunction BookshelfWidget:_refreshPublished%(fps%)\n(.-)\nend\n")
    local env = setmetatable({ UIManager = { scheduleIn = function() end, unschedule = function() end,
        setDirty = function() end }, Repo = {}, require = require }, { __index = _G })
    local f = assert(load("return function(self, fps)\n" .. body .. "\nend", "rp", "t", env))()
    local function shelf(spines)
        local s = { _inner_vgroup = {}, _shelf_dims = {}, refreshed = {}, hero = 0, rebuilds = 0,
            _page_items = { { filepath = "/a" }, { filepath = "/b" } },
            _preview_book = { filepath = "/a" },
            _sortsByPublished = function() return false end,
            _isSpineMode = function() return spines end,
            _rebuild = function(self) self.rebuilds = self.rebuilds + 1 end,
            _swapHeroInPlace = function(self) self.hero = self.hero + 1 end }
        s._refreshSpineInPlace = function(self, fp) self.refreshed[#self.refreshed + 1] = fp end
        return s
    end
    local sp = shelf(true)
    f(sp, { "/a", "/b" })
    eq(#sp.refreshed, 0, "repainted spines for a date they cannot show")
    eq(sp.rebuilds, 0)
    eq(sp.hero, 1, "the top panel's date did not update")
    local cov = shelf(false)
    f(cov, { "/a", "/b" })
    eq(#cov.refreshed, 2, "a cover shelf's captions can show the date")
end)

t.test("a folder view's file entry (fp, attr) sorts by its year too", function()
    years = { ["/f/old.epub"] = "1850", ["/f/new.epub"] = "2020" }
    SortEngine.clearPublishedMemo()
    local list = { { name = "new.epub", fp = "/f/new.epub", attr = { mode = "file" } },
                   { name = "old.epub", fp = "/f/old.epub", attr = { mode = "file" } },
                   { name = "Sub", fp = "/f/Sub", attr = { mode = "directory" } } }
    SortEngine.sort(list, { { key = "published" } })
    eq(list[1].fp, "/f/old.epub"); eq(list[2].fp, "/f/new.epub")
end)

t.test("the shelf editor offers it, with dated directions", function()
    local ed = io.open("lib/bookshelf_chip_editor.lua"):read("*a")
    assert(ed:find('add(chips({ "title", "author_name", "author_surname", "filename", "published" }))', 1, true),
        "Publication year is not on the Sort page")
    assert(ed:find('if key == "last_opened" or key == "date_added" or key == "added_or_opened"\n            or key == "published" then', 1, true),
        "its directions read A-Z / Z-A")
    assert(ed:find("    published    = true,", 1, true), "it should default to newest first")
end)

t.done()
