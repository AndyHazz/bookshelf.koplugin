-- Adapted from OrbitUI's series-box implementation (AGPL-3.0).
--
-- A series on a spine shelf as one box set, in one of two styles.
--
-- The slipcase (Series boxes: Cover or Plain): an open-topped box a face-out
-- cover tall, the books standing in it spine-out with their heads above the
-- rim, its front a plain board with the first cover on it as a sticker, the
-- series name printed below and the read count printed in a notch of the
-- sticker. See Box:_initSlipcase and Box:_paintSlipcase.
--
-- The spine-out box (Series boxes: Spines): a box standing at the front of
-- the plank like a spine, its books spine-out behind a board frame with the
-- first cover printed across them, the name on a strip below and the read
-- count on the lid. See Box:_initSpines and Box:_paintSpines.
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
-- A spine-out box's books (titled = true) keep their titles, and no page
-- top: the box's lid is their depth.
local function memberEntry(member, w, h, SpineShelf, titled)
    local look = SpineShelf.shownLook(member)
    return { book = member, item = member, w = w, h = h, look = look,
             w_dp = math.floor(w / (Screen:scaleBySize(100) / 100) + .5),
             label = titled and (member.display_title or member.title or member.label) or "",
             author = member.author or (member.authors and member.authors[1]) or nil,
             series_num = member.series_num and tostring(member.series_num) or nil,
             face_out = false, favourite = false, no_top_edge = titled or nil }
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
-- The read status from the book facts store when it holds one (checked
-- against the sidecar's mtime once a session, SpineShelf.cachedProgress),
-- else the sidecar itself. Parsing every member's sidecar on each build was
-- most of a box's cost on the first visit to a page (a 10-book series box:
-- ten dofiles) on the PW5.
local function finishedCount(books)
    local Repo = require("lib/bookshelf_book_repository")
    local SS = require("lib/bookshelf_spine_shelf")
    local done = 0
    for _, member in ipairs(books) do
        local _p, status, known = SS.cachedProgress(member.filepath)
        if not known then
            local _pct
            _pct, status = Repo.readProgress(member.filepath)
            -- Kept for next time (status only: the stored page count stays).
            if member.filepath then pcall(SS.persistProgress, member.filepath, nil, status) end
        end
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
    if shape.style == "spines" then return self:_initSpines() end
    return self:_initSlipcase()
end

-- ── The face-out box set: an open-topped slipcase ──────────────────────────
-- The books stand in it spine-out, titles off, their heads above the rim so
-- each one's page top and status mark show; the front, printed with the first
-- cover, hides the rest of them. The read count is a section label on the
-- front, and says how many the series holds when it holds more than fit.
local CONTACT_SHADOW = 0.35   -- the shadow's strength at the rim

-- The ink printed on a slipcase: its name and count.
-- Finished sticker images by what they show (see paintTo), oldest out.
local _stickers, _sticker_order, STICKERS_MAX = {}, {}, 12
-- scaled(src, w, h) -> a new w x h copy: MuPDF's scaler (C), the one the
-- covers use (RenderImage's, which falls back on its own); Blitbuffer:scale
-- is a per-pixel Lua loop.
local function scaled(src, w, h)
    if src:getWidth() == w and src:getHeight() == h then return src:copy() end
    local ok, out = pcall(function() return require("ui/renderimage"):scaleBlitBuffer(src, w, h) end)
    if ok and out then return out end
    return src:scale(w, h)
end

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
    self.first_look = SpineShelf.shownLook(first)
    local Slot = SpineShelf._SpineBookSlot
    self.slots = {}
    for _, sp in ipairs(shape.spines) do
        if sp.member then
            local m = entry.book.books[sp.member]
            local e = memberEntry(m, sp.w, shape.h, SpineShelf)
            e.binding = entry.binding
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
    if shape.plain then
        -- No picture (Series boxes: Plain): nothing to look up or build. The
        -- sticker's space stays, so the name and count print where they do
        -- on a box with a picture.
        self.custom_path = nil
        self.st_w, self.st_h, self.st_dx, self.st_dy = self.art_w, self.art_h, 0, 0
        self:_initLabels(shape)
        return
    end
    -- The series' own image, when it has one (set from its long-press menu,
    -- or found in the image library's series/ folder), in place of the first
    -- cover: the box set's front, as on its stack in covers view.
    -- A lookup that fails leaves the first cover, never a broken box.
    local ok_is, ImageSource = pcall(require, "lib/bookshelf_image_source")
    local sname = entry.book.series_name
    self.custom_path = nil
    if ok_is and ImageSource and type(sname) == "string" and sname ~= "" then
        local ok_r, path = pcall(ImageSource.resolveStackImage, "series", sname)
        if ok_r then self.custom_path = path end
    end
    local custom_aspect
    if self.custom_path then
        local tag = ImageSource.imageSizeTag and ImageSource.imageSizeTag(self.custom_path)
        local iw, ih
        if tag then iw, ih = tag:match("^(%d+)x(%d+)$") end
        iw, ih = tonumber(iw), tonumber(ih)
        if iw and ih and iw > 0 then custom_aspect = ih / iw end
    end
    -- The whole cover, stretched or squashed to fill the space above the
    -- name exactly: drawn at its own proportions, then scaled to the space.
    local aspect = custom_aspect or (self.first_look and self.first_look.aspect) or 1.5
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
    self:_initLabels(shape)
end

-- The read count and the series name, printed on the box's front.
function Box:_initLabels(shape)
    local entry = self.entry
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
    if not p.plain then pcall(function()
        local c = self.art_crop
        local FH = self.st_full_h
        local iw, ih = math.max(1, SW - 2 * E), math.max(1, SH - 2 * E)
        -- The finished sticker image, kept across rebuilds (a page turn makes
        -- new widgets): rendering the cover tile, cropping it and scaling it
        -- with Blitbuffer:scale, a per-pixel Lua loop, was ~10% of a spine
        -- page turn on the PW5 with series boxes on screen.
        local first = self.art_cover and self.art_cover.book
        -- Made from boosted covers (Image contrast), so the strength is in it.
        local boost = require("lib/bookshelf_image_contrast").boost()
        local skey = table.concat({ tostring(self.custom_path or (first and first.filepath)),
            tostring(first and first.cover_sizetag), SW, FH, iw, ih, c, boost,
            tostring(bb:getType()), night and "n" or "d" }, "|")
        local kept = _stickers[skey]
        if kept then
            bb:blitFrom(kept, sx + E, sy + E, 0, 0, iw, ih)
            return
        end
        local function keep(fit)
            _stickers[skey] = fit
            _sticker_order[#_sticker_order + 1] = skey
            if #_sticker_order > STICKERS_MAX then
                local old = table.remove(_sticker_order, 1)
                local ob = _stickers[old]
                _stickers[old] = nil
                if ob then ob:free() end
            end
        end
        -- The series' own image: no tile frame to crop. Cache-owned, so it is
        -- scaled from and never freed here.
        local custom = self.custom_path
            and require("lib/bookshelf_image_source").loadImage(self.custom_path, SW, FH)
        if custom then
            local fit = scaled(custom, iw, ih)
            -- The series' own picture is not a cover from the cache: our copy
            -- gets the boost here.
            if boost > 0 then require("lib/bookshelf_image_contrast").boostImage(fit) end
            bb:blitFrom(fit, sx + E, sy + E, 0, 0, iw, ih)
            keep(fit)
            return
        end
        local tw_, th_ = SW + 2 * c, FH + 2 * c
        local tmp = BB.new(tw_, th_, bb:getType())
        tmp:paintRectRGB32(0, 0, tw_, th_, BB.ColorRGB32(255,255,255,255))
        self.art_cover:paintTo(tmp, 0, 0)
        -- Off with the tile's frame, then to the space inside the edge.
        local inner = BB.new(SW, FH, bb:getType())
        inner:blitFrom(tmp, 0, 0, c, c, SW, FH)
        tmp:free()
        local fit = scaled(inner, iw, ih)
        bb:blitFrom(fit, sx + E, sy + E, 0, 0, iw, ih)
        keep(fit)
        inner:free()
    end) end
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
    -- A plain box has no sticker: the board alone, already painted.
    for row = 0, p.plain and -1 or SH - 1 do
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

-- ── The spine-out box (Series boxes: Spines) ───────────────────────────────
-- The first cover is enlarged so a crop of its upper middle spans the spines,
-- then made quieter before it goes on them: its contrast squeezed toward its
-- own middle grey (ART_DARKEN can darken it too; off, as darkening muddied
-- the picture on the PW5's greys), so the spines' light lettering stays
-- clear over it. Quietened that way it can be printed strongly (ART_MIX)
-- and still read as a picture, where fading a full contrast cover enough
-- for the titles left little of it.
local ART_ZOOM = 1.6
local ART_MIX = 0.75
local ART_CONTRAST = -0.5   -- wallpaperLUT's c: -1 is one flat grey
local ART_DARKEN = 0       -- wallpaperLUT's b: toward black
-- The read count printed on the lid like a watermark: the bundled bold, a
-- shade lighter than the lid, squashed as the lid foreshortens it.
local COUNT_SQUASH = 0.7
local COUNT_TINT = 0.4       -- from the lid's colour toward white

function Box:_initSpines()
    local entry, shape = self.entry, self.entry.series_box
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
    self.first_look = SpineShelf.shownLook(first)
    self.slots = {}
    local Slot = SpineShelf._SpineBookSlot
    local run_w = 0
    for _, sp in ipairs(shape.spines) do
        local m = entry.book.books[sp.member]
        local e = memberEntry(m, sp.w, shape.inner_h, SpineShelf, true)
        e.binding = entry.binding
        self.slots[#self.slots + 1] = Slot:new{ book = m, entry = e, width = sp.w,
            height = shape.inner_h, show_author = false }
        run_w = run_w + sp.w
    end
    self.run_w = run_w
    -- The series' own image when it has one, as on the slipcase's front.
    local ok_is, ImageSource = pcall(require, "lib/bookshelf_image_source")
    local sname = entry.book.series_name
    if ok_is and ImageSource and type(sname) == "string" and sname ~= "" then
        local ok_r, path = pcall(ImageSource.resolveStackImage, "series", sname)
        if ok_r then self.custom_path = path end
    end
    -- Only a real cover goes across the spines: one not extracted yet, or a
    -- book with none, would spread its placeholder (title and author in big
    -- faint letters) behind theirs. The box repaints when the cover lands.
    if run_w > 0 and (self.custom_path or first.has_cover == true) then
        local aspect = (self.first_look and self.first_look.aspect) or 1.5
        if self.custom_path and ImageSource.imageSizeTag then
            local iw, ih = (ImageSource.imageSizeTag(self.custom_path) or ""):match("^(%d+)x(%d+)$")
            iw, ih = tonumber(iw), tonumber(ih)
            if iw and ih and iw > 0 then aspect = ih / iw end
        end
        local ah = math.floor(shape.inner_h * ART_ZOOM)
        local aw = math.floor(ah / aspect)
        if aw < run_w then aw = run_w; ah = math.floor(aw * aspect) end
        self.art_size = { w = aw, h = ah }
        self.art_book = first
        self.art_cover = require("lib/bookshelf_spine_widget"):new{
            book = first, width = aw, height = ah, flat_thumb = true,
            show_progress = false, show_status = false, suppress_favorite_badge = true,
            suppress_number_badges = true,
        }
    end
    local font = BFont.getUIFontFace() or "cfont"
    local scale = 100
    pcall(function()
        scale = require("lib/bookshelf_settings_store").read("stack_label_font_scale", 100) or 100
    end)
    self.count = TextWidget:new{ text = string.format(COUNT_FORMAT,
        finishedCount(entry.book.books), #entry.book.books),
        face = countFace(math.max(8, math.floor(14 * scale / 100 + 0.5)), font), padding = 0 }
    self.name = fitName(entry.book.series_name or "", shape.label_size,
        math.max(1, shape.w - 2 * shape.border - 2 * shape.pad), font)
end

-- _spinesArt(bb, night) -> the quietened crop of the cover, run_w x inner_h,
-- kept across rebuilds with the slipcase stickers; nil when there is none.
function Box:_spinesArt(bb, night)
    local p, a = self.shape, self.art_size
    if not (self.art_cover and a and self.run_w > 0) then return nil end
    local first = self.art_book
    local boost = require("lib/bookshelf_image_contrast").boost()
    local key = table.concat({ "spines", tostring(self.custom_path or (first and first.filepath)),
        tostring(first and first.cover_sizetag), a.w, a.h, self.run_w, p.inner_h, boost,
        ART_CONTRAST, ART_DARKEN, tostring(bb:getType()), night and "n" or "d" }, "|")
    local kept = _stickers[key]
    if kept then return kept end
    local tmp = BB.new(a.w, a.h, bb:getType())
    tmp:paintRectRGB32(0, 0, a.w, a.h, BB.ColorRGB32(255,255,255,255))
    local custom = self.custom_path
        and require("lib/bookshelf_image_source").loadImage(self.custom_path, a.w, a.h)
    if custom then
        local fit = scaled(custom, a.w, a.h)
        tmp:blitFrom(fit, 0, 0, 0, 0, a.w, a.h)
        fit:free()
    else
        self.art_cover:paintTo(tmp, 0, 0)
    end
    -- The upper middle of the cover: the picture, clear of the title panel
    -- most covers carry at the foot.
    local ox = math.max(0, math.floor((a.w - self.run_w) / 2))
    local oy = math.max(0, math.floor((a.h - p.inner_h) * 0.25))
    local crop = BB.new(self.run_w, p.inner_h, bb:getType())
    crop:blitFrom(tmp, 0, 0, ox, oy, self.run_w, p.inner_h)
    tmp:free()
    -- Quieter: squeezed toward its own middle grey, then darkened (lightened
    -- in night mode, where what is stored is inverted). A buffer the
    -- contrast code cannot read is left as it is.
    pcall(function()
        local C = require("lib/bookshelf_image_contrast")
        local _lo, med = C.levels(crop)
        if med then
            C.applyLUT(crop, C.wallpaperLUT(med, night and -ART_DARKEN or ART_DARKEN, ART_CONTRAST))
        end
    end)
    _stickers[key] = crop
    _sticker_order[#_sticker_order + 1] = key
    if #_sticker_order > STICKERS_MAX then
        local old = table.remove(_sticker_order, 1)
        local ob = _stickers[old]
        _stickers[old] = nil
        if ob then ob:free() end
    end
    return crop
end

function Box:_paintSpines(bb, x, y)
    local p = self.shape
    local SpineShelf = require("lib/bookshelf_spine_shelf")
    local night = require("lib/bookshelf_night_mode_sync").active()
    local top = y + self.top
    local B = p.border
    local l = self.first_look or {r=60, g=60, b=60}
    local board = SpineShelf.boardColor(l, night)
    local function lit(f)
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
    bb:paintRectRGB32(x, front_y - math.max(1, math.floor(B/2)), p.w,
                      math.max(1, math.floor(B/2)), lit(1.6))
    -- Front: the frame, then the opening and the spines.
    bb:paintRectRGB32(x, front_y, p.w, p.face_h, board)
    local ix, iy = x + B, front_y + B
    bb:paintRectRGB32(ix, iy, p.w - 2*B, p.inner_h, lit(.35))
    -- Two passes with the cover between them: the spines' bodies, the cover
    -- over them, then their lettering on top.
    local function spines(body)
        local sx = ix
        for _, slot in ipairs(self.slots) do
            slot.entry.body, slot.entry.marks = body, not body
            slot:_renderIntoAt(bb, sx, iy, night)
            sx = sx + slot.width
        end
    end
    local art
    pcall(function() art = self:_spinesArt(bb, night) end)
    -- Each spine takes its colour from the strip of the cover it stands
    -- behind, so its body and the band behind its title match the picture
    -- instead of patching it with its own book's colour. Once per box (the
    -- picture is fixed for its life).
    if art and not self._looks_from_art then
        self._looks_from_art = true
        local sx = 0
        for _, slot in ipairs(self.slots) do
            local ok, look = pcall(SpineShelf.lookFromRegion, art, sx, 0, slot.width, p.inner_h, night)
            if ok and type(look) == "table" then
                local own = slot.entry.look
                local mine = {}
                for k, v in pairs(look) do mine[k] = v end
                mine.aspect = own and own.aspect
                slot.entry.look = mine
            end
            sx = sx + slot.width
        end
    end
    spines(true)
    if art then
        pcall(function() bb:addblitFrom(art, ix, iy, 0, 0, self.run_w, p.inner_h, ART_MIX) end)
    end
    spines(false)
    -- The seams between spines, solid, so the cover does not run the books
    -- together: one at each book's left edge and one after the last, so two
    -- books meet at a single seam, as an end book meets the case (each
    -- spine drawing both its edges made the gaps between books double).
    local seam = math.max(1, Screen:scaleBySize(1))
    local ink_dark = night and BB.ColorRGB32(255,255,255,255) or BB.ColorRGB32(0,0,0,255)
    local sx = ix
    for _, slot in ipairs(self.slots) do
        bb:paintRectRGB32(sx, iy, seam, p.inner_h, ink_dark)
        sx = sx + slot.width
    end
    if #self.slots > 0 then bb:paintRectRGB32(sx - seam, iy, seam, p.inner_h, ink_dark) end
    -- Name strip across the foot of the front, the name centred on it.
    local stripy = iy + p.inner_h
    bb:paintRectRGB32(x + B, stripy, p.w - 2*B, p.strip_h, lit(.7))
    local sz = self.name:getSize()
    self.name.fgcolor = name_ink_for(night)
    self.name:paintTo(bb, x + math.max(B + p.pad, math.floor((p.w - sz.w)/2)),
        stripy + math.floor((p.strip_h - sz.h)/2))
    -- The count, printed on the lid at its bottom-right corner: no badge
    -- behind it, the glyphs painted through their own mask a shade lighter
    -- than the lid, squashed as the lid foreshortens it.
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
        local function t(c)
            local lid = math.min(255, c * .45 * 1.25)
            return math.floor(lid + (255 - lid) * COUNT_TINT + 0.5)
        end
        local r, g, b = t(l.r), t(l.g), t(l.b)
        if night then r, g, b = 255 - r, 255 - g, 255 - b end
        local cx = x + math.max(0, p.w - cs.w - B - p.pad)
        local cy = math.max(top + 1, front_y - sq_h - math.max(1, Screen:scaleBySize(2)))
        bb:colorblitFrom(sq, cx, cy, 0, 0, cs.w, sq_h, BB.ColorRGB32(r, g, b, 255))
        sq:free()
    end)
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
    if self.shape.style == "spines" then return self:_paintSpines(bb, x, y) end
    return self:_paintSlipcase(bb, x, y)
end

return Box
