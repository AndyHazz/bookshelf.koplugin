-- tests/_test_author_cover_crop.lua
-- Author photos are cropped to a book cover's shape: every author card is the
-- same shape whatever the photo came in as (square, landscape, 4:5, a
-- full-length portrait), on a true-aspect shelf too.
--
-- Usage (from plugin root): lua tests/_test_author_cover_crop.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()

local src = assert(io.open("lib/bookshelf_image_source.lua")):read("*a")
local body = assert(src:match("\n(function ImageSource%.coverCrop%(.-\nend)\n"), "no coverCrop")
local IS = {}
assert(load(body, "coverCrop", "t", { ImageSource = IS, math = math }))()

t.test("the picture always covers the whole card", function()
    for _i, sz in ipairs({ { 500, 500 }, { 800, 500 }, { 400, 500 }, { 300, 900 }, { 200, 300 } }) do
        local rw, rh, x, y = IS.coverCrop(sz[1], sz[2], 200, 300)
        assert(rw >= 200 and rh >= 300, sz[1] .. "x" .. sz[2])
        assert(x >= 0 and y >= 0 and x + 200 <= rw and y + 300 <= rh, "window off the picture")
        -- Aspect kept: one side fits exactly, the other overflows.
        assert(rw == 200 or rh == 300, "scaled past both sides")
    end
end)

t.test("a square or landscape photo loses its sides, evenly", function()
    local rw, rh, x, y = IS.coverCrop(500, 500, 200, 300)
    assert(rw == 300 and rh == 300 and x == 50 and y == 0, rw .. "," .. rh .. "," .. x .. "," .. y)
end)

t.test("a tall photo keeps its top, where the face is", function()
    local rw, rh, x, y = IS.coverCrop(300, 900, 200, 300)
    assert(rw == 200 and rh == 600 and x == 0, rw .. "," .. rh)
    assert(y == 60, "a fifth of the cut off the top, not half: " .. y)
end)

t.test("a 2:3 photo is used whole", function()
    local rw, rh, x, y = IS.coverCrop(400, 600, 200, 300)
    assert(rw == 200 and rh == 300 and x == 0 and y == 0)
end)

t.test("the author card draws the crop and takes a cover's shape", function()
    local st = assert(io.open("lib/bookshelf_series_stack.lua")):read("*a")
    assert(st:find("bb = ImageSource.loadImageCover(custom_image_path,", 1, true), "not cropped")
    assert(not st:find("loadImageFramed", 1, true), "the old frame is still in use")
    assert(st:find('local _front = (custom_image_path and stack_kind == "author") and {}', 1, true),
        "a true-aspect shelf gives an author card the photo's shape")
    assert(src:find('|cover"', 1, true), "the crop shares a cache key with the stretched picture")
end)

t.done()
