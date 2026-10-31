-- tests/_test_picker_as_page.lua
-- A picker the shelf editor opens is a page of it (LibraryModal config.over):
-- in the editor's frame with its breadcrumb and a back chevron, refreshing
-- only that box, rather than a window over the editor that lined up with it
-- and read as one badly drawn menu.
--
-- Usage (from plugin root): lua tests/_test_picker_as_page.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local lm = io.open("lib/bookshelf_library_modal.lua"):read("*a")
local ed = io.open("lib/bookshelf_chip_editor.lua"):read("*a")

t.test("the lone Back or Close is the page's back chevron", function()
    local body = assert(lm:match("\nfunction LibraryModal:_closeOnlyAction%(%)\n(.-)\nend\n"))
    local f = assert(load("local self, _ = ...\n" .. body))
    local function only(label, over)
        return f({ config = { over = over, footer_actions = { { label = label, on_tap = function() end } } } },
                 function(s) return s end)
    end
    assert(only("Back", {}), "Back is not the chevron on a page")
    assert(not only("Back", nil), "Back became the X on a plain picker")
    assert(only("Close", nil) and only("Close", {}))
end)

t.test("a page refreshes its own box opening and closing, not the whole screen", function()
    local show = assert(lm:match("\nfunction LibraryModal:onShow%(%)\n(.-)\nend\n"))
    assert(show:find('UIManager:setDirty(self, "ui", Geom:new(self._shown_rect))', 1, true))
    local close = assert(lm:match("\nfunction LibraryModal:onCloseWidget%(%)\n(.-)\nend\n"))
    assert(close:find('UIManager:setDirty("all", "ui", Geom:new(self._shown_rect))', 1, true))
    assert(not lm:find("scrimUnder", 1, true), "the fade is back")
end)

t.test("the editor's pickers, the Theme library, Modules, Folders and a catalog's download folder open as its pages", function()
    eq(select(2, ed:gsub("over%s*= Editor%._over%(", "")), 6)
end)

-- Modules was a window of its own over the editor ("Bookshelf
-- micro-modules"), with no way back to it (user test).
t.test("Modules is a page of the editor, and its pick is not asked twice", function()
    assert(ed:find('over = Editor._over({ _("Modules") })', 1, true), "Modules is not a page")
    assert(ed:find('_editShelfModules(nil, { add = true, key = key })', 1, true),
        "the pick is not handed on, so the picker would open again")
    local mp = io.open("lib/bookshelf_module_picker.lua"):read("*a")
    assert(mp:find("over = opts.over,", 1, true), "the picker ignores over")
    assert(mp:find("if opts.key then\n        if on_select then on_select(opts.key) end\n        return", 1, true),
        "a module already picked still opens the picker")
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    assert(w:find("ed.session:add(nil, nil, pick)", 1, true), "covers: the pick does not reach the layout editor")
    assert(w:find("return self:_addSpineModule(pick)", 1, true), "spines: the pick does not reach the add")
end)

-- A page of the editor keeps the editor's height (less to paint), and the
-- picker on it fills that height with rows of cards at their own size, the
-- page row at the bottom (maintainer: Collections from the bulk menu left an
-- empty band under the page row).
t.test("a page fills its height with rows, the page row at the bottom", function()
    local cpp = assert(lm:match("\nfunction LibraryModal:_cellsPerPage%(content_width%)\n(.-)\nend\n"))
    assert(cpp:find("self._fill_rows * self:_gridCols()", 1, true), "the rows that fit are not used")
    for _i, fn in ipairs({ "_renderGridArea", "_gridNav", "_revealFocus" }) do
        local body = assert(lm:match("\nfunction LibraryModal:" .. fn .. "%(.-%)\n(.-)\nend\n"), fn)
        assert(not body:find("self.config.cells_per_page(", 1, true), fn .. " pages by the picker's own count")
    end
    assert(lm:find("elseif self._over_rect and self.config.cell_renderer then", 1, true), "a page is not filled")
    assert(lm:find("if i == page_at then parts[#parts + 1] = VerticalSpan:new{ width = short } end", 1, true),
        "the spare height is under the page row")
end)

-- PW5 2026-10-31: the genre picker opened from the short Genre page took
-- that page's height, two rows of cards: 73 pages of genres.
t.test("a page on a short editor still has the picker's own rows", function()
    assert(lm:find("math.max(fit(room()), math.min(rows_per_page, fit(room(screen_h))))", 1, true),
        "a short editor page gives its picker a couple of rows")
    assert(lm:find("local screen_h = Screen:getHeight() - self._over_rect.y - MARGIN", 1, true),
        "the picker can run off the bottom of the screen")
end)

-- PW5 2026-10-31: the module picker sizes its own area (config.area_height)
-- and was given the editor's front page as its room: with the module packs'
-- second row of tabs, one row of squashed cards under the page row. A page
-- gives such a picker at least its own height, as far as the screen goes.
t.test("a picker that sizes its own area gets its own height as a page", function()
    local body = assert(lm:match("if self.config.area_height then\n(.-)\n    elseif"), "no area_height branch")
    assert(body:find("self.config.area_height(cw, nil)", 1, true), "the picker's own height is not asked")
    assert(body:find("room(Screen:getHeight() - self._over_rect.y - MARGIN)", 1, true),
        "the room is not the screen below the editor's top")
end)

t.done()
