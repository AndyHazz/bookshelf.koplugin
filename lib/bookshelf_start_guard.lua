-- lib/bookshelf_start_guard.lua
-- A start that never settles clears the caches that are read at start-up.
--
-- Issue 621: after an upgrade, a Kobo and a Kindle both froze hard right
-- after the shelf first painted (touch and the power button dead, nothing in
-- crash.log) on every start, until cache/bookshelf/ was emptied by hand.
-- Everything in that folder rebuilds itself, so a start that never got far
-- enough to clear the sentinel below gets those caches dropped on the next
-- one, before any of them is read.
--
-- The sentinel is a 0-byte file, as for the hero's crash marker
-- (lib/bookshelf_module_breaker): arm() makes it before our modules load,
-- settle() removes it once the shelf has been on screen for a while (the
-- freeze in 621 came after the first paint, not during it). A start that
-- freezes, crashes or loses power in between leaves it behind.
--
-- What goes is what a start reads: the compiled copies of our modules
-- (lib/bookshelf_bytecode; LuaJIT does not check bytecode, so a damaged copy
-- can hang rather than fail), the scaled covers and ornament renders, and the
-- library walk snapshots. Not the OPDS feed cache, downloads or fetched
-- covers: nothing reads those at start, and some need the network again.
--
-- The compiled copies save ~0.3-0.5 s of a PW5 start, and can be switched off
-- (Performance tweaks). A device that fails to settle twice within a few
-- starts gets them switched off for it: the guard cannot tell what hung, and
-- a second time suggests something about that device rather than bad luck,
-- so it costs that start time instead of risking a third. Both live in
-- settings/bookshelf/, so emptying the cache folder does not undo them:
--   bytecode_off  present = the copies are off; "auto" until the reader has
--                 been told why, then "auto-told"; "user" when switched off
--                 in the menu.
--   start_trip    after a start that did not settle: how many starts since.
local M = {}

M.NAME  = "start_inflight"
M.CLEAR = { "bytecode", "scaled_covers", "bookshelf.walk", "bookshelf.lightmeta",
            "bookshelf.finishedcount" }
M.OFF_NAME  = "bytecode_off"
M.TRIP_NAME = "start_trip"
-- A second start that does not settle on one of the this-many starts after
-- the first switches the compiled copies off.
M.TRIP_WINDOW = 10

local function lfs()
    local ok, l = pcall(require, "libs/libkoreader-lfs")
    return ok and l or nil
end

-- cacheDir() -> cache/bookshelf, or nil off a device.
function M.cacheDir()
    local ok, DataStorage = pcall(require, "datastorage")
    if not (ok and DataStorage and DataStorage.getDataDir) then return nil end
    local ok_dir, d = pcall(function() return DataStorage:getDataDir() end)
    if not (ok_dir and type(d) == "string") then return nil end
    return d .. "/cache/bookshelf"
end

-- settingsDir() -> settings/bookshelf, or nil off a device.
function M.settingsDir()
    local ok, DataStorage = pcall(require, "datastorage")
    if not (ok and DataStorage and DataStorage.getSettingsDir) then return nil end
    local ok_dir, d = pcall(function() return DataStorage:getSettingsDir() end)
    if not (ok_dir and type(d) == "string") then return nil end
    return d .. "/bookshelf"
end

local function readFile(path)
    local f = path and io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function writeFile(L, path, s)
    local dir = path:match("^(.*)/[^/]*$")
    if dir and L and not L.attributes(dir) then pcall(L.mkdir, dir) end
    local f = io.open(path, "w")
    if not f then return false end
    f:write(s)
    f:close()
    return true
end

-- Removes a file, or a folder and everything in it. os.remove takes an
-- empty folder as well as a file.
local function removeTree(L, path)
    local a = L.attributes(path)
    if not a then return end
    if a.mode == "directory" then
        local names = {}
        pcall(function()
            for name in L.dir(path) do
                if name ~= "." and name ~= ".." then names[#names + 1] = name end
            end
        end)
        for i = 1, #names do removeTree(L, path .. "/" .. names[i]) end
    end
    os.remove(path)
end

-- Counts this start against the last one that did not settle: a second
-- within TRIP_WINDOW switches the compiled copies off. Returns true then.
local function countTrip(L, sdir, stuck)
    if not sdir then return false end
    local trip = sdir .. "/" .. M.TRIP_NAME
    local since = tonumber((readFile(trip) or ""):match("%d+"))
    if stuck then
        if since and since < M.TRIP_WINDOW and M.bytecodeOn(sdir) then
            writeFile(L, sdir .. "/" .. M.OFF_NAME, "auto")
            os.remove(trip)
            return true
        end
        writeFile(L, trip, "0")
    elseif since then
        if since + 1 >= M.TRIP_WINDOW then os.remove(trip)
        else writeFile(L, trip, tostring(since + 1)) end
    end
    return false
end

-- arm([dir, sdir]) -> true when the previous start left its sentinel (and the
-- caches were cleared). Makes the sentinel for this start either way.
-- dir is cache/bookshelf, sdir settings/bookshelf.
function M.arm(dir, sdir)
    if M._armed then return false end
    dir = dir or M.cacheDir()
    sdir = sdir or M.settingsDir()
    local L = lfs()
    if not (dir and L) then return false end
    M._armed = true
    local sentinel = dir .. "/" .. M.NAME
    local stuck = L.attributes(sentinel) ~= nil
    if stuck then
        for i = 1, #M.CLEAR do pcall(removeTree, L, dir .. "/" .. M.CLEAR[i]) end
        pcall(function()
            require("logger").warn("[bookshelf] the last start did not settle: start-up caches cleared")
        end)
    end
    local ok, switched = pcall(countTrip, L, sdir, stuck)
    if ok and switched then
        pcall(function()
            require("logger").warn("[bookshelf] two starts did not settle: compiled module cache switched off")
        end)
    end
    if not L.attributes(dir) then pcall(L.mkdir, dir) end
    local f = io.open(sentinel, "w")
    if f then f:close() end
    M._sentinel = sentinel
    return stuck
end

-- settle(): this start got through; the next one keeps its caches.
function M.settle()
    if M._sentinel then
        os.remove(M._sentinel)
        M._sentinel = nil
    end
end

-- bytecodeOn([sdir]) -> whether our modules load from compiled copies.
function M.bytecodeOn(sdir)
    sdir = sdir or M.settingsDir()
    if not sdir then return true end
    return readFile(sdir .. "/" .. M.OFF_NAME) == nil
end

-- setBytecode(on, [sdir, dir]): the Performance tweaks switch. Off removes
-- the copies there are; on lets the next start compile them again, and
-- forgets any start that did not settle.
function M.setBytecode(on, sdir, dir)
    sdir = sdir or M.settingsDir()
    dir = dir or M.cacheDir()
    local L = lfs()
    if not (sdir and L) then return end
    if on then
        os.remove(sdir .. "/" .. M.OFF_NAME)
        os.remove(sdir .. "/" .. M.TRIP_NAME)
    else
        writeFile(L, sdir .. "/" .. M.OFF_NAME, "user")
        if dir then pcall(removeTree, L, dir .. "/bytecode") end
    end
end

-- takeNotice([sdir]) -> true once, after the guard switched the copies off,
-- so the reader is told why (and where to turn them back on).
function M.takeNotice(sdir)
    sdir = sdir or M.settingsDir()
    if not sdir then return false end
    local path = sdir .. "/" .. M.OFF_NAME
    if readFile(path) ~= "auto" then return false end
    writeFile(lfs(), path, "auto-told")
    return true
end

return M
