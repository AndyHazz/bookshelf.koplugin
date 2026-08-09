-- tests/_test_opds_catalogs.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["logger"] = { dbg=function() end, info=function() end,
                             warn=function() end, err=function() end }

-- Injectable stub for the read bridge. Tests reset its fields per case.
local FakeSource
FakeSource = {
    _live = nil, _file = nil, _inst = nil,
    _liveServers  = function() return FakeSource._live end,
    _fileServers  = function() return FakeSource._file end,
    liveInstance  = function() return FakeSource._inst end,
    _settingsPath = function() return "/tmp/does-not-matter/opds.lua" end,
    serverKey     = function(url)  -- deterministic short stub key
        local h = 0
        for i = 1, #url do h = (h * 31 + url:byte(i)) % 1000000 end
        return string.format("k%06d", h)
    end,
}
package.loaded["lib/bookshelf_opds_source"] = FakeSource

local Cat = dofile("lib/bookshelf_opds_catalogs.lua")

local pass, fail = 0, 0
local function eq(got, want, label)
    if got == want then pass = pass + 1
    else fail = fail + 1; print("FAIL "..label..": got "..tostring(got).." want "..tostring(want)) end
end
local function ok(cond, label)
    if cond then pass = pass + 1 else fail = fail + 1; print("FAIL "..label) end
end

-- normaliseUrl
eq(Cat.normaliseUrl("https://h/opds"), "https://h/opds", "scheme kept")
eq(Cat.normaliseUrl("manybooks.net/opds"), "http://manybooks.net/opds", "bare host gets http://")

-- defaults(): probes a stubbed pluginloader (enabled first, then disabled)
local fake_pl = {
    enabled_plugins  = {},
    disabled_plugins = { { settings_file = "/x/opds.lua",
                           default_servers = { { title="D1", url="https://d1/opds" } } } },
}
local d = Cat.defaults(fake_pl)
eq(#d, 1, "defaults from disabled stock module")
eq(d[1].title, "D1", "defaults title")

-- defaults() falls back to the hardcoded mirror when no opds module is present
local d2 = Cat.defaults({ enabled_plugins = {}, disabled_plugins = {} })
ok(#d2 == 6, "fallback mirror has six entries")

-- list(): live wins over file; both are copies (mutating result never touches source)
FakeSource._live = { { title="L", url="https://l/opds" } }
FakeSource._file = { { title="F", url="https://f/opds" } }
local l = Cat.list()
eq(l[1].title, "L", "live list wins")
l[1].title = "MUT"
eq(FakeSource._live[1].title, "L", "list() returns a copy, not the live table")

FakeSource._live = nil
eq(Cat.list()[1].title, "F", "file used when no live list")

FakeSource._live, FakeSource._file = nil, nil
ok(#Cat.list() == 6, "defaults baseline when neither live nor file")

print(string.format("opds_catalogs: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
