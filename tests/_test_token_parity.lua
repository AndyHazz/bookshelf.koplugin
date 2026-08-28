-- tests/_test_token_parity.lua
-- The #348 regression net: bookshelf's LIVE expanders, driven with the same
-- inputs the shared fixture uses, must produce the fixture's strings. This is
-- what actually catches drift - _test_token_semantics only proves the vendored
-- copy is intact, not that bookshelf USES it, and it passes either way.
-- Usage: cd into the plugin dir, then `lua tests/_test_token_parity.lua`.

package.loaded["device"] = {
    getPowerDevice  = function() return nil end,
    isKindle        = function() return false end,
    hasNaturalLight = function() return true end,
    home_dir        = "/",
}
-- Signature matches KOReader's real datetime: (format, seconds, withoutSeconds).
package.loaded["datetime"] = {
    secondsToClockDuration = function(fmt, secs)
        if not secs or secs <= 0 then return "" end
        if fmt == "letters" then
            return string.format("%dh%dm", math.floor(secs / 3600),
                                 math.floor((secs % 3600) / 60))
        end
        return string.format("%d:%02d", math.floor(secs / 3600),
                             math.floor((secs % 3600) / 60))
    end,
}
local _i18n_stub = {
    gettext  = function(t) return t end,
    ngettext = function(s, p, n) return n == 1 and s or p end,
}
package.loaded["bookshelf_i18n"] = _i18n_stub
package.loaded["lib/bookshelf_i18n"] = _i18n_stub
_G.G_reader_settings = setmetatable({}, {
    __index = function() return function() return false end end,
})

local t = dofile("tests/_helpers.lua").runner()
local Tokens = dofile("lib/bookshelf_tokens.lua")

-- A device-state table shaped the way _buildDeviceState builds one. It carries
-- BOTH the pre-#348 field names and the post-fix ones, so this suite's failure
-- output shows what bookshelf actually printed rather than merely reporting a
-- missing field. The legacy names become dead once the expanders are rewired.
local function state()
    return {
        batt = 82, charging = false, charged = true,
        wifi = "on", connected = "no",          -- radio up, NO link
        light = 0, light_pct = 0, fl_max = 24,
        warmth = 50,                            -- legacy: the 0-100 value
        warmth_native = 12, warmth_pct = 50, has_natural_light = true,
        mem = 38,           mem_total = 1000, mem_available = 624,
        ram_mib = 84,       ram_kb = 86016,
        sysused_mib = 84,   sysused_bytes = 88080384,
        disk_free = "12.3G", disk_bytes = 13207024435,
        duration_format = "classic",
    }
end

t.test("%light words zero as OFF (#348)", function()
    local got = Tokens.expanders.light(nil, state())
    assert(got == "OFF", 'expected "OFF" got "' .. tostring(got) .. '"')
end)

t.test("%warmth uses the native device scale (#348)", function()
    local got = Tokens.expanders.warmth(nil, state())
    assert(got == "12", 'expected "12" got "' .. tostring(got) .. '"')
end)

t.test("%wifi reflects the link, not just the radio (#348)", function()
    local got = Tokens.expanders.wifi(nil, state())
    assert(got == "\xEE\xB2\xA9",
           "radio on but unlinked must show wifi-off")
end)

t.test("%ram uses the short M suffix (#348)", function()
    local got = Tokens.expanders.ram(nil, state())
    assert(got == "84M", 'expected "84M" got "' .. tostring(got) .. '"')
end)

t.test("%mem truncates rather than rounds (#348)", function()
    local got = Tokens.expanders.mem(nil, state())
    assert(got == "37%", 'expected "37%" got "' .. tostring(got) .. '"')
end)

t.test("%batt_icon passes isCharged through (#348)", function()
    local seen = {}
    package.loaded["device"] = {
        getPowerDevice = function()
            return {
                getBatterySymbol = function(_self, charged, charging, cap)
                    seen.charged, seen.charging, seen.cap = charged, charging, cap
                    return "SYM"
                end,
            }
        end,
        hasNaturalLight = function() return true end,
        home_dir = "/",
    }
    Tokens.expanders.batt_icon(nil, state())
    assert(seen.charged == true,
           "charged must arrive as true, got " .. tostring(seen.charged))
end)

t.test("%book_read_time honours duration_format (#348)", function()
    local book = { book_read_time_seconds = 11100 }
    local got = Tokens.expanders.book_read_time(book, state())
    assert(got == "3:05", 'expected "3:05" got "' .. tostring(got) .. '"')
end)

t.done()
