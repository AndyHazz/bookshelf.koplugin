--[[
Micro-module: an ornament. A piece from your ornament packs placed on the
grid, sized to its cell and cropped to its drawing, with the same tap actions
a shelf ornament has: a KOReader or plugin action, Zoom (the piece full screen
with its info), or nothing.

The piece (its name in the ornaments folder) and the tap live on the card's
own entry (ctx.config), so two cards can show different pieces and do
different things. A piece set to Mirror: Always on the shelf is mirrored
here too. Add picks the piece in the ornament browser; Module settings
changes the piece or the tap action.
]]
local _ = require("lib/bookshelf_i18n").gettext

local function pieceFor(name)
    if type(name) ~= "string" then return nil end
    local ok, Orn = pcall(require, "lib/bookshelf_ornaments")
    if not (ok and Orn and Orn.listAll) then return nil end
    for _i, e in ipairs(Orn.listAll() or {}) do
        if e.name == name then return e end
    end
    return nil
end

-- The browser in pick mode; on_pick(entry) gets the chosen piece.
local function pickPiece(on_pick)
    require("lib/bookshelf_ornament_browser").show(nil, {
        title = _("Choose an ornament"),
        pick = on_pick,
    })
end

local function showSettings(ctx)
    if not (ctx and ctx.config) then return end
    local UIManager    = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local function close(fn)
        return function() UIManager:close(dialog); if fn then fn() end end
    end
    dialog = ButtonDialog:new{
        title = _("Ornament"), title_align = "center", width_factor = 0.7,
        buttons = {
            {{ text = _("Change ornament\xE2\x80\xA6"), callback = close(function()
                pickPiece(function(e) ctx.config:set("ornament", e.name) end)
            end) }},
            {{ text = _("Tap action\xE2\x80\xA6"), callback = close(function()
                -- The shelf ornaments' own chooser (an action, Zoom, or none),
                -- stored on this card instead of the piece.
                require("lib/bookshelf_ornament_menu").chooseTap(nil, nil, function(v)
                    if v == "zoom" then v = { zoom = true } end
                    ctx.config:set("tap", v)
                end)
            end) }},
        },
    }
    UIManager:show(dialog)
end

return {
    key   = "ornament",   -- stable id stored in user layouts; never change it
    title = _("Ornament"),
    summary = _("A piece from your ornament packs. Works offline."),
    -- A decoration for the home-screen grids, not a start-menu row.
    hero_only = true,
    -- No card behind it: the piece stands on the wallpaper, as on the shelf.
    bare = true,
    -- One cell to start: a new piece drops into any free cell on the page,
    -- since pieces fill small gaps (maintainer), not a page of its own.
    start_w = 1,
    start_h = 1,
    tap_feedback = true,

    render = function(ctx)
        local Kit = require("lib/bookshelf_module_kit")
        local mw = math.max(50, ctx.width)
        local mh = (ctx.height and ctx.height > 0) and ctx.height or mw
        local piece = pieceFor(ctx.config and ctx.config:get("ornament"))
        if not piece and ctx.preview then
            local ok, Orn = pcall(require, "lib/bookshelf_ornaments")
            local all = ok and Orn.listAll and Orn.listAll() or {}
            piece = all[1]
        end
        if not piece then
            return Kit.fitText{ text = _("Choose an ornament"), size = 15,
                scale_pct = ctx.scale, width = mw, fgcolor = Kit.COLOR_MUTED }
        end
        local CenterContainer = require("ui/widget/container/centercontainer")
        local Geom = require("ui/geometry")
        -- In the module picker the piece gets room round it, so it reads as a
        -- piece on a card rather than one cropped to its edges. A card on the
        -- grid stays edge to edge: its size is the user's choice.
        local pad = ctx.preview and math.floor(math.min(mw, mh) * 0.14) or 0
        return CenterContainer:new{
            dimen = Geom:new{ w = mw, h = mh },
            -- Mirrored as the piece's own shelf setting says ("Always").
            require("lib/bookshelf_ornament_browser").preview(piece, mw - 2 * pad, mh - 2 * pad,
                piece.mirror == "always"),
        }
    end,

    on_tap = function(ctx)
        local tap = ctx and ctx.config and ctx.config:get("tap")
        if type(tap) ~= "table" then return end
        if tap.zoom then
            local piece = pieceFor(ctx.config:get("ornament"))
            if piece then require("lib/bookshelf_ornament_zoom").show(piece, ctx.bw) end
        else
            require("lib/bookshelf_action_exec").dispatch(tap, ctx.bw)
        end
    end,

    -- Add flow: pick the piece first; cancelling the browser aborts the add.
    on_add = function(_host_ctx, done)
        pickPiece(function(e) done({ ornament = e.name }) end)
    end,

    show_settings = showSettings,
    _test = { pieceFor = pieceFor },
}
