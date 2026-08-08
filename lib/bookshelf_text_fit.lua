-- Shared text-fitting helpers.
--
--   balanceLines - redistribute a wrapping title across its lines so each line
--     is roughly the same width (avoids a one-word "widow" last line). Used by
--     the hero title and the no-cover placeholder card.
--   fitFontSize  - largest font size at which text fills a box without a word
--     overflowing the width or the wrapped block overflowing the height. Lets
--     the placeholder card grow its text to the slot instead of sitting at a
--     fixed size that looks tiny on a large / high-DPI cover.
--
-- Kept out of the widgets that use them so a widget need not require another
-- widget (spine -> hero would be circular). Heavy requires (RenderText, the
-- font kit, TextBoxWidget) are deferred into the functions so merely loading
-- this module pulls in nothing at module scope -- keeps the pure-Lua test
-- harnesses that load the consuming widgets able to stub lazily.

local M = {}

-- balanceLines(text, face, max_width, bold) - redistribute words across
-- wrapped lines so each line is roughly the same width. Avoids the
-- "widow" effect where a long title's last line is one or two words.
-- TextBoxWidget wraps greedily (fill each line to capacity); this
-- rebalances by enumerating valid break-point combinations and picking
-- the one that minimises the *widest* resulting line.
--
-- Returns text with manual "\n" inserted at the chosen break points,
-- or the original text when balancing isn't possible (single line,
-- words too long to fit, line count > 3 - for which the search space
-- explodes and the natural wrap is usually acceptable).
function M.balanceLines(text, face, max_width, bold)
    if not text or text == "" or text:find("\n") then return text end
    local RenderText = require("ui/rendertext")
    -- Tokenize on whitespace. Drop any pre-existing manual breaks above.
    local words = {}
    for w in text:gmatch("%S+") do words[#words + 1] = w end
    local nw = #words
    if nw < 2 then return text end

    -- Measure each word once. Space width is constant for the face.
    local widths = {}
    for i = 1, nw do
        widths[i] = RenderText:sizeUtf8Text(0, max_width, face, words[i], true, bold).x
    end
    local space_w = RenderText:sizeUtf8Text(0, false, face, " ", true, bold).x

    -- line_w(i, j) - width of joined words[i..j] with single spaces.
    local function line_w(i, j)
        local w = 0
        for k = i, j do w = w + widths[k] end
        return w + (j - i) * space_w
    end

    -- Greedy wrap to determine natural line count. If everything fits on
    -- one line, nothing to balance.
    local n_lines = 0
    do
        local i = 1
        while i <= nw do
            local j = i
            while j < nw and line_w(i, j + 1) <= max_width do
                j = j + 1
            end
            -- If a single word doesn't fit, give up - TextBoxWidget will
            -- glyph-truncate it and balancing wouldn't help.
            if j < i then return text end
            n_lines = n_lines + 1
            i = j + 1
        end
    end
    if n_lines < 2 then return text end
    if n_lines > 4 then return text end
    -- The 4-line search is O(nw^3). Titles that wrap to four lines are already
    -- short (the fit loop shrank the font to reach four), but cap the word
    -- count so a pathological one can't stall the fit loop this runs inside.
    if n_lines == 4 and nw > 16 then return text end

    -- Brute-force search over break combinations. For n_lines = 2 we choose 1
    -- break in [1..nw-1]; for 3, two breaks; for 4, three breaks.
    -- Picks the configuration that minimises max line width while still
    -- satisfying every line <= max_width. Ties broken by smallest sum-
    -- of-squared-deviations from the mean (lightly favours the visually
    -- "tightest" balance).
    local best_breaks
    local best_max  = math.huge
    local best_dev  = math.huge
    local function consider(breaks)
        local prev = 0
        local mx, sum = 0, 0
        local line_ws = {}
        for _i, b in ipairs(breaks) do
            local w = line_w(prev + 1, b)
            if w > max_width then return end
            line_ws[#line_ws + 1] = w
            if w > mx then mx = w end
            sum = sum + w
            prev = b
        end
        local last = line_w(prev + 1, nw)
        if last > max_width then return end
        line_ws[#line_ws + 1] = last
        sum = sum + last
        if last > mx then mx = last end
        local mean = sum / (#breaks + 1)
        local dev = 0
        for _i, w in ipairs(line_ws) do
            local d = w - mean
            dev = dev + d * d
        end
        if mx < best_max or (mx == best_max and dev < best_dev) then
            best_max    = mx
            best_dev    = dev
            best_breaks = breaks
        end
    end
    if n_lines == 2 then
        for k = 1, nw - 1 do consider({ k }) end
    elseif n_lines == 3 then
        for k1 = 1, nw - 2 do
            for k2 = k1 + 1, nw - 1 do
                consider({ k1, k2 })
            end
        end
    else  -- n_lines == 4
        for k1 = 1, nw - 3 do
            for k2 = k1 + 1, nw - 2 do
                for k3 = k2 + 1, nw - 1 do
                    consider({ k1, k2, k3 })
                end
            end
        end
    end
    if not best_breaks then return text end

    -- Reassemble with manual newlines at the chosen break points.
    local parts = {}
    local prev = 0
    for _i, b in ipairs(best_breaks) do
        parts[#parts + 1] = table.concat(words, " ", prev + 1, b)
        prev = b
    end
    parts[#parts + 1] = table.concat(words, " ", prev + 1, nw)
    return table.concat(parts, "\n")
end

-- The widest single word at `face` (unwrapped). A font size is too big the
-- moment its widest word can't fit `width` on one line, since TextBoxWidget
-- can't wrap inside a word and would glyph-truncate it.
local function widestWordWidth(text, face, bold)
    local RenderText = require("ui/rendertext")
    local mx = 0
    for w in text:gmatch("%S+") do
        local ww = RenderText:sizeUtf8Text(0, false, face, w, true, bold).x
        if ww > mx then mx = ww end
    end
    return mx
end

-- fitFontSize{ text, width, max_h, lo, hi, bold, font } -> integer size.
--
-- Largest size in [lo, hi] at which `text`, wrapped to `width`, keeps its
-- widest word within `width` AND its wrapped height within `max_h`. Both
-- metrics rise monotonically with size, so a binary search finds the
-- boundary in ~log2(hi-lo) measurements. Returns `lo` when nothing fits -
-- the caller renders at `lo` and lets TextBoxWidget ellipsis-truncate, which
-- is the "truncate before it goes too small" floor.
function M.fitFontSize(o)
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local BFont         = require("lib/bookshelf_fonts")
    local text  = o.text or ""
    local width = o.width
    local max_h = o.max_h
    local lo    = o.lo or 8
    local hi    = math.max(lo, o.hi or lo)
    local bold  = o.bold and true or false
    local font  = o.font or "infofont"
    if text == "" or not width or width <= 0 or not max_h or max_h <= 0 then
        return lo
    end

    local function fits(size)
        local face = BFont:getFace(font, size, bold and { bold = true } or nil)
        if widestWordWidth(text, face, bold) > width then return false end
        local tb = TextBoxWidget:new{
            text          = text,
            face          = face,
            bold          = bold,
            width         = width,
            alignment     = "center",
            height_adjust = true,
        }
        local h = tb:getSize().h
        if tb.free then tb:free() end
        return h <= max_h
    end

    local best, a, b = lo, lo, hi
    while a <= b do
        local mid = math.floor((a + b) / 2)
        if fits(mid) then best = mid; a = mid + 1 else b = mid - 1 end
    end
    return best
end

return M
