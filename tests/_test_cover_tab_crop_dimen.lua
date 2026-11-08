-- tests/_test_cover_tab_crop_dimen.lua
-- Tapping a page chevron on the book popup's Cover tab crashed KOReader
-- (issue 585, since 6.1.0). With flash_ui on, a text Button's tap highlight
-- repaints through the modal's cropping_widget at cropping_widget.dimen.
-- The Cover tab's body became a bare VerticalGroup (the grey controls
-- strip), and a VerticalGroup never sets a dimen: "attempt to index field
-- 'dimen' (a nil value)" in UIManager:widgetRepaint. Reproduced on the rig
-- (covertapdrv). The modal now crops to a borderless FrameContainer around
-- the native body, which records its dimen when painted, whatever the tab
-- builds.
--
-- bookshelf_reviews_modal.lua needs the full widget stack to load, so this
-- reads the source (comment lines stripped), as _test_reviews_modal_shape.
--
-- Usage (from plugin root): lua tests/_test_cover_tab_crop_dimen.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t = H.runner()

local code = {}
for line in io.lines("lib/bookshelf_reviews_modal.lua") do
    if not line:match("^%s*%-%-") then code[#code + 1] = line end
end
local src = table.concat(code, "\n")
local asm = src:match("function ReviewsModal:_assemble%(%)(.-)\nend\n")
assert(asm, "_assemble moved")

t.test("a native tab is cropped to a frame that records its dimen", function()
    assert(not asm:find("self.cropping_widget = is_native and body or nil", 1, true),
        "the crop is the bare tab body again: a VerticalGroup body has no dimen")
    assert(asm:find("FrameContainer:new{", 1, true),
        "the crop must be a FrameContainer (it sets dimen in paintTo)")
    assert(asm:find("vg[#vg + 1] = crop or body", 1, true),
        "the frame has to be in the window, or it is never painted and has no dimen")
end)

-- An icon button's tap flash goes through UIManager:widgetInvert, which asks
-- the crop for getCropRegion(): only a ScrollableContainer has one. The Edit
-- tab's body IS a scroll container (no strip), and wrapping it lost that
-- (rig audit, cropauditdrv). A scroll body is the crop itself, as in 6.3.2;
-- the frame answers getCropRegion for the rest.
t.test("a scroll body stays the crop and the frame answers getCropRegion", function()
    assert(asm:find("body.getCropRegion", 1, true),
        "a body that is already a scroll container must be the crop itself")
    assert(asm:find("getCropRegion = function", 1, true),
        "the frame needs a getCropRegion for an icon button's tap flash")
end)

t.done()
