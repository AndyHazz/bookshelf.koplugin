-- tests/_test_book_popup_no_rules.lua
-- The book popup's tabs draw lines only in the popup's frame (book popup
-- redesign): a rule inset or run to the frame edge beside controls that stop
-- at the inset read as a line ending nowhere. Controls are closed rounded
-- shapes from lib/bookshelf_popup_kit, so the tabs share one look.
-- Run from the plugin root: lua tests/_test_book_popup_no_rules.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()

local function read(p) local f = assert(io.open(p)); local s = f:read("*a"); f:close(); return s end
local widget = read("lib/bookshelf_widget.lua")
local function method(src, name)
    return assert(src:match("\nfunction [%w_]+:" .. name .. "%(.-\nend\n"), "no " .. name)
end

t.test("the review header and the review text have no rule between them", function()
    assert(not method(widget, "_headedHtmlBody"):find("LineWidget", 1, true))
    local modal = read("lib/bookshelf_reviews_modal.lua")
    assert(not method(modal, "_buildSourcedBody"):find("LineWidget", 1, true))
end)

t.test("highlights are parted by space, not rules", function()
    local hl = read("lib/bookshelf_book_highlights.lua")
    local build = assert(hl:match("\nfunction M%.buildTab%(.-\nend\n"))
    assert(not build:find("LineWidget", 1, true))
end)

t.test("source switches and the status control are the kit's rounded control", function()
    assert(method(widget, "_segmentedChips"):find("PopupKit.segmented{", 1, true))
    assert(method(widget, "_buildBookEditTab"):find("PopupKit.segmented{", 1, true))
    local modal = read("lib/bookshelf_reviews_modal.lua")
    assert(method(modal, "_buildSourceChips"):find("PopupKit.segmented{", 1, true))
end)

t.test("an editable Tags section carries its Edit in the heading", function()
    assert(method(widget, "_sectionHeadingBar"):find("action", 1, true))
    assert(widget:find("headingWithEdit(sec.title, editCollections)", 1, true))
    assert(widget:find("headingWithEdit(sec.title, editGenres)", 1, true))
    -- An underlined link, not a bordered pill a tag could be mistaken for.
    assert(widget:find("local link = PopupKit.textLink{", 1, true))
end)

t.test("an unreviewed book gets a Write a review tile", function()
    assert(method(widget, "_buildMyReviewBody"):find('PopupKit.wideTile{', 1, true))
end)

t.done()
