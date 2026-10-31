-- tests/_test_palette_greys.lua
-- A greyscale screen picks a grey from chips, white to black, as they look,
-- in place of the "% black" dialog (whose number was hard to read the right
-- way round in night mode). The chips have to be told apart on a PW5, whose
-- greys are 16 bands (v >> 4), and the greys picked are stored as the dialog
-- stored them.
--
-- Usage (from plugin root): lua tests/_test_palette_greys.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local pal = io.open("lib/bookshelf_color_palette.lua"):read("*a")
local block = assert(pal:match("\nlocal GREYS = {}\n(do.-\nend)\n"), "GREYS moved")
local GREYS = assert(load("local GREYS = {}\n" .. block .. "\nreturn GREYS"))()

t.test("fifteen chips, white to black, light to dark, five to a row", function()
    local all = {}
    for _r, row in ipairs(GREYS) do
        eq(#row, 5)
        for _c, hex in ipairs(row) do all[#all + 1] = tonumber(hex:sub(2, 3), 16) end
    end
    eq(#all, 15); eq(all[1], 255); eq(all[15], 0)
    for i = 2, #all do assert(all[i] < all[i - 1], "not light to dark at " .. i) end
end)

t.test("no two chips are the same grey on a PW5 (16 bands)", function()
    local bands = {}
    for _r, row in ipairs(GREYS) do
        for _c, hex in ipairs(row) do
            local band = math.floor(tonumber(hex:sub(2, 3), 16) / 16)
            assert(not bands[band], "two chips in band " .. band)
            bands[band] = true
        end
    end
end)

t.test("a greyscale screen opens the palette's greys, anchored as the dialog was", function()
    local st = io.open("lib/bookshelf_settings.lua"):read("*a")
    local picker = st:match("function Settings:_pickColor%(raw_key, field, default_pct, title,(.-)\nend\n")
    assert(picker:find("{ greys = true, anchor = anchor, on_closed = onClosed })", 1, true))
    assert(not picker:find("showNudgeDialog", 1, true), "the % dialog is still used")
    -- What is stored: the grey as seen, through the % the dialog stored by.
    assert(picker:find("TP.partSave(key, { grey = _screenPctToByte(pct) })", 1, true))
end)

t.test("in night mode a chip is painted to look the grey it stands for", function()
    assert(pal:find("if self.seen and bb.getInverse and bb:getInverse() == 1 then", 1, true))
end)

t.test("Panel text left on Auto opens on the text colour drawn, not on black", function()
    -- Over a mid grey panel Auto draws white text; the picker marked black.
    local st = io.open("lib/bookshelf_settings.lua"):read("*a")
    local body = assert(st:match("\nlocal function _paintedRaw%(field%)\n(.-)\nend\n"), "_paintedRaw moved")
    local ink, raw_colors = nil, {}
    local stubs = {
        ["lib/bookshelf_cover_progress"] = { rawColors = function() return raw_colors end,
                                             panelInk = function() return ink end },
        ["ffi/blitbuffer"] = { isColor8 = function(c) return c.grey ~= nil end },
    }
    local env = setmetatable({ require = function(n) return stubs[n] end }, { __index = _G })
    local f = assert(load("local field = ...\n" .. body, "paintedRaw", "t", env))
    ink = { grey = 255, getColor8 = function(self) return { a = self.grey } end }
    eq(f("panel_ink").grey, 255, "Auto's white not offered")
    raw_colors.panel_ink = { grey = 0 }
    eq(f("panel_ink").grey, 0, "a picked Panel text is not what opens")
    raw_colors = {}
    eq(f("panel_color"), nil, "another colour borrowed the panel text's Auto")
    ink = nil
    eq(f("panel_ink"), nil)
end)

-- Perf review 2026-10-31: every swatch tap wrote the whole settings file
-- (~130 ms on a PW5) and rebuilt the shelf before the tick could show.
t.test("the picker holds its writes in memory and rebuilds the shelf once the taps pause", function()
    local st = io.open("lib/bookshelf_settings.lua"):read("*a")
    local picker = st:match("function Settings:_pickColor%(raw_key, field, default_pct, title,(.-)\nend\n")
    assert(picker:find("if own_defer then Orn.beginDeferred() end", 1, true), "each tap writes the settings file")
    assert(picker:find("UIManager:scheduleIn(0.35, fire)", 1, true), "each tap rebuilds the shelf")
    assert(picker:find("if own_defer then Orn.endDeferred() end", 1, true), "nothing writes it as it closes")
    local cp = io.open("lib/bookshelf_color_palette.lua"):read("*a")
    assert(cp:find("if opts and opts.on_closed then opts.on_closed() end", 1, true), "the picker has no close hook")
end)

t.done()
