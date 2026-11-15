-- tests/_test_spine_marks_key.lua
-- Issue 605: the glyphs a narrow spine carries (favourite heart or star,
-- reading / finished / on-hold mark, series number) are baked into its cached
-- render. Changing the favourite icon, or any of the marks' spine switches or
-- styles, must miss that cache rather than serve the old picture until a
-- restart.
-- Run from the plugin root: lua tests/_test_spine_marks_key.lua
package.path = "./?.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t = H.runner()
local F = dofile("tests/_binding_fixture.lua")
package.loaded["lib/bookshelf_cover_progress"].favoriteIcon = function()
    return F.settings.fav_icon == "star" and "star" or "heart"
end
local Shelf = F.configure(require("lib/bookshelf_spine_shelf"))

-- A real save bumps the settings generation; set it directly and bump too.
local function set(k, v) F.settings[k] = v; F.flushes = F.flushes + 1 end

local function changes(k, a, b, why)
    set(k, a)
    local slot = F.slot(Shelf, nil)
    local before = slot:_renderKey(false)
    set(k, b)
    assert(slot:_renderKey(false) ~= before, why)
    set(k, nil)
end

t.test("the favourite icon is part of the render key", function()
    changes("fav_icon", "heart", "star", "the cache served the old favourite icon")
end)

t.test("the spine switches are part of it", function()
    changes("show_fav_badge_spines", true, false, "favourite switch for spines")
    changes("show_series_num_spines", true, false, "series number switch for spines")
    changes("progress_bookmark_spines", true, false, "bookmark switch for spines")
    changes("on_hold_spines", true, false, "on-hold switch for spines")
    changes("progress_badge_spines", true, false, "finished badge switch for spines")
end)

t.test("an unset spine switch follows covers, so the covers switch counts", function()
    changes("show_fav_badge", true, false, "favourite covers switch with spines unset")
end)

t.test("the styles behind the status glyph are part of it", function()
    changes("progress_badge_style", "bookmark", "tickbox", "finished badge style")
    changes("on_hold_display", "badge", "none", "on-hold display")
end)

t.test("an unrelated setting leaves the key alone", function()
    local slot = F.slot(Shelf, nil)
    local before = slot:_renderKey(false)
    set("some_unrelated_setting", 1)
    assert(slot:_renderKey(false) == before, "an unrelated save changed the spine key")
    set("some_unrelated_setting", nil)
end)

t.done()
