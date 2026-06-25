-- Headless tests for lib/bookshelf_kobo_source.lua — the defensive bridge to
-- OGKevin/kobo.koplugin's virtual library. Tests inject a fake virtual_library
-- via M._virtualLibrary, so no kobo plugin / Kobo hardware is needed.
package.path = "./?.lua;./?/init.lua;" .. package.path

local M = dofile("lib/bookshelf_kobo_source.lua")
local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()

-- A fake virtual_library with the methods we feature-detect.
local function fakeVL(opts)
    opts = opts or {}
    local vl = {}
    if opts.active ~= nil or opts.with_isActive ~= false then
        vl.isActive = function() return opts.active ~= false end
    end
    if opts.with_getBookEntries ~= false then
        vl.getBookEntries = function() return opts.entries or {} end
    end
    if opts.with_getMetadataForPath ~= false then
        vl.getMetadataForPath = function(_self, _path, _cover)
            return opts.meta_for_path
        end
    end
    if opts.with_isVirtualPath then
        vl.isVirtualPath = function(_self, p) return p == opts.virtual_path end
    end
    if opts.thumbnail_path then
        vl.getThumbnailPath = function(_self, _p) return opts.thumbnail_path end
    end
    if opts.with_getBookId ~= false then
        vl.getBookId = function(_self, p) return p:match("KOBO_VIRTUAL://([^/]+)/") end
    end
    if opts.decrypt_path ~= nil or opts.with_decrypt then
        vl.decryptIfNeeded = function(_self, _id) return opts.decrypt_path end
    end
    if opts.real_path ~= nil or opts.with_getRealPath then
        vl.getRealPath = function(_self, _p) return opts.real_path end
    end
    return vl
end
local function inject(vl) M._virtualLibrary = function() return vl end end

t.test("isAvailable: false when plugin absent", function()
    inject(nil)
    assert(M.isAvailable() == false)
end)

t.test("isAvailable: requires getBookEntries only (cover method optional)", function()
    -- Older kobo.koplugin builds expose getBookEntries but not getMetadataForPath.
    -- The shelf must still appear (covers degrade), so this must be true (#203).
    inject(fakeVL({ with_getMetadataForPath = false }))
    assert(M.isAvailable() == true, "available without getMetadataForPath (covers degrade)")
    -- No getBookEntries means nothing to list -> unavailable.
    inject(fakeVL({ with_getBookEntries = false }))
    assert(M.isAvailable() == false, "should be false without getBookEntries")
end)

t.test("isAvailable: false when inactive, true when active + complete", function()
    inject(fakeVL({ active = false }))
    assert(M.isAvailable() == false, "inactive should be false")
    inject(fakeVL({ active = true }))
    assert(M.isAvailable() == true, "active + complete should be true")
end)

t.test("toRecord: maps fields + derives status from percent", function()
    local rec = M._toRecord({
        path = "KOBO_VIRTUAL://abc/Iain Banks - Use of Weapons.epub",
        attr = { mode = "file", size = 1234, modification = 99 },
        kobo_book_id = "abc",
        kobo_metadata = {
            title = "Use of Weapons", author = "Iain Banks",
            series = "Culture", series_number = 3, percent_read = 50,
        },
    })
    assert(rec.filepath == "KOBO_VIRTUAL://abc/Iain Banks - Use of Weapons.epub")
    assert(rec.title == "Use of Weapons")
    assert(rec.author == "Iain Banks", "primary author")
    assert(type(rec.authors) == "table" and rec.authors[1] == "Iain Banks", "authors list")
    assert(rec.series_name == "Culture" and rec.series_num == "3", "series mapped")
    assert(math.abs(rec.book_pct - 0.5) < 1e-9, "percent -> 0..1")
    assert(rec.status == "reading", "50% -> reading")
    assert(rec.added_time == 99 and rec.last_read_time == 99, "mtime")
    assert(rec.kobo_book_id == "abc" and rec.is_kobo == true)
    assert(rec.rating == nil, "no Kobo rating")
end)

t.test("toRecord: status edges + empty series/author dropped", function()
    local unread = M._toRecord({ path = "x", kobo_metadata = { percent_read = 0 } })
    assert(unread.status == "unread")
    local done = M._toRecord({ path = "x", kobo_metadata = { percent_read = 100 } })
    assert(done.status == "finished")
    local bare = M._toRecord({ path = "x", kobo_metadata = { title = "T", author = "", series = "" } })
    assert(bare.author == nil, "empty author dropped")
    assert(bare.series_name == nil and bare.series_num == nil, "empty series dropped")
end)

t.test("listBooks: maps entries, skips malformed, {} when unavailable", function()
    inject(fakeVL({ entries = {
        { path = "KOBO_VIRTUAL://1/A.epub", kobo_metadata = { title = "A", percent_read = 0 } },
        { kobo_metadata = { title = "no path -> skipped" } },  -- no path
        { path = "KOBO_VIRTUAL://2/B.epub", kobo_metadata = { title = "B", percent_read = 100 } },
    } }))
    local list = M.listBooks()
    assert(#list == 2, "skipped the path-less entry, got " .. #list)
    assert(list[1].title == "A" and list[2].title == "B")
    inject(nil)
    assert(#M.listBooks() == 0, "no plugin -> empty list")
end)

t.test("coverBB: returns the cover bb + dims (no :copy method -> original)", function()
    local fake_bb = { _fake = true }   -- no copy() method
    inject(fakeVL({ meta_for_path = { cover_bb = fake_bb, cover_w = 100, cover_h = 150 } }))
    local bb, w, h = M.coverBB("KOBO_VIRTUAL://1/A.epub")
    assert(bb == fake_bb and w == 100 and h == 150, "cover bb + dims returned")
    inject(fakeVL({ meta_for_path = {} }))  -- no cover
    assert(M.coverBB("x") == nil, "nil when no cover")
end)

t.test("coverBB: returns a COPY of the plugin's cached bb, not the original (#203)", function()
    -- The plugin caches and returns the same bb each call; coverBB must copy it
    -- so the shelf freeing it after paint doesn't blank the plugin's cache.
    local copy_marker = { _copy = true, getWidth = function() return 100 end,
                          getHeight = function() return 150 end }
    local cached = { _cached = true, copy = function() return copy_marker end }
    inject(fakeVL({ meta_for_path = { cover_bb = cached, cover_w = 100, cover_h = 150 } }))
    local bb = M.coverBB("KOBO_VIRTUAL://1/A.epub")
    assert(bb == copy_marker, "should return the copy, not the cached original")
    assert(bb ~= cached, "must not hand back the plugin's cached bb")
end)

t.test("coverBB: falls back to getThumbnailPath + render on older builds", function()
    local rendered = { _rendered = true,
        getWidth = function() return 80 end, getHeight = function() return 120 end }
    package.loaded["ui/renderimage"] = {
        renderImageFile = function(_self, p) return p == "/cache/thumb.png" and rendered or nil end,
    }
    -- Older build: no getMetadataForPath, only getThumbnailPath.
    inject(fakeVL({ with_getMetadataForPath = false, thumbnail_path = "/cache/thumb.png" }))
    local bb, w, h = M.coverBB("KOBO_VIRTUAL://1/A.epub")
    assert(bb == rendered and w == 80 and h == 120, "rendered thumbnail bb + dims returned")
    -- No cover method at all -> nil.
    inject(fakeVL({ with_getMetadataForPath = false }))
    assert(M.coverBB("x") == nil, "nil when neither cover method present")
    package.loaded["ui/renderimage"] = nil
end)

t.test("realPathForOpen: decryptIfNeeded resolves the openable path (#203)", function()
    inject(fakeVL({ decrypt_path = "/mnt/onboard/.cache/dec/abc.epub" }))
    assert(M.realPathForOpen("KOBO_VIRTUAL://abc/Author - Title.epub")
        == "/mnt/onboard/.cache/dec/abc.epub", "should return the decrypted path")
end)

t.test("realPathForOpen: nil when decrypt declines (DRM off / failed)", function()
    inject(fakeVL({ with_decrypt = true, decrypt_path = nil }))
    assert(M.realPathForOpen("KOBO_VIRTUAL://abc/A.epub") == nil,
        "nil when the plugin can't produce a real file")
end)

t.test("realPathForOpen: falls back to getRealPath without decryptIfNeeded", function()
    inject(fakeVL({ with_decrypt = false, real_path = "/mnt/onboard/books/abc.kepub.epub" }))
    assert(M.realPathForOpen("KOBO_VIRTUAL://abc/A.epub")
        == "/mnt/onboard/books/abc.kepub.epub", "plain resolve when no decryptIfNeeded")
end)

t.test("isKoboPath: uses isVirtualPath when present", function()
    inject(fakeVL({ with_isVirtualPath = true, virtual_path = "KOBO_VIRTUAL://1/A.epub" }))
    assert(M.isKoboPath("KOBO_VIRTUAL://1/A.epub") == true)
    assert(M.isKoboPath("/mnt/onboard/real.epub") == false)
end)

t.done()
