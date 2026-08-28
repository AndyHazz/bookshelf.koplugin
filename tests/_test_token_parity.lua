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

-- The catalogue drives the token picker, so a token missing from it is
-- effectively unshipped. Bookshelf already carries orphans in the other
-- direction (catalogued or expanded tokens with no producer, copied over from
-- bookends, rendering empty forever); this is the guard against adding more.
t.test("every catalogued token has an expander", function()
    local missing = {}
    for _i, entry in ipairs(Tokens.CATALOGUE or {}) do
        local tok = tostring(entry.token or "")
        -- The catalogue is a PICKER catalogue, so it also holds snippets that
        -- are not bare tokens and have no expander by design: conditionals
        -- ([if:...]), inline style ([b], [font=NAME]), and braced forms
        -- (%bar{rel}, %calibre{name}) whose braces are parsed before the name
        -- loop runs. Only plain %name entries are expected to have producers.
        local name = tok:match("^%%([a-z_0-9]+)$")
        -- %bar and %spacer are elastic WIDGETS the renderer handles after
        -- expansion, so they deliberately have no expander either.
        if name and name ~= "bar" and name ~= "spacer"
           and type(Tokens.expanders[name]) ~= "function" then
            missing[#missing + 1] = tok
        end
    end
    assert(#missing == 0,
           "catalogued tokens with no producer: " .. table.concat(missing, " "))
end)

t.test("the warmth escape hatches are catalogued", function()
    local seen = {}
    for _i, entry in ipairs(Tokens.CATALOGUE or {}) do
        seen[tostring(entry.token or "")] = true
    end
    assert(seen["%warmth_pct"],  "%warmth_pct is not in the picker catalogue")
    assert(seen["%warmth_icon"], "%warmth_icon is not in the picker catalogue")
end)

t.done()
