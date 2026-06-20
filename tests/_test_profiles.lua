-- tests/_test_profiles.lua

local Profiles = dofile("lib/bookshelf_profiles.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        pass = pass + 1
    else
        fail = fail + 1
        io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n")
    end
end

test("matchFile: prose roots map to prose profile", function()
    assert(Profiles.matchFile("/storage/emulated/0/ePubs/Fiktion/book.epub") == "prose")
    assert(Profiles.matchFile("/storage/emulated/0/ePubs/Facklitteratur/book.epub") == "prose")
    assert(Profiles.matchFile("/storage/emulated/0/ePubs/Lyrik/book.epub") == "prose")
end)

test("matchFile: comics roots map to comics profile", function()
    assert(Profiles.matchFile("/storage/emulated/0/ePubs/Manga/Attack on Titan/01.cbz") == "comics")
    assert(Profiles.matchFile("/storage/emulated/0/ePubs/Serier/album.cbz") == "comics")
end)

test("matchFile: unknown paths have no profile match", function()
    assert(Profiles.matchFile("/storage/emulated/0/Downloads/book.epub") == nil)
    assert(Profiles.matchFile(nil) == nil)
end)

test("locationForFile: prose root file selects its folder chip", function()
    local loc = Profiles.locationForFile(
        "/storage/emulated/0/ePubs/Fiktion/book.epub")
    assert(loc and loc.profile_key == "prose")
    assert(loc.chip_key == "profile_fiction")
    assert(loc.root == "/storage/emulated/0/ePubs/Fiktion")
    assert(loc.folder == loc.root)
end)

test("locationForFile: nested manga selects the series folder", function()
    local loc = Profiles.locationForFile(
        "/storage/emulated/0/ePubs/Manga/Attack on Titan/31.cbz")
    assert(loc and loc.profile_key == "comics")
    assert(loc.chip_key == "profile_manga")
    assert(loc.root == "/storage/emulated/0/ePubs/Manga")
    assert(loc.folder == "/storage/emulated/0/ePubs/Manga/Attack on Titan")
end)

test("locationForFile: unknown paths have no location", function()
    assert(Profiles.locationForFile("/storage/emulated/0/Downloads/book.epub") == nil)
    assert(Profiles.locationForFile(nil) == nil)
end)

test("folderSortPriority: prose defaults to author surname and comics defaults to series", function()
    assert(Profiles.folderSortPriority(Profiles.get("prose"))[1].key == "author_surname")
    assert(Profiles.folderSortPriority(Profiles.get("comics"))[1].key == "series_name")
end)

test("scope: profile roots are exposed for repository scoping", function()
    local scope = Profiles.scope(Profiles.get("prose"))
    assert(scope and scope.roots and #scope.roots == 3)
end)

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
