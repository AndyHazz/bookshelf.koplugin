-- tests/_test_token_picker_shell.lua
-- SOURCE-SHAPE checks for which LibraryModal the token picker opens.
--
-- bookshelf_settings.lua is 5k lines and needs the full widget stack to load,
-- so these read the source -- named as such, per the repo's convention.
-- Comment lines are stripped first so prose quoting the patterns cannot
-- satisfy a check.
--
-- WHAT WENT WRONG. _pickToken used to require("menu.library_modal") -- the
-- copy that ships with the SISTER PLUGIN, bookends -- because bookshelf had
-- no shell of its own when it was written. It has one now, and every other
-- picker uses it. That one straggler meant the token picker's chrome depended
-- on whether a second plugin happened to be installed, and the two copies had
-- since diverged: ours grew swipe-to-page and grid dpad nav, bookends's did
-- not. Result on a machine with both installed: swipe paging worked in the
-- icon picker and silently did nothing in the token picker.
--
-- The last test is the one that earns its keep. It does not check a fixed
-- list of features; it reads the config keys the picker actually hands the
-- shell and insists our shell consumes each one, so the next key added to the
-- picker is checked too.

package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local function strip(path)
    local code = {}
    for line in io.lines(path) do
        if not line:match("^%s*%-%-") then code[#code + 1] = line end
    end
    return table.concat(code, "\n")
end

local settings = strip("lib/bookshelf_settings.lua")
local modal    = strip("lib/bookshelf_library_modal.lua")

-- Just the body of _pickToken, so a require elsewhere in the file (the
-- fallback's own requires, say) cannot answer for it.
local pick = settings:match("function Settings:_pickToken%(dialog, filter%)(.-)\nend\n")
assert(pick, "Settings:_pickToken is gone or was renamed")

t.test("the token picker opens bookshelf's own shell", function()
    -- The require goes through pcall, so match the module path rather than
    -- a require( call shape.
    assert(pick:find('"lib/bookshelf_library_modal"', 1, true),
        "the token picker no longer reaches for the bundled LibraryModal")
end)

t.test("the token picker does not reach into bookends", function()
    -- The whole bug: a soft dependency silently changing the chrome of a
    -- first-party surface, and drifting from it afterwards.
    assert(not pick:find("menu.library_modal", 1, true),
        "the token picker is back on bookends's copy of the modal")
end)

t.test("the bundled shell actually pages on a swipe", function()
    -- The symptom that exposed the divergence. Both directions, because
    -- half a pager is its own bug report.
    assert(modal:find("function LibraryModal:onSwipeNextPage", 1, true),
        "swipe-to-next-page is gone from the shell")
    assert(modal:find("function LibraryModal:onSwipePrevPage", 1, true),
        "swipe-to-prev-page is gone from the shell")
    assert(modal:find("SwipeNextPage = {", 1, true),
        "onSwipeNextPage exists but no gesture is registered for it")
    assert(modal:find("SwipePrevPage = {", 1, true),
        "onSwipePrevPage exists but no gesture is registered for it")
end)

t.test("the shell consumes every config key the token picker passes", function()
    local body = settings:match(
        "function Settings:_pickTokenViaLibraryModal.-\n        config = {\n(.-)\n        },")
    assert(body, "the token picker's config table could not be located")

    local keys = {}
    for line in (body .. "\n"):gmatch("(.-)\n") do
        local k = line:match("^            ([%w_]+) = ")
        if k then keys[#keys + 1] = k end
    end
    assert(#keys >= 10,
        "found only " .. #keys .. " config keys -- the pattern has gone stale")

    local missing = {}
    for _i, k in ipairs(keys) do
        if not modal:find("config." .. k, 1, true) then
            missing[#missing + 1] = k
        end
    end
    eq(#missing, 0, "the shell ignores: " .. table.concat(missing, ", "))
end)

t.done()
