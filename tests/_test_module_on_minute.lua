-- tests/_test_module_on_minute.lua
-- on_minute(ctx): a module's own once-a-minute hook, for cards that poll (a
-- Home Assistant sensor) without being re-rendered every minute the way a
-- clock is. The shelf's minute heartbeat only runs while the grid is on
-- screen, so the hook inherits "only while visible". The module calls
-- ctx.refresh() itself when its data changed.
package.path = "./?.lua;" .. package.path
local t  = dofile("tests/_helpers.lua").runner()
local hm = io.open("lib/bookshelf_hero_modules.lua"):read("*a")

local body = hm:match("\nfunction HeroModules%._tickMinuteHooks%(bw%)\n(.-)\nend\n")

local function run(bw, defs)
    assert(body, "HeroModules._tickMinuteHooks not found")
    local reloaded, swapped = {}, 0
    local env = {
        ipairs = ipairs, pcall = pcall, type = type,
        Modules = { get = function(k) return defs[k] end },
        HeroModules = {
            _reloadCellById = function(_bw, id) reloaded[#reloaded + 1] = id end,
            _swapCell = function() swapped = swapped + 1 end,
        },
        Kit = { entryConfig = function(entry) return { entry = entry } end },
        _build_surface = "hero",
        require = function() return { entryConfig = function(entry) return { entry = entry } end } end,
    }
    local f = assert(load("local bw = ...\n" .. body, "hooks", "t", env))
    return f(bw), reloaded, swapped
end

t.test("each on_minute cell's hook runs with its own entry, no re-render", function()
    local seen = {}
    local defs = { ha = { on_minute = function(ctx)
        seen[#seen + 1] = ctx
    end } }
    local e1, e2 = { id = "a", module = "ha" }, { id = "b", module = "ha" }
    local bw = { _hero_minute_cells = { { entry = e1 }, { entry = e2 } } }
    local did, reloaded, swapped = run(bw, defs)
    assert(did == true, "should report it ran hooks")
    assert(#seen == 2 and seen[1].entry == e1 and seen[2].entry == e2, "hooks not called per cell")
    assert(seen[1].config and seen[1].config.entry == e1, "no config handle")
    assert(seen[1].bw == bw, "no bw")
    assert(swapped == 0 and #reloaded == 0, "a hook must not re-render by itself")
    seen[2].refresh()
    assert(reloaded[1] == "b", "ctx.refresh must reload that card")
end)

t.test("a hook that errors doesn't stop the others", function()
    local n = 0
    local defs = { bad = { on_minute = function() error("boom") end },
                   ok = { on_minute = function() n = n + 1 end } }
    local bw = { _hero_minute_cells = { { entry = { id = "x", module = "bad" } },
                                        { entry = { id = "y", module = "ok" } } } }
    run(bw, defs)
    assert(n == 1, "the second hook did not run")
end)

t.test("no hook cells: nothing to do", function()
    assert(run({}, {}) == false)
end)

t.test("the grid records on_minute cells and the heartbeat runs them", function()
    assert(hm:find("bw._hero_minute_cells = {}", 1, true), "build does not reset the list")
    assert(hm:find("def.on_minute then", 1, true), "build does not record on_minute cells")
    local tick = hm:match("function HeroModules%.tickClocks%(bw%).-\nend")
    assert(tick and tick:find("_tickMinuteHooks(bw)", 1, true), "tickClocks does not run the hooks")
end)

t.done()
