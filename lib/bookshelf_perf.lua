--[[
Interaction timing, as "[bookshelf perf]" log lines (logger.dbg, like the
rest of the codebase's timing; Perf.loud sends them to the warn level for a
measuring session with debug logging off -- it swamps the log with per-spine
lines, and that distorts the very timings being taken).

A span is one interaction: start() where the tap lands, part() for each step
on the way, finish() once its screen has painted. One line per interaction:

  [bookshelf perf] editor select: 412ms to editor painted (grid 301, cell
  shelf 220, bars 18, paint grid 60, paint editor 31)
]]
local _gettime
do
    local ok, s = pcall(require, "socket")
    _gettime = (ok and s and type(s.gettime) == "function")
        and function() return s.gettime() end
        or  os.clock
end

local M = { loud = false }

M.now = _gettime

function M.log(fmt, ...)
    -- Required here: tests load the modules that time themselves without it.
    local logger = require("logger")
    local line = "[bookshelf perf] " .. string.format(fmt, ...)
    if M.loud then logger.warn(line) else logger.dbg(line) end
end

--- start(label): a new interaction (one already open is replaced: its
--- screen never painted, or another tap came first).
function M.start(label)
    M._span = { label = label, t0 = _gettime(), parts = {} }
end

--- active() -> true while a span is open.
function M.active() return M._span ~= nil end

--- part(name, since): a step of the open span, timed from `since` (a now()).
function M.part(name, since)
    local s = M._span
    if not s then return end
    s.parts[#s.parts + 1] = string.format("%s %.0f", name, (_gettime() - since) * 1000)
end

--- finish(where): log the open span, timed to now.
function M.finish(where)
    local s = M._span
    if not s then return end
    M._span = nil
    M.log("%s: %.0fms to %s (%s)", s.label, (_gettime() - s.t0) * 1000, where,
        table.concat(s.parts, ", "))
end

return M
