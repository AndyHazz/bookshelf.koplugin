-- tests/_test_battery_module.lua
-- The battery micro-module (issue 342): what it reads from PowerD and the
-- wording it builds, without a device.
--
-- Usage (from plugin root): lua tests/_test_battery_module.lua

package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local function stub(name, v) package.loaded[name] = v end
stub("lib/bookshelf_i18n", { gettext = function(s) return s end })
stub("ffi/util", { template = function(s, ...)
    local a = { ... }
    return (s:gsub("%%([1-9])", function(i) return tostring(a[tonumber(i)]) end))
end })

local powerd
stub("device", { getPowerDevice = function() return powerd end })

local spec = dofile("micromodules/battery.lua")
local read, lines = spec._test.read, spec._test.lines

local function mkPowerD(o)
    return {
        getCapacity = function() return o.cap end,
        isCharging = function() return o.charging end,
        isCharged = function() return o.charged end,
        getBatterySymbol = function(_s, charged, charging, cap)
            return (charged and "F" or charging and "C" or "B") .. cap
        end,
        isAuxBatteryConnected = function() return o.aux ~= nil end,
        getAuxCapacity = function() return o.aux end,
        isAuxCharging = function() return o.aux_charging end,
        device = { hasAuxBattery = function() return o.has_aux end },
    }
end

t.test("spec shape", function()
    eq(spec.key, "battery")
    eq(type(spec.render), "function")
    eq(spec.wants_minute_tick, true)
    eq(type(spec.on_tap), "function")
end)

t.test("discharging: glyph, percent, remaining", function()
    powerd = mkPowerD{ cap = 78 }
    local s = read()
    eq(s.cap, 78); eq(s.charging, false); eq(s.symbol, "B78")
    local v, suf, sub = lines(s)
    eq(v, "B78 78%"); eq(suf, " remaining"); eq(sub, nil)
end)

t.test("charging and charged pass through to the glyph", function()
    powerd = mkPowerD{ cap = 40, charging = true }
    local v, suf = lines(read())
    eq(v, "C40 40%"); eq(suf, " charging")
    powerd = mkPowerD{ cap = 100, charging = true, charged = true }
    v, suf = lines(read())
    eq(v, "F100 100%"); eq(suf, " charged")
end)

t.test("cover battery only when the device has one and it is attached", function()
    powerd = mkPowerD{ cap = 50, aux = 60 }
    eq(read().aux_cap, nil)
    powerd = mkPowerD{ cap = 50, aux = 60, has_aux = true }
    local _v, _s, sub = lines(read())
    eq(sub, "Cover: 60%")
    powerd = mkPowerD{ cap = 50, aux = 60, has_aux = true, aux_charging = true }
    _v, _s, sub = lines(read())
    eq(sub, "Cover: 60% (charging)")
end)

t.test("no PowerD or a bad capacity reads as unavailable", function()
    powerd = nil
    eq(read(), nil)
    powerd = mkPowerD{ cap = "?" }
    eq(read(), nil)
    powerd = { getCapacity = function() error("boom") end }
    eq(read(), nil)
end)

t.test("capacity is clamped and rounded; no symbol leaves just the percent", function()
    powerd = mkPowerD{ cap = 104.6 }
    powerd.getBatterySymbol = nil
    local s = read()
    eq(s.cap, 100)
    eq((lines(s)), "100%")
end)

t.done()
