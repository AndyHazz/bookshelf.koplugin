-- tests/_test_ornament_module.lua
-- The Ornament micro-module: a piece from the ornament packs placed on the
-- grid, with the same tap actions a shelf ornament has (a KOReader/plugin
-- action, or Zoom). Its piece and tap live on the card's own entry.
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
package.loaded["ffi/util"] = { template = function(s) return s end }
package.loaded["logger"] = { dbg = function() end, info = function() end,
    warn = function() end, err = function() end }

local PIECES = {
    { name = "Autumn/leaf.png", path = "/o/Autumn/leaf.png", aspect = 1 },
    { name = "cactus.svg", path = "/o/cactus.svg", aspect = 0.5 },
}
package.loaded["lib/bookshelf_ornaments"] = { listAll = function() return PIECES end }
local dispatched, zoomed, picked_with
package.loaded["lib/bookshelf_action_exec"] = {
    dispatch = function(tap, bw) dispatched = { tap = tap, bw = bw } end }
package.loaded["lib/bookshelf_ornament_zoom"] = {
    show = function(entry, bw) zoomed = { entry = entry, bw = bw } end }
local previewed
package.loaded["lib/bookshelf_ornament_browser"] = {
    show = function(_on_change, opts) picked_with = opts end,
    preview = function(e, w, h, mirror) previewed = { e = e, mirror = mirror }; return {} end }
package.loaded["lib/bookshelf_module_kit"] = { fitText = function() return {} end, COLOR_MUTED = 0 }
package.loaded["ui/widget/container/centercontainer"] = { new = function(_s, o) return o end }
package.loaded["ui/geometry"] = { new = function(_s, o) return o end }

local M = dofile("micromodules/ornament.lua")
local t = dofile("tests/_helpers.lua").runner()

local function ctxWith(cfg)
    local store = {}
    for k, v in pairs(cfg) do store[k] = v end
    return { bw = { tag = "bw" }, config = {
        get = function(_s, k, d) if store[k] == nil then return d end return store[k] end,
        set = function(_s, k, v) store[k] = v end,
    }, store = store }
end

t.test("finds its piece by name", function()
    assert(M._test.pieceFor("cactus.svg") == PIECES[2])
    assert(M._test.pieceFor("gone.png") == nil)
end)

t.test("a tap runs the stored action, as a shelf ornament's does", function()
    dispatched = nil
    local tap = { action = "show_frontlight_dialog", label = "Light" }
    M.on_tap(ctxWith({ ornament = "cactus.svg", tap = tap }))
    assert(dispatched and dispatched.tap == tap and dispatched.bw.tag == "bw")
end)

t.test("a Zoom tap shows the piece full screen", function()
    zoomed = nil
    M.on_tap(ctxWith({ ornament = "cactus.svg", tap = { zoom = true } }))
    assert(zoomed and zoomed.entry == PIECES[2])
end)

t.test("no tap action: a tap does nothing", function()
    dispatched, zoomed = nil, nil
    M.on_tap(ctxWith({ ornament = "cactus.svg" }))
    assert(dispatched == nil and zoomed == nil)
end)

t.test("Add picks a piece in the ornament browser", function()
    picked_with = nil
    local got
    M.on_add({}, function(fields) got = fields end)
    assert(picked_with and type(picked_with.pick) == "function", "browser not in pick mode")
    picked_with.pick(PIECES[1])
    assert(got and got.ornament == "Autumn/leaf.png")
end)

-- The piece keeps its own shelf mirror setting (Mirror: Always) on a card;
-- the card has no flip of its own. "Alternate" is the first deal, unflipped.
t.test("a card mirrors its piece as the shelf does", function()
    local function drawn(mirror)
        PIECES[2].mirror = mirror
        previewed = nil
        local ctx = ctxWith({ ornament = "cactus.svg", mirror = true })
        ctx.width, ctx.height, ctx.scale = 200, 200, 100
        M.render(ctx)
        assert(previewed and previewed.e == PIECES[2], "piece not drawn")
        return previewed.mirror
    end
    assert(drawn("always") == true, "Always not mirrored")
    assert(not drawn("off"), "Off mirrored (or a card-level flip still read)")
    assert(not drawn("alternate"), "Alternate's first deal mirrored")
    PIECES[2].mirror = nil
end)

t.done()
