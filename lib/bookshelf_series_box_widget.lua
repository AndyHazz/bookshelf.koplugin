-- Adapted from OrbitUI's series-box implementation (AGPL-3.0).
--
-- A series on a spine shelf as one box set, standing at the front of the
-- plank like a spine. The shelf's one camera (straight on, a little above)
-- holds: all its depth is in the lid, the band above the front, as a spine's
-- page block is. The front is a board frame holding as many of the members
-- spine-out as fit in a face-out cover's width, with the first cover printed
-- across them, and a strip below with the series name. Its read/total count
-- is printed on the lid.
local InputContainer = require("ui/widget/container/inputcontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local BB = require("ffi/blitbuffer")
local Screen = require("device").screen
local TextWidget = require("lib/bookshelf_colour_text")
local BFont = require("lib/bookshelf_fonts")
local Boxes = require("lib/bookshelf_series_boxes")

-- The look. The first cover is zoomed so a crop of it spans the spines, and
-- mixed over them at ART_MIX; SPINE_TITLES puts each member's title on its
-- spine. The other look tried, kept for now (maintainer): titles off, the art
-- at 0.6, so the box reads as one printed picture with numbers on it.
local ART_ZOOM = 1.6
local ART_MIX = 0.4
local SPINE_TITLES = true
-- The read count printed on the top of the box like a watermark: the bundled
-- bold, a shade lighter than the lid, squashed to COUNT_SQUASH of its height
-- as if seen on the lid.
local COUNT_FONT = "Inter ExtraBold"
-- read/total, a hairline space either side of the slash.
local COUNT_FORMAT = "%d\xE2\x80\x8A/\xE2\x80\x8A%d"
local COUNT_SQUASH = 0.7
local COUNT_TINT = 0.4   -- how far from the lid's colour toward white: a watermark

-- The bundled file itself, through KOReader's Font as the top panel's title
-- does: BFont:getFace takes a face KEY (cfont, ...) and maps it to the UI
-- font, so a file name handed to it came out in the UI font's regular.
local function countFace(size, fallback)
    local ok, face = pcall(function()
        return require("ui/font"):getFace(BFont.bundledFaceId(COUNT_FONT), size)
    end)
    if ok and face then return face end
    return (BFont:getFace(fallback, size, { bold = true }))
end
-- The name shrinks this far below the spine-title size before it is cut.
local NAME_MIN_SIZE = 8

local Box = InputContainer:extend{}

-- memberEntry(member, w, h, SpineShelf, titles, top_edge) -> the entry a
-- member's spine slot paints from.
local function memberEntry(member, w, h, SpineShelf, titles, top_edge)
    local look = SpineShelf.bookLook(member)
    return { book = member, item = member, w = w, h = h, look = look,
             w_dp = math.floor(w / (Screen:scaleBySize(100) / 100) + .5),
             label = titles
                 and (member.display_title or member.title or member.label) or "",
             author = member.author or (member.authors and member.authors[1]) or nil,
             series_num = member.series_num and tostring(member.series_num) or nil,
             face_out = false, favourite = false, no_top_edge = not top_edge }
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
    if shape.style == "slipcase" then return self:_initSlipcase() end
    local SpineShelf = require("lib/bookshelf_spine_shelf")
    -- At the front edge of the plank, like a spine, not set back an inset
    -- like a face-out: the box holds its books spine-out.
    self.top = self.height - shape.h
    entry._drawn_h = shape.h
    local first = Boxes.copy(entry.book.first_book)
    if first.filepath and first.has_cover == nil then
        local Repo = require("lib/bookshelf_book_repository")
        local meta = Repo.buildBookMeta(first.filepath, {want_cover=false})
        for k, v in pairs(meta or {}) do if k ~= "cover_bb" then first[k] = v end end
    end
    self.first_look = SpineShelf.bookLook(first)
    self.slots = {}
    local Slot = SpineShelf._SpineBookSlot
    local run_w = 0
    for _, sp in ipairs(shape.spines) do
        local m = entry.book.books[sp.member]
        local e = memberEntry(m, sp.w, shape.inner_h, SpineShelf, SPINE_TITLES, false)
        self.slots[#self.slots + 1] = Slot:new{ book = m, entry = e, width = sp.w,
            height = shape.inner_h, show_author = false }
        run_w = run_w + sp.w
    end
    self.run_w = run_w
    if run_w > 0 then
        local aspect = (self.first_look and self.first_look.aspect) or 1.5
        local ah = math.floor(shape.inner_h * ART_ZOOM)
        local aw = math.floor(ah / aspect)
        if aw < run_w then aw = run_w; ah = math.floor(aw * aspect) end
        self.art_size = { w = aw, h = ah }
        self.art_cover = require("lib/bookshelf_spine_widget"):new{
            book = first, width = aw, height = ah, flat_thumb = true,
            show_progress = false, show_status = false, suppress_favorite_badge = true,
            suppress_number_badges = true,
        }
    end
    -- The read count, read/total, printed on the top of every box: see paintTo.
    local font = BFont.getUIFontFace() or "cfont"
    do
        local done = finishedCount(entry.book.books)
        local scale = 100
        pcall(function()
            scale = require("lib/bookshelf_settings_store").read("stack_label_font_scale", 100) or 100
        end)
        self.count = TextWidget:new{ text = string.format(COUNT_FORMAT, done, #entry.book.books),
            face = countFace(math.max(8, math.floor(14 * scale / 100 + 0.5)), font),
            padding = 0 }
    end
    self.name = fitName(entry.book.series_name or "", shape.label_size,
        math.max(1, shape.w - 2 * shape.border - 2 * shape.pad), font)
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

-- roundCorners(bb, x, y, w, h, r, top, bottom, ink) -- round off a rect's
-- corners by painting `ink` (what is behind it) over the part of each corner
-- square outside the quarter circle. Rows, not pixels: a corner is r rows.
-- cornerCut(r, dy) -> how many pixels row dy (0 at the corner's edge) of an
-- r-pixel rounded corner lies outside the quarter circle.
local function cornerCut(r, dy)
    local dist = r - dy - 0.5
    return math.floor(r - math.sqrt(math.max(0, r * r - dist * dist)) + 0.5)
end

-- roundCorner(bb, x, y, w, h, r, corner, ink) -- round one corner ("tl",
-- "tr", "bl", "br") of the rect, painting `ink` outside the quarter circle.
local function roundCorner(bb, x, y, w, h, r, corner, ink)
    for dy = 0, r - 1 do
        local cut = cornerCut(r, dy)
        if cut > 0 then
            local ry = (corner == "tl" or corner == "tr") and (y + dy) or (y + h - 1 - dy)
            local rx = (corner == "tl" or corner == "bl") and x or (x + w - cut)
            bb:paintRectRGB32(rx, ry, cut, 1, ink)
        end
    end
end

local function roundCorners(bb, x, y, w, h, r, top, bottom, ink)
    if r < 1 then return end
    for dy = 0, r - 1 do
        local dist = r - dy - 0.5
        local cut = math.floor(r - math.sqrt(math.max(0, r * r - dist * dist)) + 0.5)
        if cut > 0 then
            if top then
                bb:paintRectRGB32(x, y + dy, cut, 1, ink)
                bb:paintRectRGB32(x + w - cut, y + dy, cut, 1, ink)
            end
            if bottom then
                bb:paintRectRGB32(x, y + h - 1 - dy, cut, 1, ink)
                bb:paintRectRGB32(x + w - cut, y + h - 1 - dy, cut, 1, ink)
            end
        end
    end
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
            local e = memberEntry(m, sp.w, shape.h, SpineShelf, false, true)
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
    -- In the name's face: both are printed on the box.
    self.count = TextWidget:new{ text = string.format(COUNT_FORMAT,
        finishedCount(entry.book.books), #entry.book.books),
        face = BFont:getFace(font, shape.label_size), padding = 0 }
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
        s.slot.entry.body, s.slot.entry.marks = nil, nil
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
    -- The front: a plain board, the first cover on it as a sticker, and the
    -- series name printed on the board below.
    bb:paintRectRGB32(x, front_y, p.w, p.front_h, board)
    bb:paintRectRGB32(x, front_y, p.w, math.max(1, math.floor(B/2)), lit(1.6))
    local I = self.inset
    local sx, sy = x + I + self.st_dx, front_y + I + self.st_dy
    local SW, SH = self.st_w, self.st_h
    pcall(function()
        local c = self.art_crop
        local FH = self.st_full_h
        local tw_, th_ = SW + 2 * c, FH + 2 * c
        local tmp = BB.new(tw_, th_, bb:getType())
        tmp:paintRectRGB32(0, 0, tw_, th_, BB.ColorRGB32(255,255,255,255))
        self.art_cover:paintTo(tmp, 0, 0)
        -- Off with the tile's frame, then to the space's shape.
        local inner = BB.new(SW, FH, bb:getType())
        inner:blitFrom(tmp, 0, 0, c, c, SW, FH)
        tmp:free()
        local fit = (FH == SH) and inner or inner:scale(SW, SH)
        bb:blitFrom(fit, sx, sy, 0, 0, SW, SH)
        if fit ~= inner then fit:free() end
        inner:free()
    end)
    -- The cover is the sticker: all four corners rounded, the board around
    -- it. The name is printed on the box itself, below.
    local R = math.max(2, Screen:scaleBySize(STICKER_RADIUS_DP))
    roundCorner(bb, sx, sy, SW, SH, R, "tl", board)
    roundCorner(bb, sx, sy, SW, SH, R, "bl", board)
    roundCorner(bb, sx, sy, SW, SH, R, "br", board)
    -- The read count, printed on the box like the name, in its top-right
    -- corner; the sticker curves round it: a notch of board cut from the
    -- sticker's corner, its inner corner rounded, the sticker's corners
    -- either side of it rounded too.
    do
        local cs = self.count:getSize()
        local g = math.max(2, Screen:scaleBySize(3))
        local nw = math.min(SW - 2 * R, cs.w + 2 * g)
        local nh = math.min(SH - 2 * R, cs.h + g)
        local nx, ny = sx + SW - nw, sy
        if nw > 0 and nh > 0 then
            -- the board through the notch, its bottom-left corner rounded
            for row = 0, nh - 1 do
                local from_bottom = nh - 1 - row
                local cut = (from_bottom < R) and cornerCut(R, from_bottom) or 0
                bb:paintRectRGB32(nx + cut, ny + row, nw - cut, 1, board)
            end
            -- the sticker's corners either side of the notch
            roundCorner(bb, sx, sy, nx - sx, SH, R, "tr", board)
            roundCorner(bb, sx, ny + nh, SW, SH - nh, R, "tr", board)
        end
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
    if self.shape.style == "slipcase" then return self:_paintSlipcase(bb, x, y) end
    local p = self.shape
    local SpineShelf = require("lib/bookshelf_spine_shelf")
    local night = require("lib/bookshelf_night_mode_sync").active()
    local top = y + self.top
    local B = p.border
    local board = SpineShelf.boardColor(self.first_look or {r=60, g=60, b=60}, night)
    local function lit(f)
        local l = self.first_look or {r=60, g=60, b=60}
        local r, g, b = math.min(255, l.r*.45*f), math.min(255, l.g*.45*f), math.min(255, l.b*.45*f)
        if night then r, g, b = 255-r, 255-g, 255-b end
        return BB.ColorRGB32(math.floor(r+.5), math.floor(g+.5), math.floor(b+.5), 255)
    end
    local ch = math.max(2, Screen:scaleBySize(1))
    local front_y = top + p.lid
    -- Lid: the top face, a touch lighter than the boards (it faces the
    -- light), its two top corners chamfered like a face-out's page block.
    bb:paintRectRGB32(x, top + ch, ch, p.lid - ch, lit(1.25))
    bb:paintRectRGB32(x + ch, top, p.w - 2*ch, p.lid, lit(1.25))
    bb:paintRectRGB32(x + p.w - ch, top + ch, ch, p.lid - ch, lit(1.25))
    bb:paintRectRGB32(x, front_y - math.max(1, math.floor(B/2)), p.w, math.max(1, math.floor(B/2)), lit(1.6))
    -- Front: the frame, then the opening and the spines.
    bb:paintRectRGB32(x, front_y, p.w, p.face_h, board)
    local ix, iy = x + B, front_y + B
    bb:paintRectRGB32(ix, iy, p.w - 2*B, p.inner_h, lit(.35))
    -- Two passes with the art between them: the spines' bodies, the first
    -- cover mixed over them, then their lettering, so the art tints the
    -- spines without fading what is written on them.
    local function spines(body)
        local sx = ix
        for _, slot in ipairs(self.slots) do
            slot.entry.body, slot.entry.marks = body, not body
            slot:_renderIntoAt(bb, sx, iy, night)
            sx = sx + slot.width
        end
    end
    spines(true)
    if self.art_cover and self.run_w > 0 then
        pcall(function()
            local a = self.art_size
            local tmp = BB.new(a.w, a.h, bb:getType())
            tmp:paintRectRGB32(0, 0, a.w, a.h, BB.ColorRGB32(255,255,255,255))
            self.art_cover:paintTo(tmp, 0, 0)
            -- Upper middle of the cover: the picture, clear of the title
            -- panel most covers carry at the foot.
            local ox = math.max(0, math.floor((a.w - self.run_w) / 2))
            local oy = math.max(0, math.floor((a.h - p.inner_h) * 0.25))
            bb:addblitFrom(tmp, ix, iy, ox, oy, self.run_w, p.inner_h, ART_MIX)
            tmp:free()
        end)
    end
    spines(false)
    -- The seams between spines, solid, so the art does not run the books
    -- together: each spine's own edge pixels, painted over the art.
    local seam = math.max(1, Screen:scaleBySize(1))
    local ink_dark = night and BB.ColorRGB32(255,255,255,255) or BB.ColorRGB32(0,0,0,255)
    local sx = ix
    for _, slot in ipairs(self.slots) do
        bb:paintRectRGB32(sx, iy, seam, p.inner_h, ink_dark)
        bb:paintRectRGB32(sx + slot.width - seam, iy, seam, p.inner_h, ink_dark)
        sx = sx + slot.width
    end
    -- Name strip across the foot of the front, the name centred on it.
    local stripy = iy + p.inner_h
    bb:paintRectRGB32(x + B, stripy, p.w - 2*B, p.strip_h, lit(.7))
    local sz = self.name:getSize()
    self.name.fgcolor = night and BB.ColorRGB32(30,28,24,255) or BB.ColorRGB32(246,239,219,255)
    self.name:paintTo(bb, x + math.max(B + p.pad, math.floor((p.w - sz.w)/2)),
        stripy + math.floor((p.strip_h - sz.h)/2))
    -- The count, printed on the top of the box at its bottom-right corner: no
    -- badge behind it, the glyphs painted through their own mask a shade
    -- lighter than the lid, squashed as the lid foreshortens it.
    if self.count then
        pcall(function()
            local cs = self.count:getSize()
            local sq_h = math.max(1, math.floor(cs.h * COUNT_SQUASH + 0.5))
            local m = BB.new(cs.w, cs.h, BB.TYPE_BB8)
            m:fill(BB.COLOR_WHITE)
            self.count.fgcolor = BB.COLOR_BLACK
            self.count:paintTo(m, 0, 0)
            -- Black text on white, inverted: the coverage colorblitFrom wants
            -- (see lib/bookshelf_transparent_text.lua).
            m:invertRect(0, 0, cs.w, cs.h)
            local sq = m:scale(cs.w, sq_h)
            m:free()
            -- The lid's own colour (lit(1.25) below), lifted a little.
            local l = self.first_look or {r=60, g=60, b=60}
            local function t(c)
                local lid = math.min(255, c * .45 * 1.25)
                return math.floor(lid + (255 - lid) * COUNT_TINT + 0.5)
            end
            local r, g, b = t(l.r), t(l.g), t(l.b)
            if night then r, g, b = 255 - r, 255 - g, 255 - b end
            -- In the lid's bottom-right corner, clear of the front's edge.
            local cx = x + math.max(0, p.w - cs.w - B - p.pad)
            local cy = math.max(top + 1, front_y - sq_h - math.max(1, Screen:scaleBySize(2)))
            bb:colorblitFrom(sq, cx, cy, 0, 0, cs.w, sq_h, BB.ColorRGB32(r, g, b, 255))
            sq:free()
        end)
    end
end

return Box
