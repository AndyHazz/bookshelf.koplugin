-- tests/_test_folder_filter_picker.lua
-- Filters > Folders adds a folder from Bookshelf's own folder list (the one
-- Move to and Save downloads to use), as a page of the shelf editor, not
-- KOReader's file browser over it (maintainer, PW5). Picking folders to
-- filter by makes none, so it has no New folder.
--
-- Usage (from plugin root): lua tests/_test_folder_filter_picker.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

local shown
package.loaded["logger"] = { dbg = function() end, info = function() end, warn = function() end, err = function() end }
package.loaded["ui/uimanager"] = { show = function(_s, w) shown = w end, close = function() end }
package.loaded["device"] = { screen = { getWidth = function() return 600 end,
    getHeight = function() return 800 end } }
package.loaded["lib/bookshelf_home_dir"] = { get = function() return "/books" end }
package.loaded["lib/bookshelf_book_repository"] = { getAllFolderChoices = function()
    return { { value = "/books/Fiction/", label = "Fiction" } } end }
package.loaded["lib/bookshelf_library_modal"] = { new = function(_s, o) return o end }
local Picker = require("lib/bookshelf_folder_picker")

local function labels(cfg)
    local out = {}
    for _i, a in ipairs(cfg.header_actions or {}) do out[#out + 1] = a.label end
    return table.concat(out, ",")
end

t.test("the picker opens as a page when given one", function()
    local over = { rect = function() end }
    Picker.show{ over = over, on_pick = function() end }
    eq(shown.config.over, over)
end)

t.test("a picker for folders that exist has no New folder", function()
    Picker.show{ new_folder = false, on_pick = function() end }
    eq(labels(shown.config), "Browse device\xE2\x80\xA6")
end)

t.test("Move to keeps New folder", function()
    Picker.show{ on_pick = function() end }
    eq(labels(shown.config), "New folder\xE2\x80\xA6,Browse device\xE2\x80\xA6")
end)

t.test("a picked folder comes back without its trailing slash", function()
    local got
    Picker.show{ on_pick = function(d) got = d end }
    shown.config.on_cell_tap(shown.config.item_at(2))
    eq(got, "/books/Fiction")
end)

t.test("Filters > Folders adds from the folder list, as a page of the editor", function()
    local ed = io.open("lib/bookshelf_chip_editor.lua"):read("*a")
    local i = ed:find("function Editor:_pickFolderFilter", 1, true)
    local body = ed:sub(i, ed:find("\nend\n", i, true))
    assert(not body:find("ui/widget/pathchooser", 1, true), "still KOReader's file browser")
    assert(body:find('require("lib/bookshelf_folder_picker")', 1, true), "not the folder list")
    assert(body:find("over%s*= Editor%._over%("), "not a page of the editor")
    assert(body:find("new_folder%s*= false"), "offers New folder")
end)

t.done()
