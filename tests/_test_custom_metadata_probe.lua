-- tests/_test_custom_metadata_probe.lua
-- _customKeywords asks for a book's custom_metadata.lua once per book during
-- the light-meta build. The sibling ".sdr" fast path answers that with one
-- stat against a path the cached directory listing already proved exists,
-- instead of DocSettings:findCustomMetadataFile stat-ing every candidate
-- location. On a PW5 (243 books, 82% with a sidecar, 11 with custom metadata)
-- that took the probe from ~190ms to ~130ms of a ~1000ms cold build.
--
-- The fast path is only SOUND when the sibling is the only place the file
-- could be. These are SOURCE-SHAPE checks on that condition: the function is
-- a module local several layers below any exported entry point, and the
-- repository suite's fixture does not reach it (verified). The device
-- measurement showed the same 11 files found either way.
package.path = "./?.lua;./?/init.lua;" .. package.path

local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()

local src  = io.open("lib/bookshelf_book_repository.lua"):read("*a")
local ck   = src:match("\nlocal function _customKeywords%(filepath%)\n(.-)\nend\n")
local only = src:match("\nlocal function _sidecarIsOnlyLocation%(%)\n(.-)\nend\n")

t.test("the pieces are still there under those names", function()
    assert(ck, "_customKeywords is gone or was renamed")
    assert(only, "_sidecarIsOnlyLocation is gone or was renamed")
    assert(src:match("\nlocal function _siblingSidecarDir%(filepath%)"),
        "_siblingSidecarDir is gone or was renamed")
end)

t.test("the fast path is gated on the sibling being the ONLY location", function()
    assert(ck:match("_sidecarIsOnlyLocation%(%)"),
        "the single-stat probe must be gated -- otherwise a hash-located or "
        .. "mirrored sidecar is silently missed")
end)

t.test("anything else still goes through findCustomMetadataFile", function()
    assert(ck:match("findCustomMetadataFile"),
        "the slow path must survive for the locations the sibling cannot answer for")
    assert(ck:match("_customMetaPossible"),
        "the original gate must still guard the slow path")
end)

t.test("the only-location test rules out each way the sibling could be wrong",
function()
    -- Miss any one of these and the fast path starts returning "no custom
    -- metadata" for books that have some, which looks like data loss rather
    -- than a bug: the genres just quietly revert to the embedded keywords.
    assert(only:match("document_metadata_folder"),
        "a non-doc metadata folder preference must disable the fast path")
    assert(only:match("isHashLocationEnabled"),
        "a hash-located sidecar is not name-derivable -- must disable it")
    assert(only:match("getDocSettingsDir"),
        "a mirrored sidecar tree must disable it")
end)

t.test("the memo is dropped with the rest of the gate state", function()
    local inv = src:match("\nlocal function _invalidateCustomMetaGate%(%)\n(.-)\nend\n")
    assert(inv and inv:match("_only_location"),
        "_only_location must be cleared alongside the directory listings, or a "
        .. "settings change is ignored until restart")
end)

t.done()
