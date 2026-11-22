--[[
Start-menu module: a random vocabulary word from the Vocabulary Builder.

Shows one word from KOReader's vocabulary_builder.sqlite3 with its dictionary
definition (type + senses), the sentence it was looked up in (as captured by
the Vocabulary Builder itself) and the book it came from. Data source:
vocabulary_builder.sqlite3 (read-only) + sdcv (the installed StarDict
dictionaries). Works offline; needs at least one dictionary installed.

Rotation is a shuffled deck, so no word repeats until every one has been
shown; with "Review-due words first" on (default), words whose Vocabulary
Builder SRS due_time has passed come first. "✓ I know it" removes a word from
the deck (persistent, resettable from the module settings).

Key design: sdcv is called exactly ONCE per session, with ALL uncached words
in a single batch (--utf8-input/output: a locale-less Kobo cannot convert
non-ASCII queries without --utf8-input, so every accented word would fail to
cache and never enter the rotation), over the same dict folders KOReader's
own dictionary searches (data/dict + data/dict_ext). Definitions — and the
misses: a word no dictionary knows is cached empty, so the batch never
re-runs for it (until the installed dictionary set changes, when cached
misses are dropped for a re-check) — live persistently in
vocab_word_cache.json; after the batch every tap serves from cache — zero
forks, zero OOM. The heavy init (sqlite reads + that one sdcv batch) runs
lazily on the FIRST render, never at module load: this file must load in
standalone Lua (the headless contract test dofiles every micromodules/*.lua
with only logger/i18n stubbed), and a blocking load would freeze the menu.

Taps: the word line hands off to the file browser's own dictionary
(filemanager.instance.dictionary:onLookupWord), which opens the full
DictQuickLookup popup with working buttons, exactly as a lookup from the
reader gets it; "✓ I know it" marks the word; anywhere else advances. Tap
zones are declared via ctx.set_tap_regions.
]]
local _ = require("lib/bookshelf_i18n").gettext
local logger = require("logger")

-- Setting keys (module-settings convention: micromodule_<key>_<setting>)
local KEY_SENSES     = "micromodule_vocab_word_senses"      -- 1, 2, 3, "all"
local KEY_SHOW_TYPE  = "micromodule_vocab_word_show_type"   -- true/false
local KEY_DICT       = "micromodule_vocab_word_dict"         -- dictionary bookname or "all"
local KEY_SHOW_CTX   = "micromodule_vocab_word_show_context" -- true: show the book sentence where the word was looked up
local KEY_PREFER_DUE = "micromodule_vocab_word_prefer_due"   -- true: SRS review-due words come first in the deck
local CACHE_VERSION  = 8   -- bump to force cache rebuild when data format changes
                            -- (8: no more definition_raw in results; misses cached)

-- Lazy requires: nothing below this point loads at module load time. The
-- settings store is reached through this shim, and Kit/BFont/widgets are
-- required inside render/settings (see the header note on standalone load).
local function store() return require("lib/bookshelf_settings_store") end

local lazyInit  -- forward-declared; defined near the end of the file

local function readAcepciones()
    local v = store().read(KEY_SENSES, "3")
    if v == "all" then return "all" end
    v = tonumber(v)
    if v and v >= 1 and v <= 3 then return v end
    return 3
end

local function readShowType()
    return store().read(KEY_SHOW_TYPE, true)
end

local function readSelectedDict()
    return store().read(KEY_DICT, "all")
end

-- Prefer words due for SRS review (Vocabulary Builder's due_time) first.
local function readPreferDue()
    return store().read(KEY_PREFER_DUE, true) ~= false
end

-- Show the sentence from the book where the word was looked up.
local function readShowContext()
    return store().read(KEY_SHOW_CTX, true) ~= false
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

-- Lazy-load heavy modules (JSON lives here too: the cache is JSON on disk)
local SQ3, DataStorage, lfs, JSON

local function ensureDeps()
    if not SQ3 then SQ3 = require("lua-ljsqlite3/init") end
    if not DataStorage then DataStorage = require("datastorage") end
    if not lfs then lfs = require("libs/libkoreader-lfs") end
    if not JSON then JSON = require("json") end
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

-- Scan the dict folders KOReader's own dictionary searches (data/dict +
-- data/dict_ext) for all available StarDict dictionaries.
-- Returns array of { name = "bookname", path = "/full/path/to/file.ifo" }
local function findAvailableDictionaries()
    if _available_dicts then return _available_dicts end
    ensureDeps()
    local data_dir = DataStorage:getDataDir()
    local dict_dirs = { data_dir .. "/data/dict" }
    if lfs.attributes(data_dir .. "/data/dict_ext", "mode") == "directory" then
        dict_dirs[#dict_dirs + 1] = data_dir .. "/data/dict_ext"
    end

    local ok, result = pcall(function()
        local dicts = {}
        local function addIfo(path)
            local bn = readIfoBookname(path)
            if bn then
                dicts[#dicts + 1] = { name = bn, path = path }
            end
        end

        for _, dict_dir in ipairs(dict_dirs) do
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
-- Stores { word -> { word, results: [ { dict, definition }, ... ] } }
-- `results` holds every dictionary that knows this word (one entry per
-- dictionary); a word NO dictionary knows is stored with results = {} (a
-- cached miss, so the batch never re-runs for it). The card display picks
-- the result matching the user's selected dictionary; the popup is a live
-- onLookupWord, so no raw HTML is kept.
-- Saves to JSON. Survives KOReader restarts.
-- After batchBuildCache(), all words are cached — sdcv is never called again.
local _def_cache = {}
local _cache_path = nil
local _cache_dirty = false
-- Dictionary names the cached misses were looked up under, and the ones
-- installed at the last batch (stamped into the cache on save; misses are
-- dropped on load when the set changed, so a newly installed dictionary
-- gets a chance at words it might know).
local _cache_dicts = nil
local _batch_dicts = nil

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
        logger.dbg("[vocab_word] no cache file yet:", path)
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
            logger.dbg("[vocab_word] cache version mismatch:", tostring(cached_version), "→", CACHE_VERSION, "-- rebuilding")
            _def_cache = {}
            _cache_dicts = nil
            _cache_dirty = true
        else
            _def_cache = data
            -- Remove version key from cache entries (not a word)
            _def_cache.__cache_version = nil
            _cache_dicts = type(data.__dicts) == "table" and data.__dicts or nil
            _def_cache.__dicts = nil
            local n = 0
            for _ in pairs(_def_cache) do n = n + 1 end
            logger.dbg("[vocab_word] cache loaded:", n, "words")
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
        -- Stamp version (and the dictionary names the misses were cached
        -- under) into the cache before saving
        _def_cache.__cache_version = CACHE_VERSION
        _def_cache.__dicts = _batch_dicts
        local content = JSON.encode(_def_cache)
        _def_cache.__cache_version = nil  -- remove from live cache
        _def_cache.__dicts = nil
        local f = io.open(path, "w")
        if not f then return nil end
        f:write(content)
        f:close()
    end)
    if ok then
        _cache_dirty = false
        local n = 0
        for _ in pairs(_def_cache) do n = n + 1 end
        logger.dbg("[vocab_word] cache saved:", n, "words")
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

-- Grammatical abbreviations worth relaying as the type (Spanish DRAE and
-- common English shorthand).
local TYPE_ABBR_ORDER = { "f.", "m.", "n.", "v.", "adj.", "tr.", "intr.", "adv.", "pron.", "prep.", "conj.", "interj." }

-- Parse definition HTML to extract the type and the senses. The type is
-- relayed AS THE DICTIONARY PRINTS IT — its own localized label
-- ("Sustantivo", "Nom") or its own grammatical abbreviation ("m.", "n.") —
-- never translated to another language.
local function parseDefinition(html, word)
    if not html or html == "" then return nil end

    -- ── Strategy 1: reader.dict ES format ────────────────────
    -- <b>Tipo</b> + <li>acepción</li>. Some dictionaries (DIEC) put the
    -- word itself in the first <b>: that is a header, not a type.
    local word_type = html:match("<b>([^<]+)</b>")
    if word_type and word and word_type:lower() == word:lower() then
        word_type = nil
    end

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
                    local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
                    if trimmed ~= "" then
                        acepciones[#acepciones + 1] = trimmed
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

    -- ── Strategy 4: relay the grammatical abbreviation ──────
    -- DRAE-style and English dictionaries mark the type as a leading
    -- abbreviation in the sense text ("m.", "com.", "n.", "v."...). Show
    -- the dictionary's own abbreviation as the type, and strip it from
    -- the senses so it doesn't appear twice.
    if not word_type and #acepciones > 0 then
        local first = acepciones[1]
        for _, abbr in ipairs(TYPE_ABBR_ORDER) do
            local escaped = abbr:gsub("%.", "%%.")
            if first:match("^" .. escaped) then
                word_type = abbr
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

-- sdcv, where KOReader's own dictionary finds it: the binary bundled in
-- the install folder (the process runs with its cwd there), or the Android
-- native library. Mirrors readerdictionary.lua.
local function findSdcv()
    if android and android.nativeLibraryDir then
        return android.nativeLibraryDir .. "/libsdcv.so"
    end
    return "./sdcv"
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
        logger.dbg("[vocab_word] no vocab DB yet")
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
        logger.dbg("[vocab_word] empty vocab DB")
        return
    end

    -- Drop cached misses when the installed dictionary set changed (or an
    -- older cache never recorded it): a word that missed before a
    -- dictionary was installed deserves a re-check. They re-enter the
    -- batch as uncached below. findAvailableDictionaries() is memoized.
    local names_now = {}
    for _, d in ipairs(findAvailableDictionaries()) do
        names_now[#names_now + 1] = d.name
    end
    local dicts_changed = (_cache_dicts == nil)
    if _cache_dicts then
        if #_cache_dicts ~= #names_now then
            dicts_changed = true
        else
            for i, name in ipairs(_cache_dicts) do
                if name ~= names_now[i] then dicts_changed = true break end
            end
        end
    end
    if dicts_changed then
        local dropped = 0
        for w, entry in pairs(_def_cache) do
            if entry.results and #entry.results == 0 then
                _def_cache[w] = nil
                dropped = dropped + 1
            end
        end
        if dropped > 0 then
            _cache_dirty = true
            logger.dbg("[vocab_word] dictionary set changed: dropped",
                dropped, "cached misses for a re-check")
        end
    end
    _batch_dicts = names_now

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
        logger.dbg("[vocab_word] all words already cached (", #all_words, ")")
        return
    end

    logger.dbg("[vocab_word] caching", #uncached, "uncached words:", table.concat(uncached, ", "))

    -- 3. Build the batch: same binary and folders KOReader's own
    -- dictionary uses (data/dict + data/dict_ext when the latter exists).
    local sdcv = findSdcv()
    if not sdcv then
        logger.warn("[vocab_word] sdcv not found")
        return
    end

    local data_dir = DataStorage:getDataDir()
    local dict_dirs = { data_dir .. "/data/dict" }
    if lfs.attributes(data_dir .. "/data/dict_ext", "mode") == "directory" then
        dict_dirs[#dict_dirs + 1] = data_dir .. "/data/dict_ext"
    end

    -- Query every installed dictionary. The user's selected dictionary
    -- only affects which result is shown on the card.
    local any_success = false
    local word_results = {}
    for _, dict_dir in ipairs(dict_dirs) do
        local parts = {
            "'" .. sdcv .. "'",
            "-2", "'" .. dict_dir .. "'",
            "--json",
        }
        parts[#parts + 1] = "--exact-search"
        parts[#parts + 1] = "--non-interactive"
        parts[#parts + 1] = "--utf8-output"
        -- Without --utf8-input, sdcv on a locale-less device (Kobo) cannot
        -- convert non-ASCII queries ("Can not convert … to utf8"), so every
        -- accented word fails to cache and never enters the random rotation.
        parts[#parts + 1] = "--utf8-input"
        parts[#parts + 1] = "--"
        for _, w in ipairs(uncached) do
            parts[#parts + 1] = "'" .. w:gsub("'", "'\''") .. "'"
        end
        local cmd = table.concat(parts, " ") .. " 2>/dev/null ; echo"

        local ok_popen, output = pcall(function()
            local handle = io.popen(cmd, "r")
            if not handle then return nil end
            local out = handle:read("*a")
            handle:close()
            return out
        end)

        -- The trailing "; echo" in cmd makes the output non-empty even
        -- when sdcv itself produced nothing, so the success test is a
        -- literal "[": a healthy sdcv answers in JSON arrays, a crashed
        -- one leaves only the echo's newline.
        if ok_popen and output and output:find("[", 1, true) then
            any_success = true
            logger.dbg("[vocab_word] batch sdcv output length:", #output)
            -- Group results by word (sdcv may return multiple dicts per word).
            -- Even with --exact-search some dictionaries return related words
            -- (e.g. "novela" also returns "novelar"); keep only exact matches.
            for _, item in ipairs(parseSDCVChunks(output)) do
                local word = item.word
                local def_html = item.definition
                if word and def_html and word_set[word] then
                    local list = word_results[word]
                    if not list then
                        list = {}
                        word_results[word] = list
                    end
                    list[#list + 1] = { dict = item.dict or "", definition_raw = def_html }
                end
            end
        else
            logger.warn("[vocab_word] batch sdcv failed for", dict_dir)
        end
    end

    -- 4. Parse and cache each definition (no raw HTML kept: the popup
    -- re-queries live via onLookupWord, so the cache stores only what
    -- the card itself displays).
    local cached_count = 0
    for word, results_list in pairs(word_results) do
        if not _def_cache[word] then
            local parsed_results = {}
            for _, r in ipairs(results_list) do
                local ok_def, definition = pcall(parseDefinition, r.definition_raw, word)
                if ok_def and definition then
                    parsed_results[#parsed_results + 1] = {
                        dict = r.dict,
                        definition = definition,
                    }
                else
                    logger.warn("[vocab_word] parse failed for '" .. word .. "' (" .. r.dict .. "):", tostring(definition))
                end
            end

            if #parsed_results > 0 then
                _def_cache[word] = {
                    word = word,
                    -- Full results array for card display.
                    -- The card picks the entry matching the selected dictionary.
                    results = parsed_results,
                }
                cached_count = cached_count + 1
            end
        end
    end

    -- 5. Cache the misses too: a word no dictionary knows stays cached
    -- (empty results), so the one-time batch never re-runs for it in
    -- later sessions. Only when sdcv actually answered: a failed run
    -- must not poison the cache. The deck skips entries with no results.
    local miss_count = 0
    if any_success then
        for _, w in ipairs(uncached) do
            if not _def_cache[w] then
                _def_cache[w] = { word = w, results = {} }
                miss_count = miss_count + 1
            end
        end
    end

    if cached_count > 0 or miss_count > 0 then
        _cache_dirty = true
        savePersistentCache()
        logger.dbg("[vocab_word] batch cached:", cached_count, "new words,",
            miss_count, "misses")
    end
end

-- ── Vocabulary DB metadata (context, book, SRS) ────────────────
-- Per-word info from KOReader's own vocabulary_builder.sqlite3: the
-- sentence where the word was looked up (prev/next context), the book it
-- came from, and the SRS review data (due_time). Read-only: this module
-- never writes to the Vocabulary Builder DB.

local _vocab_meta = {}

local function loadVocabMeta()
    ensureDeps()
    local db_path = DataStorage:getSettingsDir() .. "/vocabulary_builder.sqlite3"
    if lfs.attributes(db_path, "mode") ~= "file" then return end
    local conn = SQ3.open(db_path, "ro")
    local ok, err = pcall(function()
        local stmt = conn:prepare([[
            SELECT v.word, v.prev_context, v.next_context, v.due_time,
                   v.review_count, v.streak_count, t.name
            FROM vocabulary v LEFT JOIN title t ON t.id = v.title_id
        ]])
        while true do
            local row = stmt:step()
            if not row then break end
            local w = row[1]
            if w and w ~= "" then
                local prev, nxt = row[2], row[3]
                local ctx = nil
                if (prev and prev ~= "") or (nxt and nxt ~= "") then
                    ctx = ((prev or "") .. w .. (nxt or "")):gsub("[%c%s]+", " ")
                end
                local book = row[7]
                _vocab_meta[w] = {
                    book = (type(book) == "string" and book ~= "" and book) or nil,
                    context = (ctx ~= nil and ctx ~= "" and ctx) or nil,
                    due = tonumber(row[4]),
                    reviews = tonumber(row[5]) or 0,
                    streak = tonumber(row[6]) or 0,
                }
            end
        end
        stmt:close()
    end)
    if not ok then
        logger.warn("[vocab_word] vocab meta load failed:", tostring(err))
    end
    conn:close()
    local n = 0
    for _ in pairs(_vocab_meta) do n = n + 1 end
    logger.dbg("[vocab_word] vocab meta loaded:", n, "words")
end

-- ── Fetch from cache (zero sdcv calls at runtime) ─────────────

local VOCAB_TTL_S = 300
local _vocab_cache

-- Debounce: limit taps to 1 every 2 seconds
local TAP_DEBOUNCE_S = 2
local _last_tap_at = 0

local _last_word_data = nil  -- word_data for the currently displayed word

-- Pre-cache queue: smooth rotation between words
local _word_queue = {}
local _prefetch_queue_size = 2
local _refill_busy = false

-- ── Word rotation: a shuffled deck, no repeats until exhausted ──
-- Words marked "✓ I know it" are excluded. With "review-due first" ON,
-- words whose Vocabulary Builder SRS due_time has passed come first
-- (still shuffled within each group). When the deck runs out it is
-- rebuilt and reshuffled.

local _rng_seeded = false
local _deck = {}
local _known = {}
local _known_store = nil

local function knownCount()
    local n = 0
    for _ in pairs(_known) do n = n + 1 end
    return n
end

local function loadKnownWords()
    if not _known_store then
        _known_store = require("lib/bookshelf_module_kit").moduleStore("vocab_word")
    end
    local stored = _known_store:get("known")
    if type(stored) == "table" then _known = stored end
    if knownCount() > 0 then
        logger.dbg("[vocab_word] known words loaded:", knownCount())
    end
end

local function markWordKnown(word)
    if not word or _known[word] then return end
    _known[word] = true
    if _known_store then _known_store:set("known", _known) end
end

local function purgeQueueWord(word)
    for i = #_word_queue, 1, -1 do
        if _word_queue[i].word == word then table.remove(_word_queue, i) end
    end
end

-- Why the card has little or nothing to show, or nil when Vocabulary
-- Builder is collecting words: "plugin_off" (the plugin is disabled, so
-- nothing is saved at all) or "auto_off" (lookups are saved only through
-- the dictionary popup's "Add to vocabulary builder" button).
local function vocabStatus()
    local G = rawget(_G, "G_reader_settings")
    if not G then return nil end
    local disabled = G:readSetting("plugins_disabled")
    if type(disabled) == "table" and disabled.vocabbuilder then return "plugin_off" end
    local vb = G:readSetting("vocabulary_builder")
    if type(vb) == "table" and not vb.enabled then return "auto_off" end
    return nil
end

-- Words the card can show (a dictionary knows them), known ones included.
local function usableWordCount()
    local n = 0
    for _, entry in pairs(_def_cache) do
        if entry.results and #entry.results > 0 then n = n + 1 end
    end
    return n
end

-- The hint the card shows instead of a word, or nil to show a word. With
-- the plugin off the deck can never grow; with one word a tap has nothing
-- to move on to, so it says how to collect more.
local function hintText(status, count)
    local how_plugin = _("Turn on Vocabulary builder in Tools > More tools > Plugin management, then words you look up while reading appear here.")
    local how_auto = _("To save every word you look up, turn on Auto add new words in Vocabulary builder's menu (search menu > Vocabulary builder).")
    if status == "plugin_off" then return how_plugin end
    if count == 0 then
        if status == "auto_off" then
            return _("Look up words while reading to fill this card.") .. " " .. how_auto
        end
        return _("Look up words while reading to fill this card.")
    end
    if count == 1 and status == "auto_off" then
        return _("Only one word saved so far.") .. " " .. how_auto
    end
    return nil
end

-- Is a word due for review according to Vocabulary Builder's SRS data?
local function isDueForReview(word)
    local m = _vocab_meta[word]
    return m ~= nil and m.due ~= nil and m.due <= os.time()
end

local function shuffleArray(t)
    for i = #t, 2, -1 do
        local j = math.random(i)
        t[i], t[j] = t[j], t[i]
    end
end

local function rebuildDeck()
    -- Nothing in KOReader seeds math.random (frontend/random.lua is never
    -- required), so without an explicit seed the "random" sequence repeats
    -- identically after every restart of KOReader.
    if not _rng_seeded then
        math.randomseed(os.time())
        _rng_seeded = true
    end
    local due, rest = {}, {}
    local prefer_due = readPreferDue()
    for w, entry in pairs(_def_cache) do
        -- Misses (no dictionary knows the word) stay out of the deck.
        if entry.results and #entry.results > 0 and not _known[w] then
            if prefer_due and isDueForReview(w) then
                due[#due + 1] = w
            else
                rest[#rest + 1] = w
            end
        end
    end
    shuffleArray(due)
    shuffleArray(rest)
    for i = 1, #due do _deck[i] = due[i] end
    for i = 1, #rest do _deck[#_deck + 1] = rest[i] end
    logger.dbg("[vocab_word] deck rebuilt:", #due, "due /", #rest, "later")
end

-- Draw the next word from the deck; rebuilds (reshuffles) when it runs
-- out. Never repeats the word currently on display if the deck has any
-- other word left.
local function drawNextWord(current)
    if #_deck == 0 then rebuildDeck() end
    if #_deck == 0 then
        -- Everything marked known: fall back to any cached word so the
        -- card never goes blank.
        local keys = {}
        for k, entry in pairs(_def_cache) do
            if entry.results and #entry.results > 0 then keys[#keys + 1] = k end
        end
        if #keys == 0 then return nil end
        return _def_cache[keys[math.random(1, #keys)]]
    end
    if #_deck > 1 and _deck[1] == current then
        _deck[1], _deck[2] = _deck[2], _deck[1]
    end
    local word = table.remove(_deck, 1)
    return _def_cache[word]
end

-- Pick the next word to display: drawn from the deck (cache only. No sdcv).
local function pickNextWord()
    local data = drawNextWord(_last_word_data and _last_word_data.word)
    if not data then
        logger.dbg("[vocab_word] cache empty")
    end
    return data
end

-- Refill queue: fill from cache only (instant, no sdcv)
local function refillQueue()
    if _refill_busy then return end
    if #_word_queue >= _prefetch_queue_size then return end

    _refill_busy = true
    local data = pickNextWord()
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
        -- Never hand out the word that is currently on display (the queue
        -- may still hold it if the deck was rebuilt between prefetch and
        -- display, e.g. across an exhausted-deck boundary).
        local prev_word = _last_word_data and _last_word_data.word
        local data = nil
        while #_word_queue > 0 and not data do
            local cand = table.remove(_word_queue, 1)
            if not cand.word or cand.word ~= prev_word then data = cand end
        end
        if not data then data = pickNextWord() end
        _vocab_cache = { at = now, data = data }
        refillQueue()
        return data
    end

    -- 3. Fallback: draw from the deck (also instant)
    local data = pickNextWord()
    if data then
        refillQueue()
    end
    _vocab_cache = { at = now, data = data }
    return data
end

-- ── Settings dialog ────────────────────────────────────────────

local function showSettings(ctx)
    lazyInit()
    local Kit = require("lib/bookshelf_module_kit")
    local T = require("ffi/util").template
    local dialog

    -- The standard pick-landed triple (close the dialog, reload the menu
    -- beneath so the card re-renders, re-open so the checkmarks refresh),
    -- via Kit's shared helper.
    local function picked()
        Kit.settingsReopen(ctx, dialog, showSettings)
    end

    -- Radio row for a stored setting: reads `key` (default `default`),
    -- saves `value` when a different row is picked.
    local function radioBtn(key, label, value, default)
        local current = store().read(key, default)
        return Kit.radioRow{
            label = label,
            -- tostring: Senses shown stores 1-3 as numbers but defaults
            -- to the string "3", which never matched the number 3 row.
            active = (tostring(current) == tostring(value)),
            on_pick = function()
                if tostring(current) == tostring(value) then return end
                store().save(key, value)
                picked()
            end,
        }
    end

    -- Toggle row for a stored true/false setting (default on): a checkmark,
    -- and a tap flips it.
    local function toggleBtn(key, label)
        local on = store().read(key, true) == true
        return Kit.radioRow{
            label = label, active = on, toggle = true,
            on_pick = function()
                store().save(key, not on)
                picked()
            end,
        }
    end

    local function resetKnownBtn()
        local n = knownCount()
        return {
            text = T(_("Reset known words (%1)"), n),
            enabled = n > 0,
            callback = function()
                _known = {}
                if _known_store then _known_store:set("known", {}) end
                _deck = {}
                picked()
            end,
        }
    end

    -- One heading, then that setting's choices side by side on one row, as
    -- the other modules' settings are laid out.
    local function heading(text) return { { text = text, enabled = false } } end
    local buttons = {
        heading(_("Senses shown")),
        { radioBtn(KEY_SENSES, "1", 1, "3"), radioBtn(KEY_SENSES, "2", 2, "3"),
          radioBtn(KEY_SENSES, "3", 3, "3"), radioBtn(KEY_SENSES, _("All"), "all", "3") },
        heading(_("Show")),
        { toggleBtn(KEY_SHOW_TYPE, _("Word type")), toggleBtn(KEY_SHOW_CTX, _("Book context")) },
        { toggleBtn(KEY_PREFER_DUE, _("Review-due words first")) },
    }

    -- Dictionary selector: names are long, so one to a row.
    local dicts = findAvailableDictionaries()
    if #dicts > 0 then
        buttons[#buttons + 1] = heading(_("Dictionary"))
        buttons[#buttons + 1] = { radioBtn(KEY_DICT, _("All dictionaries"), "all", "all") }
        for _, d in ipairs(dicts) do
            buttons[#buttons + 1] = { radioBtn(KEY_DICT, d.name, d.name, "all") }
        end
    end
    buttons[#buttons + 1] = { resetKnownBtn() }

    dialog = require("ui/widget/buttondialog"):new(Kit.withClose{
        title        = _("Vocab Word"),
        title_align  = "center",
        width_factor = 0.75,
        buttons      = buttons,
    })
    require("ui/uimanager"):show(dialog)
end

-- ── Lazy init ──────────────────────────────────────────────────
-- Runs once, on the first render/tap/settings-open — never at module load
-- (this file must load in standalone Lua, and the sqlite reads plus the one
-- sdcv batch would block the menu open). Loads the persistent definition
-- cache, batch-builds any missing definitions (ONE sdcv call total), the
-- "known words" store and the DB metadata (context, book, due_time).
local _inited = false
lazyInit = function()
    if _inited then return end
    _inited = true
    ensureDeps()
    loadPersistentCache()
    batchBuildCache()
    loadKnownWords()
    loadVocabMeta()
end

return {
    key = "vocab_word",
    -- A headword and definitions: one grid column wide they shrink to
    -- nothing (as Quote of the day's text does).
    min_w = 2,
    title = _("Vocab Word"),
    summary = _("From Vocabulary Builder + dictionary. Works offline."),

    render = function(ctx)
        -- The Add-picker renders every module's preview: keep the one-time
        -- heavy init (sqlite + the batch sdcv) out of it.
        if not ctx.preview then lazyInit() end
        local width, scale_pct = ctx.width, ctx.scale
        -- Kit/BFont/widgets are required here (never at load: see the header
        -- note on the standalone-load contract).
        local Kit = require("lib/bookshelf_module_kit")
        local BFont = require("lib/bookshelf_fonts")
        local Geom = require("ui/geometry")
        local LineWidget = require("ui/widget/linewidget")
        local Blitbuffer = require("ffi/blitbuffer")
        local HorizontalGroup = require("ui/widget/horizontalgroup")
        local HorizontalSpan = require("ui/widget/horizontalspan")
        -- Sized by the host alone (its own module text size included): a
        -- size setting of the module's own was undone by the cell's fit.
        local sc = Kit.sc(scale_pct)
        local show_type = readShowType()
        local max_acepciones = readAcepciones()

        -- Nothing to show, or nothing a tap could move on to: say how to
        -- collect words instead (the preview keeps the sample word).
        local hint = not ctx.preview and hintText(vocabStatus(), usableWordCount())
        local word_data = not hint and fetchRandomWord()
        if not word_data then
            local VerticalGroup = require("ui/widget/verticalgroup")
            local VerticalSpan = require("ui/widget/verticalspan")
            local TextWidget = require("lib/bookshelf_colour_text")
            local head_face, head_bold = Kit.face(16, scale_pct, {bold = true})
            local head = TextWidget:new{
                text = _("Vocab Word"),
                face = head_face, bold = head_bold,
                max_width = width,
                fgcolor = Kit.COLOR_PRIMARY,
                bgcolor = Kit.CARD_BG,
            }
            local gap = sc(6)
            local room = ctx.height or ctx.max_height
            local body = Kit.fitText{
                text = hint or _("No vocab words yet"),
                size = 13, scale_pct = scale_pct, width = width,
                fgcolor = Kit.COLOR_MUTED,
                max_h = room and (room - head:getSize().h - gap) or nil,
            }
            return VerticalGroup:new{ align = "left",
                head, VerticalSpan:new{ dimen = { w = 1, h = gap } }, body }
        end

        local VerticalGroup = require("ui/widget/verticalgroup")
        local VerticalSpan = require("ui/widget/verticalspan")
        local TextWidget = require("lib/bookshelf_colour_text")
        local TextBoxWidget = require("ui/widget/textboxwidget")

        local selected = pickResult(word_data, readSelectedDict())
        local def = selected and selected.definition
        local dict_name = selected and selected.dict

        local word_size = dynamicWordSize(word_data.word, 28)
        local word_face, word_bold = BFont:getFace("Inter-ExtraBold.ttf", sc(word_size))
        local type_face, type_bold = BFont:getFace("Caveat-Regular.ttf", sc(18), { italic = true })
        local dict_face, dict_bold = BFont:getFace("Caveat-Regular.ttf", sc(11), { italic = true })

        local items = {
            align = "left",
            dimen = { w = width, h = 0 },
            VerticalSpan:new{ dimen = { w = 1, h = sc(4) } },
        }

        -- Word row: plain widget (its tap region is declared at the bottom)
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

        -- The definitions and the book quote: placeholders here, filled once
        -- the fixed parts are measured (below), so they get the room that is
        -- really left and wrap at the real width.
        local def_slot = #items + 1
        items[def_slot] = false
        local ctx_slot = #items + 1
        items[ctx_slot] = false

        -- Source dictionary: small, right-aligned attribution at the bottom.
        if dict_row then
            items[#items + 1] = VerticalSpan:new{ dimen = { w = 1, h = sc(3) } }
            items[#items + 1] = dict_row
        end

        items[#items + 1] = VerticalSpan:new{ dimen = { w = 1, h = sc(2) } }

        -- Footer row (last element): book where the word was learned (left)
        -- and "✓ I know it" (right, a tap region declared below).
        local footer_face, footer_bold = BFont:getFace("Caveat-Regular.ttf", sc(12), { italic = true })
        local know_widget = TextWidget:new{
            text = _("✓ I know it"),
            face = footer_face,
            bold = footer_bold,
            fgcolor = Kit.COLOR_MUTED,
            bgcolor = Kit.CARD_BG,
            alignment = "right",
        }
        local meta = _vocab_meta[current_word]
        local book_widget
        if meta and meta.book then
            book_widget = TextWidget:new{
                text = meta.book,
                max_width = math.max(1, width - know_widget:getSize().w - sc(8)),
                face = footer_face,
                bold = footer_bold,
                fgcolor = Kit.COLOR_MUTED,
                bgcolor = Kit.CARD_BG,
                alignment = "left",
            }
        end
        local know_size = know_widget:getSize()
        local book_w = book_widget and book_widget:getSize().w or 0
        local footer_h = math.max(know_size.h, book_widget and book_widget:getSize().h or 0)
        items[#items + 1] = HorizontalGroup:new{
            dimen = Geom:new{ w = width, h = 0 },
            book_widget or HorizontalSpan:new{ width = 0 },
            HorizontalSpan:new{ width = math.max(0, width - book_w - know_size.w) },
            know_widget,
        }

        -- Now the flexible text. The room: the cell's height (or the start
        -- menu's ceiling) less everything else on the card. The quote keeps
        -- to two lines; the definitions take the rest and end in an ellipsis
        -- rather than make the host shrink the whole card to fit them.
        local fixed_h = 0
        for i = 1, #items do
            local it = items[i]
            if it and it.getSize then fixed_h = fixed_h + it:getSize().h end
        end
        local room = ctx.height or ctx.max_height
        local def_face_size = Kit.face(12, scale_pct).size

        local quote_widget
        if readShowContext() and meta and meta.context and meta.context ~= "" then
            local qface = BFont:getFace("Caveat-Regular.ttf", sc(13), { italic = true })
            local qline = math.floor(qface.size * 1.3 + 0.5)
            quote_widget = TextBoxWidget:new{
                text = "\u{00AB}" .. meta.context .. "\u{00BB}",
                face = qface,
                width = width,
                height = qline * 2,
                height_adjust = true,
                height_overflow_show_ellipsis = true,
                fgcolor = Kit.COLOR_MUTED,
                bgcolor = Kit.CARD_BG,
                alignment = "left",
            }
            fixed_h = fixed_h + quote_widget:getSize().h + sc(6)
        end

        local def_widget
        if def and def.acepciones and #def.acepciones > 0 then
            local limit = max_acepciones == "all" and #def.acepciones or max_acepciones
            local shown = {}
            for i = 1, math.min(limit, #def.acepciones) do
                local a = def.acepciones[i]
                if a and a ~= "" then shown[#shown + 1] = i .. ". " .. a end
            end
            if #shown > 0 then
                local one_line = math.floor(def_face_size * 1.3 + 0.5)
                local max_h
                if room and room > 0 then
                    max_h = math.max(one_line, room - fixed_h - sc(6))
                else
                    max_h = one_line * 8
                end
                def_widget = Kit.fitText{
                    text = table.concat(shown, "\n"), size = 12, scale_pct = scale_pct,
                    width = width, max_h = max_h, fgcolor = Kit.COLOR_MUTED,
                }
            end
        end

        -- Into their slots; an empty slot is dropped.
        local filled = {}
        for i = 1, #items do
            if i == def_slot then
                if def_widget then
                    filled[#filled + 1] = VerticalSpan:new{ dimen = { w = 1, h = sc(6) } }
                    filled[#filled + 1] = def_widget
                end
            elseif i == ctx_slot then
                if quote_widget then
                    filled[#filled + 1] = VerticalSpan:new{ dimen = { w = 1, h = sc(6) } }
                    filled[#filled + 1] = quote_widget
                end
            else
                filled[#filled + 1] = items[i]
            end
        end
        filled.align = items.align
        filled.dimen = items.dimen
        items = filled

        local card = VerticalGroup:new(items)

        -- Tap regions: word zone → dictionary popup, footer → mark as known.
        if ctx.set_tap_regions then
            local group_h = card:getSize().h
            ctx.set_tap_regions({
                { id = "word", x = 0, y = 0, w = width, h = word_size.h + sc(6) },
                { id = "know", x = 0, y = math.max(0, group_h - footer_h - sc(4)),
                  w = width, h = footer_h + sc(4) },
            })
        end

        return card
    end,

    on_tap = function(ctx)
        lazyInit()

        -- Debounce
        local now = os.time()
        if now - _last_tap_at < TAP_DEBOUNCE_S then return end

        -- "✓ I know it" footer (tap region): mark the word as known and
        -- move on.
        if ctx.tapped_region == "know" then
            if _last_word_data then
                markWordKnown(_last_word_data.word)
                purgeQueueWord(_last_word_data.word)
                logger.dbg("[vocab_word] marked as known:", _last_word_data.word,
                    "(" .. knownCount() .. " known)")
            end
            _last_tap_at = now
            _vocab_cache = nil
            return true
        end

        -- Word zone: hand off to the file browser's own dictionary, which
        -- opens the full DictQuickLookup popup with working buttons, exactly
        -- as a lookup from the reader gets it. (A hand-built DictQuickLookup
        -- with ui = nil errors in buildButtonLayout on both 2026.07.1 and
        -- the current nightlies, and the host pcalls taps, so it failed
        -- silently.)
        if ctx.tapped_region == "word" and _last_word_data then
            local filemanager = require("apps/filemanager/filemanager")
            if filemanager.instance and filemanager.instance.dictionary then
                filemanager.instance.dictionary:onLookupWord(_last_word_data.word)
            end
            _last_tap_at = now
            return true
        end

        -- Tap elsewhere: advance to next word
        _last_tap_at = now
        _vocab_cache = nil
    end,

    show_settings = showSettings,
    keep_open = true,
    _test = { hintText = hintText, vocabStatus = vocabStatus },
}
