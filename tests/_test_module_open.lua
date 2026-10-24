-- tests/_test_module_open.lua
-- A book tapped in a micro-module (the Shelf module) opens the way the shelf
-- opens one: the tap-to-open setting, the double tap, and the cover-opening
-- effect played on the module's own cover before the full-screen view closes
-- (closing it first left no effect and no "Opening" message: a dead pause).
package.path = "./?.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()

local settings = {}
local log = {}
package.loaded["lib/bookshelf_settings_store"] = {
    expandedTapAction = function() return settings.action or "open" end,
    nilOrTrue = function(k) return settings[k] ~= false end,
}
package.loaded["lib/bookshelf_gestures"] = { on = function(id) return settings[id] ~= false end }
package.loaded["ui/uimanager"] = { forceRePaint = function() log[#log + 1] = "repaint" end }
package.loaded["device"] = { screen = { refreshUI = function() log[#log + 1] = "refresh" end } }
local SW = {}
package.loaded["lib/bookshelf_spine_widget"] = SW
local SS = { paintOpeningTilt = function(slot) log[#log + 1] = "tilt " .. slot.book.filepath; return 0, 0, 10, 10 end }
package.loaded["lib/bookshelf_spine_shelf"] = SS
package.loaded["lib/bookshelf_widget"] = {
    _paintOpeningEffect = function(_self, fp)
        log[#log + 1] = "flex " .. fp
        SW.last_tapped = nil
    end,
}
package.loaded["apps/reader/readerui"] = { showReader = function(_s, fp) log[#log + 1] = "showReader " .. fp end }
local reloaded = {}
package.loaded["lib/bookshelf_hero_modules"] = { _reloadShelfCell = function(bw, id)
    if bw._cells and bw._cells[id] then reloaded[#reloaded + 1] = id; return true end
    return false
end }
local M = dofile("lib/bookshelf_module_open.lua")

local book = { filepath = "/a.epub" }
local function shelfCtx()
    local fs = { onTapClose = function() log[#log + 1] = "close fullscreen" end }
    local bw = { _micro_fullscreen = fs }
    function bw:_openBook(b, after, opts)
        log[#log + 1] = "open " .. b.filepath .. (opts and opts.no_effect and " no_effect" or "")
        self._after = after
    end
    function bw:_previewBook(b) log[#log + 1] = "preview " .. b.filepath end
    local ctx = { bw = bw, refresh = function() log[#log + 1] = "refresh module" end }
    return ctx, bw
end

t.test("a tap opens with the effect on the module's cover, then the full screen goes", function()
    settings = {}; log = {}; M._staged = {}
    local ctx, bw = shelfCtx()
    SW.last_tapped = { book = book }
    M.tap(ctx, "m1", book)
    assert(log[1] == "repaint" and log[2] == "flex /a.epub", table.concat(log, ", "))
    assert(log[3] == "open /a.epub no_effect", "the shelf would play its effect on the wrong screen: " .. tostring(log[3]))
    assert(#log == 3, "the full-screen view closed before the reader was up")
    bw._after()
    assert(log[4] == "close fullscreen", "the full-screen view stayed under the reader")
end)

t.test("a tapped spine tilts", function()
    settings = {}; log = {}; M._staged = {}
    local ctx = shelfCtx()
    SW.last_tapped = nil
    SS.last_tapped_slot = { book = book }
    M.tap(ctx, "m1", book)
    assert(log[2] == "tilt /a.epub" and SS.last_tapped_slot == nil, table.concat(log, ", "))
end)

t.test("Open with a double tap: the first tap marks the book, the second opens", function()
    settings = { action = "open_double" }; log = {}; M._staged = {}
    local ctx = shelfCtx()
    M.tap(ctx, "m1", book)
    assert(M.staged("m1") == "/a.epub" and log[1] == "refresh module" and #log == 1, table.concat(log, ", "))
    M.tap(ctx, "m1", { filepath = "/b.epub" })
    assert(M.staged("m1") == "/b.epub", "another book moves the mark")
    log = {}
    M.tap(ctx, "m1", { filepath = "/b.epub" })
    assert(M.staged("m1") == nil and log[#log] == "open /b.epub no_effect", table.concat(log, ", "))
end)

t.test("Show the book's details: the top panel on the shelf, a mark over the reader", function()
    settings = { action = "show_detail" }; log = {}; M._staged = {}
    local ctx = shelfCtx()
    M.tap(ctx, "m1", book)
    assert(log[1] == "close fullscreen" and log[2] == "preview /a.epub", table.concat(log, ", "))
    log = {}
    local reader = { bw = { _reader_context = true }, refresh = function() log[#log + 1] = "refresh module" end }
    M.tap(reader, "m2", book)
    assert(M.staged("m2") == "/a.epub", "nowhere to show it, and not opened either")
end)

t.test("with the top panel on screen a tap shows the book there, as on the shelf", function()
    for _i, surface in ipairs({ "hero", "shelf" }) do
        settings = { action = "open" }; log = {}; M._staged = {}
        local ctx, bw = shelfCtx()
        ctx.surface = surface
        M.tap(ctx, "m1", book)
        assert(log[1] == "preview /a.epub" and #log == (surface == "shelf" and 2 or 1), surface .. ": " .. table.concat(log, ", "))
        -- The second tap on the book now in the panel opens it, with the
        -- effect on the module's own cover.
        bw._preview_book = book; log = {}
        M.tap(ctx, "m1", book)
        assert(log[#log] == "open /a.epub no_effect", surface .. ": " .. table.concat(log, ", "))
    end
    -- A full screen shelf, the full-screen view and the start menu hide the
    -- panel: those keep the full screen setting.
    for _i, case in ipairs({ { "shelf", true }, { "fullscreen" }, { "start_menu" } }) do
        settings = { action = "open" }; log = {}; M._staged = {}
        local ctx, bw = shelfCtx()
        ctx.surface, bw._expanded = case[1], case[2]
        M.tap(ctx, "m1", book)
        assert(log[1] == "open /a.epub no_effect", case[1] .. ": " .. table.concat(log, ", "))
    end
end)

t.test("with the top panel on screen the module lifts the panel's book, and lets go", function()
    settings = { action = "open" }; log = {}; M._staged = {}
    local ctx, bw = shelfCtx()
    ctx.surface = "shelf"
    function bw:_previewBook(b) log[#log + 1] = "preview " .. b.filepath; self._preview_book = b end
    M.tap(ctx, "m1", book)
    assert(log[2] == "refresh module", "the tapped spine never lifts: " .. table.concat(log, ", "))
    assert(M.staged("m1", ctx) == "/a.epub", "the render doesn't lift the panel's book")
    -- Another book (a shelf cover, say) takes the panel: the module redraws.
    local ticked
    package.loaded["ui/uimanager"].nextTick = function(_s, f) ticked = f end
    M.previewChanged(bw, "/b.epub")
    assert(ticked and bw._module_lifts.m1 == nil, "the old book stays lifted")
    log = {}; ticked()
    assert(log[1] == "refresh module", "no redraw: " .. table.concat(log, ", "))
    -- A module that never had a book in the panel doesn't redraw on the
    -- shelf's taps (it did on every one).
    local ctx2 = { bw = bw, surface = "shelf", refresh = function() end }
    bw._preview_book = { filepath = "/c.epub" }
    assert(M.staged("m2", ctx2) == nil and bw._module_lifts.m2 == nil,
        "a module with no book in the panel signs up for redraws")
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    assert(w:find('require("lib/bookshelf_module_open").previewChanged(self, book.filepath)', 1, true),
        "the shelf never tells the module")
    assert(io.open("micromodules/shelf.lua"):read("*a"):find("Open.staged(key, ctx)", 1, true))
end)

t.test("the lift moves by flipping two slots, not by redrawing the module", function()
    settings = { action = "open" }; log = {}; M._staged = {}
    package.loaded["device"].screen.scaleBySize = function(_s, n) return n end
    package.loaded["ui/geometry"] = { new = function(_s, r) return r end }
    local dirty = {}
    package.loaded["ui/uimanager"].setDirty = function(_s, _w, f) dirty[#dirty + 1] = f() end
    local ctx, bw = shelfCtx()
    ctx.surface = "shelf"
    function bw:_previewBook(b) M.previewChanged(self, b.filepath); self._preview_book = b end
    local a = { entry = {}, book = { filepath = "/a.epub" }, dimen = { x = 0, y = 0, w = 10, h = 10 } }
    local b = { entry = {}, book = { filepath = "/b.epub" }, dimen = { x = 20, y = 0, w = 10, h = 10 } }
    local face = { book = { filepath = "/f.epub" } }   -- face-out: no entry
    -- The shelf as on screen, the module's row a few levels down.
    bw._inner_vgroup = { {}, { { { _slots_by_fp = { ["/a.epub"] = a, ["/b.epub"] = b, ["/f.epub"] = face } } } } }
    M.tap(ctx, "m1", { filepath = "/a.epub" })
    assert(a.is_selected == true and #dirty == 1, "a: " .. #dirty)
    assert(not table.concat(log, ","):find("refresh module"), "the module redrew: " .. table.concat(log, ", "))
    dirty = {}
    M.tap(ctx, "m1", { filepath = "/b.epub" })
    assert(a.is_selected == false and b.is_selected == true and #dirty == 2, "moved: " .. #dirty)
    assert(not table.concat(log, ","):find("refresh module"), "the module redrew")
    -- A face-out book's lift is built in: the module is made again in its
    -- own cell, or, where that can't be found, its host redraws.
    M.tap(ctx, "m1", { filepath = "/f.epub" })
    assert(log[#log] == "refresh module", table.concat(log, ", "))
    bw._cells = { m1 = true }; log = {}
    M.tap(ctx, "m1", { filepath = "/b.epub" })
    M.tap(ctx, "m1", { filepath = "/f.epub" })
    assert(reloaded[#reloaded] == "m1" and not table.concat(log, ","):find("refresh module"),
        "the whole shelf redrew for one module: " .. table.concat(log, ", "))
    -- The tap tells the shelf the book isn't one of its own, so its
    -- highlight repaint doesn't fall back to rebuilding every row.
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    assert(w:find("if replaced == 0 and self._preview_from_module then return end", 1, true))
end)

t.test("the Shelf module asks for its books' covers, as the shelf does for its own", function()
    local src = io.open("micromodules/shelf.lua"):read("*a")
    assert(src:find("pcall(bw._kickOffMissingMetaExtraction, bw, books,", 1, true), "never asks")
    local _n, c = src:gsub("\n    askForCovers%(ctx, books, ", "")
    assert(c == 2, "covers and spines both ask: " .. c)
end)

t.test("a shelf module's render knows it is on the shelf", function()
    local src = io.open("lib/bookshelf_hero_modules.lua"):read("*a")
    assert(src:find("surface = _surfaceOf(entry), bw = bw,", 1, true),
        "a shelf module's ctx names whichever grid was built last")
    assert(src:find("return (host and host.surface) or _build_surface", 1, true))
end)

t.test("a double tap opens straight away, when KOReader's double tap is on", function()
    settings = { action = "open_double" }; log = {}; M._staged = { m1 = "/x.epub" }
    local ctx = shelfCtx()
    M.doubleTap(ctx, "m1", book)
    assert(log[#log] == "open /a.epub no_effect" and M.staged("m1") == nil, table.concat(log, ", "))
    settings.double_tap = false; log = {}
    M.doubleTap(ctx, "m1", book)
    assert(#log == 0, "opened with the double tap switched off")
end)

t.test("over the reader it opens through KOReader; effect off plays nothing", function()
    settings = { open_cover_effect = false }; log = {}; M._staged = {}
    SW.last_tapped = { book = book }
    M.tap({ bw = { _reader_context = true } }, "m1", book)
    assert(log[1] == "showReader /a.epub" and #log == 1 and SW.last_tapped == nil, table.concat(log, ", "))
end)

t.test("the Shelf module and the shelf use it", function()
    local src = io.open("micromodules/shelf.lua"):read("*a")
    assert(src:find('require("lib/bookshelf_module_open")', 1, true), "the Shelf module opens on its own")
    assert(not src:find("local function openBook", 1, true), "the old open, which closed the full-screen view first, is still there")
    local _n, sel = src:gsub("selected_filepath = staged", "")
    assert(sel == 2, "the marked book isn't ringed in both styles")
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    assert(w:find("function BookshelfWidget:_openBook(book, after_open_callback, opts)", 1, true), "no opts")
    assert(w:find("if not (opts and opts.no_effect) then", 1, true), "the shelf plays its effect again")
    local ss = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")
    assert(ss:find("SpineShelf.last_tapped_slot = self", 1, true), "a spine tap leaves no rendezvous")
end)

-- A module's spine tips forward over the ground really behind it: the
-- full-screen view tints and blurs the wallpaper, so the shelf's own
-- wallpaper-and-recess ground showed as a bright block above the spine.
t.test("a module's spine keeps the ground it was painted over, and the tilt uses it", function()
    local ss = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")
    assert(ss:find("tile.keep_ground = opts.keep_ground or nil", 1, true), "module spines aren't told")
    local paint = ss:match("\nfunction SpineBookSlot:paintTo%(bb, x, y%)\n(.-)\nend\n")
    assert(paint and paint:find("if self.keep_ground then", 1, true), "no ground kept at paint time")
    local tilt = ss:match("\nfunction SpineShelf%.paintOpeningTilt%(slot%)\n(.-)\nend\n")
    assert(tilt and tilt:find("c:blitFrom(slot._ground", 1, true), "the tilt still guesses the ground")
end)

t.done()
