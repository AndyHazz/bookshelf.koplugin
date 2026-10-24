-- tests/_test_editor_select_fast.lua
-- Selecting a module in the layout editor was 650-780 ms on a PW5 after the
-- fade was kept: every module rebuilt (150-200 ms) and every unselected one
-- dimmed by a blend (330-390 ms). A select now repaints the grid as built,
-- and each module's dimmed look is kept while the editor is up.
--
-- Usage (from plugin root): lua tests/_test_editor_select_fast.lua
package.path = "./?.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()

local hm = assert(io.open("lib/bookshelf_hero_modules.lua")):read("*a")
local body = assert(hm:match("\n(function HeroModules%._dimCell%(bb, id, sig, x, y, w, h%).-\nend)\n"))
local fades = 0
local HM = { _dim_cache = {}, _fade = function() fades = fades + 1 end }
local function newBB(w, h)
    local b = { w = w, h = h, blits = 0 }
    function b:getType() return 1 end
    function b:blitFrom() self.blits = self.blits + 1 end
    function b:free() end
    return b
end
local env = { HeroModules = HM, Modules = { CARD_BG = "bg" }, table = table, tostring = tostring,
    os = os, pcall = pcall, Blitbuffer = { new = function(w, h) return newBB(w, h) end } }
assert(load(body, "dim", "t", env))()

t.test("a module is dimmed once, then copied back", function()
    local bb = newBB(100, 100)
    HM._dimCell(bb, "a", "sig1", 0, 0, 10, 10)
    HM._dimCell(bb, "a", "sig1", 0, 0, 10, 10)
    assert(fades == 1, "blended twice: " .. fades)
    assert(bb.blits == 1, "not copied back")
end)

t.test("a changed module, or a moved one, is dimmed afresh", function()
    local bb = newBB(100, 100)
    HM._dimCell(bb, "a", "sig2", 0, 0, 10, 10)
    assert(fades == 2, "kept across a settings change")
    HM._dimCell(bb, "a", "sig2", 20, 0, 10, 10)
    assert(fades == 3, "kept across a move")
end)

t.test("a select repaints the view as built, when only the selection moved", function()
    local ses = assert(io.open("lib/bookshelf_module_grid_session.lua")):read("*a")
    local sel = ses:match("\nfunction Session:select%(id%)\n(.-)\nend\n")
    assert(sel:find("self.host.reselect and self.host:reselect(self:edit())", 1, true))
    local mf = assert(io.open("lib/bookshelf_micro_fullscreen.lua")):read("*a")
    local rs = mf:match("\nfunction MicroFullscreen:reselect%(edit%)\n(.-)\nend\n")
    assert(rs and rs:find("edit.items == cur.items", 1, true) and rs:find("edit.boxes == cur.boxes", 1, true),
        "a changed layout would be shown as the old one")
    assert(rs:find("cur.selected_id = edit.selected_id", 1, true))
    local ed = assert(io.open("lib/bookshelf_module_grid_editor.lua")):read("*a")
    assert(ed:find('_dropDimCache() end)\n    local ed = Editor:new', 1, true), "a stale dim survives into a new editor")
end)

t.done()
