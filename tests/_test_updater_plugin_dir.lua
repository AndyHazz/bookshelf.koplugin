-- tests/_test_updater_plugin_dir.lua
-- The updater reads and writes the copy KOReader is actually running.
--
-- THE REPORT. A reader on Reddit: "when i click 'about' i can see im on
-- v4.2.1 but when i do the 'check for updates' i'm on v5.0.8" -- after
-- updating several times, using Reset to latest stable, and rebooting.
--
-- Both numbers were true. About derives the plugin folder from the running
-- file's own path, so it reports the code KOReader loaded. The updater read a
-- fixed <data dir>/plugins/bookshelf.koplugin, and installed there too. When
-- those are not the same folder, every update succeeds and changes nothing a
-- reader can see.
--
-- They can differ two ways, both ordinary. KOReader looks in "plugins" under
-- the install directory FIRST and <data dir>/plugins second, which are
-- different places on desktop and Android. And it loads every directory
-- ending .koplugin in either, with no check for a name already seen, so a
-- leftover "bookshelf-old.koplugin" runs alongside the real one.
--
-- Usage (from plugin root): lua tests/_test_updater_plugin_dir.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()
local src = io.open("lib/bookshelf_updater.lua"):read("*a")
local set = io.open("lib/bookshelf_settings.lua"):read("*a")

t.test("the folder is derived from the running file, not a fixed path", function()
    local body = src:match("\nfunction Updater.pluginDir%(%)\n(.-)\nend\n")
    assert(body, "Updater.pluginDir missing")
    assert(body:find("debug.getinfo(1", 1, true),
        "the folder is not derived from the running file")
    -- The old path survives only as the fallback, after the derivation.
    local at_derive = body:find("debug.getinfo", 1, true)
    local at_fixed  = body:find("getDataDir()", 1, true)
    assert(at_fixed and at_fixed > at_derive,
        "the fixed path is not a fallback; it is being preferred")
end)

t.test("the version and the install target both go through it", function()
    local ver = src:match("\nfunction Updater.getInstalledVersion%(%)\n(.-)\nend\n")
    assert(ver and ver:find("Updater.pluginDir()", 1, true),
        "the reported version still comes from a fixed path, so it can "
        .. "disagree with About")
    assert(src:find("local plugin_path = Updater.pluginDir()", 1, true),
        "the install still extracts to a fixed path, so it can update a copy "
        .. "nobody runs")
    -- No fixed plugin path left anywhere in the updater.
    local fixed = select(2, src:gsub('getDataDir%(%) %.%. "/plugins/bookshelf%.koplugin', ""))
    assert(fixed <= 1, "found " .. fixed .. " fixed plugin paths; expected only "
        .. "the one fallback inside pluginDir")
end)

t.test("a second copy is reported where the reader will look", function()
    local body = src:match("\nfunction Updater.otherCopies%(%)\n(.-)\nend\n")
    assert(body, "Updater.otherCopies missing")
    -- Both lookup paths, because the install dir is searched first and is a
    -- different place from the data dir on desktop and Android.
    assert(body:find('"plugins"', 1, true) and body:find("getDataDir()", 1, true),
        "otherCopies does not search both of KOReader's lookup paths")
    assert(body:find('entry:sub(-9) == ".koplugin"', 1, true),
        "otherCopies does not match what KOReader actually loads")
    assert(body:find("path ~= mine", 1, true), "otherCopies would report itself")
    -- And About says so, because that is the screen showing the wrong number.
    assert(set:find("Updater.otherCopies", 1, true),
        "About does not mention a second copy")
    assert(set:find("Another copy of Bookshelf is installed", 1, true),
        "About has no wording for it")
end)

t.done()
