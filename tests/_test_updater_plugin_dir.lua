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
local eq = helpers.eq
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
    assert(body:find("id ~= mine_id", 1, true),
        "otherCopies compares paths rather than identities, so it reports "
        .. "itself whenever the loader spelled our path the other way")
    -- And About says so, because that is the screen showing the wrong number.
    assert(set:find("Updater.otherCopies", 1, true),
        "About does not mention a second copy")
    assert(set:find("Another copy of Bookshelf is installed", 1, true),
        "About has no wording for it")
end)

-- ── the same directory, reached two ways ──────────────────────────────────
--
-- KOReader's two lookup paths are "plugins", relative to its own working
-- directory, and <datadir>/plugins. On a Kobo, an Android install and the
-- emulator those are THE SAME DIRECTORY. Keyed on the path strings, the scan
-- walked it twice and reported the one true install as a second copy:
--
--     Another copy of Bookshelf is installed and is also being loaded
--     ./plugins/bookshelf.koplugin
--
-- on a device with exactly one, to a reader who had installed once and
-- updated through the plugin for a year (Reddit, 2026-09-20).
local function harness(tree, datadir, mine)
    -- tree: { [path] = { mode =, dev =, ino = } }. Two paths sharing a
    -- dev/ino pair are the same directory, which is the whole point.
    local lfs = {
        attributes = function(path, what)
            local e = tree[path]
            if not e then return nil end
            if what == "mode" then return e.mode end
            return e
        end,
        dir = function(path)
            local names, i = {}, 0
            for p, e in pairs(tree) do
                local rest = p:match("^" .. path:gsub("[%-%.%+%[%]%(%)%$%^%%%?%*]", "%%%0") .. "/([^/]+)$")
                if rest and e.mode == "directory" then names[#names + 1] = rest end
            end
            table.sort(names)
            return function() i = i + 1; return names[i] end
        end,
    }
    local body = src:match("\nfunction Updater%.otherCopies%(%)\n(.-)\nend\n")
    local ident = src:match("\nlocal function _identity%(lfs, path%)\n(.-)\nend\n")
    assert(body and ident, "otherCopies or _identity moved")
    local env = {
        type = type, tostring = tostring, pcall = pcall, pairs = pairs,
        table = table, string = string,
        require = function(name)
            if name == "libs/libkoreader-lfs" then return lfs end
            if name == "datastorage" then
                return { getDataDir = function() return datadir end }
            end
            error("unexpected require " .. name)
        end,
        Updater = { pluginDir = function() return mine end },
    }
    env._identity = assert(load("local lfs, path = ...\n" .. ident,
                                "_identity", "t", env))
    -- The body declares its own `out` and returns it, so wrap rather than splice.
    local fn = assert(load("return function()\n" .. body .. "\nend",
                           "otherCopies", "t", env))()
    return fn()
end

t.test("one install reached by both lookup paths is not a second copy", function()
    -- The Kobo shape: cwd IS the data dir, so "plugins" and
    -- "/mnt/onboard/.adds/koreader/plugins" stat to the same directory.
    local D = "/mnt/onboard/.adds/koreader"
    local tree = {
        ["plugins"]                         = { mode = "directory", dev = 8, ino = 100 },
        [D .. "/plugins"]                   = { mode = "directory", dev = 8, ino = 100 },
        ["plugins/bookshelf.koplugin"]      = { mode = "directory", dev = 8, ino = 200 },
        [D .. "/plugins/bookshelf.koplugin"]= { mode = "directory", dev = 8, ino = 200 },
    }
    -- pluginDir answers with whichever form the loader used; both must work.
    for _i, mine in ipairs({ "plugins/bookshelf.koplugin",
                             D .. "/plugins/bookshelf.koplugin" }) do
        local out = harness(tree, D, mine)
        eq(#out, 0, "reported itself when pluginDir said " .. mine
                    .. ": " .. table.concat(out, ", "))
    end
end)

t.test("a real second copy is still reported", function()
    local D = "/mnt/onboard/.adds/koreader"
    local tree = {
        ["plugins"]                          = { mode = "directory", dev = 8, ino = 100 },
        [D .. "/plugins"]                    = { mode = "directory", dev = 8, ino = 100 },
        ["plugins/bookshelf.koplugin"]       = { mode = "directory", dev = 8, ino = 200 },
        [D .. "/plugins/bookshelf.koplugin"] = { mode = "directory", dev = 8, ino = 200 },
        ["plugins/bookshelf-old.koplugin"]   = { mode = "directory", dev = 8, ino = 201 },
        [D .. "/plugins/bookshelf-old.koplugin"] = { mode = "directory", dev = 8, ino = 201 },
    }
    local out = harness(tree, D, "plugins/bookshelf.koplugin")
    eq(#out, 1, "expected the leftover copy exactly once, got "
                .. table.concat(out, ", "))
    assert(out[1]:find("bookshelf-old", 1, true), "reported " .. out[1])
end)

t.test("two genuinely separate lookup paths are both searched", function()
    -- Desktop and Android: the install dir and the data dir really are
    -- different places, and a copy in either one is loaded.
    local D = "/home/reader/.config/koreader"
    local tree = {
        ["plugins"]                          = { mode = "directory", dev = 8, ino = 100 },
        [D .. "/plugins"]                    = { mode = "directory", dev = 8, ino = 101 },
        ["plugins/bookshelf.koplugin"]       = { mode = "directory", dev = 8, ino = 200 },
        [D .. "/plugins/bookshelf.koplugin"] = { mode = "directory", dev = 8, ino = 201 },
    }
    local out = harness(tree, D, "plugins/bookshelf.koplugin")
    eq(#out, 1, "the copy in the other lookup path went unreported")
    assert(out[1] == D .. "/plugins/bookshelf.koplugin", "reported " .. out[1])
end)

t.test("a symlinked install is itself, not a second copy", function()
    -- What a developer runs: the data dir's plugin folder is a symlink to a
    -- working tree. Same inode, so same install.
    local D = "/home/dev/.config/koreader"
    local tree = {
        ["plugins"]                          = { mode = "directory", dev = 8, ino = 100 },
        [D .. "/plugins"]                    = { mode = "directory", dev = 8, ino = 101 },
        ["plugins/bookshelf.koplugin"]       = { mode = "directory", dev = 8, ino = 200 },
        [D .. "/plugins/bookshelf.koplugin"] = { mode = "directory", dev = 8, ino = 200 },
    }
    local out = harness(tree, D, "/home/dev/src/bookshelf.koplugin")
    eq(#out, 1, "one entry expected: the two paths are one install")
end)

t.test("no inodes, no crash: the old path comparison stands in", function()
    local D = "/mnt/onboard/.adds/koreader"
    local tree = {
        ["plugins"]                          = { mode = "directory" },
        [D .. "/plugins"]                    = { mode = "directory" },
        ["plugins/bookshelf.koplugin"]       = { mode = "directory" },
        [D .. "/plugins/bookshelf.koplugin"] = { mode = "directory" },
    }
    local out = harness(tree, D, "plugins/bookshelf.koplugin")
    -- Without inodes the two roots cannot be told apart, so this platform
    -- keeps the behaviour it had. It must not error, and it must not report
    -- the SAME path twice.
    local seen = {}
    for _i, p in ipairs(out) do
        assert(not seen[p], "reported " .. p .. " twice")
        seen[p] = true
    end
end)

t.done()
