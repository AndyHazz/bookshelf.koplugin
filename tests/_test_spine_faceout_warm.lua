-- tests/_test_spine_faceout_warm.lua
-- A Spines shelf with every book facing out (Face out: all) paints a cover
-- for every book, so its next pages' covers are warmed in the background as a
-- Covers shelf's are. Measured on a PW5 (Decades, 9 covers a page): a cover
-- never shown at face-out size cost 70-150 ms on the turn (decode 30-70 ms
-- plus scale and cache), 0.7-1 s a page; one already cached, 23-31 ms.
--
-- Driven against the real bodies, extracted by name.
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

local wsrc = io.open("lib/bookshelf_widget.lua"):read("*a")
local ssrc = io.open("lib/bookshelf_spine_widget.lua"):read("*a")

local function compile(code, env, name)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, name)); _G.setfenv(f, env); return f
    end
    return assert(load(code, name, "t", env))
end

-- ── Which covers: BookshelfWidget:_spineFaceOutJobs(direction) ──────────
-- The books themselves come from SpineShelf.faceOutPaths (the plan's own
-- decision, _test_face_out_ahead); this is which run of the list it is asked
-- about, and what it is handed.
local JOBS = assert(wsrc:match("\nfunction BookshelfWidget:_spineFaceOutJobs%(direction%)\n(.-)\nend\n"),
    "BookshelfWidget:_spineFaceOutJobs is gone")
local WARMABLE = assert(wsrc:match("\nfunction BookshelfWidget:_spineWarmable%(%)\n(.-)\nend\n"),
    "BookshelfWidget:_spineWarmable is gone")
local dims, asked, slot_args
local SpineStub = {
    faceOutSpec = function(v)
        if v == "all" then return { all = true } end
        if v == "none" then return {} end
        return { [v] = true }
    end,
    faceOutEmpty = function(spec) return next(spec) == nil end,
    -- Faces out: every book whose path ends in an even number.
    faceOutPaths = function(items, opts)
        asked = { items = items, opts = opts }
        local out, books = {}, {}
        for _i, it in ipairs(items) do
            local n = tonumber(it.filepath and it.filepath:match("(%d+)%.epub$"))
            if n and (opts.face_out == "all" or n % 2 == 0) then
                out[#out + 1] = it.filepath; books[#books + 1] = it
            end
        end
        return out, books
    end,
    -- A book's cover, by its number: wider for higher numbers.
    faceOutSlot = function(b, row_h, same_size)
        slot_args = { row_h = row_h, same_size = same_size }
        local n = tonumber(b.filepath:match("(%d+)%.epub$"))
        return 301, 190 + (n % 10)
    end,
    seriesClaimedBefore = function(all, first, window) return { claimed_from = first } end,
}
local jobs_env = setmetatable({
    SPINE_WARM_AHEAD = 24,
    require = function(n)
        if n == "lib/bookshelf_spine_widget" then return { CARD_BORDER = 1 } end
        if n == "lib/bookshelf_spine_shelf" then return SpineStub end
        error("unexpected require " .. n)
    end,
}, { __index = _G })
local jobsFor = compile("local self, direction = ...\n" .. JOBS, jobs_env, "jobs")
local warmable = compile("local self = ...\n" .. WARMABLE, jobs_env, "warmable")

local function shelf(face, cursor, n)
    local items = {}
    for i = 1, n do items[i] = { filepath = "/b/" .. i .. ".epub" } end
    return {
        _cursor = cursor,
        _spineFaceOut = function() return face end,
        _spineCachedFetch = function() return items end,
        _spineFaceRecent = function(_s, all) return { recent_of = all } end,
        _pageAheadSafe = function() return true end,
        _spineSameSize = function() return "height" end,
        _shelf_dims = dims and { shelf_h = 432 } or nil,
    }, items
end

t.test("every cover facing out: the next books' covers, at the size drawn", function()
    dims = { w = 199, h = 301 }
    local jobs = jobsFor(shelf("all", 10, 100), 1)
    eq(#jobs, 24)
    eq(jobs[1].fp, "/b/10.epub"); eq(jobs[24].fp, "/b/33.epub")
    eq(jobs[1].face_out, true)
end)

t.test("each cover at its own slot: the card less its border, sized as the plan sizes it", function()
    dims = { w = 199, h = 301 }
    local s, items = shelf("all", 10, 100)
    items[13].cover_image_path = "/c/13.jpg"
    local jobs = jobsFor(s, 1)
    eq(jobs[1].w, 190 - 2); eq(jobs[1].h, 301 - 2)     -- /b/10
    eq(jobs[2].w, 191 - 2)                            -- /b/11: its own width
    eq(slot_args.row_h, 432); eq(slot_args.same_size, "height")
    eq(jobs[4].ext, "/c/13.jpg")                      -- its own cover image goes with it
    eq(jobs[1].ext, nil)
end)

t.test("some facing out: only those, as the plan decides", function()
    dims = { w = 199, h = 301 }
    local jobs = jobsFor(shelf("favorites", 10, 100), 1)
    eq(#jobs, 12)
    eq(jobs[1].fp, "/b/10.epub"); eq(jobs[2].fp, "/b/12.epub")
end)

t.test("decided with the shelf around it: the run in shelf order, the shelf's recent set", function()
    dims = { w = 199, h = 301 }
    local s, items = shelf("first_unread", 30, 100)
    jobsFor(s, -1)
    eq(asked.items[1].filepath, "/b/6.epub")      -- shelf order, not paging order
    eq(#asked.items, 24)
    eq(asked.opts.face_out, "first_unread")
    eq(asked.opts.face_recent_set.recent_of, items)
    eq(asked.opts.series_next_claimed.claimed_from, 6)
end)

t.test("paging back warms the nearest first", function()
    dims = { w = 199, h = 301 }
    local jobs = jobsFor(shelf("all", 30, 100), -1)
    eq(#jobs, 24)
    eq(jobs[1].fp, "/b/29.epub"); eq(jobs[24].fp, "/b/6.epub")
end)

t.test("stops at either end of the list", function()
    dims = { w = 199, h = 301 }
    eq(#jobsFor(shelf("all", 95, 100), 1), 6)
    eq(#jobsFor(shelf("all", 3, 100), -1), 2)
end)

t.test("warmable: something faces out, a shelf laid out, building ahead allowed", function()
    dims = { w = 199, h = 301 }
    eq(warmable(shelf("favorites", 1, 10)), true)
    eq(warmable(shelf("none", 1, 10)), false)
    local s = shelf("all", 1, 10)
    s._pageAheadSafe = function() return false end   -- a feed's list can reach the network
    eq(warmable(s), false)
    dims = nil   -- no shelf laid out yet
    eq(warmable(shelf("all", 1, 10)), false)
end)

t.test("the warm loop's first step asks for them, after the pause", function()
    local b = assert(wsrc:match("\nfunction BookshelfWidget:_buildPhaseJobs%(phase, seen%)\n(.-)\nend\n"))
    assert(b:find("self:_spineFaceOutJobs(self._preload_dir)", 1, true),
        "the preload's first step does not choose a Spines shelf's covers")
end)

-- ── Warming one: SpineWidget.warmFaceOut(fp, w, h) ──────────────────────
local WARM = assert(ssrc:match("\nfunction SpineWidget%.warmFaceOut%(job%)\n(.-)\nend\n"),
    "SpineWidget.warmFaceOut is gone")
local log
local function bb(w, h) return { w = w, h = h, getWidth = function(s) return s.w end,
    getHeight = function(s) return s.h end, free = function(s) s.freed = true end } end
local cache, src_bb
local warm_env = setmetatable({
    ScaledCoverCache = {
        getSized = function(_c, fp, w, h) return cache.sized end,
        get = function(_c, fp) return cache.any end,
        put = function(_c, fp, b) log[#log + 1] = "put"; return cache.put_returns or b end,
        putSized = function(_c, fp, w, h, b) log[#log + 1] = "putSized"; return b end,
    },
    _getRepo = function() return { getCoverBB = function() log[#log + 1] = "decode"; return src_bb end } end,
    _coverFillBB = function(b, w, h) return bb(w, h) end,
    _derived = function(_s, c) return c end,
    _sameShape = function(b, w, h) return math.abs(b.h / b.w - h / w) < 0.02 end,
}, { __index = _G })
local ext_calls
warm_env.SpineWidget = {
    externalCover = function(path, w, h, fill)
        ext_calls[#ext_calls + 1] = { path = path, w = w, h = h, fill = fill }
        return cache.ext_bb, cache.ext_fit, cache.ext_cached
    end,
}
local warm_job = compile("local job = ...\n" .. WARM, warm_env, "warm")
local function warm(fp, w, h, ext) return warm_job{ fp = fp, w = w, h = h, ext = ext } end

local function reset(c) cache, log, src_bb, ext_calls = c, {}, bb(600, 900), {} end

t.test("a cover already kept at the size, or larger in its shape, is left alone", function()
    reset{ sized = bb(199, 301) }
    eq(warm("/b/1", 199, 301), "already"); eq(#log, 0)
    reset{ any = bb(398, 602) }
    eq(warm("/b/1", 199, 301), "already"); eq(#log, 0)
end)

t.test("one smaller, or another shape, is decoded and kept at the size drawn", function()
    reset{ any = bb(85, 130) }
    eq(warm("/b/1", 199, 301), "decoded")
    eq(log[1], "decode"); eq(log[2], "put")
    assert(src_bb.freed, "the decoded source was not freed")
    reset{ any = bb(300, 300) }
    eq(warm("/b/1", 199, 301), "decoded")
end)

t.test("kept on its own when the cache keeps a larger copy of another shape", function()
    reset{ put_returns = bb(400, 400) }
    eq(warm("/b/1", 199, 301), "decoded")
    eq(log[3], "putSized")
end)

t.test("a copy the cache turned down for a larger one of its shape is freed", function()
    local made
    warm_env._coverFillBB = function(b, w, h) made = bb(w, h); return made end
    reset{ put_returns = bb(398, 602) }
    eq(warm("/b/1", 199, 301), "decoded")
    assert(made.freed, "the unused copy leaked")
    warm_env._coverFillBB = function(b, w, h) return bb(w, h) end
end)

t.test("no cover to decode: failed, nothing kept", function()
    reset{}
    src_bb = nil
    eq(warm("/b/1", 199, 301), "failed")
    eq(#log, 1)
end)

t.test("a book with its own cover image is warmed from that image, as the tile shows it", function()
    reset{ ext_bb = bb(198, 299), ext_cached = false }
    eq(warm("/b/1", 198, 299, "/c/1.jpg"), "decoded")
    eq(ext_calls[1].path, "/c/1.jpg"); eq(ext_calls[1].w, 198); eq(ext_calls[1].fill, true)
    eq(#log, 0)                                  -- the book's own cover was never decoded
    reset{ ext_bb = bb(198, 299), ext_cached = true }
    eq(warm("/b/1", 198, 299, "/c/1.jpg"), "already")
end)

t.test("an image that cannot be loaded falls back to the book's own cover, as the tile does", function()
    reset{}                                      -- externalCover loads nothing
    eq(warm("/b/1", 198, 299, "/c/1.jpg"), "decoded")
    eq(#ext_calls, 1)
    eq(log[1], "decode")                         -- the book's own cover, warmed
    reset{}
    src_bb = nil
    eq(warm("/b/1", 198, 299, "/c/1.jpg"), "failed")
end)

t.test("the tile loads its own cover image through the same function", function()
    local body = assert(ssrc:match("\nfunction SpineWidget:_renderCover%(bb%)\n(.-)\nend\n"))
    assert(body:find("SpineWidget.externalCover(external_cover, img_w, img_h, self.cover_fill)", 1, true),
        "_renderCover loads external covers on its own again")
end)

-- ── Wiring ───────────────────────────────────────────────────────────────
t.test("the warm loop warms a face-out job through the tile's own cache rules", function()
    local body = assert(wsrc:match("\nlocal function _warmChunk%(jobs, chunk, counters%)\n(.-)\nend\n"))
    assert(body:find("SW.warmFaceOut(job)", 1, true),
        "_warmChunk does not warm face-out jobs")
end)

t.done()
