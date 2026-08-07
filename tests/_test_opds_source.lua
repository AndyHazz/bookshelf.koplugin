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

os.remove(path)
print(string.format("%d pass, %d fail", pass, fail))
if fail > 0 then os.exit(1) end
