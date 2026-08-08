-- tests/_test_text_fit.lua
-- Algorithm tests for bookshelf_text_fit. The real height/width come from the
-- font stack, so we stub the measurement layer with a deterministic model:
--   * a char is `size` px wide; a space is `size` px wide
--   * a TextBoxWidget greedy-wraps words to `width`, and each line is
--     ceil(size * 1.3) px tall
-- Both metrics rise monotonically with size, which is the property the binary
-- search relies on -- so this pins the search boundary, the width cap, the
-- height cap, and the "nothing fits -> floor" return without needing fonts.

package.path = "./?.lua;" .. package.path

local function wordWidth(w, size) return #w * size end
local function spaceWidth(size) return size end

-- Greedy word wrap -> number of lines (mirrors TextBoxWidget).
local function lineCount(text, size, width)
    local words = {}
    for w in text:gmatch("%S+") do words[#words + 1] = w end
    if #words == 0 then return 0 end
    local lines, cur = 1, wordWidth(words[1], size)
    for i = 2, #words do
        local add = spaceWidth(size) + wordWidth(words[i], size)
        if cur + add <= width then
            cur = cur + add
        else
            lines = lines + 1
            cur = wordWidth(words[i], size)
        end
    end
    return lines
end

package.preload["ui/rendertext"] = function()
    return {
        sizeUtf8Text = function(_self, _x, _w, face, str, _kern, _bold)
            return { x = #str * (face.size or 1) }
        end,
    }
end
package.preload["lib/bookshelf_fonts"] = function()
    return { getFace = function(_self, _name, size) return { size = size } end }
end
package.preload["ui/widget/textboxwidget"] = function()
    local TB = {}
    TB.__index = TB
    function TB:new(o)
        o = setmetatable(o or {}, self)
        local size = (o.face and o.face.size) or 1
        local lines = lineCount(o.text or "", size, o.width or 1)
        o._h = lines * math.ceil(size * 1.3)
        return o
    end
    function TB:getSize() return { w = self.width, h = self._h } end
    function TB:free() end
    return TB
end

local TextFit = require("lib/bookshelf_text_fit")

local pass, fail = 0, 0
local function check(name, got, want)
    if got == want then
        pass = pass + 1
    else
        fail = fail + 1
        print(string.format("FAIL %s: got %s want %s", name, tostring(got), tostring(want)))
    end
end

-- A: single word, width-bound. "Ulysses" (7) at size S is 7S wide; fits
-- width 100 iff S <= 14. Height (1 line) never binds. -> 14.
check("width-bound single word",
    TextFit.fitFontSize{ text = "Ulysses", width = 100, max_h = 1000, lo = 12, hi = 34, bold = true },
    14)

-- B: multi-word, height-bound. Four 2-char words, width 60: at S=12 two
-- words/line (5S=60) = 2 lines = 32px <= max_h 40; at S=13 one word/line =
-- 4 lines = 68 > 40. Boundary is 12, and it is between lo(8) and hi(34), so
-- this proves a genuine search rather than a clamp.
check("height-bound multi word",
    TextFit.fitFontSize{ text = "aa bb cc dd", width = 60, max_h = 40, lo = 8, hi = 34 },
    12)

-- C: nothing fits the height even at the floor -> returns lo (the truncate
-- floor; caller renders at lo and ellipsis-clamps).
check("height floor return",
    TextFit.fitFontSize{ text = "hello world", width = 10000, max_h = 5, lo = 8, hi = 34 },
    8)

-- D: a single word wider than the box at every size -> width rejects even lo,
-- so the floor is returned (again the truncate case).
check("width floor return",
    TextFit.fitFontSize{ text = "Supercalifragilistic", width = 100, lo = 8, hi = 34 },
    8)

-- E: empty text / degenerate box -> floor, no crash.
check("empty text", TextFit.fitFontSize{ text = "", width = 100, max_h = 100, lo = 9, hi = 30 }, 9)
check("zero width",  TextFit.fitFontSize{ text = "x", width = 0, max_h = 100, lo = 9, hi = 30 }, 9)

-- balanceLines: a title that greedy-wraps to two lines gets one manual break,
-- and neither resulting line exceeds max_width. Face size 10, width 130:
-- "The Odyssey of Homer" -> greedy "The Odyssey of" (fits) then "Homer";
-- balancer keeps two lines but evens them.
do
    local face = { size = 10 }
    local out = TextFit.balanceLines("The Odyssey of Homer", face, 130, true)
    local nl = select(2, out:gsub("\n", ""))
    check("balance inserts one break", nl, 1)
    local RenderText = require("ui/rendertext")
    local widest = 0
    for line in (out .. "\n"):gmatch("(.-)\n") do
        local w = RenderText:sizeUtf8Text(0, 130, face, line, true, true).x
        if w > widest then widest = w end
    end
    check("balanced lines within width", widest <= 130, true)
end

-- balanceLines: a title that greedy-wraps to FOUR lines with a lone short
-- word on the last line ("... 3)") gets rebalanced so the last line is no
-- longer a widow. size 10, width 95: 40px words two-per-line, seven words ->
-- greedy 90/90/90/10 (widow); minimising max-then-deviation prefers a config
-- whose last line carries two words.
do
    local face = { size = 10 }
    local out = TextFit.balanceLines("aaaa aaaa aaaa aaaa aaaa aaaa a", face, 95, true)
    local nl = select(2, out:gsub("\n", ""))
    check("4-line title balanced (3 breaks)", nl, 3)
    local last = out:match("([^\n]*)$")
    check("last line is not a lone word", last:find(" ") ~= nil, true)
end

-- balanceLines: a single word (or empty) is returned unchanged.
check("balance single word", TextFit.balanceLines("Ulysses", { size = 10 }, 100, true), "Ulysses")
check("balance empty", TextFit.balanceLines("", { size = 10 }, 100, true), "")

print(string.format("text_fit: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
