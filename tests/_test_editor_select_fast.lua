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
local env = { require = require, HeroModules = HM, Modules = { CARD_BG = "bg" }, table = table, tostring = tostring,
    os = os, pcall = pcall, Blitbuffer = { new = function(w, h) return newBB(w, h) end } }
assert(load(body, "dim", "t", env))()

t.test("a module is dimmed once, then copied back", function()
    local bb = newBB(100, 100)
    HM._dimCell(bb, "a", "sig1", 0, 0, 10, 10)
    HM._dimCell(bb, "a", "sig1", 0, 0, 10, 10)
    assert(fades == 1, "blended twice: " .. fades)
    -- Written back once when dimmed (in a copy, off the framebuffer), and
    -- once from the kept copy.
    assert(bb.blits == 2, "not copied back: " .. bb.blits)
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

t.test("in the editor a module is built only when its kept picture won't do", function()
    -- The three-row Shelf module painted for 745 ms on every change (PW5).
    assert(hm:find("container[#container + 1] = HeroModules._EditCell:new{", 1, true), "editor cells not kept")
    local p = hm:match("\nfunction HeroModules%._EditCell:paintTo%(bb, x, y%)\n(.-)\nend\n")
    assert(p, "no paintTo")
    local hit = p:find("bb:blitFrom(rec.bb, x, y, 0, 0, self.w, self.h)", 1, true)
    local build = p:find("self[1] = self.build()", 1, true)
    assert(hit and build and hit < build, "built before the kept picture is tried")
    -- What it drew past its cell (the Shelf module's heading) is kept too.
    assert(p:find("SpineShelf.badgeRectsSince(seq0, x, y, self.w, self.h)", 1, true))
    assert(p:find("HeroModules._noteOverhang(e)", 1, true), "a kept heading is not reported to the editor")
    local key = hm:match("\nfunction HeroModules%._EditCell:_key%(bb, x, y%)\n(.-)\nend\n")
    assert(key:find("tostring(self.sig), x, y, self.w, self.h, os.date(\"%H%M\")", 1, true),
        "the picture is not redone when the module, its place or the minute changes")
    local drop = hm:match("\nfunction HeroModules%._dropDimCache%(%)\n(.-)\nend\n")
    assert(drop:find("HeroModules._paint_cache = {}", 1, true), "kept pictures outlive the editor")
end)

t.test("a module can name more of what its kept picture depends on", function()
    -- The Shelf module's shelf can change while the module's entry does not.
    local sig = hm:match("\nfunction HeroModules%._entrySig%(entry%)\n(.-)\nend\n")
    assert(sig and sig:find("def.cache_key, entry", 1, true), "spec cache_key ignored")
    local shelf = io.open("micromodules/shelf.lua"):read("*a")
    assert(shelf:find("cache_key = function(entry)", 1, true), "the Shelf module's picture outlives a shelf edit")
end)

t.done()
