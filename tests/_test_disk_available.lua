-- tests/_test_disk_available.lua
-- _diskAvailable: free space without forking.
--
-- util.diskUsage shells out to `df -kP | awk` through io.popen, forking the
-- whole KOReader process: 27.5ms on a PW5 against 0.42ms for the statvfs call
-- df wraps. It sits on the hero's 60s slow tier, so the cost lands in full on
-- whichever interaction crosses the TTL boundary.
--
-- What these pin is the FALLBACK, because that is where the risk is: if
-- statvfs is unavailable or fails and the fallback is broken, %disk silently
-- disappears from the status line rather than erroring. Also pinned is
-- f_bavail (not f_bfree), which is what df's "Available" column reports --
-- f_bfree counts the root reserve and reads high on ext4.
--
-- Driven against the real function body, extracted by name, as
-- _test_preload_arming does for methods.
package.path = "./?.lua;./?/init.lua;" .. package.path

local t   = dofile("tests/_helpers.lua").runner()
local src = io.open("lib/bookshelf_widget.lua"):read("*a")

local body = src:match("\nlocal function _diskAvailable%(path%)\n(.-)\nend\n")
assert(body, "could not find _diskAvailable - renamed?")

local function compile(code, env, name)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, name))
        _G.setfenv(f, env)
        return f
    end
    return assert(load(code, name, "t", env))
end

-- opts.statvfs_rc   : return code from statvfs (0 = success)
-- opts.bavail/frsize: values the stub struct reports
-- opts.ffi_throws   : require("ffi") raises
-- opts.disk_usage   : what util.diskUsage returns (nil = module absent)
local function run(opts)
    opts = opts or {}
    local calls = { statvfs = 0, disk_usage = 0 }
    local env = {
        pcall = pcall, tonumber = tonumber, type = type, error = error,
        require = function(name)
            if name == "ffi" then
                if opts.ffi_throws then error("no ffi here") end
                return {
                    new = function() return { f_bavail = 0, f_frsize = 0 } end,
                    C = {
                        statvfs = function(_path, st)
                            calls.statvfs = calls.statvfs + 1
                            st.f_bavail = opts.bavail or 0
                            st.f_frsize = opts.frsize or 0
                            return opts.statvfs_rc or 0
                        end,
                    },
                }
            end
            if name == "ffi/posix_h" then return true end
            if name == "util" then
                if opts.no_util then error("no util") end
                return {
                    diskUsage = function()
                        calls.disk_usage = calls.disk_usage + 1
                        return opts.disk_usage
                    end,
                }
            end
            error("unexpected require: " .. tostring(name))
        end,
    }
    local fn = compile("local path = ...\n" .. body, env, "_diskAvailable")
    return fn("/mnt/us"), calls
end

t.test("uses statvfs f_bavail * f_frsize, and does not fork", function()
    local v, calls = run{ bavail = 100, frsize = 4096 }
    assert(v == 409600, "wanted 409600, got " .. tostring(v))
    assert(calls.statvfs == 1, "statvfs not called")
    assert(calls.disk_usage == 0, "forked to df even though statvfs worked")
end)

t.test("falls back to util.diskUsage when statvfs reports failure", function()
    -- Non-zero bavail/frsize deliberately: with zeros, dropping the return
    -- code check would still yield 0, the >0 guard would reject it, and the
    -- fallback would run anyway -- so the test would pass against the bug.
    local v, calls = run{ statvfs_rc = -1, bavail = 9, frsize = 1024,
                          disk_usage = { available = 777 } }
    assert(v == 777, "wanted the fallback value, got " .. tostring(v))
    assert(calls.disk_usage == 1, "fallback was not used")
end)

t.test("falls back when ffi is unavailable", function()
    local v, calls = run{ ffi_throws = true, disk_usage = { available = 555 } }
    assert(v == 555, "wanted the fallback value, got " .. tostring(v))
    assert(calls.disk_usage == 1, "fallback was not used")
end)

t.test("falls back when statvfs reports zero free space", function()
    -- A zero here means the call did not really work: a mounted filesystem
    -- with genuinely 0 bytes free would show the same, and re-asking df is
    -- cheap in that corner compared with reporting a wrong 0 in the status line.
    local v = run{ bavail = 0, frsize = 4096, disk_usage = { available = 42 } }
    assert(v == 42, "zero from statvfs should fall through, got " .. tostring(v))
end)

t.test("returns nil when neither source works, rather than erroring", function()
    local v = run{ statvfs_rc = -1, disk_usage = nil }
    assert(v == nil, "wanted nil, got " .. tostring(v))
end)

t.test("survives util being unavailable too", function()
    local ok, v = pcall(run, { statvfs_rc = -1, no_util = true })
    assert(ok, "should not propagate the require failure")
    assert(v == nil, "wanted nil, got " .. tostring(v))
end)

t.done()
