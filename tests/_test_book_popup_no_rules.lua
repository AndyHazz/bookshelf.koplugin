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

t.test("tab controls sit on one grey strip, edge to edge", function()
    local kit = read("lib/bookshelf_popup_kit.lua")
    local row = assert(kit:match("function Kit%.headerRow.-\nend\n"))
    assert(row:find("background = Kit.STRIP_BG", 1, true))
    assert(row:find("width = o.width", 1, true))
    -- The Description source switch and Hardcover's header use the same strip.
    local modal = read("lib/bookshelf_reviews_modal.lua")
    assert(method(modal, "_buildSourceChips"):find("PopupKit.headerRow{", 1, true))
    assert(method(widget, "_buildReviewsHeader"):find("PopupKit.STRIP_BG", 1, true))
end)

t.test("a long-press on an action card starts arranging", function()
    local edit = method(widget, "_buildBookEditTab")
    assert(edit:find("function() startArranging(id) end", 1, true))
    assert(edit:find("Arr.arrange(tile_specs", 1, true))
    -- Hidden cards stay out of the normal view.
    assert(edit:find("if not arranging then tile_specs = Arr.visible(tile_specs) end", 1, true))
    -- Reset puts back the default order with nothing hidden.
    assert(edit:find("arranging.order, arranging.hidden = order, {}", 1, true))
end)

t.test("the Cover tab's page nav counts the strip above its column", function()
    -- The strip sits outside the column; leaving it out of the sum put the
    -- nav a strip's height low and pushed the popup off the screen.
    local cover = method(widget, "_buildBookCoverTab")
    assert(cover:find("local used = toolbar_h   -- the strip above the column\n        for", 1, true))
end)

t.test("Include spoilers starts off with every popup and is never saved", function()
    assert(widget:find("reviews_tab = { data = data, html = html, show_spoilers = false }", 1, true))
    assert(not widget:find("Settings%.[%w_]+%([^)]*spoiler"), "the spoiler switch is saved")
    -- Only offered when Hardcover has spoiler reviews for the book.
    assert(method(widget, "_buildReviewsHeader"):find("if spoilers and tab.toggleSpoilers then", 1, true))
end)

t.test("Author(s) and Series share a row when both fit on one line", function()
    assert(widget:find('and sideBySide(sec.title, specs, _("Series"), by_cat.series)', 1, true))
    assert(widget:find("if not (a and b) or a:getSize().w + gap + b:getSize().w > pills_w then return nil end", 1, true))
    -- Series is not listed twice once it has joined the author row.
    assert(widget:find('not (sec.cat == "series" and series_paired)', 1, true))
end)

t.test("the grey strips have a shadow line under them", function()
    local kit = read("lib/bookshelf_popup_kit.lua")
    local row = assert(kit:match("function Kit%.headerRow.-\nend\n"))
    assert(row:find("Kit.withShadow(", 1, true))
    assert(method(widget, "_buildReviewsHeader"):find("PopupKit.withShadow(", 1, true))
end)

t.done()
