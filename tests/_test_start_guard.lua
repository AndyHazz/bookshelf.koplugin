-- tests/_test_start_guard.lua
-- lib/bookshelf_start_guard (issue 621): a start that never settled (a hard
-- freeze after the shelf painted, cured by emptying cache/bookshelf/ by hand)
-- has the caches read at start-up cleared on the next one.
package.path = "./?.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

local function ls(dir)
    local out = {}
    local p = io.popen('ls -A "' .. dir .. '" 2>/dev/null')
    for l in p:lines() do out[#out + 1] = l end
    p:close()
    table.sort(out)
    return out
end
local function exists(path)
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return os.execute('test -d "' .. path .. '"') == true or os.execute('test -d "' .. path .. '"') == 0
end
local function write(path, s) local f = assert(io.open(path, "w")); f:write(s or "x"); f:close() end

-- A tiny lfs for the module when the real one is not installed.
local lfs_ok, lfs = pcall(require, "lfs")
package.loaded["libs/libkoreader-lfs"] = lfs_ok and lfs or {
    attributes = function(path)
        local p = io.popen('stat -c "%F" "' .. path .. '" 2>/dev/null')
        local l = p:read("*l"); p:close()
        if not l then return nil end
        return { mode = l:find("directory") and "directory" or "file" }
    end,
    mkdir = function(path) return os.execute('mkdir "' .. path .. '" 2>/dev/null') end,
    dir = function(path)
        local list = ls(path)
        local i = 0
        return function() i = i + 1; return list[i] end, nil
    end,
}
package.loaded["logger"] = { warn = function() end, dbg = function() end }

local function fresh()
    local tmp = os.tmpname(); os.remove(tmp)
    local dir = tmp .. "_cache"
    os.execute('mkdir -p "' .. dir .. '/bytecode/LuaJIT_2.1-arm" "' .. dir .. '/scaled_covers" "' .. dir .. '/online"')
    write(dir .. "/bytecode/LuaJIT_2.1-arm/bookshelf_widget-1-2.luac")
    write(dir .. "/scaled_covers/0a1b2c3d_40")
    write(dir .. "/scaled_covers/.total")
    for _i, f in ipairs({ "bookshelf.walk", "bookshelf.lightmeta", "bookshelf.finishedcount",
                          "opds.sqlite3", "hero_inflight", "online/cover.jpg" }) do
        write(dir .. "/" .. f)
    end
    package.loaded["lib/bookshelf_start_guard"] = nil
    return dir, require("lib/bookshelf_start_guard")
end

t.test("a first start keeps the caches and leaves a sentinel", function()
    local dir, G = fresh()
    eq(G.arm(dir), false)
    assert(exists(dir .. "/start_inflight"), "sentinel made")
    assert(exists(dir .. "/bytecode/LuaJIT_2.1-arm/bookshelf_widget-1-2.luac"), "bytecode kept")
    assert(exists(dir .. "/scaled_covers/0a1b2c3d_40"), "covers kept")
end)

t.test("a start that settles removes the sentinel", function()
    local dir, G = fresh()
    G.arm(dir)
    G.settle()
    assert(not exists(dir .. "/start_inflight"))
    G.settle()  -- again: harmless
end)

t.test("after a start that never settled, the start-up caches go", function()
    local dir, G = fresh()
    write(dir .. "/start_inflight", "")
    eq(G.arm(dir), true)
    eq(ls(dir), { "hero_inflight", "online", "opds.sqlite3", "start_inflight" })
    eq(ls(dir .. "/online"), { "cover.jpg" })
end)

t.test("it is armed once a process", function()
    local dir, G = fresh()
    G.arm(dir)
    eq(G.arm(dir), false)
    assert(exists(dir .. "/bytecode"), "second arm cleared nothing")
end)

t.test("no cache folder (off a device): nothing happens", function()
    package.loaded["datastorage"] = nil
    package.loaded["lib/bookshelf_start_guard"] = nil
    local G = require("lib/bookshelf_start_guard")
    eq(G.arm(), false)
    G.settle()
end)

-- ── The compiled copies switch ───────────────────────────────────────────────
-- A start of KOReader: the module afresh (it arms once a process).
local function start(dir, sdir, stuck)
    if stuck then write(dir .. "/start_inflight", "") end
    package.loaded["lib/bookshelf_start_guard"] = nil
    local G = require("lib/bookshelf_start_guard")
    G.arm(dir, sdir)
    G.settle()
    return G
end
local function read(path)
    local f = io.open(path); if not f then return nil end
    local s = f:read("*a"); f:close(); return s
end
local function freshSettings()
    local tmp = os.tmpname(); os.remove(tmp)
    os.execute('mkdir -p "' .. tmp .. '_settings"')
    return tmp .. "_settings"
end

t.test("one start that did not settle leaves the compiled copies on", function()
    local dir, sdir = fresh(), freshSettings()
    local G = start(dir, sdir, true)
    eq(G.bytecodeOn(sdir), true)
    eq(read(sdir .. "/start_trip"), "0")
end)

t.test("a second within a few starts switches them off, and says so once", function()
    local dir, sdir = fresh(), freshSettings()
    start(dir, sdir, true)
    for _i = 1, 3 do start(dir, sdir, false) end
    eq(read(sdir .. "/start_trip"), "3")
    local G = start(dir, sdir, true)
    eq(G.bytecodeOn(sdir), false)
    eq(read(sdir .. "/bytecode_off"), "auto")
    eq(G.takeNotice(sdir), true)
    eq(G.takeNotice(sdir), false)
    eq(G.bytecodeOn(sdir), false, "still off once told")
end)

t.test("a second long after the first is bad luck again, not a pattern", function()
    local dir, sdir = fresh(), freshSettings()
    start(dir, sdir, true)
    for _i = 1, 9 do start(dir, sdir, false) end
    eq(read(sdir .. "/start_trip"), "9")
    start(dir, sdir, false)
    eq(read(sdir .. "/start_trip"), nil, "forgotten after ten starts")
    local G = start(dir, sdir, true)
    eq(G.bytecodeOn(sdir), true)
end)

t.test("the switch: off removes the copies, on forgets the trips", function()
    local dir, G = fresh()
    local sdir = freshSettings()
    G.setBytecode(false, sdir, dir)
    eq(G.bytecodeOn(sdir), false)
    eq(read(sdir .. "/bytecode_off"), "user")
    assert(not exists(dir .. "/bytecode/LuaJIT_2.1-arm/bookshelf_widget-1-2.luac"), "copies gone")
    eq(G.takeNotice(sdir), false, "no notice for a choice the reader made")
    write(sdir .. "/start_trip", "2")
    G.setBytecode(true, sdir, dir)
    eq(G.bytecodeOn(sdir), true)
    eq(read(sdir .. "/start_trip"), nil)
end)

t.test("emptying the cache folder does not switch them back on", function()
    local dir, sdir = fresh(), freshSettings()
    start(dir, sdir, true); start(dir, sdir, true)
    os.execute('rm -rf "' .. dir .. '"')
    eq(start(dir, sdir, false).bytecodeOn(sdir), false)
end)

t.test("main.lua arms it before the bytecode searcher, and settles it", function()
    local src = assert(io.open("main.lua")):read("*a")
    local arm = src:find('require("lib/bookshelf_start_guard").arm()', 1, true)
    local bc = src:find('require("lib/bookshelf_bytecode").install()', 1, true)
    assert(arm and bc and arm < bc, "arm() runs before install()")
    local on = src:find('if require("lib/bookshelf_start_guard").bytecodeOn() then', 1, true)
    assert(on and on < bc and src:sub(on, bc - 1):match("then%s+$"), "install() only while the copies are on")
    assert(src:find("takeNotice()", 1, true), "the reader is told when they go off")
    assert(src:find("afterFirstPaint%(%d+, function%(%)%s+pcall%(function%(%) require%(\"lib/bookshelf_start_guard\"%)%.settle%(%)"),
        "settled after the first paint")
    local exit_fn = src:match("function Bookshelf:onExit%(%)(.-)\nend")
    assert(exit_fn and exit_fn:find("bookshelf_start_guard", 1, true), "settled on a clean exit")
end)

t.test("bytecode copies are synced before they are renamed into place", function()
    local src = assert(io.open("lib/bookshelf_bytecode.lua")):read("*a")
    local wf = src:match("M%._writeFile = function(.-)\nend")
    assert(wf and wf:find("C.fsync(C.fileno(fp))", 1, true), "fsync in the write")
    local st = src:match("local function store(.-)\nend")
    assert(st and st:find("M._writeFile(tmp, code)", 1, true), "store writes through it")
end)

t.done()
