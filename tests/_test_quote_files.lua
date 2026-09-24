-- tests/_test_quote_files.lua
-- Issue 258: quotes files in SimpleUI's format as a quote of the day source.
--   return { { q = "Quote.", a = "Author", b = "Book (optional)" }, ... }
-- Read from bookshelf's own quotes folder and SimpleUI's; highlights stay the
-- default; a file runs with an empty environment, so it can only be data.
package.path = "./?.lua;./?/init.lua;" .. package.path

package.loaded["lib/bookshelf_text_safe"] = { safe = function(s) return s end }
package.loaded["logger"] = { dbg = function() end, info = function() end,
                             warn = function() end, err = function() end }
local kv = {}
package.loaded["lib/bookshelf_settings_store"] = {
    read  = function(k, default) if kv[k] == nil then return default end return kv[k] end,
    save  = function(k, v) kv[k] = v end,
    delete = function(k) kv[k] = nil end,
    flush = function() end,
}
-- A shell-backed lfs, as in _test_wallpaper: attributes (whole table or one
-- key) and a two-value dir() whose iterator needs its state, like the real one.
local function sh(cmd) local p = io.popen(cmd .. " 2>/dev/null"); local o = p:read("*a"); p:close(); return o end
local lfs = {}
function lfs.attributes(path, key)
    local q = "'" .. path .. "'"
    local mode = sh("test -d " .. q .. " && echo d || (test -f " .. q .. " && echo f)")
    mode = mode:match("d") and "directory" or (mode:match("f") and "file") or nil
    if not mode then return nil end
    local a = { mode = mode, size = tonumber(sh("stat -c %s " .. q)) or 0,
                modification = tonumber(sh("stat -c %Y " .. q)) or 0 }
    -- The size alone does not change on a same-length rewrite, so add the
    -- nanoseconds a test's quick successive writes would otherwise hide.
    a.modification = a.modification + (tonumber(sh("stat -c %y " .. q):match("%.(%d+)")) or 0) / 1e9
    if key then return a[key] end
    return a
end
function lfs.dir(path)
    local list = {}
    for name in sh("ls -a '" .. path .. "'"):gmatch("[^\n]+") do list[#list + 1] = name end
    local state = { i = 0 }
    return function(st) st.i = st.i + 1; return list[st.i] end, state
end
package.loaded["libs/libkoreader-lfs"] = lfs

local dir = os.tmpname(); os.remove(dir)
os.execute("mkdir -p '" .. dir .. "/bookshelf/quotes' '" .. dir .. "/simpleui/sui_quotes'")
package.loaded["datastorage"] = { getSettingsDir = function() return dir end }
local function write(path, text) local f = assert(io.open(path, "w")); f:write(text); f:close() end

package.loaded["readhistory"] = { hist = { { file = "/b.epub" } } }
package.loaded["docsettings"] = {
    hasSidecarFile = function(_self, fp) return fp == "/b.epub" end,
    open = function() return { readSetting = function(_s, k)
        if k == "doc_props" then return { title = "Book" } end
        if k == "annotations" then return { { drawer = "lighten", text = "A highlight.", page = 1 } } end
    end } end,
}
package.loaded["lib/bookshelf_start_menu_modules"] = { menu_generation = 1 }

write(dir .. "/bookshelf/quotes/mine.lua", [[
return {
    { q = "Mine one.", a = "Ann", b = "First Book" },
    { q = "Mine two.", a = "Bob" },
    { q = "   " },
    { a = "no quote" },
    "not a table",
}]])
write(dir .. "/simpleui/sui_quotes/quote.lua", [[return { { q = "From SimpleUI." } }]])
write(dir .. "/bookshelf/quotes/evil.lua", [[os.execute("touch ]] .. dir .. [[/pwned"); return { { q = "x" } }]])
write(dir .. "/bookshelf/quotes/broken.lua", [[return { { q = "unterminated" ]])

local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()
local eq = helpers.eq

local function pool(Q)
    local seen, n = {}, 0
    for _i = 1, 40 do
        local q = Q.ofTheDay()
        if q and not seen[q.text] then seen[q.text] = q; n = n + 1 end
        Q.reroll()
    end
    return seen, n
end

t.test("highlights stay the default", function()
    kv = {}
    local Q = dofile("lib/bookshelf_quotes.lua")
    eq(Q.readSource(), "highlights")
    local seen, n = pool(Q)
    eq(n, 1); assert(seen["A highlight."])
end)

t.test("files: every valid quote from both folders, nothing else", function()
    kv = {}
    local Q = dofile("lib/bookshelf_quotes.lua")
    Q.setSource("files")
    local seen, n = pool(Q)
    eq(n, 3, "Mine one, Mine two, From SimpleUI")
    assert(seen["Mine one."] and seen["Mine two."] and seen["From SimpleUI."])
    eq(seen["Mine one."].author, "Ann"); eq(seen["Mine one."].title, "First Book")
    eq(seen["Mine two."].title, nil)
    assert(not seen["A highlight."])
end)

t.test("a quotes file cannot run anything", function()
    local f = io.open(dir .. "/pwned", "r")
    assert(not f, "evil.lua reached os.execute")
end)

t.test("both: highlights and files together", function()
    kv = {}
    local Q = dofile("lib/bookshelf_quotes.lua")
    Q.setSource("both")
    local _seen, n = pool(Q)
    eq(n, 4)
end)

t.test("an edited file is read again", function()
    kv = {}
    local Q = dofile("lib/bookshelf_quotes.lua")
    eq(#Q.fileQuotes(), 3)
    write(dir .. "/simpleui/sui_quotes/quote.lua", [[return { { q = "One." }, { q = "Two, and longer." } }]])
    eq(#Q.fileQuotes(), 4)
end)

t.test("changing the source is not undone by a persisted daily pick", function()
    kv = {}
    local Q = dofile("lib/bookshelf_quotes.lua")
    local first = Q.ofTheDay()
    eq(first.text, "A highlight.")
    Q.setSource("files")
    local Q2 = dofile("lib/bookshelf_quotes.lua")
    assert(Q2.ofTheDay().text ~= "A highlight.")
end)

os.execute("rm -rf '" .. dir .. "'")
t.done()
