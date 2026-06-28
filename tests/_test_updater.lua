package.path = "./?.lua;./?/init.lua;" .. package.path

package.loaded["ui/widget/confirmbox"] = {}
package.loaded["device"] = {}
package.loaded["ui/widget/infomessage"] = {}
package.loaded["ui/uimanager"] = {}
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }

local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()
local eq = helpers.eq
local Updater = dofile("lib/bookshelf_updater.lua")
local test = Updater._test

t.test("semantic version comparison", function()
    eq(test.isNewer("3.5.4", "3.5.3"), true)
    eq(test.isNewer("3.5.3", "3.5.3"), false)
    eq(test.isNewer("3.5.2", "3.5.3"), false)
end)

t.test("different installed channel requires a switch", function()
    eq(test.branchState("master", "release", "", "abc"), "switch")
    eq(test.branchState("master", "branch:test", "abc", "abc"), "switch")
end)

t.test("legacy branch install establishes a baseline", function()
    eq(test.branchState("master", "branch:master", "", "abc"), "baseline")
end)

t.test("same branch commit is current", function()
    eq(test.branchState("master", "branch:master", "abc", "abc"), "current")
end)

t.test("changed branch commit is an update", function()
    eq(test.branchState("master", "branch:master", "abc", "def"), "update")
end)

t.done()
