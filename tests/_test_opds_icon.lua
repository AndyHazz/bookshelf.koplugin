-- tests/_test_opds_icon.lua
-- Pure halves of the OPDS nav-icon pipeline: data-URI parsing, integer scale
-- selection, and the nearest-neighbour upscale (exercised against a stub bb).
-- iconFor needs RenderImage/ffi and is device-verified, not unit-tested.
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["logger"] = { dbg=function() end, info=function() end,
                             warn=function() end, err=function() end }
-- parse() reaches CoverFetch._base64decode; stub cover_fetch's KOReader deps
-- so the real decoder loads in the pure-Lua harness (same trio
-- _test_cover_fetch_base64.lua stubs).
package.preload["datastorage"] = function()
    return { getSettingsDir = function() return "/tmp" end }
end
package.preload["libs/libkoreader-lfs"] = function()
    return { attributes = function() return nil end }
end

local Icon = dofile("lib/bookshelf_opds_icon.lua")

local pass, fail = 0, 0
local function eq(got, want, label)
    if got == want then pass = pass + 1
    else fail = fail + 1; print("FAIL "..label..": got "..tostring(got).." want "..tostring(want)) end
end
local function ok(c, l) if c then pass = pass + 1 else fail = fail + 1; print("FAIL "..l) end end

-- parse(): base64 data URIs decode; anything else is nil
-- "aGk=" is "hi"
eq(Icon.parse("data:image/png;base64,aGk="), "hi", "base64 data uri decodes")
eq(Icon.parse("data:image/png,rawpayload"), nil, "non-base64 data uri rejected")
eq(Icon.parse("https://h/icon.png"), nil, "http url rejected")
eq(Icon.parse(nil), nil, "nil rejected")
eq(Icon.parse("data:image/png;base64,%%%"), nil, "undecodable payload rejected")

-- scaleFactor(): round(target/native), clamped 1..3
eq(Icon.scaleFactor(16, 16), 1, "1:1")
eq(Icon.scaleFactor(16, 36), 2, "16 -> 36 rounds to x2")
eq(Icon.scaleFactor(16, 48), 3, "x3")
eq(Icon.scaleFactor(16, 200), 3, "clamped high")
eq(Icon.scaleFactor(64, 16), 1, "never below 1 (no downscale)")
eq(Icon.scaleFactor(0, 20), 1, "degenerate native height -> 1")

-- scaledCopy(): nearest-neighbour against a stub bb
local function stub_bb(w, h)
    local px = {}
    local bb = {
        w = w, h = h,
        getWidth  = function() return w end,
        getHeight = function() return h end,
        getType   = function() return 7 end,
        getPixel  = function(_, x, y) return px[y * 1000 + x] end,
        setPixel  = function(_, x, y, v) px[y * 1000 + x] = v end,
        _px = px,
    }
    return bb
end
-- Icon.scaledCopy must build the destination through its injectable
-- constructor seam so the stub works without ffi.
local made
Icon._new_bb = function(w, h, _t) made = stub_bb(w, h); return made end
local src = stub_bb(2, 1)
src._px[0 * 1000 + 0] = "L"   -- (0,0)
src._px[0 * 1000 + 1] = "R"   -- (1,0)
local dst = Icon.scaledCopy(src, 2)
ok(dst == made, "x2 copy built through the constructor seam")
eq(dst.getWidth(), 4, "x2 width")
eq(dst.getHeight(), 2, "x2 height")
eq(dst._px[0 * 1000 + 0], "L", "(0,0) from left source pixel")
eq(dst._px[0 * 1000 + 1], "L", "(1,0) still left")
eq(dst._px[0 * 1000 + 2], "R", "(2,0) right")
eq(dst._px[1 * 1000 + 3], "R", "(3,1) right, second row")
local same = stub_bb(2, 1)
ok(Icon.scaledCopy(same, 1) == same, "s == 1 returns the same bb")

print(string.format("opds_icon: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
