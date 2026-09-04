-- tests/_test_clock_date_fit.lua
-- analogue_clock's dateFits: does a hero cell have room for a clock face AND
-- the date line beneath it?
--
-- The cell's content is pad + face + pad + date, and the face has a minimum
-- diameter. In a short cell the face stops shrinking while the date keeps its
-- reserve, so the content grows past the cell and ClipContainer cuts the date
-- through the middle -- which reads as broken rendering rather than a layout
-- choice. The fit loop cannot rescue it because the date font has its own
-- floor. So the date is dropped instead.
--
-- Pinned because BOTH directions are user-visible and opposite: too strict and
-- the date disappears from cells that could hold it; too lax and it comes back
-- sliced in half. Surfaced when the hero grid started pairing flex modules
-- (issue #359), which makes rows taller and cells squarer.
package.path = "./?.lua;./?/init.lua;" .. package.path

local t   = dofile("tests/_helpers.lua").runner()
local src = io.open("micromodules/analogue_clock.lua"):read("*a")

local body = src:match("\nlocal function dateFits%(avail_h, pad, date_h, min_diam%)\n(.-)\nend\n")
assert(body, "could not find dateFits in analogue_clock - renamed?")

local function compile(code, env, name)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, name))
        _G.setfenv(f, env)
        return f
    end
    return assert(load(code, name, "t", env))
end

local function fits(avail_h, pad, date_h, min_diam)
    local fn = compile("local avail_h, pad, date_h, min_diam = ...\n" .. body, {}, "dateFits")
    return fn(avail_h, pad, date_h, min_diam)
end

-- Realistic hero numbers: pad = scaleBySize(8), date_h ~ scaleBySize(12)*1.4,
-- min face diameter = scaleBySize(40). At ~2x that is pad 16, date 34, face 80.
local PAD, DATE_H, MIN_DIAM = 16, 34, 80

t.test("a tall cell keeps the date", function()
    assert(fits(400, PAD, DATE_H, MIN_DIAM) == true, "400px cell should keep the date")
end)

t.test("a short cell drops it rather than showing it sliced", function()
    assert(fits(120, PAD, DATE_H, MIN_DIAM) == false, "120px cell cannot hold face + date")
end)

t.test("the boundary is exact, and inclusive", function()
    -- Content is pad + face + pad + date + a trailing pad of slack, so the
    -- smallest cell that still fits is 3*pad + date_h + min_diam.
    local exact = 3 * PAD + DATE_H + MIN_DIAM
    assert(fits(exact, PAD, DATE_H, MIN_DIAM) == true,
        "the exact fit must KEEP the date, not drop it one pixel early")
    assert(fits(exact - 1, PAD, DATE_H, MIN_DIAM) == false,
        "one pixel under must drop it")
end)

t.test("missing geometry keeps the date, so a caller without a height is unaffected", function()
    -- The non-hero callers (start menu, settings preview) pass no avail_h and
    -- must render exactly as before.
    assert(fits(nil, PAD, DATE_H, MIN_DIAM) == true, "no height must not suppress the date")
    assert(fits(400, nil, DATE_H, MIN_DIAM) == true, "no pad must not suppress the date")
end)

t.done()
