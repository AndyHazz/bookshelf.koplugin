-- tests/_test_list_presets.lua
-- Named list-view layouts: capture, round-trip, apply, rename, delete.
--
-- Usage (from plugin root): lua tests/_test_list_presets.lua
--
-- The properties worth pinning are the ones that make a preset system feel
-- haunted when they break: a preset that half-applies and leaves a field of the
-- previous layout behind, a rename that loses the preset, and a bad file in the
-- directory taking the whole menu down.
--
-- LuaSettings is stubbed with an in-memory store keyed by path, which is
-- exactly what it is from this module's point of view -- a table that persists
-- under a filename. Its real serialisation is KOReader's business and has its
-- own tests upstream.

package.path = "./?.lua;./?/init.lua;" .. package.path

package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
package.loaded["logger"] = { warn = function() end, dbg = function() end,
                             info = function() end, err = function() end }
package.loaded["datastorage"] = {
    getFullDataDir = function() return "/data" end,
    getDataDir     = function() return "/data" end,
}

-- The "filesystem": path -> table of settings.
local FILES = {}
local MKDIRS = {}
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(path, what)
        if what == "mode" then
            return MKDIRS[path] and "directory" or nil
        end
    end,
    mkdir = function(path) MKDIRS[path] = true; return true end,
    dir = function(dir)
        local names = {}
        for path in pairs(FILES) do
            local f = path:match("^" .. dir:gsub("%-", "%%-") .. "/(.+)$")
            if f then names[#names + 1] = f end
        end
        table.sort(names)
        local i = 0
        return function() i = i + 1; return names[i] end
    end,
}
local flushes = 0
package.loaded["luasettings"] = {
    open = function(_self, path)
        local data = FILES[path] or {}
        local s = {}
        function s:readSetting(k) return data[k] end
        function s:saveSetting(k, v) data[k] = v end
        function s:flush() FILES[path] = data; flushes = flushes + 1 end
        return s
    end,
}

local STORE = {}
package.loaded["lib/bookshelf_settings_store"] = {
    read   = function(k, d) local v = STORE[k]; if v == nil then return d end return v end,
    save   = function(k, v) STORE[k] = v end,
    delete = function(k) STORE[k] = nil end,
    isTrue = function(k) return STORE[k] == true end,
    flush  = function() end,
}
package.loaded["lib/bookshelf_list_geom"] = {
    FONT_SIZE_DP = 16,
    secondaryFontSize = function() return 14 end,
}

-- os.remove, redirected at the fake filesystem.
local real_remove = os.remove
os.remove = function(path)
    if FILES[path] then FILES[path] = nil; return true end
    return real_remove and nil or nil
end

local helpers = dofile("tests/_helpers.lua")
local t       = helpers.runner()
local eq      = helpers.eq

local Presets = require("lib/bookshelf_list_presets")
local Lines   = require("lib/bookshelf_list_lines")

local function reset()
    for k in pairs(FILES) do FILES[k] = nil end
    for k in pairs(STORE) do STORE[k] = nil end
    flushes = 0
end

-- ── Filenames ──────────────────────────────────────────────────────────────

t.test("a filename cannot escape the directory or come out empty", function()
    eq(Presets.filenameFor("Two column, rich"), "two_column_rich.lua")
    eq(Presets.filenameFor("../../etc/passwd"), "etc_passwd.lua")
    eq(Presets.filenameFor("  Compact  "), "compact.lua")
    -- Punctuation only would otherwise produce ".lua", which is a hidden file
    -- with no name.
    eq(Presets.filenameFor("!!!"), "preset.lua")
    eq(Presets.filenameFor(""), "preset.lua")
    eq(Presets.filenameFor(nil), "preset.lua")
end)

-- ── Capture ────────────────────────────────────────────────────────────────

t.test("what is captured is RESOLVED, never 'unset'", function()
    reset()
    -- Nothing saved at all: the capture still comes back with concrete values
    -- for all four keys, which is what lets apply() write all four and never
    -- leave a field of the previous layout behind.
    local cur = Presets.current()
    eq(type(cur.lines), "table")
    assert(#cur.lines > 0, "an untouched library captured no lines")
    eq(cur.show_cover, Lines.DEFAULT_SHOW_COVER)
    eq(cur.columns, 1)
    eq(cur.font_scale, 100)
end)

t.test("the capture reflects what is actually set", function()
    reset()
    STORE[Lines.KEYS.lines]      = { { template = "%title" } }
    STORE[Lines.KEYS.show_cover] = false
    STORE["list_columns"]        = 3
    STORE["list_font_scale"]     = 130
    local cur = Presets.current()
    eq(#cur.lines, 1)
    eq(cur.lines[1].template, "%title")
    eq(cur.show_cover, false)
    eq(cur.columns, 3)
    eq(cur.font_scale, 130)
end)

-- ── Round trip ─────────────────────────────────────────────────────────────

t.test("a preset saves and reads back with its name intact", function()
    reset()
    STORE[Lines.KEYS.lines] = { { template = "%title", bold = true } }
    STORE["list_columns"]   = 2
    local file = Presets.save("Two column, rich")
    eq(file, "two_column_rich.lua")
    local entry = Presets.read(file)
    assert(entry, "the preset did not read back")
    -- The punctuated NAME survives even though the filename cannot carry it.
    eq(entry.name, "Two column, rich")
    eq(entry.layout.columns, 2)
    eq(entry.layout.lines[1].template, "%title")
    eq(entry.layout.lines[1].bold, true)
end)

t.test("saving the same name overwrites rather than making a second", function()
    reset()
    STORE["list_columns"] = 1
    Presets.save("Compact")
    STORE["list_columns"] = 3
    Presets.save("Compact")
    eq(#Presets.list(), 1, "a duplicate name made a second preset")
    eq(Presets.list()[1].layout.columns, 3, "the overwrite kept the old value")
end)

t.test("an empty name is refused", function()
    reset()
    assert(Presets.save("") == nil)
    assert(Presets.save("   ") == nil)
    assert(Presets.save(nil) == nil)
    eq(#Presets.list(), 0)
end)

-- ── Listing ────────────────────────────────────────────────────────────────

t.test("the list is sorted by name and skips anything unreadable", function()
    reset()
    STORE["list_columns"] = 1
    Presets.save("zebra")
    Presets.save("Alpha")
    -- A file a user hand-edited into nonsense, and one that is not a preset at
    -- all. Neither may take the menu down: these are plain files in a directory
    -- somebody can reach.
    FILES[Presets.dir() .. "/broken.lua"] = { name = "broken" }  -- no layout
    FILES[Presets.dir() .. "/notes.txt"]  = { layout = {} }      -- not .lua
    local out = Presets.list()
    eq(#out, 2, "a bad file was counted or a good one dropped")
    eq(out[1].name, "Alpha", "the list is not sorted case-insensitively")
    eq(out[2].name, "zebra")
end)

-- ── Apply ──────────────────────────────────────────────────────────────────

t.test("applying writes ALL four keys, not just the ones that differ",
function()
    reset()
    -- A previous layout with everything set...
    STORE[Lines.KEYS.lines]      = { { template = "old" }, { template = "old2" } }
    STORE[Lines.KEYS.show_cover] = false
    STORE["list_columns"]        = 3
    STORE["list_font_scale"]     = 150
    -- ...replaced by a preset that differs in every field.
    Presets.apply{
        lines = { { template = "new" } },
        show_cover = true, columns = 1, font_scale = 100,
    }
    eq(#Lines.layout().lines, 1, "the old line count survived")
    eq(Lines.layout().lines[1].template, "new")
    eq(Lines.layout().show_cover, true)
    eq(STORE["list_columns"], 1)
    eq(STORE["list_font_scale"], 100)
end)

t.test("a partial layout applies a default, never the incumbent value",
function()
    reset()
    STORE["list_columns"]    = 3
    STORE["list_font_scale"] = 150
    -- NOT a migration path -- presets have only ever had this one shape, and
    -- current() cannot produce a partial table. This is apply() being a total
    -- function: hand a it a table missing a field (a hand-edited file is the
    -- only way to get one) and it still writes every key, because leaving the
    -- previous value in place is what makes a preset feel like it
    -- half-applied.
    Presets.apply{ lines = { { template = "x" } } }
    eq(STORE["list_columns"], 1)
    eq(STORE["list_font_scale"], 100)
end)

t.test("applying nonsense changes nothing", function()
    reset()
    STORE["list_columns"] = 2
    assert(Presets.apply(nil) == false)
    assert(Presets.apply("layout") == false)
    eq(STORE["list_columns"], 2)
end)

t.test("a saved preset round-trips through apply unchanged", function()
    reset()
    STORE[Lines.KEYS.lines] = {
        { template = "%title", font_size = 18, bold = true, italic = true },
        { template = "%authors%spacer%bar{rel}", font_size = 13,
          bar_height = 70, bar_style = "solid", alignment = "right" },
    }
    STORE[Lines.KEYS.show_cover] = false
    STORE["list_columns"]        = 2
    STORE["list_font_scale"]     = 120
    local file = Presets.save("Rich")
    -- Wander off to something completely different...
    Presets.apply{ lines = { { template = "z" } }, show_cover = true,
                   columns = 1, font_scale = 100 }
    -- ...and come back.
    Presets.apply(Presets.read(file).layout)
    local L = Lines.layout()
    eq(#L.lines, 2)
    eq(L.lines[1].italic, true, "slant did not survive the round trip")
    eq(L.lines[2].bar_style, "solid", "a bar field did not survive")
    eq(L.lines[2].alignment, "right")
    eq(L.show_cover, false)
    eq(STORE["list_columns"], 2)
    eq(STORE["list_font_scale"], 120)
end)

-- ── Rename and delete ──────────────────────────────────────────────────────

t.test("rename writes the new file BEFORE removing the old", function()
    reset()
    STORE["list_columns"] = 2
    local old = Presets.save("Before")
    local new = Presets.rename(old, "After")
    eq(new, "after.lua")
    eq(#Presets.list(), 1, "rename left both files behind")
    eq(Presets.list()[1].name, "After")
    eq(Presets.list()[1].layout.columns, 2, "rename lost the layout")
end)

t.test("renaming to the same name is not a delete", function()
    reset()
    STORE["list_columns"] = 2
    local f = Presets.save("Same")
    assert(Presets.rename(f, "Same") ~= nil)
    eq(#Presets.list(), 1, "renaming to itself deleted the preset")
end)

t.test("renaming something that is not there fails without side effects",
function()
    reset()
    assert(Presets.rename("ghost.lua", "New") == nil)
    eq(#Presets.list(), 0)
end)

t.test("delete removes exactly one", function()
    reset()
    STORE["list_columns"] = 1
    Presets.save("One")
    Presets.save("Two")
    Presets.delete("one.lua")
    eq(#Presets.list(), 1)
    eq(Presets.list()[1].name, "Two")
end)

t.done()
