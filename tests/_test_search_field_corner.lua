-- tests/_test_search_field_corner.lua
-- InputText builds a new frame for its text on every keystroke
-- (initTextBox), so the search field's corner and white fill have to be
-- set again after each rebuild, not once.
--
-- Usage (from plugin root): lua tests/_test_search_field_corner.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t = H.runner()
local function read(p) return io.open(p):read("*a") end

t.test("the search field is styled again after each initTextBox", function()
    local lm = read("lib/bookshelf_library_modal.lua")
    local s = lm:find("input.initTextBox = function(this, ...)", 1, true)
    assert(s, "initTextBox is not wrapped: typing leaves the field square")
    local e = lm:find("\n        end\n", s, true)
    local body = lm:sub(s, e)
    assert(body:find("orig_initTextBox(this, ...)", 1, true), "the original initTextBox is not called")
    assert(body:find("styleField(this)", 1, true), "the rebuilt frame is not styled")
    local sf = lm:find("local function styleField(this)", 1, true)
    assert(sf, "no styleField")
    local sf_body = lm:sub(sf, lm:find("\n        end\n", sf, true))
    assert(sf_body:find("this._frame_textwidget.radius = PopupKit.RADIUS", 1, true), "no corner")
    assert(sf_body:find("this._frame_textwidget.background = Blitbuffer.COLOR_WHITE", 1, true), "no white fill")
end)

t.done()
