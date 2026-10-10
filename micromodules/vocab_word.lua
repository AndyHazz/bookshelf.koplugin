--[[
Start-menu module: random vocabulary word from the Vocabulary Builder plugin.

Shows a random word with its dictionary definition (type + acepciones).
Data source: vocabulary_builder.sqlite3 + sdcv (StarDict dictionaries).
Works offline (needs installed dictionaries).

Key design: sdcv is called exactly ONCE per session (at module init), with ALL
uncached words in a single batch. Definitions are cached persistently in
vocab_word_cache.json. Taps serve from cache — zero forks, zero OOM.
]]
local _ = require("lib/bookshelf_i18n").gettext
local Kit = require("lib/bookshelf_module_kit")
local BFont = require("lib/bookshelf_fonts")
local Store = require("lib/bookshelf_settings_store")
local logger = require("logger")
local JSON = require("json")
local LineWidget        = require("ui/widget/linewidget")
local Geom              = require("ui/geometry")
local Blitbuffer        = require("ffi/blitbuffer")
local HorizontalGroup   = require("ui/widget/horizontalgroup")
local HorizontalSpan    = require("ui/widget/horizontalspan")
local UIManager         = require("ui/uimanager")

-- Setting keys
local KEY_ACEPCIONES  = "vocab_word_acepciones"    -- 1, 2, 3, "all"
local KEY_SHOW_TYPE   = "vocab_word_show_type"     -- true/false
local KEY_FONT_SCALE  = "vocab_word_font_scale"    -- 80-150, default 100
local KEY_DICT        = "vocab_word_dict"          -- dictionary bookname or "all"
local CACHE_VERSION   = 7   -- bump to force cache rebuild when data format changes

local function readAcepciones()
    local v = Store.read(KEY_ACEPCIONES, "3")
    if v == "all" then return "all" end
    v = tonumber(v)
    if v and v >= 1 and v <= 3 then return v end
    return 3
end

local function readShowType()
    return Store.read(KEY_SHOW_TYPE, true)
end

local function readFontScale()
    local v = tonumber(Store.read(KEY_FONT_SCALE, 100))
    if v and v >= 80 and v <= 150 then return v end
    return 100
end

local function readSelectedDict()
    return Store.read(KEY_DICT, "all")
end

-- UTF-8 character count (pattern-based, works in LuaJIT)
local function utf8len(s)
    if not s then return 0 end
    local _, count = s:gsub("[\1-\127\194-\244][\128-\191]*", "")
    return count
end

-- Dynamic word size: fixed base, only reduce for very long words (>12 chars).
local function dynamicWordSize(word, base_size)
    local len = utf8len(word)
    if len <= 12 then return base_size end
    if len <= 15 then return math.floor(base_size * 0.9) end
    if len <= 20 then return math.floor(base_size * 0.8) end
    return math.floor(base_size * 0.7)
end

-- Lazy-load heavy modules
local SQ3, DataStorage, lfs

local function ensureDeps()
    if not SQ3 then SQ3 = require("lua-ljsqlite3/init") end
    if not DataStorage then DataStorage = require("datastorage") end
    if not lfs then lfs = require("libs/libkoreader-lfs") end
end

-- ── Dictionary discovery ───────────────────────────────────────
-- Cached list of available dictionaries (scanned once per session)
local _available_dicts = nil

-- Read bookname from a StarDict .ifo file
-- Uses read("*a") + gmatch (same pattern as loadPersistentCache) for KOReader compat
local function readIfoBookname(path)
    local f, err = io.open(path, "r")
    if not f then return nil, err end
    local content = f:read("*a")
    f:close()
    if not content then return nil end
    local bookname = content:match("bookname=([^\n]+)")
    return bookname
end

-- Scan data/dict/ for all available StarDict dictionaries
-- Returns array of { name = "bookname", path = "/full/path/to/file.ifo" }
local function findAvailableDictionaries()
    if _available_dicts then return _available_dicts end
    ensureDeps()
    local dict_dir = DataStorage:getDataDir() .. "/data/dict"
    local attr = lfs.attributes(dict_dir, "mode")
    if attr ~= "directory" then
        _available_dicts = {}
        return _available_dicts
    end

    local ok, result = pcall(function()
        local dicts = {}
        local function addIfo(path)
            local bn = readIfoBookname(path)
            if bn then
                dicts[#dicts + 1] = { name = bn, path = path }
            end
        end

        for file in lfs.dir(dict_dir) do
            if file ~= "." and file ~= ".." then
                local full = dict_dir .. "/" .. file
                local mode = lfs.attributes(full, "mode")
                if mode == "file" and file:match("%.ifo$") then
                    addIfo(full)
                elseif mode == "directory" then
                    local ok_sub, sub_result = pcall(function()
                        for sub in lfs.dir(full) do
                            if sub ~= "." and sub ~= ".." and sub:match("%.ifo$") then
                                addIfo(full .. "/" .. sub)
                            end
                        end
                    end)
                end
            end
        end

        table.sort(dicts, function(a, b) return a.name:lower() < b.name:lower() end)
        return dicts
    end)

    if ok then
        _available_dicts = result
    else
        logger.warn("[vocab_word] dict scan failed:", tostring(result))
        _available_dicts = {}
    end
    return _available_dicts
end

-- ── Persistent definition cache ────────────────────────────────
-- Stores { word -> { word, results: [ { dict, definition_raw, definition }, ... ] } }
-- `results` holds every dictionary that knows this word (one entry per dictionary).
-- The card display picks the result matching the user's selected dictionary;
-- the popup receives the full array so the user can browse all dictionaries.
-- Saves to JSON. Survives KOReader restarts.
-- After batchBuildCache(), all words are cached — sdcv is never called again.
local _def_cache = {}
local _cache_path = nil
local _cache_dirty = false

local function getCachePath()
    if _cache_path then return _cache_path end
    ensureDeps()
    _cache_path = DataStorage:getDataDir() .. "/vocab_word_cache.json"
    return _cache_path
end

local function loadPersistentCache()
    local path = getCachePath()
    local attr = lfs.attributes(path, "mode")
    if attr ~= "file" then
        logger.warn("[vocab_word] no cache file yet:", path)
        return
    end
    local ok, data = pcall(function()
        local f = io.open(path, "r")
        if not f then return nil end
        local content = f:read("*a")
        f:close()
        if not content or content == "" then return nil end
        return JSON.decode(content)
    end)
    if ok and data and type(data) == "table" then
        -- Invalidate cache if format version changed (e.g. results array added)
        local cached_version = data.__cache_version
        if cached_version ~= CACHE_VERSION then
            logger.warn("[vocab_word] cache version mismatch:", tostring(cached_version), "→", CACHE_VERSION, "-- rebuilding")
            _def_cache = {}
            _cache_dirty = true
        else
            _def_cache = data
            -- Remove version key from cache entries (not a word)
            _def_cache.__cache_version = nil
            local n = 0
            for _ in pairs(_def_cache) do n = n + 1 end
            logger.warn("[vocab_word] cache loaded:", n, "words")
        end
    else
        logger.warn("[vocab_word] failed to load cache, starting fresh")
        _def_cache = {}
    end

end

local function savePersistentCache()
    if not _cache_dirty then return end
    local path = getCachePath()
    local ok, err = pcall(function()
        -- Stamp version into cache before saving
        _def_cache.__cache_version = CACHE_VERSION
        local content = JSON.encode(_def_cache)
        _def_cache.__cache_version = nil  -- remove from live cache
        local f = io.open(path, "w")
        if not f then return nil end
        f:write(content)
        f:close()
    end)
    if ok then
        _cache_dirty = false
        local n = 0
        for _ in pairs(_def_cache) do n = n + 1 end
        logger.warn("[vocab_word] cache saved:", n, "words")
    else
        logger.warn("[vocab_word] cache save error:", tostring(err))
    end
end

-- ── Definition parsing ────────────────────────────────────────
-- Handles multiple HTML formats:
--   reader.dict ES: <b>Tipo</b><ol><li>acepción</li></ol>
--   Dictionary es to es: <strong>palabra.</strong><strong>1.</strong> acepción<br/><strong>2.</strong> acepción
--   Plain text (fallback): texto sin HTML

-- Strip HTML tags, preserving newlines from <br/>
local function stripHtmlKeepNewlines(html)
    if not html then return "" end
    local s = html
    s = s:gsub("<br%s*/?>", "\n")
    s = s:gsub("<[^>]+>", "")
    s = s:gsub("&nbsp;", " ") s = s:gsub("&lt;", "<")
    s = s:gsub("&gt;", ">")   s = s:gsub("&amp;", "&")
    s = s:gsub("[ \t]+", " ")  -- collapse horizontal whitespace only
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

-- Strip everything (for plain text fallback)
local function stripHtml(html)
    if not html then return "" end
    local s = html
    s = s:gsub("<br%s*/?>", "\n")
    s = s:gsub("<li>", "• ")
    s = s:gsub("</li>", "\n")
    s = s:gsub("<[^>]+>", "")
    s = s:gsub("&nbsp;", " ")
    s = s:gsub("&lt;", "<")
    s = s:gsub("&gt;", ">")
    s = s:gsub("&amp;", "&")
    s = s:gsub("%s+", " ")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

-- Parse definition HTML to extract word type and acepciones
local function parseDefinition(html)
    if not html or html == "" then return nil end

    -- ── Strategy 1: reader.dict ES format ────────────────────
    -- <b>Tipo</b> + <li>acepción</li>
    local word_type = html:match("<b>([^<]+)</b>")

    local acepciones = {}
    for li in html:gmatch("<li>([^<]*)</li>") do
        local clean = li:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
        if clean and clean ~= "" then
            acepciones[#acepciones + 1] = clean
        end
    end

    -- ── Strategy 2: Dictionary es to es (DRAE) format ────────
    -- <strong>palabra.</strong><p style="background:lightgray;">etimología</p>
    -- <strong>1.</strong> acepción.<br/><strong>2.</strong> acepción.
    if #acepciones == 0 then
        local text = html
        -- Remove word-header <p><strong>word.</strong>
        text = text:gsub("^%s*<p>%s*<strong>[^<]+</strong>", "", 1)
        -- Remove etymology sections (<p style="background:lightgray;">...</p>)
        text = text:gsub("<p[^>]*style=\"[^\"]*lightgray[^\"]*\"[^>]*>.-</p>", "")
        -- Extract numbered definitions from DRAE-style HTML.
        -- Stop when the numbering restarts: that marks locutions/examples.
        local last_num = 0
        local pos = 1
        while true do
            local s, e, num_str = text:find("<strong>(%d+)%.%s*</strong>", pos)
            if not s then break end
            local num = tonumber(num_str)
            if num <= last_num then break end
            last_num = num
            local next_s = text:find("<strong>", e + 1)
            local end_pos = next_s and (next_s - 1) or #text
            local chunk = text:sub(e + 1, end_pos)
            chunk = chunk:gsub("<br%s*/?>", "\n")
            chunk = chunk:gsub("<[^>]+>", "")
            chunk = chunk:gsub("&nbsp;", " "):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&amp;", "&")
            chunk = chunk:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
            if chunk ~= "" then
                acepciones[#acepciones + 1] = chunk
            end
            pos = e + 1
        end

        -- If DRAE extraction failed, fall back to generic <br/> split
        if #acepciones == 0 then
            local clean = stripHtmlKeepNewlines(html)
            if clean and clean ~= "" then
                for line in clean:gmatch("[^\n]+") do
                    line = line:gsub("^%s+", ""):gsub("%s+$", "")
                    if line ~= "" then
                        acepciones[#acepciones + 1] = line
                    end
                end
            end
        end
    end

    -- ── Strategy 3: Plain text fallback ──────────────────────
    if #acepciones == 0 then
        local clean = stripHtml(html)
        if clean and clean ~= "" then
            acepciones[#acepciones + 1] = clean
        end
    end

    -- ── Strategy 4: derive type from grammatical abbreviations ─
    -- Handles Spanish (DRAE: f., m., adj., tr., intr...) and common
    -- English dictionary shorthand (n., v., adj., adv...).
    local TYPE_ABBR_ORDER = { "f.", "m.", "n.", "v.", "adj.", "tr.", "intr.", "adv.", "pron.", "prep.", "conj.", "interj." }
    local TYPE_ABBR_NAMES = {
        ["f."]     = "Sustantivo femenino",
        ["m."]     = "Sustantivo masculino",
        ["n."]     = "Sustantivo",
        ["v."]     = "Verbo",
        ["adj."]   = "Adjetivo",
        ["tr."]    = "Verbo transitivo",
        ["intr."]  = "Verbo intransitivo",
        ["adv."]   = "Adverbio",
        ["pron."]  = "Pronombre",
        ["prep."]  = "Preposición",
        ["conj."]  = "Conjunción",
        ["interj."] = "Interjección",
    }
    if not word_type and #acepciones > 0 then
        local first = acepciones[1]
        for _, raw in ipairs(TYPE_ABBR_ORDER) do
            local escaped = raw:gsub("%.", "%%.")
            if first:match("^" .. escaped) then
                word_type = TYPE_ABBR_NAMES[raw]
                -- Strip the grammatical prefix from every acepción so it
                -- doesn't appear twice (once as type, once in the text).
                for i, a in ipairs(acepciones) do
                    acepciones[i] = a:gsub("^" .. escaped .. "%s*", "")
                end
                break
            end
        end
    end

    return {
        type = word_type,
        acepciones = acepciones,
    }
end

-- Pick the result entry to display on the card.
-- If a specific dictionary is selected, prefer that; otherwise the first result.
local function pickResult(word_data, dict_name)
    if not word_data or not word_data.results then return nil end
    if dict_name and dict_name ~= "all" then
        for _, r in ipairs(word_data.results) do
            if r.dict == dict_name then return r end
        end
    end
    return word_data.results[1]
end

-- ── Batch cache build (ONE sdcv call for all uncached words) ───
-- This is the KEY design decision: instead of calling sdcv per word
-- (which causes OOM from multiple forks), we call it ONCE with all
-- uncached words at module init. After that, everything is from cache.

-- Find sdcv binary
local function findSdcv()
    ensureDeps()
    local data_dir = DataStorage:getDataDir()
    local candidates = {
        data_dir .. "/../base/build/arm64-apple-darwin24.4.0-debug/sdcv",
        data_dir .. "/../base/build/x86_64-linux-debug/sdcv",
        data_dir .. "/sdcv",
    }
    for _, path in ipairs(candidates) do
        local attr = lfs.attributes(path)
        if attr and attr.mode == "file" then
            return path
        end
    end
    return nil
end

-- Parse sdcv concatenated JSON output, respecting bracket depth
-- sdcv outputs separate arrays per word: [{...}][{...}]...
local function parseSDCVChunks(output)
    local results = {}
    local i = 1
    local len = #output

    while i <= len do
        local start = output:find("%[", i)
        if not start then break end

        -- Bracket-counting parser: find matching top-level ]
        local depth = 1
        local in_str = false
        local esc = false
        local j = start + 1

        while j <= len and depth > 0 do
            local ch = output:byte(j)
            if esc then
                esc = false
            elseif ch == 92 then -- backslash
                esc = true
            elseif ch == 34 then -- double quote
                in_str = not in_str
            elseif not in_str then
                if ch == 91 then -- [
                    depth = depth + 1
                elseif ch == 93 then -- ]
                    depth = depth - 1
                end
            end
            j = j + 1
        end

        if depth == 0 then
            local chunk = output:sub(start, j - 1)
            local ok, data = pcall(JSON.decode, chunk)
            if ok and type(data) == "table" then
                for _, item in ipairs(data) do
                    results[#results + 1] = item
                end
            end
        end
        i = j
    end
    return results
end

-- Build cache for all uncached words in ONE sdcv call.
-- Called once at module init.
local function batchBuildCache()
    ensureDeps()
    local db_path = DataStorage:getSettingsDir() .. "/vocabulary_builder.sqlite3"
    if lfs.attributes(db_path, "mode") ~= "file" then
        logger.warn("[vocab_word] no vocab DB yet")
        return
    end

    -- 1. Get ALL words from DB
    local conn = SQ3.open(db_path, "ro")
    local stmt = conn:prepare("SELECT word FROM vocabulary")
    local all_words = {}
    while true do
        local row = stmt:step()
        if not row then break end
        if row[1] and row[1] ~= "" then
            all_words[#all_words + 1] = row[1]
        end
    end
    stmt:close()
    conn:close()

    if #all_words == 0 then
        logger.warn("[vocab_word] empty vocab DB")
        return
    end

    -- 2. Filter already cached + build word set for exact-match filtering
    local word_set = {}
    local uncached = {}
    for _, w in ipairs(all_words) do
        word_set[w] = true
        if not _def_cache[w] then
            uncached[#uncached + 1] = w
        end
    end

    if #uncached == 0 then
        logger.warn("[vocab_word] all words already cached (", #all_words, ")")
        return
    end

    logger.warn("[vocab_word] caching", #uncached, "uncached words:", table.concat(uncached, ", "))

    -- 3. Build sdcv command with all uncached words
    local sdcv = findSdcv()
    if not sdcv then
        logger.warn("[vocab_word] sdcv not found")
        return
    end

    local dict_dir = DataStorage:getDataDir() .. "/data/dict"
    -- Always query every installed dictionary. The user's selected dictionary
    -- only affects which result is shown on the card; the popup can browse all.
    local parts = {
        "'" .. sdcv .. "'",
        "-2", "'" .. dict_dir .. "'",
        "--json",
    }
    parts[#parts + 1] = "--exact-search"
    parts[#parts + 1] = "--non-interactive"
    parts[#parts + 1] = "--utf8-output"
    parts[#parts + 1] = "--"
    for _, w in ipairs(uncached) do
        parts[#parts + 1] = "'" .. w:gsub("'", "'\''") .. "'"
    end
    local cmd = table.concat(parts, " ") .. " 2>/dev/null ; echo"

    -- 4. ONE sdcv call for all uncached words
    local ok_popen, output = pcall(function()
        local handle = io.popen(cmd, "r")
        if not handle then return nil end
        local out = handle:read("*a")
        handle:close()
        return out
    end)

    if not ok_popen or not output or output == "" then
        logger.warn("[vocab_word] batch sdcv failed")
        return
    end

    logger.warn("[vocab_word] batch sdcv output length:", #output)

    -- 5. Parse JSON chunks and cache each definition
    local items = parseSDCVChunks(output)
    local cached_count = 0
    -- Group results by word (sdcv may return multiple dicts per word).
    -- Even with --exact-search some dictionaries return related words
    -- (e.g. "novela" also returns "novelar"); keep only exact matches.
    local word_results = {}
    for _, item in ipairs(items) do
        local word = item.word
        local def_html = item.definition
        local dict_name = item.dict
        if word and def_html and word_set[word] then
            if not word_results[word] then
                word_results[word] = {}
            end
            word_results[word][#word_results[word] + 1] = {
                dict = dict_name or "",
                definition_raw = def_html,
            }
        end
    end

    for word, results_list in pairs(word_results) do
        if not _def_cache[word] then
            -- Parse all definitions from every dictionary.
            local parsed_results = {}
            for _, r in ipairs(results_list) do
                local ok_def, definition = pcall(parseDefinition, r.definition_raw)
                if ok_def and definition then
                    parsed_results[#parsed_results + 1] = {
                        dict = r.dict,
                        definition_raw = r.definition_raw,
                        definition = definition,
                    }
                else
                    logger.warn("[vocab_word] parse failed for '" .. word .. "' (" .. r.dict .. "):", tostring(definition))
                end
            end

            if #parsed_results > 0 then
                _def_cache[word] = {
                    word = word,
                    -- Full results array for card display + DictQuickLookup popup.
                    -- The card picks the entry matching the selected dictionary.
                    results = parsed_results,
                }
                cached_count = cached_count + 1
            end
        end
    end

    if cached_count > 0 then
        _cache_dirty = true
        savePersistentCache()
        logger.warn("[vocab_word] batch cached:", cached_count, "new words")
    end
end

-- ── Fetch from cache (zero sdcv calls at runtime) ─────────────

local VOCAB_TTL_S = 300
local _vocab_cache

-- Debounce: limit taps to 1 every 2 seconds
local TAP_DEBOUNCE_S = 2
local _last_tap_at = 0

-- Word zone tracking: the absolute Y of the word within the cell,
-- used by on_tap to detect taps on the word vs elsewhere.
local _word_zone_y = 0       -- absolute Y of word top in the cell
local _word_zone_h = 0       -- height of the word widget
local _word_zone_padding = 0 -- top padding before the word
local _last_word_data = nil  -- word_data for the currently displayed word

-- Pre-cache queue: smooth rotation between words
local _word_queue = {}
local _prefetch_queue_size = 2
local _refill_busy = false

-- Pick a random word from persistent cache (never calls sdcv)
local function randomCachedWord()
    local keys = {}
    for k, _ in pairs(_def_cache) do
        keys[#keys + 1] = k
    end
    if #keys == 0 then return nil end
    local word = keys[math.random(1, #keys)]
    return _def_cache[word]
end

-- Fetch a word: only from persistent cache. No sdcv.
local function fetchWordFromSDCV()
    local data = randomCachedWord()
    if not data then
        logger.warn("[vocab_word] cache empty")
    end
    return data
end

-- Refill queue: fill from cache only (instant, no sdcv)
local function refillQueue()
    if _refill_busy then return end
    if #_word_queue >= _prefetch_queue_size then return end

    _refill_busy = true
    local data = fetchWordFromSDCV()
    if data then
        _word_queue[#_word_queue + 1] = data
    end
    _refill_busy = false
end

-- High-level fetch: queue → TTL cache → persistent cache
local function fetchRandomWord()
    local now = os.time()

    -- 1. TTL cache (auto-refresh timer)
    if _vocab_cache and _vocab_cache.at and (now - _vocab_cache.at) < VOCAB_TTL_S then
        return _vocab_cache.data
    end

    -- 2. Pre-cache queue (instant rotation)
    if #_word_queue > 0 then
        local data = table.remove(_word_queue, 1)
        _vocab_cache = { at = now, data = data }
        refillQueue()
        return data
    end

    -- 3. Fallback: random from persistent cache (also instant)
    local data = fetchWordFromSDCV()
    if data then
        refillQueue()
    end
    _vocab_cache = { at = now, data = data }
    return data
end

-- ── Text wrapping ──────────────────────────────────────────────

local function wrapText(text, max_chars, max_lines)
    max_lines = max_lines or 2
    if not text or text == "" then return "" end
    local function utf8len(s)
        local _, count = s:gsub("[\1-\127\194-\244][\128-\191]*", "")
        return count
    end
    local function utf8sub(s, i, j)
        local result = {}
        local char_idx = 1
        for _, code in utf8.codes(s) do
            if char_idx >= i and (j == nil or char_idx <= j) then
                result[#result + 1] = utf8.char(code)
            end
            char_idx = char_idx + 1
        end
        return table.concat(result)
    end
    if utf8len(text) <= max_chars then return text end
    local lines, current = {}, ""
    for word in text:gmatch("%S+") do
        local cur_len = utf8len(current)
        local word_len = utf8len(word)
        if cur_len + word_len + 1 > max_chars then
            if current ~= "" then lines[#lines + 1] = current end
            current = word
        else
            current = current == "" and word or (current .. " " .. word)
        end
    end
    if current ~= "" then lines[#lines + 1] = current end
    if #lines > max_lines then
        lines[max_lines] = utf8sub(lines[max_lines], 1, max_chars - 3) .. "…"
        for i = max_lines + 1, #lines do lines[i] = nil end
    end
    return table.concat(lines, "\n")
end

-- ── Settings dialog ────────────────────────────────────────────

local function showSettings(ctx)
    local ButtonDialog = require("ui/widget/buttondialog")
    local function acepcionesBtn(label, value)
        local current = readAcepciones()
        local active = (current == value)
        return {
            text = (active and "\xE2\x9C\x93 " or "  ") .. label,
            callback = function()
                if active then return end
                Store.save(KEY_ACEPCIONES, value)
                UIManager:close(dialog)
                if ctx and ctx.menu and ctx.menu._reload then ctx.menu:_reload() end
                showSettings(ctx)
            end,
        }
    end

    local function typeBtn(label, value)
        local current = readShowType()
        local active = (current == value)
        return {
            text = (active and "\xE2\x9C\x93 " or "  ") .. label,
            callback = function()
                if active then return end
                Store.save(KEY_SHOW_TYPE, value)
                UIManager:close(dialog)
                if ctx and ctx.menu and ctx.menu._reload then ctx.menu:_reload() end
                showSettings(ctx)
            end,
        }
    end

    local function fontScaleBtn(label, delta)
        return {
            text = label,
            callback = function()
                local current = readFontScale()
                local new_val = math.max(80, math.min(150, current + delta))
                if new_val == current then return end
                Store.save(KEY_FONT_SCALE, new_val)
                UIManager:close(dialog)
                if ctx and ctx.menu and ctx.menu._reload then ctx.menu:_reload() end
                showSettings(ctx)
            end,
        }
    end

    local scale = readFontScale()

    -- Dictionary selector buttons
    local dicts = findAvailableDictionaries()
    local current_dict = readSelectedDict()

    local function dictBtn(label, value)
        local active = (current_dict == value)
        return {
            text = (active and "\xE2\x9C\x93 " or "  ") .. label,
            callback = function()
                if active then return end
                Store.save(KEY_DICT, value)
                UIManager:close(dialog)
                if ctx and ctx.menu and ctx.menu._reload then ctx.menu:_reload() end
                showSettings(ctx)
            end,
        }
    end

    local buttons = {
        { { text = _("Acepciones"), enabled = false } },
        { acepcionesBtn(_("1"), 1) },
        { acepcionesBtn(_("2"), 2) },
        { acepcionesBtn(_("3"), 3) },
        { acepcionesBtn(_("All"), "all") },
        { { text = _("Show type"), enabled = false } },
        { typeBtn(_("Yes"), true) },
        { typeBtn(_("No"), false) },
        { { text = _("Font scale") .. ": " .. scale .. "%", enabled = false } },
        { fontScaleBtn("  \xE2\x96\xB2  ", 10) },
        { fontScaleBtn("  \xE2\x96\xBC  ", -10) },
    }

    -- Add dictionary selector
    if #dicts > 0 then
        buttons[#buttons + 1] = { { text = _("Dictionary"), enabled = false } }
        buttons[#buttons + 1] = { dictBtn(_("All dictionaries"), "all") }
        for _, d in ipairs(dicts) do
            buttons[#buttons + 1] = { dictBtn(d.name, d.name) }
        end
    end

    dialog = ButtonDialog:new{
        title        = _("Vocab Word"),
        title_align  = "center",
        width_factor = 0.75,
        buttons      = buttons,
    }
    UIManager:show(dialog)
end

-- ── Module init ────────────────────────────────────────────────

-- Load cache + batch-build any missing definitions (ONE sdcv call total)
ensureDeps()
loadPersistentCache()
batchBuildCache()

return {
    key = "vocab_word",
    title = _("Vocab Word"),
    summary = _("From Vocabulary Builder + dictionary. Works offline."),

    render = function(ctx)
        local width, scale_pct = ctx.width, ctx.scale
        local user_scale = readFontScale()
        local sc = Kit.sc(scale_pct * user_scale / 100)
        local show_type = readShowType()
        local max_acepciones = readAcepciones()

        local word_data = fetchRandomWord()

        if not word_data then
            local TextWidget = require("ui/widget/textwidget")
            return TextWidget:new{
                text = _("No vocab words yet"),
                face = Kit.face(14, scale_pct, {italic = true}),
                width = width,
                fgcolor = Kit.COLOR_MUTED,
                bgcolor = Kit.CARD_BG,
            }
        end

        local VerticalGroup = require("ui/widget/verticalgroup")
        local VerticalSpan = require("ui/widget/verticalspan")
        local TextWidget = require("ui/widget/textwidget")
        local TextBoxWidget = require("ui/widget/textboxwidget")

        local selected = pickResult(word_data, readSelectedDict())
        local def = selected and selected.definition
        local dict_name = selected and selected.dict

        local word_size = dynamicWordSize(word_data.word, 28)
        local word_face, word_bold = BFont:getFace("Inter-ExtraBold.ttf", sc(word_size))
        local type_face, type_bold = BFont:getFace("Caveat-Regular.ttf", sc(18), { italic = true })
        local dict_face, dict_bold = BFont:getFace("Caveat-Regular.ttf", sc(11), { italic = true })
        local def_face, def_bold = BFont:getFace("infofont", sc(12))

        local items = {
            align = "left",
            dimen = { w = width, h = 0 },
            VerticalSpan:new{ dimen = { w = 1, h = sc(4) } },
        }

        -- Word row: plain widget (tap region is handled by on_tap via ctx.tap_pos)
        local current_word = word_data.word

        local word_widget = TextWidget:new{
            text = current_word,
            face = word_face,
            bold = word_bold,
            fgcolor = Kit.COLOR_PRIMARY,
            bgcolor = Kit.CARD_BG,
            alignment = "left",
        }

        local word_size = word_widget:getSize()

        -- Store absolute word zone for tap detection in on_tap.
        -- The word sits at cell_y + sc(4) padding from the top of the card.
        _word_zone_y = 0  -- will be set after we know cell position
        _word_zone_h = word_size.h
        _word_zone_padding = sc(4)
        _last_word_data = word_data

        local spacer_w = math.max(0, width - word_size.w)

        local word_row = HorizontalGroup:new{
            dimen = Geom:new{ w = width, h = 0 },
            word_widget,
            HorizontalSpan:new{ width = spacer_w },
        }

        items[#items + 1] = word_row
        items[#items + 1] = VerticalSpan:new{ dimen = { w = 1, h = sc(1) } }
        items[#items + 1] = LineWidget:new{
            dimen = Geom:new{ w = word_size.w, h = 1 },
            background = Blitbuffer.gray(0.3),
        }

        -- Prepare optional type/dict widgets so we can measure their height
        -- before deciding how much room is left for the definitions.
        local type_widget
        if show_type and def and def.type then
            type_widget = TextWidget:new{
                text = def.type,
                face = type_face,
                bold = type_bold,
                width = width,
                fgcolor = Kit.COLOR_MUTED,
                bgcolor = Kit.CARD_BG,
                alignment = "left",
            }
        end

        local dict_row
        if dict_name and dict_name ~= "" then
            local dict_widget = TextWidget:new{
                text = dict_name,
                face = dict_face,
                bold = dict_bold,
                fgcolor = Kit.COLOR_MUTED,
                bgcolor = Kit.CARD_BG,
                alignment = "right",
            }
            local dict_w = dict_widget:getSize().w
            local dict_spacer = HorizontalSpan:new{ width = math.max(0, width - dict_w) }
            dict_row = HorizontalGroup:new{
                dimen = Geom:new{ w = width, h = 0 },
                dict_spacer,
                dict_widget,
            }
        end

        if type_widget then
            items[#items + 1] = VerticalSpan:new{ dimen = { w = 1, h = sc(2) } }
            items[#items + 1] = type_widget
        end

        if def and def.acepciones and #def.acepciones > 0 then
            items[#items + 1] = VerticalSpan:new{ dimen = { w = 1, h = sc(6) } }

            local max_chars = math.floor(width / (sc(12) * 0.45))
            if max_chars < 30 then max_chars = 30 end

            local limit = max_acepciones == "all" and #def.acepciones or max_acepciones

            local shown = {}
            for i = 1, math.min(limit, #def.acepciones) do
                local acep = wrapText(def.acepciones[i], max_chars, 2)
                if acep ~= "" then
                    shown[#shown + 1] = i .. ". " .. acep
                end
            end

            if #shown > 0 then
                items[#items + 1] = TextBoxWidget:new{
                    text = table.concat(shown, "\n"),
                    face = def_face,
                    bold = def_bold,
                    width = width,
                    fgcolor = Kit.COLOR_MUTED,
                    bgcolor = Kit.CARD_BG,
                    alignment = "left",
                }
            end
        end

        -- Source dictionary: small, right-aligned attribution at the bottom.
        if dict_row then
            items[#items + 1] = VerticalSpan:new{ dimen = { w = 1, h = sc(3) } }
            items[#items + 1] = dict_row
        end

        items[#items + 1] = VerticalSpan:new{ dimen = { w = 1, h = sc(4) } }

        return VerticalGroup:new(items)
    end,

    on_tap = function(ctx)
        -- Debounce
        local now = os.time()
        if now - _last_tap_at < TAP_DEBOUNCE_S then return end

        -- Check if tap is on the word zone (top of the card)
        -- If so, show the DictQuickLookup popup with full dictionary results.
        -- Otherwise, advance to next word.
        if ctx.tap_pos and ctx.cell_dimen and _last_word_data then
            local tap_y = ctx.tap_pos.y
            local cell_y = ctx.cell_dimen.y
            -- Word zone: cell_y + padding ... cell_y + padding + word_height
            local word_top = cell_y + _word_zone_padding
            local word_bottom = word_top + _word_zone_h
            if tap_y >= word_top and tap_y <= word_bottom then
                -- Build results array for DictQuickLookup from cached multi-dict data
                local word = _last_word_data.word
                local cached_results = _last_word_data.results

                local dict_results
                if cached_results and #cached_results > 0 then
                    -- Build DictQuickLookup results from every cached dictionary.
                    -- Put the currently selected dictionary first so the popup
                    -- opens on the same definition shown on the card.
                    dict_results = {}
                    local selected_dict = readSelectedDict()
                    for pass = 1, 2 do
                        for _, r in ipairs(cached_results) do
                            local is_selected = (selected_dict == "all" or r.dict == selected_dict)
                            if (pass == 1 and is_selected) or (pass == 2 and not is_selected) then
                                dict_results[#dict_results + 1] = {
                                    dict = r.dict,
                                    word = word,
                                    definition = r.definition_raw or "",
                                    is_html = true,
                                }
                            end
                        end
                    end
                else
                    -- Fallback: cache entry is from old version without 'results'.
                    -- Reconstruct from parsed data.
                    local def = _last_word_data.definition
                    local lines = {}
                    if def and def.type then
                        lines[#lines + 1] = def.type
                    end
                    if def and def.acepciones and #def.acepciones > 0 then
                        for i, a in ipairs(def.acepciones) do
                            lines[#lines + 1] = i .. ". " .. a
                        end
                    end
                    local plain_text = table.concat(lines, "\n")
                    if plain_text == "" then
                        plain_text = _("(definition not available)")
                    end
                    dict_results = {
                        {
                            dict = _last_word_data.dict or "",
                            word = word,
                            definition = plain_text,
                            is_html = false,
                        },
                    }
                end

                -- Import DictQuickLookup lazily
                local DictQuickLookup = require("ui/widget/dictquicklookup")
                -- Pass ui = nil so DictQuickLookup disables all ui-dependent
                -- buttons (menu icon, search, highlight, wikipedia) and avoids crashes.
                local dict_popup = DictQuickLookup:new{
                    word = word,
                    ui = nil,
                    results = dict_results,
                    -- Override: disable text selection callbacks that crash without ui
                    onHoldStartText = function() end,
                    onHoldPanText = function() end,
                    onHoldReleaseText = function() end,
                }
                -- Disable edit button callback (pencil icon crashes without ui)
                dict_popup.onLookupInputWord = function() end
                UIManager:show(dict_popup)
                _last_tap_at = now
                return true
            end
        end

        -- Tap outside word zone: advance to next word
        _last_tap_at = now
        _vocab_cache = nil
    end,

    show_settings = showSettings,
    keep_open = true,
}
