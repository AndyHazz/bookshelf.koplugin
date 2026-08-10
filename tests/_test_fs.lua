-- tests/_test_fs.lua
-- lib/bookshelf_fs.ensureDir: the union of the three per-module copies it
-- replaced - recursive (mkdir -p) AND pcall-hardened (lfs calls may raise on
-- Android's storage sandbox rather than return nil).
package.path = "./?.lua;./?/init.lua;" .. package.path

local t = dofile("tests/_helpers.lua").runner()

-- In-memory filesystem. mkdir honours POSIX semantics: fails when the
-- parent doesn't exist (that's exactly what the recursive walk is for).
local dirs, mkdir_calls, raise_mode
local function reset()
    dirs, mkdir_calls, raise_mode = { ["/root"] = true }, {}, false
end
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(p, what)
        if raise_mode then error("EACCES sandbox") end
        if dirs[p] then return "directory" end
        return nil
    end,
    mkdir = function(p)
        if raise_mode then error("EACCES sandbox") end
        mkdir_calls[#mkdir_calls + 1] = p
        local parent = p:match("^(.*)/[^/]+$")
        if parent and parent ~= "" and not dirs[parent] then
            return nil, "no parent"
        end
        dirs[p] = true
        return true
    end,
}

local FS = dofile("lib/bookshelf_fs.lua")

t.test("existing directory returns true without mkdir", function()
    reset()
    assert(FS.ensureDir("/root") == true)
    assert(#mkdir_calls == 0, "no mkdir for an existing dir")
end)

t.test("single missing level is created", function()
    reset()
    assert(FS.ensureDir("/root/covers") == true)
    assert(dirs["/root/covers"], "dir must exist afterwards")
end)

t.test("two missing levels are created parent-first (mkdir -p)", function()
    reset()
    assert(FS.ensureDir("/root/covers/online") == true)
    assert(dirs["/root/covers"] and dirs["/root/covers/online"])
    assert(mkdir_calls[1] == "/root/covers", "parent must be created first")
    assert(mkdir_calls[2] == "/root/covers/online")
end)

t.test("deeply nested path from scratch", function()
    reset()
    assert(FS.ensureDir("/root/a/b/c/d") == true)
    assert(dirs["/root/a/b/c/d"])
end)

t.test("raising lfs (Android sandbox) returns false, never throws", function()
    reset()
    raise_mode = true
    local ok, ret = pcall(FS.ensureDir, "/root/covers")
    assert(ok, "must not propagate the lfs error")
    assert(ret == false)
end)

t.test("non-string and empty input return false", function()
    reset()
    assert(FS.ensureDir(nil) == false)
    assert(FS.ensureDir("") == false)
    assert(FS.ensureDir(42) == false)
end)

t.test("unreachable target (parent chain never materialises) returns false", function()
    reset()
    -- Simulate a read-only mount: mkdir reports success=false everywhere.
    package.loaded["libs/libkoreader-lfs"].mkdir = function() return nil, "EROFS" end
    assert(FS.ensureDir("/root/covers") == false)
end)

t.done()
