-- bookshelf_hardcover_match.lua
-- Pure-Lua port of the ebook-enricher "best guess" matcher (matcher.py +
-- enrich.py ranking). Given a local book's title/author/series and a list of
-- Hardcover search hits, picks the best confident match -- or nothing.
--
-- Scoring mirrors the Python: per field, score = max(token_set_ratio,
-- partial_ratio) on lowercased strings; both title and author must clear 80.
-- Survivors are ranked by (series_match, is_canonical, total, -title_len_diff)
-- and a non-canonical winner (adaptation / box-set / omnibus) is rejected.
--
-- The ratio primitives are a faithful-but-approximate port of rapidfuzz: ratio
-- is the normalised LCS similarity (100 * 2*LCS / (len_a + len_b)), partial is
-- the best equal-length window of the shorter string over the longer, and
-- token_set follows fuzzywuzzy's intersection/remainder construction. They
-- won't be bit-identical to rapidfuzz's C implementation, but track it closely
-- enough for the 80/80 gate.

local Match = {}

local TITLE_THRESHOLD  = 80
local AUTHOR_THRESHOLD = 80

-- ─── ratio primitives ────────────────────────────────────────────────────────

-- Longest common subsequence length (byte-wise). Titles/authors are short, so
-- the O(n*m) table is cheap; a rolling two-row table keeps memory to O(min).
local function _lcs(a, b)
    local na, nb = #a, #b
    if na == 0 or nb == 0 then return 0 end
    -- Iterate with `a` as the outer (rows) and keep two columns-rows of nb+1.
    local prev = {}
    for j = 0, nb do prev[j] = 0 end
    local cur = {}
    for i = 1, na do
        cur[0] = 0
        local ai = a:byte(i)
        for j = 1, nb do
            if ai == b:byte(j) then
                cur[j] = prev[j - 1] + 1
            elseif prev[j] >= cur[j - 1] then
                cur[j] = prev[j]
            else
                cur[j] = cur[j - 1]
            end
        end
        for j = 0, nb do prev[j] = cur[j] end
    end
    return prev[nb]
end

-- rapidfuzz fuzz.ratio: 100 * 2*LCS / (len_a + len_b). Two empty strings score
-- 0 here (not 100) -- callers gate on real content, matching matcher.py.
local function _ratio(a, b)
    local total = #a + #b
    if total == 0 then return 0 end
    return math.floor((200 * _lcs(a, b) / total) + 0.5)
end

-- partial_ratio: best _ratio of the shorter string against every equal-length
-- window of the longer. Mirrors fuzzywuzzy's sliding-window approximation.
local function _partial_ratio(a, b)
    if #a == 0 or #b == 0 then return 0 end
    local short, long = a, b
    if #a > #b then short, long = b, a end
    local sl, ll = #short, #long
    if sl == ll then return _ratio(short, long) end
    local best = 0
    for i = 1, ll - sl + 1 do
        local score = _ratio(short, long:sub(i, i + sl - 1))
        if score > best then best = score end
        if best == 100 then break end
    end
    return best
end

-- ─── token helpers ───────────────────────────────────────────────────────────

local function _tokens(s)
    local set = {}
    for tok in s:gmatch("%S+") do set[tok] = true end
    return set
end

-- Sorted, space-joined token string (fuzzywuzzy's _process_and_sort shape).
local function _sortedJoin(token_set)
    local list = {}
    for tok in pairs(token_set) do list[#list + 1] = tok end
    table.sort(list)
    return table.concat(list, " ")
end

-- token_set_ratio: split both into word sets; build the sorted intersection
-- plus each side's sorted remainder, then take the max ratio across the three
-- fuzzywuzzy comparisons. Word-order independent.
local function _token_set_ratio(a, b)
    local ta, tb = _tokens(a), _tokens(b)
    local inter, only_a, only_b = {}, {}, {}
    for tok in pairs(ta) do
        if tb[tok] then inter[tok] = true else only_a[tok] = true end
    end
    for tok in pairs(tb) do
        if not ta[tok] then only_b[tok] = true end
    end
    local s_inter = _sortedJoin(inter)
    local combined_a = (s_inter .. " " .. _sortedJoin(only_a)):gsub("^%s+", ""):gsub("%s+$", "")
    local combined_b = (s_inter .. " " .. _sortedJoin(only_b)):gsub("^%s+", ""):gsub("%s+$", "")
    -- An exact-equal intersection with no remainder on one side is a strong
    -- signal; the three comparisons below capture that the way fuzzywuzzy does.
    return math.max(
        _ratio(s_inter, combined_a),
        _ratio(s_inter, combined_b),
        _ratio(combined_a, combined_b)
    )
end

-- ─── scoring (matcher.py score_match) ────────────────────────────────────────

local function _hasContent(s)
    return type(s) == "string" and s:match("%S") ~= nil
end

-- Returns title_score, author_score in 0..100. Any empty input -> 0,0.
function Match.scoreMatch(epub_title, epub_author, hc_title, hc_author)
    if not (_hasContent(epub_title) and _hasContent(epub_author)
            and _hasContent(hc_title) and _hasContent(hc_author)) then
        return 0, 0
    end
    local et, ea = epub_title:lower(), epub_author:lower()
    local ht, ha = hc_title:lower(), hc_author:lower()
    local title_score  = math.max(_token_set_ratio(et, ht), _partial_ratio(et, ht))
    local author_score = math.max(_token_set_ratio(ea, ha), _partial_ratio(ea, ha))
    return title_score, author_score
end

-- ─── canonical / series heuristics (matcher.py) ──────────────────────────────

local _ADAPTATION_MARKERS = {
    "graphic novel", "graphic novels",
    "on radio", "radio drama",
    "audio drama", "audiobook", "audio book",
}
local _COLLECTION_MARKERS = {
    "omnibus", "box set", "boxed set",
    "collection set", "books collection",
    "complete series", "complete novels",
}

-- Lowercase, trim, drop a leading "the " so "The Culture" == "Culture".
function Match.normaliseSeriesName(name)
    if type(name) ~= "string" or name == "" then return "" end
    local n = name:gsub("^%s+", ""):gsub("%s+$", ""):lower()
    n = n:gsub("^the ", "")
    return n
end

-- True if the hit looks like an adaptation or a multi-book collection, or its
-- title enumerates >= 2 " / "-separated segments (box-set contents shape).
-- Used only to RANK candidates lower / reject a sole non-canonical winner.
function Match.isNonCanonical(title, series_name)
    local hay_title  = (type(title) == "string" and title or ""):lower()
    local hay_series = (type(series_name) == "string" and series_name or ""):lower()
    for _, m in ipairs(_ADAPTATION_MARKERS) do
        if hay_title:find(m, 1, true) or hay_series:find(m, 1, true) then return true end
    end
    for _, m in ipairs(_COLLECTION_MARKERS) do
        if hay_title:find(m, 1, true) or hay_series:find(m, 1, true) then return true end
    end
    local _, slashes = hay_title:gsub(" / ", "")
    if slashes >= 2 then return true end
    return false
end

-- ─── candidate ranking (enrich.py) ───────────────────────────────────────────

-- epub  = { title=, author=, series= }
-- cands = array of { title=, author=, series_name=, ... } (extra fields kept)
-- Returns the chosen candidate table + title_score + author_score, or nil when
-- nothing clears the 80/80 gate (or only a non-canonical hit does).
function Match.pickBest(epub, cands)
    if type(epub) ~= "table" or type(cands) ~= "table" then return nil end
    local epub_series = Match.normaliseSeriesName(epub.series)
    local chosen, chosen_t, chosen_a
    -- key = { series_match, is_canonical, total, length_penalty }, maximised.
    local best = { -1, -1, -1, -(2 ^ 30) }
    local function keyGreater(k)
        for i = 1, 4 do
            if k[i] ~= best[i] then return k[i] > best[i] end
        end
        return false
    end
    for _, c in ipairs(cands) do
        local t, a = Match.scoreMatch(epub.title, epub.author, c.title, c.author)
        if t >= TITLE_THRESHOLD and a >= AUTHOR_THRESHOLD then
            local total = t + a
            local length_penalty = -math.abs(#(epub.title or "") - #(c.title or ""))
            local series_match = (epub_series ~= ""
                and Match.normaliseSeriesName(c.series_name) == epub_series) and 1 or 0
            local is_canonical = Match.isNonCanonical(c.title, c.series_name) and 0 or 1
            local key = { series_match, is_canonical, total, length_penalty }
            if keyGreater(key) then
                best = key
                chosen, chosen_t, chosen_a = c, t, a
            end
        end
    end
    if not chosen then return nil end
    -- Never let an adaptation/collection be the match that writes metadata.
    if Match.isNonCanonical(chosen.title, chosen.series_name) then return nil end
    return chosen, chosen_t, chosen_a
end

Match.TITLE_THRESHOLD  = TITLE_THRESHOLD
Match.AUTHOR_THRESHOLD = AUTHOR_THRESHOLD

return Match
