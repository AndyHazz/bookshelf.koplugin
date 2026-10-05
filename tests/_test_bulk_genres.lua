-- tests/_test_bulk_genres.lua
-- Pure tests for the bulk genre editor's merge / change / apply logic.
package.path = "./?.lua;./?/init.lua;" .. package.path
local G = require("lib/bookshelf_bulk_genres")

local fails = 0
local function eq(a, b, name)
    local function ser(t) return type(t) == "table" and table.concat(t, "|") or tostring(t) end
    if ser(a) ~= ser(b) then
        fails = fails + 1
        print("FAIL " .. name .. ": got " .. ser(a) .. " want " .. ser(b))
    end
end

eq(G.merge({ "Fantasy", "Sci-Fi" }, { horror = "Horror" }, nil), { "Fantasy", "Sci-Fi", "Horror" }, "add appends")
eq(G.merge({ "Fantasy", "Sci-Fi" }, nil, { fantasy = "Fantasy" }), { "Sci-Fi" }, "remove")
eq(G.merge({ "Fantasy" }, { fantasy = "fantasy" }, nil), { "Fantasy" }, "add is case-insensitive, keeps spelling")
eq(G.merge({ "fantasy" }, nil, { fantasy = "Fantasy" }), {}, "remove is case-insensitive")
eq(G.merge(nil, { b = "B", a = "A" }, nil), { "A", "B" }, "nil current, sorted adds")
eq(G.merge({ "A", "a" }, nil, nil), { "A" }, "dedupes")
eq(G.changed({ "A" }, { "A" }), false, "unchanged")
eq(G.changed(nil, {}), false, "nil vs empty")
eq(G.changed({ "A" }, { "A", "B" }), true, "changed")

-- applyTo: reads everything before writing, skips no-op books, counts failures.
local log, written = {}, {}
local lists = { ["/a"] = { "Fantasy" }, ["/b"] = {}, ["/c"] = { "Horror" } }
local Repo = {
    lightMetaFor = function(fp)
        log[#log + 1] = "read " .. fp
        return { genre_sources = { embedded = lists[fp] } }
    end,
    setEmbeddedGenres = function(fp, list)
        log[#log + 1] = "write " .. fp
        if fp == "/c" then error("boom") end
        written[fp] = list
    end,
}
local ok, bad = G.applyTo({ "/a", "/b", "/c" }, { add = { fantasy = "Fantasy" }, remove = { horror = "Horror" } }, Repo)
eq(ok, 1, "applied count (a unchanged, b written, c failed)")
eq(bad, 1, "failed count")
eq(written["/b"], { "Fantasy" }, "b gets the genre")
eq(written["/a"], nil, "a untouched")
eq(log[3], "read /c", "all reads precede writes")

-- hideUpdates: hide lands only on books that have the tag; unhide restores.
local cands = { ["/a"] = { "Science Fiction", "Fantasy" }, ["/b"] = { "Fantasy" }, ["/c"] = { "Science Fiction" } }
local hidden = { ["/c"] = { "Science Fiction" }, ["/b"] = { "Old" } }
local function candidates(fp) return cands[fp] end
local function excluded(fp) return hidden[fp] end
local up = G.hideUpdates({ "/a", "/b", "/c" }, { hide = { ["science fiction"] = "Science Fiction" } }, candidates, excluded)
eq(up["/a"], { "Science Fiction" }, "hide lands on a book that has the tag")
eq(up["/b"], nil, "hide skips a book without the tag")
eq(up["/c"], nil, "hide on an already-hidden tag changes nothing")
up = G.hideUpdates({ "/a", "/b", "/c" }, { unhide = { ["science fiction"] = "Science Fiction", old = "Old" } }, candidates, excluded)
eq(up["/c"], {}, "unhide empties the list")
eq(up["/b"], {}, "unhide matches case-insensitively and per book")
eq(up["/a"], nil, "unhide skips books with nothing hidden")
up = G.hideUpdates({ "/a" }, { hide = { fantasy = "Fantasy", ["science fiction"] = "Science Fiction" } }, candidates, excluded)
eq(up["/a"], { "Fantasy", "Science Fiction" }, "several hides, sorted")

-- A hide typed by the tag's original name still lands when an alias renames it.
up = G.hideUpdates({ "/a" }, { hide = { ["sci-fi"] = "Sci-Fi" } }, candidates, excluded,
    function() return { "Sci-Fi" } end)
eq(up["/a"], { "Sci-Fi" }, "hide by original name")
up = G.hideUpdates({ "/a" }, { hide = { ["sci-fi"] = "Sci-Fi" } }, candidates, excluded)
eq(up["/a"], nil, "without raw names it does not match")

print(fails == 0 and "bulk genres: all passed" or (fails .. " fail"))
os.exit(fails == 0 and 0 or 1)
