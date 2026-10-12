-- Adapted from OrbitUI's series-box implementation (AGPL-3.0).
local InputContainer = require("ui/widget/container/inputcontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local BB = require("ffi/blitbuffer")
local Screen = require("device").screen
local TextWidget = require("lib/bookshelf_colour_text")
local BFont = require("lib/bookshelf_fonts")
local CountBadge = require("lib/bookshelf_count_badge")
local Boxes = require("lib/bookshelf_series_boxes")

local Box = InputContainer:extend{}

function Box:init()
    self.dimen = Geom:new{w=self.width, h=self.height}
    self.ges_events = {
        Tap = {GestureRange:new{ges="tap", range=self.dimen}},
        Hold = {GestureRange:new{ges="hold", range=self.dimen}},
        DoubleTap = {GestureRange:new{ges="double_tap", range=self.dimen}},
    }
    local entry, shape = self.entry, self.entry.series_box
    self.book = entry.book
    local book = Boxes.copy(entry.book.first_book)
    if book.filepath and book.has_cover == nil then
        local Repo = require("lib/bookshelf_book_repository")
        local meta = Repo.buildBookMeta(book.filepath, {want_cover=false})
        for k, v in pairs(meta or {}) do if k ~= "cover_bb" then book[k] = v end end
    end
    self.shape = shape
    self.stroke = math.max(1, math.min(Screen:scaleBySize(1), math.floor(shape.cover_w/8)))
    self.look = entry.look or {r=90, g=100, b=95}
    self.spines = Boxes.spineSlots(shape, self.stroke)
    for _, spine in ipairs(self.spines) do
        local member = entry.book.books[spine.member]
        -- The planner already sampled the first cover. Other visible bindings
        -- share Bookshelf's persistent look cache; no sampling during paint.
        spine.look = spine.member == 1 and self.look
            or (member and self.book_look and self.book_look(member)) or self.look
    end
    self.top = self.height - (self.inset or 0) - shape.h
    entry._drawn_h = shape.h
    self[1] = require("lib/bookshelf_spine_widget"):new{
        book=book, width=math.max(1, shape.cover_w-2*self.stroke),
        height=math.max(1, shape.face_h-2*self.stroke), flat_thumb=true,
        show_progress=false, show_status=false, suppress_favorite_badge=true,
        suppress_number_badges=true,
    }
    local font_size = math.floor(math.max(7, math.min(11, shape.cover_w / Screen:scaleBySize(100) * 9))+.5)
    local face = BFont:getFace("smallinfofont", font_size)
    self.label_w = math.max(1, shape.cover_w - 4*self.stroke)
    self[2] = TextWidget:new{text=entry.book.series_name, face=face,
        max_width=math.max(1, self.label_w-2*self.stroke), padding=0}
    self.label_h = self[2]:getSize().h + 2*self.stroke
    self.show_title = self.label_h < shape.face_h*.45

    -- Match native group badges: use canonical, cached status, not stale group
    -- summaries or percent read. Only visible boxes pay this member sweep.
    local Repo = require("lib/bookshelf_book_repository")
    local finished = 0
    for _, member in ipairs(entry.book.books) do
        local _, status = Repo.readProgress(member.filepath)
        if status == "finished" then finished = finished + 1 end
    end
    self[3] = CountBadge.render(#entry.book.books, nil, finished)
    self.badge_size = self[3] and self[3]:getSize()
    self.show_badge = self.badge_size and self.badge_size.w <= self.label_w
        and self.badge_size.h <= shape.face_h-4*self.stroke
    if self.show_badge then
        self.show_title = self.show_title
            and self.label_h+self.badge_size.h+5*self.stroke < shape.face_h
    end
    self.all_read = #entry.book.books > 0 and finished == #entry.book.books
    if self.all_read then
        self[4], self.mark_size, self.fade_amount =
            require("lib/bookshelf_spine_widget").finishedDecoration(self.label_w)
        if self[4] then
            local bottom = shape.face_h-2*self.stroke
            if self.show_title then bottom = bottom-self.label_h-self.stroke end
            self.mark_y = bottom-self.mark_size.h
            local clear_top = self.show_badge and self.badge_size.h+3*self.stroke or 2*self.stroke
            self.show_mark = self.mark_size.w <= self.label_w and self.mark_y >= clear_top
        end
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
    local p, look = self.shape, self.look
    local top, stroke = y+self.top, self.stroke
    -- paintRect's C fast path reduces RGB inks to grey. The RGB entry point
    -- preserves cover hues on colour devices and converts on grey devices.
    local fill = bb.paintRectRGB32
    local night = require("lib/bookshelf_night_mode_sync").active()
    local function colour(r, g, b)
        r, g, b = math.min(255, math.max(0, r)), math.min(255, math.max(0, g)), math.min(255, math.max(0, b))
        r, g, b = math.floor(r+.5), math.floor(g+.5), math.floor(b+.5)
        if night then r, g, b = 255-r, 255-g, 255-b end
        return BB.ColorRGB32(r, g, b, 255)
    end
    local r, g, b = look.r, look.g, look.b
    -- Native spine samples already cap luminance for light spine lettering.
    -- Do not darken them a second time into an almost-black sleeve.
    local board = colour(r*1.15+8, g*1.15+8, b*1.15+8)
    local cavity = colour(r*.23, g*.23, b*.23)
    local upper = colour(r*1.3+22, g*1.3+22, b*1.3+22)
    local rim = colour(r*1.35+35, g*1.35+35, b*1.35+35)
    local foot = colour(r*.75, g*.75, b*.75)
    -- Both planes recede by the same (side, -depth) vector. Leave the
    -- triangles above the front-left and below the rear-right untouched.
    for dy = 0, p.depth-1 do
        local dx = math.ceil(p.side*(p.depth-dy)/p.depth)
        fill(bb, x+dx, top+dy, p.cover_w, 1, dy<stroke and rim or upper)
    end
    -- Every binding, rim and highlight follows the same receding plane.
    -- Coalesce equal-rise columns, so cost is bounded by depth and six spines.
    local function sideStrip(first, last, inset, height, ink)
        if height <= 0 then return end
        local dx = first
        while dx < last do
            local rise = math.floor((dx+1)*p.depth/p.side)
            local next_dx = p.depth>0
                and math.min(last, math.ceil((rise+1)*p.side/p.depth)-1) or last
            fill(bb, x+p.cover_w+dx, top+p.depth-rise+inset, next_dx-dx, height, ink)
            dx = next_dx
        end
    end
    sideStrip(0, p.side, 0, p.face_h, cavity)
    for _, spine in ipairs(self.spines) do
        local c = spine.look
        local bands = math.min(5, spine.w)
        for band = 1, bands do
            local first = math.floor((band-1)*spine.w/bands)
            local last = math.floor(band*spine.w/bands)
            local across = (band-.5)/bands
            local roundness = math.sin(across*math.pi)
            local shoulder = math.floor((1-roundness)*2*stroke+.5)
            local inset = 2*stroke+shoulder
            local height = p.face_h-2*inset
            local light = .68+.30*roundness + (across<.5 and .08 or 0)
            local ink = colour(c.r*light+12, c.g*light+12, c.b*light+12)
            sideStrip(spine.x+first, spine.x+last, inset, height, ink)
            -- Small head/tail glints make the rounded bindings sit inside,
            -- not on top of, the darker opening. No invented spine artwork.
            if height > 6*stroke then
                sideStrip(spine.x+first, spine.x+last, inset, stroke,
                    colour(c.r*.65+62, c.g*.65+62, c.b*.65+62))
                sideStrip(spine.x+first, spine.x+last, inset+height-stroke, stroke,
                    colour(c.r*.5, c.g*.5, c.b*.5))
            end
        end
    end
    local edge = math.min(stroke, p.face_h)
    sideStrip(0, p.side, 0, edge, rim)
    sideStrip(0, p.side, p.face_h-edge, edge, foot)
    sideStrip(math.max(0, p.side-stroke), p.side, 0, p.face_h, board)
    fill(bb, x, top+p.depth, p.cover_w, p.face_h, board)
    self[1]:paintTo(bb, x+stroke, top+p.depth+stroke)
    if self.fade_amount then
        -- Fade only the painted silhouette, before the labels/mark. A single
        -- bounding rectangle would also wash out the wallpaper at the corners.
        bb:lightenRect(x, top+p.depth, p.cover_w, p.face_h, self.fade_amount)
        for dy = 0, p.depth-1 do
            local offset = math.ceil(p.side*(p.depth-dy)/p.depth)
            bb:lightenRect(x+offset, top+dy, p.cover_w, 1, self.fade_amount)
        end
        local column = 0
        while column < p.side do
            local top_rise = math.floor(column*p.depth/p.side)
            local rise = math.floor((column+1)*p.depth/p.side)
            local next_column = p.depth>0
                and math.min(p.side, math.ceil((top_rise+1)*p.side/p.depth),
                    math.ceil((rise+1)*p.side/p.depth)-1) or p.side
            -- Start just below the top plane's last pixel in these columns;
            -- rounded projections can share more than one boundary pixel.
            local remaining_h = p.face_h-rise+top_rise
            if remaining_h > 0 then
                bb:lightenRect(x+p.cover_w+column, top+p.depth-top_rise, next_column-column,
                    remaining_h, self.fade_amount)
            end
            column = next_column
        end
    end
    -- A narrow printed band belongs to the sleeve, not a pale catalogue label.
    if self.show_title then
        local lx = x+2*stroke
        local ly = top+p.h-self.label_h-2*stroke
        local label_colour = colour(r*.65, g*.65, b*.65)
        fill(bb, lx, ly, self.label_w, self.label_h, label_colour)
        local size = self[2]:getSize()
        self[2].fgcolor = night and colour(217, 211, 196) or colour(246, 239, 219)
        self[2]:paintTo(bb, lx+math.floor((self.label_w-size.w)/2), ly+stroke)
    end
    if self.show_badge then
        self[3]:paintTo(bb, x+p.cover_w-2*stroke-self.badge_size.w, top+p.depth+2*stroke)
    end
    if self.show_mark then
        self[4]:paintTo(bb, x+2*stroke, top+p.depth+self.mark_y)
    end
end

return Box
