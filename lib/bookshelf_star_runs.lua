--[[
bookshelf_star_runs.lua -- a book's rating stars inside a text, and the colour
the reader gave them (issue 594).

The rating tokens (%rating, %hardcover_stars) write a star row into whatever
template uses them: a line of the top panel, its description, a list row. To
colour those stars the text is searched, just before it is drawn, for the
exact rows the tokens write for THAT book. Nothing is added to the text, so
widths measured on it stay right, and stars a reader typed by hand or the
favourite mark are left alone (unless they spell out the book's own rating).

inText is asked for every piece of every list row, so it gives up before any
lookup when the text holds no star glyph at all.
]]
local Runs = require("lib/bookshelf_colour_runs")

local M = {}

-- The colour set for the rating stars, or nil: unset, the stars are drawn in
-- the text ink like everything round them.
function M.ink()
    local ok, CP = pcall(require, "lib/bookshelf_cover_progress")
    if not ok or type(CP) ~= "table" or not CP.resolvedColors then return nil end
    local ok_c, colors = pcall(CP.resolvedColors)
    if not ok_c or type(colors) ~= "table" then return nil end
    -- type(), not ~= nil: a Blitbuffer colour raises on a compare with nil.
    if type(colors.rating_star) == "nil" then return nil end
    return colors.rating_star
end

-- The star rows the tokens write for this book, or nil when it has none.
function M.needles(book)
    if type(book) ~= "table" then return nil end
    local ok, Tokens = pcall(require, "lib/bookshelf_tokens")
    if not ok or type(Tokens) ~= "table" or type(Tokens.expanders) ~= "table" then return nil end
    local needles = {}
    for _i, name in ipairs({ "rating", "hardcover_stars" }) do
        local fn = Tokens.expanders[name]
        local row = fn and fn(book)
        if type(row) == "string" and row ~= "" then needles[#needles + 1] = row end
    end
    if #needles == 0 then return nil end
    return needles
end

-- Every star glyph the tokens use starts with one of these byte pairs:
-- U+2605/2606 (E2 98 ..) and the Nerd Font stars U+F005/F006 (EF 80 ..) and
-- U+F123 (EF 84 ..).
local function mayHoldStars(text)
    return text:find("\xE2\x98", 1, true) or text:find("\xEF\x80", 1, true)
        or text:find("\xEF\x84", 1, true)
end

-- The runs of `text` that are this book's star rows, each carrying the star
-- colour, or nil: no stars in the text, no colour set, or an unrated book.
function M.inText(book, text)
    if type(text) ~= "string" or type(book) ~= "table" or not mayHoldStars(text) then
        return nil
    end
    local ink = M.ink()
    if type(ink) == "nil" then return nil end
    local needles = M.needles(book)
    if not needles then return nil end
    local runs = Runs.find(text, needles, ink)
    if #runs == 0 then return nil end
    return runs
end

return M
