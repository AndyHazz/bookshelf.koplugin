--[[
bookshelf_colour_runs.lua -- the parts of a text that take a colour of their own.

A text widget draws in one ink. A "run" is a stretch of that text, counted in
characters, with its own colour: today the rating stars, which the reader can
give a colour in the theme's colour menu.

Runs are found by looking for known strings (the book's own star row) in the
text as it is about to be drawn, after every transform a template goes
through. Nothing is added to the text itself, so every measurement made on it
stays right and no other reader of a template ever sees a marker.

rects() turns the record a laid-out text keeps of its glyphs (which character
each came from, and its left and right edge on its line) into the rectangles a
run covers. That is how a run is coloured inside WRAPPED text: the text box
does its own line breaking and truncation, and tells us afterwards where the
characters landed.
]]

local Runs = {}

-- The byte offset of every character start, plus one past the end, so
-- starts[i] is where character i begins and #starts - 1 is the length.
local function charStarts(text)
    local starts, n = {}, 0
    for i = 1, #text do
        local b = text:byte(i)
        if b < 0x80 or b >= 0xC0 then
            n = n + 1
            starts[n] = i
        end
    end
    starts[n + 1] = #text + 1
    return starts
end

function Runs.charLen(text)
    if type(text) ~= "string" or text == "" then return 0 end
    return #charStarts(text) - 1
end

-- Every occurrence of each needle in `text`, as { s, e, colour } in characters
-- (inclusive), sorted, never overlapping: at a given place the first needle
-- that matches wins and the search carries on after it.
function Runs.find(text, needles, colour)
    local runs = {}
    if type(text) ~= "string" or text == "" or type(needles) ~= "table" then return runs end
    local list = {}
    for _, n in ipairs(needles) do
        if type(n) == "string" and n ~= "" then list[#list + 1] = n end
    end
    if #list == 0 then return runs end
    local hits = {}
    local pos = 1
    while pos <= #text do
        local best_s, best_e
        for _, n in ipairs(list) do
            local s0, e0 = text:find(n, pos, true)
            if s0 and (not best_s or s0 < best_s) then best_s, best_e = s0, e0 end
        end
        if not best_s then break end
        hits[#hits + 1] = { best_s, best_e }
        pos = best_e + 1
    end
    if #hits == 0 then return runs end
    -- Bytes to characters, in one pass over the text.
    local starts = charStarts(text)
    local ci = 1
    for _, h in ipairs(hits) do
        while starts[ci] < h[1] do ci = ci + 1 end
        local s = ci
        while starts[ci + 1] <= h[2] do ci = ci + 1 end
        runs[#runs + 1] = { s = s, e = ci, colour = colour }
    end
    return runs
end

-- The run character `index` falls in, or nil.
function Runs.at(runs, index)
    for _, r in ipairs(runs) do
        if index >= r.s and index <= r.e then return r end
    end
    return nil
end

-- lines: the laid-out text, one entry per line, each with `xglyphs` (absent on
-- an empty line): { text_index, x0, x1, no_drawing }. One rectangle per run
-- per line it reaches, line_h tall, covering its drawn glyphs (min and max of
-- their edges, so right-to-left text is covered too). A glyph the layout cut
-- off is not in the record and so has no rectangle.
function Runs.rects(lines, runs, line_h)
    local rects = {}
    if type(lines) ~= "table" or type(runs) ~= "table" or #runs == 0 then return rects end
    for li, line in ipairs(lines) do
        local glyphs = type(line) == "table" and line.xglyphs
        if glyphs then
            local open = {}   -- run -> its rectangle on this line
            for _, g in ipairs(glyphs) do
                if not g.no_drawing and g.text_index and g.x0 and g.x1 then
                    local r = Runs.at(runs, g.text_index)
                    if r then
                        local x0, x1 = g.x0, g.x1
                        if x1 < x0 then x0, x1 = x1, x0 end
                        local rect = open[r]
                        if not rect then
                            rect = { x = x0, x1 = x1, y = (li - 1) * line_h, h = line_h,
                                     colour = r.colour }
                            open[r] = rect
                            rects[#rects + 1] = rect
                        else
                            if x0 < rect.x then rect.x = x0 end
                            if x1 > rect.x1 then rect.x1 = x1 end
                        end
                    end
                end
            end
        end
    end
    for _, rect in ipairs(rects) do
        rect.w = rect.x1 - rect.x
        rect.x1 = nil
    end
    return rects
end

return Runs
