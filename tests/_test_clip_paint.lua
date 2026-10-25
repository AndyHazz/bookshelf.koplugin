-- tests/_test_clip_paint.lua
-- Clipped repaints: when every dirty request for the shelf names a small
-- region, the shelf paints through lib/bookshelf_clip_bb, which cuts every
-- drawing call to those regions while the widgets run at their real
-- coordinates. A full shelf paint was 150 ms on the PW5; clipped to one book,
-- 51-72 ms.
--
-- Usage (from plugin root): lua tests/_test_clip_paint.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local t  = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq

local ClipBB = dofile("lib/bookshelf_clip_bb.lua")

local function fakeBB(w, h)
    local b = { w = w, h = h, calls = {} }
    function b:getWidth() return self.w end
    function b:getHeight() return self.h end
    function b:getType() return 1 end
    function b:blitFrom(src, x, y, ox, oy, cw, ch)
        self.calls[#self.calls + 1] = { "blit", src, x, y, ox, oy, cw, ch }
    end
    function b:paintRect(x, y, cw, ch, c)
        self.calls[#self.calls + 1] = { "rect", x, y, cw, ch, c }
    end
    function b:paintBorder(x, y, cw, ch) self.calls[#self.calls + 1] = { "border", x, y, cw, ch } end
    b.data = "ptr"
    return b
end

t.test("a blit outside the rects is dropped; one across a rect is cut to it", function()
    local screen = fakeBB(1000, 1000)
    local c = ClipBB.new(screen, { { x = 100, y = 100, w = 50, h = 50 } })
    local src = fakeBB(40, 40)
    c:blitFrom(src, 500, 500, 0, 0, 40, 40)
    eq(#screen.calls, 0, "drew outside the rect")
    c:blitFrom(src, 80, 90, 0, 0, 40, 40)          -- 80..120 x 90..130
    eq(#screen.calls, 1)
    local k = screen.calls[1]
    eq(k[3], 100); eq(k[4], 100); eq(k[5], 20); eq(k[6], 10); eq(k[7], 20); eq(k[8], 30)
end)

t.test("several rects: each gets its part", function()
    local screen = fakeBB(1000, 1000)
    local c = ClipBB.new(screen, { { x = 0, y = 0, w = 10, h = 10 }, { x = 90, y = 0, w = 10, h = 10 } })
    c:paintRect(0, 0, 100, 5, "ink")
    eq(#screen.calls, 2)
    eq(screen.calls[1][4], 10); eq(screen.calls[2][2], 90)
end)

t.test("anything else reaches the real buffer; a clipped source is unwrapped", function()
    local screen = fakeBB(1000, 1000)
    local c = ClipBB.new(screen, { { x = 0, y = 0, w = 100, h = 100 } })
    eq(c:getWidth(), 1000); eq(c.data, "ptr")
    eq(ClipBB.real(c), screen); eq(ClipBB.real(screen), screen)
    c:blitFrom(c, 10, 10, 0, 0, 5, 5)              -- a copy within the target
    assert(screen.calls[1][2] == screen, "handed the stand-in to a real blit")
    c:paintBorder(500, 500, 10, 10)
    eq(#screen.calls, 1, "a border far away was drawn")
end)

t.test("a shape crossing a rect's edge is drawn only inside it", function()
    -- Drawn whole, a chip's rounded background that touched the dirty rect
    -- of the chip beside it painted over its own text, which lay outside
    -- the rect and was skipped: a blank chip.
    local made = {}
    package.loaded["ffi/blitbuffer"] = { new = function(w, h)
        local b = fakeBB(w, h); b.free = function() end
        function b:paintRoundedRect(x, y, cw, ch) self.calls[#self.calls + 1] = { "shape", x, y, cw, ch } end
        made[#made + 1] = b
        return b
    end }
    local screen = fakeBB(1000, 1000)
    function screen:paintRoundedRect(x, y, cw, ch) self.calls[#self.calls + 1] = { "shape", x, y, cw, ch } end
    local c = ClipBB.new(screen, { { x = 0, y = 0, w = 100, h = 100 } })
    c:paintRoundedRect(10, 10, 20, 20)             -- inside: drawn as it is
    eq(screen.calls[1][1], "shape")
    c:paintRoundedRect(90, 10, 40, 20)             -- across the edge
    eq(#made, 1, "no offscreen buffer for the crossing shape")
    eq(made[1].w, 10); eq(made[1].calls[2][2], 0, "drawn at the wrong offset in the copy")
    local back = screen.calls[#screen.calls]
    eq(back[1], "blit"); eq(back[3], 90); eq(back[7], 10, "more than the inside was copied back")
    c:paintRoundedRect(500, 500, 10, 10)
    eq(#made, 1, "a shape far away was drawn")
    package.loaded["ffi/blitbuffer"] = nil
end)

t.test("overlapping rects are merged, so a blend is applied once", function()
    local screen = fakeBB(1000, 1000)
    local c = ClipBB.new(screen, { { x = 0, y = 0, w = 50, h = 50 }, { x = 40, y = 40, w = 50, h = 50 } })
    c:paintRect(0, 0, 200, 200, "ink")
    eq(#screen.calls, 1, "painted twice where the rects overlap")
    eq(screen.calls[1][4], 90)
end)

-- The shelf's side: _noteDirty, _takePaintClip and the setDirty wrap.
local src = io.open("lib/bookshelf_widget.lua"):read("*a")
local function method(name)
    local body = src:match("\n(function BookshelfWidget[:%.]" .. name .. "%(.-\nend)\n")
    assert(body, name .. " moved")
    return body
end
local function load_bw()
    local BW = { CLIP_MAX_SHARE = 0.5 }
    local UM = { calls = 0 }
    function UM:setDirty() self.calls = self.calls + 1 end
    local Screen = { bb = "SCREEN", getWidth = function() return 1000 end, getHeight = function() return 1000 end }
    local env = setmetatable({ BookshelfWidget = BW, UIManager = UM, Screen = Screen }, { __index = _G })
    for _i, n in ipairs({ "_noteDirty", "_takePaintClip", "installClipHook" }) do
        assert(load(method(n), n, "t", env))()
    end
    return BW, UM, Screen
end

t.test("small regions are painted clipped; anything else paints the whole shelf", function()
    local BW = load_bw()
    local bw = setmetatable({ _first_paint_done = true }, { __index = BW })
    bw:_noteDirty(bw, function() return "ui", { x = 0, y = 0, w = 100, h = 100 } end)
    bw:_noteDirty(bw, function() return "ui", { x = 500, y = 500, w = 50, h = 50 } end)
    local r = bw:_takePaintClip("SCREEN")
    eq(#r, 2)
    eq(bw:_takePaintClip("SCREEN"), nil, "the requests were not spent")
    for _i, req in ipairs({ "ui", function() return "ui" end, function() error("x") end,
                            function() return "ui", { x = 0, y = 0, w = 900, h = 900 } end }) do
        bw:_noteDirty(bw, function() return "ui", { x = 0, y = 0, w = 10, h = 10 } end)
        bw:_noteDirty(bw, req)
        eq(bw:_takePaintClip("SCREEN"), nil, "a whole-shelf request was clipped")
    end
    -- A mode string with the region as the third argument is a region too.
    bw:_noteDirty(bw, "ui", { x = 5, y = 5, w = 10, h = 10 })
    eq(#bw:_takePaintClip("SCREEN"), 1, "setDirty(w, \"ui\", rect) painted everything")
    bw:_noteDirty("all", function() return "ui", { x = 0, y = 0, w = 10, h = 10 } end)
    eq(bw:_takePaintClip("SCREEN"), nil, "\"all\" was clipped")
    -- Offscreen, before the first paint, and under the editor: whole.
    bw:_noteDirty(bw, function() return "ui", { x = 0, y = 0, w = 10, h = 10 } end)
    eq(bw:_takePaintClip("OFFSCREEN"), nil)
    bw._shelf_module_edit = {}
    bw:_noteDirty(bw, function() return "ui", { x = 0, y = 0, w = 10, h = 10 } end)
    eq(bw:_takePaintClip("SCREEN"), nil, "clipped under the module editor")
end)

t.test("the wrap tells the live shelf, and still asks UIManager", function()
    local BW, UM = load_bw()
    local bw = setmetatable({ _first_paint_done = true }, { __index = BW })
    BW._clip_target = bw
    BW.installClipHook(); BW.installClipHook()     -- once
    UM:setDirty(bw, function() return "ui", { x = 1, y = 1, w = 5, h = 5 } end)
    UM:setDirty({}, "ui")                          -- another window: not ours
    eq(UM.calls, 2, "the original went uncalled")
    eq(#bw:_takePaintClip("SCREEN"), 1)
end)

t.test("a clipped paint that throws is painted whole, and clipping goes off", function()
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    assert(w:find('local ok, err = pcall(InputContainer.paintTo, self,\n            require("lib/bookshelf_clip_bb").new(bb, clip_rects), x, y)', 1, true),
        "the clipped paint is not guarded")
    assert(w:find("BookshelfWidget._clip_off = true", 1, true) and w:find("if not clipped_ok then", 1, true))
    -- Every read of a paint target in the plugin hands over the real buffer.
    for _i, f in ipairs({ "lib/bookshelf_spine_shelf.lua", "lib/bookshelf_widget.lua", "lib/bookshelf_wallpaper.lua",
                          "lib/bookshelf_hero_modules.lua", "lib/bookshelf_module_grid_editor.lua", "lib/bookshelf_spine_widget.lua" }) do
        local src = io.open(f):read("*a")
        -- bb:blitFrom(bb, ...) copies within the target: the stand-in's own
        -- blit unwraps its source.
        for line in src:gmatch("[^\n]+") do
            if line:find("%wFrom%(%s*bb%s*,") and not line:find("bb:%w*From%(%s*bb%s*,") then
                error(f .. " reads the target without ClipBB.real: " .. line)
            end
        end
    end
end)

t.test("a colour shadow outside the rects is not drawn (issue 550)", function()
    -- On a colour screen the drop shadow is a ColorRGB32 and is painted with
    -- paintRoundedRectRGB32. Passed through unclipped, a repaint scoped to
    -- the hero's status line drew every shadow on the shelf while the covers
    -- above them were (rightly) clipped away: grey cards until a full paint.
    local made = {}
    package.loaded["ffi/blitbuffer"] = { new = function(w, h)
        local b = fakeBB(w, h); b.free = function() end
        function b:paintRoundedRectRGB32(x, y, cw, ch) self.calls[#self.calls + 1] = { "shape", x, y, cw, ch } end
        made[#made + 1] = b
        return b
    end }
    local screen = fakeBB(1000, 1000)
    function screen:paintRoundedRectRGB32(x, y, cw, ch) self.calls[#self.calls + 1] = { "shape", x, y, cw, ch } end
    local c = ClipBB.new(screen, { { x = 400, y = 0, w = 600, h = 300 } })
    c:paintRoundedRectRGB32(40, 600, 250, 380, "grey", 8)
    eq(#screen.calls, 0, "a shadow far from the rect was drawn")
    c:paintRoundedRectRGB32(450, 50, 100, 100, "grey", 8)
    eq(#screen.calls, 1, "a shadow inside the rect was not drawn")
    c:paintRoundedRectRGB32(350, 50, 100, 100, "grey", 8)
    eq(#made, 1, "a shadow across the edge was not drawn through a copy")
end)

t.test("the other drawing calls are clipped too", function()
    local screen = fakeBB(1000, 1000)
    for _i, name in ipairs({ "hatchRect", "multiplyRectRGB" }) do
        screen[name] = function(self, x, y, cw, ch) self.calls[#self.calls + 1] = { name, x, y, cw, ch } end
    end
    for _i, name in ipairs({ "setPixelAdd", "setPixelBlend", "setPixelColorize", "setPixelColorizeRGB32",
                             "setPixelInverted", "setPixelMultiply", "setPixelPmulBlend" }) do
        screen[name] = function(self, x, y) self.calls[#self.calls + 1] = { name, x, y } end
    end
    local c = ClipBB.new(screen, { { x = 0, y = 0, w = 100, h = 100 } })
    c:hatchRect(500, 500, 50, 50, 4, "ink")
    c:multiplyRectRGB(500, 500, 50, 50, "tint")
    c:hatchRect(50, 50, 100, 100, 4, "ink")
    eq(#screen.calls, 1, "a rect fill outside the rect was drawn")
    eq(screen.calls[1][4], 50, "not cut to the rect")
    c:setPixelBlend(500, 500, "ink"); c:setPixelMultiply(5, 5, "ink")
    eq(#screen.calls, 2, "a pixel outside the rect was set")
end)

t.test("a drawing call it does not know throws rather than draw unclipped", function()
    -- Unclipped, it lands on top of whatever the clip then cuts away. The
    -- shelf's guard paints the frame whole when the clipped paint throws.
    local screen = fakeBB(1000, 1000)
    function screen:paintCircle() self.calls[#self.calls + 1] = { "circle" } end
    function screen:invert() self.calls[#self.calls + 1] = { "invert" } end
    function screen:somethingNew() self.calls[#self.calls + 1] = { "new" } end
    local c = ClipBB.new(screen, { { x = 0, y = 0, w = 100, h = 100 } })
    for _i, name in ipairs({ "invert", "somethingNew" }) do
        local ok = pcall(function() c[name](c, 500, 500, 10) end)
        assert(not ok, name .. " did not throw")
    end
    -- A circle (cover marks, badges) is clipped like a shape instead.
    c:paintCircle(500, 500, 10, "ink")
    eq(#screen.calls, 0, "an unknown call or a far circle reached the screen")
    c:paintCircle(50, 50, 10, "ink")
    eq(#screen.calls, 1, "a circle inside the rect was not drawn")
    -- Reads still reach the real buffer.
    function screen:getRotation() return 0 end
    function screen:isRotated() return false end
    function screen:canUseCbb() return true end
    eq(c:getRotation(), 0); eq(c:isRotated(), false); eq(c:canUseCbb(), true)
end)

t.done()
