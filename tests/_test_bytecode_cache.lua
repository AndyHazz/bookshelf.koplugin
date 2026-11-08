-- tests/_test_bytecode_cache.lua
-- Our modules load from compiled bytecode kept on the device.
--
-- Every start parsed ~3 MB of our Lua source: on a PW3 the seven largest
-- files took 268 ms to parse against 17 ms as bytecode. A searcher ahead
-- of the file searchers loads lib/bookshelf_* from a bytecode copy keyed
-- on the source's mtime and size, compiling and storing it on a miss.
package.path = "./?.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq
local lfs_ok, lfs = pcall(require, "lfs")
if not lfs_ok then
    package.loaded["libs/libkoreader-lfs"] = nil
end

local tmp = os.tmpname()
os.remove(tmp)
local ROOT, CACHE = tmp .. "_root/", tmp .. "_cache"
os.execute("mkdir -p " .. ROOT .. "lib")

local function write(path, s) local f = assert(io.open(path, "w")); f:write(s); f:close() end
local function files(dir)
    local out = {}
    local p = io.popen('ls "' .. dir .. '" 2>/dev/null')
    for l in p:lines() do out[#out + 1] = l end
    p:close()
    return out
end

-- A tiny lfs for the module when the real one is not installed.
package.loaded["libs/libkoreader-lfs"] = lfs_ok and lfs or {
    attributes = function(path)
        local p = io.popen('stat -c "%Y %s %F" "' .. path .. '" 2>/dev/null')
        local l = p:read("*l"); p:close()
        if not l then return nil end
        local m, s, kind = l:match("^(%d+) (%d+) (.+)$")
        return { modification = tonumber(m), size = tonumber(s),
                 mode = kind:find("directory") and "directory" or "file" }
    end,
    mkdir = function(path) return os.execute('mkdir "' .. path .. '" 2>/dev/null') end,
    dir = function(path)
        local list = files(path)
        local i = 0
        return function() i = i + 1; return list[i] end, nil
    end,
}

local BC = require("lib/bookshelf_bytecode")
local compiles = 0
BC._compile = function(path) compiles = compiles + 1; return loadfile(path) end
BC.install(ROOT, CACHE)

write(ROOT .. "lib/bookshelf_bctest.lua", "return { v = 1, where = debug.getinfo(1, 'S').source }")

t.test("a module is compiled once and loaded from bytecode after", function()
    local m = require("lib/bookshelf_bctest")
    eq(m.v, 1); eq(compiles, 1)
    package.loaded["lib/bookshelf_bctest"] = nil
    local again = require("lib/bookshelf_bctest")
    eq(again.v, 1)
    eq(compiles, 1, "compiled again with a copy in hand")
    assert(again.where:find("lib/bookshelf_bctest.lua", 1, true), "the source name is lost: " .. tostring(again.where))
end)

t.test("a changed source is compiled again, and the old copy goes", function()
    os.execute("sleep 1")
    write(ROOT .. "lib/bookshelf_bctest.lua", "return { v = 2, pad = 'xxxxxxxx' }")
    package.loaded["lib/bookshelf_bctest"] = nil
    eq(require("lib/bookshelf_bctest").v, 2, "an edited module loaded its old code")
    local n = 0
    for _i, f in ipairs(files(CACHE .. "/" .. BC.vmTag())) do
        if f:find("^lib_bookshelf_bctest%-") then n = n + 1 end
    end
    eq(n, 1, "copies of earlier versions pile up")
end)

t.test("a damaged copy falls back to the source", function()
    package.loaded["lib/bookshelf_bctest"] = nil
    for _i, f in ipairs(files(CACHE .. "/" .. BC.vmTag())) do
        write(CACHE .. "/" .. BC.vmTag() .. "/" .. f, "\27Lgarbage")
    end
    eq(require("lib/bookshelf_bctest").v, 2)
end)

t.test("other modules are left to the usual search", function()
    eq(BC._search("lib/somebody_else"), nil)
    eq(BC._search("ui/widget/foo"), nil)
    eq(BC._search("lib/bookshelf_not_here"), nil, "a missing module was claimed")
end)

t.test("a syntax error still says which file", function()
    write(ROOT .. "lib/bookshelf_bcbad.lua", "return {")
    local ok, err = pcall(require, "lib/bookshelf_bcbad")
    assert(not ok and tostring(err):find("bookshelf_bcbad", 1, true), tostring(err))
end)

t.test("main.lua installs it before any other module of ours", function()
    local src = io.open("main.lua"):read("*a")
    local i = src:find('require("lib/bookshelf_bytecode").install()', 1, true)
    assert(i, "main.lua does not install it")
    eq(src:find('require("lib/bookshelf_', 1, true), i, "a module of ours loads before the bytecode cache is in place")
end)

-- ── Parsed data kept the same way (the translations) ─────────────────────────
-- Parsing a .po took ~140 ms of a PW3 start for a non-English reader.
t.test("a table built from a file is built once, then read back", function()
    local po = ROOT .. "x.po"
    write(po, "anything")
    local builds = 0
    local function build() builds = builds + 1; return { ["Hello"] = "Hiya", ['say "x"\n'] = 'line\nnext "q"' } end
    local a = BC.data(po, "po_x", build)
    local b = BC.data(po, "po_x", build)
    eq(builds, 1, "built again with a copy in hand")
    eq(b["Hello"], "Hiya")
    eq(b['say "x"\n'], 'line\nnext "q"', "a string with quotes or newlines came back changed")
    eq(a["Hello"], b["Hello"])
end)

t.test("a changed file is built again", function()
    local po = ROOT .. "x.po"
    os.execute("sleep 1")
    write(po, "anything else")
    local builds = 0
    BC.data(po, "po_x", function() builds = builds + 1; return { k = "v2" } end)
    eq(builds, 1)
    eq(BC.data(po, "po_x", function() builds = builds + 1; return {} end).k, "v2")
end)

t.test("what cannot be kept is still handed back", function()
    local po = ROOT .. "y.po"
    write(po, "z")
    local t1 = BC.data(po, "po_y", function() return { nested = { 1 } } end)
    eq(type(t1.nested), "table")
    eq(BC.data(ROOT .. "missing.po", "po_m", function() return nil end), nil)
end)

t.test("the translations go through it", function()
    local src = io.open("lib/bookshelf_i18n.lua"):read("*a")
    assert(src:find('.data(path, "po_" .. name, parsePO)', 1, true), "the .po is parsed on every start")
end)

os.execute('rm -rf "' .. ROOT .. '" "' .. CACHE .. '"')
t.done()
