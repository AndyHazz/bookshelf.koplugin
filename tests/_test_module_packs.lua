-- tests/_test_module_packs.lua
-- Third-party module packs ship as small KOReader plugins: a .koplugin with a
-- bookshelf_modules/ folder. App Store and Storefront install and update
-- plugins already, so a pack published that way installs and updates from the
-- device. Bookshelf looks in every plugin folder KOReader loads from (the
-- default one and extra_plugin_paths) and skips packs switched off in
-- KOReader's plugin manager.
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["logger"] = { dbg = function() end, info = function() end,
    warn = function() end, err = function() end }
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
package.loaded["ffi/util"] = { template = function(s) return s end }

-- A fake filesystem: path -> "directory" | "file"; dir listings from it.
local FS = {
    ["plugins"] = "directory",
    ["plugins/bookshelf.koplugin"] = "directory",
    ["plugins/bookshelf.koplugin/micromodules"] = "directory",
    ["plugins/readinglog.koplugin"] = "directory",
    ["plugins/readinglog.koplugin/bookshelf_modules"] = "directory",
    ["plugins/readinglog.koplugin/bookshelf_modules/rings.lua"] = "file",
    ["plugins/other.koplugin"] = "directory",
    ["/extra"] = "directory",
    ["/extra/quotes.koplugin"] = "directory",
    ["/extra/quotes.koplugin/bookshelf_modules"] = "directory",
    ["/extra/off.koplugin"] = "directory",
    ["/extra/off.koplugin/bookshelf_modules"] = "directory",
    ["/extra/notaplugin"] = "directory",
}
local lfs = {
    attributes = function(p, what) if what == "mode" then return FS[p] end end,
    dir = function(d)
        local names = {}
        for p in pairs(FS) do
            local name = p:match("^" .. d:gsub("%p", "%%%0") .. "/([^/]+)$")
            if name then names[#names + 1] = name end
        end
        table.sort(names)
        local i = 0
        return function() i = i + 1; return names[i] end
    end,
}
package.loaded["libs/libkoreader-lfs"] = lfs

local M = dofile("lib/bookshelf_start_menu_modules.lua")
local t = dofile("tests/_helpers.lua").runner()

t.test("finds every installed plugin's bookshelf_modules folder", function()
    local dirs = M._test.packDirs({ "plugins", "/extra" }, { off = true })
    local got = {}
    for _i, d in ipairs(dirs) do got[#got + 1] = d.dir .. " <" .. d.origin .. ">" end
    table.sort(got)
    assert(table.concat(got, " | ") ==
        "/extra/quotes.koplugin/bookshelf_modules <plugin:quotes> | "
        .. "plugins/readinglog.koplugin/bookshelf_modules <plugin:readinglog>",
        table.concat(got, " | "))
end)

t.test("a missing plugin folder is no error", function()
    assert(#M._test.packDirs({ "/nowhere" }, {}) == 0)
end)

t.done()
