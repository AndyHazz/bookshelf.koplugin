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
    assert(menu:find("if on_shelf and src and src.pin_after_idx and bw and bw._pinOrnament then", 1, true), "offered with nowhere to pin")
    assert(menu:find('left_btns[#left_btns + 1] = barButton(_("Pin to a spot")', 1, true), "Pin to a spot is not on the bar")
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
    -- One way in for a pinned piece: the piece's own ornament menu, in
    -- place of Width and the module's own settings.
    -- Maintainer: "Rename the adjust ornament button ... edit ornament and
    -- put its button in the strip, along with unpin."
    -- Since: "Edit" with the ornament's cup, the same width as the book
    -- menu's "Edit" with a book (maintainer).
    assert(m and m:find('{ icon = CUI.ICON_ORNAMENT, label = _("Edit"), callback = adjustPiece }', 1, true),
        "Edit (ornament) isn't in the piece's strip")
    assert(not m:find('_("Adjust ornament")', 1, true), "still called Adjust ornament")
    assert(m:find("if pinned_piece then\n            bar[#bar + 1] = { icon = ", 1, true)
           and m:find("if not pinned_piece then\n            blocks[#blocks + 1] = { type = \"stepper\", label = _(\"Width\")", 1, true),
        "a pinned piece still has Width or the module's own Settings")
end)

-- Maintainer: "When I use the adjust ornament button, then close that
-- adjust ornament menu by tapping outside, it should return the arrange
-- ornament menu."
t.test("leaving Adjust ornament by a tap outside, or Back, returns to the piece's menu", function()
    local m = w:match("\nfunction BookshelfWidget:_spineModuleMenu%(entry%)\n(.-)\nend\n")
    local adj = m:match("local function adjustPiece%(%)(.-)\n    end\n")
    assert(adj and adj:find("on_back = function() UIManager:nextTick(function()", 1, true)
        and adj:find("if now then bw:_spineModuleMenu(now) end", 1, true),
        "Adjust ornament has no way back to the piece's menu")
    local om = io.open("lib/bookshelf_ornament_menu.lua"):read("*a")
    local tap = om:match("function dialog:onTapOutside%(_arg, ges%)(.-)\n    end\n")
    assert(tap and tap:find("back()", 1, true), "a tap outside does not go back")
    assert(om:find("function dialog:onClose() back(); return true end", 1, true), "Back does not go back")
end)

t.test("a pinned piece's menu can add another ornament beside it", function()
    local m = w:match("\nfunction BookshelfWidget:_spineModuleMenu%(entry%)\n(.-)\nend\n")
    assert(m:find('bar[#bar + 1] = { icon = CUI_ORN, text = _("Add ornament") .. "\\xE2\\x80\\xA6", callback = addPiece }', 1, true),
        "no Add ornament in the piece's menu")
    local add = m:match("local function addPiece%(%)(.-)\n    end\n")
    assert(add and add:find("SM.addPieceAfter(l, id, pe)", 1, true), "it does not add after this piece")
end)

-- Maintainer: "arrange ornament menu should have a swap ornament button to
-- pick another".
t.test("a pinned piece's menu can swap it for another ornament, in the same spot", function()
    local m = w:match("\nfunction BookshelfWidget:_spineModuleMenu%(entry%)\n(.-)\nend\n")
    assert(m:find('bar[#bar + 1] = { icon = "\\xEE\\xAF\\xA0", text = _("Swap ornament") .. "\\xE2\\x80\\xA6", callback = swapPiece }', 1, true),
        "no Swap ornament in the piece's menu")
    local swap = m:match("local function swapPiece%(%)(.-)\n    end\n")
    assert(swap and swap:find("l[i].ornament = pe.name", 1, true) and swap:find("l[i].tap = pe.tap", 1, true),
        "it does not change this piece's ornament in place")
    assert(not swap:find("after", 1, true), "a swap moved the piece")
end)

t.test("arranging a piece: a hold on another piece or a book swaps them; a tap still switches", function()
    local m = w:match("\nfunction BookshelfWidget:_spineModuleMenu%(entry%)\n(.-)\nend\n")
    local hold = m:match("local function onHoldOther%(ges%)(.-)\n    end\n")
    assert(hold and hold:find("bw:_shelfSwap({ piece = id }, { piece = piece.id })", 1, true), "no piece swap")
    assert(hold:find("bw:_shelfSwap({ piece = id }, { book = fp })", 1, true), "no piece-with-book swap")
    assert(m:find('ev.ges == "hold" and onHoldOther(ev)', 1, true), "a hold still switches menus")
    assert(m:find('_("Long-press a book or another ornament to swap their places.")', 1, true), "the hint")
end)

-- Its long-press opens a different menu from the piece it was: the title
-- names the menu as a book's Arrange menu is named (maintainer), and the
-- strip under it says what pinning did.
t.test("a pinned piece's menu is titled as an Arrange menu", function()
    local m = w:match("\nfunction BookshelfWidget:_spineModuleMenu%(entry%)\n(.-)\nend\n")
    assert(m and m:find('template(_("Arrange: %1"), pieceName() or (def and def.title) or entry.module)', 1, true),
           "titled like any Ornament module")
    -- The piece by the name its file has ("Arrange: Cactus"), as the ornament
    -- browser shows it; the module's own title only where there is none.
    local name = m:match("local function pieceName%(%)(.-)\n    end\n")
    assert(name, "a pinned piece is only ever called Ornament")
    assert(name:find("displayName({ file = file })", 1, true), "not the browser's name for it")
    assert(name:find('match("([^/]+)$")', 1, true), "the pack's folder in the title")
    assert(m:find('_("Ornament module, positioned manually")', 1, true), "nothing says why this menu, not the ornament's")
end)

t.test("a pinned piece keeps its row: the dealt end piece gives way", function()
    assert(ss:find("hk.keep = function(i) return entries[i] and entries[i].orn_pl ~= nil end", 1, true),
           "a pinned piece wraps to the next row when a dealt piece takes the room")
end)

t.test("a pinned piece's ornament menu leaves out the deal's controls", function()
    assert(w:find('show(pe, bw, nil, nil, { pinned = true,', 1, true), "not opened as a pinned piece's")
    local mm = menu:match("\nfunction M%.show%(entry, bw, piece, widget, opts%)\n(.-)\nend\n")
    assert(mm, "show takes no opts")
    -- Place (the d-pad's left and right, and its count) and Swap / Shuffle /
    -- Switch off: none of them for a piece out of the deal.
    assert(mm:find("local placed = not opts.pinned", 1, true) and mm:find("local can_move = placed and", 1, true),
        "the place controls are offered for a pinned piece")
    assert(mm:find("if not opts.pinned then\n            left_btns[#left_btns + 1] = barButton(_(\"Swap\")", 1, true),
        "Swap/Shuffle/Switch off are offered for a pinned piece")
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
