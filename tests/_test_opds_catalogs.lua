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

-- Fake LuaSettings that records saves and preserves a pre-seeded data table.
local FakeStore = {}
FakeStore.__index = FakeStore
local last_store
package.loaded["luasettings"] = {
    open = function(_, _path)
        local o = setmetatable({ data = { settings = {"KEEP"}, downloads = {"KEEP"} },
                                 flushed = false }, FakeStore)
        last_store = o
        return o
    end,
}
function FakeStore:saveSetting(k, v) self.data[k] = v end
function FakeStore:readSetting(k, d) local v = self.data[k]; if v == nil then return d end; return v end
function FakeStore:flush() self.flushed = true end

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

-- persist writes ONLY servers, preserves other keys, flushes
FakeSource._inst = nil
local plist = { { title="P", url="https://p/opds", sync=true } }
ok(Cat.persist(plist) == true, "persist returns true")
eq(last_store.data.servers[1].title, "P", "servers persisted")
eq(last_store.data.servers[1].sync, true, "sync field carried through")
ok(last_store.data.settings[1] == "KEEP", "settings key preserved")
ok(last_store.data.downloads[1] == "KEEP", "downloads key preserved")
ok(last_store.flushed == true, "flushed")

-- persist refills a live stock table IN PLACE and flags updated
local live_tbl = { { title="OLD", url="https://old/opds" } }
FakeSource._inst = { servers = live_tbl, settings_file = "/x/opds.lua", updated = nil }
Cat.persist({ { title="NEW", url="https://new/opds" } })
ok(FakeSource._inst.servers == live_tbl, "same table object kept (in-place refill)")
eq(live_tbl[1].title, "NEW", "live table contents replaced")
eq(#live_tbl, 1, "live table length correct")
ok(FakeSource._inst.updated == true, "live instance flagged updated")

-- add / edit / delete operate on the effective list and persist
FakeSource._inst = nil
FakeSource._live = nil
FakeSource._file = { { title="One", url="https://one/opds" } }

-- add appends, normalises URL, rejects empties + duplicates
ok(Cat.add({ title="Two", url="two.net/opds" }) == true, "add ok")
eq(last_store.data.servers[2].url, "http://two.net/opds", "added url normalised")
local ok_a, err_a = Cat.add({ title="", url="x" }); ok(not ok_a and err_a=="title_required", "empty title rejected")
local ok_b, err_b = Cat.add({ title="X", url="" });  ok(not ok_b and err_b=="url_required", "empty url rejected")
-- duplicate against the CURRENT file list
FakeSource._file = { { title="One", url="https://one/opds" } }
local ok_c, err_c = Cat.add({ title="Dup", url="https://one/opds" })
ok(not ok_c and err_c=="duplicate_url", "duplicate url rejected")

-- edit replaces in place, preserves raw_names/sync when set in fields
FakeSource._file = { { title="One", url="https://one/opds", raw_names=true } }
local ok_e = Cat.edit("https://one/opds", { title="One!", url="https://one/opds", raw_names=true })
ok(ok_e == true, "edit ok")
eq(last_store.data.servers[1].title, "One!", "edit changed title")
eq(last_store.data.servers[1].raw_names, true, "edit kept raw_names")

-- edit not-found
FakeSource._file = { { title="One", url="https://one/opds" } }
local ok_nf, err_nf = Cat.edit("https://missing/opds", { title="Z", url="https://z/opds" })
ok(not ok_nf and err_nf=="not_found", "edit missing rejected")

-- edit URL-collision with a DIFFERENT entry
FakeSource._file = { { title="One", url="https://one/opds" }, { title="Two", url="https://two/opds" } }
local ok_col, err_col = Cat.edit("https://one/opds", { title="One", url="https://two/opds" })
ok(not ok_col and err_col=="duplicate_url", "edit url-collision rejected")

-- delete removes
FakeSource._file = { { title="One", url="https://one/opds" }, { title="Two", url="https://two/opds" } }
ok(Cat.delete("https://one/opds") == true, "delete ok")
eq(#last_store.data.servers, 1, "delete removed one")
eq(last_store.data.servers[1].title, "Two", "delete kept the other")

-- edit that changes the URL to a free slot: returns the new url, and re-keys chips with the correct serverKey pair
FakeSource._inst = nil
FakeSource._live = nil
FakeSource._file = { { title="One", url="https://one/opds" } }
local real_rekey = Cat.rekeyChips
local rekey_args
Cat.rekeyChips = function(a, b) rekey_args = { a, b }; return 1 end
local ok_uc, newurl = Cat.edit("https://one/opds", { title="One", url="two.net/opds" })
ok(ok_uc == true, "url-change edit ok")
eq(newurl, "http://two.net/opds", "edit returns the new normalised url")
eq(rekey_args[1], FakeSource.serverKey("https://one/opds"), "rekey old key")
eq(rekey_args[2], FakeSource.serverKey("http://two.net/opds"), "rekey new key")
eq(last_store.data.servers[1].url, "http://two.net/opds", "edit persisted the new url")
Cat.rekeyChips = real_rekey -- restore the placeholder for later tests

-- empty username/password become nil
FakeSource._file = { }
Cat.add({ title="Auth", url="https://auth/opds", username="", password="" })
ok(last_store.data.servers[#last_store.data.servers].username == nil, "empty username becomes nil")
ok(last_store.data.servers[#last_store.data.servers].password == nil, "empty password becomes nil")

-- non-empty username/password are kept
FakeSource._file = { }
Cat.add({ title="Auth2", url="https://auth2/opds", username="u", password="p" })
eq(last_store.data.servers[#last_store.data.servers].username, "u", "non-empty username kept")
eq(last_store.data.servers[#last_store.data.servers].password, "p", "non-empty password kept")

-- edit with empty title rejected
FakeSource._file = { { title="One", url="https://one/opds" } }
local ok_ev, err_ev = Cat.edit("https://one/opds", { title="", url="https://one/opds" })
ok(not ok_ev and err_ev == "title_required", "edit empty title rejected")

-- delete nonexistent returns false
ok(Cat.delete("https://missing/opds") == false, "delete nonexistent returns false")

-- rekeyChips / chipsUsing against a stub tab model
local FakeTabs
local FakeTabModel = {}
FakeTabModel._saved = false
function FakeTabModel.load() return FakeTabs end
function FakeTabModel.save(t)
    FakeTabs = t
    FakeTabModel._saved = true
end

FakeTabs = {
    { id="a", source = { kind="opds", id="OLD" } },
    { id="b", source = { kind="opds", id="OTHER" } },
    { id="c", source = { kind="all" } },
    { id="d", source = { kind="opds", id="OLD" } },
}
eq(Cat.chipsUsing("OLD", FakeTabModel), 2, "chipsUsing counts both OLD chips")
eq(Cat.chipsUsing("NONE", FakeTabModel), 0, "chipsUsing zero when unused")

FakeTabModel._saved = false
eq(Cat.rekeyChips("OLD", "NEW", FakeTabModel), 2, "rekey re-points two chips")
eq(FakeTabs[1].source.id, "NEW", "chip a re-keyed")
eq(FakeTabs[4].source.id, "NEW", "chip d re-keyed")
eq(FakeTabs[2].source.id, "OTHER", "unrelated opds chip untouched")
ok(FakeTabModel._saved == true, "rekey saved the tab list")

FakeTabModel._saved = false
eq(Cat.rekeyChips("SAME", "SAME", FakeTabModel), 0, "no-op when keys equal")
ok(FakeTabModel._saved == false, "no save on no-op")

print(string.format("opds_catalogs: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
