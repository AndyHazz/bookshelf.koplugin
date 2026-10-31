package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t = H.runner()
local src = io.open("lib/bookshelf_ornament_browser.lua"):read("*a")

t.test("the browser has a pick mode", function()
    assert(src:find("function Browser.show(on_change, opts)", 1, true))
    local b = src:match("function Browser:_pick%(item%)(.-)\nend\n")
    assert(b, "no _pick")
    assert(not src:find("is_plank", 1, true), "plank tiles are back in the collection")
    -- Through the seam (SW: the set of the theme on screen, or the collection's).
    assert(b:find('sw.setOff(item.entry.name, false)', 1, true), "a picked off piece stays off")
    assert(b:find('sw.setPackOff(item.entry.pack, false)', 1, true), "a picked piece's off pack stays off")
    assert(b:find("self.opts.pick(item.entry)", 1, true))
    assert(b:find("self._close()", 1, true), "picking does not close the browser")
    -- Close, which the modal turns into the title's X; Cancel when picking.
    assert(src:find('self.opts.pick and _("Cancel") or _("Close")', 1, true), "the footer is not Close (or Cancel when picking)")
end)

t.test("the browser's title is the collection, as its settings row", function()
    assert(src:find('title = self.opts.title or (self.opts.pick and _("Swap for") or _("Ornament collection")),', 1, true),
        "the browser is not titled Ornament collection (or the caller's title)")
end)

local function method(text, name)
    local body = text:match("\nfunction " .. name:gsub("[%.%(%):]", "%%%0") .. "\n(.-)\nend\n")
    assert(body, name .. " not found")
    return body
end

t.test("a pack with no ornaments (planks only) gets no chip", function()
    -- PW5: the Planks pack's designs moved to the plank picker, and its chip
    -- here opened an empty page.
    local Orn = {
        listAll = function()
            return { { name = "Autumn/owl.png", pack = "Autumn" }, { name = "cat.svg" } },
                   { "Autumn", "Planks" }
        end,
        isPackOff = function() return false end,
        allowRecent = function() return false end,
    }
    local chips = load("return function(self)\n" .. method(src, "Browser:_chips()") .. "\nend", "c", "t",
        { O = function() return Orn end, SW = function() return Orn end, _ = function(x) return x end,
          T = function(x) return x end, ALL = "\0all", ipairs = ipairs, pairs = pairs })()
    local got = {}
    for _i, c in ipairs(chips({ chip = "\0all" })) do got[#got + 1] = c.label end
    H.eq(table.concat(got, ","), "All,Autumn")
end)

t.test("switching packs keeps the browser one height", function()
    -- PW5: a pack with Apply pack theme has two footer rows, one without has
    -- one; the modal shrank and left a copy of its title bar on screen.
    -- Since the theme buttons left (Shelf theme menu), every pack's footer is
    -- one row; the two-row reserve went with them. The resize repaint stays,
    -- a general fix.
    assert(not src:find("footer_min_rows", 1, true), "the browser still reserves two footer rows")
    local m = io.open("lib/bookshelf_library_modal.lua"):read("*a")
    local r = method(m, "LibraryModal:refresh()")
    assert(not r:find("footer_min_rows", 1, true), "the modal's unused footer_min_rows is still there")
    assert(r:find("self:_repaintIfResized(old)", 1, true), "a resized modal does not repaint where it was")
    -- _repaintIfResized: the rectangle the modal last had (centred on the
    -- screen, recorded each refresh), repainted from the whole stack
    -- underneath, only when the size changed; and the frame's dimen, which
    -- FrameContainer sizes once at first paint, dropped so taps outside the
    -- modal are judged by its new size.
    local dirty = {}
    local f = load("return function(self, old)\n" .. method(m, "LibraryModal:_repaintIfResized(old)") .. "\nend", "r", "t",
        { UIManager = { setDirty = function(_u, w, mode, region) dirty[#dirty + 1] = { w, mode, region } end },
          Geom = { new = function(_g, o) return o end }, math = math,
          Device = { screen = { getWidth = function() return 1000 end, getHeight = function() return 1600 end } } })()
    local self = { frame = { getSize = function() return { w = 100, h = 200 } end, dimen = { w = 100, h = 240 } } }
    f(self, { x = 450, y = 680, w = 100, h = 240 })
    H.eq(#dirty, 1); H.eq(dirty[1][1], "all"); H.eq(dirty[1][3].h, 240, "not the old rectangle")
    H.eq(self.frame.dimen, nil, "the frame keeps hit-testing taps at its old size")
    H.eq(self._shown_rect.y, 700, "the new rectangle is not recorded where it is centred")
    dirty = {}
    f(self, self._shown_rect)
    H.eq(#dirty, 0, "a refresh at the same size repainted the stack")
    f(self, nil)
    H.eq(#dirty, 0, "the first refresh repainted the stack")
end)

t.test("Swap lists only the pieces the shelf deals from", function()
    local Orn = {
        listAll = function()
            return { { name = "H/bat.png", pack = "H" }, { name = "G/frame.png", pack = "G" },
                     { name = "pot.svg" } }, { "G", "H" }
        end,
        isOff = function() return false end,
        isPackOff = function() return false end,
        allowRecent = function() return false end,
    }
    local items = load("return function(self)\n" .. method(src, "Browser:_items()") .. "\nend", "i", "t",
        { O = function() return Orn end, SW = function() return Orn end, ALL = "\0all", ipairs = ipairs })()
    local function names(opts)
        local got = {}
        for _i, it in ipairs(items({ chip = "\0all", opts = opts })) do got[#got + 1] = it.entry.name end
        return table.concat(got, ",")
    end
    H.eq(names({}), "H/bat.png,G/frame.png,pot.svg", "no pool filtered something")
    H.eq(names({ pool = function(e) return e.pack == nil or e.pack == "H" end }), "H/bat.png,pot.svg")
end)

-- Maintainer: Swap offering only the shelf's own pack was unexpected; any
-- piece can be picked, and the pick switches it on for the shelf.
t.test("the long-press menu's Swap offers every piece", function()
    local m = io.open("lib/bookshelf_ornament_menu.lua"):read("*a")
    local i = m:find('barButton(_("Swap")', 1, true)
    assert(i, "no Swap")
    local call = m:sub(i, (m:find("Deck.swap(", i, true)))
    assert(call:find("pick = function(chosen)", 1, true), "Swap does not open the browser to pick")
    assert(not call:find("pool", 1, true), "Swap limits the browser to the shelf's pieces")
end)

t.test("opening shows a message at once and builds the browser after it", function()
    -- Decoding a page of pieces takes seconds on a PW5; with nothing on screen
    -- meanwhile, choosing the Ornament module felt like a crash (maintainer).
    local show = src:match("\nfunction Browser%.show%(on_change, opts%)\n(.-)\nend\n")
    assert(show, "Browser.show not found")
    local msg = show:find('_("Loading ornaments', 1, true)
    local paint = show:find("forceRePaint", 1, true)
    local later = show:find("nextTick", 1, true)
    local build = show:find("Browser._open", 1, true)
    assert(msg and paint and later and build, "no loading message before the build")
    assert(msg < paint and paint < later and later < build, "the message must paint before the build starts")
end)

-- PW5, 2026-10-30, 443 pieces: opening the browser took 32 s. Each piece's
-- isOff asks for the theme's set, which reached listAll, and outside the
-- recent window listAll reads every folder again (~36 ms on the PW5): 889
-- scans. The list takes one fresh look and holds the window for the rest.
t.test("listing the pieces reads the folders once, however many there are", function()
    local open, fresh = false, 0
    local all = {}
    for i = 1, 50 do all[i] = { name = "P/" .. i .. ".png", pack = "P" } end
    local Orn = {
        listAll = function() if not open then fresh = fresh + 1 end; return all, { "P" } end,
        allowRecent = function(on) local was = open; open = on and true or false; return was end,
    }
    local sw = {
        isOff = function() Orn.listAll(); return false end,
        isPackOff = function() Orn.listAll(); return false end,
    }
    local env = { O = function() return Orn end, SW = function() return sw end, ALL = "\0all",
        ipairs = ipairs, pairs = pairs, _ = function(x) return x end, T = function(x) return x end }
    local items = load("return function(self)\n" .. method(src, "Browser:_items()") .. "\nend", "i", "t", env)()
    H.eq(#items({ chip = "\0all", opts = {} }), 50)
    H.eq(fresh, 1, "the folders were read per piece")
    H.eq(open, false, "the window was left open")
    fresh = 0
    local chips = load("return function(self)\n" .. method(src, "Browser:_chips()") .. "\nend", "c", "t", env)()
    chips({ chip = "\0all" })
    H.eq(fresh, 1, "the chips read the folders per pack")
    H.eq(open, false)
end)

-- Maintainer: every piece looked greyed out, with no word on what the boxes
-- were for. The ticks are the set of the shelf's theme (Plain's was empty).
t.test("the browser says whose set the ticks are, and only a pack that is off fades", function()
    local cell = method(src, "Browser._renderCell(item, dimen)")
    assert(cell:find("if item.pack_off and not item.pick then preview = Faded:new", 1, true),
        "a piece that is only off still fades")
    assert(cell:find("if item.pick then return card end", 1, true), "Swap still shows the boxes")
    assert(src:find("intro = function() return self:_intro() end,\n        intro_below = true,", 1, true),
        "no line under the grid saying whose set it is")
    local m = io.open("lib/bookshelf_library_modal.lua"):read("*a")
    local grid = m:find("table.insert(body, padded(result_area))", 1, true)
    local below = m:find("if has_intro and self.config.intro_below then", 1, true)
    assert(grid and below and below > grid, "intro_below does not put the line under the grid")
    local intro = method(src, "Browser:_intro()")
    assert(intro:find("self.opts.pick", 1, true), "Swap gets the switches' line")
    -- The words, through a stub.
    local env = { _ = function(x) return x end,
        T = function(f, ...) local a = { ... }; return (f:gsub("%%(%d)", function(n) return tostring(a[tonumber(n)]) end)) end,
        TP = function() return { themeName = function() return "Plain" end, shelfTheme = function() return "plain" end } end }
    local f = load("return function(self)\n" .. intro .. "\nend", "n", "t", env)()
    H.eq(f({ opts = {}, on_count = 0, all_count = 443 }), "On Plain shelves: none yet. Check a piece to add it.")
    H.eq(f({ opts = {}, on_count = 12, all_count = 443 }),
        "On Plain shelves: 12 of 443. Check a piece to add it, uncheck to take it off.")
    H.eq(f({ opts = { pick = true }, on_count = 0, all_count = 443 }), nil)
end)

-- Perf review 2026-10-31: a tick read every ornament folder twice (the list,
-- then the chips, each outside the recent window).
t.test("a tick reads the folders as they were, not afresh", function()
    local ch = method(src, "Browser:_changed(rescan)")
    assert(ch:find("local was = (not rescan) and Orn.allowRecent(true)", 1, true), "a tick rescans the folders")
    assert(ch:find("if not rescan and not was then Orn.allowRecent(false) end", 1, true), "the window is left open")
end)

t.done()
