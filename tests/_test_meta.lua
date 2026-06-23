-- Guards _meta.lua's `name` field. It MUST be present and equal to the plugin
-- directory id ("bookshelf"). Removing it (to silence the deprecation warning on
-- current KOReader) broke enable/disable on stable releases up to ~v2025.10,
-- which still key plugins_disabled by `name`: a disabled Bookshelf could not be
-- re-enabled. See the comment in _meta.lua. This test stops a future "tidy-up"
-- from reintroducing the regression.
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }

local t = dofile("tests/_helpers.lua").runner()

t.test("_meta.lua declares name == the directory id 'bookshelf'", function()
    local meta = dofile("_meta.lua")
    assert(type(meta) == "table", "_meta.lua must return a table")
    assert(meta.name == "bookshelf",
        "_meta.lua must set name = \"bookshelf\" (the .koplugin directory id) so "
        .. "enable/disable tracking keys consistently on older KOReader; got "
        .. tostring(meta.name))
    assert(type(meta.version) == "string", "_meta.lua must carry a version string")
end)

t.done()
