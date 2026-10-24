-- tests/_test_shelf_module_face_out.lua
-- A Shelf module shows its shelf's books face-out as the shelf does: a recent
-- shelf set to all face-out showed mostly spines in the module (maintainer,
-- PW5), because the module planned its rows with no face-out choice at all.
--
-- Usage (from plugin root): lua tests/_test_shelf_module_face_out.lua
package.path = "./?.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()
local ss = assert(io.open("lib/bookshelf_spine_shelf.lua")):read("*a")

local body = assert(ss:match("\n(function SpineShelf%.faceOutFor%(tab%).-\nend)\n"), "no SpineShelf.faceOutFor")
local stored = nil
local SS = { FACE_REASONS = { "favorites", "reading", "first", "recent" } }
assert(load(body, "f", "t", { SpineShelf = SS, type = type, ipairs = ipairs, pcall = pcall,
    require = function(name)
        assert(name == "lib/bookshelf_settings_store", name)
        return { read = function() return stored end }
    end }))()

t.test("the shelf's own choice, as stored", function()
    assert(SS.faceOutFor({ spine_face_out = "all" }) == "all")
    local set = { reading = true }
    assert(SS.faceOutFor({ spine_face_out = set }) == set)
    assert(SS.faceOutFor({ spine_face_out = false }) == false, "none is a choice, not unset")
end)

t.test("unset, the library's, else favourites", function()
    stored = "reading"
    assert(SS.faceOutFor({}) == "reading")
    stored = nil
    assert(SS.faceOutFor({}) == "favorites")
    assert(SS.faceOutFor(nil) == "favorites")
end)

t.test("the Shelf module plans with it, and the recent ones", function()
    local shelf = assert(io.open("micromodules/shelf.lua")):read("*a")
    local spine = shelf:match("\nlocal function spineBody%(ctx, tab, w, h, gap, label%)\n(.-)\nend\n")
    assert(spine:find("face_out      = SpineShelf.faceOutFor(tab),", 1, true), "no face-out choice")
    assert(spine:find("SpineShelf.recentSetForItems(", 1, true), "\"recent N\" has nothing to count")
    local w = assert(io.open("lib/bookshelf_widget.lua")):read("*a")
    assert(w:find("return require(\"lib/bookshelf_spine_shelf\").faceOutFor(tab)", 1, true),
        "the main shelf resolves it another way")
end)

t.done()
