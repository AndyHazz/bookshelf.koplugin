-- bookshelf_inline_style.lua
-- Style runs INSIDE one line of tokens.
--
-- ── What this is for ───────────────────────────────────────────────────────
--
-- A list line has one face, one size and one weight for its whole length. That
-- is right for a title and wrong for the thing the maintainer asked for:
--
--     "put the series number in a small light font on the same line as the
--      title, with a spacer between them"
--
-- which needs two styles on one line. The alternative considered was splitting
-- every row into a left and a right column, each with its own style block. It
-- was turned down for two reasons worth keeping written down: a column pair
-- changes the SHAPE of the line array, which is what the page-constant row
-- height is computed from (ListGeom.rowHeight, shareBands, packRow and
-- _viewSize all consume one entry per line), and it leaves %bar nowhere to
-- live -- "%authors%bar%book_time_left" is three zones today, with the bar
-- between them. Inline runs leave the budget path untouched: a line is still
-- one line with one height.
--
-- ── The vocabulary ─────────────────────────────────────────────────────────
--
--     [b]…[/b]            bold
--     [i]…[/i]            italic
--     [u]…[/u]            recognised and DROPPED -- TextWidget cannot
--                         underline, and a tag that silently did nothing
--                         would read as a bug. It was already being stripped
--                         before this module existed; that has not changed.
--     [font=NAME]…[/font] a named font, resolved through BFont by the caller
--     [size=N]…[/size]    N points, in the same units as the line's own Size
--                         control (BEFORE list_font_scale, which the renderer
--                         applies on top)
--     [size=+N] [size=-N] N points either side of what the enclosing run is
--                         at. Survives a change to the line's own size, which
--                         an absolute value does not.
--
-- Tags nest and may be left unclosed (an unclosed tag runs to the end of the
-- line). A closer with no opener is dropped. ANY OTHER bracketed word is not
-- ours and passes through untouched -- which is what keeps [if:…] conditionals
-- safe here, though in practice they have already been resolved by the time
-- this module sees a string.
--
-- ── Pure ───────────────────────────────────────────────────────────────────
--
-- No requires, no KOReader. Faces are resolved by the caller (ListRow), which
-- is the only part that needs the widget stack -- so this file is unit-tested
-- under a plain interpreter, which is where the parsing bugs are.

local InlineStyle = {}

-- The tags this module owns. Anything else bracketed is somebody's text.
local RECOGNISED = { b = true, i = true, u = true, font = true, size = true }

-- One tag: [/?name=value]. `%a+` stops at the "=" or the "]", so [font=Noto
-- Sans] yields name "font" and value "Noto Sans", and [if:authors] yields name
-- "if" with value ":authors" -- unrecognised, so it is left in the text.
local TAG_PATTERN = "%[(/?)(%a+)=?([^%]]*)%]"

-- The same pattern with no captures, for callers that only need to know where
-- a tag STARTS and ENDS -- the case transform steps over these exactly as it
-- steps over %spacer, or "[size=12]" becomes "[SIZE=12]" and stops being a tag.
InlineStyle.TAG_SPAN_PATTERN = "%[/?%a+=?[^%]]*%]"

InlineStyle.SIZE_MIN = 1

-- A size value: "12" absolute, "+2" / "-2" relative to the enclosing run.
-- Anything else leaves the size alone rather than guessing.
local function resolveSize(value, current)
    local sign, digits = value:match("^([+-]?)(%d+)$")
    if not digits then return current end
    local n = tonumber(digits)
    if sign == "+" then n = (current or 0) + n
    elseif sign == "-" then n = (current or 0) - n end
    if n < InlineStyle.SIZE_MIN then n = InlineStyle.SIZE_MIN end
    return n
end

local function derive(cur, name, value)
    local out = { font = cur.font, size = cur.size,
                  bold = cur.bold, italic = cur.italic }
    if name == "b" then out.bold = true
    elseif name == "i" then out.italic = true
    elseif name == "font" then
        if value ~= "" then out.font = value end
    elseif name == "size" then
        out.size = resolveSize(value, cur.size)
    end
    -- "u" falls through deliberately: recognised, so it is consumed and does
    -- not render, but there is nothing to apply.
    return out
end

local function sameStyle(a, b)
    return a.font == b.font and a.size == b.size
       and a.bold == b.bold and a.italic == b.italic
end

-- scan(text, base) -> runs, saw_tag
--
-- Every chunk of text with the style in force where it sits. Empty chunks are
-- dropped (two adjacent tags produce no run). `saw_tag` is what tells a caller
-- whether the string had any of our markup at all, which is how the single-
-- widget fast path stays free for the overwhelming majority of lines.
local function scan(text, base)
    local runs, saw_tag = {}, false
    local cur = { font = base.font, size = base.size,
                  bold = base.bold or false, italic = base.italic or false }
    local open = {}   -- { name = , prev = <style before this tag> }
    local pos = 1
    local function emit(chunk)
        if chunk == "" then return end
        local last = runs[#runs]
        -- Adjacent chunks in the same style are one run: "[u]a[/u]b" is one
        -- piece of text, and two TextWidgets would double its inter-word
        -- spacing at the seam.
        if last and sameStyle(last, cur) then
            last.text = last.text .. chunk
            return
        end
        runs[#runs + 1] = { text = chunk, font = cur.font, size = cur.size,
                            bold = cur.bold, italic = cur.italic }
    end
    while true do
        local s, e, close, name, value = text:find(TAG_PATTERN, pos)
        if not s then break end
        if not RECOGNISED[name] then
            -- Not ours. Consume up to and including it as plain text, so the
            -- scan cannot loop and the brackets still render.
            emit(text:sub(pos, e))
            pos = e + 1
        else
            saw_tag = true
            emit(text:sub(pos, s - 1))
            if close == "/" then
                -- Unwind to the matching opener. A closer with no opener is
                -- dropped rather than treated as an opener.
                for i = #open, 1, -1 do
                    if open[i].name == name then
                        cur = open[i].prev
                        for j = #open, i, -1 do open[j] = nil end
                        break
                    end
                end
            else
                open[#open + 1] = { name = name, prev = cur }
                cur = derive(cur, name, value)
            end
            pos = e + 1
        end
    end
    emit(text:sub(pos))
    return runs, saw_tag
end

-- InlineStyle.key(style) -> a string that is equal for equal styles.
--
-- How a run finds the face the page already resolved for it. Resolving per run
-- per row would put BFont's name-to-file scan inside the render loop; the page
-- resolves each distinct style once and the runs look theirs up by this.
function InlineStyle.key(style)
    if not style then return "-" end
    return table.concat({ tostring(style.font or "-"),
                          tostring(style.size or "-"),
                          style.bold and "b" or "-",
                          style.italic and "i" or "-" }, "|")
end

-- InlineStyle.parse(text, base) -> array of { text, font, size, bold, italic },
-- or nil when the string carries none of our markup.
--
-- nil rather than a one-run array on purpose: it is the caller's signal to
-- take the single-TextWidget path it has always taken. Every line that does
-- not use this feature must cost exactly what it cost before.
function InlineStyle.parse(text, base)
    if type(text) ~= "string" or text == "" then return nil end
    if not text:find("[", 1, true) then return nil end
    local runs, saw_tag = scan(text, base or {})
    if not saw_tag then return nil end
    return runs
end

-- InlineStyle.strip(text) -> the same text with every recognised tag removed.
--
-- For the readers that want the words and not the styling: the row-height
-- budget's "did this line expand to anything?" test, the wrapping ({xN}) path,
-- which is one face by construction, and the menu preview.
function InlineStyle.strip(text)
    if type(text) ~= "string" or text == "" then return text end
    if not text:find("[", 1, true) then return text end
    return (text:gsub(TAG_PATTERN, function(_close, name, _value)
        if RECOGNISED[name] then return "" end
        return nil   -- not ours: gsub keeps the original match
    end))
end

-- InlineStyle.styles(text, base) -> the distinct styles this string renders
-- at, base included, most-different-first in no particular order.
--
-- Read off the TEMPLATE, not off expanded text: a line's height is reserved
-- before any book has been expanded against it, so what the budget needs is
-- every size the line CAN render at. Same trick, and the same trade, as
-- ListRow.templateFont and {xN} -- a conditional that only picks a big font
-- for some books makes every row tall enough for it, rather than giving the
-- page rows of different heights.
function InlineStyle.styles(text, base)
    base = base or {}
    local out = { { font = base.font, size = base.size,
                    bold = base.bold or false, italic = base.italic or false } }
    local runs = InlineStyle.parse(text, base)
    if not runs then return out end
    for _i, run in ipairs(runs) do
        local seen = false
        for _j, have in ipairs(out) do
            if sameStyle(have, run) then seen = true break end
        end
        if not seen then
            out[#out + 1] = { font = run.font, size = run.size,
                              bold = run.bold, italic = run.italic }
        end
    end
    return out
end

return InlineStyle
