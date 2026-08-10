-- tests/_test_updater.lua
-- lib/bookshelf_updater's pure parts: composeBranchUrl (URL-encoding a
-- branch path without mangling its slashes) and _unpackStripRoot (release /
-- branch zips wrap everything in one top-level dir that must be stripped),
-- against a stubbed ffi/archiver. The network/install flow is device-tested.
package.path = "./?.lua;./?/init.lua;" .. package.path

-- Load-time deps of the updater module.
package.loaded["ui/widget/confirmbox"]  = { new = function(_self, o) return o end }
package.loaded["ui/widget/infomessage"] = { new = function(_self, o) return o end }
package.loaded["ui/uimanager"] = { show = function() end, close = function() end,
                                   scheduleIn = function() end }
package.loaded["device"] = { canOpenLink = function() return false end }
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }

-- ── ffi/archiver stub ───────────────────────────────────────────────────────
local arc_entries, open_ok, extract_fail_at, last_reader
package.loaded["ffi/archiver"] = {
    Reader = {
        new = function(_self)
            local r = { extracted = {}, closed = false }
            last_reader = r
            function r:open(path)
                self.opened = path
                if not open_ok then self.err = "bad zip"; return false end
                return true
            end
            function r:iterate()
                local i = 0
                return function()
                    i = i + 1
                    return arc_entries[i] and { path = arc_entries[i] } or nil
                end
            end
            function r:extractToPath(src, dst)
                if src == extract_fail_at then self.err = "disk full"; return false end
                self.extracted[#self.extracted + 1] = { src = src, dst = dst }
                return true
            end
            function r:close() self.closed = true end
            return r
        end,
    },
}

local Updater = dofile("lib/bookshelf_updater.lua")
local t = dofile("tests/_helpers.lua").runner()

-- ── composeBranchUrl ────────────────────────────────────────────────────────
local BASE = "https://api.github.com/repos/AndyHazz/bookshelf.koplugin/zipball/"

t.test("composeBranchUrl: plain branch passes through", function()
    assert(Updater.composeBranchUrl("master") == BASE .. "master")
end)

t.test("composeBranchUrl: slashes survive (feature branches)", function()
    assert(Updater.composeBranchUrl("feature/v5.2-test") == BASE .. "feature/v5.2-test")
end)

t.test("composeBranchUrl: dot, dash, underscore, tilde stay literal", function()
    assert(Updater.composeBranchUrl("fix-1.2_x~y") == BASE .. "fix-1.2_x~y")
end)

t.test("composeBranchUrl: specials are percent-encoded", function()
    assert(Updater.composeBranchUrl("wip branch") == BASE .. "wip%20branch",
        Updater.composeBranchUrl("wip branch"))
    assert(Updater.composeBranchUrl("a#b") == BASE .. "a%23b")
    assert(Updater.composeBranchUrl("a+b") == BASE .. "a%2Bb")
end)

-- ── _unpackStripRoot ────────────────────────────────────────────────────────
t.test("strips the single top-level dir from every entry", function()
    open_ok, extract_fail_at = true, nil
    arc_entries = {
        "bookshelf.koplugin-abc123/",              -- the root dir itself: skipped
        "bookshelf.koplugin-abc123/main.lua",
        "bookshelf.koplugin-abc123/lib/bookshelf_widget.lua",
    }
    local ok, err = Updater._unpackStripRoot("/tmp/x.zip", "/plugins/bookshelf.koplugin")
    assert(ok == true, tostring(err))
    assert(last_reader.opened == "/tmp/x.zip")
    assert(#last_reader.extracted == 2, "root-dir entry itself is not extracted")
    assert(last_reader.extracted[1].dst == "/plugins/bookshelf.koplugin/main.lua")
    assert(last_reader.extracted[2].dst == "/plugins/bookshelf.koplugin/lib/bookshelf_widget.lua")
    assert(last_reader.closed, "archive closed on success")
end)

t.test("unopenable archive fails cleanly with the reader's error", function()
    open_ok = false
    arc_entries = {}
    local ok, err = Updater._unpackStripRoot("/tmp/broken.zip", "/plugins/x")
    assert(ok == false)
    assert(err == "bad zip", tostring(err))
    assert(last_reader.closed, "archive closed even when open failed")
    open_ok = true
end)

t.test("a failing extract aborts with the error, archive still closed", function()
    arc_entries = {
        "root/main.lua",
        "root/lib/big.bin",
        "root/never-reached.lua",
    }
    extract_fail_at = "root/lib/big.bin"
    local ok, err = Updater._unpackStripRoot("/tmp/x.zip", "/plugins/x")
    assert(ok == false)
    assert(err == "disk full", tostring(err))
    assert(#last_reader.extracted == 1, "extraction stops at the failure")
    assert(last_reader.closed)
    extract_fail_at = nil
end)

t.test("missing extractor degrades to a clean error, not a crash", function()
    package.loaded["ffi/archiver"] = nil
    package.preload["ffi/archiver"] = function() error("not on this build") end
    local ok, err = Updater._unpackStripRoot("/tmp/x.zip", "/plugins/x")
    assert(ok == false)
    assert(err == "archive extractor unavailable", tostring(err))
    package.preload["ffi/archiver"] = nil
end)

-- ── small exported state helpers ────────────────────────────────────────────
t.test("getInstalledVersion falls back to 'unknown' without a _meta.lua", function()
    package.loaded["datastorage"] = {
        getDataDir = function() return "/nonexistent-harness-path" end,
    }
    assert(Updater.getInstalledVersion() == "unknown")
end)

t.test("getAvailableUpdate starts empty", function()
    local v, url = Updater.getAvailableUpdate()
    assert(v == nil and url == nil)
end)

t.done()
