-- tests/_test_hardcover_key.lua
-- Where Bookshelf finds a Hardcover API key (lib/bookshelf_hardcover_key):
-- its own, else one a sync plugin already holds, read from that plugin's
-- file each time and never copied unless the reader asks.
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t, eq = helpers.runner(), helpers.eq

-- A fake filesystem: path -> contents.
local files
local real_open = io.open
io.open = function(path, mode)
    if type(path) == "string" and path:sub(1, 4) == "/fs/" then
        mode = mode or "r"
        if mode:find("r", 1, true) then
            local body = files[path]
            if not body then return nil, "no such file" end
            return { read = function() return body end, close = function() end }
        end
        local buf = {}
        return {
            write = function(_s, ...) for _i, v in ipairs({ ... }) do buf[#buf + 1] = v end return true end,
            close = function() files[path] = table.concat(buf) end,
        }
    end
    return real_open(path, mode)
end
local removed = {}
local real_remove = os.remove
os.remove = function(path)
    if type(path) == "string" and path:sub(1, 4) == "/fs/" then
        removed[#removed + 1] = path; files[path] = nil; return true
    end
    return real_remove(path)
end

package.loaded["datastorage"] = {
    getDataDir = function() return "/fs/ko" end,
    getSettingsDir = function() return "/fs/ko/settings" end,
}
package.loaded["lib/bookshelf_paths"] = {
    settingsFile = function(name) return "/fs/ko/settings/bookshelf/" .. name end,
}
local extra
_G.G_reader_settings = { readSetting = function(_s, k) if k == "extra_plugin_paths" then return extra end end }

local Key = dofile("lib/bookshelf_hardcover_key.lua")

local TOKEN = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.abc-DEF_123"
local function reset()
    files, extra, removed = {}, nil, {}
    Key.invalidate()
end

t.test("nothing anywhere: no key", function()
    reset()
    local tok, src = Key.get()
    eq(tok, nil); eq(src, nil)
    eq(Key.available(), false)
end)

t.test("the Hardcover plugin's key is read from its config file", function()
    reset()
    files["/fs/ko/plugins/hardcoverapp.koplugin/hardcover_config.lua"] =
        "return {\n  token = '" .. TOKEN .. "'\n}\n"
    local tok, src = Key.get()
    eq(tok, TOKEN); eq(src, "hardcover")
end)

t.test("the folder may be named either way, and live under an extra plugin path", function()
    reset()
    extra = { "/fs/elsewhere/" }
    files["/fs/elsewhere/hardcover.koplugin/hardcover_config.lua"] = 'return { token = "' .. TOKEN .. '" }'
    eq((Key.get()), TOKEN)
end)

t.test("a second plugin's key: its config file's hardcover section, then its settings", function()
    reset()
    files["/fs/ko/plugins/shelfsync.koplugin/shelfsync_config.lua"] =
        'return {\n  storygraph = {\n    session_cookie = "COOKIE",\n    remember_user_token = "",\n  },\n'
        .. '  hardcover = {\n    token = "' .. TOKEN .. '",\n  },\n}\n'
    local tok, src = Key.get()
    eq(tok, TOKEN); eq(src, "shelfsync")
    reset()
    -- Typed into its menu: kept in its settings file. Its sign-in tokens
    -- there are NOT keys (they expire, and get no reviews).
    files["/fs/ko/settings/hardcoversync_settings.lua"] =
        'return {\n    ["api_token"] = "' .. TOKEN .. '",\n    ["oauth_access_token"] = "OPAQUE",\n}\n'
    tok, src = Key.get()
    eq(tok, TOKEN); eq(src, "shelfsync")
    reset()
    files["/fs/ko/settings/hardcoversync_settings.lua"] = 'return {\n    ["oauth_access_token"] = "OPAQUE",\n}\n'
    eq((Key.get()), nil, "a sign-in token was taken for a key")
end)

t.test("an empty or placeholder token is no key", function()
    reset()
    files["/fs/ko/plugins/hardcoverapp.koplugin/hardcover_config.lua"] = "return {\n  token = ''\n}\n"
    eq((Key.get()), nil)
end)

t.test("a pasted 'Bearer ' prefix and stray spaces are cleaned up", function()
    eq(Key.clean("  Bearer " .. TOKEN .. " \n"), TOKEN)
    eq(Key.clean("bearer " .. TOKEN), TOKEN)
    eq(Key.clean(""), nil); eq(Key.clean("   "), nil); eq(Key.clean(nil), nil)
    eq(Key.clean("has spaces inside"), nil, "a token never has a space in it")
end)

t.test("Bookshelf's own key wins, lives in its own file, and is not readable at a glance", function()
    reset()
    files["/fs/ko/plugins/hardcoverapp.koplugin/hardcover_config.lua"] = "return { token = 'OTHER.TOKEN.x' }"
    eq(Key.set("Bearer " .. TOKEN), true)
    local tok, src = Key.get()
    eq(tok, TOKEN); eq(src, "own")
    local stored = files["/fs/ko/settings/bookshelf/hardcover_key"]
    assert(stored and stored ~= "", "nothing written")
    assert(not stored:find(TOKEN, 1, true), "the key is stored as typed")
    assert(not stored:find("eyJ", 1, true), "the key's start is readable in the file")
    -- A fresh session reads it back.
    Key.invalidate()
    eq((Key.get()), TOKEN)
    eq(Key.hasOwn(), true)
end)

t.test("clearing the own key falls back to a plugin's", function()
    reset()
    files["/fs/ko/plugins/hardcoverapp.koplugin/hardcover_config.lua"] = "return { token = 'OTHER.TOKEN.x' }"
    Key.set(TOKEN)
    Key.clear()
    eq(removed[1], "/fs/ko/settings/bookshelf/hardcover_key")
    local tok, src = Key.get()
    eq(tok, "OTHER.TOKEN.x"); eq(src, "hardcover")
    eq(Key.hasOwn(), false)
end)

t.test("keeping a copy is the reader's choice, from the plugin that has one", function()
    reset()
    eq(Key.keepCopy(), false, "nothing to copy")
    files["/fs/ko/plugins/shelfsync.koplugin/shelfsync_config.lua"] = 'return { hardcover = { token = "' .. TOKEN .. '" } }'
    eq(Key.pluginSource(), "shelfsync")
    eq(Key.keepCopy(), true)
    files["/fs/ko/plugins/shelfsync.koplugin/shelfsync_config.lua"] = nil
    Key.invalidate()
    local tok, src = Key.get()
    eq(tok, TOKEN); eq(src, "own")
end)

t.test("a key can be read from a file dropped on the device, which is then removed", function()
    reset()
    -- Nobody types 500 characters on an e-reader keyboard.
    eq(Key.importPath(), "/fs/ko/settings/bookshelf/hardcover_api_key.txt")
    eq(Key.importFile(), false, "no file, nothing imported")
    files["/fs/ko/settings/bookshelf/hardcover_api_key.txt"] = "Bearer " .. TOKEN .. "\r\n"
    eq(Key.importFile(), true)
    local tok, src = Key.get()
    eq(tok, TOKEN); eq(src, "own")
    eq(files["/fs/ko/settings/bookshelf/hardcover_api_key.txt"], nil, "the plain file was left on the device")
    -- A file that holds no token is left alone, for the reader to fix.
    reset()
    files["/fs/ko/settings/bookshelf/hardcover_api_key.txt"] = "this is not a key"
    eq(Key.importFile(), false)
    assert(files["/fs/ko/settings/bookshelf/hardcover_api_key.txt"], "a file that was not used was deleted")
end)

t.test("a rejected own key is not offered again this session, and a damaged file is no key", function()
    reset()
    files["/fs/ko/settings/bookshelf/hardcover_key"] = "not a key file"
    eq((Key.get()), nil)
    reset()
    files["/fs/ko/settings/bookshelf/hardcover_key"] = "bs1:!!!!"
    eq((Key.get()), nil)
end)

t.test("the answer is remembered until something changes it", function()
    reset()
    files["/fs/ko/plugins/hardcoverapp.koplugin/hardcover_config.lua"] = "return { token = 'A.B.c' }"
    eq((Key.get()), "A.B.c")
    files["/fs/ko/plugins/hardcoverapp.koplugin/hardcover_config.lua"] = "return { token = 'D.E.f' }"
    eq((Key.get()), "A.B.c", "the files are read again on every call")
    Key.invalidate()
    eq((Key.get()), "D.E.f")
end)

t.done()
