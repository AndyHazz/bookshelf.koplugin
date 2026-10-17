-- tests/_test_calibre_home_default.lua
-- Where the calibre reader looks for metadata.calibre when the reader never
-- saved a home folder (issue 517). KOReader only writes home_dir once one is
-- picked, and until then shows Device.home_dir as home -- /mnt/onboard on a
-- Kobo, where Calibre puts metadata.calibre. Read as "/", the file was never
-- found: no custom columns, no %calibre{pubdate}, no calibre.bookshelf.json.
-- Usage: cd into the plugin dir, then `lua tests/_test_calibre_home_default.lua`.

local saved_home
_G.G_reader_settings = {
    readSetting = function(_self, key)
        if key == "home_dir" then return saved_home end
    end,
}
local device = { home_dir = "/mnt/onboard" }
package.loaded["device"] = device
local probed = {}
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(path)
        probed[#probed + 1] = path
        return nil   -- nothing found: only the probe order is under test
    end,
}

local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq
local CalibreMeta = dofile("lib/calibre_metadata.lua")

local function probe()
    probed = {}
    CalibreMeta.invalidate()
    CalibreMeta.entryFor("/mnt/onboard/Books/a.epub", true)
    return probed
end

t.test("an unset home looks in the device's library folder first", function()
    saved_home = nil
    local p = probe()
    eq(p[1], "/mnt/onboard/metadata.calibre")
    eq(p[2], "/mnt/onboard/.metadata.calibre")
end)

t.test("an empty saved home is the same as an unset one", function()
    saved_home = ""
    eq(probe()[1], "/mnt/onboard/metadata.calibre")
end)

t.test("a saved home still wins, then the folder above it (issue 475)", function()
    saved_home = "/mnt/onboard/Books"
    local p = probe()
    eq(p[1], "/mnt/onboard/Books/metadata.calibre")
    eq(p[3], "/mnt/onboard/metadata.calibre")
end)

t.test("no device default falls back to the root, as before", function()
    saved_home = nil
    device.home_dir = nil
    eq(probe()[1], "/metadata.calibre")
    device.home_dir = "/mnt/onboard"
end)

t.done()
