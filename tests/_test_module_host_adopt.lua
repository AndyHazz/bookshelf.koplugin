-- tests/_test_module_host_adopt.lua
-- A module standing on a SHELF (not the top panel or the full-screen view)
-- must save its settings to that shelf, refresh through it and open the
-- shelf's own editor on long-press. Its host adopts the entry
-- (HeroModules.adopt); the context and the cell ask for it.
package.path = "./?.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()
local hm = io.open("lib/bookshelf_hero_modules.lua"):read("*a")
local ed = io.open("lib/bookshelf_module_grid_editor.lua"):read("*a")

local ctx_body = hm:match("\nfunction HeroModules%._ctx%(bw, refresh, entry%)\n(.-)\nend\n")

t.test("an adopted entry saves through its host, not the top panel's list", function()
    assert(ctx_body, "_ctx not found")
    local saved, reloaded, hero_saved = nil, 0, false
    local entry = { id = "m1" }
    local host = { save = function(e) saved = e end, refresh = function() reloaded = reloaded + 1 end,
                   surface = "shelf" }
    local env = {
        require = function(name)
            if name == "lib/bookshelf_module_kit" then
                return { entryConfig = function(e, save) return { set = function(_s, k, v) e[k] = v; save() end } end }
            end
            hero_saved = true
            return { load = function() return {} end, findById = function() end, save = function() end }
        end,
        HeroModules = { _rebuild = function() end, _hostOf = function(e) return e == entry and host or nil end },
    }
    local ctx = load("local bw, refresh, entry = ...\n" .. ctx_body, "ctx", "t", env)({}, nil, entry)
    ctx.config:set("rows", 2)
    assert(saved == entry and entry.rows == 2, "not saved through the host")
    assert(reloaded == 1, "not refreshed through the host")
    assert(not hero_saved, "written to the top panel's list as well")
    assert(ctx.surface == "shelf")
end)

t.test("an entry nobody adopted saves as before", function()
    assert(ctx_body:find("Model.save(items)", 1, true), "the old path is gone")
end)

t.test("the cell refreshes and long-presses through its host", function()
    local mk = hm:match("\nfunction HeroModules%._makeCell%(.-\nend\n")
    assert(mk and mk:find("_hostOf(entry)", 1, true), "the cell ignores its host")
end)

t.test("the layout editor takes a host's own settings opener", function()
    assert(ed:find("open_settings = host.open_settings or", 1, true))
end)

t.done()
