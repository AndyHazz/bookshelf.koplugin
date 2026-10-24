-- tests/_test_module_card.lua
-- lib/bookshelf_module_card: a module's own card look (background, border,
-- text) and the colours its spec declares, stored on the module for the light
-- and dark looks, falling back to the shared Colors rows when unset.
package.path = "./?.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()

-- Colours as plain greys: { a = luminance }, paint = what is stored.
local function c8(v) return { a = v, getColor8 = function(self) return self end } end
package.loaded["ffi/blitbuffer"] = { Color8 = c8, COLOR_BLACK = c8(0), COLOR_WHITE = c8(0xFF) }
local suffix, flip = "", false
package.loaded["lib/bookshelf_cover_progress"] = {
    modeSuffix = function() return suffix end,
    resolvePicked = function(raw)
        if raw == nil then return nil end
        local g = raw.grey
        if flip then g = 0xFF - g end
        return c8(g)
    end,
}
package.loaded["lib/bookshelf_color"] = {
    invertValue = function(raw) return { grey = 0xFF - raw.grey } end,
}
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
local Card = dofile("lib/bookshelf_module_card.lua")

local base = { bg = c8(0xEE), border = c8(0x00), ink = c8(0x00), muted = c8(0x55) }

t.test("unset, a card looks as the shared Colors rows say", function()
    suffix = ""
    local look = Card.look({ id = "m" }, {}, base)
    assert(look.bg == base.bg and look.border == base.border and look.ink == base.ink, "not the shared look")
    assert(look.border_on == true and look.own_bg == false, "border or own_bg wrong")
end)

t.test("its own background brings auto ink; an override wins", function()
    suffix = ""
    local e = { colors = { bg = { grey = 0x20 } } }
    local look = Card.look(e, {}, base)
    assert(look.own_bg and look.bg.a == 0x20, "own bg not used")
    assert(look.ink.a == 0xFF, "dark card, dark text: " .. look.ink.a)
    assert(look.muted.a > 0x20 and look.muted.a < 0xFF, "muted not between card and ink")
    e.colors.ink = { grey = 0x40 }
    assert(Card.look(e, {}, base).ink.a == 0x40, "the override lost")
    local light = Card.look({ colors = { bg = { grey = 0xF0 } } }, {}, base)
    assert(light.ink.a == 0x00, "light card, light text")
end)

t.test("a card without its own background keeps the shared ink", function()
    local look = Card.look({ colors = { border_color = { grey = 0x80 } } }, {}, { bg = c8(0xEE), ink = c8(0x33), muted = c8(0x66), border = c8(0) })
    assert(look.ink.a == 0x33 and look.border.a == 0x80, "shared ink replaced, or border colour ignored")
end)

t.test("the border can be switched off, per look", function()
    suffix = ""
    local e = { colors = { border = false } }
    assert(Card.look(e, {}, base).border_on == false, "still on")
    suffix = "_night"
    assert(Card.look(e, {}, base).border_on == true, "the dark look followed the light one")
end)

t.test("light and dark are stored apart", function()
    local e = {}
    suffix = ""
    Card.set(e, "bg", { grey = 0x10 })
    suffix = "_night"
    Card.set(e, "bg", { grey = 0x90 })
    assert(e.colors.bg.grey == 0x10 and e.colors.bg_night.grey == 0x90, "slots collided")
    Card.set(e, "bg", nil)
    assert(e.colors.bg_night == nil and e.colors.bg.grey == 0x10, "clearing hit the wrong slot")
    suffix = ""
    Card.set(e, "bg", nil)
    assert(e.colors == nil, "an empty colours table is left on the module")
end)

t.test("a spec's own colours resolve with their light and dark defaults", function()
    local def = { colors = {
        { id = "bar", text = "Bar", default = { grey = 0x30 }, default_dark = { grey = 0xC0 } },
    } }
    suffix, flip = "", false
    assert(Card.look({}, def, base).colors.bar.a == 0x30, "light default")
    -- The dark default is what the reader SEES; the night slot is stored
    -- pre-inverted for a frame that flips it (as every palette colour is).
    suffix, flip = "_night", true
    assert(Card.look({}, def, base).colors.bar.a == 0xC0, "dark default")
    suffix, flip = "", false
    local e = { colors = { bar = { grey = 0x77 } } }
    assert(Card.look(e, def, base).colors.bar.a == 0x77, "the reader's pick lost")
end)

t.test("rows: the card's four, then the spec's own; a bare module has only its own", function()
    local def = { colors = { { id = "bar", text = "Bar" } } }
    local keys = {}
    for _i, r in ipairs(Card.rows(def)) do keys[#keys + 1] = r.key end
    assert(table.concat(keys, ",") == "bg,border,border_color,ink,bar", table.concat(keys, ","))
    def.bare = true
    keys = {}
    for _i, r in ipairs(Card.rows(def)) do keys[#keys + 1] = r.key end
    assert(table.concat(keys, ",") == "bar", table.concat(keys, ","))
    assert(#Card.rows({ bare = true }) == 0, "a bare module with no colours has rows")
end)

t.test("a spec colour may not take a card key", function()
    assert(Card.validColors({ { id = "bar", text = "Bar" } }) == true)
    assert(Card.validColors({ { id = "bg", text = "X" } }) == false, "took bg")
    assert(Card.validColors({ { text = "X" } }) == false, "no id")
    assert(Card.validColors("red") == false, "not a list")
end)

-- Every card is made by HeroModules._makeCell (top panel, full screen, cover
-- and spine shelves): it takes the module's look, points the module's render
-- at its own card and ink, and puts the shared ones back after.
t.test("cards are drawn with the module's own look", function()
    local src = io.open("lib/bookshelf_hero_modules.lua"):read("*a")
    local cell = src:match("\nfunction HeroModules%._makeCell%(.-\nend\n")
    assert(cell and cell:find("local look = Card.look(entry, def, shared)", 1, true), "no look")
    assert(cell:find("Modules.setCardBg(look.bg)", 1, true) and cell:find("Modules.setCardBg(shared.bg)", 1, true),
           "the module's render isn't pointed at its own card, or it isn't put back")
    assert(cell:find("local card_bg = look.bg", 1, true), "the card isn't filled with it")
    assert(cell:find("(bare or not look.border_on) and 0", 1, true), "the border can't be switched off")
    assert(cell:find("color       = look.border,", 1, true), "the border colour isn't the module's")
    assert(src:find("colors = colors or {},", 1, true), "ctx.colors missing from the render")
end)

t.test("the palette icon is in the editor toolbar and the spine module menu", function()
    local ed = io.open("lib/bookshelf_module_grid_editor.lua"):read("*a")
    assert(ed:find("self:_titleRow(title, face, width - 2 * self.margin, entry)", 1, true), "editor title")
    assert(ed:find('require("lib/bookshelf_module_card_menu").show(ctx)', 1, true), "editor opens the menu")
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    assert(w:find("d:addWidget(CardMenu.titleRow(", 1, true), "spine module menu title")
    assert(w:find("function host.ctx_for(entry)", 1, true), "a cover shelf's modules don't save to the shelf")
end)

t.test("ctx.card says when the reader set this card, for the look on screen", function()
    -- A module that paints its own card (the Reading Log's framed cards) uses
    -- this card when custom, so the palette icon reaches every module.
    suffix = ""
    assert(Card.custom({ colors = {} }) == false)
    assert(Card.custom({ colors = { border = false } }) == true, "a border switched off is a setting")
    assert(Card.custom({ colors = { bg_night = { grey = 3 } } }) == false, "the dark look's setting counted in the light")
    suffix = "_night"
    assert(Card.custom({ colors = { bg_night = { grey = 3 } } }) == true)
    suffix = ""
    local entry = { colors = { bg = { grey = 0x30 } } }
    local look = Card.look(entry, nil, base)
    local c = Card.ctxCard(entry, look)
    assert(c.custom and c.bg == look.bg and c.ink == look.ink and c.border_on == true)
    c = Card.ctxCard({ colors = { border = false } }, Card.look({ colors = { border = false } }, nil, base))
    assert(c.border_on == false)
end)

t.test("the render context carries the card", function()
    local hm = io.open("lib/bookshelf_hero_modules.lua"):read("*a")
    assert(hm:find("local function _renderFitted(def, inner_w, inner_h, base_scale, refresh, entry, user_mult, bw, colors, card)", 1, true))
    assert(hm:find("            card = card,", 1, true), "ctx.card not set")
    assert(hm:find("Card.ctxCard(entry, look))", 1, true), "the cell does not pass its look")
end)

t.done()
