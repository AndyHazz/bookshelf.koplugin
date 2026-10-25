--[[--
Bookshelf's top-menu icon (issue 548). KOReader's file browser gained a
"Reader" tab with book.opened, the icon Bookshelf's tab had always used, so
6.0 brings its own: assets/icons/bookshelf.svg.

KOReader finds a tab icon by NAME, as <icon dir>/<name>.svg, in its icon
folders (the user's koreader/icons first, the last the relative
"resources"). There is no way to hand it a file. So the name climbs from
whichever icon folder it is tried in to the root ("../" more times than any
path is deep, and the root's ".." is the root), then down to the plugin's
own file by its absolute path. That holds wherever the plugin is installed,
in plugins/ or an extra plugin folder, and writes nothing into the reader's
own icon folders.

A reader who prefers another icon puts their own bookshelf.svg (or .png) in
koreader/icons, as for any KOReader icon: found there, the plain name
"bookshelf" is used, so KOReader loads theirs.
]]

local M = {}

M.FALLBACK = "book.opened"
M.USER_NAME = "bookshelf"
M._lfs = nil        -- seams for the tests
M._data_dir = nil

local function lfs() return M._lfs or require("libs/libkoreader-lfs") end
local function dataDir()
    if M._data_dir then return M._data_dir end
    local ok, DataStorage = pcall(require, "datastorage")
    return ok and DataStorage and DataStorage:getDataDir() or nil
end

-- The reader's own icon, in koreader/icons, by the plain name.
local function userIcon()
    local dir = dataDir()
    if not dir then return false end
    for _i, ext in ipairs({ ".svg", ".png" }) do
        if lfs().attributes(dir .. "/icons/" .. M.USER_NAME .. ext, "mode") == "file" then return true end
    end
    return false
end

--- name(plugin_path) -> the icon name for the top-menu tab: the reader's own
--- bookshelf icon, else the plugin's, else KOReader's book when the file is
--- missing.
function M.name(plugin_path)
    if userIcon() then return M.USER_NAME end
    if type(plugin_path) ~= "string" or plugin_path == "" then return M.FALLBACK end
    local abs = plugin_path
    if abs:sub(1, 1) ~= "/" then
        local cwd = lfs().currentdir()
        if not cwd then return M.FALLBACK end
        abs = cwd .. "/" .. abs:gsub("^%./", "")
    end
    local base = abs:gsub("/+$", "") .. "/assets/icons/bookshelf"
    if lfs().attributes(base .. ".svg", "mode") ~= "file" then return M.FALLBACK end
    return ("../"):rep(40) .. base:gsub("^/+", "")
end

return M
