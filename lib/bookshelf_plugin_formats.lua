-- lib/bookshelf_plugin_formats.lua
-- Book formats that other plugins teach KOReader to open.
--
-- The shelf's own format list (SUPPORTED_EXT in bookshelf_book_repository) is a
-- fixed mirror of KOReader's built-in engines, deliberately minus images and
-- code/markup that the engines can open but that are not shelf books.
--
-- Plugins register while they load, and Bookshelf loads before most of them
-- (pluginloader sorts by directory name), so the set cannot be computed once at
-- load. It is rebuilt whenever the provider list has grown -- an integer compare
-- per lookup, and the lookup only happens for names SUPPORTED_EXT rejected.

local M = {}

-- provider.provider keys of the engines KOReader registers itself
-- (frontend/document/{cre,pdf,djvu,pic}document.lua).
M.CORE_PROVIDERS = {
    crengine    = true,
    mupdf       = true,
    djvulibre   = true,
    picdocument = true,
}

-- Never books, whoever registers them (DocumentRegistry.image_ext covers the
-- usual ones; these are the extras MuPDF knows).
local IMAGE_EXT = {
    gif = true, jpeg = true, jpg = true, png = true, svg = true, tif = true,
    tiff = true, webp = true, bmp = true, jxr = true, jp2 = true, j2k = true,
    hdp = true, pbm = true, pgm = true, ppm = true, pam = true, pnm = true,
}

local _registry
local _set, _seen_n = {}, -1
local _fingerprint = ""

local function registry()
    if _registry == nil then
        local ok, reg = pcall(require, "document/documentregistry")
        _registry = (ok and type(reg) == "table") and reg or false
    end
    return _registry or nil
end

-- extensions(reg?) -> set { ext = provider_key } of plugin-provided formats,
-- lowercased, compound forms ("foo.zip") as registered. reg is for tests.
function M.extensions(reg)
    reg = reg or registry()
    local providers = reg and reg.providers
    if type(providers) ~= "table" then
        _set, _seen_n, _fingerprint = {}, -1, ""
        return _set
    end
    if #providers == _seen_n then return _set end
    local images = type(reg.image_ext) == "table" and reg.image_ext or {}
    local set = {}
    for _i, p in ipairs(providers) do
        local ext = type(p) == "table" and type(p.extension) == "string"
            and p.extension:lower() or nil
        local key = type(p) == "table" and type(p.provider) == "table"
            and p.provider.provider or nil
        if ext and ext ~= "" and type(key) == "string" and not M.CORE_PROVIDERS[key]
                and not images[ext] and not IMAGE_EXT[ext] then
            set[ext] = key
        end
    end
    local exts = {}
    for ext in pairs(set) do exts[#exts + 1] = ext end
    table.sort(exts)
    _set, _seen_n, _fingerprint = set, #providers, table.concat(exts, ",")
    return set
end

-- fingerprint() -> the plugin format set as one comparable string: the
-- extensions, sorted and comma-joined ("meguru"), "" when there are none.
function M.fingerprint()
    M.extensions()
    return _fingerprint
end

-- isPluginFormat(ext) -> true when a plugin registered a document provider
-- for this (lowercased) extension.
function M.isPluginFormat(ext)
    return type(ext) == "string" and M.extensions()[ext] ~= nil
end

-- Test hook: forget the cached registry and set.
function M._reset()
    _registry, _set, _seen_n, _fingerprint = nil, {}, -1, ""
end

return M
