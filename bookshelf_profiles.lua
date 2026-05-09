-- bookshelf_profiles.lua
-- Fixed library profiles used by external launchers such as SimpleUI.

local Profiles = {}

local PROFILE_DEFS = {
    prose = {
        key = "prose",
        label = "Books",
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

return Profiles
