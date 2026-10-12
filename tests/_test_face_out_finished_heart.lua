-- tests/_test_face_out_finished_heart.lua
-- 5.4.4: the Finished face-out reason, and the favourite mark on spine shelves.
--   * "finished" is a reason like "reading": stored as the bare string alone,
--     combined in a set otherwise, and it faces out books whose status is
--     "finished" (the repository's name for KOReader's "complete").
--   * A face-out favourite keeps its heart (it was always left off, so a
--     finished favourite showed only its tick), drawn top-right because the
--     status glyphs have the top-left on this shelf.
--   * An edge-on spine draws the favourite icon the reader chose (heart by
--     default); it was always the star.
-- Source-reading where the behaviour is a line in a long function, as
-- _test_face_out_first_unread.lua does; reintroduce each bug to see it fail.
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t, eq = helpers.runner(), helpers.eq

local shelf  = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")
local widget = io.open("lib/bookshelf_spine_widget.lua"):read("*a")
local editor = io.open("lib/bookshelf_chip_editor.lua"):read("*a")

-- The spec parser, run for real (the same chunk _test_face_out.lua loads).
local chunk = shelf:match("(SpineShelf%.FACE_REASONS = .-\nfunction SpineShelf%.faceOutEmpty.-\nend\n)")
assert(chunk, "could not find FACE_REASONS..faceOutEmpty")
local env = { SpineShelf = {}, ipairs = ipairs, pairs = pairs, type = type,
              tonumber = tonumber, math = math }
local f = _G.setfenv and (function() local g = assert(_G.loadstring(chunk)); _G.setfenv(g, env); return g end)()
    or assert(load(chunk, "faceout", "t", env))
f()
local SS = env.SpineShelf

t.test("finished is a face-out reason", function()
    local listed = false
    for _i, k in ipairs(SS.FACE_REASONS) do if k == "finished" then listed = true end end
    assert(listed, "finished is not in FACE_REASONS")
    eq(SS.faceOutSpec("finished").finished, true)
    eq(SS.faceOutSpec("finished").favorites, nil)
    local spec = SS.faceOutSpec{ finished = true, unread = true }
    eq(spec.finished, true); eq(spec.unread, true)
    eq(SS.faceOutEmpty(SS.faceOutSpec{ finished = true }), false)
end)

t.test("on hold is one too", function()
    eq(SS.faceOutSpec("on_hold").on_hold, true)
    eq(SS.faceOutSpec{ on_hold = true, finished = true }.finished, true)
    assert(shelf:find('or (face_spec.on_hold and (src.status == "on_hold" or src.status == "abandoned"))', 1, true),
        "the plan no longer tests books on hold")
    local labels = editor:match("local FACE_LABELS = (%b{})")
    assert(labels and labels:find('on_hold   = _("On hold")', 1, true), "no On hold label")
end)

t.test("it faces out books marked finished", function()
    -- Records carry "finished" (Repo maps KOReader's "complete" to it), so a
    -- test for "complete" alone faced out nothing: caught on the rig.
    assert(shelf:find('or (face_spec.finished and (src.status == "finished" or src.status == "complete"))', 1, true),
        "the plan no longer tests finished books")
end)

t.test("the picker labels it, beside the other reading states", function()
    local labels = editor:match("local FACE_LABELS = (%b{})")
    assert(labels and labels:find('finished  = _("Finished")', 1, true), "no Finished label")
    assert(editor:find('{ toggle("unread"), toggle("reading"), toggle("on_hold"), toggle("finished") }', 1, true))
end)

t.test("a face-out favourite keeps its heart, top-right", function()
    local tile = shelf:match("elseif e%.face_out then(.-)glyphs_top_left = true")
    assert(tile, "could not find the face-out tile")
    assert(not tile:find("suppress_favorite_badge", 1, true),
        "the face-out tile hides the heart again")
    assert(tile:find("favorite_top_right = true", 1, true), "the heart is not moved top-right")
    assert(widget:find("if self.favorite_top_right then", 1, true),
        "the cover tile ignores favorite_top_right")
end)

t.test("an edge-on spine draws the reader's favourite icon", function()
    local block = shelf:match("if e%.favourite and not e%.face_out then(.-)\n    end\n")
    assert(block, "could not find the spine's favourite mark")
    assert(block:find("CoverProgress.favoriteIcon()", 1, true), "the spine ignores the icon setting")
    assert(block:find("FAV_GLYPH_HEART", 1, true))
end)

t.done()
