-- tests/_test_kit_review.lua
-- Fixes from the 2026-10-31 review of the shared popup kit.
--
-- Usage (from plugin root): lua tests/_test_kit_review.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t = H.runner()
local function read(p) return io.open(p):read("*a") end

-- A right-to-left UI mirrors HorizontalGroup; controls painted by their own
-- offsets put the black of a choice, a tick's label, under another cell.
t.test("controls painted by their own offsets are not mirrored", function()
    local kit = read("lib/bookshelf_popup_kit.lua")
    assert(kit:find('local row = HorizontalGroup:new{ align = "top", allow_mirroring = false }', 1, true),
        "Kit.segmented mirrors")
    assert(kit:find('local hg, fr = HorizontalGroup:new{ align = "top", allow_mirroring = false }, {}', 1, true),
        "Kit.segmentedGrid mirrors")
    local sl = read("lib/bookshelf_slider.lua")
    local _n, count = sl:gsub("allow_mirroring = false", "")
    H.eq(count, 3, "the slider's rows mirror")
end)

t.test("a page of a menu lines up with it, takes its corners, and rings its footer", function()
    local lm = read("lib/bookshelf_library_modal.lua")
    assert(lm:find("self.modal_w = over and (over.w - 2 * Size.border.window)", 1, true),
        "a page of the menu stands a border proud of it")
    assert(lm:find("radius = over and Space.radius.window or Space.px(8),", 1, true), "a page has its own corners")
    assert(lm:find("PopupKit.footerRow(actions, content_width, { radius = self.frame.radius })", 1, true),
        "the footer's corners are not the frame's")
    local fr = read("lib/bookshelf_popup_kit.lua"):match("\n(function Kit%.footerRow%(.-\nend)\n")
    assert(fr and fr:find("Kit.ringFocus(btn", 1, true), "the footer inverts on focus")
end)

t.test("greyed text is grey, a nudge's hold acts at once, no false in a keys row", function()
    local ep = read("lib/bookshelf_editor_page.lua")
    assert(ep:find("if enabled == false then return Blitbuffer.COLOR_GRAY end", 1, true), "greyed text is dark grey")
    assert(ep:find("if b.on_edit then cell = Kit.tapCell(pill, pill_w, h, b.on_edit) end", 1, true),
        "on_edit = false puts false in the keys row")
    local cb = read("lib/bookshelf_chip_button.lua")
    assert(cb:find("if opts.instant then opts.on_hold()", 1, true), "a hold shows pressed first")
end)

t.test("a card's heading reads on the card: light grey on black, darker grey on grey", function()
    local kit = read("lib/bookshelf_popup_kit.lua")
    assert(kit:find("local head = Kit.heading(text, font_size, Kit.headInk(ink))", 1, true),
        "the icon heading ignores the card's ink")
    local hi = kit:match("\n(function Kit%.headInk%(ink%).-\nend)\n")
    assert(hi and not hi:find("== nil", 1, true), "a Color8 compared with nil raises on the device")
    local BB = { COLOR_WHITE = {}, COLOR_BLACK = {}, COLOR_LIGHT_GRAY = {}, COLOR_GRAY = {} }
    local K = { DIM_ON_GREY = {} }
    local f = assert(load("local Kit, Blitbuffer = ...\n" .. hi .. "\nreturn Kit.headInk", "hi", "t", _G))(K, BB)
    assert(f(BB.COLOR_WHITE) == BB.COLOR_LIGHT_GRAY)
    assert(f(BB.COLOR_BLACK) == K.DIM_ON_GREY)
    assert(f(nil) == K.DIM_ON_GREY)
    assert(f(BB.COLOR_GRAY) == BB.COLOR_GRAY, "a greyed card's heading is not its grey")
end)

-- The picker spans the screen, so a bare setDirty(self) or close(widget,
-- "ui") refreshed all of it on every swatch tap and on closing.
t.test("the colour picker refreshes its own box", function()
    local cp = read("lib/bookshelf_color_palette.lua")
    assert(not cp:find('UIManager:setDirty(self, "ui")', 1, true), "a swatch tap refreshes the whole screen")
    assert(not cp:find('UIManager:close(widget, "ui")', 1, true), "closing refreshes the whole screen")
    assert(cp:find('UIManager:close(widget, "ui", (d and d.x) and d or nil)', 1, true))
end)

-- The grey nudge card was built four ways (border 0, then cardify), each
-- with its own copy of the minus and plus glyphs.
t.test("a nudge card is Kit.button's card, its glyphs the kit's", function()
    local kit = read("lib/bookshelf_popup_kit.lua")
    assert(kit:find("Kit.MINUS, Kit.PLUS = ", 1, true), "no shared minus and plus")
    local b = kit:match("\n(function Kit%.button%(opts%).-\nend)\n")
    assert(b and b:find("if card then Kit.cardify(btn[1]) end", 1, true), "Kit.button has no card")
    for _i, f in ipairs({ "lib/bookshelf_editor_page.lua", "lib/bookshelf_slider.lua",
                          "lib/bookshelf_ornament_menu.lua", "lib/bookshelf_module_grid_editor.lua" }) do
        local src = read(f)
        assert(not src:find("cardify(btn[1])", 1, true), f .. " builds its own card")
        assert(not src:find('"\\xEF\\x81\\xA8"', 1, true) and not src:find("\xEF\x81\xA8", 1, true),
            f .. " has its own minus")
    end
end)

-- STYLE.md: every popup takes the keys. The colour picker had no layout, so
-- on a keys-only Kindle it could be neither used nor left.
t.test("the colour picker takes the keys: swatches, tiles and footer, Back cancels", function()
    local cp = read("lib/bookshelf_color_palette.lua")
    assert(cp:find("Kit.keyFocus(self, self._key_state", 1, true), "the picker has no key cursor")
    assert(cp:find("self.layout = layout", 1, true), "the picker has no key layout")
    local sw = cp:match("\n(local function swatchTile%(.-\nend)\n")
    assert(sw and sw:find("Kit.tapCell(", 1, true), "a swatch is not a kit tap cell (no focus ring)")
    local ft = cp:match("\n(local function makeFooterBtn%(.-\nend)\n")
    assert(ft and ft:find("Kit.tapCell(", 1, true), "a footer button is not a kit tap cell")
    assert(cp:find("self.key_events.Close = { { Device.input.group.Back } }", 1, true), "Back does not close it")
    assert(cp:find("function ColorPaletteWidget:onClose()", 1, true))
end)

t.done()
