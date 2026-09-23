-- tests/_test_spine_folder_sections.lua
-- On a spine shelf a folder's books spill out as labelled runs, wherever the
-- folder is reached from -- never a folder standing edge-on like a book.
--
-- Usage (from plugin root): lua tests/_test_spine_folder_sections.lua
--
-- Issue 420. Home already sectioned its folders on a spine shelf; a folder
-- drilled into from the cover view, or a shelf pinned to one, still went to
-- getAll, whose folder cards stood on the spine shelf as narrow book-like
-- spines. A wider spine with a folder glyph was tried and rejected
-- (maintainer: "we can't show folders as books, even with the icon"). Both
-- routes now section the folder from its own root down.

package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local repo = io.open("lib/bookshelf_book_repository.lua"):read("*a")
local w    = io.open("lib/bookshelf_widget.lua"):read("*a")

t.test("a folder source sections on a spine shelf, rooted at the folder", function()
    assert(repo:find('if (kind == "all" or kind == "folder") and Repo.spine_light then', 1, true),
        "a shelf pinned to a folder still stands its subfolders up as spines")
    assert(repo:find("sopts.root = source.id", 1, true))
end)

t.test("a drilled-into folder does too", function()
    local at = w:find("sopts.root = tip.payload.path", 1, true)
    assert(at, "drilling into a folder on a spine shelf still lists folder cards")
    local get_all = w:find("return Repo.getAll(tip.payload.path", 1, true)
    assert(get_all and at < get_all, "the spine branch must come before the folder-card fetch")
end)

t.test("getFolderSections walks a folder under the library once, via the library's walk", function()
    local body = repo:match("\nfunction Repo%.getFolderSections%(.-%)\n(.-)\nend\n")
    assert(body)
    assert(body:find("local root = (opts and opts.root) or lib_root", 1, true))
    assert(body:find("local walk = cachedWalk(walk_root, depth)", 1, true),
        "a drill re-walks the disk instead of reusing the library walk")
    assert(body:find("_getLightMetaCache(walk_root, depth)", 1, true))
end)

-- The prefix filter, run for real on the section rules.
t.test("only the folder's own tree is sectioned", function()
    local FS = dofile("lib/bookshelf_folder_sections.lua")
    local walk = {
        { fp = "/lib/Other/x.epub" },
        { fp = "/lib/T/own.epub" },
        { fp = "/lib/T/A/a1.epub" }, { fp = "/lib/T/A/a2.epub" },
        { fp = "/lib/T2/not-inside.epub" },
    }
    local prefix, inside = "/lib/T/", {}
    for _i, c in ipairs(walk) do
        if c.fp:sub(1, #prefix) == prefix then inside[#inside + 1] = c end
    end
    local labels = {}
    for _i, s in ipairs(FS.group(inside, "/lib/T")) do labels[#labels + 1] = tostring(s.label) end
    eq(table.concat(labels, ","), "nil,A", "a sibling folder with a shared prefix leaked in")
end)

t.done()
