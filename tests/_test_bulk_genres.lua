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

print(fails == 0 and "bulk genres: all passed" or (fails .. " fail"))
os.exit(fails == 0 and 0 or 1)
