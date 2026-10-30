-- tests/_test_nudge_page.lua
-- The size nudges (font scales, start menu width) are a page (STYLE.md):
-- a stepper, not a greyed button holding the value between -10/-5/+5/+10;
-- the bigger steps and Default as chips; Cancel | Apply in the footer.
-- Locked as before: a stray tap outside does not close it mid-edit, and
-- the chip-bar nudge opens under the bar it resizes.
--
-- Usage (from plugin root): lua tests/_test_nudge_page.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

local src = io.open("lib/bookshelf_settings.lua"):read("*a")
local body = src:match("\n(function Settings:_nudgePage%(.-\nend)\n")
assert(body, "no Settings:_nudgePage")

local function open(spec)
    local saved, state = { k = spec.start }, { previews = 0, restored = 0, rebuilds = 0, refreshes = 0 }
    local env = setmetatable({
        Settings = {},
        _ = function(s) return s end,
        T = function(s, a) return (s:gsub("%%1", tostring(a))) end,
        BookshelfSettings = { read = function(k, d) local v = saved[k]; if v == nil then return d end; return v end,
            save = function(k, v) saved[k] = v end },
        UIManager = { close = function() state.closed = true end, setDirty = function() end },
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
        _bw = { _rebuild = function() state.rebuilds = state.rebuilds + 1 end },
    }, { __index = env.Settings })
    spec.key = "k"
    spec.preview = function() state.previews = state.previews + 1 end
    self:_nudgePage(nil, spec)
    return state, saved
end

local function find(model, type_, pred)
    for _i, b in ipairs(model.blocks) do
        if b.type == type_ and (not pred or pred(b)) then return b end
    end
end

t.test("a stepper, the bigger steps and Default as chips, Cancel | Apply", function()
    local st = open{ title = "Text size", default = 100, min = 50, max = 200, fine = 5, big = 10, unit = "%", start = 120 }
    local m = st.dlg.page()
    local step = find(m, "stepper")
    eq(step.value, "120%")
    local chips = find(m, "chips")
    local texts = {}
    for i, it in ipairs(chips.items) do texts[i] = it.text end
    eq(table.concat(texts, " "), "\xE2\x88\x9210 +10 Default")
    eq(#st.dlg.footer, 2)
    eq(st.dlg.dismissable, false)
end)

t.test("each step saves, previews and redraws; clamped to the range", function()
    local st, saved = open{ title = "T", default = 100, min = 50, max = 130, fine = 5, big = 10, unit = "%", start = 120 }
    find(st.dlg.page(), "stepper").on_inc()
    eq(saved.k, 125); eq(st.previews, 1); eq(st.refreshes, 1)
    find(st.dlg.page(), "chips").items[2].callback()
    eq(saved.k, 130, "not clamped to max")
    find(st.dlg.page(), "chips").items[3].callback()
    eq(saved.k, 100)
    assert(find(st.dlg.page(), "chips").items[3].enabled == false, "Default is offered at the default")
end)

t.test("Cancel and the X put the value back; Apply keeps it; the menu comes back", function()
    local st, saved = open{ title = "T", default = 100, min = 50, max = 200, fine = 5, big = 10, unit = "%", start = 120 }
    find(st.dlg.page(), "stepper").on_inc()
    st.dlg.footer[1].callback()          -- Cancel
    eq(saved.k, 120); eq(st.restored, 1)
    st, saved = open{ title = "T", default = 100, min = 50, max = 200, fine = 5, big = 10, unit = "%", start = 120 }
    find(st.dlg.page(), "stepper").on_inc()
    st.dlg.on_close()                    -- the X / Back
    eq(saved.k, 120); eq(st.restored, 1)
    st, saved = open{ title = "T", default = 100, min = 50, max = 200, fine = 5, big = 10, unit = "%", start = 120 }
    find(st.dlg.page(), "stepper").on_inc()
    st.dlg.footer[2].callback()          -- Apply
    eq(saved.k, 125); eq(st.restored, 1)
end)

t.test("the summary says what the value means", function()
    local st = open{ title = "T", default = 100, min = 50, max = 200, fine = 5, big = 10, unit = "%", start = 100 }
    eq(st.dlg.page().strip[1].text, "The normal size.")
    st = open{ title = "T", default = 100, min = 50, max = 200, fine = 5, big = 10, unit = "%", start = 120 }
    eq(st.dlg.page().strip[1].text, "120% of the normal size.")
end)

t.test("the scale nudges and the start menu's use it, none a ButtonDialog", function()
    for _i, name in ipairs({ "_showScaleNudge", "_pickStartMenuFontScale", "_pickStartMenuMinWidth" }) do
        local b = src:match("\nfunction Settings:" .. name .. "%(.-\nend\n")
        assert(b, name .. " moved")
        assert(b:find("self:_nudgePage(", 1, true), name .. " does not use the page")
        assert(not b:find("buttondialog", 1, true), name .. " still builds a ButtonDialog")
    end
end)

t.done()
