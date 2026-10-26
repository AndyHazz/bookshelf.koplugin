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

t.test("the Tags tab has one Edit for the whole tab, not one per section", function()
    -- One button toggles the tab's edit mode; editing puts a cross in each
    -- removable tag and "+ Add" after each editable group.
    assert(widget:find("local tags_editing = false", 1, true))
    assert(not widget:find("headingWithEdit", 1, true))
    assert(widget:find("pillsFrame(editSpecs(specs or {}, leaveCollection, editCollections))", 1, true))
    assert(widget:find("function(it) applyEdit(withoutGenre(it.label)) end, editGenres))", 1, true))
end)

t.test("an inverted chip button keeps its rounded corners", function()
    local chip = read("lib/bookshelf_chip_button.lua")
    local paint = assert(chip:match("function ChipFrame:paintTo.-\nend\n"))
    -- invertRect once for the box, then again for the corners.
    local _, n = paint:gsub("invertRect", "")
    assert(n > 1, "corners outside the radius are not restored")
end)

t.test("every tab's own actions are the kit's header button", function()
    -- One control for Edit, Refresh, Write a review and the Cover tools, so
    -- the tabs' top rows match.
    assert(method(widget, "_buildMyReviewBody"):find("PopupKit.headerButton{", 1, true))
    assert(method(widget, "_buildReviewsHeader"):find("PopupKit.headerButton{", 1, true))
    local cover = method(widget, "_buildBookCoverTab")
    local _, n = cover:gsub("PopupKit%.headerButton{", "")
    assert(n == 2, "Cover's two tools")
    assert(widget:find("local btn = PopupKit.headerButton{\n                        text      = tags_editing", 1, true))
end)

t.done()
