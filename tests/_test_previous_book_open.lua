-- tests/_test_previous_book_open.lua
-- Issue 617: a book opened from KOReader's file browser while the shelf was on
-- top (the top menu's Reader icon, "Previous: ...", the gesture) closed back
-- to the file browser. And newer KOReader rebuilds the reader menu's buttons on
-- first show, which dropped the shelf's File browser tab.

package.path = "./?.lua;./?/init.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()
local src = io.open("main.lua"):read("*a")

-- Compile Bookshelf._shelfIsFront out of main.lua against a fake UIManager.
local function shelfIsFront(stack)
    local a = src:find("function Bookshelf._shelfIsFront", 1, true)
    local b = src:find("\nend\n", a, true)
    local chunk = "local UIManager, Bookshelf = ...\n" .. src:sub(a, b + 4) .. "return Bookshelf._shelfIsFront"
    local fn = assert(loadstring or load)(chunk)
    return fn({ _window_stack = stack }, {})
end

local shelf = { covers_fullscreen = true }
local fm = { covers_fullscreen = true, menu = { menu_container = { covers_fullscreen = true } } }
local function stack(...)
    local s = {}
    for i, w in ipairs({ ... }) do s[i] = { widget = w } end
    return s
end

t.test("shelf on top counts as front", function()
    assert(shelfIsFront(stack(fm, shelf))(fm, shelf))
end)

t.test("the file browser's own menu over the shelf is ignored", function()
    assert(shelfIsFront(stack(fm, shelf, fm.menu.menu_container))(fm, shelf))
end)

t.test("a non-fullscreen popup over the shelf is ignored", function()
    assert(shelfIsFront(stack(fm, shelf, { name = "toast" }))(fm, shelf))
end)

t.test("buried under another full-screen layer is not front", function()
    assert(not shelfIsFront(stack(fm, shelf, { covers_fullscreen = true, name = "homescreen" }))(fm, shelf))
end)

t.test("not on the stack is not front", function()
    assert(not shelfIsFront(stack(fm))(fm, shelf))
end)

t.test("the previous-book wrap is installed from init and opens through the shelf", function()
    assert(src:find("self:_wirePreviousBookOpen()", 1, true), "called from init")
    local a = src:find("function Bookshelf:_wirePreviousBookOpen", 1, true)
    local body = src:sub(a, src:find("\nend\n", a, true))
    assert(body:find("fm.onOpenLastDoc = function", 1, true), "wraps onOpenLastDoc")
    assert(body:find("w:_openBook(", 1, true), "opens via the shelf")
    assert(body:find("return orig(fm_self, ...)", 1, true), "falls back to KOReader")
end)

t.test("the File browser tab is re-wrapped when the menu rebuilds its buttons", function()
    local a = src:find("function Bookshelf:_wireFastFileBrowserTab", 1, true)
    local body = src:sub(a, src:find("\nend\n", a, true))
    assert(body:find("menu_ref.getDefaultMenuButtons = function", 1, true))
    assert(body:find("_wrapFileBrowserItem(menu_ref, buttons.filemanager)", 1, true))
end)

t.done()
