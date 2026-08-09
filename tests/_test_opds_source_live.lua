-- tests/_test_opds_source_live.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["logger"] = { dbg=function() end, info=function() end,
                             warn=function() end, err=function() end }
package.loaded["datastorage"] = { getSettingsDir = function() return "/tmp/x" end }

-- Fake a FileManager instance holding the stock opds module (module carrying a
-- .servers table and a settings_file ending opds.lua).
local stock = { servers = { { title="A", url="https://a/opds" } },
                settings_file = "/tmp/x/opds.lua" }
package.loaded["apps/filemanager/filemanager"] = { instance = { stock } }
package.loaded["apps/reader/readerui"] = { instance = nil }

local Src = dofile("lib/bookshelf_opds_source.lua")

local pass, fail = 0, 0
local function ok(c, l) if c then pass=pass+1 else fail=fail+1; print("FAIL "..l) end end

ok(Src.liveInstance() == stock, "liveInstance finds the stock module by identity")
ok(Src._liveServers() == stock.servers, "_liveServers still returns the servers table")

package.loaded["apps/filemanager/filemanager"] = { instance = nil }
ok(Src.liveInstance() == nil, "no instance -> nil")

print(string.format("opds_source_live: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
