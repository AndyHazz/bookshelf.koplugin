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
                    local e = arc_entries[i]
                    if type(e) == "table" then return e end
                    return e and { path = e } or nil
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

t.test("a link in the zip is not extracted; files and folders are", function()
    open_ok, extract_fail_at = true, nil
    arc_entries = {
        { path = "root/lib/", mode = "directory" },
        { path = "root/evil", mode = "link" },
        { path = "root/main.lua", mode = "file" },
        { path = "root/dev", mode = "other" },
    }
    local ok, err = Updater._unpackStripRoot("/tmp/x.zip", "/plugins/x")
    assert(ok == true, tostring(err))
    assert(#last_reader.extracted == 2, "only the folder and the file: " .. #last_reader.extracted)
    assert(last_reader.extracted[1].src == "root/lib/")
    assert(last_reader.extracted[2].src == "root/main.lua")
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

-- Traversal. The encoder deliberately passes "/" and "." through so
-- feature/v5.2-test survives, which also let a ".." segment out of the repo
-- path: both curl (client-side) and api.github.com (server-side) collapse dot
-- segments, so a typed "branch" could retarget the install at ANY repo while
-- every URL constant in the module still says AndyHazz. git itself forbids ".."
-- anywhere in a refname, so rejecting it outright cannot reject a real branch.
t.test("composeBranchUrl: rejects a traversal segment", function()
    assert(Updater.composeBranchUrl("../../../evil/repo/zipball/master") == nil,
        tostring(Updater.composeBranchUrl("../../../evil/repo/zipball/master")))
end)

t.test("composeBranchUrl: rejects '..' anywhere (git forbids it in refnames)", function()
    assert(Updater.composeBranchUrl("fix..bug") == nil)
    assert(Updater.composeBranchUrl("..") == nil)
    assert(Updater.composeBranchUrl("a/../b") == nil)
end)

t.test("composeBranchUrl: rejects a non-string or empty branch", function()
    assert(Updater.composeBranchUrl(nil) == nil)
    assert(Updater.composeBranchUrl("") == nil)
end)

t.test("composeBranchUrl: a single dot is still fine inside a name", function()
    assert(Updater.composeBranchUrl("v5.2") == BASE .. "v5.2")
end)

-- ── The background check runs its request in a child process ──────────────
-- An HTTPS request to GitHub, made on the UI thread at startup and on every
-- wake (when "notify on wake" is on): 0.5 s on a PW5 with nothing able to
-- get past it. The child sends back only what the check reads.
t.test("the latest release travels from the child as one short line", function()
    local line = Updater._latestLine({ tag_name = "v6.5.0", draft = false, prerelease = false,
        body = string.rep("notes ", 20000),
        assets = { { name = "notes.txt", browser_download_url = "x" },
                   { name = "bookshelf.zip", browser_download_url = "https://e/b.zip" } } })
    assert(#line < 300, "the whole payload went through the pipe: " .. #line)
    local r = Updater._parseLatest(line)
    assert(r.tag_name == "v6.5.0" and r.draft == false and r.prerelease == false)
    assert(r.assets[1].browser_download_url == "https://e/b.zip")
    assert(Updater._parseLatest("") == nil, "nothing read as a release")
    assert(Updater._parseLatest(Updater._latestLine(nil)) == nil, "a failed request read as a release")
end)

t.test("checkBackground asks through the child, and reports a newer version", function()
    package.loaded["ui/network/manager"] = { isWifiOn = function() return true end }
    local sched = {}
    package.loaded["ui/uimanager"].scheduleIn = function(_s, _d, fn) sched[#sched + 1] = fn end
    local orig_fetch, orig_ver = Updater._fetchLatest, Updater.getInstalledVersion
    local asked
    Updater._fetchLatest = function(ua, done)
        asked = ua
        done({ tag_name = "v99.0.0", assets = { { name = "b.zip", browser_download_url = "https://e/b.zip" } } })
    end
    Updater.getInstalledVersion = function() return "6.4.0" end
    local found
    Updater.checkBackground(function(v) found = v end)
    for _i, fn in ipairs(sched) do fn() end
    Updater._fetchLatest, Updater.getInstalledVersion = orig_fetch, orig_ver
    assert(asked and asked:find("6.4.0", 1, true), "the request did not go through _fetchLatest")
    assert(found == "99.0.0", tostring(found))
    local v, zip = Updater.getAvailableUpdate()
    assert(v == "99.0.0" and zip == "https://e/b.zip")
    local src = io.open("lib/bookshelf_updater.lua"):read("*a")
    local body = assert(src:match("\nfunction Updater%.checkBackground%(on_update_found%)\n(.-)\nend\n"))
    assert(not body:find("httpGetJSON(", 1, true), "the check still makes its request on the UI thread")
end)

t.done()
