-- tests/_test_library_modal_done.lua
-- A multi-select filter picker (Home > Filters > Status) left the reader
-- wondering what to do after ticking: its only way on was the back chevron
-- or a tap outside (maintainer, PW5). A footer action marked `done` stays a
-- button in the footer, and is also what the chevron and a tap outside run.
--
-- Usage (from plugin root): lua tests/_test_library_modal_done.lua
package.path = "./?.lua;" .. package.path
local t  = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq
local src = io.open("lib/bookshelf_library_modal.lua"):read("*a")
local LibraryModal = {}
for _i, name in ipairs({ "_closeOnlyAction", "_backAction" }) do
    local body = src:match("(function LibraryModal:" .. name .. "%(%).-\nend)\n")
    assert(body, name .. " not found")
    assert(load("local LibraryModal, _ = ...\n" .. body))(LibraryModal, function(s) return s end)
end
local function modal(config)
    return setmetatable({ config = config }, { __index = LibraryModal })
end

t.test("a Done action stays in the footer", function()
    local done = { label = "Done", done = true, on_tap = function() end }
    local m = modal({ over = {}, footer_actions = { done } })
    eq(m:_closeOnlyAction(), nil, "Done was folded into the title bar")
end)

t.test("going back runs Done", function()
    local done = { label = "Done", done = true, on_tap = function() end }
    local m = modal({ over = {}, footer_actions = { done } })
    eq(m:_backAction(), done)
end)

t.test("a lone Back on a page is still the chevron", function()
    local back = { label = "Back", on_tap = function() end }
    local m = modal({ over = {}, footer_actions = { back } })
    eq(m:_closeOnlyAction(), back)
end)


-- The More... chip's menu: sized to its labels, not the screen (maintainer).
t.test("the More menu is as wide as its labels", function()
    local src = io.open("lib/bookshelf_library_modal.lua"):read("*a")
    local b = src:match("\nfunction LibraryModal:_showMoreChips%(.-\nend\n")
    assert(b and b:find("shrink_unneeded_width = true", 1, true), "the More menu is full width")
end)

t.done()
