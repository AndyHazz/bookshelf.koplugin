-- tests/_test_decades_wiring.lua
-- The Decades shelf in the chip editor and on the shelf: offered beside
-- Languages, named and iconned, kept by plugins' hands off its kind names,
-- its drill restored after sleep, its long-press making a one-decade shelf,
-- and dates arriving from the background read regrouping it.
-- Usage (from plugin root): lua tests/_test_decades_wiring.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t = H.runner()

local function read(p) return io.open(p):read("*a") end
local editor = read("lib/bookshelf_chip_editor.lua")
local widget = read("lib/bookshelf_widget.lua")
local sources = read("lib/bookshelf_sources.lua")

t.test("the chip editor offers Decades and A decade", function()
    assert(editor:find('stackChip("decades", _("Decades")', 1, true), "no Decades stack chip")
    assert(editor:find('oneChip("decade", _("A decade"), group_pick("decade"))', 1, true), "no A decade chip")
    assert(editor:find('decades       = function() return _("Decades")', 1, true), "no Decades source label")
    assert(editor:find('decade        = function() return _("Decade")', 1, true), "no Decade source label")
    assert(editor:find("decades = true", 1, true), "Decades is not a group kind in the editor")
end)

t.test("a Decades shelf sorts by decade then year, newest first", function()
    local d = editor:match("\n    decades%s*= ({.-}),\n")
    assert(d and d:find('key = "published"', 1, true) and d:find("reverse = true", 1, true),
        "no published-newest-first default sort for decades: " .. tostring(d))
end)

t.test("plugins cannot take the decade kinds", function()
    assert(sources:find(" decades ", 1, true) or sources:find(" decades\"", 1, true), "decades not reserved")
    assert(sources:find(" decade ", 1, true) or sources:find(" decade\"", 1, true), "decade not reserved")
end)

t.test("the drill survives sleep and re-sorts like the other group kinds", function()
    local _n, hits = widget:gsub('or e%.kind == "decade"', "")
    assert(hits >= 2, "decade drills are not saved and restored")
    assert(widget:find('or tip.kind == "decade"', 1, true), "decade drill not re-sorted on fetch")
end)

t.test("long-press on a decade makes a one-decade shelf", function()
    local g = widget:match("\n    decade = {(.-)\n    },\n")
    assert(g and g:find('source_kind%s*=%s*"decade"'), "no GROUP_KINDS.decade")
    assert(widget:find("GROUP_KINDS[group.kind]", 1, true),
        "the group menu still treats every non-series stack as a series")
end)

t.test("dates arriving regroup a Decades shelf", function()
    local body = widget:match("function BookshelfWidget:_sortsByPublished%(%)(.-)\nend\n")
    assert(body and body:find('"decades"', 1, true) and body:find('"decade"', 1, true),
        "_sortsByPublished ignores a Decades shelf")
end)

t.test("a decade's books sort by the same year that filed them", function()
    local repo = read("lib/bookshelf_book_repository.lua")
    -- Both copies the within-group sort reads (the member record and the
    -- cached books_meta) carry what Published.info reads ahead of the file.
    local build = repo:match("\nlocal function _buildGroups%(.-\nend\n")
    assert(build, "_buildGroups moved")
    local member = build:match("g%.books%[#g%.books %+ 1%] = {(.-)\n                            }")
    assert(member, "member record moved")
    assert(member:find("calibre%s*=%s*book%.calibre"), "member record drops calibre")
    assert(member:find("hardcover_published%s*=%s*book%.hardcover_published"), "member record drops hardcover_published")
    local shapes = repo:match("\nlocal function _cacheGroupShapes%(.-\nend\n")
    assert(shapes, "_cacheGroupShapes moved")
    local meta = shapes:match("books_meta%[#books_meta %+ 1%] = {(.-)\n            }")
    assert(meta, "books_meta record moved")
    assert(meta:find("calibre%s*=%s*b%.calibre"), "books_meta drops calibre")
    assert(meta:find("hardcover_published%s*=%s*b%.hardcover_published"), "books_meta drops hardcover_published")
end)

t.test("an open decade regroups when dates arrive", function()
    local body = widget:match("self%._published_resort = function%(%)(.-)\n        end\n")
    assert(body and body:find('kind == "decade"', 1, true) and body:find('Repo.findGroup("decade"', 1, true),
        "the resort leaves an open decade's stale books in place")
end)

t.test("long-press stores the decade as the picker does, by its label", function()
    local g = widget:match("\n    decade = {(.-)\n    },\n")
    assert(g and g:find('source_id_field%s*=%s*"series_name"'), "decade shelf id is not the card label")
end)

t.done()
