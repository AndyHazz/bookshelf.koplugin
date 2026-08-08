-- tests/_test_opds_source.lua
-- Read-only bridge to the stock opds.koplugin server list. The settings file
-- is plugin-owned input: every field is type-validated, and any read failure
-- degrades to "no servers".
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["logger"] = { dbg=function() end, info=function() end,
                             warn=function() end, err=function() end }
package.loaded["datastorage"] = { getSettingsDir = function() return "/tmp/opds_test_settings" end }

local Src = dofile("lib/bookshelf_opds_source.lua")

local pass, fail = 0, 0
local function ok(cond, label)
    if cond then pass = pass + 1 else fail = fail + 1; print("FAIL " .. label) end
end

os.execute("mkdir -p /tmp/opds_test_settings")
local path = "/tmp/opds_test_settings/opds.lua"

-- 1. missing file -> empty, not available
os.remove(path)
ok(#Src.servers() == 0, "missing file -> no servers")
ok(Src.isAvailable() == false, "missing file -> unavailable")

-- 2. real-shaped file (LuaSettings format: return { servers = {...} })
local f = io.open(path, "w")
f:write([[return {
    ["servers"] = {
        { ["title"] = "Test Cat", ["url"] = "http://localhost:8080/", ["username"] = "u", ["password"] = "p" },
        { ["title"] = "No URL entry" },
        { ["title"] = 42, ["url"] = "http://x/" },
        "not even a table",
    },
}]])
f:close()
local list = Src.servers()
ok(#list == 1, "only the valid entry survives, got " .. #list)
ok(list[1].title == "Test Cat" and list[1].url == "http://localhost:8080/", "fields carried")
ok(list[1].username == "u" and list[1].password == "p", "credentials carried")
ok(type(list[1].key) == "string" and #list[1].key == 8, "key is 8 hex chars")
ok(Src.getServer(list[1].key) ~= nil, "getServer round-trips")
ok(Src.getServer("ffffffff") == nil, "unknown key -> nil")
ok(Src.isAvailable() == true, "available with one server")

-- 3. keys are stable and URL-derived
ok(Src.serverKey("http://localhost:8080/") == list[1].key, "key = hash of url")
ok(Src.serverKey("http://other/") ~= list[1].key, "different url, different key")

-- 4. corrupt file -> degrade to empty
f = io.open(path, "w"); f:write("return {{{{ syntax error"); f:close()
ok(#Src.servers() == 0, "corrupt file -> no servers")

-- 5. LIVE in-memory list is preferred over the on-disk file.
-- The stock editor mutates its in-memory table and only flushes opds.lua
-- later; reading the file would show a stale catalogue until then. servers()
-- must read the live list when the plugin instance is loaded.
f = io.open(path, "w")
f:write([[return { ["servers"] = { { ["title"] = "On Disk", ["url"] = "http://disk/" } } }]])
f:close()

local real_live = Src._liveServers
Src._liveServers = function()
    return { { title = "Live One", url = "http://live/", username = "lu", password = "lp" },
             { title = "", url = "http://bad/" } }   -- invalid entries still get filtered
end
local live_list = Src.servers()
ok(#live_list == 1, "live list preferred: only the valid live entry survives, got " .. #live_list)
ok(live_list[1].title == "Live One" and live_list[1].url == "http://live/", "live fields carried")
ok(live_list[1].username == "lu" and live_list[1].password == "lp", "live credentials carried")
ok(Src.getServer(live_list[1].key) ~= nil, "getServer round-trips against the live list")

-- 6. no live instance -> file fallback (unchanged behaviour).
Src._liveServers = function() return nil end
local file_list = Src.servers()
ok(#file_list == 1 and file_list[1].title == "On Disk", "no live instance -> reads the file")

-- 7. live present but EMPTY -> file fallback (lazily-loaded plugin, not zero servers).
Src._liveServers = function() return {} end
local empty_live = Src.servers()
ok(#empty_live == 1 and empty_live[1].title == "On Disk", "empty live list -> file fallback")

Src._liveServers = real_live

-- 8. _liveServers finds the stock plugin on the live UI by feature detection.
-- The plugin's module field name is not hardcoded: the module carrying a
-- .servers table AND a .settings_file ending opds.lua is the one.
local fake_opds = {
    name = "opds",
    settings_file = "/whatever/settings/opds.lua",
    servers = { { title = "From Live UI", url = "http://ui/" } },
}
local fm = {}
fm[1] = fake_opds
fm.opds = fake_opds   -- registered both as an array entry and a named field
package.loaded["apps/filemanager/filemanager"] = { instance = fm }
local found = Src._liveServers()
ok(type(found) == "table" and #found == 1 and found[1].title == "From Live UI",
    "_liveServers feature-detects the stock plugin module")
-- and servers() maps it end-to-end
local via_scan = Src.servers()
ok(#via_scan == 1 and via_scan[1].title == "From Live UI", "servers() reads the scanned live list")
package.loaded["apps/filemanager/filemanager"] = nil

os.remove(path)
print(string.format("%d pass, %d fail", pass, fail))
if fail > 0 then os.exit(1) end
