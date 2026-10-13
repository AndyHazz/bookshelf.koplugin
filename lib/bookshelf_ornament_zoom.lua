--[[
An ornament full screen: the "zoom" tap action (an ornaments.json record's
"tap": "zoom", which a pack can set for all its pieces). The piece is drawn as
large as the screen allows, with a panel under it holding its name and, when
the record has one, its "info" text in a scrolling area -- a print's title,
artist and notes in the Ukiyo-e pack.

Built the way the full-screen micro-module view is (bookshelf_micro_fullscreen):
the shelf's wallpaper as the ground (white without one), and the panel painted
as the shelf paints its own panels (Wallpaper.panel in the palette's panel
colour at the reader's panel strength, blurred behind when that option is on), with the palette's ink for the text.
Colours are paint-space, so night mode needs nothing of its own. Back, or a tap
anywhere outside the text, closes it; a tap or swipe on the text scrolls it.
]]
local Blitbuffer       = require("ffi/blitbuffer")
local Device           = require("device")
local FrameContainer   = require("ui/widget/container/framecontainer")
local Geom             = require("ui/geometry")
local InputContainer   = require("ui/widget/container/inputcontainer")
local OverlapGroup     = require("ui/widget/overlapgroup")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local TextBoxWidget    = require("ui/widget/textboxwidget")
local UIManager        = require("ui/uimanager")
local Widget           = require("ui/widget/widget")
local Screen           = Device.screen

local M = {}

-- titleOf(entry) -> the piece's name as the browser shows it: the file name,
-- without its pack folder or extension.
function M.titleOf(entry)
    local n = entry and entry.name or ""
    return (n:match("([^/]+)$") or n):gsub("%.%w+$", "")
end

-- infoText(entry) -> the record's info, or nil (the panel then shows the
-- name alone).
function M.infoText(entry)
    local t = entry and entry.info
    if type(t) == "string" and t ~= "" then return t end
    return nil
end

-- fit(aspect, w, h) -> the largest w x h of that aspect inside the box.
function M.fit(aspect, w, h)
    aspect = (aspect and aspect > 0) and aspect or 1
    local fw, fh = w, math.floor(w / aspect)
    if fh > h then fh, fw = h, math.floor(h * aspect) end
    return math.max(1, fw), math.max(1, fh)
end

-- panelBox(sw, margin, pad, title_w, has_info) -> x, w of the panel. With
-- info it spans the screen inside the margins; a piece with only its name
-- gets a panel just wide enough for it, centred under the piece (maintainer).
function M.panelBox(sw, margin, pad, title_w, has_info)
    local full = sw - 2 * margin
    if has_info then return margin, full end
    local w = math.min(full, title_w + 2 * pad)
    return math.floor((sw - w) / 2), w
end

-- cropFit(aspect, box, w, h) -> W, H, crop: the file's size so that its
-- DRAWING (box = contentBox's l, t, r, b fractions, or nil for the whole
-- file) is the largest it can be inside w x h, and the crop that is that
-- drawing. A pack's pieces carry transparent padding (their share of the
-- tallest piece, a side margin) that would otherwise shrink them here.
-- margin: that much of the file (a fraction) is kept around the drawing.
function M.cropFit(aspect, box, w, h, margin)
    aspect = (aspect and aspect > 0) and aspect or 1
    local l, t, r, b = 0, 0, 1, 1
    if box and box[1] then l, t, r, b = box[1], box[2], box[3], box[4] end
    -- margin: a little of the file around the drawing, so what fades out
    -- past its edge (a frame's soft shadow) is not cut off square
    local m = margin or 0
    l, t, r, b = math.max(0, l - m), math.max(0, t - m), math.min(1, r + m), math.min(1, b + m)
    local fw, fh = math.max(0.05, r - l), math.max(0.05, b - t)
    local dw, dh = M.fit(aspect * fw / fh, w, h)
    local W, H = math.max(1, math.floor(dw / fw + 0.5)), math.max(1, math.floor(dh / fh + 0.5))
    local crop = { x = math.floor(l * W + 0.5), y = math.floor(t * H + 0.5), w = dw, h = dh }
    crop.w = math.min(crop.w, W - crop.x)
    crop.h = math.min(crop.h, H - crop.y)
    return W, H, crop
end

-- A scrolling text area that composites over the panel instead of painting
-- an opaque box on it: ScrollTextWidget always builds a plain TextBoxWidget,
-- so over a painted ground that is swapped for a TransparentTextBox of the
-- same size (the hero's text does the same, bookshelf_transparent_text).
local ZoomText = ScrollTextWidget:extend{ transparent = false }
function ZoomText:init()
    ScrollTextWidget.init(self)
    if not self.transparent then return end
    local ok, TTB = pcall(require, "lib/bookshelf_transparent_text")
    if not ok then return end
    local old = self.text_widget
    local tw = TTB:new{
        text = self.text, face = self.face, fgcolor = self.fgcolor,
        width = old.width, height = old.height, dialog = self.dialog,
        alignment = self.alignment, justified = self.justified, lang = self.lang,
    }
    self.text_widget = tw
    self[1][1] = tw
    old:free()
end

local Zoom = InputContainer:extend{ name = "bookshelf_ornament_zoom" }

function M.show(entry, bw)
    local z = Zoom:new{ entry = entry, bw = bw }
    -- An explicit refresh, as every full-screen view here: a nil one is
    -- dropped and nothing reaches the panel (see MicroFullscreen.open).
    UIManager:show(z, "ui", z.dimen)
    return z
end

function Zoom:init()
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    self:_build()
end

function Zoom:_build()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self._built_w, self._built_h = sw, sh
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    local Orn = require("lib/bookshelf_ornaments")
    local Space = require("lib/bookshelf_space")
    local CP = require("lib/bookshelf_cover_progress")
    local bw = self.bw
    local margin = math.floor(math.min(sw, sh) * 0.04)
    local pad = Space.padding and Space.padding.large or Screen:scaleBySize(12)
    local ink = (CP.ink and CP.ink()) or Blitbuffer.COLOR_BLACK
    local painted = bw and bw.groundIsPainted and bw:groundIsPainted() or false
    local strength = (bw and bw.wallpaperScrimStrength and bw:wallpaperScrimStrength()) or 0

    -- The panel: the name, then the info in a scrolling area no taller than
    -- a third of the screen (the piece gets the rest). In the bookshelf UI
    -- font, as the rest of the shelf's text.
    local BFont = require("lib/bookshelf_fonts")
    local tface, tbold = BFont:getFace("infofont", 22, { bold = true })
    local info = M.infoText(self.entry)
    local name = M.titleOf(self.entry)
    local natural = 0
    pcall(function()
        local probe = require("lib/bookshelf_colour_text"):new{ text = name, face = tface, bold = tbold }
        natural = probe:getSize().w
        probe:free()
    end)
    local px, pw = M.panelBox(sw, margin, pad, natural, info ~= nil)
    local tw = pw - 2 * pad
    local TitleBox = TextBoxWidget
    if painted then
        local ok, TTB = pcall(require, "lib/bookshelf_transparent_text")
        if ok then TitleBox = TTB end
    end
    local title = TitleBox:new{
        text = name, face = tface, bold = tbold, width = tw, fgcolor = ink,
        alignment = info and "left" or "center",
    }
    local body
    local gap = math.floor(pad * 0.75)
    if info then
        local face = BFont:getFace("infofont", 18)
        -- Only as tall as the text needs, up to the cap.
        local probe = TextBoxWidget:new{ text = info, face = face, width = tw - Screen:scaleBySize(12),
                                         for_measurement_only = true }
        local want = probe:getSize().h
        probe:free()
        local cap = math.floor(sh / 3)
        body = ZoomText:new{
            text = info, face = face, fgcolor = ink, width = tw,
            height = math.max(Screen:scaleBySize(40), math.min(want, cap)),
            dialog = self, transparent = painted,
        }
    end
    local th = title:getSize().h
    local ph = pad + th + (body and (gap + body:getSize().h) or 0) + pad
    local py = sh - margin - ph

    -- The piece, as large as the space above the panel allows.
    local aw, ah = sw - 2 * margin, py - 2 * margin
    local box
    if self.entry.path and Orn.contentBox then
        local ok, l, t, r, b = pcall(Orn.contentBox, self.entry)
        if ok and l then box = { l, t, r, b } end
    end
    local w, h, crop = M.cropFit(self.entry.aspect, box, aw, ah, 0.03)
    local ix, iy = math.floor((sw - crop.w) / 2), margin + math.floor((ah - crop.h) / 2)
    local night = false
    pcall(function() night = require("lib/bookshelf_night_mode_sync").active() end)
    local entry = self.entry
    local picture = Widget:new{ dimen = Geom:new{ w = sw, h = sh } }
    function picture:paintTo(b)
        pcall(Orn.paintPlacement, b, ix, iy, { entry = entry, w = w, h = h, mirror = false, crop = crop }, night)
    end

    -- The ground: the shelf's wallpaper, or the page.
    local bg, on_wall = nil, false
    if bw and bw._wallpaperWidget then
        local ok, wp = pcall(function() return bw:_wallpaperWidget() end)
        if ok and wp then bg, on_wall = wp, true end
    end
    if not bg then
        bg = FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE, bordersize = 0, padding = 0, margin = 0,
            dimen = Geom:new{ w = sw, h = sh },
            Widget:new{ dimen = Geom:new{ w = sw, h = sh } },
        }
    end
    local panel = Widget:new{ dimen = Geom:new{ w = sw, h = sh } }
    if painted and strength > 0 then
        local colors = CP.resolvedColors and CP.resolvedColors() or {}
        local ground = colors.panel_bg or Blitbuffer.COLOR_WHITE
        local radius = Space.radius and Space.radius.window or 7
        function panel:paintTo(b)
            pcall(function()
                -- Wallpaper.panel, as the shelf's own panels: the picture behind
                -- it blurred when "Blur wallpaper behind panels" is on (and
                -- dithered on greyscale e-ink), then the tint; plain scrim
                -- otherwise (maintainer: the zoom's description panel should
                -- follow the blur preference too).
                require("lib/bookshelf_wallpaper").panel(b, px, py, pw, ph, ground, strength, radius, on_wall)
            end)
        end
    end
    local texts = Widget:new{ dimen = Geom:new{ w = sw, h = sh } }
    local tx, ty = px + pad, py + pad
    function texts:paintTo(b)
        title:paintTo(b, tx, ty)
        if body then body:paintTo(b, tx, ty + th + gap) end
    end
    self._title, self._body = title, body
    self[1] = OverlapGroup:new{ dimen = self.dimen:copy(), allow_mirroring = false,
                                bg, panel, picture, texts }
    -- No whole-screen tap range: a tap is read in handleEvent, after
    -- KOReader's own zones have had it (a range would take corner taps too).
end

-- The text scrolls under a tap or a swipe on it; KOReader's own gestures
-- (edge swipes for brightness, the top swipe for its menu, the diagonal
-- refresh, corner taps) pass through to it; any other tap closes.
local Passthrough = require("lib/bookshelf_gesture_passthrough")
function Zoom:handleEvent(event)
    if event.handler == "onGesture" then
        if Device.screen_saver_lock then return false end
        local ev = event.args and event.args[1]
        local body = self._body
        if body and ev and ev.pos and body.dimen and body.dimen.x and ev.pos:intersectWith(body.dimen) then
            if body:handleEvent(event) then return true end
        end
        if InputContainer.handleEvent(self, event) then return true end
        if Passthrough.gesture(ev) then return true end
        if ev and ev.ges == "tap" then return self:onTapClose() end
        return false
    end
    if InputContainer.handleEvent(self, event) then return true end
    return Passthrough.event(event)
end

function Zoom:paintTo(bb, x, y)
    if Screen:getWidth() ~= self._built_w or Screen:getHeight() ~= self._built_h then
        self:_build()
    end
    InputContainer.paintTo(self, bb, x, y)
end

function Zoom:onTapClose()
    UIManager:close(self)
    if self.bw then UIManager:setDirty(self.bw, "ui") end
    return true
end
Zoom.onClose = Zoom.onTapClose

function Zoom:onCloseWidget()
    if self._title then self._title:free() end
    if self._body and self._body.text_widget then self._body.text_widget:free() end
end

return M
