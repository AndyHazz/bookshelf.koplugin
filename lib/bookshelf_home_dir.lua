--[[
The reader's home folder, as KOReader itself resolves it.

KOReader only saves home_dir once the reader sets one; until then (a fresh
install) it uses the device's own library folder, Device.home_dir:
/mnt/onboard on a Kobo, /mnt/us on a Kindle (reader.lua). Bookshelf read the
saved setting alone, so on a fresh install Home showed no books and the
shelves that fell back to "/" walked the whole device (a Kobo Color reader:
"unable to set the home folder ... when I do anything the system freezes").

On desktop and the emulator there is no such fallback: Device.home_dir is
$HOME there, and walking it locked up the UI (feedback_dont_lift_walk_depth),
so those keep the old behaviour of an unset home.
]]

local HomeDir = {}

-- get() -> the saved home_dir, else the device's library folder on an
-- e-reader, else nil.
function HomeDir.get()
    local gs = G_reader_settings
    local home = gs and gs:readSetting("home_dir")
    if type(home) == "string" and home ~= "" then return home end
    local ok, Device = pcall(require, "device")
    if not (ok and type(Device) == "table") then return nil end
    local dir = Device.home_dir
    if type(dir) ~= "string" or dir == "" then return nil end
    local function is(name)
        local f = Device[name]
        if type(f) ~= "function" then return false end
        local ok2, v = pcall(f, Device)
        return ok2 and v == true
    end
    if is("isDesktop") or is("isEmulator") then return nil end
    return dir
end

return HomeDir
