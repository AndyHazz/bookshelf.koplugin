-- tests/_test_source_editor_hooks.lua
-- Issue 452 (kokomga port): a fetch-mode source's own shelf-editor buttons
-- take the place of the disabled "Server order" row, and a source's `info`
-- gets ctx.open like `open` does, so a download started from the details
-- dialog can offer to open the book.
-- Run from the plugin root: lua tests/_test_source_editor_hooks.lua
package.path = "./?.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()
local editor = io.open("lib/bookshelf_chip_editor.lua"):read("*a")
local widget = io.open("lib/bookshelf_widget.lua"):read("*a")

t.test("the editor asks a fetch-mode source for its rows", function()
    assert(editor:find("Sources.editorRows(draft.source.kind, draft)", 1, true),
        "the editor never asks the source for its rows")
end)

t.test("the source's rows replace the Server order row", function()
    assert(editor:find("row == sort_row and src_rows", 1, true),
        "the rows are not put in place of the sort row")
end)

t.test("a source button's done() saves the change and redraws", function()
    local cb = editor:match("local done = function%(%)(.-)end")
    assert(cb and cb:find("commit()", 1, true) and cb:find("rebuild()", 1, true),
        "done() does not save the change and rebuild")
end)

t.test("info gets ctx.open", function()
    local body = widget:match("function BookshelfWidget:_showSourceInfo%(.-\nend\n")
    assert(body, "_showSourceInfo moved")
    assert(body:find("open = function(path)", 1, true) and body:find("_launchReader", 1, true),
        "info's ctx has no open(path)")
end)

t.test("the working copy is a deep copy, so a refused change never reaches the saved shelf", function()
    assert(editor:find("local draft = Editor._deepCopy(target)", 1, true),
        "the working copy still shares nested tables with the saved shelf")
end)

t.test("a change tells the shelf when the source changed, and the drill resets", function()
    assert(editor:find("owed_info.source_changed = true", 1, true)
        and editor:find("if opts.on_change then opts.on_change(info) end", 1, true),
        "the rebuild does not say whether the source changed")
    local body = widget:match("function BookshelfWidget:_afterChipEdit%(.-\nend\n")
    assert(body and body:find("source_changed", 1, true) and body:find("_drilldown_path = {}", 1, true),
        "a changed source keeps the old drill")
end)

t.done()
