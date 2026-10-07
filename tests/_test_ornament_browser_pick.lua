package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t = H.runner()
local src = io.open("lib/bookshelf_ornament_browser.lua"):read("*a")

t.test("the browser has a pick mode", function()
    assert(src:find("function Browser.show(on_change, opts)", 1, true))
    local b = src:match("function Browser:_pick%(item%)(.-)\nend\n")
    assert(b, "no _pick")
    assert(not src:find("is_plank", 1, true), "plank tiles are back in the collection")
    assert(b:find('O().setOff(item.entry.name, false)', 1, true), "a picked off piece stays off")
    assert(b:find('O().setPackOff(item.entry.pack, false)', 1, true), "a picked piece's off pack stays off")
    assert(b:find("self.opts.pick(item.entry)", 1, true))
    assert(b:find("self._close()", 1, true), "picking does not close the browser")
    assert(src:find('self.opts.pick and _("Cancel") or _("Apply")', 1, true), "the pick footer still says Apply")
end)

t.test("the browser's title is the collection, as its settings row", function()
    assert(src:find('title = self.opts.pick and _("Swap for") or _("Ornament collection"),', 1, true),
        "the browser is not titled Ornament collection")
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
    }
    local chips = load("return function(self)\n" .. method(src, "Browser:_chips()") .. "\nend", "c", "t",
        { O = function() return Orn end, _ = function(x) return x end, T = function(x) return x end,
          ALL = "\0all", ipairs = ipairs, pairs = pairs })()
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
    }
    local items = load("return function(self)\n" .. method(src, "Browser:_items()") .. "\nend", "i", "t",
        { O = function() return Orn end, ALL = "\0all", ipairs = ipairs })()
    local function names(opts)
        local got = {}
        for _i, it in ipairs(items({ chip = "\0all", opts = opts })) do got[#got + 1] = it.entry.name end
        return table.concat(got, ",")
    end
    H.eq(names({}), "H/bat.png,G/frame.png,pot.svg", "no pool filtered something")
    H.eq(names({ pool = function(e) return e.pack == nil or e.pack == "H" end }), "H/bat.png,pot.svg")
end)

t.test("the long-press menu's Swap hands the browser the shelf's pool", function()
    local m = io.open("lib/bookshelf_ornament_menu.lua"):read("*a")
    assert(m:find("ornamentsFor(shelf)", 1, true) and m:find("pool = ", 1, true),
        "Swap offers pieces this shelf never deals")
end)

t.done()
