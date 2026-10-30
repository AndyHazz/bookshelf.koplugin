-- tests/_test_module_plugin.lua
-- A module in a pack (a .koplugin's bookshelf_modules/) often shows its own
-- plugin's state: a pet, a game, a reading log. Kit.plugin(MODULE_DIR) hands
-- it that plugin's live instance, found by folder, so a module needs no global
-- of its own and no guess at the name KOReader filed the plugin under (the
-- folder's, whatever main.lua calls itself).
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["logger"] = { dbg = function() end, info = function() end,
    warn = function() end, err = function() end }
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
package.loaded["ffi/util"] = { template = function(s) return s end }

local instances = {}
package.loaded["pluginloader"] = {
    getPluginInstance = function(_self, name) return instances[name] end,
}

local M = dofile("lib/bookshelf_start_menu_modules.lua")
local t = dofile("tests/_helpers.lua").runner()

t.test("a pack module gets its own plugin's instance", function()
    local pet = { name = "silverfish", path = "plugins/silverfish.koplugin" }
    instances.silverfish = pet
    assert(M.pluginOf("plugins/silverfish.koplugin/bookshelf_modules") == pet)
end)

t.test("a doubled slash in the plugin folder still matches", function()
    -- KOReader's default extra path is the data dir's "plugins/", with the
    -- slash, so its plugins' paths carry "//"; ours are built without it.
    local pet = { name = "silverfish", path = "/mnt/us/koreader/plugins//silverfish.koplugin" }
    instances.silverfish = pet
    assert(M.pluginOf("/mnt/us/koreader/plugins/silverfish.koplugin/bookshelf_modules") == pet)
end)

t.test("another folder of the same name is not this pack's plugin", function()
    instances.silverfish = { name = "silverfish", path = "/elsewhere/silverfish.koplugin" }
    assert(M.pluginOf("plugins/silverfish.koplugin/bookshelf_modules") == nil)
end)

t.test("nothing for a plugin that is not running, or a folder outside any plugin", function()
    instances.silverfish = nil
    assert(M.pluginOf("plugins/silverfish.koplugin/bookshelf_modules") == nil)
    assert(M.pluginOf("/koreader/settings/bookshelf/micromodules") == nil)
    assert(M.pluginOf(nil) == nil)
end)

t.test("a KOReader without the loader's lookup gives nothing, not an error", function()
    package.loaded["pluginloader"] = {}
    assert(M.pluginOf("plugins/silverfish.koplugin/bookshelf_modules") == nil)
end)

t.done()
