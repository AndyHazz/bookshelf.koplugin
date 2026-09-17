-- tests/_test_wallpaper_folder_hint.lua
-- The wallpaper picker always says where pictures come from.
--
-- WHAT CHANGED. The line naming the folder appeared only when the folder was
-- EMPTY, on the reasoning that a reader who already has pictures knows where
-- they put them. Bundling a picture breaks that reasoning: the folder is
-- never empty on a fresh install, so the one line that tells a reader how to
-- add their own would only ever be seen by someone who had first deleted the
-- shipped one (maintainer).
--
-- It sits at the END, after a divider: a footnote to the list, not a rival to
-- the pictures the reader came here to choose between.
--
-- Usage (from plugin root): lua tests/_test_wallpaper_folder_hint.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()
local src = io.open("lib/bookshelf_settings.lua"):read("*a")

local body = src:match("\nfunction Settings:_wallpaperSubItems%(key%)(.-)\nend\n")
    or src:match("\nfunction Settings:_wallpaperSubItems%((.-)\nend\n")
assert(body, "_wallpaperSubItems moved or was renamed")

t.test("the folder is named whether or not there are pictures", function()
    assert(body:find("folderHint", 1, true), "no always-on folder hint")
    -- After the loop that lists the pictures, not inside the empty branch.
    local at_empty = body:find("No images in", 1, true)
    local at_hint  = body:find("items[#items + 1] = folderHint()", 1, true)
    assert(at_hint, "the hint is never appended")
    assert(at_empty and at_hint > at_empty,
        "the hint must come after the empty-folder branch, so a populated "
        .. "folder reaches it too")
end)

t.test("it is a footnote: disabled, last, and below a divider", function()
    local hint = body:match("local function folderHint%(%)(.-)\n    end")
    assert(hint, "folderHint moved")
    assert(hint:find("enabled = false", 1, true),
        "the hint must not look pickable")
    assert(hint:find("Wallpaper.dir()", 1, true),
        "the hint must name the real folder, not a guess at it")
    assert(body:find("separator = (_i == #list) or nil", 1, true),
        "no divider between the last picture and the footnote")
end)

t.test("the empty-folder wording still exists for an empty folder", function()
    -- Two different sentences on purpose: one explains an absence, the other
    -- explains where to add more.
    assert(body:find("No images in", 1, true), "the empty case lost its message")
    assert(body:find("Images are loaded from", 1, true), "the footnote lost its message")
end)

t.done()
