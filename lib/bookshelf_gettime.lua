-- lib/bookshelf_gettime.lua
-- THE wall-clock for [bookshelf perf] instrumentation (and reader_park's
-- input-idle bookkeeping): LuaSocket's gettime() gives fractional seconds
-- including I/O waits. Falls back to os.time (integer wall seconds) where
-- LuaSocket is absent (the standalone test harness) - coarse, but still WALL
-- time. The ten per-file copies this replaces had drifted between os.clock
-- (CPU-only, which freezes during idle waits and would break reader_park's
-- idle measurement) and os.time, so the "shared clock" the comments promised
-- wasn't actually shared under fallback.
--
-- Returns the function itself:
--   local _gettime = require("lib/bookshelf_gettime")

local ok, s = pcall(require, "socket")
if ok and s and type(s.gettime) == "function" then
    return function() return s.gettime() end
end
return os.time
