-- tests/_test_spine_text_size.lua
-- Text size > Spine text (spine_font_scale, 50-200%, default 100): the
-- titles and authors on spine-out books. The face still caps at what an
-- average book gets and shrinks to fit across a thin spine; the setting
-- scales that size. A changed size must not be served from the cache of
-- rendered spines.
-- Run from the plugin root: lua tests/_test_spine_text_size.lua
package.path = "./?.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq
local F = dofile("tests/_binding_fixture.lua")
local Shelf = F.configure(require("lib/bookshelf_spine_shelf"))
-- A real save bumps the settings generation; these tests set values
-- directly, so they bump it too.
local function set(v) F.settings.spine_font_scale = v; F.flushes = F.flushes + 1 end

t.test("at 100% a spine's title is the size it always was", function()
    set(nil)
    -- min(the average book's cap, half the spine's width), never below 8.
    eq(Shelf.titleFaceSize(30, 22), 11)
    eq(Shelf.titleFaceSize(12, 22), 8)
    eq(Shelf.titleFaceSize(40, 40), 18)
end)

t.test("the setting scales it", function()
    set(150)
    eq(Shelf.titleFaceSize(30, 22), 17)
    set(50)
    eq(Shelf.titleFaceSize(30, 22), 6, "smaller than KOReader's 6pt floor for a face")
    set(nil)
end)

t.test("a changed size is a different render, not the cached one", function()
    set(nil)
    local slot = F.slot(Shelf, nil)
    local before = slot:_renderKey(false)
    set(130)
    assert(slot:_renderKey(false) ~= before, "the cache served spines rendered at the old size")
    set(nil)
end)

t.test("the painter takes the title size from titleFaceSize", function()
    local src = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")
    assert(src:find("local tsize = SpineShelf.titleFaceSize(w_dp, txt_ref_w_dp)", 1, true),
        "the spine painter sizes its title some other way")
end)

-- Larger spine text needs room: past 100% the spines get thicker by the
-- same factor (both plan passes see it: it is a plan option), so the bigger
-- face fits across them and a book keeps its thickness next to the others.
t.test("past 100% the spines are thicker by the same factor; below it they are not", function()
    local books={{filepath="one.epub",title="One",has_cover=false,page_count=300}}
    local function w(scale)
        local o={content_w=800,row_h=300,n_rows=2,face_out="none",text_scale=scale}
        local e=Shelf.plan(books,o).entries[1]
        return e.w, e.w_dp, e.ref_w_dp
    end
    local w100, d100, r100 = w(100)
    local w150, d150, r150 = w(150)
    local w70 = w(70)
    eq(w70, w100, "smaller text thinned the spines")
    assert(math.abs(d150 - d100 * 1.5) < 0.01, "the spine did not grow with the text: " .. d100 .. " > " .. d150)
    assert(math.abs(r150 - r100 * 1.5) < 0.01, "the average book's width did not grow with it")
    assert(w150 > w100)
end)

t.test("the title is sized from the spine before it was thickened, then scaled once", function()
    -- A 30dp spine thickened to 45 for 150% must not take the size a 45dp
    -- spine gets AND be scaled again.
    set(150)
    eq(Shelf.titleFaceSize(30, 22), 17)
    set(nil)
    local src = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")
    assert(src:find("local w_dp = (e.w_dp or 20) / thick", 1, true), "the painter sizes text from the thickened spine")
end)

-- The title (and the band of the spine's colour behind it) stays inside the
-- spine's border: a face as tall as the spine is wide covered both edges.
t.test("the title stays inside the spine's border, however large the text", function()
    set(200)
    local e = { w=14, h=300, look=F.look, w_dp=14, ref_w_dp=22, label="A long enough title" }
    local slot = Shelf._SpineBookSlot:new{ entry=e, book={}, width=e.w, height=e.h }
    local bb = F.surface(e.w, e.h)
    slot:_renderInto(bb, false)
    set(nil)
    local title
    for _, b in ipairs(bb.blits) do if b.src and b.src.original then title = b end end
    assert(title, "no title painted")
    local hair = 1
    assert(title.x >= hair and title.x + title.w <= e.w - hair,
        string.format("the title spilt over the border: %d..%d on a %d-wide spine", title.x, title.x + title.w, e.w))
end)

-- Read for every visible spine on every paint (the render cache key and the
-- painter): once per settings change, not once per spine.
t.test("the size is read from the store once per settings change", function()
    local Store = package.loaded["lib/bookshelf_settings_store"]
    local real, reads = Store.read, 0
    Store.read = function(k, d) if k == "spine_font_scale" then reads = reads + 1 end; return real(k, d) end
    set(120)
    for _ = 1, 50 do Shelf.spineTextScale() end
    eq(reads, 1, "read the store for every spine")
    set(140)
    eq(Shelf.spineTextScale(), 140, "kept the old size after a save")
    eq(reads, 2)
    Store.read = real
    set(nil)
end)

t.done()
