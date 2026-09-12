-- bookshelf_asset_folder.lua
-- "Has this drop-in folder changed?", answered once for every feature that
-- has one: ornaments, wallpapers, anything later.
--
-- ── WHY THIS IS NOT JUST AN MTIME ───────────────────────────────────────────
--
-- The obvious cache key for a folder is its modification time, and it is
-- wrong in two ways that both end in "restart KOReader to see your own file"
-- -- the worst possible outcome for a feature whose entire interaction is
-- dropping a file into a folder.
--
--   * A DELETE DOES NOT BUMP THE MTIME on the Kindle's fuse.fsp mount.
--     Measured on device, with a real gap between the operations:
--         mtime before rm: 1789238485
--         mtime after  rm: 1789238485
--     So a removed file stayed in the pool for the rest of the session.
--   * MTIMES ARE WHOLE SECONDS. A file dropped in during the same second as
--     the last read leaves the key unchanged, so it is invisible until
--     something else touches the folder. This one bit in the unit tests
--     before it bit on hardware.
--
-- The key therefore carries the sorted set of matching NAMES as well as the
-- mtime. Enumerating names is the cheap half -- no file is opened -- and
-- whatever the caller does per file (parsing a PNG header, decoding an image)
-- is the expensive half the cache still avoids. The mtime stays in the key
-- because it catches a file EDITED IN PLACE, where the name set has not moved.

local AssetFolder = {}

-- scan(fs, dir, exts) -> sorted {name,...}, cache key  (or nil on failure)
--
-- fs   : an lfs-alike (attributes, dir)
-- dir  : the folder to look in
-- exts : set of lowercase extensions WITHOUT the dot, e.g. { png = true }
--
-- Names come back sorted, so a caller that builds its list in this order gets
-- a stable, alphabetical result for free.
function AssetFolder.scan(fs, dir, exts)
    if not (fs and dir and exts) then return nil end
    local mtime = fs.attributes(dir, "modification")
    if not mtime then return nil end
    local names = {}
    local ok = pcall(function()
        for name in fs.dir(dir) do
            local ext = name:match("%.([^%.]+)$")
            if ext and exts[ext:lower()] then
                names[#names + 1] = name
            end
        end
    end)
    if not ok then return nil end
    table.sort(names)
    -- "\0" as the separator: it cannot occur in a filename, so two different
    -- name sets can never collide into one key.
    return names, tostring(mtime) .. "|" .. table.concat(names, "\0")
end

-- extsFromList({"png","jpg"}) -> { png = true, jpg = true }
-- Convenience so callers can declare their formats as a readable list.
function AssetFolder.extsFromList(list)
    local set = {}
    for _i = 1, #(list or {}) do set[tostring(list[_i]):lower()] = true end
    return set
end

return AssetFolder
