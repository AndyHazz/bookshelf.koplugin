-- tests/_test_module_groups.lua
-- The module library's chips: each module's group. Bundled modules have a
-- category set here; a plugin pack's modules are that pack; loose modules in
-- the reader's folder group by a "Name ·" title prefix (a bundle like
-- Reading Log's), else they are the reader's own. A spec's own `pack` or
-- `category` says so explicitly.
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["logger"] = { dbg = function() end, info = function() end,
                             warn = function() end, err = function() end }
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
package.loaded["ffi/util"] = { template = function(s) return s end }
local M = dofile("lib/bookshelf_start_menu_modules.lua")
local t = dofile("tests/_helpers.lua").runner()

local function g(key, spec, file) local id, label = M.groupFor(key, spec, file); return id, label end

t.test("bundled modules have their categories", function()
    assert(g("shelf", {}, { origin = "bundled" }) == "shelf")
    assert(g("last_books", {}, { origin = "bundled" }) == "shelf")
    assert(g("stats", {}, { origin = "bundled" }) == "reading")
    assert(g("analogue_clock", {}, { origin = "bundled" }) == "time")
    assert(g("otd", {}, { origin = "bundled" }) == "fun")
    assert(g("action", {}, { origin = "bundled" }) == "actions")
end)

t.test("a plugin pack's modules are that pack", function()
    local id, label = g("ha", { title = "Home Assistant" },
        { origin = "plugin:bookshelf-homeassistant-poc", label = "Home Assistant POC" })
    assert(id == "pack:bookshelf-homeassistant-poc" and label == "Home Assistant POC", tostring(id) .. " " .. tostring(label))
    local _id, plain = g("x", {}, { origin = "plugin:some-pack" })
    assert(plain == "some-pack", "no label: the folder name")
end)

t.test("loose modules group by a title prefix, else they are the reader's own", function()
    local id, label = g("alm_activity", { title = "Reading Log \xC2\xB7 Activity rings" }, { origin = "user" })
    assert(id == "pack:Reading Log" and label == "Reading Log", tostring(id))
    assert(g("finances", { title = "Finances" }, { origin = "user" }) == "mine")
end)

t.test("a spec's own pack or category wins", function()
    local id, label = g("y", { title = "Y", pack = "My Bundle" }, { origin = "user" })
    assert(id == "pack:My Bundle" and label == "My Bundle")
    assert(g("z", { title = "Z", category = "time" }, { origin = "user" }) == "time")
    assert(g("z", { title = "Z", category = "nonsense" }, { origin = "user" }) == "mine", "an unknown category")
end)

t.test("the chips: All, the categories in use, then packs, then the reader's own", function()
    local chips = M.groupChips({ "shelf", "reading", "pack:Reading Log", "mine", "time", "pack:Alpha" },
        { ["pack:Reading Log"] = "Reading Log", ["pack:Alpha"] = "Alpha" })
    local ids = {}
    for i, c in ipairs(chips) do ids[i] = c.id end
    assert(table.concat(ids, ",") == "all,shelf,reading,time,pack:Alpha,pack:Reading Log,mine", table.concat(ids, ","))
end)

t.done()
