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

local Regions = dofile("lib/bookshelf_hero_regions.lua")

local pass, fail = 0, 0
local function test(name, fn)
    stored = nil
    -- read() memoises behind a private cache that production invalidates in
    -- write(); reset it per test so each case sees its own `stored`.
    if Regions.invalidateCache then Regions.invalidateCache() end
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

test("ORDER lists all eight regions in render order", function()
    eq(#Regions.ORDER, 8)
    eq(Regions.ORDER[1], "status")
    eq(Regions.ORDER[2], "rating")
    eq(Regions.ORDER[3], "title")
    eq(Regions.ORDER[4], "author")
    eq(Regions.ORDER[5], "metadata")
    eq(Regions.ORDER[6], "description")
    eq(Regions.ORDER[7], "tags")
    eq(Regions.ORDER[8], "progress")
end)

test("DEFAULTS: every region has a template; text regions have a font_size", function()
    for _, key in ipairs(Regions.ORDER) do
        local d = Regions.DEFAULTS[key]
        assert(type(d.template) == "string", key .. " missing template")
        -- Widget-only regions (e.g. tags pills) render as widgets, not text,
        -- so they carry no font_size; any font_size present must be numeric.
        assert(d.font_size == nil or type(d.font_size) == "number",
            key .. " has non-numeric font_size")
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

-- #99: hero Tags line customisation. Per-category visibility + font/alignment.
test("tags region: defaults show every category (current behaviour)", function()
    local t = Regions.read().tags
    eq(t.show_author, true,      "show_author")
    eq(t.show_series, true,      "show_series")
    eq(t.show_collections, true, "show_collections")
    eq(t.show_genres, true,      "show_genres")
    eq(t.show_folder, true,      "show_folder")
end)

test("tags region: default font_size and alignment", function()
    local t = Regions.read().tags
    eq(t.font_size, 12, "font_size")
    eq(t.alignment, "left", "alignment")
end)

test("tags region: a stored false category overrides the default", function()
    Regions.write("tags", { disabled = false, show_author = false,
                            show_series = false, alignment = "center" })
    local t = Regions.read().tags
    eq(t.show_author, false, "show_author off")
    eq(t.show_series, false, "show_series off")
    -- Unset categories still fall through to the true default.
    eq(t.show_genres, true,  "show_genres default")
    eq(t.alignment, "center", "alignment override")
end)

print(string.format("\n%d pass, %d fail", pass, fail))
os.exit(fail == 0 and 0 or 1)

print(string.format("\n%d pass, %d fail", pass, fail))
os.exit(fail == 0 and 0 or 1)
