-- tests/_test_thumb_store.lua
-- List thumbnails are kept by book and size, and found before the cover
-- they are made from is.
--
-- A grouped list page (Decades on a PW5) draws ~90 small covers, each made
-- from the book's shelf-sized cover (~100 KB, for a ~5 KB thumbnail). Kept
-- 96 at most, and valid only while that exact source bitmap stayed in the
-- cover cache, they were made again on nearly every visit -- and making
-- them pulled every source cover in from disk, pushing other shelves'
-- covers out: switching to Decades after the other shelves loaded 86 covers
-- from disk, evicted 114 and remade 73 thumbnails (0.7 s of a 1.4 s switch).
-- They are now sized entries of the cover cache (getSized), dropped with
-- the book's cover or a change of Image contrast like any other.
package.path = "./?.lua;" .. package.path
package.loaded["logger"] = { dbg = function() end, warn = function() end, info = function() end }
package.loaded["lib/bookshelf_cover_disk_cache"] = { store = function() return true end, load = function() end,
    drop = function() end, clear = function() end }
package.loaded["lib/bookshelf_hero_tier"] = { drop = function() end }
local SCC = require("lib/bookshelf_scaled_cover_cache")
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq
local SW = io.open("lib/bookshelf_spine_widget.lua"):read("*a")
local body = assert(SW:match("\nlocal function _thumbFor%(fp, src, w, h%)\n(.-)\nend\n"), "_thumbFor moved")

local made, derived = 0, {}
local env = setmetatable({
    ScaledCoverCache = SCC,
    _derived = function(src, copy) derived[copy] = src; return copy end,
    require = function(n)
        if n == "ui/renderimage" then
            return { scaleBlitBuffer = function(_s, _src, w, h)
                made = made + 1
                return { stride = w, getWidth = function() return w end, getHeight = function() return h end }
            end }
        end
        return require(n)
    end,
}, { __index = _G })
local code = "local fp, src, w, h = ...\n" .. body
local thumbFor
if setfenv then thumbFor = assert(loadstring(code)); setfenv(thumbFor, env)
else thumbFor = assert(load(code, "thumb", "t", env)) end

t.test("a thumbnail is served again though its source cover was reloaded meanwhile", function()
    SCC:clear(); made = 0
    local a = thumbFor("/b/1.epub", { "first copy" }, 58, 89)
    eq(thumbFor("/b/1.epub", { "copy read back from disk" }, 58, 89), a)
    eq(made, 1, "the thumbnail was made again for the same art")
end)

t.test("a changed cover drops its thumbnails", function()
    SCC:clear(); made = 0
    thumbFor("/b/1.epub", {}, 58, 89)
    SCC:drop("/b/1.epub")
    thumbFor("/b/1.epub", {}, 58, 89)
    eq(made, 2, "the old art's thumbnail outlived the cover")
end)

t.test("a thumbnail of a boosted cover is marked as such (or the cache boosts it twice)", function()
    SCC:clear(); derived = {}
    local src = {}
    local th = thumbFor("/b/2.epub", src, 58, 89)
    eq(derived[th], src)
end)

t.test("the cover path asks for the thumbnail before the source cover", function()
    local i = assert(SW:find("    -- Cache-first. ScaledCoverCache is keyed by filepath only", 1, true))
    local block = SW:sub(i, i + 4000)
    local k = block:find("ScaledCoverCache:getSized(fp, img_w, img_h)", 1, true)
    local g = block:find("local cached = ScaledCoverCache:get(fp)", 1, true)
    assert(k and g and k < g, "every thumbnail still pulls its source cover in first")
end)

t.done()
