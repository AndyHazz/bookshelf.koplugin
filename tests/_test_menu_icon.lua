-- tests/_test_menu_icon.lua
-- Bookshelf's top-menu tab has its own icon (issue 548): KOReader's file
-- browser gained a "Reader" tab with book.opened, the icon Bookshelf used.
-- KOReader finds a tab icon by name as <icon dir>/<name>.svg, so the name
-- climbs from any icon dir to the root and back down to the plugin's own
-- file, wherever the plugin is installed.
--
-- Usage (from plugin root): lua tests/_test_menu_icon.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local t  = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq

local function sh(cmd) local p = io.popen(cmd); local o = p:read("*a"); p:close(); return (o:gsub("%s+$", "")) end
local root = sh("mktemp -d")
local ko = root .. "/koreader"
local plugin_rel = "plugins/bookshelf.koplugin"
sh("mkdir -p " .. ko .. "/resources/icons/mdlight " .. ko .. "/" .. plugin_rel .. "/assets/icons")
sh("cp assets/icons/bookshelf.svg " .. ko .. "/" .. plugin_rel .. "/assets/icons/")

local lfs = { currentdir = function() return ko end,
              attributes = function(p, a)
                  local f = io.open(p, "rb"); if not f then return nil end; f:close()
                  return (a == "mode") and "file" or { mode = "file" }
              end }
local Icon = dofile("lib/bookshelf_menu_icon.lua")
Icon._lfs = lfs
Icon._data_dir = root .. "/no-data"

local function opens(dir, name)
    local f = io.open(ko .. "/" .. dir .. "/" .. name .. ".svg", "rb")
    if f then f:close(); return true end
    return false
end

t.test("from a relative plugin path, every icon dir finds the file", function()
    local name = Icon.name(plugin_rel)
    assert(name ~= "book.opened", "fell back")
    for _i, dir in ipairs({ "resources/icons/mdlight", "resources/icons", "resources" }) do
        assert(opens(dir, name), "not found from " .. dir .. ": " .. name)
    end
end)

t.test("from an absolute plugin path too (extra plugin folders)", function()
    local name = Icon.name(ko .. "/" .. plugin_rel)
    assert(opens("resources", name), name)
end)

t.test("with the file missing, KOReader's own icon", function()
    eq(Icon.name(ko .. "/nowhere"), "book.opened")
end)

t.test("a bookshelf icon in the reader's own icons folder wins", function()
    local data = root .. "/data"
    sh("mkdir -p " .. data .. "/icons && touch " .. data .. "/icons/bookshelf.png")
    Icon._data_dir = data
    eq(Icon.name(plugin_rel), "bookshelf", "the reader's own icon was passed over")
    sh("rm " .. data .. "/icons/bookshelf.png")
    assert(Icon.name(plugin_rel) ~= "bookshelf", "with none, the plugin's own")
    Icon._data_dir = nil
end)

t.test("the tab and the release zip use it", function()
    local main = io.open("main.lua"):read("*a")
    assert(main:find('menu_items.bookshelf_tab = { icon = require("lib/bookshelf_menu_icon").name(self.path), text = _("Bookshelf") }', 1, true),
        "the tab still uses book.opened")
    local ga = io.open(".gitattributes"):read("*a")
    assert(ga:find("assets/icons               -export-ignore", 1, true)
        and ga:find("assets/icons/**            -export-ignore", 1, true), "the icon is left out of the zip")
end)

sh("rm -rf " .. root)
t.done()
