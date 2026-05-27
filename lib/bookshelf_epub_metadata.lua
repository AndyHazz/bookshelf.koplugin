-- bookshelf_epub_metadata.lua
-- Small, cached EPUB OPF helpers for metadata that KOReader's
-- BookInfoManager currently flattens away (notably creator roles).

local EpubMetadata = {}

local function _shellQuote(s)
    return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

local function _xmlDecode(s)
    if not s then return "" end
    return (s:gsub("&lt;", "<")
             :gsub("&gt;", ">")
             :gsub("&quot;", "\"")
             :gsub("&apos;", "'")
             :gsub("&amp;", "&"))
end

local function _trim(s)
    return tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function _cleanText(s)
    s = _xmlDecode(tostring(s or ""):gsub("<[^>]+>", ""))
    s = s:gsub("%s+", " ")
    return _trim(s)
end

local function _attr(attrs, name)
    if type(attrs) ~= "string" then return nil end
    local pattern_dq = name .. '%s*=%s*"([^"]+)"'
    local pattern_sq = name .. "%s*=%s*'([^']+)'"
    return attrs:match(pattern_dq) or attrs:match(pattern_sq)
end

local function _normaliseRole(role)
    role = _trim(_xmlDecode(role or "")):lower()
    role = role:gsub("^marc:relators:", "")
               :gsub("^marc:relators#", "")
               :gsub("^http://id%.loc%.gov/vocabulary/relators/", "")
    return role
end

local function _isAuthorRole(role)
    role = _normaliseRole(role)
    return role == "aut" or role == "author"
end

local function _copyList(list)
    if type(list) ~= "table" then return nil end
    local out = {}
    for i, v in ipairs(list) do out[i] = v end
    return out
end

function EpubMetadata.extractAuthorCreatorsFromOpf(opf)
    if type(opf) ~= "string" or opf == "" then return nil end

    -- EPUB 3 commonly stores roles as:
    --   <dc:creator id="creator01">Name</dc:creator>
    --   <meta refines="#creator01" property="role">aut</meta>
    local refined_roles = {}
    for attrs, value in opf:gmatch("<%s*[%w_%-:]*meta([^>]*)>(.-)</%s*[%w_%-:]*meta%s*>") do
        local property = (_attr(attrs, "property") or ""):lower()
        local refines = _attr(attrs, "refines")
        if property == "role" and refines then
            local id = refines:gsub("^#", "")
            refined_roles[id] = _normaliseRole(value)
        end
    end

    local authors, seen = {}, {}
    local function add(name)
        name = _cleanText(name)
        if name ~= "" and not seen[name] then
            seen[name] = true
            authors[#authors + 1] = name
        end
    end

    for attrs, value in opf:gmatch("<%s*[%w_%-:]*creator([^>]*)>(.-)</%s*[%w_%-:]*creator%s*>") do
        local role = _attr(attrs, "opf:role") or _attr(attrs, "role")
        local id = _attr(attrs, "id")
        if (not role or role == "") and id then
            role = refined_roles[id]
        end
        if _isAuthorRole(role) then
            add(value)
        end
    end

    return #authors > 0 and authors or nil
end

local function _readCommand(cmd, max_bytes)
    local ok, fh = pcall(io.popen, cmd, "r")
    if not ok or not fh then return nil end
    local chunks, total = {}, 0
    for line in fh:lines() do
        total = total + #line
        if max_bytes and total > max_bytes then break end
        chunks[#chunks + 1] = line
    end
    fh:close()
    return #chunks > 0 and table.concat(chunks, "\n") or nil
end

local function _readOpfPath(filepath)
    local container = _readCommand(
        "unzip -p " .. _shellQuote(filepath) .. " META-INF/container.xml 2>/dev/null",
        128 * 1024)
    if container then
        local path = container:match("<%s*rootfile[^>]-full%-path%s*=%s*\"([^\"]+)\"")
                  or container:match("<%s*rootfile[^>]-full%-path%s*=%s*'([^']+)'")
        if path and path ~= "" then return _xmlDecode(path) end
    end

    local listing = _readCommand(
        "unzip -lqq " .. _shellQuote(filepath) .. " '*.opf' 2>/dev/null",
        256 * 1024)
    if not listing then return nil end
    for line in listing:gmatch("[^\n]+") do
        local path = line:match("%s+%d+%s+%S+%s+%S+%s+(.+%.opf)$")
                  or line:match("([^%s].-%.opf)$")
        if path then return path end
    end
    return nil
end

local function _readOpfFromEpub(filepath)
    local opf_path = _readOpfPath(filepath)
    if not opf_path then return nil end
    return _readCommand(
        "unzip -p " .. _shellQuote(filepath) .. " " .. _shellQuote(opf_path) .. " 2>/dev/null",
        1024 * 1024)
end

local _cache = {}

local function _statKey(filepath)
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok or not lfs then return "" end
    local attr = lfs.attributes(filepath)
    if type(attr) == "table" then
        return tostring(attr.modification or "") .. ":" .. tostring(attr.size or "")
    end
    local mtime = lfs.attributes(filepath, "modification")
    local size = lfs.attributes(filepath, "size")
    return tostring(mtime or "") .. ":" .. tostring(size or "")
end

function EpubMetadata.authorCreatorsForFile(filepath)
    if type(filepath) ~= "string" or not filepath:lower():match("%.epub$") then
        return nil
    end

    local stat_key = _statKey(filepath)
    local cached = _cache[filepath]
    if cached and cached.stat_key == stat_key then
        return _copyList(cached.authors)
    end

    local authors
    local ok, opf = pcall(_readOpfFromEpub, filepath)
    if ok and opf then
        authors = EpubMetadata.extractAuthorCreatorsFromOpf(opf)
    end
    _cache[filepath] = { stat_key = stat_key, authors = authors }
    return _copyList(authors)
end

function EpubMetadata.invalidate(filepath)
    if filepath then
        _cache[filepath] = nil
    else
        _cache = {}
    end
end

return EpubMetadata
