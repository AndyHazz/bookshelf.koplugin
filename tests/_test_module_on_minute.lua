-- tests/_test_module_on_minute.lua
-- on_minute(ctx): a module's own once-a-minute hook, for cards that poll (a
-- Home Assistant sensor) without being re-rendered every minute the way a
-- clock is. The shelf's minute heartbeat only runs while the grid is on
-- screen, so the hook inherits "only while visible". The module calls
-- ctx.refresh() itself when its data changed.
package.path = "./?.lua;" .. package.path
local t  = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq
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

-- Modules among a shelf's books: the heartbeat runs their on_minute too (the
-- Silverfish card lives on the home shelf). The page on screen records them
-- as it builds its rows; a hook runs only while that shelf is what is on
-- screen, and every ctx.refresh() of one tick is one redraw of the rows.
local shelf_body = hm:match("\nfunction HeroModules%._tickShelfMinuteHooks%(bw%)\n(.-)\nend\n")

local function runShelf(bw, defs, top)
    assert(shelf_body, "HeroModules._tickShelfMinuteHooks not found")
    local redraws = 0
    local host = { refresh = function() redraws = redraws + 1 end }
    local env = {
        ipairs = ipairs, pcall = pcall, type = type,
        Modules = { get = function(k) return defs[k] end },
        UIManager = { getTopmostVisibleWidget = function() return top or bw end },
        HeroModules = {
            _hostOf = function() return host end,
            _shelfView = function() return "spines" end,
        },
        require = function() return { entryConfig = function(entry) return { entry = entry } end } end,
    }
    local f = assert(load("local bw = ...\n" .. shelf_body, "shelfhooks", "t", env))
    return f(bw), function() return redraws end
end

local function shelfWith(entries, extra)
    local cells = { chip = "home" }
    for _i, e in ipairs(entries) do cells[#cells + 1] = e end
    local bw = { chip = "home", _shelf_minute_cells = cells, _isListMode = function() return false end }
    for k, v in pairs(extra or {}) do bw[k] = v end
    return bw
end

t.test("shelf: each hook runs with its entry and the shelf's surface", function()
    local seen = {}
    local defs = { pet = { on_minute = function(ctx) seen[#seen + 1] = ctx end } }
    local e1, e2 = { id = "sm_1", module = "pet" }, { id = "sm_2", module = "pet" }
    local did, redraws = runShelf(shelfWith({ e1, e2 }), defs)
    assert(did == true)
    assert(#seen == 2 and seen[1].entry == e1 and seen[2].entry == e2)
    assert(seen[1].surface == "shelf" and seen[1].shelf_view == "spines")
    assert(redraws() == 0, "no hook asked, yet the rows redrew")
end)

t.test("shelf: two refreshes in one tick are one redraw; a later one redraws itself", function()
    local ctxs = {}
    local defs = { pet = { on_minute = function(ctx) ctxs[#ctxs + 1] = ctx; ctx.refresh() end } }
    local _did, redraws = runShelf(shelfWith({ { id = "a", module = "pet" }, { id = "b", module = "pet" } }), defs)
    eq(redraws(), 1)
    ctxs[1].refresh()   -- async work done after the tick
    eq(redraws(), 2)
end)

t.test("shelf: nothing runs off screen, on another chip, in List view or mid-edit", function()
    local n = 0
    local defs = { pet = { on_minute = function() n = n + 1 end } }
    local e = { id = "a", module = "pet" }
    assert(runShelf(shelfWith({ e }), defs, {}) == false, "ran under another window")
    assert(runShelf(shelfWith({ e }, { chip = "recent" }), defs) == false, "ran for another chip's page")
    assert(runShelf(shelfWith({ e }, { _isListMode = function() return true end }), defs) == false)
    assert(runShelf(shelfWith({ e }, { _shelf_module_edit = {} }), defs) == false)
    assert(runShelf(shelfWith({ e }, { _closed = true }), defs) == false)
    eq(n, 0)
    assert(runShelf({ chip = "home" }, defs) == false)
end)

t.test("shelf: the rows record their hooks, and the heartbeat runs them", function()
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    for _i, name in ipairs({ "_buildShelfRows", "_buildSpineRows" }) do
        local head = w:match("\nfunction BookshelfWidget:" .. name .. "%(.-%)\n(.-)\nend\n")
        assert(head and head:find("self._shelf_minute_cells = { chip = self.chip }", 1, true),
            name .. " does not reset the shelf's hook list")
    end
    local cell = hm:match("\nfunction HeroModules%._makeCell%(.-\nend\n")
    assert(cell and cell:find("_shelf_minute_cells", 1, true), "_makeCell does not record shelf hooks")
    assert(w:find("_tickShelfMinuteHooks(self)", 1, true), "the heartbeat does not run the shelf's hooks")
end)

t.done()
