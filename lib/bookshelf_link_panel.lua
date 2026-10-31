-- bookshelf_link_panel.lua
-- The About panel's kind of popup: a white rounded frame of centred blocks
-- over the screen, closed by a tap outside it or Back; links that open (or,
-- with no browser, copy) a URL; and a QR code of a URL, so a reader on an
-- e-reader with no browser can open it on their phone (maintainer,
-- 2026-10-31). About, Add theme pack and Add ornaments use it.
--   LinkPanel.show{ build = function(content_w) -> { widgets }, pad_top }
--   LinkPanel.linkButton(display, url) -> a Button
--   LinkPanel.qr(text, side) -> an ImageWidget about side px square, or nil
--   LinkPanel.showShop{ title, text, shop } -> a panel that says how to add
--     something, then where to get ready-made ones: the shop's QR and link

local Blitbuffer = require("ffi/blitbuffer")
local Device     = require("device")
local UIManager  = require("ui/uimanager")
local Space      = require("lib/bookshelf_space")
local _          = require("lib/bookshelf_i18n").gettext
local Screen     = Device.screen

local M = {}

-- The quiet zone round the code, in modules: the standard's four. In night
-- mode the code keeps its own colours (a phone reads black on white), so
-- its white border is all the quiet zone it has there.
M.QUIET = 4

-- openLink(url): Device:openLink where there is a browser (desktop,
-- Android); else to KOReader's clipboard, with a note that it went there.
function M.openLink(url)
    local ok = false
    if Device.openLink then
        local _ok, ret = pcall(function() return Device:openLink(url) end)
        if _ok and ret then ok = true end
    end
    if not ok and Device.input and Device.input.setClipboardText then
        pcall(function() Device.input.setClipboardText(url) end)
        local Notification = require("ui/widget/notification")
        UIManager:show(Notification:new{ text = _("Link copied to clipboard") })
    end
end

function M.linkButton(display, url)
    local Button = require("ui/widget/button")
    return Button:new{
        text = display, bordersize = 0, padding = 0, margin = 0,
        text_font_face = "cfont", text_font_size = 14,
        callback = function() M.openLink(url) end,
    }
end

-- qr(text, side): whole pixels a module, so no module blurs into the next;
-- nil when the encoder is missing or fails (the link still shows).
function M.qr(text, side)
    local ok, qrencode = pcall(require, "ffi/qrencode")
    if not ok or not qrencode then return nil end
    local ok2, good, grid = pcall(qrencode.qrcode, text)
    if not (ok2 and good and type(grid) == "table" and #grid > 0) then return nil end
    local n = #grid + 2 * M.QUIET
    local px = math.max(1, math.floor(side / n))
    local size = px * n
    local bb = Blitbuffer.new(size, size, Blitbuffer.TYPE_BB8)
    bb:fill(Blitbuffer.COLOR_WHITE)
    for x, col in ipairs(grid) do
        for y, v in ipairs(col) do
            if v > 0 then
                bb:paintRect((x - 1 + M.QUIET) * px, (y - 1 + M.QUIET) * px, px, px, Blitbuffer.COLOR_BLACK)
            end
        end
    end
    local ImageWidget = require("ui/widget/imagewidget")
    return ImageWidget:new{ image = bb, width = size, height = size,
        original_in_nightmode = true }
end

-- M.qrSide(): the code's size, about an inch on any screen.
function M.qrSide()
    return Screen:scaleBySize(130)
end

function M.show(o)
    local Geom             = require("ui/geometry")
    local FrameContainer   = require("ui/widget/container/framecontainer")
    local CenterContainer  = require("ui/widget/container/centercontainer")
    local MovableContainer = require("ui/widget/container/movablecontainer")
    local InputContainer   = require("ui/widget/container/inputcontainer")
    local VerticalGroup    = require("ui/widget/verticalgroup")
    local GestureRange     = require("ui/gesturerange")

    local sw, sh = Screen:getWidth(), Screen:getHeight()
    -- ~80% of a phone-sized portrait, capped so it doesn't sprawl in
    -- landscape or on a tablet.
    local frame_w = math.min(math.floor(sw * 0.8), Screen:scaleBySize(420))
    local FRAME_PAD = Space.px(24)
    local content_w = frame_w - FRAME_PAD * 2
    local column = VerticalGroup:new{ align = "center" }
    for _i, w in ipairs(o.build(content_w)) do column[#column + 1] = w end
    local frame = FrameContainer:new{
        radius      = Space.radius.window,
        padding     = FRAME_PAD,
        padding_top = o.pad_top and math.floor(FRAME_PAD * o.pad_top) or FRAME_PAD,
        margin      = 0,
        background  = Blitbuffer.COLOR_WHITE,
        column,
    }
    local dialog = InputContainer:new{
        align = "center",
        dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh },
        CenterContainer:new{
            dimen = Geom:new{ w = sw, h = sh },
            MovableContainer:new{ frame },
        },
    }
    if Device:isTouchDevice() then
        dialog.ges_events = {
            TapClose = { GestureRange:new{ ges = "tap", range = Geom:new{ x = 0, y = 0, w = sw, h = sh } } },
        }
        dialog.onTapClose = function(self_d, _arg, ges_ev)
            if not frame.dimen or ges_ev.pos:notIntersectWith(frame.dimen) then
                UIManager:close(self_d)
            end
            return true
        end
    end
    if Device:hasKeys() then
        dialog.key_events = { Close = { { Device.input.group.Back } } }
        dialog.onClose = function(self_d)
            UIManager:close(self_d)
            return true
        end
    end
    -- Refreshed on show and on close, as InfoMessage is: UIManager:show
    -- with no refresh type queues none, and on e-ink nothing shows until
    -- one is (the rig shows the framebuffer, so it looked fine there; on a
    -- PW5 Add theme pack did nothing, maintainer).
    function dialog:onShow()
        UIManager:setDirty(self, function() return "ui", frame.dimen end)
        return true
    end
    function dialog:onCloseWidget()
        UIManager:setDirty(nil, function() return "ui", frame.dimen end)
    end
    UIManager:show(dialog)
    return dialog
end

M.SHOP_URL = "https://ko-fi.com/andyhazz/shop"
M.SHOP_DISPLAY = "ko-fi.com/andyhazz/shop"

-- showShop{ title, text, shop }: the title in the menus' bold, the text,
-- then shop (a line such as "Ready-made theme packs") over the shop's QR
-- code and its link.
function M.showShop(o)
    local BFont         = require("lib/bookshelf_fonts")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local VerticalSpan  = require("ui/widget/verticalspan")
    return M.show{ build = function(content_w)
        local tface, tbold = BFont:getFace("cfont", 22, { bold = true })
        local face, bold = BFont:getFace("cfont", 16)
        local function box(text, f, b, align)
            return TextBoxWidget:new{ text = text, face = f, bold = b,
                width = content_w, alignment = align or "center" }
        end
        local out = {
            box(o.title, tface, tbold),
            VerticalSpan:new{ width = Space.padding.large },
            box(o.text, face, bold, "left"),
            VerticalSpan:new{ width = Space.padding.large * 2 },
            box(o.shop, face, true),
            VerticalSpan:new{ width = Space.padding.default },
        }
        local qr = M.qr(M.SHOP_URL, math.min(content_w, M.qrSide()))
        if qr then
            out[#out + 1] = qr
            out[#out + 1] = VerticalSpan:new{ width = Space.padding.default }
        end
        out[#out + 1] = M.linkButton(M.SHOP_DISPLAY, M.SHOP_URL)
        return out
    end }
end

return M
