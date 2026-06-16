-- Unit test for lib/bookshelf_action_chooser.lua. We stub the System-action
-- picker so triggering that row's callback synchronously yields fields, and
-- assert the field shape passed to on_pick. (Plugin/Bookshelf rows open live UI
-- and are verified on-device.)
package.path = "./?.lua;./?/init.lua;" .. package.path

package.loaded["ui/uimanager"]   = { show=function() end, close=function() end }
package.loaded["ui/widget/buttondialog"] = { new=function(_, o) return o end }
package.loaded["ui/widget/notification"] = { new=function(_, o) return o end }
package.loaded["logger"] = { dbg=function() end, info=function() end,
    warn=function() end, err=function() end }
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
package.loaded["lib/bookshelf_action_picker"] = {
    show = function(opts) opts.on_pick({ stats_calendar_view = true }, "Calendar") end,
}

local Chooser = dofile("lib/bookshelf_action_chooser.lua")
local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()

t.test("actionRows returns the three action choices", function()
    local rows = Chooser.actionRows(function(fn) return fn end, function() end)
    assert(#rows == 3, "expected 3 rows, got " .. #rows)
    assert(rows[1][1].text and rows[2][1].text and rows[3][1].text,
        "each row needs a labelled button")
end)

t.test("System action row yields {label, action} to on_pick", function()
    local got
    -- close is identity here: it returns the callback unchanged so we can fire
    -- it directly.
    local rows = Chooser.actionRows(function(fn) return fn end,
        function(fields) got = fields end)
    rows[2][1].callback()   -- System action row
    assert(got and got.label == "Calendar", "label not set from action name")
    assert(got.action and got.action.stats_calendar_view == true,
        "action table not passed through")
    assert(got.plugin == nil and got.internal == nil, "should be action-only")
end)

t.done()
