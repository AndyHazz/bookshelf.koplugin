-- tests/_test_micro_fullscreen_open_hold.lua
-- Opening a book from a module in the full-screen micro-modules view keeps
-- the opening pose on screen until the book is up. Inside a book the old
-- reader closes first, which marks everything under it dirty, and KOReader's
-- showReader forces a repaint: the view repainted from its widgets, putting
-- the book back on its shelf before it opened (maintainer, PW5). The shelf
-- itself already skips that paint (_suppress_transition_paint); the view
-- now does the same.
--
-- Usage (from plugin root): lua tests/_test_micro_fullscreen_open_hold.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()

local fs = assert(io.open("lib/bookshelf_micro_fullscreen.lua")):read("*a")
local main = assert(io.open("main.lua")):read("*a")

t.test("the view skips its paint while a book is opening", function()
    local body = fs:match("\nfunction MicroFullscreen:paintTo%(bb, x, y%)\n(.-)\nend\n")
    assert(body, "paintTo moved")
    local hold = body:find("if MicroFullscreen.hold_paint then return end", 1, true)
    assert(hold, "no hold")
    assert(hold < body:find("InputContainer.paintTo", 1, true), "the hold comes after the paint")
end)

t.test("a book starting to open sets the hold, a ready reader clears it", function()
    local showing = main:match("\nfunction Bookshelf:onShowingReader%(%)\n(.-)\nend\n")
    local ready = main:match("\nfunction Bookshelf:onReaderReady%(%)\n(.-)\nend\n")
    assert(showing and ready, "handlers moved")
    -- Only when the view is loaded: requiring it here would load it for
    -- every book opened from anywhere.
    assert(showing:find('package.loaded["lib/bookshelf_micro_fullscreen"]', 1, true), "loads the view to set it")
    assert(showing:find("hold_paint = true", 1, true), "never set")
    assert(showing:find("hold_paint = nil", 1, true), "no time limit: a failed open would leave it blank")
    assert(ready:find("hold_paint = nil", 1, true), "never cleared")
end)

t.test("opening the view again clears a hold left over", function()
    local body = fs:match("\nfunction MicroFullscreen%.open%(bw, button_dimen, footer_h%)\n(.-)\nend\n")
    assert(body and body:find("MicroFullscreen.hold_paint = nil", 1, true))
end)

t.done()
