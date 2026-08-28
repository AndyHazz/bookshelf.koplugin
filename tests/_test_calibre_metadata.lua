-- tests/_test_calibre_metadata.lua
-- The vendored calibre reader, exercised directly. It was extracted out of
-- bookshelf_book_repository so BOOKENDS can share it byte-identically (#348):
-- both plugins write the same calibre.bookshelf.json harvest, and a subset
-- writer would clobber the other's author_sort and extra_series.
-- Usage: cd into the plugin dir, then `lua tests/_test_calibre_metadata.lua`.

-- KOReader environment, stubbed the way every other suite here does it. Unlike
-- token_semantics this module is NOT pure by design: reading a settings key and
-- stat-ing a file is its whole job, so the environment is stubbed rather than
-- the module made defensive against a KOReader that cannot happen.
_G.G_reader_settings = {
    readSetting = function(_self, key)
        if key == "home_dir" then return "/nonexistent-library" end
        return nil
    end,
}
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function() return nil end,   -- no metadata.calibre anywhere
}

local t = dofile("tests/_helpers.lua").runner()
local CalibreMeta = dofile("lib/calibre_metadata.lua")

t.test("module exposes its contract", function()
    assert(type(CalibreMeta.entryFor) == "function", "entryFor missing")
    assert(type(CalibreMeta.fieldsFor) == "function", "fieldsFor missing")
    assert(type(CalibreMeta.invalidate) == "function", "invalidate missing")
    assert(CalibreMeta.HARVEST_NAME == "calibre.bookshelf.json",
           "harvest filename must not change: renaming orphans every existing "
           .. "harvest file on every device")
end)

-- The gate is the whole reason this is a parameter rather than a settings read:
-- bookshelf passes its beta setting, bookends passes true because its
-- needs("calibre") check already means the file is untouched unless a template
-- names the token.
t.test("a falsy gate returns nil without touching the filesystem", function()
    assert(CalibreMeta.entryFor("/any/path.epub", false) == nil)
    assert(CalibreMeta.entryFor("/any/path.epub", nil) == nil)
    assert(CalibreMeta.fieldsFor("/any/path.epub", false) == nil)
end)

t.test("a missing metadata.calibre yields nil, not an error", function()
    CalibreMeta.invalidate()
    local ok, res = pcall(CalibreMeta.entryFor, "/nonexistent/book.epub", true)
    assert(ok, "entryFor raised: " .. tostring(res))
    assert(res == nil, "expected nil for a library with no metadata.calibre")
end)

t.done()
