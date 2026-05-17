-- bookshelf_author_name.lua
-- Extracts surname / given name from an author string. Handles the
-- three main Calibre conventions:
--   "Forename Surname"          -> surname = last word
--   "Surname, Forename"         -> surname = part before the comma
--   "Author1 & Author2"         -> uses Author1 only
--                                  (separators: " & ", " and ", ";")
-- Compound surnames with particles ("Le Guin", "van der Berg",
-- "de la Cruz", "Nikki St. Crowe") are kept whole when the preceding
-- word is a known particle. Used as a fallback only -- when Calibre
-- author_sort metadata is available we read that directly (see
-- cachedSurname in bookshelf_sort_engine.lua); this parser only runs
-- on non-Calibre libraries OR when KOReader's calibre.koplugin sync
-- has stripped author_sort from the device-side metadata (which it
-- currently does as of 2026.03 -- see GitHub issue #43).

local AuthorName = {}

-- Words that bind to the next word as part of the surname. All lowercase
-- (comparison lowercases input). Periods are literal -- "St." matches
-- exactly, "St" without period matches separately.
local PARTICLES = {
    -- Romance / Germanic / Slavic
    le  = true, la  = true, de  = true, del = true, di  = true,
    da  = true, du  = true, of  = true,
    van = true, von = true, der = true, den = true,
    ten = true, ter = true, dos = true, das = true,
    -- Religious / English (Saint)
    st  = true, ["st."] = true, saint = true,
    -- Arabic
    el  = true, al  = true, bin = true, ibn  = true,
}

-- pickFirstAuthor(s): drop second-and-subsequent authors.
local function pickFirstAuthor(s)
    if not s or s == "" then return "" end
    -- Split on " & " or " and " or ";". Take the first part.
    local first = s:match("^(.-)%s*&") or s:match("^(.-)%s+and%s") or s:match("^(.-);")
    return (first and first ~= "") and first or s
end

function AuthorName.surnameOf(raw)
    if type(raw) ~= "string" or raw == "" then return "" end
    local s = pickFirstAuthor(raw)
    -- "Surname, Forename" form
    local before_comma = s:match("^([^,]+),")
    if before_comma then return before_comma:gsub("^%s+", ""):gsub("%s+$", "") end
    -- "Forename Surname" form -- split on whitespace, take from end.
    local words = {}
    for w in s:gmatch("%S+") do words[#words + 1] = w end
    if #words == 0 then return "" end
    if #words == 1 then return words[1] end
    -- Particle handling: walk back from the end picking up known particles.
    local idx = #words - 1
    while idx >= 1 do
        if PARTICLES[words[idx]:lower()] then
            idx = idx - 1
        else
            break
        end
    end
    local out = words[idx + 1]
    for i = idx + 2, #words do out = out .. " " .. words[i] end
    return out
end

function AuthorName.givenOf(raw)
    if type(raw) ~= "string" or raw == "" then return "" end
    local s = pickFirstAuthor(raw)
    -- "Surname, Forename" form -> after the comma.
    local after_comma = s:match(",%s*(.+)$")
    if after_comma then return after_comma:gsub("^%s+", ""):gsub("%s+$", "") end
    -- "Forename Surname" form -> everything except the surname tail.
    local words = {}
    for w in s:gmatch("%S+") do words[#words + 1] = w end
    if #words == 0 then return "" end
    -- Single-word authors (folder named after surname, or just a handle
    -- like "AndyHazz") have no distinct given/surname split. We return
    -- the word for both surname and given so that sorting on either key
    -- places the entry in alphabetical position rather than tying every
    -- single-word author at the empty string.
    if #words == 1 then return words[1] end
    -- Mirror surnameOf to find the surname's start.
    local idx = #words - 1
    while idx >= 1 do
        if PARTICLES[words[idx]:lower()] then idx = idx - 1
        else break end
    end
    local out = nil
    for i = 1, idx do
        out = out and (out .. " " .. words[i]) or words[i]
    end
    return out or ""
end

return AuthorName
