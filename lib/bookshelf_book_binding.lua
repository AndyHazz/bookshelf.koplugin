-- Adapted from OrbitUI's binding styles (AGPL-3.0).
-- Presentation only: shelf defaults and library-wide series overrides.
local Settings = require("lib/bookshelf_settings_store")
local M = {}
local KEY = "series_bindings"
local paperback = { shade = 0.14, paper = 248, page_line = 210 }

function M.normalize(value)
    if value == "hardcover" or value == "paperback" then return value end
end

function M.label(value)
    local _ = require("lib/bookshelf_i18n").gettext
    -- "Hardcover" already names the metadata service in the translations.
    return value == "paperback" and _("Paperback") or _("Hardback")
end

function M.skin(value)
    if value == "paperback" then return paperback end
end

local function overrides()
    local saved = Settings.read(KEY)
    return type(saved) == "table" and saved or {}
end

function M.series(name)
    return M.normalize(overrides()[name])
end

function M.setSeries(name, value)
    if type(name) ~= "string" or name == "" then return false end
    if value ~= nil and not M.normalize(value) then return false end
    local saved = {}
    for k, v in pairs(overrides()) do saved[k] = v end
    saved[name] = value
    Settings.save(KEY, saved)
    Settings.flush()
    return true
end

-- Both pagination and rendering use this snapshot. An unset/unknown choice
-- remains Hardcover without rewriting any settings or book records.
function M.applyOptions(opts, chip, path)
    local tab = require("lib/bookshelf_tab_model").getById(chip) or {}
    opts.book_binding = M.normalize(tab.book_binding) or "hardcover"
    opts.series_bindings = {}
    for name, value in pairs(overrides()) do
        if type(name) == "string" and M.normalize(value) then
            opts.series_bindings[name] = value
        end
    end
    local tip = path and path[#path]
    if tip and tip.kind == "series" then
        opts.binding_series_name = (tip.payload or {}).series_name or tip.label
    elseif not tip and tab.source and tab.source.kind == "single_series" then
        opts.binding_series_name = tab.source.id
    end
    return opts
end

function M.resolve(book, source, opts)
    local name = book.series_name or source.series_name or opts.binding_series_name
    local choices = opts.series_bindings or {}
    return M.normalize(choices[name]) or M.normalize(opts.book_binding) or "hardcover"
end

return M
