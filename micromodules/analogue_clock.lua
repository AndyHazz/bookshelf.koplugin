--[[
Start-menu module: an analogue clock face.
See README.md in this directory for the module spec contract. The digital
clock is a separate module (clock.lua); this one is its own entry in the Add
list for discoverability.

The face is drawn with blitbuffer primitives: 12 ticks inset from the edge
(the four quarter marks longer and thicker, the other eight shorter and
thinner), and the hour/minute hands stepped as small squares along
their angle (the painted-stroke technique used for the footer art). There is
no centre hub — the hands run a little past the centre point. No second hand:
the menu is static and e-ink does not animate per second.

Anti-aliasing: the whole face is drawn into an offscreen buffer at SS× and
scaled down, so the rim, ticks and hands get smooth edges instead of stepped
ones. Stroke widths and lengths are multiples of one scaled pixel unit
(Screen:scaleBySize(1), times the module font scale) so they stay proportional
across devices and allow fractional weights. The face sits inside an even
margin in the card, with an optional date line below it. Module settings
offer a face size and a show/hide toggle for the date. No TTL cache; no on_tap.
]]
local _ = require("lib/bookshelf_i18n").gettext

local SIZE_KEY = "micromodule_analogue_clock_size" -- "small" | "medium" (default) | "large"
local DATE_KEY = "micromodule_analogue_clock_date" -- boolean, default true (shown)

-- Face diameter caps per size, in scaled-pixel units (see pxUnit). "large"
-- fills the available width (minus the even margin) rather than using a cap.
local SIZE_UNITS = { small = 64, medium = 84, large = math.huge }

local function readSize()
    local Store = require("lib/bookshelf_settings_store")
    local v = Store.read(SIZE_KEY, "medium")
    if not SIZE_UNITS[v] then v = "medium" end
    return v
end

local function readShowDate()
    local Store = require("lib/bookshelf_settings_store")
    local v = Store.read(DATE_KEY, true)
    return v ~= false -- default (nil) and true both show
end

-- One scaled pixel unit and a fractional-weight helper, shared by the face
-- geometry and the diameter so everything scales together.
local function pxUnit(scale_pct)
    local Screen = require("device").screen
    local unit = math.max(1, Screen:scaleBySize(1) * (scale_pct or 100) / 100)
    return function(k) return math.max(1, math.floor(unit * k + 0.5)) end
end

-- Square Widget of side `diam` drawn for the time `now` (os.time()).
-- Anti-aliased by coverage: for each pixel near a shape we compute how much of
-- it the shape covers and blend black over the existing pixel by that fraction
-- (the device's bb:scale is nearest-neighbour, so supersampling gave no AA).
local function buildFace(diam, now, scale_pct)
    local Blitbuffer = require("ffi/blitbuffer")
    local Geom       = require("ui/geometry")
    local Widget     = require("ui/widget/widget")
    local Screen     = require("device").screen
    local unit = math.max(1, Screen:scaleBySize(1) * (scale_pct or 100) / 100)
    local function w(k) return unit * k end -- float weights, for crisp AA

    local tm    = os.date("*t", now)
    local minA  = (tm.min / 60) * 2 * math.pi
    local hourA = ((tm.hour % 12) + tm.min / 60) / 12 * 2 * math.pi

    local r          = diam / 2
    local ring       = w(1.5)          -- tick inset reference (no rim drawn)
    local tick_gap   = w(4.5)          -- gap between the ticks and the rim
    local tick_w_maj = w(1.5)          -- quarter ticks (12/3/6/9)
    local tick_w_min = w(1)            -- the other eight, thinner
    local tick_maj   = w(6)            -- quarter-mark length
    local tick_min   = w(2.5)          -- minor-mark length (shorter)
    local min_w, hour_w = w(1), w(2)   -- hand thicknesses (thin minute)
    local min_len    = r * 0.78
    local hour_len   = r * 0.50
    local tail_len   = math.max(w(4), r * 0.10) -- run past centre

    local Face = Widget:extend{}
    function Face:init() self.dimen = Geom:new{ w = diam, h = diam } end
    function Face:getSize() return Geom:new{ w = diam, h = diam } end
    function Face:paintTo(bb, x, y)
        self.dimen = Geom:new{ x = x, y = y, w = diam, h = diam }
        local sqrt, floor = math.sqrt, math.floor
        local x0, y0 = x, y
        local x1b, y1b = x + diam - 1, y + diam - 1
        -- Blend `ink` (0 = black, default) over (px,py) by coverage in [0,1]
        -- (over-composite: existing pixel moves toward ink, so it works on any
        -- bg and overlapping strokes compound correctly).
        local function blend(px, py, cov, ink)
            if cov <= 0 or px < x0 or px > x1b or py < y0 or py > y1b then return end
            if cov > 1 then cov = 1 end
            ink = ink or 0
            local g = bb:getPixel(px, py):getColor8().a
            bb:setPixel(px, py, Blitbuffer.Color8(floor(g * (1 - cov) + ink * cov + 0.5)))
        end
        -- Capsule (thick segment) from (ax,ay) to (bx,by), full width wd.
        local function line(ax, ay, bx, by, wd)
            local hw = wd / 2
            local dx, dy = bx - ax, by - ay
            local len2 = dx * dx + dy * dy
            local minx = floor(math.min(ax, bx) - hw - 1)
            local maxx = floor(math.max(ax, bx) + hw + 1)
            local miny = floor(math.min(ay, by) - hw - 1)
            local maxy = floor(math.max(ay, by) + hw + 1)
            for py = miny, maxy do
                for px = minx, maxx do
                    local t = len2 > 0 and ((px - ax) * dx + (py - ay) * dy) / len2 or 0
                    if t < 0 then t = 0 elseif t > 1 then t = 1 end
                    local qx, qy = ax + t * dx, ay + t * dy
                    blend(px, py, hw + 0.5 - sqrt((px - qx) ^ 2 + (py - qy) ^ 2))
                end
            end
        end
        local cx, cy = x + r, y + r
        -- No rim ring. At larger face sizes / in a flyout it could paint out
        -- of position (a phantom ring landing over the primary panel); the
        -- clock reads cleanly as bare ticks + hands without it. `ring` is kept
        -- only as the tick inset reference below.
        for i = 0, 11 do
            local a = i * (math.pi / 6)
            local is_maj = (i % 3 == 0)
            local outer = r - ring - tick_gap
            local inner = outer - (is_maj and tick_maj or tick_min)
            local sn, co = math.sin(a), math.cos(a)
            line(cx + inner * sn, cy - inner * co,
                 cx + outer * sn, cy - outer * co,
                 is_maj and tick_w_maj or tick_w_min)
        end
        line(cx - tail_len * math.sin(hourA), cy + tail_len * math.cos(hourA),
             cx + hour_len * math.sin(hourA), cy - hour_len * math.cos(hourA), hour_w)
        line(cx - tail_len * math.sin(minA), cy + tail_len * math.cos(minA),
             cx + min_len * math.sin(minA), cy - min_len * math.cos(minA), min_w)
    end
    return Face:new{}
end

-- Module settings: face size (radio) and a show/hide toggle for the date.
local function showSettings(ctx)
    local ButtonDialog = require("ui/widget/buttondialog")
    local UIManager    = require("ui/uimanager")
    local Store        = require("lib/bookshelf_settings_store")
    local dialog
    local function commit()
        UIManager:close(dialog)
        if ctx and ctx.menu and ctx.menu._reload then ctx.menu:_reload() end
        showSettings(ctx)
    end
    local function sizeBtn(label, mode)
        return {
            text = (readSize() == mode and "\xE2\x9C\x93 " or "  ") .. label,
            callback = function()
                if readSize() == mode then return end
                Store.save(SIZE_KEY, mode)
                commit()
            end,
        }
    end
    dialog = ButtonDialog:new{
        title        = _("Analogue clock"),
        title_align  = "center",
        width_factor = 0.7,
        buttons      = {
            { sizeBtn(_("Small"),  "small") },
            { sizeBtn(_("Medium"), "medium") },
            { sizeBtn(_("Large"),  "large") },
            {
                {
                    text = (readShowDate() and "\xE2\x9C\x93 " or "  ") .. _("Show date"),
                    callback = function()
                        Store.save(DATE_KEY, not readShowDate())
                        commit()
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

return {
    key   = "analogue_clock", -- stable id stored in user menus; never change it
    title = _("Analogue clock"),
    summary = _("Device clock. Works offline."),
    -- The round face reads best as a square; the hero grid packs square-aspect
    -- modules tightly (more per row) rather than stretching them wide. (The
    -- digital clock stays flex -- its time string wants the width.)
    aspect = "square",
    -- Time-sensitive: the hero grid re-renders this cell each minute so the
    -- hands advance while the hero sits on screen (the start menu doesn't need
    -- it — it re-renders on every open). Ignored elsewhere.
    wants_minute_tick = true,
    -- `preview` (3rd arg, set by the module chooser) forces the small face
    -- size (the date line is kept): the chooser's preview cell is fixed-height,
    -- so a large square sized to the cell width would overflow it. The live
    -- menu calls render with no 3rd arg and honours the user's size setting.
    -- avail_h (4th arg, optional): the cell height a caller (the hero grid)
    -- wants filled. When given, the face grows to fill the cell (bounded by
    -- width and height, reserving the date line) instead of obeying the fixed
    -- small/medium cap — so the clock scales with its cell like the text
    -- modules do. Hand/tick weights then scale with the rendered face rather
    -- than scale_pct, keeping proportions at any size.
    render = function(ctx)
        local width, scale_pct, preview, avail_h = ctx.width, ctx.scale, ctx.preview, ctx.height
        local Blitbuffer      = require("ffi/blitbuffer")
        local Fonts           = require("lib/bookshelf_fonts")
        local TextWidget      = require("ui/widget/textwidget")
        local VerticalGroup   = require("ui/widget/verticalgroup")
        local VerticalSpan    = require("ui/widget/verticalspan")
        local CenterContainer = require("ui/widget/container/centercontainer")
        local Geom            = require("ui/geometry")
        local Screen          = require("device").screen
        local SM              = require("lib/bookshelf_start_menu_modules")
        local px  = pxUnit(scale_pct)
        local mw  = math.max(50, width)
        local now = os.time()

        -- Date label size is STABLE across shelf layouts. Tying it to scale_pct
        -- (the cell fill factor) made it balloon in a tall hero and shrink in a
        -- short one -- a jarring swing just from changing cover size, and the
        -- big size truncated the date. Use a DPI-scaled size instead, capped
        -- down only so it can't dominate a very short cell.
        local date_px = math.max(10, Screen:scaleBySize(12))
        if avail_h and avail_h > 0 then
            date_px = math.min(date_px, math.max(10, math.floor(avail_h * 0.16)))
        end
        local date_h = math.floor(date_px * 1.4 + 0.5) -- one line incl. leading

        -- small/medium are capped and centre in the natural left/right slack,
        -- with tight uniform vertical padding. "large" is inset by an equal,
        -- larger margin on every side (it would otherwise fill the width and
        -- sit tight top/bottom). Padding is uniform: top, clock-to-date, bottom.
        local size = preview and "small" or readSize()
        local pad, diam, face_scale
        if avail_h and avail_h > 0 and not preview then
            -- Height-aware (hero grid): fill the cell.
            pad = px(8)
            local date_reserve = readShowDate() and (date_h + pad) or 0
            diam = math.max(px(40),
                math.min(mw - 2 * pad, avail_h - 2 * pad - date_reserve))
            face_scale = math.max(50,
                math.floor(diam / math.max(1, Screen:scaleBySize(84)) * 100 + 0.5))
        elseif size == "large" then
            pad  = px(12)
            diam = math.max(px(40), mw - 2 * pad)
            face_scale = scale_pct
        else
            pad  = px(6)
            diam = math.min(mw, px(SIZE_UNITS[size]))
            face_scale = scale_pct
        end

        local content = VerticalGroup:new{ align = "center" }
        content[#content + 1] = VerticalSpan:new{ width = pad }
        content[#content + 1] = buildFace(diam, now, face_scale)
        if readShowDate() then
            content[#content + 1] = VerticalSpan:new{ width = pad } -- clock-to-date
            -- SHORTEN the format before shrinking the font: try full, then
            -- abbreviated, then numeric, and use the LONGEST that fits the cell
            -- width at the stable date size. os.date's %a/%b come from the same
            -- C locale as %A/%B, so this changes the date's LENGTH, not how it's
            -- localised. Font shrink is a last resort for a cell so narrow even
            -- "17/06" overflows. A small margin keeps us off the truncation edge.
            local fit_w = mw * 0.96
            local face  = Fonts:getFace("cfont", date_px, { italic = true })
            local date_txt, date_w
            for _, fmt in ipairs({ "%A %d %B", "%a %d %b", "%d %b", "%d/%m" }) do
                date_txt = os.date(fmt, now)
                date_w = TextWidget:new{ text = date_txt, face = face }:getSize().w
                if date_w <= fit_w then break end
            end
            if date_w > fit_w and date_w > 0 then
                local px2 = math.max(8, math.floor(date_px * fit_w / date_w + 0.5))
                face = Fonts:getFace("cfont", px2, { italic = true })
            end
            content[#content + 1] = TextWidget:new{
                text = date_txt, face = face,
                fgcolor = SM.COLOR_PRIMARY, max_width = mw,
            }
        end
        content[#content + 1] = VerticalSpan:new{ width = pad }

        -- render is called with the card's inner width, so a widget of exactly
        -- `mw` fills the card and centres its contents (the trailing pad in
        -- _buildModuleRow then collapses to zero).
        return CenterContainer:new{
            dimen = Geom:new{ w = mw, h = content:getSize().h },
            content,
        }
    end,
    show_settings = showSettings,
}
