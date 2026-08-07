-- tests/_test_drill_rekey.lua
-- Regression tests for lib/bookshelf_drill_rekey: re-keying a moved book's
-- filepath inside live drilldown payloads.
--
-- These exist because the logic regressed twice on device:
--   1. The move flow first REMOVED the old path (delete-path behaviour),
--      so a book moved from inside a collection vanished from it.
--   2. The re-key then updated `books` but not the parallel `books_meta`,
--      and _applyWithinGroupSort rebuilds books as the INTERSECTION of the
--      two keyed on filepath -- so the book still vanished, this time only
--      on chips carrying a second sort level (which is why it survived the
--      first round of testing).
-- The intersection test below is the one that would have caught #2.
--
-- Usage: lua tests/_test_drill_rekey.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()
local eq = helpers.eq

local Rekey = require("lib/bookshelf_drill_rekey")

local OLD = "/h/A/moved.epub"
local NEW = "/h/B/moved.epub"

-- A collection/series drilldown as the widget builds it: `books` renders,
-- `books_meta` is the parallel light-metadata array used for sorting.
local function groupDrill()
    return {
        {
            kind = "tag", label = "To be read",
            payload = {
                books = {
                    { filepath = "/h/A/keep1.epub" },
                    { filepath = OLD },
                    { filepath = "/h/A/keep2.epub" },
                },
                books_meta = {
                    { filepath = "/h/A/keep1.epub" },
                    { filepath = OLD },
                    { filepath = "/h/A/keep2.epub" },
                },
            },
        },
    }
end

-- What _applyWithinGroupSort actually does: rebuild books as the entries
-- of books_meta that still have a match in books, keyed on filepath. If
-- the two arrays disagree, entries silently disappear from the view.
local function intersect(payload)
    local by_fp = {}
    for _i, b in ipairs(payload.books) do by_fp[b.filepath] = b end
    local out = {}
    for _i, m in ipairs(payload.books_meta) do
        if by_fp[m.filepath] then out[#out + 1] = by_fp[m.filepath] end
    end
    return out
end

t.test("re-keys the book in books, and does not remove it", function()
    local drill = groupDrill()
    Rekey.apply(drill, OLD, NEW)
    local books = drill[1].payload.books
    eq(#books, 3, "book count must not change - a move is not a removal")
    eq(books[2].filepath, NEW)
    eq(books[1].filepath, "/h/A/keep1.epub", "unrelated book touched")
    eq(books[3].filepath, "/h/A/keep2.epub", "unrelated book touched")
end)

t.test("re-keys the parallel books_meta array too", function()
    local drill = groupDrill()
    Rekey.apply(drill, OLD, NEW)
    eq(drill[1].payload.books_meta[2].filepath, NEW)
end)

t.test("REGRESSION: sort intersection keeps the moved book visible", function()
    local drill = groupDrill()
    local payload = drill[1].payload
    eq(#intersect(payload), 3, "precondition: nothing dropped before the move")
    Rekey.apply(drill, OLD, NEW)
    local visible = intersect(payload)
    eq(#visible, 3, "moved book dropped out of the sorted view")
    local paths = {}
    for _i, b in ipairs(visible) do paths[#paths + 1] = b.filepath end
    eq(paths, { "/h/A/keep1.epub", NEW, "/h/A/keep2.epub" })
end)

t.test("search payload: bare filepath strings are re-keyed", function()
    local drill = {
        { kind = "search", payload = {
            book_fps = { "/h/A/keep1.epub", OLD },
            folders  = { { path = "/h/A", first_book_fp = OLD } },
        } },
    }
    Rekey.apply(drill, OLD, NEW)
    eq(drill[1].payload.book_fps, { "/h/A/keep1.epub", NEW })
    eq(drill[1].payload.folders[1].first_book_fp, NEW)
    eq(drill[1].payload.folders[1].path, "/h/A", "folder path is not a book path")
end)

t.test("nested group lists (series inside a search payload)", function()
    local drill = {
        { kind = "search", payload = {
            series = { { series_name = "S",
                         books      = { { filepath = OLD } },
                         books_meta = { { filepath = OLD } } } },
        } },
    }
    Rekey.apply(drill, OLD, NEW)
    eq(drill[1].payload.series[1].books[1].filepath, NEW)
    eq(drill[1].payload.series[1].books_meta[1].filepath, NEW)
end)

t.test("every level of the drill stack is re-keyed, not just the tip", function()
    local drill = {
        { kind = "author", payload = { books = { { filepath = OLD } } } },
        { kind = "tag",    payload = { books = { { filepath = OLD } } } },
    }
    Rekey.apply(drill, OLD, NEW)
    eq(drill[1].payload.books[1].filepath, NEW, "parent level left stale")
    eq(drill[2].payload.books[1].filepath, NEW)
end)

t.test("folder drilldown payload survives untouched", function()
    -- Folder views re-query the filesystem on render, so their payload
    -- holds a path, not book records. Nothing to re-key, nothing to break.
    local drill = { { kind = "folder", payload = { path = "/h/A" } } }
    eq(Rekey.apply(drill, OLD, NEW), 0)
    eq(drill[1].payload.path, "/h/A")
end)

t.test("returns how many entries were touched", function()
    eq(Rekey.apply(groupDrill(), OLD, NEW), 2, "books + books_meta")
    eq(Rekey.apply(groupDrill(), "/h/A/absent.epub", NEW), 0)
end)

t.test("guards: nil args, same path, empty stack", function()
    eq(Rekey.apply(nil, OLD, NEW), 0)
    eq(Rekey.apply({}, OLD, NEW), 0)
    eq(Rekey.apply(groupDrill(), OLD, nil), 0)
    eq(Rekey.apply(groupDrill(), OLD, OLD), 0, "same path must be a no-op")
end)

t.done()
