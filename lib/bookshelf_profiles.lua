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
    return profile.folder_sort
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

return Profiles
