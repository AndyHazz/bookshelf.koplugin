-- Adapted from OrbitUI's series-box implementation (AGPL-3.0).
--
-- A series on a spine shelf as one box set: an open-topped slipcase a
-- face-out cover tall, the books standing in it spine-out with their heads
-- above the rim, its front a plain board with the first cover on it as a
-- sticker, the series name printed below and the read count printed in a
-- notch of the sticker. See Box:_initSlipcase and Box:_paintSlipcase.
local InputContainer = require("ui/widget/container/inputcontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local BB = require("ffi/blitbuffer")
local Screen = require("device").screen
local TextWidget = require("lib/bookshelf_colour_text")
local BFont = require("lib/bookshelf_fonts")
local Boxes = require("lib/bookshelf_series_boxes")

-- The read count: the bundled bold, at the series name's size.
local COUNT_FONT = "Inter ExtraBold"
-- read/total, a hairline space either side of the slash.
local COUNT_FORMAT = "%d\xE2\x80\x8A/\xE2\x80\x8A%d"

-- The bundled file itself, through KOReader's Font as the top panel's title
-- does: BFont:getFace takes a face KEY (cfont, ...) and maps it to the UI
-- font, so a file name handed to it came out in the UI font's regular.
-- Without the bundled file (removed, or not yet copied into the fonts dir)
-- it is the bookshelf UI font in bold. KOReader logs an error for a font it
-- cannot open, so a miss is remembered and not asked again every paint.
local _count_font_missing = false
local function countFace(size, fallback)
    if not _count_font_missing then
        local ok, face = pcall(function()
            return require("ui/font"):getFace(BFont.bundledFaceId(COUNT_FONT), size)
        end)
        if ok and face then return face end
        _count_font_missing = true
    end
    return (BFont:getFace(fallback, size, { bold = true }))
end
-- The name shrinks this far below the spine-title size before it is cut.
local NAME_MIN_SIZE = 8

local Box = InputContainer:extend{}

-- memberEntry(member, w, h, SpineShelf) -> the entry a member's spine slot
-- paints from: its own look, number and status, no title (a slipcase's
-- books show their heads, not their spines' lettering).
local function memberEntry(member, w, h, SpineShelf)
    local look = SpineShelf.bookLook(member)
    return { book = member, item = member, w = w, h = h, look = look,
             w_dp = math.floor(w / (Screen:scaleBySize(100) / 100) + .5),
             label = "",
             author = member.author or (member.authors and member.authors[1]) or nil,
             series_num = member.series_num and tostring(member.series_num) or nil,
             face_out = false, favourite = false }
end

-- fitName(name, size, room, font) -> the series name at the spine-title size,
-- smaller on a narrow box rather than cut short, cut only at NAME_MIN_SIZE.
local function fitName(name, size, room, font)
    local floor = math.min(size, NAME_MIN_SIZE)
    local tw
    while true do
        tw = TextWidget:new{ text = name, face = BFont:getFace(font, size), padding = 0 }
        if tw:getSize().w <= room or size <= floor then break end
        tw:free()
        size = size - 1
    end
    if tw:getSize().w > room then
        tw:free()
        tw = TextWidget:new{ text = name, face = BFont:getFace(font, size),
            max_width = room, padding = 0 }
    end
    return tw
end

-- finishedCount(books) -> how many of them are marked finished.
local function finishedCount(books)
    local Repo = require("lib/bookshelf_book_repository")
    local done = 0
    for _, member in ipairs(books) do
        local _, status = Repo.readProgress(member.filepath)
        if status == "finished" then done = done + 1 end
    end
    return done
end

function Box:init()
    self.dimen = Geom:new{w=self.width, h=self.height}
    self.ges_events = {
        Tap = {GestureRange:new{ges="tap", range=self.dimen}},
        Hold = {GestureRange:new{ges="hold", range=self.dimen}},
        DoubleTap = {GestureRange:new{ges="double_tap", range=self.dimen}},
    }
    local entry, shape = self.entry, self.entry.series_box
    self.book = entry.book
    self.shape = shape
    return self:_initSlipcase()
end

-- ── The face-out box set: an open-topped slipcase ──────────────────────────
-- The books stand in it spine-out, titles off, their heads above the rim so
-- each one's page top and status mark show; the front, printed with the first
-- cover, hides the rest of them. The read count is a section label on the
-- front, and says how many the series holds when it holds more than fit.
local CONTACT_SHADOW = 0.35   -- the shadow's strength at the rim

-- The ink printed on a slipcase: its name and count.
local function name_ink_for(night)
    return night and BB.ColorRGB32(30,28,24,255) or BB.ColorRGB32(246,239,219,255)
end
-- The front is a plain board with the first cover on it as a sticker, inset
-- from the front's edges and rounded, and the series name printed below.
local STICKER_INSET_DP = 4
local STICKER_RADIUS_DP = 5
local STICKER_EDGE_PX = 1      -- the sticker's light edge, a hairline

-- cornerCut(r, dy) -> how many pixels row dy (0 at the corner's edge) of an
-- r-pixel rounded corner lies outside the quarter circle.
local function cornerCut(r, dy)
    local dist = r - dy - 0.5
    return math.floor(r - math.sqrt(math.max(0, r * r - dist * dist)) + 0.5)
end

-- stickerSpan(w, h, r, nw, nh, row) -> left, right: the columns [left, right)
-- that row of a w x h sticker covers. Its four corners are rounded by r and
-- an nw x nh notch is cut from its top-right corner, the notch's inner
-- corner rounded too, and the sticker's corners either side of it.
local function stickerSpan(w, h, r, nw, nh, row)
    local left, right = 0, w
    if row < r then left = cornerCut(r, row) end
    if h - 1 - row < r then left = math.max(left, cornerCut(r, h - 1 - row)) end
    if nw > 0 and row < nh then
        right = w - nw
        if row < r then right = right - cornerCut(r, row) end
        if nh - 1 - row < r then right = right + cornerCut(r, nh - 1 - row) end
    else
        local below = row - (nw > 0 and nh or 0)
        if below < r then right = w - cornerCut(r, below) end
        if h - 1 - row < r then right = math.min(right, w - cornerCut(r, h - 1 - row)) end
    end
    return left, math.max(left, right)
end

function Box:_initSlipcase()
    local entry, shape = self.entry, self.entry.series_box
    local SpineShelf = require("lib/bookshelf_spine_shelf")
    self.top = self.height - shape.h
    entry._drawn_h = shape.h
    local first = Boxes.copy(entry.book.first_book)
    if first.filepath and first.has_cover == nil then
        local Repo = require("lib/bookshelf_book_repository")
        local meta = Repo.buildBookMeta(first.filepath, {want_cover=false})
        for k, v in pairs(meta or {}) do if k ~= "cover_bb" then first[k] = v end end
    end
    self.first_look = SpineShelf.bookLook(first)
    local Slot = SpineShelf._SpineBookSlot
    self.slots = {}
    for _, sp in ipairs(shape.spines) do
        if sp.member then
            local m = entry.book.books[sp.member]
            local e = memberEntry(m, sp.w, shape.h, SpineShelf)
            self.slots[#self.slots + 1] = { slot = Slot:new{ book = m, entry = e,
                width = sp.w, height = shape.h, show_author = false }, x = sp.x }
        end
    end
    -- The front's picture: the first cover as a sticker in the space above
    -- the name.
    local B = shape.border
    self.inset = math.max(2, Screen:scaleBySize(STICKER_INSET_DP))
    self.art_w = math.max(1, shape.w - 2 * self.inset)
    self.art_h = math.max(1, shape.front_h - 2 * self.inset - shape.strip_h)
    -- The whole cover, stretched or squashed to fill the space above the
    -- name exactly: drawn at its own proportions, then scaled to the space.
    local aspect = (self.first_look and self.first_look.aspect) or 1.5
    self.st_w, self.st_h = self.art_w, self.art_h
    self.st_full_h = math.max(1, math.floor(self.st_w * aspect + 0.5))
    self.st_dx, self.st_dy = 0, 0
    -- Drawn a little larger than the sticker and cropped inside: the cover
    -- tile carries a hairline frame, which showed as a black line down each
    -- side of the sticker.
    self.art_crop = math.max(2, Screen:scaleBySize(2))
    self.art_cover = require("lib/bookshelf_spine_widget"):new{
        book = first, width = self.st_w + 2 * self.art_crop,
        height = self.st_full_h + 2 * self.art_crop, flat_thumb = true,
        show_progress = false, show_status = false, suppress_favorite_badge = true,
        suppress_number_badges = true,
    }
    local font = BFont.getUIFontFace() or "cfont"
    -- The bundled bold, at the name's size: both are printed on the box.
    self.count = TextWidget:new{ text = string.format(COUNT_FORMAT,
        finishedCount(entry.book.books), #entry.book.books),
        face = countFace(shape.label_size, font), padding = 0 }
    local room = math.max(1, self.art_w - 2 * shape.pad)
    if shape.name_lines then
        -- Two lines, broken where the geometry chose (the box was sized to
        -- the longer one).
        self.name_lines = {}
        for i, line in ipairs(shape.name_lines) do
            self.name_lines[i] = fitName(line, shape.label_size, room, font)
        end
    else
        self.name = fitName(entry.book.series_name or "", shape.label_size, room, font)
    end
end

function Box:_paintSlipcase(bb, x, y)
    local p = self.shape
    local SpineShelf = require("lib/bookshelf_spine_shelf")
    local night = require("lib/bookshelf_night_mode_sync").active()
    local top = y + self.top
    local B = p.border
    local l = self.first_look or {r=60, g=60, b=60}
    local function lit(f)
        local r, g, b = math.min(255, l.r*.45*f), math.min(255, l.g*.45*f), math.min(255, l.b*.45*f)
        if night then r, g, b = 255-r, 255-g, 255-b end
        return BB.ColorRGB32(math.floor(r+.5), math.floor(g+.5), math.floor(b+.5), 255)
    end
    local ix = x + p.wall
    local front_y = top + p.rise
    -- The books, whole: the front goes over their lower part.
    for _, s in ipairs(self.slots) do
        s.slot:_renderIntoAt(bb, ix + s.x, top, night)
    end
    -- A contact shadow on the books just above the rim, where the front
    -- stands in front of them: darkest at the rim, gone a few pixels up.
    pcall(function()
        local W = require("lib/bookshelf_wallpaper")
        local fade = math.max(2, Screen:scaleBySize(6))
        local inner_w = p.w - 2 * p.wall
        for k = 1, fade do
            W.shadeRect(bb, ix, front_y - k, inner_w, 1,
                        CONTACT_SHADOW * (1 - (k - 1) / fade), night)
        end
    end)
    -- The side walls' tops, running back from the rim as far as the books'
    -- page tops do, then hidden behind the books: the box is shorter than
    -- what it holds. Lit like the lid, since they face up.
    local board = SpineShelf.boardColor(l, night)
    local rim = math.max(1, math.floor(B/2))
    local wall_y = math.max(top, front_y - p.wall_top)
    -- The back corners rounded off, the outer one of each wall, as the
    -- spine-out box's lid is.
    local ch = math.min(p.wall - 1, math.max(2, Screen:scaleBySize(1)))
    for i, wx in ipairs({ x, x + p.w - p.wall }) do
        local cut_x = (i == 1) and (wx + ch) or wx
        bb:paintRectRGB32(cut_x, wall_y, p.wall - ch, ch, lit(1.25))
        bb:paintRectRGB32(wx, wall_y + ch, p.wall, front_y - wall_y - ch, lit(1.25))
        bb:paintRectRGB32(cut_x, wall_y, p.wall - ch, rim, lit(1.6))
    end
    -- A seam on each wall's inside edge, as between the spines, so the books
    -- stand a little apart from the boards rather than on them.
    local seam = math.max(1, Screen:scaleBySize(1))
    local seam_ink = night and BB.ColorRGB32(255,255,255,255) or BB.ColorRGB32(0,0,0,255)
    bb:paintRectRGB32(x + p.wall - seam, wall_y, seam, front_y - wall_y, seam_ink)
    bb:paintRectRGB32(x + p.w - p.wall, wall_y, seam, front_y - wall_y, seam_ink)
    -- The front: a plain board, the first cover on it as a sticker, and the
    -- series name printed on the board below.
    bb:paintRectRGB32(x, front_y, p.w, p.front_h, board)
    bb:paintRectRGB32(x, front_y, p.w, math.max(1, math.floor(B/2)), lit(1.6))
    local I = self.inset
    local sx, sy = x + I + self.st_dx, front_y + I + self.st_dy
    local SW, SH = self.st_w, self.st_h
    -- The cover is the sticker: its corners rounded, a notch cut round the
    -- read count, and a light edge all the way round, the board outside it.
    local R = math.max(2, Screen:scaleBySize(STICKER_RADIUS_DP))
    local E = STICKER_EDGE_PX
    local cs = self.count:getSize()
    local g = math.max(2, Screen:scaleBySize(3))
    local nw = math.max(0, math.min(SW - 2 * R, cs.w + 2 * g))
    local nh = math.max(0, math.min(SH - 2 * R, cs.h + g))
    pcall(function()
        local c = self.art_crop
        local FH = self.st_full_h
        local tw_, th_ = SW + 2 * c, FH + 2 * c
        local tmp = BB.new(tw_, th_, bb:getType())
        tmp:paintRectRGB32(0, 0, tw_, th_, BB.ColorRGB32(255,255,255,255))
        self.art_cover:paintTo(tmp, 0, 0)
        -- Off with the tile's frame, then to the space inside the edge.
        local inner = BB.new(SW, FH, bb:getType())
        inner:blitFrom(tmp, 0, 0, c, c, SW, FH)
        tmp:free()
        local iw, ih = math.max(1, SW - 2 * E), math.max(1, SH - 2 * E)
        local fit = inner:scale(iw, ih)
        bb:blitFrom(fit, sx + E, sy + E, 0, 0, iw, ih)
        fit:free()
        inner:free()
    end)
    -- Row by row: board outside the sticker's outline, the edge between it
    -- and the outline drawn E inside it, the cover within that.
    -- Halfway between the box and white, as it shows: in night mode the
    -- board is stored inverted, so halfway toward 0 there.
    local edge
    pcall(function()
        local c = board.getColorRGB32 and board:getColorRGB32() or board
        local function half(v) return math.floor((night and v or (v + 255)) / 2 + 0.5) end
        edge = BB.ColorRGB32(half(c.r), half(c.g), half(c.b), 255)
    end)
    edge = edge or lit(1.6)
    local ir = math.max(1, R - E)
    for row = 0, SH - 1 do
        local l, r_ = stickerSpan(SW, SH, R, nw, nh, row)
        local yy = sy + row
        if l > 0 then bb:paintRectRGB32(sx, yy, l, 1, board) end
        if r_ < SW then bb:paintRectRGB32(sx + r_, yy, SW - r_, 1, board) end
        local irow = row - E
        if irow < 0 or irow >= SH - 2 * E then
            if r_ > l then bb:paintRectRGB32(sx + l, yy, r_ - l, 1, edge) end
        else
            local il, ir_ = stickerSpan(SW - 2 * E, SH - 2 * E, ir, nw, nh, irow)
            il, ir_ = il + E, ir_ + E
            if il > l then bb:paintRectRGB32(sx + l, yy, il - l, 1, edge) end
            if r_ > ir_ then bb:paintRectRGB32(sx + ir_, yy, r_ - ir_, 1, edge) end
        end
    end
    -- The read count, printed on the box in the notch.
    do
        local nx, ny = sx + SW - nw, sy
        self.count.fgcolor = name_ink_for(night)
        -- Never past the box's own edges, however narrow the sticker.
        local cx = nx + math.floor((nw - cs.w + g) / 2)
        cx = math.max(x, math.min(cx, x + p.w - cs.w))
        if cs.w <= p.w then
            self.count:paintTo(bb, cx, ny + math.max(0, math.floor((nh - cs.h) / 2)))
        end
    end
    local stripy = front_y + p.front_h - p.strip_h
    local name_ink = name_ink_for(night)
    local lines = self.name_lines or { self.name }
    local total = 0
    for _, ln in ipairs(lines) do total = total + ln:getSize().h end
    local ly = stripy + math.floor((p.strip_h - total) / 2)
    for _, ln in ipairs(lines) do
        local sz = ln:getSize()
        ln.fgcolor = name_ink
        ln:paintTo(bb, sx + math.max(p.pad, math.floor((self.art_w - sz.w)/2)), ly)
        ly = ly + sz.h
    end
end

function Box:onTap()
    local cb = self.callbacks and self.callbacks.on_series_tap
    if cb then cb(self.entry.book); return true end
    return false
end

function Box:onDoubleTap() return self:onTap() end

function Box:onHold()
    local cb = self.callbacks and self.callbacks.on_series_hold
    if cb then cb(self.entry.book); return true end
    return false
end

function Box:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    return self:_paintSlipcase(bb, x, y)
end

return Box
