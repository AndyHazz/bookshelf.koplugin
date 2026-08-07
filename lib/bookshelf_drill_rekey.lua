-- lib/bookshelf_drill_rekey.lua
-- Re-key a moved book's filepath inside the live drilldown payloads.
--
-- Extracted from bookshelf_widget so it can be unit-tested: the widget
-- itself can't load under the standalone test runner, and this logic has
-- already regressed twice.
--
-- Why re-key rather than remove: a moved book is still a member of a
-- series / author / genre / collection view - only its path changed.
-- Removing it (the delete-path behaviour) made a book moved from inside
-- a collection vanish until the view was re-entered.
--
-- Why every list, not just `books`: group payloads carry a PARALLEL
-- array, books_meta, holding light sort metadata. _applyWithinGroupSort
-- rebuilds group.books as the INTERSECTION of books and books_meta keyed
-- on filepath. Re-keying books alone therefore drops the moved book on
-- the next fetch, and a swipe-down refresh can't recover it because the
-- stale books_meta is re-intersected every time. That only bites chips
-- carrying a second sort level, which is what made it hard to spot.

local Rekey = {}

-- One list. Entries are either book records ({ filepath = ... }), bare
-- filepath strings (search payloads' book_fps), or nested groups that
-- carry their own books / books_meta arrays.
local function rekeyList(list, old_fp, new_fp)
    if type(list) ~= "table" then return end
    for i = 1, #list do
        local item = list[i]
        if type(item) == "string" then
            if item == old_fp then list[i] = new_fp end
        elseif type(item) == "table" then
            if item.filepath == old_fp then item.filepath = new_fp end
            if item.first_book_fp == old_fp then item.first_book_fp = new_fp end
            if type(item.first_book) == "table"
                    and item.first_book.filepath == old_fp then
                item.first_book.filepath = new_fp
            end
            rekeyList(item.books, old_fp, new_fp)
            rekeyList(item.books_meta, old_fp, new_fp)
        end
    end
end

-- Every path-bearing list a drilldown payload can hold.
local PAYLOAD_LISTS = {
    "books", "books_meta", "series", "authors",
    "genres", "folders", "book_fps",
}

-- apply(drill_path, old_fp, new_fp): rewrite in place. Returns the number
-- of payload entries touched, so callers (and tests) can assert the
-- re-key actually found something.
function Rekey.apply(drill_path, old_fp, new_fp)
    if not (drill_path and old_fp and new_fp) then return 0 end
    if old_fp == new_fp then return 0 end
    local touched = 0
    for _i, entry in ipairs(drill_path) do
        local payload = entry and entry.payload
        if type(payload) == "table" then
            for _j, key in ipairs(PAYLOAD_LISTS) do
                local list = payload[key]
                if type(list) == "table" then
                    local before = Rekey.countPath(list, old_fp)
                    rekeyList(list, old_fp, new_fp)
                    touched = touched + before
                end
            end
            if payload.first_book_fp == old_fp then
                payload.first_book_fp = new_fp
                touched = touched + 1
            end
            if type(payload.first_book) == "table"
                    and payload.first_book.filepath == old_fp then
                payload.first_book.filepath = new_fp
                touched = touched + 1
            end
        end
    end
    return touched
end

-- countPath(list, fp): how many entries in this list reference fp. Used
-- for the return count above and by tests asserting the invariant that
-- books and books_meta stay in agreement.
function Rekey.countPath(list, fp)
    if type(list) ~= "table" then return 0 end
    local n = 0
    for i = 1, #list do
        local item = list[i]
        if type(item) == "string" then
            if item == fp then n = n + 1 end
        elseif type(item) == "table" then
            if item.filepath == fp then n = n + 1 end
            if item.first_book_fp == fp then n = n + 1 end
            if type(item.first_book) == "table"
                    and item.first_book.filepath == fp then
                n = n + 1
            end
            n = n + Rekey.countPath(item.books, fp)
            n = n + Rekey.countPath(item.books_meta, fp)
        end
    end
    return n
end

return Rekey
