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
local JOBS = assert(wsrc:match("\nfunction BookshelfWidget:_spineFaceOutJobs%(direction%)\n(.-)\nend\n"),
    "BookshelfWidget:_spineFaceOutJobs is gone")
local dims
local jobs_env = setmetatable({
    SPINE_WARM_AHEAD = 24,
    require = function(n)
        if n == "lib/bookshelf_spine_widget" then return { face_out_dims = dims } end
        if n == "lib/bookshelf_spine_shelf" then return require("lib/bookshelf_spine_shelf") end
        error("unexpected require " .. n)
    end,
}, { __index = _G })
package.loaded["lib/bookshelf_spine_shelf"] = package.loaded["lib/bookshelf_spine_shelf"] or {
    faceOutSpec = function(v) return v == "all" and { all = true } or { favorites = true } end,
}
local jobsFor = compile("local self, direction = ...\n" .. JOBS, jobs_env, "jobs")

local function shelf(face, cursor, n)
    local items = {}
    for i = 1, n do items[i] = { filepath = "/b/" .. i .. ".epub" } end
    return {
        _cursor = cursor,
        _spineFaceOut = function() return face end,
        _spineCachedFetch = function() return items end,
        _pageAheadSafe = function() return true end,
    }, items
end

t.test("every cover facing out: the next books' covers, at the size drawn", function()
    dims = { w = 199, h = 301 }
    local jobs = jobsFor(shelf("all", 10, 100), 1)
    eq(#jobs, 24)
    eq(jobs[1].fp, "/b/10.epub"); eq(jobs[24].fp, "/b/33.epub")
    eq(jobs[1].w, 199); eq(jobs[1].h, 301); eq(jobs[1].face_out, true)
end)

t.test("paging back warms the books before the page", function()
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

t.test("nothing unless every book faces out, or before a face-out was drawn", function()
    dims = { w = 199, h = 301 }
    eq(#jobsFor(shelf("favorites", 10, 100), 1), 0)
    dims = nil
    eq(#jobsFor(shelf("all", 10, 100), 1), 0)
end)

t.test("never where building ahead is not allowed (a feed's list can reach the network)", function()
    dims = { w = 199, h = 301 }
    local s = shelf("all", 10, 100)
    local fetched = false
    s._pageAheadSafe = function() return false end
    s._spineCachedFetch = function() fetched = true; return {} end
    eq(#jobsFor(s, 1), 0)
    assert(not fetched, "fetched the list anyway")
end)

t.test("only books: a series box or an add tile has no cover of its own to warm", function()
    dims = { w = 199, h = 301 }
    local s, items = shelf("all", 1, 4)
    items[2] = { _series_box = true }
    items[3] = { add_subshelf = true }
    local jobs = jobsFor(s, 1)
    eq(#jobs, 2); eq(jobs[2].fp, "/b/4.epub")
end)

-- ── Warming one: SpineWidget.warmFaceOut(fp, w, h) ──────────────────────
local WARM = assert(ssrc:match("\nfunction SpineWidget%.warmFaceOut%(fp, w, h%)\n(.-)\nend\n"),
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
local warm = compile("local fp, w, h = ...\n" .. WARM, warm_env, "warm")

local function reset(c) cache, log, src_bb = c, {}, bb(600, 900) end

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

-- ── Wiring ───────────────────────────────────────────────────────────────
t.test("a face-out tile records the size it draws at", function()
    local body = assert(ssrc:match("\nfunction SpineWidget:_renderCover%(bb%)\n(.-)\nend\n"))
    assert(body:find("SpineWidget.face_out_dims = { w = img_w, h = img_h }", 1, true),
        "_renderCover does not record the face-out size")
end)

t.test("the warm loop warms a face-out job through the tile's own cache rules", function()
    local body = assert(wsrc:match("\nlocal function _warmChunk%(jobs, chunk, counters%)\n(.-)\nend\n"))
    assert(body:find("warmFaceOut(job.fp, job.w, job.h)", 1, true),
        "_warmChunk does not warm face-out jobs")
end)

t.done()
