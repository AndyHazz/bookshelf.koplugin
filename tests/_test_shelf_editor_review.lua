-- tests/_test_shelf_editor_review.lua
-- Fixes from the 2026-10-31 review of the shelf editor.
--
-- Usage (from plugin root): lua tests/_test_shelf_editor_review.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t = H.runner()
local src = io.open("lib/bookshelf_chip_editor.lua"):read("*a")
local lm = io.open("lib/bookshelf_library_modal.lua"):read("*a")

local function body(text, head)
    local s = text:find(head, 1, true)
    assert(s, "not found: " .. head)
    local e = text:find("\n    end\n", s, true) or text:find("\nend\n", s, true)
    return text:sub(s, e)
end

-- Re-tapping the source a shelf already has ran its defaults (a Recently
-- read shelf's sort went back to Most recently read on the card) and left
-- that in the working copy for the next change to save.
t.test("the same source again puts the working copy back", function()
    local b = body(src, "local function sourceChosen()")
    assert(b:find("if Editor._sameValue(draft.source, committed.source) then revert(); rebuild(); return end", 1, true),
        "a re-tapped source keeps its defaults' sort")
end)

-- Ticks on a filter page left by the X (or Back) were lost, or stayed in the
-- working copy for the next unrelated change to save.
t.test("closing the editor keeps what the working copy holds", function()
    local b = body(src, "local function finish()")
    assert(b:find("if not Editor._sameValue(draft, committed) then commit() end", 1, true),
        "finish drops the working copy's changes")
end)

t.test("Back on the keys in a page of the editor goes back a page", function()
    local b = body(lm, "function LibraryModal:onClose()")
    assert(b:find("local back = self.config and self.config.over and self:_backAction()", 1, true)
        and b:find("back.on_tap()", 1, true), "Back closes a page of the editor without going back")
end)

-- Each up or down rewrote the whole settings file (~130 ms on a PW5) and
-- rebuilt the shelf at once; rapid taps queued behind it.
t.test("Shelf order keeps its moves in memory and lets the shelf catch up", function()
    local b = body(src, "function Editor:_openShelfOrder(")
    assert(b:find("TabModel.saveDeferred(all)", 1, true), "every move writes the settings file")
    assert(not b:find("TabModel.save(all)", 1, true))
    local caller = src:match("self:_openShelfOrder%(tab_id, (.-), editOther%)")
    assert(caller and caller:find("schedulePreview", 1, true), "every move rebuilds the shelf at once")
end)

t.done()
