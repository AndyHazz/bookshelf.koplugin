-- tests/_test_ornament_pin.lua
-- "Pin here" on a shelf ornament: the piece becomes an Ornament module at the
-- place it stood (after the books before it), leaves that shelf's deal, and
-- the shelf shows the page it lands on. On a grouped shelf it is offered only
-- where the piece stands between groups: a module stands only between items.
package.path = "./?.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()
local ss = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")
local w = io.open("lib/bookshelf_widget.lua"):read("*a")
local menu = io.open("lib/bookshelf_ornament_menu.lua"):read("*a")

local function pinAfter()
    local body = ss:match("\nfunction SpineShelf%.pinAfter%(entries, i, side%)\n(.-)\nend\n")
    assert(body, "no pinAfter")
    return assert(load("return function(entries, i, side)\n" .. body .. "\nend"))()
end

t.test("a piece pins only at a boundary between items", function()
    local pa = pinAfter()
    -- items: 1 (one book), 2 (a group of three spines), 3
    local entries = { { item_idx = 1 }, { item_idx = 2 }, { item_idx = 2 }, { item_idx = 2 }, { item_idx = 3 } }
    assert(pa(entries, 2, "before") == 1, "before a group's first spine")
    assert(pa(entries, 3, "before") == nil, "mid-group, before")
    assert(pa(entries, 4, "after") == 2, "after a group's last spine")
    assert(pa(entries, 3, "after") == nil, "mid-group, after")
    assert(pa(entries, 1, "before") == 0, "before the page's first item")
    assert(pa(entries, 5, "after") == 3, "after the page's last item")
end)

t.test("each kind of piece knows where it would pin", function()
    assert(ss:find('w_.pin_after_idx = SpineShelf.pinAfter(opts.plan.entries, i, "before")', 1, true), "lead or gap piece")
    assert(ss:find('SpineShelf.pinAfter(opts.plan.entries, opts.row.last, "after")', 1, true), "row-end piece")
    assert(ss:find("w_.pin_after_idx = math.huge", 1, true), "a piece on a bare plank")
    assert(ss:find("c._pin_of = w_", 1, true), "a tall piece's own-row copy")
end)

t.test("a pinned piece leaves its shelf's deal", function()
    assert(ss:find('if m.module == "ornament" and m.ornament then pinned[m.ornament] = true end', 1, true), "not collected")
    assert(ss:find("if not pinned[c.name] then kept[#kept + 1] = c end", 1, true), "not left out of the deal")
end)

t.test("Pin here is offered where it can pin, and pins there", function()
    assert(menu:find("local src = widget or piece", 1, true) and menu:find("src = src and (src._pin_of or src)", 1, true),
           "the copy doesn't speak for the piece")
    -- A real long-press: the piece hands itself to the menu, not only its rect.
    local orn = io.open("lib/bookshelf_ornaments.lua"):read("*a")
    assert(orn:find("return h(self.placement.entry, self.placement, self.dimen, self)", 1, true), "the long-press passes only the rect")
    assert(w:find('require("lib/bookshelf_ornament_menu").show(entry, shelf, piece, widget)', 1, true), "the shelf drops the piece")
    assert(menu:find("if src and src.pin_after_idx and bw and bw._pinOrnament then", 1, true), "offered with nowhere to pin")
    assert(menu:find('row[#row + 1] = { text = _("Done"), callback = closeAnd() }', 1, true), "Done lost from the row")
    local f = w:match("\nfunction BookshelfWidget:_pinOrnament%(entry, piece%)\n(.-)\nend\n")
    assert(f, "no _pinOrnament")
    assert(f:find('module = "ornament"', 1, true) and f:find("ornament = entry.name", 1, true), "not an Ornament module of the piece")
    assert(f:find("local pos = (self._cursor or 1) + idx - 1", 1, true), "not where it stood")
    assert(f:find("self:_spineShowModule(m.id)", 1, true), "the shelf doesn't follow it")
end)

-- A pinned piece is drawn as the shelf draws the piece -- the same placement
-- (size), standing at ornamentY -- not as a module scaled to a box; its
-- long-press is its module menu, where Adjust stands in for Narrower/Wider.
t.test("a pinned piece looks as it did dealt, and its menu adjusts the piece", function()
    assert(ss:find('if m.module == "ornament" and m.ornament and orn then', 1, true), "not sized as a piece")
    assert(ss:find("orn_pl = orn.mod.place(pe, orn.budget, orn.stand_h, {", 1, true), "not the dealt piece's placement")
    assert(ss:find("tile = SpineShelf._pinnedPieceTile(e, stand_h, opts)", 1, true), "not drawn as a piece")
    local tile = ss:match("\nfunction SpineShelf%._pinnedPieceTile%(e, stand_h, opts%)\n(.-)\nend\n")
    assert(tile and tile:find("SpineShelf.ornamentY(pl, stand_h, opts)", 1, true), "doesn't stand like a piece")
    assert(tile:find("w_.hold_fn = function()", 1, true), "its long-press is the ornament menu")
    local orn = io.open("lib/bookshelf_ornaments.lua"):read("*a")
    assert(orn:find("if self.hold_fn then", 1, true), "the piece ignores its own hold handler")
    local m = w:match("\nfunction BookshelfWidget:_spineModuleMenu%(entry%)\n(.-)\nend\n")
    -- One Settings for a pinned piece: the piece's own ornament menu.
    assert(m and m:find("buttons = pinned_piece and {", 1, true), "no layout of its own")
    assert(m:find('{ text = _("Settings"), callback = adjustPiece }', 1, true), "Settings isn't the piece's menu")
    local pinned_rows = m:match("buttons = pinned_piece and {(.-)} or {")
    assert(pinned_rows and not pinned_rows:find("Narrower", 1, true) and not pinned_rows:find("def.show_settings", 1, true),
           "a pinned piece still has Narrower or the module's own Settings")
end)

-- Its long-press opens a different menu from the piece it was: the title
-- says why, so it doesn't read as the ornament menu gone missing.
t.test("a pinned piece's menu is titled as a pinned ornament", function()
    local m = w:match("\nfunction BookshelfWidget:_spineModuleMenu%(entry%)\n(.-)\nend\n")
    assert(m and m:find('(pinned_piece and _("Ornament micro-module (pinned)")', 1, true),
           "titled like any Ornament module")
end)

t.test("a pinned piece keeps its row: the dealt end piece gives way", function()
    assert(ss:find("hk.keep = function(i) return entries[i] and entries[i].orn_pl ~= nil end", 1, true),
           "a pinned piece wraps to the next row when a dealt piece takes the room")
end)

t.test("a pinned piece's ornament menu leaves out the deal's controls", function()
    assert(w:find('show(pe, bw, nil, nil, { pinned = true })', 1, true), "not opened as a pinned piece's")
    local mm = menu:match("\nfunction M%.show%(entry, bw, piece, widget, opts%)\n(.-)\nend\n")
    assert(mm, "show takes no opts")
    local _, n = mm:gsub("not opts%.pinned and {", "")
    assert(n == 2, "Place and Swap/Shuffle/Switch off rows not both left out: " .. n)
end)

-- A Shelf module's pieces are dealt for the module, not the shelf: pinning
-- one there would stand it among the main shelf's books instead, so "Pin
-- here" is never offered in a module (maintainer). The menu offers it only
-- to a piece that knows where it stands (pin_after_idx).
t.test("no Pin here for a piece in a Shelf module", function()
    local shelf = io.open("micromodules/shelf.lua"):read("*a")
    assert(shelf:find("no_pin = true", 1, true), "the Shelf module's rows don't say so")
    local n_all = select(2, ss:gsub("w_%.pin_after_idx = ", ""))
    local n_gated = select(2, ss:gsub("if not opts%.no_pin then w_%.pin_after_idx = ", ""))
    assert(n_all > 0 and n_all == n_gated, n_gated .. " of " .. n_all .. " pin positions are gated")
end)

t.done()
