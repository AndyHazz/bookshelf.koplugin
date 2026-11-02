-- tests/_test_cover_match_light.lua
-- A filtered folder tile's cover pick checks the filter against the shared
-- light-metadata map, not a fresh BookInfoManager read per book. Each such
-- read loads the book's whole row, cover included: a 1371-book folder on a
-- filtered shelf of shelves cost 25 s and 250 MB a time on the PW5, again on
-- every rebuild (a filtered call is never memoised).
-- Driven against the real closure, extracted from Repo.getAll.
-- Usage (from plugin root): lua tests/_test_cover_match_light.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

local src = io.open("lib/bookshelf_book_repository.lua"):read("*a")
local body = src:match("\n    local function _folderCoverFps%(folder_path%)\n(.-)\n    end\n")
assert(body, "getAll's _folderCoverFps moved or was renamed")

local function run(light_map)
    local builds = 0
    local seen_match
    local env = setmetatable({
        _cover_match_built = false, _cover_match = nil, filter = { status = { reading = true } },
        Filter = { isActive = function() return true end, compile = function() return "compiled" end },
        Repo = { filterOpts = function() return {} end,
                 folderCoverPaths = function(_p, _pr, _l, o) seen_match = o.match; return {} end },
        _buildBookMetaLight = function(fp) builds = builds + 1; return { filepath = fp, status = "new" } end,
        _recordMatches = function(rec, _c) return rec.status == "reading" end,
        _coverLightCache = function() return light_map end,
        priority = {},
    }, { __index = _G })
    local f = assert((loadstring or load)("local folder_path = ...\n" .. body))
    if setfenv then setfenv(f, env) else f = assert(load("local folder_path = ...\n" .. body, "c", "t", env)) end
    f("/lib/Folder")
    return seen_match, function() return builds end
end

t.test("a book the light map knows is matched from it, with no BIM read", function()
    local match, builds = run({ ["/lib/Folder/a.epub"] = { filepath = "/lib/Folder/a.epub", status = "reading" } })
    eq(match("/lib/Folder/a.epub"), true)
    eq(builds(), 0, "a per-book BIM read for a book the map had")
end)

t.test("a book the map doesn't know falls back to its own read", function()
    local match, builds = run({})
    eq(match("/lib/Folder/b.epub"), false)
    eq(builds(), 1)
end)

t.test("no map at all still works", function()
    local match, builds = run(nil)
    eq(match("/lib/Folder/c.epub"), false)
    eq(builds(), 1)
end)

t.done()
