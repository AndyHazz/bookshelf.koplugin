-- tests/_test_render_guard.lua
-- The page-count scan's guard against one book taking KOReader down
-- (issue 518): the child's memory cap, and the book left in flight by a crash
-- being skipped next time while the file is unchanged.
local dir = os.tmpname(); os.remove(dir); os.execute("mkdir -p " .. dir)
package.loaded["lib/bookshelf_paths"] = { settingsDir = function() return dir end }
local sizes = {}
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(fp, what) assert(what == "size"); return sizes[fp] end,
}
local G = dofile("lib/bookshelf_render_guard.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1; print("PASS  " .. name)
    else fail = fail + 1; print("FAIL  " .. name .. "\n  " .. tostring(err)) end
end
local function eq(a, b, msg)
    if a ~= b then error((msg or "") .. "\n  got:  " .. tostring(a) .. "\n  want: " .. tostring(b), 2) end
end
local function store()
    local t = {}
    return { read = function(k) return t[k] end, save = function(k, v) t[k] = v end,
             flush = function() end, t = t }
end

test("MemAvailable is read in bytes", function()
    eq(G.memAvailableBytes("MemTotal: 500000 kB\nMemAvailable:   123456 kB\n"), 123456 * 1024)
    eq(G.memAvailableBytes("MemTotal: 1 kB\n"), nil)
end)

test("the cap is what is mapped plus a share of what is free", function()
    eq(G.addressLimit(100, 1000), 100 + math.floor(1000 * G.AVAILABLE_SHARE))
    eq(G.addressLimit(nil, 1000), nil, "an unknown mapping must leave the limit alone")
    eq(G.addressLimit(100, nil), nil)
end)

test("the child may take half of what is free (issue 518)", function()
    -- Three quarters let a heavy book freeze a 512 MB Kobo before the child's
    -- allocation was refused; half lets it fail cleanly.
    eq(G.addressLimit(100, 1000), 600)
end)

test("a book the old skip list held gets one more try", function()
    local s = store()
    s.save("page_count_skip", { ["/b/a.epub"] = -1 })
    assert(not G.skipped(s, "/b/a.epub"),
        "books skipped under the old, larger share should be retried once")
end)

test("no crash: nothing is taken and nothing is skipped", function()
    local s = store()
    eq(G.takeCrashed(s), nil)
    assert(not G.skipped(s, "/b/a.epub"))
end)

test("a book left in flight is skipped next time", function()
    local s = store()
    sizes["/b/omnibus.epub"] = 9000
    G.mark("/b/omnibus.epub")
    eq(G.takeCrashed(s), "/b/omnibus.epub")
    assert(G.skipped(s, "/b/omnibus.epub"), "the crashing book was rendered again")
    assert(not G.skipped(s, "/b/other.epub"))
    eq(G.takeCrashed(s), nil, "the marker outlived being taken")
end)

test("a cleared marker (Stop, clean exit, finished scan) skips nothing", function()
    local s = store()
    G.mark("/b/fine.epub"); G.clear()
    eq(G.takeCrashed(s), nil)
end)

test("a file that changed size gets another try", function()
    local s = store()
    sizes["/b/fixed.epub"] = 100
    G.mark("/b/fixed.epub"); G.takeCrashed(s)
    sizes["/b/fixed.epub"] = 120
    assert(not G.skipped(s, "/b/fixed.epub"), "a changed file stayed skipped")
end)

os.execute("rm -rf " .. dir)
print(string.format("PASS %d  FAIL %d", pass, fail))
os.exit(fail == 0 and 0 or 1)
