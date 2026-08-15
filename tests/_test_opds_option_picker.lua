-- tests/_test_opds_option_picker.lua
-- Editor:_pickOpdsOption -- which row a catalog's radio list opens ticked.
--
-- A chip that has never set the field stores nothing, and the list ticked
-- NOTHING: `active = draft[field] == opt.value`, and nil equals no option. On
-- device that read as a setting nobody had chosen, over a catalog that was
-- very much refreshing (or not) according to a default. Caught in a release
-- screenshot of the refresh list with no row marked.
--
-- The rule is that options[1] IS the default: every list here leads with it,
-- Prefs.labelFor already renders an unset chip as options[1], and
-- _test_opds_prefs holds that invariant for REFRESH_OPTIONS. This suite holds
-- the picker's half of the same bargain.
--
-- Driven against the real method body, extracted by name and run under a stub
-- env (as _test_jump_scan_list does) -- requiring the chip editor would pull
-- in the whole widget stack for four assertions about a checkmark.
package.path = "./?.lua;./?/init.lua;" .. package.path

local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local src  = io.open("lib/bookshelf_chip_editor.lua"):read("*a")
local body = src:match(
    "\nfunction Editor:_pickOpdsOption%(draft, field, options, title, on_close%)\n(.-)\nend\n")
assert(body, "could not find Editor:_pickOpdsOption - renamed?")

-- The real radioRow, extracted the same way, so the checkmark convention under
-- test is the shipped one rather than a guess about it. Requiring the kit
-- outright pulls in the font stack.
local kit_src  = io.open("lib/bookshelf_module_kit.lua"):read("*a")
local kit_body = kit_src:match("\nfunction Kit.radioRow%(o%)\n(.-)\nend\n")
assert(kit_body, "could not find Kit.radioRow - renamed?")
-- The chunk IS the function: called with `o`, it returns the row.
local Kit = { radioRow = assert(
    (_G.loadstring or _G.load)("local o = ...\n" .. kit_body, "radioRow")) }

local shown
local env = {
    ipairs = ipairs, pairs = pairs, type = type, tostring = tostring,
    _ = function(s) return s end,
    require = function(mod)
        if mod == "ui/uimanager" then
            return { show = function(_, d) shown = d end, close = function() end }
        elseif mod == "ui/widget/buttondialog" then
            return { new = function(_, o) return o end }
        elseif mod == "lib/bookshelf_module_kit" then
            return Kit
        end
        error("picker required an unexpected module: " .. tostring(mod))
    end,
}
env._G = env

local function compile(code)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, "_pickOpdsOption"))
        _G.setfenv(f, env)
        return f
    end
    return assert(load(code, "_pickOpdsOption", "t", env))
end
local run = compile(
    "local self, draft, field, options, title, on_close = ...\n" .. body)

local OPTIONS = {
    { value = -1,   label_func = function() return "Only when I swipe down" end },
    { value = 300,  label_func = function() return "If it's over 5 minutes old" end },
    { value = 3600, label_func = function() return "If it's over an hour old" end },
    { value = 0,    label_func = function() return "Every time I open it" end },
}

-- Which labels came back ticked. radioRow prefixes U+2713 when active.
local function tickedRows(draft)
    shown = nil
    run({}, draft, "opds_refresh_age", OPTIONS, "Refresh", nil)
    local ticked = {}
    for _i, row in ipairs(shown and shown.buttons or {}) do
        local btn = row[1]
        if btn and btn.text and btn.text:find("\xE2\x9C\x93", 1, true) then
            ticked[#ticked + 1] = (btn.text:gsub("^%s*\xE2\x9C\x93%s*", ""))
        end
    end
    return ticked
end

t.test("an untouched chip opens ticked on the default, not on nothing", function()
    local ticked = tickedRows({})
    eq(#ticked, 1, "rows ticked:")
    eq(ticked[1], "Only when I swipe down", "the ticked row:")
end)

t.test("a chip that chose something opens on that", function()
    local ticked = tickedRows({ opds_refresh_age = 3600 })
    eq(#ticked, 1, "rows ticked:")
    eq(ticked[1], "If it's over an hour old", "the ticked row:")
end)

t.test("the every-time option is not mistaken for unset", function()
    -- 0 is a real value and a falsy-looking one. It is truthy in Lua, so
    -- `draft[field] or default` is correct here - but the trap is one line
    -- away in any language where it is not, so pin the behaviour.
    local ticked = tickedRows({ opds_refresh_age = 0 })
    eq(#ticked, 1, "rows ticked:")
    eq(ticked[1], "Every time I open it", "the ticked row:")
end)

t.test("exactly one row is ever ticked", function()
    for _i, v in ipairs({ -1, 300, 3600, 0 }) do
        eq(#tickedRows({ opds_refresh_age = v }), 1,
           "rows ticked for stored value " .. v .. ":")
    end
end)

t.done()
