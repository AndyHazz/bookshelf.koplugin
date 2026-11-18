-- tests/_test_input_guard.lua
-- lib/bookshelf_input_guard (issue 610): when the input guard lifts after a
-- book opens, taps still queued are read first, while touch is still voided.

package.path = "./?.lua;./?/init.lua;" .. package.path

local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()

local dispatched = {}
package.loaded["ui/uimanager"] = {
    handleInputEvent = function(_self, ev) dispatched[#dispatched + 1] = ev end,
}
package.loaded["ui/time"] = { now = function() return 0 end }

-- A fake Input: `queue` is what the kernel holds. Each read takes one batch;
-- touch batches come back empty while voided, as Input:waitEvent does.
local function fakeInput()
    local input = { queue = {}, log = {} }
    function input.voidEv() end
    function input.realTouch() end
    input.handleTouchEv = input.realTouch
    function input:inhibitInput(toggle)
        self.log[#self.log + 1] = toggle
        self.handleTouchEv = toggle and self.voidEv or self.realTouch
    end
    function input:waitEvent(_now, _deadline)
        local b = table.remove(self.queue, 1)
        if not b then return nil end
        if b.kind == "touch" then
            if self.handleTouchEv == self.voidEv then return {} end
            return { "TOUCH" }
        end
        return { b.kind }
    end
    return input
end

local function load(input)
    package.loaded["device"] = { input = input }
    package.loaded["lib/bookshelf_input_guard"] = nil
    dispatched = {}
    return dofile("lib/bookshelf_input_guard.lua")
end

t.test("armed: queued taps are drained while voided, then input is restored", function()
    local input = fakeInput()
    local G = load(input)
    input:inhibitInput(true)
    G.arm()
    input.queue = { { kind = "touch" }, { kind = "touch" }, { kind = "touch" }, { kind = "touch" } }
    input:inhibitInput(false)
    assert(#input.queue == 0, "queue drained")
    assert(#dispatched == 0, "no touch reached the UI")
    assert(input.handleTouchEv == input.realTouch, "guard lifted")
    assert(not G.isArmed(), "one shot")
end)

t.test("a power event queued during the load still gets through", function()
    local input = fakeInput()
    local G = load(input)
    input:inhibitInput(true)
    G.arm()
    input.queue = { { kind = "touch" }, { kind = "Suspend" } }
    input:inhibitInput(false)
    helpers.eq(dispatched, { "Suspend" })
end)

t.test("not armed: lifting the guard leaves the queue alone", function()
    local input = fakeInput()
    load(input)
    input:inhibitInput(true)
    input.queue = { { kind = "touch" } }
    input:inhibitInput(false)
    assert(#input.queue == 1)
end)

t.test("only the next lift drains", function()
    local input = fakeInput()
    local G = load(input)
    input:inhibitInput(true)
    G.arm()
    input:inhibitInput(false)
    input:inhibitInput(true)
    input.queue = { { kind = "touch" } }
    input:inhibitInput(false)
    assert(#input.queue == 1, "second lift did not drain")
end)

t.test("never drains with touch live (that would deliver the taps)", function()
    local input = fakeInput()
    local G = load(input)
    G.arm()
    input.queue = { { kind = "touch" } }
    input:inhibitInput(false)
    assert(#input.queue == 1)
    assert(#dispatched == 0)
end)

t.test("arming is inert without a usable Input", function()
    package.loaded["device"] = { input = { inhibitInputUntil = function() end } }
    package.loaded["lib/bookshelf_input_guard"] = nil
    local G = dofile("lib/bookshelf_input_guard.lua")
    G.arm()
    assert(not G.isArmed())
end)

t.done()
