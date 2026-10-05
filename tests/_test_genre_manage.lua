-- tests/_test_genre_manage.lua
-- Pure test for the genre shelf management helpers.
package.path = "./?.lua;./?/init.lua;" .. package.path
local M = require("lib/bookshelf_genre_manage")
local fails = 0
local function eq(a, b, name)
    local function ser(t) return type(t) == "table" and table.concat(t, "|") or tostring(t) end
    if ser(a) ~= ser(b) then fails = fails + 1; print("FAIL " .. name .. ": got " .. ser(a) .. " want " .. ser(b)) end
end
local cands = { ["/a"] = { "Science Fiction", "Fantasy" }, ["/b"] = { "fantasy" }, ["/c"] = nil }
local function candidates(fp) return cands[fp] end
eq(M.carriers({ "/a", "/b", "/c" }, "Fantasy", candidates), { "/a", "/b" }, "case-insensitive carriers")
eq(M.carriers({ "/a", "/b" }, "Horror", candidates), {}, "no carriers")
eq(M.carriers(nil, "X", candidates), {}, "nil paths")
print(fails == 0 and "genre manage: all passed" or (fails .. " fail"))
os.exit(fails == 0 and 0 or 1)
