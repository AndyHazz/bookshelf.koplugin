-- tests/_test_image_source_budget.lua
-- Pure-Lua tests for the bb cache's byte budget in
-- lib/bookshelf_image_source.lua. KOReader runtime modules are stubbed via
-- package.loaded before dofile, the way tests/_test_book_repository.lua and
-- tests/_test_reader_park.lua do.

package.path = "./?.lua;./?/init.lua;" .. package.path

local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()
local eq = helpers.eq

local MIB = 1024 * 1024

-- Controllable render stub: renderImageFile returns a fake bb sized by
-- pending_bytes[path] (default 1 byte) rather than decoding anything.
-- render_calls counts invocations per path, which is how a cache hit (no
-- call) is told apart from a cache miss (a call) -- the module's _bb_cache
-- is a local the test has no direct handle on.
local pending_bytes = {}
local render_calls = {}

-- stride * h is exactly what the module's copy of _bbBytes measures, so
-- h = 1 makes "bytes" the whole story.
local function fakeBb(bytes)
    return { stride = bytes, h = 1 }
end

package.loaded["ui/renderimage"] = {
    renderImageFile = function(_self, path, _gray, _w, _h)
        render_calls[path] = (render_calls[path] or 0) + 1
        return fakeBb(pending_bytes[path] or 1)
    end,
}

package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(_path, key)
        if key == "mode" then return "file" end
        return { mode = "file", modification = 1 }
    end,
}

package.loaded["logger"] = {
    dbg = function() end, info = function() end,
    warn = function() end, err = function() end,
}

-- Required at module load time; none of its methods are exercised by these
-- tests (no folder/stack image resolution calls here).
package.loaded["lib/bookshelf_settings_store"] = {
    read = function() return nil end,
    save = function() end,
    delete = function() end,
    generation = function() return 0 end,
}

local Src = dofile("lib/bookshelf_image_source.lua")

t.test("BB_BYTE_BUDGET is 8 MiB", function()
    eq(Src.BB_BYTE_BUDGET, 8 * MIB)
end)

t.test("two 3 MiB entries fit under the budget", function()
    Src._bbCacheReset()
    pending_bytes["/img/a.dat"] = 3 * MIB
    pending_bytes["/img/b.dat"] = 3 * MIB
    Src.loadImageNative("/img/a.dat")
    Src.loadImageNative("/img/b.dat")

    local stats = Src._bbCacheStats()
    eq(stats.n, 2)
    eq(stats.bytes, 6 * MIB)
end)

t.test("a third 3 MiB entry evicts the oldest", function()
    Src._bbCacheReset()
    render_calls = {}
    pending_bytes["/img/a.dat"] = 3 * MIB
    pending_bytes["/img/b.dat"] = 3 * MIB
    pending_bytes["/img/c.dat"] = 3 * MIB
    Src.loadImageNative("/img/a.dat")
    Src.loadImageNative("/img/b.dat")
    Src.loadImageNative("/img/c.dat")

    local stats = Src._bbCacheStats()
    eq(stats.n, 2)
    eq(stats.bytes, 6 * MIB)

    -- The newest key is still resident: reloading it must not re-render.
    local c_calls_before = render_calls["/img/c.dat"]
    Src.loadImageNative("/img/c.dat")
    eq(render_calls["/img/c.dat"], c_calls_before)

    -- The oldest key was evicted: reloading it must re-render.
    local a_calls_before = render_calls["/img/a.dat"]
    Src.loadImageNative("/img/a.dat")
    assert(render_calls["/img/a.dat"] == a_calls_before + 1,
        "expected the evicted entry to be re-rendered on next load")
end)

t.test("a single entry over budget on its own is kept", function()
    Src._bbCacheReset()
    pending_bytes["/img/big.dat"] = 12 * MIB
    Src.loadImageNative("/img/big.dat")

    local stats = Src._bbCacheStats()
    eq(stats.n, 1)
    eq(stats.bytes, 12 * MIB)
end)

t.test("overwriting the same key replaces its size rather than adding to it", function()
    Src._bbCacheReset()
    Src._bbCachePut("same-key", fakeBb(3 * MIB))
    Src._bbCachePut("same-key", fakeBb(5 * MIB))

    local stats = Src._bbCacheStats()
    eq(stats.n, 1)
    eq(stats.bytes, 5 * MIB)
end)

t.test("the entry-count cap still binds under the byte budget", function()
    Src._bbCacheReset()
    for i = 1, 70 do
        local path = "/img/tiny" .. i .. ".dat"
        pending_bytes[path] = 1
        Src.loadImageNative(path)
    end

    local stats = Src._bbCacheStats()
    eq(stats.n, 64)
end)

t.done()
