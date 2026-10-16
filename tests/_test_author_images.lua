-- tests/_test_author_images.lua
-- Author photos from Open Library / Wikipedia into the image library
-- (lib/bookshelf_author_images). The two services are stubbed at
-- Http.getJSON and CoverFetch.download; the picking rules are the ones
-- measured live on 28 authors (see the module header).
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t, eq = helpers.runner(), helpers.eq

local DIR = os.tmpname()
os.remove(DIR)
assert(os.execute("mkdir -p '" .. DIR .. "'"))

package.loaded["logger"] = { dbg = function() end, info = function() end, warn = function() end }
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(p, key)
        local f = io.open(p, "rb")
        if not f then
            if os.execute("test -d '" .. p .. "'") == true or os.execute("test -d '" .. p .. "'") == 0 then
                return key == "mode" and "directory" or { mode = "directory" }
            end
            return nil
        end
        local size = f:seek("end"); f:close()
        if key == "size" then return size end
        if key == "mode" then return "file" end
        return { mode = "file", size = size }
    end,
}
package.loaded["lib/bookshelf_fs"] = { ensureDir = function() return true end }

-- Services. json[url-prefix] answers getJSON; files[url] is what a download
-- writes (nil = the download fails, as a 404 would).
local json, files, requests = {}, {}, {}
package.loaded["lib/bookshelf_http"] = {
    getJSON = function(url, opts)
        requests[#requests + 1] = url
        assert(opts and opts.user_agent and opts.user_agent:find("github.com/AndyHazz", 1, true),
               "requests name the plugin")
        for prefix, body in pairs(json) do
            if url:sub(1, #prefix) == prefix then return body end
        end
        return nil
    end,
}
package.loaded["lib/bookshelf_cover_fetch"] = {
    download = function(url, dest, _u, _p, opts)
        requests[#requests + 1] = url
        assert(opts and opts.user_agent, "downloads name the plugin")
        local body = files[url]
        if not body then return nil, "download failed (404)" end
        local f = assert(io.open(dest, "wb")); f:write(body); f:close()
        return dest
    end,
}
local resolved = {}
package.loaded["lib/bookshelf_image_source"] = {
    getImageLibraryPath = function() return "/lib/.bookshelf-images" end,
    resolveStackImage = function(kind, name) return kind == "author" and resolved[name] or nil end,
}

local AI = dofile("lib/bookshelf_author_images.lua")

local JPEG = "\xFF\xD8\xFF\xE0" .. string.rep("j", 4000)
local PNG  = "\x89PNG\r\n\x1A\n" .. string.rep("p", 4000)
local HTML = "<!DOCTYPE html>" .. string.rep("h", 4000)
local OL   = "https://openlibrary.org/search/authors.json"
local WP   = "https://en.wikipedia.org/w/api.php"
local function olPhoto(id) return "https://covers.openlibrary.org/a/olid/" .. id .. "-L.jpg?default=false" end
local stubGetJSON = package.loaded["lib/bookshelf_http"].getJSON
local function reset()
    -- Some tests swap in their own getJSON; every test starts from the stub.
    package.loaded["lib/bookshelf_http"].getJSON = stubGetJSON
    json, files, requests, resolved = {}, {}, {}, {}
    os.execute("rm -f '" .. DIR .. "'/* '" .. DIR .. "'/.[!.]* 2>/dev/null")
end
local function exists(p) local f = io.open(p, "rb"); if f then f:close() end; return f ~= nil end
local function wpPage(p) return { query = { pages = { p } } } end

t.test("names compare without case, punctuation, spacing or diacritics", function()
    eq(AI.matchKey("Stanisław Lem"), AI.matchKey("Stanislaw Lem"))
    eq(AI.matchKey("H. P. Lovecraft"), AI.matchKey("H.P. Lovecraft"))
    eq(AI.matchKey("ÉMILE ZOLA"), AI.matchKey("emile zola"))
    eq(AI.matchKey("Ursula K. Le Guin"), "ursulakleguin")
    assert(AI.matchKey("Richard Osman") ~= AI.matchKey("Richard W. Osman"))
end)

t.test("Last, First is searched as First Last; anything odder is left alone", function()
    eq(AI.queryName("Osman, Richard"), "Richard Osman")
    eq(AI.queryName("  Le Guin, Ursula K. "), "Ursula K. Le Guin")
    eq(AI.queryName("Terry Pratchett"), "Terry Pratchett")
    eq(AI.queryName("Smith, Jr., John"), "Smith, Jr., John")
end)

t.test("placeholder names are not people", function()
    for _i, n in ipairs({ "Anonymous", "Various", "unknown", "Unknown Author", "N/A", "", "  " }) do
        eq(AI.isPlaceholder(n), true, n)
    end
    eq(AI.isPlaceholder("Saki"), false)
    eq(AI.isPlaceholder("Homer"), false)
end)

t.test("Open Library: the matching author with the most works", function()
    local docs = {
        { key = "OL9233779A", name = "Becky Chambers BS.MEd.", work_count = 5 },
        { key = "OL16276782A", name = "Becky Chambers", work_count = 1 },
        { key = "OL7387940A", name = "Becky Chambers", work_count = 25 },
    }
    eq(AI.pickOpenLibrary(docs, "Becky Chambers").key, "OL7387940A")
    eq(AI.pickOpenLibrary(docs, "Chambers, Becky").key, "OL7387940A")
    eq(AI.pickOpenLibrary({ { key = "OL1A", name = "Becky Chambers", work_count = 0 } },
        "Becky Chambers"), nil, "an author with no works is a stray record")
    eq(AI.pickOpenLibrary({ { key = "OL2A", name = "Richard W. Osman", work_count = 9 } },
        "Richard Osman"), nil, "a different name is a different person")
    eq(AI.pickOpenLibrary({ { key = "OL3A", name = "Hector Munro", alternate_names = { "Saki" },
        work_count = 300 } }, "Saki").key, "OL3A", "alternate names count")
    eq(AI.pickOpenLibrary(nil, "Saki"), nil)
end)

t.test("Wikipedia: only a page that exists, is not a disambiguation, and describes a writer", function()
    local thumb = { source = "https://upload.example/x.jpg" }
    eq(AI.pickWikipedia(wpPage{ title = "Saki", description = "British writer (1870-1916)", thumbnail = thumb }),
       "https://upload.example/x.jpg")
    eq(AI.pickWikipedia(wpPage{ title = "John Smith", description = "English footballer", thumbnail = thumb }), nil)
    eq(AI.pickWikipedia(wpPage{ title = "John Smith", description = "Topics referred to by the same term",
        pageprops = { disambiguation = "" }, thumbnail = thumb }), nil)
    eq(AI.pickWikipedia(wpPage{ title = "Nobody", missing = true }), nil)
    eq(AI.pickWikipedia(wpPage{ title = "Emily Tesh", description = "British science fiction and fantasy author" }),
       nil, "no image")
    eq(AI.isWriterDescription("American poet and novelist"), true)
    eq(AI.isWriterDescription("Polish science fiction author and futurologist (1921-2006)"), true)
    eq(AI.isWriterDescription("American actor"), false)
    eq(AI.isWriterDescription("Authority figure"), false, "whole words only")
end)

t.test("saved under the name as shown, or its slug when that cannot be a file name", function()
    eq(AI.fileStem("Osman, Richard"), "Osman, Richard")
    eq(AI.fileStem("Stanisław Lem"), "Stanisław Lem")
    eq(AI.fileStem("AC/DC"), "ac-dc")
    eq(AI.fileStem("What? Who: Me"), "what-who-me")
    eq(AI.fileStem("..."), nil)
    eq(AI.fileStem(nil), nil)
end)

t.test("Open Library's photo when it has one", function()
    reset()
    json[OL] = { docs = { { key = "/authors/OL25712A", name = "Terry Pratchett", work_count = 232 } } }
    files[olPhoto("OL25712A")] = JPEG
    local path, source = AI.fetch("Terry Pratchett", { dir = DIR })
    eq(path, DIR .. "/Terry Pratchett.jpg"); eq(source, "openlibrary")
    assert(exists(path))
    for _i, u in ipairs(requests) do assert(not u:find(WP, 1, true), "Wikipedia not asked") end
end)

t.test("Wikipedia when Open Library knows the author but has no photo", function()
    reset()
    json[OL] = { docs = { { key = "OL591204A", name = "Saki", work_count = 354 } } }
    json[WP] = wpPage{ title = "Saki", description = "British writer (1870-1916)",
                       thumbnail = { source = "https://thumb.example/saki.png" } }
    files["https://thumb.example/saki.png"] = PNG   -- Open Library's photo 404s
    local path, source = AI.fetch("Saki", { dir = DIR })
    eq(path, DIR .. "/Saki.png"); eq(source, "wikipedia")
end)

t.test("the format is what arrived, not what the url said; a web page is not kept", function()
    reset()
    json[OL] = { docs = { { key = "OL1A", name = "Mick Herron", work_count = 55 } } }
    files[olPhoto("OL1A")] = PNG
    eq(AI.fetch("Mick Herron", { dir = DIR }), DIR .. "/Mick Herron.png")
    reset()
    json[OL] = { docs = { { key = "OL1A", name = "Mick Herron", work_count = 55 } } }
    files[olPhoto("OL1A")] = HTML
    local path, why = AI.fetch("Mick Herron", { dir = DIR })
    eq(path, nil); eq(why, "none")
    eq(exists(DIR .. "/.Mick Herron.download"), false, "the partial download is removed")
end)

t.test("a new photo replaces the old one in any format", function()
    reset()
    local old = assert(io.open(DIR .. "/Ann Leckie.png", "wb")); old:write(PNG); old:close()
    json[OL] = { docs = { { key = "OL5A", name = "Ann Leckie", work_count = 26 } } }
    files[olPhoto("OL5A")] = JPEG
    eq(AI.fetch("Ann Leckie", { dir = DIR }), DIR .. "/Ann Leckie.jpg")
    eq(exists(DIR .. "/Ann Leckie.png"), false)
end)

t.test("a failed lookup keeps the image already there", function()
    reset()
    local old = assert(io.open(DIR .. "/Emily Tesh.jpg", "wb")); old:write(JPEG); old:close()
    json[OL] = { docs = {} }
    json[WP] = wpPage{ title = "Emily Tesh", description = "British science fiction and fantasy author" }
    local path, why = AI.fetch("Emily Tesh", { dir = DIR })
    eq(path, nil); eq(why, "none")
    assert(exists(DIR .. "/Emily Tesh.jpg"))
end)

t.test("a writer's page without a photo stops the suffixed titles", function()
    reset()
    json[OL] = { docs = {} }
    json[WP] = wpPage{ title = "Emily Tesh", description = "British science fiction and fantasy author" }
    AI.fetch("Emily Tesh", { dir = DIR })
    local wp = 0
    for _i, u in ipairs(requests) do if u:find(WP, 1, true) then wp = wp + 1 end end
    eq(wp, 1)
end)

t.test("someone else's page leads on to '(writer)'", function()
    reset()
    json[OL] = { docs = {} }
    local calls = 0
    package.loaded["lib/bookshelf_http"].getJSON = function(url)
        requests[#requests + 1] = url
        if url:find(OL, 1, true) then return { docs = {} } end
        calls = calls + 1
        if url:find("%%28writer%%29") then
            return wpPage{ title = "John Smith (writer)", description = "English writer",
                           thumbnail = { source = "https://thumb.example/js.jpg" } }
        end
        return wpPage{ title = "John Smith", description = "English footballer",
                       thumbnail = { source = "https://thumb.example/fb.jpg" } }
    end
    files["https://thumb.example/js.jpg"] = JPEG
    local path, source = AI.fetch("John Smith", { dir = DIR })
    eq(path, DIR .. "/John Smith.jpg"); eq(source, "wikipedia"); eq(calls, 2)
end)

t.test("no answer from either source is 'unreachable', not 'none'", function()
    reset()
    package.loaded["lib/bookshelf_http"].getJSON = function() return nil end
    local path, why = AI.fetch("Naomi Novik", { dir = DIR })
    eq(path, nil); eq(why, "unreachable")
end)

t.test("placeholders are never looked up", function()
    reset()
    local path, why = AI.fetch("Anonymous", { dir = DIR })
    eq(path, nil); eq(why, "placeholder"); eq(#requests, 0)
end)

t.test("missing(): only real authors with no image yet", function()
    reset()
    resolved["Terry Pratchett"] = "/lib/.bookshelf-images/authors/Terry Pratchett.jpg"
    local todo = AI.missing({ "Terry Pratchett", "Anonymous", "Saki", "Various", "Naomi Novik" })
    eq(#todo, 2); eq(todo[1], "Saki"); eq(todo[2], "Naomi Novik")
end)

-- _compact: a stand-in decoder/encoder. A decoded "bb" remembers its size;
-- writeToFile writes a JPEG of jpeg_bytes, or fails when jpeg_fail is set.
local decoded, scaled_to, jpeg_bytes, jpeg_fail
local function fakeBB(w, h, typ)
    local bb = { w = w, h = h, typ = typ or 5 }
    function bb:getWidth() return self.w end
    function bb:getHeight() return self.h end
    function bb:getType() return self.typ end
    function bb:free() end
    function bb:fill() end
    -- As KOReader's C blitter: no alpha blit INTO RGB24. The real one aborts
    -- the process (it killed KOReader on the PW5); this one fails the test.
    function bb:pmulalphablitFrom()
        assert(self.typ ~= 5, "alpha blit into an RGB24 buffer: KOReader's C blitter aborts on it")
        self.composited = true
    end
    function bb:blitFrom() end
    function bb:writeToFile(path)
        if jpeg_fail then return false end
        local f = io.open(path, "wb"); f:write("\xFF\xD8\xFF\xE0" .. string.rep("c", jpeg_bytes - 4)); f:close()
        return true
    end
    return bb
end
local function withCodec(w, h)
    decoded, scaled_to, jpeg_bytes, jpeg_fail = { w = w, h = h }, nil, 30000, false
    package.loaded["ui/renderimage"] = {
        renderImageFile = function() return fakeBB(decoded.w, decoded.h, 6) end,
        scaleBlitBuffer = function(_s, _bb, nw, nh) scaled_to = { nw, nh }; return fakeBB(nw, nh, 6) end,
    }
    package.loaded["ffi/blitbuffer"] = {
        TYPE_BBRGB32 = 6, TYPE_BBRGB24 = 5, COLOR_WHITE = 255,
        new = function(w2, h2, typ) return fakeBB(w2, h2, typ) end,
    }
    package.loaded["device"] = { screen = { getWidth = function() return 1236 end,
                                            getHeight = function() return 1648 end } }
end
local function size(p) local f = io.open(p, "rb"); local n = f:seek("end"); f:close(); return n end

t.test("a PNG is saved as a smaller JPEG", function()
    reset(); withCodec(500, 667)
    json[OL] = { docs = { { key = "OL1A", name = "Mick Herron", work_count = 55 } } }
    files[olPhoto("OL1A")] = "\x89PNG\r\n\x1A\n" .. string.rep("p", 445000)
    eq(AI.fetch("Mick Herron", { dir = DIR }), DIR .. "/Mick Herron.jpg")
    eq(size(DIR .. "/Mick Herron.jpg"), 30000)
    eq(scaled_to, nil, "500 px is under the cap, so not resized")
    eq(exists(DIR .. "/.Mick Herron.download.jpg"), false)
end)

t.test("a small JPEG is kept exactly as it came", function()
    reset(); withCodec(500, 500)
    json[OL] = { docs = { { key = "OL2A", name = "Ann Leckie", work_count = 26 } } }
    files[olPhoto("OL2A")] = JPEG
    eq(AI.fetch("Ann Leckie", { dir = DIR }), DIR .. "/Ann Leckie.jpg")
    eq(size(DIR .. "/Ann Leckie.jpg"), #JPEG)
end)

t.test("a photo bigger than a tile is scaled to the cap", function()
    reset(); withCodec(2000, 3000)
    eq(AI.maxSide(), 824)
    json[OL] = { docs = { { key = "OL3A", name = "Big Photo", work_count = 3 } } }
    files[olPhoto("OL3A")] = "\xFF\xD8\xFF\xE0" .. string.rep("b", 900000)
    eq(AI.fetch("Big Photo", { dir = DIR }), DIR .. "/Big Photo.jpg")
    eq(scaled_to[1], 549); eq(scaled_to[2], 824)
end)

t.test("when the JPEG cannot be written the download is kept", function()
    reset(); withCodec(500, 667); jpeg_fail = true
    json[OL] = { docs = { { key = "OL1A", name = "Mick Herron", work_count = 55 } } }
    files[olPhoto("OL1A")] = PNG
    eq(AI.fetch("Mick Herron", { dir = DIR }), DIR .. "/Mick Herron.png")
end)

t.test("a JPEG that comes out bigger is not used", function()
    reset(); withCodec(500, 667); jpeg_bytes = 5000
    json[OL] = { docs = { { key = "OL1A", name = "Mick Herron", work_count = 55 } } }
    files[olPhoto("OL1A")] = PNG   -- 4008 bytes
    eq(AI.fetch("Mick Herron", { dir = DIR }), DIR .. "/Mick Herron.png")
end)

os.execute("rm -rf '" .. DIR .. "'")
t.done()
