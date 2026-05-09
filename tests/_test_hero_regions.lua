-- tests/_test_hero_regions.lua
-- Pure-Lua test runner. No KOReader dependencies.
-- Usage: cd into the plugin dir, then `lua tests/_test_hero_regions.lua`.

local stored
_G.G_reader_settings = {
    readSetting = function(_, key) if key == "bookshelf_hero_regions" then return stored end end,
    saveSetting = function(_, key, value) if key == "bookshelf_hero_regions" then stored = value end end,
    flush       = function() end,
    delSetting  = function() end,
}

local Regions = dofile("bookshelf_hero_regions.lua")

local pass, fail = 0, 0
local function test(name, fn)
    stored = nil
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end
local function eq(a, e, msg)
    if a ~= e then error((msg or "") .. " expected=" .. tostring(e) .. " got=" .. tostring(a), 2) end
end

test("smoke: module loads", function()
    assert(type(Regions) == "table")
    assert(type(Regions.read) == "function")
    assert(type(Regions.resolve) == "function")
    assert(type(Regions.write) == "function")
    assert(type(Regions.snapshot) == "function")
    assert(type(Regions.restore) == "function")
end)

test("ORDER lists all five regions in render order", function()
    eq(#Regions.ORDER, 5)
    eq(Regions.ORDER[1], "status")
    eq(Regions.ORDER[2], "title")
    eq(Regions.ORDER[3], "author")
    eq(Regions.ORDER[4], "description")
    eq(Regions.ORDER[5], "progress")
end)

test("DEFAULTS: every region has a template and font_size", function()
    for _, key in ipairs(Regions.ORDER) do
        local d = Regions.DEFAULTS[key]
        assert(type(d.template) == "string", key .. " missing template")
        assert(type(d.font_size) == "number", key .. " missing font_size")
    end
end)

test("read: returns defaults when nothing stored", function()
    local r = Regions.read()
    eq(r.title.template, Regions.DEFAULTS.title.template)
    eq(r.title.font_size, Regions.DEFAULTS.title.font_size)
end)

test("resolve: sparse field falls through to default", function()
    stored = { title = { template = "%title", bold = false } }   -- no font_size
    local r = Regions.read()
    eq(r.title.template, "%title")
    eq(r.title.font_size, Regions.DEFAULTS.title.font_size)
    eq(r.title.bold, false)
end)

test("resolve: stored field overrides default", function()
    stored = { title = { font_size = 99 } }
    local r = Regions.read()
    eq(r.title.font_size, 99)
    eq(r.title.template, Regions.DEFAULTS.title.template)
end)

test("read: drops malformed regions back to defaults", function()
    stored = { title = "not a table", author = { template = 42 } }
    local r = Regions.read()
    eq(r.title.template, Regions.DEFAULTS.title.template)
    eq(r.author.template, Regions.DEFAULTS.author.template)
end)

test("write: persists single region", function()
    Regions.write("title", { template = "X", font_size = 30 })
    eq(stored.title.template, "X")
    eq(stored.title.font_size, 30)
end)

test("write: nil clears region back to defaults", function()
    stored = { title = { template = "X" } }
    Regions.write("title", nil)
    eq(stored.title, nil)
    eq(Regions.read().title.template, Regions.DEFAULTS.title.template)
end)

test("snapshot/restore: round-trips a region", function()
    Regions.write("title", { template = "AAA", bold = true })
    local snap = Regions.snapshot("title")
    Regions.write("title", { template = "BBB" })
    eq(stored.title.template, "BBB")
    Regions.restore("title", snap)
    eq(stored.title.template, "AAA")
    eq(stored.title.bold, true)
end)

test("snapshot of nil region restores to nil", function()
    local snap = Regions.snapshot("title")
    eq(snap, nil)
    Regions.write("title", { template = "X" })
    Regions.restore("title", snap)
    eq(stored and stored.title, nil)
end)

print(string.format("\n%d pass, %d fail", pass, fail))
os.exit(fail == 0 and 0 or 1)
