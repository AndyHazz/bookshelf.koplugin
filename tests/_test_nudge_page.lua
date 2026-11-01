-- tests/_test_nudge_page.lua
-- The size nudges (font scales, start menu width) are a slim page low on the
-- screen with a slider (maintainer: not keen on the stepper and chips; a
-- slider), Cancel | Done. Locked as before: a stray tap outside does not
-- close it mid-edit, and the chip-bar nudge opens under the bar it resizes.
--
-- Usage (from plugin root): lua tests/_test_nudge_page.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

local src = io.open("lib/bookshelf_settings.lua"):read("*a")
local body = src:match("\n(function Settings:_nudgePage%(.-\nend)\n")
assert(body, "no Settings:_nudgePage")

local function open(spec)
    local saved, state = { k = spec.start }, { previews = 0, restored = 0, refreshes = 0 }
    local env = setmetatable({
        Settings = {},
        _ = function(s) return s end,
        T = function(s, a) return (s:gsub("%%1", tostring(a))) end,
        BookshelfSettings = { read = function(k, d) local v = saved[k]; if v == nil then return d end; return v end,
            -- save() writes the file; saveDeferred() keeps it in memory.
            save = function(k, v) saved[k] = v; state.writes = (state.writes or 0) + 1 end,
            saveDeferred = function(k, v) saved[k] = v end },
        -- The preview waits for the taps to pause (scheduleIn); here it runs
        -- at once, so each change shows as before.
        UIManager = { close = function() state.closed = true end, setDirty = function() end,
                      scheduleIn = function(_s, _t, f) f() end, unschedule = function() end },
        require = function(n)
            if n == "lib/bookshelf_page_dialog" then
                return { show = function(o)
                    state.dlg = o
                    o.refresh = function() state.refreshes = state.refreshes + 1 end
                    return o
                end }
            end
            if n == "ui/widget/buttondialog" then error("still a ButtonDialog") end
            return require(n)
        end,
    }, { __index = _G })
    assert(load(body, "nudge", "t", env))()
    local self = setmetatable({
        _plugin = { hideMenu = function() return function() state.restored = state.restored + 1 end end },
        _bw = { _rebuild = function() end },
    }, { __index = env.Settings })
    spec.key = "k"
    spec.preview = function() state.previews = state.previews + 1 end
    self:_nudgePage(nil, spec)
    return state, saved
end

local function slider(st)
    for _i, b in ipairs(st.dlg.page().blocks) do
        if b.type == "slider" then return b end
    end
end

local SPEC = { title = "T", default = 100, min = 50, max = 200, fine = 5, unit = "%", start = 120 }
local function spec() local o = {}; for k, v in pairs(SPEC) do o[k] = v end; return o end

t.test("a slider over the range, Default marked, a slim panel at the bottom", function()
    local st = open(spec())
    local s = slider(st)
    eq(s.value, 120); eq(s.min, 50); eq(s.max, 200); eq(s.step, 5); eq(s.default, 100)
    eq(s.format(120), "120%")
    eq(st.dlg.at_bottom, true)
    eq(s.big, 10, "no -10 / +10 either side")
    eq(st.dlg.footer[1].text, "Cancel"); eq(st.dlg.footer[2].text, "Default"); eq(st.dlg.footer[3].text, "Done")
end)

t.test("a change saves, previews and redraws; clamped to the range", function()
    local st, saved = open(spec())
    slider(st).on_change(150)
    eq(saved.k, 150); eq(st.previews, 1); eq(st.refreshes, 1)
    slider(st).on_change(999)
    eq(saved.k, 200)
    slider(st).on_change(200)
    eq(st.previews, 2, "the same value previewed again")
end)

t.test("Cancel and the X put the value back; Done and a tap outside keep it; the menu comes back", function()
    local st, saved = open(spec())
    slider(st).on_change(150)
    st.dlg.footer[1].callback()
    eq(saved.k, 120); eq(st.restored, 1)
    st, saved = open(spec())
    slider(st).on_change(150)
    st.dlg.on_close()
    eq(saved.k, 120); eq(st.restored, 1)
    st, saved = open(spec())
    slider(st).on_change(150)
    st.dlg.footer[3].callback()
    eq(saved.k, 150); eq(st.restored, 1)
    -- A tap outside is Done (the shelf paged behind it to judge the change).
    st, saved = open(spec())
    slider(st).on_change(150)
    st.dlg.on_tap_outside()
    eq(saved.k, 150); eq(st.restored, 1)
end)

t.test("Default in the footer: greyed at the default, sets it", function()
    local st, saved = open(spec())
    eq(st.dlg.footer[2].enabled_func(), true)
    st.dlg.footer[2].callback()
    eq(saved.k, 100)
    eq(st.dlg.footer[2].enabled_func(), false)
end)

t.test("the scale nudges and the start menu's use it, none a ButtonDialog", function()
    for _i, name in ipairs({ "_showScaleNudge", "_pickStartMenuFontScale", "_pickStartMenuMinWidth" }) do
        local b = src:match("\nfunction Settings:" .. name .. "%(.-\nend\n")
        assert(b, name .. " moved")
        assert(b:find("self:_nudgePage(", 1, true), name .. " does not use the page")
        assert(not b:find("buttondialog", 1, true), name .. " still builds a ButtonDialog")
    end
end)

-- Review 2026-10-31: every step rewrote the whole settings file (~130 ms on
-- a PW5). Steps stay in memory; the page writes once as it closes.
t.test("the steps are kept in memory and written once, as the page closes", function()
    local src = io.open("lib/bookshelf_settings.lua"):read("*a")
    local b = src:match("\nfunction Settings:_nudgePage%(.-\nend\n")
    local set = b:match("local function setValue%(v%)(.-)\n    end\n")
    assert(set and set:find("BookshelfSettings.saveDeferred(key, v)", 1, true) and not set:find("BookshelfSettings.save(", 1, true),
        "a step writes the settings file")
    assert(b:find("if getValue() ~= original then BookshelfSettings.save(key, getValue()) end", 1, true),
        "nothing writes it on close, or it writes an unchanged value")
end)

t.done()
