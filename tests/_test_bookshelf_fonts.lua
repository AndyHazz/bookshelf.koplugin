-- tests/_test_bookshelf_fonts.lua
-- Pure-Lua. Usage: luajit tests/_test_bookshelf_fonts.lua

-- stub KOReader Font: getFace echoes its arg into `last`, and returns nil for
-- any arg present in `missing` (to exercise the unresolvable-font fallback).
local last, missing = nil, {}
package.loaded["ui/font"] = {
    getFace = function(_, arg, size)
        last = { arg = arg, size = size }
        if missing[arg] then return nil end
        return { _face = arg, size = size }
    end,
}
-- stub lfs (module requires it at load; resolution no longer depends on it)
package.loaded["libs/libkoreader-lfs"] = { attributes = function() return "file" end }

-- stub settings store (mutable)
local settings = {}
package.loaded["lib/bookshelf_settings_store"] = {
    read = function(k, d) local v = settings[k]; if v == nil then return d end; return v end,
    save = function(k, v) settings[k] = v end,
    delete = function(k) settings[k] = nil end,
    flush = function() end,
    wasPresent = function() return false end,
}

local BFont = dofile("lib/bookshelf_fonts.lua")
local pass, fail = 0, 0
local function test(n, fn)
    settings = {}; missing = {}; last = nil
    package.loaded["lib/bookshelf_settings_store"].wasPresent = function() return false end
    local ok, e = pcall(fn)
    if ok then pass = pass + 1 else fail = fail + 1; io.stderr:write("FAIL " .. n .. "\n  " .. tostring(e) .. "\n") end
end
local function eq(a, e, m) if a ~= e then error((m or "") .. " expected=" .. tostring(e) .. " got=" .. tostring(a), 2) end end

test("follow mode (no setting): native named face, bold passed through", function()
    local face, bold = BFont:getFace("infofont", 16, { bold = true })
    eq(last.arg, "infofont", "should request native named face")
    eq(bold, true, "should pass caller bold through in follow mode")
end)

test("symbols always passes through, even with a UI font chosen", function()
    settings.bookshelf_ui_font = "/f/Foo-Regular.ttf"
    BFont:getFace("symbols", 18)
    eq(last.arg, "symbols", "symbols must never be remapped")
end)

test("chosen font, non-bold face: uses the stored face path, bold=false", function()
    settings.bookshelf_ui_font = "/f/Foo-Regular.ttf"
    local face, bold = BFont:getFace("infofont", 16)
    eq(last.arg, "/f/Foo-Regular.ttf", "uses stored regular face")
    eq(bold, false, "real file, no faux bold")
end)

test("chosen font, bold requested: derives the -Bold sibling", function()
    settings.bookshelf_ui_font = "/f/Foo-Regular.ttf"
    local face, bold = BFont:getFace("infofont", 16, { bold = true })
    eq(last.arg, "/f/Foo-Bold.ttf", "should derive -Bold sibling")
    eq(bold, false, "real bold file, no faux bold")
end)

test("bold-by-name face (tfont) derives the -Bold sibling without opts.bold", function()
    settings.bookshelf_ui_font = "/f/Foo-Regular.ttf"
    BFont:getFace("tfont", 20)
    eq(last.arg, "/f/Foo-Bold.ttf", "tfont -> bold sibling")
end)

test("bold requested but -Bold sibling unresolvable: faux-bold the regular", function()
    settings.bookshelf_ui_font = "/f/Foo-Regular.ttf"
    missing["/f/Foo-Bold.ttf"] = true              -- bold file does not resolve
    local face, bold = BFont:getFace("infofont", 16, { bold = true })
    eq(last.arg, "/f/Foo-Regular.ttf", "falls back to regular face")
    eq(bold, true, "asks the widget to faux-bold")
end)

test("chosen face with no -Regular. token, bold: faux-bold the regular", function()
    settings.bookshelf_ui_font = "Foo.ttf"          -- no "-Regular." to substitute
    local face, bold = BFont:getFace("infofont", 16, { bold = true })
    eq(last.arg, "Foo.ttf", "no sibling derivable -> use the face itself")
    eq(bold, true, "faux-bold")
end)

test("unresolvable chosen font: falls back to native named face (no crash)", function()
    settings.bookshelf_ui_font = "/f/Gone-Regular.ttf"
    missing["/f/Gone-Regular.ttf"] = true
    missing["/f/Gone-Bold.ttf"]    = true
    local face, bold = BFont:getFace("cfont", 14)
    eq(last.arg, "cfont", "unresolvable -> native named face")
    assert(face ~= nil, "must still return a (native) face, never nil")
end)

test("bundledFaceId returns the bare filename of a bundled font", function()
    eq(BFont.bundledFaceId("Inter ExtraBold"), "Inter-ExtraBold.ttf")
    eq(BFont.bundledFaceId("Caveat"), "Caveat-Regular.ttf")
    eq(BFont.bundledFaceId("Roboto Condensed"), "RobotoCondensed-Regular.ttf")
end)

test("set/get/isFollow round-trip", function()
    eq(BFont.isFollow(), true, "no setting -> follow")
    BFont.setUIFontFace("/f/Foo-Regular.ttf")
    eq(BFont.getUIFontFace(), "/f/Foo-Regular.ttf")
    eq(BFont.isFollow(), false)
    BFont.setUIFontFace(nil)
    eq(BFont.getUIFontFace(), nil, "nil -> follow")
    eq(BFont.isFollow(), true)
end)

test("seed: fresh install sets Roboto Condensed face id + seeds hero", function()
    local seeded_hero = false
    package.loaded["lib/bookshelf_hero_regions"] = { applyFreshInstallDefaults = function() seeded_hero = true end }
    BFont.maybeSeedFreshInstall()
    eq(settings.bookshelf_ui_font, "RobotoCondensed-Regular.ttf", "fresh -> Roboto Condensed face id")
    eq(settings.author_format, "first_last", "fresh -> author format First Last")
    eq(settings.chip_flex_widths, true, "fresh -> flexible chip widths (issue 176)")
    eq(seeded_hero, true, "fresh -> hero seeded")
    eq(settings.bookshelf_fonts_seeded, true, "marker set")
end)

test("seed: existing user (file present) left on follow", function()
    package.loaded["lib/bookshelf_settings_store"].wasPresent = function() return true end
    local seeded_hero = false
    package.loaded["lib/bookshelf_hero_regions"] = { applyFreshInstallDefaults = function() seeded_hero = true end }
    BFont.maybeSeedFreshInstall()
    eq(settings.bookshelf_ui_font, nil, "existing user -> no UI font (follow)")
    eq(settings.author_format, nil, "existing user -> author format untouched")
    eq(settings.chip_flex_widths, nil, "existing user -> chip widths untouched")
    eq(seeded_hero, false, "existing user -> hero NOT reseeded")
    eq(settings.bookshelf_fonts_seeded, true, "marker still set")
end)

test("seed: runs only once", function()
    settings.bookshelf_fonts_seeded = true
    BFont.maybeSeedFreshInstall()
    eq(settings.bookshelf_ui_font, nil, "already-seeded -> no-op")
end)

test("getUIFontFace: unresolvable stored face degrades to follow (issue 168)", function()
    -- The seeded RobotoCondensed default was dropped from KOReader v2026.03, so
    -- its face no longer loads; getUIFontFace must NOT hand that name back (a
    -- caller passes it straight to a KOReader Button whose Font:getFace returns
    -- nil and crashes). It degrades to follow (nil) instead.
    settings.bookshelf_ui_font = "RobotoCondensed-Regular.ttf"
    missing["RobotoCondensed-Regular.ttf"] = true
    eq(BFont.getUIFontFace(), nil, "unloadable stored face must degrade to follow")
end)

test("getUIFontFace: a loadable stored face is returned as-is", function()
    settings.bookshelf_ui_font = "/f/Bar-Regular.ttf"
    eq(BFont.getUIFontFace(), "/f/Bar-Regular.ttf", "loadable face returned unchanged")
end)

test("getUIFontFace: probe passes a size to getFace (issue 175)", function()
    -- A nil size makes the real font.lua fall back to sizemap[face]=nil and
    -- crash in Screen:scaleBySize(nil). Use a face value no other test touches
    -- so the per-value cache doesn't short-circuit the probe.
    settings.bookshelf_ui_font = "/f/Probe175-Regular.ttf"
    BFont.getUIFontFace()
    assert(last ~= nil, "probe must call Font:getFace")
    assert(type(last.size) == "number" and last.size > 0,
        "probe must pass a positive size; got " .. tostring(last and last.size))
end)

io.write(("bookshelf_fonts: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
