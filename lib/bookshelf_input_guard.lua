-- lib/bookshelf_input_guard.lua
-- Taps made while a book opens must not reach the book (issue 610).
--
-- KOReader ignores touch while a reader loads (Input:inhibitInput) and lifts
-- that 0.2 s after the load from a UIManager task. Ignoring works by voiding
-- events as they are READ, but nothing reads input during the load: the taps
-- wait in the kernel's queue. On a slow e-ink device the reader's first paint
-- and refresh take longer than 0.2 s, so the task that lifts the guard is
-- already overdue the next time the loop runs, and it runs before the loop
-- reads input. Every tap made during the load then reaches the reader as a
-- page turn (seen on a PW5: four taps made mid-load turned four pages, read
-- 8 s after they were made).
--
-- arm() marks the next lift of the guard. When it comes, everything still
-- queued is read first, while the guard is still up: touches are voided as
-- KOReader meant, and the power button (still handled while inhibited) is
-- passed on as usual.

local M = {}

local armed = false
local installed = false

-- Read and dispatch whatever is queued, without waiting. Input:waitEvent
-- returns a (possibly empty) list per read, and nil once nothing is left.
function M._drain(input)
    local UIManager = require("ui/uimanager")
    local time = require("ui/time")
    for _i = 1, 200 do
        local now = time.now()
        local ok, evs = pcall(input.waitEvent, input, now, now)
        if not ok or not evs then return end
        for _j, ev in ipairs(evs) do
            UIManager:handleInputEvent(ev)
        end
    end
end

function M.install()
    if installed then return true end
    local ok, Device = pcall(require, "device")
    local input = ok and Device and Device.input
    if not (input and input.inhibitInput and input.waitEvent) then return false end
    installed = true
    local orig = input.inhibitInput
    input.inhibitInput = function(self, toggle)
        if not toggle and armed then
            armed = false
            -- Only while touches are still voided: drained under any other
            -- handler, the taps would be delivered rather than dropped.
            if self.handleTouchEv == self.voidEv then
                pcall(M._drain, self)
            end
        end
        return orig(self, toggle)
    end
    return true
end

-- The next lift of the input guard drains the queue first.
function M.arm()
    if M.install() then armed = true end
end

function M.isArmed() return armed end

return M
