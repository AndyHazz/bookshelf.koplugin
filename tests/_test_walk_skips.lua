-- tests/_test_walk_skips.lua
-- Issue 590: with the home folder at the top of the device, the library walk
-- statted every file of KOReader's own installation, the system's folders
-- and every book's .sdr; and KOReader's settings live in its own folder
-- there, so each settings save moved a walked folder's mtime and the next
-- shelf walked the whole device again. The walk passes a .sdr or a plainly
-- non-book file by its name, and inside KOReader's data folder it skips
-- KOReader's own folders by name and never records the data folder's own
-- mtime (the settings saves move it). Books kept in a folder of their own
-- there -- KOReader's News downloader saves to koreader/news by default --
-- are still found: 6.4.0 skipped the whole data folder and lost them.
--
-- Drives the real walkBooks, lifted out of the repository by name, over a
-- fake file system that counts its stats.
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq
local src = io.open("lib/bookshelf_book_repository.lua"):read("*a")

local WALK = assert(src:match("\nlocal function walkBooks%(root, depth, out, current_depth, dirs, listings%)\n(.-)\nend\n"),
    "walkBooks moved")
local SUPPORTED = { epub = true, pdf = true, html = true, cbz = true }

-- tree: path -> { names } for folders; anything else is a file.
local function fs(tree)
    local stats = {}
    local lfs = {
        dir = function(p)
            local names = tree[p]
            if not names then error("not a folder: " .. p) end
            local i = 0
            return function() i = i + 1; return names[i] end, {}
        end,
        attributes = function(p, key)
            stats[#stats + 1] = p
            local mode = tree[p] and "directory" or "file"
            if key then return key == "mode" and mode or 0 end
            return { mode = mode, modification = 1, size = 1 }
        end,
    }
    return lfs, stats
end

local function walk(tree, root, data_dir, depth)
    local lfs, stats = fs(tree)
    local Repo = {
        _NOT_BOOK_EXT = assert(load("return " .. assert(src:match("Repo%._NOT_BOOK_EXT = (%b{})"))))(),
        _KO_OWN_DIRS = assert(load("return " .. assert(src:match("Repo%._KO_OWN_DIRS = (%b{})"))))(),
        _koreaderDataDir = function() return data_dir end,
    }
    local env = setmetatable({
        Repo = Repo,
        SYSTEM_DIR_NAMES = { proc = true },
        _joinPath = function(a, b) return a .. "/" .. b end,
        _supportedExt = function(name)
            local e = name:match("%.([^.]+)$")
            return e and SUPPORTED[e:lower()] and e:lower() or nil
        end,
        walkBooks = nil,
        logger = { warn = function() end },
        require = function(n) if n == "libs/libkoreader-lfs" then return lfs end return require(n) end,
    }, { __index = _G })
    local f
    if setfenv then
        f = assert(loadstring("return function(root, depth, out, current_depth, dirs, listings)\n" .. WALK .. "\nend"))
        setfenv(f, env)
    else
        f = assert(load("return function(root, depth, out, current_depth, dirs, listings)\n" .. WALK .. "\nend", "walk", "t", env))
    end
    local fn = f()
    env.walkBooks = fn
    local out, dirs = {}, {}
    fn(root, depth or 5, out, 0, dirs, {})
    local found = {}
    for _i, b in ipairs(out) do found[#found + 1] = b.fp end
    table.sort(found)
    return found, stats, dirs
end

local DEVICE = {
    ["/r"] = { "Books", "applications", "Photos.jpg" },
    ["/r/Books"] = { "A.epub", "A.sdr", "cover.jpg", "metadata.opf", "B.pdf", "Vol.2" },
    ["/r/Books/A.sdr"] = { "metadata.epub.lua" },
    ["/r/Books/Vol.2"] = { "C.epub" },
    ["/r/applications"] = { "koreader", "other" },
    ["/r/applications/koreader"] = { "settings", "reader.lua", "libs", "news", "books", "plugins", "cache", "docsettings" },
    ["/r/applications/koreader/settings"] = { "settings.reader.lua", "old.epub" },
    ["/r/applications/koreader/libs"] = { "libz.so" },
    ["/r/applications/koreader/news"] = { "Feed.epub" },
    ["/r/applications/koreader/books"] = { "Mine.epub" },
    ["/r/applications/koreader/plugins"] = { "x.koplugin" },
    ["/r/applications/koreader/plugins/x.koplugin"] = { "help.html" },
    ["/r/applications/koreader/cache"] = { "page.html" },
    ["/r/applications/koreader/docsettings"] = { "r" },
    ["/r/applications/koreader/docsettings/r"] = { "Books" },
    ["/r/applications/koreader/docsettings/r/Books"] = { "A.sdr" },
    ["/r/applications/other"] = { "manual.pdf" },
}

t.test("books in KOReader's folder are found; KOReader's own folders are never opened", function()
    local found, stats = walk(DEVICE, "/r", "/r/applications/koreader")
    eq(table.concat(found, " "), "/r/Books/A.epub /r/Books/B.pdf /r/Books/Vol.2/C.epub "
        .. "/r/applications/koreader/books/Mine.epub /r/applications/koreader/news/Feed.epub "
        .. "/r/applications/other/manual.pdf")
    for _i, own in ipairs({ "settings", "libs", "plugins", "cache", "docsettings" }) do
        local p = "/r/applications/koreader/" .. own
        for _j, s in ipairs(stats) do
            assert(s ~= p and not s:find(p .. "/", 1, true), "walked into KOReader's " .. own .. ": " .. s)
        end
    end
end)

t.test("a settings save in KOReader's folder does not make the walk stale", function()
    local _found, _stats, dirs = walk(DEVICE, "/r", "/r/applications/koreader")
    eq(dirs["/r/applications/koreader"], nil)
    assert(dirs["/r/applications/koreader/news"], "a new article in koreader/news would go unseen")
    assert(dirs["/r/Books"], "the ordinary folders are still tracked")
end)

t.test("a .sdr and a plainly non-book file cost no stat; a folder with a dot in its name still does", function()
    local _found, stats = walk(DEVICE, "/r", "/r/applications/koreader")
    local seen = {}
    for _i, p in ipairs(stats) do seen[p] = true end
    for _i, p in ipairs({ "/r/Books/A.sdr", "/r/Books/cover.jpg", "/r/Books/metadata.opf", "/r/Photos.jpg" }) do
        assert(not seen[p], "statted " .. p)
    end
    assert(seen["/r/Books/Vol.2"], "a folder named with a dot was passed over")
end)

t.test("a home folder that IS KOReader's folder: its mtime is not tracked, its books are found", function()
    local cw = assert(src:match("\nlocal function cachedWalk%(home, depth%)\n(.-)\nend\n"), "cachedWalk moved")
    assert(cw:find("if root_m and not (ko_dir and home:gsub(\"/+$\", \"\") == ko_dir) then", 1, true),
        "home = KOReader's folder records its mtime, so every settings save re-walks")
    local tree = {
        ["/k"] = { "news", "settings" },
        ["/k/news"] = { "F.epub" },
        ["/k/settings"] = { "x.epub" },
    }
    local found = walk(tree, "/k", "/k")
    eq(table.concat(found, " "), "/k/news/F.epub")
end)

t.test("a home folder inside KOReader's still walks its books", function()
    local tree = {
        ["/k"] = { "books" },
        ["/k/books"] = { "D.epub" },
    }
    local found = walk(tree, "/k/books", "/k")
    eq(found[1], "/k/books/D.epub")
end)

t.test("a never-opened book is answered from the folder listings, and a close drops its folder's", function()
    local R = src
    local has = assert(R:match("\nlocal function _hasSidecar%(filepath%)\n(.-)\nend\n"))
    assert(has:find("if Repo._historyDirAbsent() and not _customMetaPossible(filepath) then", 1, true),
        "every never-opened book is statted in each metadata location")
    assert(R:find("            _dir_entry_cache[parent] = nil", 1, true),
        "a book opened for the first time keeps reading as never opened (its folder's listing is stale)")
end)

t.done()
