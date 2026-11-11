-- tests/_test_colour_runs.lua
-- Pure-Lua unit tests for lib/bookshelf_colour_runs.lua: finding the runs of a
-- text that take a colour of their own (the rating stars), in characters, and
-- turning a laid-out text's glyph record into the rectangles those runs cover.

package.path = "./?.lua;./?/init.lua;" .. package.path

local Runs = dofile("lib/bookshelf_colour_runs.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        pass = pass + 1
    else
        fail = fail + 1
        io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n")
    end
end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or "") .. " expected=" .. tostring(expected) .. " got=" .. tostring(actual), 2)
    end
end
local function show(runs)
    local out = {}
    for _, r in ipairs(runs) do out[#out + 1] = r.s .. "-" .. r.e .. ":" .. tostring(r.colour) end
    return table.concat(out, " ")
end

local STAR, EMPTY = "\xE2\x98\x85", "\xE2\x98\x86"
local THREE = STAR:rep(3) .. EMPTY:rep(2)

test("a run is counted in characters, not bytes", function()
    -- "é" is two bytes and one character; the stars start at character 4.
    eq(show(Runs.find("é: " .. THREE .. " end", { THREE }, "gold")), "4-8:gold")
end)

test("no needle in the text gives no runs", function()
    eq(#Runs.find("plain text", { THREE }, "gold"), 0)
end)

test("empty and missing needles are ignored", function()
    eq(#Runs.find("plain text", { "", false }, "gold"), 0)
    eq(#Runs.find("plain text", nil, "gold"), 0)
    eq(#Runs.find(nil, { THREE }, "gold"), 0)
end)

test("every occurrence is a run, in order", function()
    eq(show(Runs.find(THREE .. " and " .. THREE, { THREE }, "c")), "1-5:c 11-15:c")
end)

test("two needles give runs sorted by position and never overlapping", function()
    local five = STAR:rep(5)
    -- "ab" + five stars: the three-star needle does not occur (no empty stars),
    -- the five-star one does.
    eq(show(Runs.find("ab" .. five, { THREE, five }, "c")), "3-7:c")
    -- A needle that is a prefix of another: the first match at a position wins
    -- and the second cannot overlap it.
    eq(show(Runs.find(five, { STAR:rep(2), five }, "c")), "1-2:c 3-4:c")
end)

test("charLen counts characters", function()
    eq(Runs.charLen("é" .. STAR .. "a"), 3)
    eq(Runs.charLen(""), 0)
end)

-- A laid-out text, as KOReader's text box keeps it: per line, the glyphs it
-- placed, each with the character it came from and its left and right edge.
local function line(first_index, x_positions)
    local g = {}
    for i = 1, #x_positions - 1 do
        g[i] = { text_index = first_index + i - 1, x0 = x_positions[i], x1 = x_positions[i + 1] }
    end
    return { xglyphs = g }
end
local function showRects(rects)
    local out = {}
    for _, r in ipairs(rects) do
        out[#out + 1] = string.format("%d,%d %dx%d:%s", r.x, r.y, r.w, r.h, tostring(r.colour))
    end
    return table.concat(out, " | ")
end

test("a run on one line is one rectangle spanning its glyphs", function()
    local lines = { line(1, { 0, 10, 20, 30, 40, 50 }) }
    eq(showRects(Runs.rects(lines, { { s = 2, e = 4, colour = "c" } }, 24)), "10,0 30x24:c")
end)

test("a run broken across two lines is one rectangle on each", function()
    local lines = { line(1, { 0, 10, 20, 30 }), line(4, { 0, 12, 24 }) }
    eq(showRects(Runs.rects(lines, { { s = 3, e = 5, colour = "c" } }, 20)),
        "20,0 10x20:c | 0,20 24x20:c")
end)

test("glyphs cut by truncation simply have no rectangle", function()
    local lines = { line(1, { 0, 10, 20 }) }   -- characters 3.. were cut off
    eq(showRects(Runs.rects(lines, { { s = 2, e = 6, colour = "c" } }, 20)), "10,0 10x20:c")
    eq(#Runs.rects(lines, { { s = 5, e = 6, colour = "c" } }, 20), 0)
end)

test("a glyph marked as not drawn is skipped, and an empty line is harmless", function()
    local l = line(1, { 0, 10, 20, 30 })
    l.xglyphs[2].no_drawing = true
    -- Skipped when it is the run's edge: the span ends at the last drawn glyph.
    eq(showRects(Runs.rects({ {}, l }, { { s = 1, e = 2, colour = "c" } }, 20)),
        "0,20 10x20:c")
end)

test("right-to-left glyphs (edges out of order) still give the covering span", function()
    -- Visual order differs from character order: take min and max of the edges.
    local l = { xglyphs = {
        { text_index = 3, x0 = 0,  x1 = 10 },
        { text_index = 2, x0 = 10, x1 = 20 },
        { text_index = 1, x0 = 20, x1 = 30 },
    } }
    eq(showRects(Runs.rects({ l }, { { s = 2, e = 3, colour = "c" } }, 20)), "0,0 20x20:c")
end)

print(string.format("colour runs: %d pass, %d fail", pass, fail))
if fail > 0 then os.exit(1) end
