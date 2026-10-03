-- tests/_test_ornament_plan_wiring.lua
-- plan() deals every ornament through the deck's fill hooks (the logic and
-- its two-pass agreement are pinned in _test_ornament_deck.lua); this pins
-- the wiring, which cannot run outside KOReader.
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq
local shelf = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")
local plan = shelf:match("\nfunction SpineShelf%.plan%(items, opts%)\n(.-)\nfunction SpineShelf%.")

t.test("plan builds the hooks from the deck and hands them to the fill", function()
    assert(plan, "plan not found")
    assert(plan:find("Deck.fillHooks(", 1, true), "plan does not build the deck's hooks")
    assert(plan:find("SpineLayout.fillRows(widths, hk.avail, hk.gaps, hk.empty_ok, hk)", 1, true),
        "the fill is not driven by the hooks")
    assert(plan:find("Deck.order(", 1, true), "cards are not dealt in the saved order")
    assert(plan:find("opts.orn_state", 1, true), "plan ignores its start state")
    assert(plan:find("hk.stop()", 1, true), "the balancer can still deal")
end)

t.test("the balancer gets the committed widths and the lead constraints", function()
    assert(plan:find("fin_gaps, fin_lead, fin_nb, fin_fixed = hk.final()", 1, true))
    assert(plan:find("lead = fin_lead, no_break = fin_nb, fixed = fin_fixed", 1, true))
end)

t.test("plan returns the end state, the page states and the bare planks", function()
    assert(plan:find("orn_end = ", 1, true))
    assert(plan:find("page_orn = ", 1, true))
    assert(plan:find("bare = ", 1, true))
    assert(not plan:find("row_ends =", 1, true), "the old row_ends flag is still returned")
end)

t.test("no odds, promises or budgets are left in plan", function()
    for _i, name in ipairs({ "Orn.pick", "orn.mod.pick", "pageGuaranteed", "ROW_END_CHANCE",
            "GROUP_CHANCE", "reservesRowEnds", "beginScreen", "rowPiece", "mayDeal" }) do
        assert(not plan:find(name, 1, true), name .. " is still in plan")
    end
end)

local rw = shelf:match("\nfunction SpineShelf%.rowWidget%(opts%)\n(.-)\nfunction SpineShelf%.")
t.test("rowWidget picks nothing: it paints what the plan dealt", function()
    assert(rw, "rowWidget not found")
    assert(not rw:find("Orn.pick(", 1, true), "rowWidget still picks")
    assert(not rw:find("reservesRowEnds", 1, true), "the second-chance row end is still there")
    assert(rw:find("opts.bare_piece", 1, true), "an empty plank does not take the plan's piece")
    assert(rw:find("lead_ornament", 1, true), "a lead piece is not painted")
end)
t.test("height is the placement's, so a piece told to stand stands", function()
    assert(not rw:find("entry.lift", 1, true), "rowWidget reads the entry's height instead of the placement's")
    local oy = shelf:match("\nfunction SpineShelf%.ornamentY%(pl, stand_h, opts%)\n(.-)\nend\n")
    assert(oy and oy:find("pl.offset or 0", 1, true) and oy:find('pl.anchor == "top"', 1, true),
        "ornamentY does not read the placement's anchor and height")
    assert(not oy:find("entry", 1, true), "ornamentY reads the entry instead of the placement")
end)
t.test("the render hands each empty row its bare piece", function()
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    local b = w:match("\nfunction BookshelfWidget:_buildSpineRows%(.-%)\n(.-)\nend\n")
    assert(b and b:find("bare_piece        = plan.bare and plan.bare[r]", 1, true))
end)

t.test("plan and Swap reconcile the order with the pieces on disk", function()
    assert(plan:find("Deck.sync(orn.mod.listAll(), opts.orn_shelf)", 1, true), "plan deals from an unreconciled order")
    local menu = io.open("lib/bookshelf_ornament_menu.lua"):read("*a")
    assert(menu:find("Deck.sync(Orn.listAll(), shelf)", 1, true), "Swap does not reconcile before swapping")
end)

t.test("page-relative options stay out of the entries cache key, the deal state included", function()
    -- PW5 bench: every tap and page turn rebuilt every entry (page counts
    -- from filenames and all) because opts.orn_state, a fresh table per
    -- render, went into the key. The cadence suite's version of this test
    -- was deleted with the odds model.
    local body = shelf:match("\n(local function _optsKey%(opts%)\n.-\nend)\n")
    assert(body, "_optsKey not found")
    local env = setmetatable({ _nightMode = function() return false end,
                               SpineShelf = { has_wallpaper = false } }, { __index = _G })
    local f
    if _G.setfenv then f = assert(loadstring(body .. "\nreturn _optsKey")); setfenv(f, env)
    else f = assert(load(body .. "\nreturn _optsKey", "optsKey", "t", env)) end
    local key = f()
    local base = { row_h = 280, content_w = 1100, gap = 4 }
    local function with(extra)
        local o = {}
        for k, v in pairs(base) do o[k] = v end
        for k, v in pairs(extra) do o[k] = v end
        return key(o)
    end
    eq(with({ orn_state = { n = 0, shelf = 0, bnd = 0, owed = {} } }),
       with({ orn_state = { n = 9, shelf = 4, bnd = 2, owed = { 3 } } }), "the deal state is in the key")
    eq(with({ skip = 0, n_rows = 2, page_index = 1 }), with({ skip = 5, n_rows = math.huge, page_index = 3 }))
end)

t.done()
