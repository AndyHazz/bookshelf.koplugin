-- Fixed library profiles used by external launchers such as SimpleUI.

local Profiles = {}

local PROFILE_DEFS = {
    prose = {
        key = "prose",
        label = "Books",
        folder_sort = {
            { key = "author_surname", reverse = false },
            { key = "title", reverse = false },
        },
        roots = {
            "/storage/emulated/0/ePubs/Fiktion",
            "/storage/emulated/0/ePubs/Facklitteratur",
            "/storage/emulated/0/ePubs/Lyrik",
        },
        chips = {
            {
                key = "profile_fiction",
                label = "Fiktion",
                kind = "folder",
                path = "/storage/emulated/0/ePubs/Fiktion",
            },
            {
                key = "profile_nonfiction",
                label = "Facklitteratur",
                kind = "folder",
                path = "/storage/emulated/0/ePubs/Facklitteratur",
            },
            {
                key = "profile_poetry",
                label = "Lyrik",
                kind = "folder",
                path = "/storage/emulated/0/ePubs/Lyrik",
            },
            { key = "authors", label = "Authors", kind = "authors" },
            { key = "latest", label = "Latest", kind = "latest" },
        },
    },
    comics = {
        key = "comics",
        label = "Comics",
        folder_sort = {
            { key = "series_name", reverse = false },
            { key = "series_index", reverse = false },
            { key = "title", reverse = false },
        },
        roots = {
            "/storage/emulated/0/ePubs/Manga",
            "/storage/emulated/0/ePubs/Serier",
        },
        chips = {
            {
                key = "profile_manga",
                label = "Manga",
                kind = "folder",
                path = "/storage/emulated/0/ePubs/Manga",
            },
            {
                key = "profile_comics",
                label = "Serier",
                kind = "folder",
                path = "/storage/emulated/0/ePubs/Serier",
            },
            { key = "next", label = "Next", kind = "next" },
            { key = "authors", label = "Authors", kind = "authors" },
            { key = "latest", label = "Latest", kind = "latest" },
        },
    },
}

function Profiles.get(key)
    return key and PROFILE_DEFS[key] or nil
end

function Profiles.defaultChip(profile)
    return profile and profile.chips and profile.chips[1] and profile.chips[1].key
end

function Profiles.chip(profile, key)
    if not (profile and profile.chips and key) then return nil end
    for _, chip in ipairs(profile.chips) do
        if chip.key == key then return chip end
    end
    return nil
end

function Profiles.scope(profile)
    if not (profile and profile.roots and #profile.roots > 0) then return nil end
    return { roots = profile.roots }
end

function Profiles.folderSortPriority(profile)
    if not profile then return nil end
    local ok_settings, BookshelfSettings = pcall(require, "lib/bookshelf_settings_store")
    if ok_settings and BookshelfSettings then
        local saved = BookshelfSettings.read("profile_folder_sort_" .. profile.key)
        if type(saved) == "table" and #saved > 0 then
            return saved
        end
    end
    return profile.folder_sort
end

function Profiles.saveFolderSortPriority(profile, sort_priority)
    if not profile then return end
    local ok_settings, BookshelfSettings = pcall(require, "lib/bookshelf_settings_store")
    if not (ok_settings and BookshelfSettings) then return end
    if type(sort_priority) == "table" and #sort_priority > 0 then
        BookshelfSettings.save("profile_folder_sort_" .. profile.key, sort_priority)
    else
        BookshelfSettings.delete("profile_folder_sort_" .. profile.key)
    end
    BookshelfSettings.flush()
end

local function normalizePath(path)
    if type(path) ~= "string" or path == "" then return nil end
    path = path:gsub("/+$", "")
    if path == "" then return "/" end
    return path
end

local function pathInRoot(filepath, root)
    local fp = normalizePath(filepath)
    root = normalizePath(root)
    if not fp or not root then return false end
    return fp == root or fp:sub(1, #root + 1) == (root .. "/")
end

function Profiles.matchFile(filepath)
    local best_key, best_len
    for key, profile in pairs(PROFILE_DEFS) do
        for _, root in ipairs(profile.roots or {}) do
            if pathInRoot(filepath, root) then
                local len = #normalizePath(root)
                if not best_len or len > best_len then
                    best_key = key
                    best_len = len
                end
            end
        end
    end
    return best_key and PROFILE_DEFS[best_key] and best_key or nil
end

-- Resolve the profile folder chip and concrete parent folder that contain a
-- book. Used when returning from the reader so Bookshelf can restore the
-- actual folder view instead of merely opening the profile's last-used chip.
function Profiles.locationForFile(filepath)
    local profile_key = Profiles.matchFile(filepath)
    local profile = Profiles.get(profile_key)
    local fp = normalizePath(filepath)
    if not (profile and fp) then return nil end

    local best_chip, best_root, best_len
    for _, chip in ipairs(profile.chips or {}) do
        if chip.kind == "folder" and chip.path then
            local root = normalizePath(chip.path)
            if root and pathInRoot(fp, root) and (not best_len or #root > best_len) then
                best_chip = chip
                best_root = root
                best_len = #root
            end
        end
    end
    if not best_chip then return nil end

    local parent = fp:match("^(.*)/[^/]+$")
    parent = normalizePath(parent)
    if not parent or not pathInRoot(parent, best_root) then
        parent = best_root
    end

    return {
        profile_key = profile_key,
        profile = profile,
        chip_key = best_chip.key,
        root = best_root,
        folder = parent,
        filepath = fp,
    }
end

return Profiles
