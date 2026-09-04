-- tests/_test_page_wipe.lua
-- lib/bookshelf_page_wipe: the strip-by-strip reveal used for shelf page
-- turns and the start-menu open/close.
--
-- These assert the VISIBLE RESULT, not the call sequence: a pixel-accurate
-- fake BlitBuffer records what actually lands in screen.bb, so the composite
-- after every frame is checked against what the reveal is supposed to show.
-- That makes the suite safe to optimise against -- an implementation that
-- blits less but paints the same thing still passes, and one that paints the
-- wrong thing fails even if it issues identical refreshes.
package.path = "./?.lua;./?/init.lua;" .. package.path

-- ── stubs ───────────────────────────────────────────────────────────────────
local yields = 0
package.loaded["ui/uimanager"] = {
    yieldToEPDC = function() yields = yields + 1 end,
}
package.loaded["device"] = { hasEinkScreen = function() return true end }
package.loaded["lib/bookshelf_settings_store"] = { read = function() return nil end }

local make_bb
local PageWipe = require("lib/bookshelf_page_wipe")
local t = dofile("tests/_helpers.lua").runner()

-- Pixel-accurate fake: a grid of single-character "colours".
make_bb = function(w, h, fill)
    local px = {}
    for y = 0, h - 1 do
        px[y] = {}
        for x = 0, w - 1 do px[y][x] = fill end
    end
    local bb = { w = w, h = h, px = px }
    function bb:getType() return 1 end
    function bb:blitFrom(src, dx, dy, sx, sy, bw, bh)
        for j = 0, bh - 1 do
            for i = 0, bw - 1 do
                local s = src.px[sy + j] and src.px[sy + j][sx + i]
                if s ~= nil and self.px[dy + j] then self.px[dy + j][dx + i] = s end
            end
        end
    end
    return bb
end

-- Read one row of the region back as a string, e.g. "OOOONNNN".
local function row(bb, y, x0, w)
    local out = {}
    for x = x0, x0 + w - 1 do out[#out + 1] = bb.px[y][x] end
    return table.concat(out)
end

local W, H = 40, 10
local REGION = { x = 4, y = 2, w = 32, h = 6 }

-- Drive a wipe, capturing the region's composite after every refresh.
local function run_wipe(forward, steps)
    -- The screen still holds the OUTGOING page: that is the whole point, the
    -- caller paints the incoming one offscreen instead of over the top. Only
    -- the incoming page is passed in, in the screen's coordinate space.
    --
    -- new_bb is "N" ONLY inside the region and "X" everywhere else, which is
    -- what makes a source-coordinate bug visible. A uniformly-"N" buffer reads
    -- "N" wherever you sample it, so reading from the wrong place looks
    -- perfect -- an earlier version of this test passed against exactly that
    -- mutation.
    local new_bb = make_bb(W, H, "X")
    for y = REGION.y, REGION.y + REGION.h - 1 do
        for x = REGION.x, REGION.x + REGION.w - 1 do new_bb.px[y][x] = "N" end
    end
    local screen = { bb = make_bb(W, H, "O") }
    local frames, refreshes = {}, {}
    function screen:refreshUI(x, y, w, h)
        refreshes[#refreshes + 1] = { x = x, y = y, w = w, h = h }
        frames[#frames + 1] = row(self.bb, REGION.y, REGION.x, REGION.w)
    end
    PageWipe.run(screen, new_bb, REGION, forward, steps)
    return screen, frames, refreshes
end

-- Expected composite for the forward reveal: old on the left, new growing in
-- from the right, boundary at rw - dx.
local function expect_forward(dx)
    return string.rep("O", REGION.w - dx) .. string.rep("N", dx)
end
local function expect_backward(dx)
    return string.rep("N", dx) .. string.rep("O", REGION.w - dx)
end

for _, steps in ipairs({ 5, 8, 12 }) do
    t.test(("forward reveal composites correctly at every frame (steps=%d)"):format(steps), function()
        local _, frames = run_wipe(true, steps)
        assert(#frames == steps, ("expected %d frames, got %d"):format(steps, #frames))
        for i = 1, steps do
            local dx = math.floor(REGION.w * i / steps)
            local want = expect_forward(dx)
            assert(frames[i] == want,
                ("frame %d/%d\n  want %s\n  got  %s"):format(i, steps, want, frames[i]))
        end
    end)

    t.test(("backward reveal composites correctly at every frame (steps=%d)"):format(steps), function()
        local _, frames = run_wipe(false, steps)
        for i = 1, steps do
            local dx = math.floor(REGION.w * i / steps)
            local want = expect_backward(dx)
            assert(frames[i] == want,
                ("frame %d/%d\n  want %s\n  got  %s"):format(i, steps, want, frames[i]))
        end
    end)
end

t.test("wipe lands on the new page in full", function()
    for _, forward in ipairs({ true, false }) do
        local screen = run_wipe(forward, 8)
        for y = REGION.y, REGION.y + REGION.h - 1 do
            assert(row(screen.bb, y, REGION.x, REGION.w) == string.rep("N", REGION.w),
                "final composite is not the new page, forward=" .. tostring(forward))
        end
    end
end)

t.test("nothing outside the region is touched", function()
    local screen = run_wipe(true, 8)
    -- Everything outside the region keeps the OUTGOING page. This matters more
    -- than it used to: the caller no longer paints the new page over the whole
    -- screen first, so anything the wipe strays onto would be left showing a
    -- half-revealed frame with no refresh coming to correct it.
    assert(row(screen.bb, 0, 0, W) == string.rep("O", W), "row above region changed")
    assert(row(screen.bb, H - 1, 0, W) == string.rep("O", W), "row below region changed")
    assert(row(screen.bb, REGION.y, 0, REGION.x) == string.rep("O", REGION.x),
        "left margin changed")
    assert(row(screen.bb, REGION.y, REGION.x + REGION.w, W - REGION.x - REGION.w)
        == string.rep("O", W - REGION.x - REGION.w), "right margin changed")
end)

t.test("the refreshed rect is exactly the strip that changed", function()
    for _, forward in ipairs({ true, false }) do
        local _, frames, refreshes = run_wipe(forward, 8)
        local prev = forward and expect_forward(0) or expect_backward(0)
        for i = 1, #frames - 1 do   -- last frame refreshes the whole region
            local r = refreshes[i]
            for x = 0, REGION.w - 1 do
                local changed = prev:sub(x + 1, x + 1) ~= frames[i]:sub(x + 1, x + 1)
                local inside = (REGION.x + x) >= r.x and (REGION.x + x) < (r.x + r.w)
                assert(not changed or inside, ("frame %d: column %d changed but sits "
                    .. "outside the refreshed rect (forward=%s)"):format(i, x, tostring(forward)))
            end
            prev = frames[i]
        end
        local last = refreshes[#refreshes]
        assert(last.x == REGION.x and last.w == REGION.w,
            "final frame should refresh the whole region")
    end
end)

t.test("paces the panel once per intermediate strip", function()
    yields = 0
    run_wipe(true, 8)
    assert(yields == 7, "expected 7 yields for 8 steps, got " .. yields)
end)

-- ── blit volume ─────────────────────────────────────────────────────────────
-- The reveal only ever changes one strip per frame, so the composite is built
-- incrementally rather than re-blitting the whole region from both buffers
-- every frame. Pinned because the wasteful version is the natural way to write
-- this and produces identical pixels -- only the cost differs.
t.test("blits only the strip that changes, not the whole region per frame", function()
    local W2, H2 = 40, 10
    local REG = { x = 4, y = 2, w = 32, h = 6 }
    for _, forward in ipairs({ true, false }) do
        local pixels = 0
        local new_bb = make_bb(W2, H2, "X")
        for y = REG.y, REG.y + REG.h - 1 do
            for x = REG.x, REG.x + REG.w - 1 do new_bb.px[y][x] = "N" end
        end
        local screen = { bb = make_bb(W2, H2, "O") }
        local inner = screen.bb.blitFrom
        screen.bb.blitFrom = function(self, src, dx, dy, sx, sy, bw, bh)
            pixels = pixels + bw * bh
            return inner(self, src, dx, dy, sx, sy, bw, bh)
        end
        function screen:refreshUI() end
        PageWipe.run(screen, new_bb, REG, forward, 8)
        -- Naive per-frame full-region compositing costs steps * w * h.
        local naive = 8 * REG.w * REG.h
        assert(pixels <= naive / 3, ("forward=%s: blitted %d px, wanted <= %d (naive %d)")
            :format(tostring(forward), pixels, naive / 3, naive))
    end
end)

t.done()
