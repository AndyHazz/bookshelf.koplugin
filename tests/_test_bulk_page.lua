-- tests/_test_bulk_page.lua
-- The bulk "Edit selected" menu is a page (lib/bookshelf_page_dialog), laid
-- out like the book popup's Edit tab, not a stock button grid; a staged
-- choice tapped again is un-staged (segmented allow_none).
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t = H.runner()

local function read(p) return io.open(p):read("*a") end

t.test("bulk edit opens a page dialog, not a ButtonDialog", function()
    local s = read("lib/bookshelf_bulk_actions.lua")
    assert(s:find('require("lib/bookshelf_page_dialog").show{', 1, true), "no page dialog")
    assert(not s:find("ui/widget/buttondialog", 1, true), "still builds a ButtonDialog")
    assert(not s:find("STAGED_BG", 1, true), "staging still shown as a grey fill")
    for _i, f in ipairs({ "status", "rating", "favorite" }) do
        assert(s:find('allow_none = true, on_pick = stage("' .. f .. '")', 1, true),
            f .. " cannot be un-staged")
    end
end)

t.test("a segmented control un-picks its active cell only with allow_none", function()
    local s = read("lib/bookshelf_popup_kit.lua")
    local body = s:match("function Kit%.segmented%(o%)(.-)\nend\n")
    assert(body and body:find("elseif o.allow_none then o.on_pick(nil) end", 1, true),
        "no allow_none un-pick")
    local pg = read("lib/bookshelf_editor_page.lua")
    local _n, c = pg:gsub("allow_none = b%.allow_none", "")
    assert(c == 2, "the page's segmented block does not pass allow_none (both forms)")
end)

t.test("the bulk Collections picker opens as a page of the bulk menu", function()
    local s = read("lib/bookshelf_bulk_actions.lua")
    assert(s:find('over           = dialog and dialog:over({ _("Collections") }),', 1, true),
        "the picker is not opened over the page")
    local cm = read("lib/bookshelf_collection_manager.lua")
    assert(cm:find("over           = opts.over,", 1, true), "the collection manager drops over")
    assert(not cm:find("to the bulk menu.\")", 1, true), "the hint still talks about a diff")
    local lm = read("lib/bookshelf_library_modal.lua")
    assert(lm:find("local back = self:_backAction()", 1, true),
        "back on a Cancel | Save page does nothing")
end)

-- Review 2026-10-31: the summary was "Apply will %s." filled with
-- lower-cased fragments ("mark reading"), which broke other languages.
t.test("what Apply will do is whole phrases, one a line; rating's clear says Clear", function()
    local src = io.open("lib/bookshelf_bulk_actions.lua"):read("*a")
    assert(not src:find(":lower()", 1, true), "a translated label is lower-cased")
    assert(not src:find('_("mark %s")', 1, true) and not src:find('_("Apply will %s.")', 1, true),
        "the summary is still built from fragments")
    assert(src:find('T(_("Apply will:\\n%1"), table.concat(parts, "\\n"))', 1, true), "not one change a line")
    assert(src:find('rating_items[6] = { key = "clear", label = _("Clear") }', 1, true), "clearing the rating says None")
end)

t.done()
