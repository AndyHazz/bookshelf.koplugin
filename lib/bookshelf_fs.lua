-- lib/bookshelf_fs.lua
-- Filesystem helpers shared across modules.
--
-- ensureDir(path) -> true when path is (now) a directory. Recursive (mkdir -p,
-- so a two-level target like covers/online/<book> works from scratch) and
-- fully pcall-hardened (Android's storage sandbox can make lfs calls raise
-- rather than return nil). Replaces three divergent per-module copies: flat
-- (cover_apply), recursive-but-bare (cover_fetch) and hardened-but-flat
-- (hardcover) - this one is the union.

local M = {}

function M.ensureDir(path)
    if type(path) ~= "string" or path == "" then return false end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or not lfs or type(lfs.attributes) ~= "function" then
        return false
    end
    local function ensure(p)
        local ok_a, mode = pcall(lfs.attributes, p, "mode")
        if ok_a and mode == "directory" then return true end
        local parent = p:match("^(.*)/[^/]+$")
        if parent and parent ~= "" then ensure(parent) end
        pcall(lfs.mkdir, p)
        local ok_b, mode2 = pcall(lfs.attributes, p, "mode")
        return (ok_b and mode2 == "directory") or false
    end
    return ensure(path)
end

return M
