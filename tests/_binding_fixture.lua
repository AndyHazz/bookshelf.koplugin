-- Headless display services for binding tests and the reproducible preview.
local F = { dpi = 1, night = false, settings = {}, flushes = 0, text_paints = 0 }
local W = {}
function W:extend(o) self.__index = self; return setmetatable(o or {}, self) end
function W:new(o) o = self:extend(o); if o.init then o:init() end; return o end
function W:free() end
F.Widget = W

package.loaded["lib/bookshelf_settings_store"] = {
    read = function(k, d) local v=F.settings[k]; if v==nil then return d end; return v end,
    save = function(k, v) F.settings[k] = v end,
    flush = function() F.flushes = F.flushes + 1 end,
    generation = function() return F.flushes end,
}
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
local Screen = { scaleBySize = function(_, n) return math.floor(n * F.dpi + .5) end }
package.loaded.device = { screen = Screen }
package.loaded.logger = { dbg = function() end, warn = function() end }
package.loaded["lib/bookshelf_space"] = { px = function(n) return Screen:scaleBySize(n) end }
package.loaded["lib/bookshelf_night_mode_sync"] = { active = function() return F.night end }
package.loaded["lib/bookshelf_cover_progress"] = {
    theme = function() return false end, decide = function() return {} end,
}
package.loaded["lib/bookshelf_round_corner"] = {}
for _, name in ipairs({ "ui/geometry", "ui/gesturerange", "ui/widget/widget",
        "ui/widget/container/inputcontainer" }) do package.loaded[name] = W end
local Text = W:extend{}
function Text:init()
    self.dimen = { w = math.min(self.max_width or math.huge, #self.text * self.face.size * .5),
                   h = self.face.size }
end
function Text:getSize() return self.dimen end
function Text:paintTo() F.text_paints = F.text_paints + 1 end
package.loaded["lib/bookshelf_colour_text"] = Text
package.loaded["lib/bookshelf_fonts"] = {
    getFace = function(_, _, size) return { size = size } end,
    getUIFontFace = function() return "cfont" end,
}
local BB = { COLOR_BLACK = "black", COLOR_WHITE = "white" }
function BB.ColorRGB32(r, g, b, a) return { r=r, g=g, b=b, a=a } end
function F.surface(w, h)
    local bb = { w=w, h=h, rects={}, blits={} }
    function bb:paintRectRGB32(x, y, rw, rh, c)
        assert(x>=0 and y>=0 and rw>=0 and rh>=0 and x+rw<=w and y+rh<=h,
            string.format("paint out of bounds: %g,%g %gx%g in %gx%g", x,y,rw,rh,w,h))
        self.rects[#self.rects+1] = {x=x,y=y,w=rw,h=rh,c=c}
    end
    function bb:blitFrom(src, x, y, sx, sy, rw, rh)
        self.blits[#self.blits+1] = {src=src,x=x,y=y,w=rw,h=rh}
    end
    function bb:getWidth() return w end
    function bb:getHeight() return h end
    function bb:getType() return 5 end
    function bb:rotatedCopy() local out=F.surface(h,w); out.original=self; return out end
    function bb:free() end
    return bb
end
BB.new = F.surface
package.loaded["ffi/blitbuffer"] = BB
package.loaded["lib/bookshelf_book_repository"] = {
    pageCountFor = function(_, pages) return pages end,
    readProgress = function() return 0, nil end,
}
package.preload["lib/bookshelf_ornaments"] = function() error("no ornaments in binding fixture") end
F.look = { r=90, g=115, b=145, aspect=1.5 }
function F.configure(shelf)
    shelf.bookLook = function() return F.look end
    shelf.prefetchFacts = function() end
    shelf.cachedProgress = function() return nil, nil, true end
    shelf.cachedPageCount = function() return nil end
    shelf.persistProgress = function() end
    return shelf
end
function F.upvalue(fn, name)
    for i=1,100 do
        local key, value = debug.getupvalue(fn, i)
        if not key then break end
        if key == name then return value end
    end
    error("missing upvalue " .. name)
end
function F.slot(shelf, binding, title)
    local e = { w=30*F.dpi, h=200*F.dpi, look=F.look, binding=binding,
                w_dp=30, ref_w_dp=22, label=title or "" }
    return shelf._SpineBookSlot:new{ entry=e, book={}, width=e.w, height=e.h }
end
function F.compile(code, env)
    setmetatable(env, {__index=_G})
    if setfenv then local f=assert(loadstring(code)); setfenv(f,env); return f end
    return assert(load(code,"binding fixture","t",env))
end
function F.source(path)
    local file=assert(io.open(path)); local text=file:read("*a"); file:close(); return text
end
return F
