-- tests/_test_library_modal_close.lua
-- InputText:onCloseWidget frees its keyboard but never closes it, so a
-- library modal closed with its search keyboard up (a cell tap or Close after
-- typing) left a modal VirtualKeyboard on the window stack swallowing every
-- tap; KOReader looked frozen (bookends fixed its copy in 5.30.0).
package.path = "./?.lua;" .. package.path
local t  = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq
local src = io.open("lib/bookshelf_library_modal.lua"):read("*a")
local body = src:match("(function LibraryModal:onCloseWidget%(%).-\nend)\n")
assert(body, "LibraryModal:onCloseWidget not found")
local dirty = 0
local UIManager = { setDirty = function() dirty = dirty + 1 end }
local LibraryModal = {}
assert(load("local LibraryModal, UIManager = ...\n" .. body))(LibraryModal, UIManager)

local function fakeModal(visible)
    local input = { closed = 0 }
    function input:isKeyboardVisible() return visible end
    function input:onCloseKeyboard() self.closed = self.closed + 1 end
    return { _search_input = input }, input
end

t.test("closing the modal closes a visible search keyboard", function()
    local modal, input = fakeModal(true)
    LibraryModal.onCloseWidget(modal)
    eq(input.closed, 1, "keyboard left on the window stack")
end)

t.test("closing the modal leaves a hidden keyboard alone", function()
    local modal, input = fakeModal(false)
    LibraryModal.onCloseWidget(modal)
    eq(input.closed, 0)
end)

t.test("closing a modal without a search box is safe, and still repaints and calls on_closed", function()
    local called = 0
    dirty = 0
    LibraryModal.onCloseWidget({ config = { on_closed = function() called = called + 1 end } })
    eq(dirty, 1, "no repaint"); eq(called, 1, "on_closed not called")
end)
