-- tests/_test_editor_fade_cache.lua
-- The layout editor fades the screen around the grid. Done afresh on every
-- select or change it was 600-740 ms on a PW5 (perf log); the faded outside
-- is the same each time, so it is kept and put back.
--
-- Usage (from plugin root): lua tests/_test_editor_fade_cache.lua
package.path = "./?.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()
local src = assert(io.open("lib/bookshelf_module_grid_editor.lua")):read("*a")

local body = assert(src:match("\n(function Editor:_fadeFromCache%(bb, key, x0, y0, w, h%).-\nend)\n"))
local Editor = { FADE_CACHE_SECS = 60 }
local now = 1000
assert(load(body, "c", "t", { Editor = Editor, os = { time = function() return now end } }))()

local function fakeBB(w, h)
    local b = { w = w, h = h, blits = {} }
    function b:getWidth() return self.w end
    function b:getHeight() return self.h end
    function b:blitFrom(_src, dx, dy, sx, sy, bw, bh)
        self.blits[#self.blits + 1] = { dx, dy, sx, sy, bw, bh }
    end
    return b
end

t.test("a fresh cache puts back the four bands around the grid", function()
    local ed = setmetatable({ _fade_cache = { key = "k", bb = fakeBB(100, 200), t = now } }, { __index = Editor })
    local bb = fakeBB(100, 200)
    assert(ed:_fadeFromCache(bb, "k", 10, 20, 80, 150))
    -- Above, below, left, right: never over the kept rect.
    assert(#bb.blits == 4, #bb.blits)
    for _i, b in ipairs(bb.blits) do
        local dx, dy, bw, bh = b[1], b[2], b[5], b[6]
        local inside = dx < 90 and dx + bw > 10 and dy < 170 and dy + bh > 20
        assert(not inside, "a band covers the grid")
    end
end)

t.test("another rect, another fade direction or an old cache fades afresh", function()
    local ed = setmetatable({ _fade_cache = { key = "k", bb = fakeBB(100, 200), t = now } }, { __index = Editor })
    assert(not ed:_fadeFromCache(fakeBB(100, 200), "other", 10, 20, 80, 150))
    now = now + 61
    assert(not ed:_fadeFromCache(fakeBB(100, 200), "k", 10, 20, 80, 150), "a minute-old fade was reused")
    now = now - 61
    assert(not ed:_fadeFromCache(fakeBB(200, 100), "k", 10, 20, 80, 150), "after a rotation")
end)

t.test("the fade keeps a cache only off a cover shelf, and frees it on close", function()
    local fa = src:match("\nfunction Editor:_fadeAround%(bb%)\n(.-)\nend\n")
    assert(fa:find("if self:_fadeFromCache(bb, cache_key, x0, y0, w, h) then\n            Editor._putBack(bb, overs)\n            return\n        end", 1, true))
    assert(fa:find('info.surface ~= "shelf"', 1, true))
    -- The overhangs' places are in the key: a heading hidden since left its
    -- faded ghost in the stored fade (maintainer, PW5).
    assert(fa:find('bb:getWidth(), bb:getHeight(), table.concat(where, ";") }, ",")', 1, true), "the fade outlives a hidden heading")
    local close = src:match("\nfunction Editor:onCloseWidget%(%)\n(.-)\nend\n")
    assert(close:find("self:_dropFadeCache()", 1, true), "the screen copy outlives the editor")
end)

t.done()
