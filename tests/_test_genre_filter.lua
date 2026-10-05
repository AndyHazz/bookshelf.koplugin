-- tests/_test_genre_filter.lua
-- Pure tests for the Hardcover genre cleanup rules.
package.path = "./?.lua;./?/init.lua;" .. package.path
local settings = {}
package.loaded["lib/bookshelf_settings_store"] = {
    read = function(k) return settings[k] end,
    save = function(k, v) settings[k] = v end,
}
local G = require("lib/bookshelf_genre_filter")

local fails = 0
local function eq(a, b, name)
    local function ser(t) return type(t) == "table" and table.concat(t, "|") or tostring(t) end
    if ser(a) ~= ser(b) then
        fails = fails + 1
        print("FAIL " .. name .. ": got " .. ser(a) .. " want " .. ser(b))
    end
end

eq(G.filter({ "A", "B" }, nil), { "A", "B" }, "no rules = passthrough")
eq(G.filter({ "A", "a", " A " }, {}), { "A" }, "dedupes, trims")
eq(G.filter({ "Fiction", "Horror" }, { blocklist = { "FICTION" } }), { "Horror" }, "blocklist ignores case")
eq(G.filter({ "Sci-Fi", "Horror" }, { aliases = { { from = "sci-fi", to = "Science Fiction" } } }),
    { "Science Fiction", "Horror" }, "alias renames in place")
eq(G.filter({ "Sci-Fi", "Science Fiction" }, { aliases = { { from = "Sci-Fi", to = "science fiction" } } }),
    { "science fiction" }, "alias merges into existing tag, first position wins")
eq(G.filter({ "Adult", "Horror" }, { aliases = { { from = "Adult", to = "" } } }), { "Horror" }, "empty alias drops")
eq(G.filter({ "Sci-Fi" }, { aliases = { { from = "Sci-Fi", to = "SF" } }, blocklist = { "sf" } }),
    {}, "blocklist applies to the alias target")
eq(G.filter({ "Sci-Fi" }, { aliases = { { from = "Sci-Fi", to = "SF" } }, blocklist = { "sci-fi" } }),
    {}, "blocklist applies to the original name")
eq(G.filter({ "A", "B" }, { aliases = { { from = "A", to = "B" }, { from = "B", to = "C" } } }),
    { "B", "C" }, "aliases are one pass, not chained")
eq(G.filter({ "Sci-Fi", "X" }, { aliases = { { from = "Sci-Fi", to = "SF" } }, excluded = { "sci-fi" } }),
    { "X" }, "per-book exclusion matches the original name")
eq(G.filter({ "Sci-Fi", "X" }, { aliases = { { from = "Sci-Fi", to = "SF" } }, excluded = { "SF" } }),
    { "X" }, "per-book exclusion matches the renamed tag")
eq(G.filter({ "A" }, { blocklist = { "A" } }), {}, "empty result is {}")
eq(G.filter(nil, { blocklist = { "A" } }), {}, "nil list")

eq(G.union({ "A", "b" }, { "B", "C", "a" }), { "A", "b", "C" }, "union keeps base order")
eq(G.union(nil, { "X" }), { "X" }, "union nil base")

-- list / alias helpers
eq(G.listAdd({ "A" }, "a"), nil, "listAdd duplicate = no change")
eq(G.listAdd({ "A" }, "  "), nil, "listAdd empty = no change")
eq(G.listAdd({ "A" }, " B "), { "A", "B" }, "listAdd trims")
eq(G.listRemove({ "A", "B" }, "b"), { "A" }, "listRemove ignores case")
eq(G.listRemove({ "A" }, "Z"), nil, "listRemove miss = no change")
eq(G.aliasSet({}, "A", "a"), nil, "alias to itself ignored")
eq(#G.aliasSet({ { from = "A", to = "X" } }, "a", "Y"), 1, "aliasSet replaces by key")
eq(G.aliasSet({ { from = "A", to = "X" } }, "a", "Y")[1].to, "Y", "aliasSet new target")
eq(G.aliasSet({ { from = "A", to = "X" } }, "A", "X"), nil, "aliasSet unchanged")
eq(G.aliasRemove({ { from = "A", to = "X" } }, "a"), {}, "aliasRemove")

-- aliasRename: renaming a tag as shown reaches the raw names behind it
local ren = G.aliasRename({ { from = "Sci-Fi", to = "Science Fiction" }, { from = "SF", to = "Science Fiction" } },
    "Science Fiction", "Speculative")
eq(G.filter({ "Sci-Fi", "SF", "Science Fiction" }, { aliases = ren }), { "Speculative" },
    "rename reaches every alias producing the shown tag, and the tag itself")
eq(G.aliasRename({}, "Fantasy", "Fantasy"), nil, "rename to itself")
ren = G.aliasRename({ { from = "Sci-Fi", to = "Science Fiction" } }, "Science Fiction", "Sci-Fi")
eq(#ren, 1, "self-pointing alias dropped")
eq(ren[1].from, "Science Fiction", "rename back leaves the tag's own alias")
eq(G.filter({ "Sci-Fi", "Science Fiction" }, { aliases = ren }), { "Sci-Fi" }, "rename back result")
eq(G.filter({ "Sci-Fi" }, { aliases = G.aliasRename({ { from = "Sci-Fi", to = "SF" } }, "SF", "") }),
    {}, "rename shown tag to empty hides it")

-- settings-backed accessors
eq(G.addBlocked("Adult"), true, "addBlocked")
eq(G.addBlocked("adult"), false, "addBlocked duplicate")
eq(G.blocklist(), { "Adult" }, "blocklist persisted")
eq(G.setAlias("Sci-Fi", "Science Fiction"), true, "setAlias")
eq(G.excludeForBook("/a", "Fantasy"), true, "excludeForBook")
eq(G.excludedFor("/a"), { "Fantasy" }, "excludedFor")
eq(G.excludedFor("/b"), {}, "other book untouched")
eq(G.forBook({ "Adult", "Sci-Fi", "Fantasy", "Horror" }, "/a"),
    { "Science Fiction", "Horror" }, "forBook applies all three")
eq(G.forBook({ "Fantasy" }, "/b"), { "Fantasy" }, "exclusion is per book")
eq(G.restoreForBook("/a", "fantasy"), true, "restoreForBook")
eq(settings.hardcover_genre_excluded["/a"], nil, "empty exclusion list is removed")
eq(G.removeBlocked("ADULT"), true, "removeBlocked")
eq(G.removeAlias("sci-fi"), true, "removeAlias")

print(fails == 0 and "genre filter: all passed" or (fails .. " fail"))
os.exit(fails == 0 and 0 or 1)
