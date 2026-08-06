-- lib/bookshelf_file_ops.lua
-- Move engine for books and folders. No UI in this module; dialogs live
-- in lib/bookshelf_move_flow.lua. Composes KOReader core primitives
-- (FileManager:moveFile, DocSettings.updateLocation, ReadHistory /
-- ReadCollection updateItem) and then repairs bookshelf-owned
-- path-keyed stores. KOReader requires are lazy (inside functions) so
-- the pure helpers run under a standalone `lua` for tests/run.sh.
-- Spec: docs/superpowers/specs/2026-08-06-file-move-design.md

local logger = require("logger")

local FileOps = {}

-- ── Pure path helpers ───────────────────────────────────────────────

-- Normalise a directory path to no trailing slash ("/" stays "/").
function FileOps.normDir(p)
    if p == "/" then return "/" end
    return (tostring(p):gsub("/+$", ""))
end

function FileOps.basename(p)
    return tostring(p):match("([^/]+)/*$")
end

function FileOps.parentDir(p)
    local parent = FileOps.normDir(p):match("^(.*)/[^/]+$")
    if parent == nil or parent == "" then return "/" end
    return parent
end

function FileOps.joinDir(dir, name)
    local base = FileOps.normDir(dir)
    if base == "/" then base = "" end
    return base .. "/" .. name
end

-- Destination filepath for moving `path` into `dest_dir`.
function FileOps.destPath(path, dest_dir)
    return FileOps.joinDir(dest_dir, FileOps.basename(path))
end

-- Swap the old_dir prefix of `path` for new_dir. Returns nil when path
-- is not under old_dir. Segment-safe: "/a/bb" is NOT under "/a/b".
function FileOps.prefixSwap(path, old_dir, new_dir)
    old_dir = FileOps.normDir(old_dir)
    new_dir = FileOps.normDir(new_dir)
    if path == old_dir then return new_dir end
    if path:sub(1, #old_dir + 1) == old_dir .. "/" then
        return new_dir .. path:sub(#old_dir + 1)
    end
    return nil
end

-- Directory depth of `dir` relative to `home`: 0 = home itself, 1 = a
-- direct child, nil = not under home. Matches walkBooks' current_depth
-- arithmetic: books inside a depth-N directory are found when N <= the
-- walk depth (bookshelf_book_repository.lua walkBooks, guard
-- `current_depth > depth`).
function FileOps.shelfDepth(dir, home)
    home = FileOps.normDir(home)
    dir  = FileOps.normDir(dir)
    if dir == home then return 0 end
    local rel = FileOps.prefixSwap(dir, home, "")
    if not rel then return nil end
    local n = 0
    for _seg in rel:gmatch("/[^/]+") do n = n + 1 end
    return n
end

-- Will books placed directly in dest_dir appear on the shelf?
function FileOps.isVisibleOnShelf(dest_dir, home, walk_depth)
    local d = FileOps.shelfDepth(dest_dir, home)
    return d ~= nil and d <= (walk_depth or 3)
end

-- planMoves(paths, dest_dir, opts): pre-check pass. Never overwrites:
-- a name collision at the destination is a skip, not a prompt (spec).
-- opts.exists(path) -> bool (default: lfs stat), opts.in_use_paths =
-- { [fp] = true } for books that must not move (open/parked reader).
function FileOps.planMoves(paths, dest_dir, opts)
    opts = opts or {}
    local exists = opts.exists or function(p)
        local lfs = require("libs/libkoreader-lfs")
        return lfs.attributes(p, "mode") ~= nil
    end
    local in_use = opts.in_use_paths or {}
    local dest_norm = FileOps.normDir(dest_dir)
    local plan = { moves = {}, skipped = {} }
    for _i, fp in ipairs(paths) do
        local to = FileOps.destPath(fp, dest_norm)
        if in_use[fp] then
            plan.skipped[#plan.skipped + 1] = { path = fp, reason = "in_use" }
        elseif FileOps.parentDir(fp) == dest_norm then
            plan.skipped[#plan.skipped + 1] = { path = fp, reason = "same_dir" }
        elseif not exists(fp) then
            plan.skipped[#plan.skipped + 1] = { path = fp, reason = "missing" }
        elseif exists(to) then
            plan.skipped[#plan.skipped + 1] = { path = fp, reason = "exists" }
        else
            plan.moves[#plan.moves + 1] = { from = fp, to = to }
        end
    end
    return plan
end

return FileOps
