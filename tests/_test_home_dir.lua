-- tests/_test_home_dir.lua
-- The home folder as KOReader resolves it: the saved home_dir, else the
-- device's own library folder on an e-reader.
--
-- WHAT WENT WRONG. A Kobo Color reader on a fresh install (Reddit,
-- 2026-10-09): "unable to set the home folder ... when I do anything the
-- system freezes". KOReader had saved no home_dir yet and itself used
-- /mnt/onboard, but Bookshelf read the setting alone: Home showed no books,
-- and the shelves that fell back to "/" walked the whole device (on the rig,
-- Series walked 14,246 folders in 12.4 s).
--
-- Usage (from plugin root): lua tests/_test_home_dir.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local function withDevice(saved, device, fn)
    local old_gs, old_dev = G_reader_settings, package.loaded["device"]
    G_reader_settings = { readSetting = function(_s, k) if k == "home_dir" then return saved end end }
    package.loaded["device"] = device
    package.loaded["lib/bookshelf_home_dir"] = nil
    local ok, err = pcall(fn, require("lib/bookshelf_home_dir"))
    G_reader_settings, package.loaded["device"] = old_gs, old_dev
    package.loaded["lib/bookshelf_home_dir"] = nil
    assert(ok, err)
end
local function yes() return true end
local function no() return false end
local kobo = { home_dir = "/mnt/onboard", isDesktop = no, isEmulator = no }

t.test("a saved home folder wins", function()
    withDevice("/mnt/onboard/Books", kobo, function(H) eq(H.get(), "/mnt/onboard/Books") end)
end)

t.test("nothing saved on an e-reader: the device's library folder, as KOReader uses", function()
    withDevice(nil, kobo, function(H) eq(H.get(), "/mnt/onboard") end)
    withDevice("", kobo, function(H) eq(H.get(), "/mnt/onboard") end)
    withDevice(nil, { home_dir = "/mnt/us", isDesktop = no, isEmulator = no },
        function(H) eq(H.get(), "/mnt/us") end)
end)

t.test("nothing saved on desktop or the emulator: still unset ($HOME is too big to walk)", function()
    withDevice(nil, { home_dir = "/home/me", isDesktop = yes, isEmulator = no },
        function(H) eq(H.get(), nil) end)
    withDevice(nil, { home_dir = "/home/me", isDesktop = no, isEmulator = yes },
        function(H) eq(H.get(), nil) end)
end)

t.test("no device module, or no home_dir on it: unset", function()
    withDevice(nil, { isDesktop = no, isEmulator = no }, function(H) eq(H.get(), nil) end)
    withDevice(nil, nil, function(H) eq(H.get(), nil) end)
end)

t.test("every home folder read goes through it", function()
    -- The one exception: the Set home folder dialog shows KOReader's own
    -- saved value (KOReader puts its default in when it is unset).
    local p = io.popen('grep -rn "readSetting(\\"home_dir\\")" lib main.lua')
    local out = p:read("*a"); p:close()
    local stray = {}
    for line in out:gmatch("[^\n]+") do
        if not line:find("^lib/bookshelf_home_dir%.lua:")
                and not line:find("local current = G_reader_settings:readSetting(\"home_dir\")", 1, true) then
            stray[#stray + 1] = line
        end
    end
    eq(#stray, 0, "home_dir read directly:\n" .. table.concat(stray, "\n"))
    local repo = io.open("lib/bookshelf_book_repository.lua"):read("*a")
    local root = repo:match("\nlocal function _resolveLibraryRoot%(%)\n(.-)\nend\n")
    assert(root and root:find("return HomeDir.get()", 1, true), "the library root does not use HomeDir")
end)

t.done()
