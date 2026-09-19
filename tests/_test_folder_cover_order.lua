-- tests/_test_folder_cover_order.lua
-- A folder tile shows the book the folder itself would show first (#409).
--
-- WHAT NEEDS PINNING. The tile's book was the first path the library walk
-- returned: disk order, and spanning every depth under the folder, so a book
-- three levels down could front a folder whose first page shows something
-- else. The reporter read that as "sorted by filename", because disk order
-- usually looks like it.
--
-- The rule now has two parts, and the order between them matters: a book
-- sitting IN the folder beats one in a subfolder, because that is what
-- opening the folder puts in front of you; within each group the chip's own
-- sort decides. Deeper books stay as the fallback, since a folder holding
-- only subfolders still has to show something.
--
-- The collage takes the same ordered set, so its four are the four you meet
-- on opening the folder rather than four arbitrary ones from the walk.
--
-- Usage (from plugin root): lua tests/_test_folder_cover_order.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

-- The engine is pure; the repository function is exercised through a stubbed
-- membership list and light-metadata lookup, so no KOReader runtime is needed.
local SortEngine = dofile("lib/bookshelf_sort_engine.lua")

local TITLES = {
    ["/lib/Folder/zulu.epub"]        = "Zulu",
    ["/lib/Folder/alpha.epub"]       = "Alpha",
    ["/lib/Folder/mike.epub"]        = "Mike",
    ["/lib/Folder/Sub/aardvark.epub"] = "Aardvark",
    ["/lib/Folder/Sub/beta.epub"]     = "Beta",
}
-- Deliberately NOT in title order, and with the deep book first: this is what
-- a library walk hands over.
local WALK = {
    "/lib/Folder/Sub/aardvark.epub",
    "/lib/Folder/zulu.epub",
    "/lib/Folder/Sub/beta.epub",
    "/lib/Folder/mike.epub",
    "/lib/Folder/alpha.epub",
}

-- A miniature of Repo.folderCoverPaths' contract, loaded from the real source
-- so the test breaks if the implementation stops following it.
local src = io.open("lib/bookshelf_book_repository.lua"):read("*a")
local body = src:match("\nfunction Repo%.folderCoverPaths%(path, sort_priority, limit, opts%)\n(.-)\nend\n")
assert(body, "Repo.folderCoverPaths moved or was renamed")

local function callCoverPaths(priority, limit, match)
    local env = {
        Repo = { getFolderBookPaths = function() local c = {} for i, v in ipairs(WALK) do c[i] = v end return c end },
        SortEngine = SortEngine,
        _buildBookMetaLight = function(fp) return { filepath = fp, title = TITLES[fp] } end,
        _lightMetaForFp = function(_, fp) return { filepath = fp, title = TITLES[fp] } end,
        -- The per-folder memo the function now consults (its own suite is
        -- _test_folder_cover_cache); a fresh one per call keeps every case
        -- here measuring the ordering itself.
        _folder_cover_cache = {}, _folder_cover_cache_order = {},
        _capInsert = function(cache, _order, key, value) cache[key] = value end,
        ipairs = ipairs, table = table, type = type,
    }
    local fn, err = load("return function(path, sort_priority, limit, opts)\n" .. body .. "\nend",
        "folderCoverPaths", "t", env)
    assert(fn, err)
    return fn()("/lib/Folder", priority, limit, { match = match })
end

local BY_TITLE = { { key = "title" } }

t.test("a book in the folder beats a book in a subfolder", function()
    local got = callCoverPaths(BY_TITLE, 1)
    eq(got[1], "/lib/Folder/alpha.epub",
        "Aardvark sorts first overall but lives a level down, so the folder does not open on it")
end)

t.test("within the folder, the chip's sort decides", function()
    local got = callCoverPaths(BY_TITLE, 3)
    eq(table.concat(got, ","),
       "/lib/Folder/alpha.epub,/lib/Folder/mike.epub,/lib/Folder/zulu.epub")
end)

t.test("a collage's four run on into the subfolders once the folder is spent", function()
    local got = callCoverPaths(BY_TITLE, 4)
    eq(#got, 4)
    eq(got[4], "/lib/Folder/Sub/aardvark.epub", "the deeper books are the fallback, in sort order too")
end)

t.test("with no sort at all the walk's own order survives", function()
    local got = callCoverPaths(nil, 2)
    eq(table.concat(got, ","), "/lib/Folder/zulu.epub,/lib/Folder/mike.epub",
        "unsorted, the folder's own books still come before the deeper ones")
end)

t.test("a filter narrows the candidates before any of that", function()
    local got = callCoverPaths(BY_TITLE, 2, function(fp) return fp:find("m", 1, true) ~= nil end)
    eq(got[1], "/lib/Folder/mike.epub", "a filtered chip fronts its folder with a book that matches")
end)

t.test("the fetch asks for four, so a collage has its set", function()
    assert(src:find("Repo.folderCoverPaths, folder_path, priority, 4", 1, true),
        "the page hydration must ask for the collage's four, not just the cover's one")
end)

t.test("both hydration sites lead with it and keep the walk as a fallback", function()
    local n = select(2, src:gsub("local lead = cover_fps%[1%] or shape%.first_book_fp", ""))
    eq(n, 2, "expected both folder hydration sites to use the ordered lead, found " .. n)
end)

t.test("the collage reads the ordered set, not the raw walk", function()
    local row = io.open("lib/bookshelf_shelf_row.lua"):read("*a")
    assert(row:find("book_paths       = item.cover_fps or folder_fpaths", 1, true),
        "the collage must prefer the fetch's ordered set")
end)

t.done()
