-- tests/_test_ornament_deck.lua
-- The ornament deck: a saved order, fixed patterns per level, a dealer.
-- Run from the plugin root: lua tests/_test_ornament_deck.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["logger"] = { dbg = function() end, info = function() end,
                             warn = function() end, err = function() end }
local H  = dofile("tests/_helpers.lua")
local t  = H.runner()
local eq = H.eq

local function fresh()
    package.loaded["lib/bookshelf_ornament_deck"] = nil
    local D = dofile("lib/bookshelf_ornament_deck.lua")
    local mem = {}
    D._store = { read = function(k) return mem[k] end,
                 save = function(k, v) mem[k] = v end }
    local s = 7
    D._rand = function(n) s = (s * 48271) % 2147483647; return (s % n) + 1 end
    D._tabs = function() return mem._tabs end
    return D, mem
end
local function pool(names)
    local out = {}
    for i, n in ipairs(names) do out[i] = { name = n, aspect = 1 } end
    return out
end
-- seed(mem, list[, shelf]) / deckOf(mem[, shelf]): a shelf's saved deck.
local function seed(mem, list, shelf)
    mem["ornament_decks"] = mem["ornament_decks"] or {}
    mem["ornament_decks"][shelf or "_"] = list
end
local function deckOf(mem, shelf) return (mem["ornament_decks"] or {})[shelf or "_"] end
local function namesOf(list) local o = {} for i, e in ipairs(list) do o[i] = e.name end return o end

t.test("first use shuffles once and saves the order", function()
    local D, mem = fresh()
    local got = namesOf(D.order(pool({ "a", "b", "c", "d" })))
    eq(#got, 4)
    eq(table.concat(deckOf(mem), ","), table.concat(got, ","), "the order was not saved")
    eq(table.concat(namesOf(D.order(pool({ "a", "b", "c", "d" }))), ","), table.concat(got, ","),
       "a second call reordered")
end)

t.test("the saved order survives a reload", function()
    local D, mem = fresh()
    seed(mem, { "c", "a", "b" })
    eq(table.concat(namesOf(D.order(pool({ "a", "b", "c" }))), ","), "c,a,b")
end)

t.test("new pieces go first by default, so they are seen; removed files are dropped", function()
    -- Maintainer: a reader who adds ornaments should see them; one who wants
    -- the shelf to stay put can have them go last instead.
    local D, mem = fresh()
    seed(mem, { "c", "gone", "a" })
    D.reconcile({ "a", "c", "new", "new2" })
    eq(table.concat(deckOf(mem), ","), "new,new2,c,a")
end)

t.test("set to last, new pieces go at the end and nothing else moves", function()
    local D, mem = fresh()
    seed(mem, { "c", "gone", "a" })
    mem[D.NEW_AT_KEY] = "end"
    D.reconcile({ "a", "c", "new" })
    eq(table.concat(deckOf(mem), ","), "c,a,new")
end)

t.test("a piece the order has not met joins it by the same rule", function()
    local D, mem = fresh()
    seed(mem, { "a", "b" })
    eq(table.concat(namesOf(D.order(pool({ "a", "b", "n" }))), ","), "n,a,b")
    seed(mem, { "a", "b" })
    mem[D.NEW_AT_KEY] = "end"
    eq(table.concat(namesOf(D.order(pool({ "a", "b", "n" }))), ","), "a,b,n")
end)

t.test("a deleted file that comes back is appended, not restored", function()
    local D, mem = fresh()
    mem[D.NEW_AT_KEY] = "end"
    seed(mem, { "a", "b", "c" })
    D.reconcile({ "b", "c" })
    D.reconcile({ "a", "b", "c" })
    eq(table.concat(deckOf(mem), ","), "b,c,a")
end)

t.test("a switched-off piece keeps its place in the saved order", function()
    local D, mem = fresh()
    seed(mem, { "a", "b", "c" })
    -- b is off: the pool handed in lacks it, but the saved order keeps it.
    eq(table.concat(namesOf(D.order(pool({ "a", "c" }))), ","), "a,c")
    D.reconcile({ "a", "b", "c" })
    eq(table.concat(deckOf(mem), ","), "a,b,c")
end)

t.test("shuffle makes and saves a new order and bumps the epoch", function()
    local D, mem = fresh()
    seed(mem, { "a", "b", "c", "d", "e", "f" })
    local e0, g0 = D.epoch(), D.generation()
    D.shuffle()
    assert(table.concat(deckOf(mem), ",") ~= "a,b,c,d,e,f", "shuffle kept the order")
    eq(#deckOf(mem), 6)
    assert(D.epoch() > e0 and D.generation() > g0)
end)

t.test("swap exchanges two places and bumps the generation, not the epoch", function()
    local D, mem = fresh()
    seed(mem, { "a", "b", "c" })
    local e0, g0 = D.epoch(), D.generation()
    eq(D.swap("a", "c"), true)
    eq(table.concat(deckOf(mem), ","), "c,b,a")
    eq(D.epoch(), e0); assert(D.generation() > g0)
    eq(D.swap("a", "a"), false, "same piece swaps nothing")
    eq(D.swap("a", "zzz"), false, "an unknown piece swaps nothing")
end)

-- ── a deck per shelf ────────────────────────────────────────────────────
-- One order for every shelf opened every spine tab on the same pieces in
-- the same places (Reddit, 2026-10-03).
local SPINE_TABS = {
    { id = "home", view_mode = "spines" },
    { id = "recent" },                                   -- covers
    { id = "latest", view_mode = "spines" },
    { id = "series", view_mode = "spines", enabled = false },
}

t.test("every shelf shuffles a deck of its own", function()
    local D, mem = fresh()
    local names = { "a", "b", "c", "d", "e", "f", "g", "h" }
    local h = table.concat(namesOf(D.order(pool(names), "home")), ",")
    local l = table.concat(namesOf(D.order(pool(names), "latest")), ",")
    eq(table.concat(deckOf(mem, "home"), ","), h, "home's deck was not saved as its own")
    eq(table.concat(deckOf(mem, "latest"), ","), l, "latest's deck was not saved as its own")
    assert(h ~= l, "two shelves dealt the same order")
    eq(table.concat(namesOf(D.order(pool(names), "home")), ","), h, "dealing another shelf moved home's")
end)

t.test("the one 5.3.0 order goes to the first shelf to deal, and only that one", function()
    local D, mem = fresh()
    mem[D.ORDER_KEY] = { "c", "a", "b" }
    eq(table.concat(namesOf(D.order(pool({ "a", "b", "c" }), "latest")), ","), "c,a,b",
       "the shelf on screen after the upgrade did not keep its pieces")
    eq(mem[D.ORDER_KEY], nil, "the old key was left behind")
    D.order(pool({ "a", "b", "c" }), "home")
    assert(deckOf(mem, "home") and deckOf(mem, "latest") ~= deckOf(mem, "home"),
        "a second shelf took the same table")
end)

t.test("swap and shuffle change only the shelf they are used on", function()
    local D, mem = fresh()
    seed(mem, { "a", "b", "c" }, "home")
    seed(mem, { "a", "b", "c" }, "latest")
    eq(D.swap("a", "c", "home"), true)
    eq(table.concat(deckOf(mem, "home"), ","), "c,b,a")
    eq(table.concat(deckOf(mem, "latest"), ","), "a,b,c", "a swap on home reached latest")
    eq(D.move("b", 1, { "a", "b", "c" }, "latest"), true)
    eq(table.concat(deckOf(mem, "latest"), ","), "a,c,b")
    eq(table.concat(deckOf(mem, "home"), ","), "c,b,a", "a move on latest reached home")
    seed(mem, { "a", "b", "c", "d", "e", "f" }, "latest")
    D.shuffle("home")
    eq(table.concat(deckOf(mem, "latest"), ","), "a,b,c,d,e,f", "shuffling home shuffled latest")
end)

t.test("a new piece goes first on the first spine shelf, anywhere on the others", function()
    local D, mem = fresh()
    mem._tabs = SPINE_TABS
    eq(D.firstShelf(), "home")
    local base = { "a", "b", "c", "d", "e", "f", "g", "h" }
    seed(mem, { "a", "b", "c", "d", "e", "f", "g", "h" }, "home")
    seed(mem, { "a", "b", "c", "d", "e", "f", "g", "h" }, "latest")
    local all = { "a", "b", "c", "d", "e", "f", "g", "h", "new" }
    D.reconcile(all, "home"); D.reconcile(all, "latest")
    eq(deckOf(mem, "home")[1], "new", "the first spine shelf does not show the new piece first")
    eq(#deckOf(mem, "latest"), 9)
    assert(deckOf(mem, "latest")[1] ~= "new", "another shelf opens on the new piece too")
    local rest = {}
    for _i, n in ipairs(deckOf(mem, "latest")) do if n ~= "new" then rest[#rest + 1] = n end end
    eq(table.concat(rest, ","), table.concat(base, ","), "joining moved the pieces already there")
    -- set to last: the end, on every shelf
    mem[D.NEW_AT_KEY] = "end"
    D.reconcile({ "a", "b", "c", "d", "e", "f", "g", "h", "new", "n2" }, "latest")
    eq(deckOf(mem, "latest")[10], "n2")
end)

t.test("decks of shelves that are gone are dropped; the Kobo shelf keeps its", function()
    local D, mem = fresh()
    mem._tabs = SPINE_TABS
    seed(mem, { "a" }, "home"); seed(mem, { "a" }, "deleted"); seed(mem, { "a" }, "kobo")
    seed(mem, { "a" }, "series")                  -- disabled, not deleted: kept
    D.sync(pool({ "a" }), "home")
    eq(deckOf(mem, "deleted"), nil, "a deleted shelf's deck stayed")
    assert(deckOf(mem, "kobo") and deckOf(mem, "series") and deckOf(mem, "home"), "a live deck was dropped")
end)

t.test("the shelf id reaches the deck from every place that deals or edits", function()
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    local base = w:match("\nfunction BookshelfWidget:_spinePlanBase%(content_w, shelf_h, all_items%)\n(.-)\nend\n")
    assert(base and base:find("orn_shelf       = self.chip,", 1, true), "_spinePlanBase does not name the shelf")
    assert(w:find('require("lib/bookshelf_ornament_deck").shuffle(self.chip)', 1, true),
        "the shuffle action does not shuffle the shelf on screen")
    local sp = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")
    assert(sp:find("Deck.sync(orn.mod.listAll(), opts.orn_shelf)", 1, true)
        and sp:find("orn.mod.listFor(TP.ornamentsFor(opts.orn_shelf))", 1, true), "plan deals from the shared deck")
    assert(sp:find('and k ~= "orn_shelf"', 1, true), "the shelf id splits the entry cache")
    local m = io.open("lib/bookshelf_ornament_menu.lua"):read("*a")
    assert(m:find("local shelf = bw and bw.chip", 1, true), "the long-press menu does not know its shelf")
    for _i, call in ipairs({ "Deck.sync(Orn.listAll(), shelf)", "Deck.order(Orn.listFor(TP.ornamentsFor(shelf)), shelf)",
                             "Deck.move(entry.name, delta, onNames(), shelf)",
                             "Deck.swap(entry.name, chosen.name, shelf)" }) do
        assert(m:find(call, 1, true), "the menu edits the wrong deck: " .. call)
    end
end)

local function slots(D, fn, level, n)
    local o = {}
    for i = 1, n do if D[fn](level, i) then o[#o + 1] = i end end
    return table.concat(o, ",")
end

t.test("patterns: bottom rows first, per level", function()
    local D = fresh()
    eq(slots(D, "shelfSlot", "rarely", 12), "4,8,12")
    eq(slots(D, "shelfSlot", "often", 6), "2,4,6")
    eq(slots(D, "shelfSlot", "always", 3), "1,2,3")
    eq(slots(D, "shelfSlot", "off", 6), "")
    eq(slots(D, "gapSlot", "rarely", 8), "")
    eq(slots(D, "gapSlot", "often", 8), "4,8")
    eq(slots(D, "gapSlot", "always", 4), "2,4")
end)

-- ── Seeded placement (2026-10-05) ───────────────────────────────────────
-- Most readers have two rows a page, and the fixed patterns put the pieces
-- in the same places on every page (Always: row 1's right end and row 2's
-- left on every page; Often: always the lower row). Seeded per shelf, the
-- side and the row in each window vary, the same way on every visit.
local function pageSig(D, level, seed, page, rows)
    local parts = {}
    for r = 1, rows do
        local s = (page - 1) * rows + r
        if D.shelfSlot(level, s, seed) then parts[#parts + 1] = r .. D.side(level, s, seed)
        else parts[#parts + 1] = r .. "-" end
    end
    return table.concat(parts, ",")
end

t.test("seeded: the same seed always gives the same pattern", function()
    local D = fresh()
    local a, b = {}, {}
    for s = 1, 40 do a[s] = tostring(D.shelfSlot("often", s, 1234)) .. D.side("often", s, 1234) end
    local D2 = fresh()
    for s = 1, 40 do b[s] = tostring(D2.shelfSlot("often", s, 1234)) .. D2.side("often", s, 1234) end
    eq(table.concat(a, " "), table.concat(b, " "))
end)

t.test("seeded: Often is one piece per two shelves, Rarely one per four", function()
    local D = fresh()
    for _i, c in ipairs({ { "often", 2 }, { "rarely", 4 } }) do
        for w = 0, 19 do
            local n = 0
            for i = 1, c[2] do if D.shelfSlot(c[1], w * c[2] + i, 777) then n = n + 1 end end
            eq(n, 1, c[1] .. " window " .. w .. " holds " .. n .. " pieces")
        end
    end
    for s = 1, 20 do assert(D.shelfSlot("always", s, 777), "Always skipped shelf " .. s) end
end)

t.test("seeded: Often does not always pick the lower row", function()
    local D = fresh()
    local upper = 0
    for w = 0, 19 do if D.shelfSlot("often", w * 2 + 1, 4242) then upper = upper + 1 end end
    assert(upper > 0 and upper < 20, "Often picked the same row in every window: " .. upper)
end)

t.test("seeded: never the same side three times running", function()
    local D = fresh()
    for _i, seed in ipairs({ 1, 99, 31337, 2026 }) do
        local run, last = 0, nil
        for s = 1, 60 do
            local side = D.side("always", s, seed)
            if side == last then run = run + 1 else run, last = 1, side end
            assert(run <= 2, "seed " .. seed .. " put three in a row at " .. s)
        end
    end
end)

t.test("seeded: a two-row shelf at Always does not repeat one arrangement on every page", function()
    local D = fresh()
    local sigs, distinct = {}, 0
    for page = 1, 10 do
        local sig = pageSig(D, "always", 5150, page, 2)
        if not sigs[sig] then sigs[sig] = true; distinct = distinct + 1 end
    end
    assert(distinct >= 2, "every page had the same arrangement")
end)

t.test("seeded: different shelves get different patterns", function()
    local D = fresh()
    local a, b = {}, {}
    for s = 1, 30 do a[s] = D.side("always", s, 11); b[s] = D.side("always", s, 12) end
    assert(table.concat(a) ~= table.concat(b), "two seeds gave the same sides")
end)

t.test("the plan hands the deck the shelf's seed, and the hooks use it", function()
    local sp = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")
    assert(sp:find("seed = orn.mod.hash(tostring(opts.orn_shelf or \"\")),", 1, true),
        "plan does not seed the deck per shelf")
    local dk = io.open("lib/bookshelf_ornament_deck.lua"):read("*a")
    assert(dk:find("M.shelfSlot(level, d.st.shelf, seed)", 1, true)
        and dk:find("M.side(level, d.st.shelf, seed)", 1, true), "the hooks ignore the seed")
end)

t.test("levels from the frequency number", function()
    local D = fresh()
    eq(D.levelOf(0), "off"); eq(D.levelOf(0.5), "rarely"); eq(D.levelOf(1), "often")
    eq(D.levelOf(2), "always"); eq(D.levelOf(4), "always"); eq(D.levelOf(nil), "off")
end)

t.test("sides alternate with each shelf-end piece", function()
    local D = fresh()
    eq(D.side("often", 2), "right"); eq(D.side("often", 4), "left"); eq(D.side("often", 6), "right")
    eq(D.side("always", 1), "right"); eq(D.side("always", 2), "left")
    eq(D.side("rarely", 4), "right"); eq(D.side("rarely", 8), "left")
end)

local function cards(spec)   -- "a,Hb,c": H = reaches the shelf above (height 100%+)
    local out = {}
    for tok in spec:gmatch("[^,]+") do
        local up = tok:sub(1, 1) == "H"
        out[#out + 1] = { name = up and tok:sub(2) or tok, reaches_above = up or nil }
    end
    return out
end

t.test("the dealer: card n to slot n, cycling, with the deal number", function()
    local D = fresh()
    local d = D.dealer(D.newState(), cards("a,b,c"))
    local got = {}
    for i = 1, 7 do local e, no = d:take(false); got[i] = e.name .. no end
    eq(table.concat(got, " "), "a1 b1 c1 a2 b2 c2 a3")
end)

t.test("peek does not deal; take does", function()
    local D = fresh()
    local d = D.dealer(D.newState(), cards("a,b"))
    eq(d:peek(false).name, "a"); eq(d:peek(false).name, "a")
    eq(d:take(false).name, "a"); eq(d:peek(false).name, "b")
end)

t.test("a top shelf takes a hanging card in its turn", function()
    -- A page's first row hangs its pieces from the bottom of the top panel
    -- (maintainer), so no card is passed over there any more.
    local D = fresh()
    local d = D.dealer(D.newState(), cards("Hbat,vase,cup"))
    eq(d:peek(true).name, "bat", "peek must agree with take")
    eq(d:take(true).name, "bat", "the top shelf passed the bat over")
    eq(d:take(false).name, "vase")
    eq(d:take(true).name, "cup")
end)

t.test("one standing card among hanging ones is not dealt to every top shelf", function()
    -- PW5: a loose test piece and a pack whose pieces all hang. Every page's
    -- top shelf skipped round the whole deck to the one standing piece, and
    -- the skipped cards piled up (about 25 more a page).
    local D = fresh()
    local spec = { "toulouse" }
    for i = 1, 26 do spec[#spec + 1] = "Hprint" .. i end
    local d = D.dealer(D.newState(), cards(table.concat(spec, ",")))
    local seen = 0
    for _page = 1, 6 do
        for _i, top in ipairs({ true, false }) do
            if d:take(top).name == "toulouse" then seen = seen + 1 end
        end
    end
    eq(seen, 1, "the standing piece came round more than once in 12 deals")
    eq(d.st.owed, nil, "the dealer still keeps a queue of passed-over cards")
end)

t.test("no cards: nothing is dealt and nothing loops", function()
    local D = fresh()
    local d = D.dealer(D.newState(), {})
    eq(d:take(true), nil); eq(d:take(false), nil); eq(d.st.n, 0)
end)

t.test("a copied state deals the same pieces", function()
    local D = fresh()
    local c = cards("Ha,b,c,d")
    local d1 = D.dealer(D.newState(), c)
    d1:take(true)
    local snap = D.copyState(d1.st)
    local x = { d1:take(false).name, d1:take(false).name }
    local d2 = D.dealer(D.copyState(snap), c)
    eq(table.concat({ d2:take(false).name, d2:take(false).name }, ","), table.concat(x, ","))
    assert(snap ~= d1.st, "copyState shares the state")
end)

-- A synthetic shelf: n books of width w, a group boundary before every
-- `every`-th book, driven through the REAL fillRows.
local SpineLayout = dofile("lib/bookshelf_spine_layout.lua")
local function shelf(n, w, every)
    local es = {}
    for i = 1, n do
        es[i] = { w = w, gap_base = (i > 1) and ((every and (i - 1) % every == 0) and 20 or 4) or 0,
                  orn_seed = (i > 1 and every and (i - 1) % every == 0) and ("b" .. i) or nil,
                  item_idx = i }
    end
    return es
end
local function sub(es, from)
    local o = {}
    for i = from, #es do
        local c = {}
        for k, v in pairs(es[i]) do c[k] = v end
        o[#o + 1] = c
    end
    o[1].orn_seed, o[1].gap_base = nil, 0      -- a render's first book has no boundary
    return o
end
local function env(D, st, level, es, paginating, per_page, n_rows, pool)
    return {
        dealer = D.dealer(st, pool), level = level, entries = es,
        paginating = paginating, per_page = per_page, n_rows = n_rows, content_w = 300,
        size = function(kind, e, no) return { entry = e, w = 40, kind = kind, no = no } end,
        space = function(kind, pl) return pl.w + 8 end,
        pageKey = function(i) return tostring(es[i].item_idx) end,
    }
end
local function run(D, e)
    local h = D.fillHooks(e)
    local ws = {}
    for i, x in ipairs(e.entries) do ws[i] = x.w end
    local rows = SpineLayout.fillRows(ws, h.avail, h.gaps, h.empty_ok, h)
    h.stop()
    return rows, h
end
local function pieces(rows, es, h, from_row, to_row)
    local out = {}
    for r = from_row, to_row do
        local row = rows[r]
        if h.row_orn[r] then out[#out + 1] = "R" .. h.row_orn[r].entry.name end
        if row then
            for i = row.first, row.last do
                local e = es[i]
                if e.lead_ornament then out[#out + 1] = "L" .. e.lead_ornament.entry.name end
                if e.ornament then out[#out + 1] = "G" .. e.ornament.entry.name end
            end
        end
    end
    return table.concat(out, " ")
end

t.test("agreement: every page the render plans matches the pagination pass", function()
    local D = fresh()
    local pool = cards("a,b,Hc,d,e")
    for _k, level in ipairs({ "rarely", "often", "always" }) do
        local all = shelf(60, 45, 3)
        local prow, ph = run(D, env(D, D.newState(), level, all, true, 2, math.huge, pool))
        local pages = SpineLayout.paginate(prow, 2)
        for p = 1, #pages - 1 do
            local first = pages[p].first
            local key = tostring(all[first].item_idx)
            local st = ph.page_orn[key]
            assert(st, level .. ": no state recorded for page " .. p)
            local es = sub(all, first)
            local rrow, rh = run(D, env(D, D.copyState(st), level, es, false, 2, 2, pool))
            eq(rrow[1].first, 1)
            eq(rrow[2] and rrow[2].last, pages[p].last - first + 1,
               level .. ": page " .. p .. " breaks differently")
            eq(pieces(rrow, es, rh, 1, 2),
               pieces(prow, all, ph, (p - 1) * 2 + 1, p * 2),
               level .. ": page " .. p .. " got different pieces")
            local nxt = ph.page_orn[tostring(all[pages[p + 1].first].item_idx)]
            local mine = rh.dealer and rh.dealer.st or rh.state()
            eq(mine.n, nxt.n, level .. ": page " .. p .. " end state n")
            eq(mine.shelf, nxt.shelf); eq(mine.bnd, nxt.bnd)
        end
    end
end)

t.test("the nth slot holds card n, and shelf ends follow the level", function()
    local D = fresh()
    local rows, h = run(D, env(D, D.newState(), "often", shelf(40, 45, nil), true, 2, math.huge, cards("a,b,c")))
    local got = {}
    for r = 1, 8 do got[#got + 1] = h.row_orn[r] and h.row_orn[r].entry.name or "-" end
    eq(table.concat(got, ""), "-a-b-c-a")
end)

t.test("a boundary piece at a row start stands as a lead piece", function()
    local D = fresh()
    -- 6 books of 45 + gaps fill a 300 row; boundary before book 7.
    local all = shelf(20, 45, 6)
    local rows, h = run(D, env(D, D.newState(), "always", all, true, 99, math.huge, cards("a,b,c,d")))
    local lead = false
    for _i, e in ipairs(all) do if e.lead_ornament then lead = true end end
    assert(lead, "no boundary landed at a row start in this shelf; adjust widths")
end)

t.test("a page starting with an empty row: the first book's boundary is absent in both passes", function()
    local D = fresh()
    -- A full-row piece: size returns w = 300, so a row-end slot row stands empty.
    local all = shelf(30, 45, 2)
    local e1 = env(D, D.newState(), "always", all, true, 2, math.huge, cards("a,b,c"))
    e1.size = function(kind, e, no) return { entry = e, w = (kind == "rowend") and 300 or 40, no = no } end
    local prow, ph = run(D, e1)
    local pages = SpineLayout.paginate(prow, 2)
    for p = 1, #pages - 1 do
        local first = pages[p].first
        local st = ph.page_orn[tostring(all[first].item_idx)]
        local es = sub(all, first)
        local e2 = env(D, D.copyState(st), "always", es, false, 2, 2, cards("a,b,c"))
        e2.size = e1.size
        local rrow, rh = run(D, e2)
        eq(pieces(rrow, es, rh, 1, 2), pieces(prow, all, ph, (p - 1) * 2 + 1, p * 2), "page " .. p)
    end
end)

t.test("bare planks continue the count on the last page", function()
    local D = fresh()
    local es = shelf(3, 45, nil)
    local rows, h = run(D, env(D, D.newState(), "always", es, false, 4, 4, cards("a,b,c,d,e")))
    eq(#rows, 1)
    local bare = h.bare(2, 4)
    eq(bare[2].entry.name, "b"); eq(bare[3].entry.name, "c"); eq(bare[4].entry.name, "d")
end)

t.test("the render deals nothing past its own rows", function()
    local D = fresh()
    local es = shelf(40, 45, 3)
    local rows, h = run(D, env(D, D.newState(), "always", es, false, 2, 2, cards("a,b,c")))
    local st = h.state()
    eq(st.shelf, 2, "the render counted shelves past its page")
end)

t.test("hanging pieces reach a page's top shelf in their turn", function()
    local D = fresh()
    local pool = cards("Ha,b,Hc,d")
    for _k, level in ipairs({ "often", "always" }) do
        local all = shelf(80, 45, 2)
        local prow, ph = run(D, env(D, D.newState(), level, all, true, 2, math.huge, pool))
        local hung_on_top = 0
        for r = 1, #prow do
            local top = ((r - 1) % 2) == 0
            local function check(pl)
                if pl and pl.entry.reaches_above and top then hung_on_top = hung_on_top + 1 end
            end
            check(ph.row_orn[r])
            for i = prow[r].first, prow[r].last do
                check(all[i].ornament); check(all[i].lead_ornament)
            end
        end
        if level == "always" then
            assert(hung_on_top > 0, level .. ": no hanging piece was dealt to a top shelf")
        end
    end
end)

t.test("a full-row piece on every shelf still leaves every page a book", function()
    -- Review: Always, one piece nudged to the whole row: every row stood
    -- empty, the page placed no book, and plan's next-page block indexed
    -- entry 0 (a crash on the home screen).
    local D = fresh()
    local function big(e)
        e.size = function(kind, en, no) return { entry = en, w = (kind == "rowend") and 300 or 40, no = no } end
        return e
    end
    local es = shelf(20, 45, nil)
    local rows = run(D, big(env(D, D.newState(), "always", es, false, 2, 2, cards("a"))))
    assert(#rows >= 1 and rows[#rows].last >= 1, "the render's page holds no book")
    local all = shelf(20, 45, nil)
    local prow = run(D, big(env(D, D.newState(), "always", all, true, 2, math.huge, cards("a"))))
    for p, pg in ipairs(SpineLayout.paginate(prow, 2)) do
        assert(pg.last >= pg.first, "page " .. p .. " holds no book")
    end
end)

t.test("a one-row page squeezes its end piece so the page's book fits", function()
    -- Device (1 row, a wide framed print as the row's end piece): the page
    -- may not stand empty, so its first book was forced in beside the piece
    -- at full size and a face-out ran past the end of the plank. The piece
    -- shrinks instead -- only as far as the book needs.
    local D = fresh()
    local function wide(e)
        e.size = function(kind, en, no, cap)
            local w = (kind == "rowend") and 250 or 40
            if cap then w = math.min(w, cap) end
            return { entry = en, w = w, kind = kind, no = no }
        end
        return e
    end
    for _i, paginating in ipairs({ false, true }) do
        local es = shelf(6, 120, nil)
        local rows, h = run(D, wide(env(D, D.newState(), "always", es, paginating, 1,
                                         paginating and math.huge or 1, cards("a"))))
        for r, row in ipairs(rows) do
            assert(row.last >= row.first, "row " .. r .. " holds no book")
            local used = 0
            for i = row.first, row.last do used = used + es[i].w end
            local pl = h.row_orn[r]
            if pl then used = used + pl.w + 8 end
            assert(used <= 300, (paginating and "pagination" or "render")
                .. ": row " .. r .. " overflows: " .. used)
        end
        local pl = h.row_orn[1]
        assert(pl and pl.w == 172, "the piece shrank only to the room left: " .. tostring(pl and pl.w))
    end
end)

t.test("a book that leaves no room for any piece: the piece is left off that row", function()
    local D = fresh()
    local e = env(D, D.newState(), "always", shelf(3, 295, nil), false, 1, 1, cards("a"))
    e.size = function(kind, en, no, cap)
        local w = (kind == "rowend") and 250 or 40
        if cap then if cap < 10 then return nil end; w = math.min(w, cap) end
        return { entry = en, w = w, kind = kind, no = no }
    end
    local rows, h = run(D, e)
    assert(rows[1].last >= rows[1].first, "the page holds no book")
    assert(h.row_orn[1] == nil, "a piece that cannot fit is still on the row")
end)

t.test("a piece squeezed below a quarter of its width is left off instead", function()
    -- sizeFor never refuses, so a tight squeeze would stand a speck.
    local D = fresh()
    local e = env(D, D.newState(), "always", shelf(3, 250, nil), false, 1, 1, cards("a"))
    e.size = function(kind, en, no, cap)
        local w = (kind == "rowend") and 200 or 40
        if cap then w = math.max(1, math.min(w, cap)) end
        return { entry = en, w = w, kind = kind, no = no }
    end
    local rows, h = run(D, e)                 -- room 50 - pads 8: a 42px piece
    assert(rows[1].last >= rows[1].first, "the page holds no book")
    assert(h.row_orn[1] == nil, "a 42px scrap of a 200px piece still stands")
end)

t.test("sync reconciles the order with every piece on disk, once per scan", function()
    -- Review: reconcile had no production caller, so deleted files were never
    -- dropped, a re-added one came back to its old place, and a piece that
    -- was off when the order was made never entered it (Swap to it did nothing).
    local D, mem = fresh()
    seed(mem, { "a", "gone", "b" })
    local all = pool({ "a", "b", "off1" })
    local saves = 0
    local save = D._store.save
    D._store.save = function(k, v) saves = saves + 1; save(k, v) end
    D.sync(all)
    eq(table.concat(deckOf(mem), ","), "off1,a,b", "new pieces join first by default")
    D.sync(all)
    eq(saves, 1, "the same scan reconciled twice")
    eq(D.swap("a", "off1"), true, "a piece that was off cannot be swapped to")
end)

t.test("place and move: a piece's place among the pieces that are on, and one step either way", function()
    local D, mem = fresh()
    seed(mem, { "a", "off1", "b", "c" })
    local on = { "a", "b", "c" }                      -- off1 is switched off
    local i, n = D.position("b", on)
    eq(i, 2); eq(n, 3)
    eq(D.position("off1", on), nil, "a switched-off piece has no place")
    eq(D.move("b", -1, on), true)
    eq(table.concat(deckOf(mem), ","), "b,off1,a,c", "Earlier did not swap with the piece before it that is on")
    eq(D.move("a", 1, { "b", "a", "c" }), true)
    eq(table.concat(deckOf(mem), ","), "b,off1,c,a")
    -- The deck deals round in a loop, so the first and last are neighbours:
    -- a step past either end wraps (maintainer).
    eq(D.move("b", -1, { "b", "c", "a" }), true, "the first piece cannot move earlier")
    eq(table.concat(deckOf(mem), ","), "a,off1,c,b", "earlier from the first did not trade with the last")
    eq(D.move("b", 1, { "a", "c", "b" }), true, "the last piece cannot move later")
    eq(table.concat(deckOf(mem), ","), "b,off1,c,a", "later from the last did not trade with the first")
    eq(D.move("x", 1, { "x" }), false, "a piece alone has nowhere to go")
end)

t.test("the menu has the new-ornaments choice beside the collection", function()
    local st = io.open("lib/bookshelf_settings.lua"):read("*a")
    local bg = st:match("function Settings:_themeSubItems%(%)(.-)\nend\n")
    assert(bg and bg:find("self:_ornamentsRow()", 1, true) and bg:find("self:_newOrnamentsRow()", 1, true),
        "the choice is not in the Theme menu")
    local row = st:match("function Settings:_newOrnamentsRow%(%)(.-)\nend\n")
    assert(row and row:find("BookshelfSettings.save(Deck.NEW_AT_KEY, value)", 1, true), "the row does not save the choice")
    assert(row:find('"start"),', 1, true) and row:find('"end"),', 1, true), "the row does not offer both choices")
end)

t.done()
