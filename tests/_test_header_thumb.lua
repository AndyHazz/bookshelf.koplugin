-- tests/_test_header_thumb.lua
-- _headerThumbBB: which bitmap the book-detail header shows, and WHO OWNS IT.
--
-- Two separate things are pinned here, and they fail in opposite ways.
--
-- 1. That a thumbnail is produced at all. buildBookMeta asks BIM for the cover
--    blob only when the scaled-cover cache does NOT already hold the book. That
--    skip is deliberate, but it is true for every book on screen -- which is
--    every book this header can be opened from -- so the record's cover_bb is
--    normally nil and the header silently lost its cover. Confirmed on a PW5:
--    in_scc=true, cover_bb=nil, and the modal rendered with no thumbnail.
--
-- 2. That ownership matches the source. `disposable = true` means the caller
--    frees the bb; `false` means a cache owns it. Marking a cache-owned bb
--    disposable is invisible until the freed bitmap is painted again as
--    garbage, so every source asserts its flag, not just its bb.
package.path = "./?.lua;./?/init.lua;" .. package.path

local t   = dofile("tests/_helpers.lua").runner()
local src = io.open("lib/bookshelf_widget.lua"):read("*a")

local body = src:match("\nlocal function _headerThumbBB%(filepath, fresh, thumb_w%)\n(.-)\nend\n")
assert(body, "could not find _headerThumbBB - renamed?")

local function compile(code, env, name)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, name))
        _G.setfenv(f, env)
        return f
    end
    return assert(load(code, name, "t", env))
end

local function bb(w, label) return { w = w, label = label } end

-- opts.external : bb ImageSource returns for cover_image_path
-- opts.cached   : bb the scaled-cover cache returns
-- opts.decoded  : bb Repo.getCoverBB returns
-- opts.no_scc   : requiring the cover cache raises
-- opts.decode_raises : Repo.getCoverBB raises
local function run(fresh, thumb_w, opts)
    opts = opts or {}
    local calls = { decode = 0 }
    local env = {
        pcall = pcall, type = type,
        Repo = {
            getCoverBB = function()
                calls.decode = calls.decode + 1
                if opts.decode_raises then error("boom") end
                return opts.decoded
            end,
        },
        require = function(name)
            if name == "lib/bookshelf_image_source" then
                return { loadImageNative = function() return opts.external end }
            end
            if name == "lib/bookshelf_scaled_cover_cache" then
                if opts.no_scc then error("absent") end
                return { get = function() return opts.cached end }
            end
            error("unexpected require: " .. tostring(name))
        end,
    }
    local fn = compile("local filepath, fresh, thumb_w = ...\n" .. body, env, "_headerThumbBB")
    local got_bb, disposable = fn("/books/a.epub", fresh, thumb_w)
    return got_bb, disposable, calls
end

t.test("external cover wins, and is NOT disposable", function()
    local ext = bb(400, "ext")
    local got, disp = run({ cover_image_path = "/c.jpg", cover_bb = bb(400, "embedded") },
                          110, { external = ext })
    assert(got == ext, "external cover should win over the embedded bb")
    assert(disp == false,
        "the ImageSource cache owns it -- freeing it corrupts the shared cache")
end)

t.test("embedded cover_bb is used when there is no external one, and IS disposable", function()
    local emb = bb(400, "embedded")
    local got, disp, calls = run({ cover_bb = emb }, 110, { cached = bb(400, "cached") })
    assert(got == emb, "embedded bb should be preferred over the cache")
    assert(disp == true, "the embedded bb is one-shot and caller-owned")
    assert(calls.decode == 0, "must not decode when a bb is already in hand")
end)

t.test("REGRESSION: with no cover_bb, a wide-enough cached bb is used", function()
    -- The case the cover gate creates for every shelf-visible book.
    local cached = bb(200, "cached")
    local got, disp, calls = run({}, 110, { cached = cached })
    assert(got == cached, "header must fall back to the cache, not render coverless")
    assert(disp == false,
        "the scaled-cover cache owns this bb -- marking it disposable would free "
        .. "a bitmap the shelf still paints from")
    assert(calls.decode == 0, "no decode needed when the cache already fits")
end)

t.test("a cached bb narrower than the thumb is refused, and one is decoded", function()
    -- Using it would mean upscaling, and MuPDF upscale corrupts on Kindle.
    local decoded = bb(400, "decoded")
    local got, disp, calls = run({}, 110, { cached = bb(109, "too-narrow"), decoded = decoded })
    assert(got == decoded, "a too-narrow cached bb must not be used")
    assert(disp == true, "a freshly decoded bb is caller-owned")
    assert(calls.decode == 1, "expected exactly one decode")
end)

t.test("exactly thumb_w wide is wide enough", function()
    local cached = bb(110, "exact")
    local got, disp = run({}, 110, { cached = cached })
    assert(got == cached and disp == false, "equal width is a downscale of 1:1, not an upscale")
end)

t.test("falls through to a decode when the cover cache is unavailable", function()
    local decoded = bb(400, "decoded")
    local got, disp = run({}, 110, { no_scc = true, decoded = decoded })
    assert(got == decoded and disp == true, "a missing cache module must not lose the cover")
end)

t.test("returns nil, not an error, when every source fails", function()
    local ok, got = pcall(run, {}, 110, { decode_raises = true })
    assert(ok, "a failing decode must not propagate out of the header builder")
    assert(got == nil, "wanted nil, got " .. tostring(got))
end)

t.test("no cache-owned bb is ever returned as disposable", function()
    -- The whole ownership contract in one assertion: whatever route is taken,
    -- a bb that came from a cache must come back with disposable == false.
    local cases = {
        { fresh = { cover_image_path = "/c.jpg" }, opts = { external = bb(400, "ext") },
          owner = "ImageSource" },
        { fresh = {}, opts = { cached = bb(400, "cached") }, owner = "ScaledCoverCache" },
    }
    for _, c in ipairs(cases) do
        local _, disp = run(c.fresh, 110, c.opts)
        assert(disp == false, c.owner .. "-owned bb came back disposable")
    end
end)

t.done()
