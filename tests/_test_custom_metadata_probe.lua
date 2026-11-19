-- tests/_test_custom_metadata_probe.lua
-- _customPropsFor asks for a book's custom_metadata.lua once per book during
-- the light-meta build. KOReader's DocSettings:findCustomMetadataFile stats
-- every candidate location, and while the hash location is in use (hash
-- preferred, or a hashdocsettings folder exists at all) it also takes a
-- partial MD5 of the book file to name the hash one: ~11.5 ms a book on a
-- PW5, 18.6 s for 1,613 books, every session.
--
-- So the doc (sibling .sdr) and dir (mirrored tree) locations are resolved by
-- name from cached directory listings (CM.namedFile), and KOReader's exact
-- probe is kept only when the hash tree holds a custom_metadata.lua at all
-- (CM.hashMayHoldCustom). Parity with findCustomMetadataFile was checked on
-- the rig for doc / dir / hash, each with no hash folder, an empty one and one
-- holding a book's custom metadata (9 cases, no mismatch).
--
-- The gate lives in module locals several layers below any exported entry
-- point, so this runs the real code: the block from the listing cache down to
-- CM.namedFile, compiled against a fake file system.
package.path = "./?.lua;./?/init.lua;" .. package.path

local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()

local src  = io.open("lib/bookshelf_book_repository.lua"):read("*a")
local ck   = src:match("\nlocal function _customPropsFor%(filepath%)\n(.-)\nend\n")
local s_at = src:find("\nlocal _dir_entry_cache = {}\n", 1, false)
local e_at = select(2, src:find("\nfunction CM%.namedFile%(filepath%)\n.-\nend\n", s_at))
assert(ck, "_customPropsFor is gone or was renamed")
assert(s_at and e_at, "the custom metadata gate block moved or was renamed")
local block = src:sub(s_at, e_at)

local function compile(code, env, name)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, name))
        _G.setfenv(f, env)
        return f
    end
    return assert(load(code, name, "t", env))
end

-- A fake file system: `files` and `dirs` are sets of absolute paths. Every
-- lfs.attributes call is counted, and the MD5 KOReader would take is too.
local function world(opts)
    local W = { files = {}, dirs = {}, stats = 0, md5 = 0, list_error = {} }
    for _i, f in ipairs(opts.files or {}) do
        W.files[f] = true
        local d = f:match("^(.*)/[^/]+$")
        while d and d ~= "" do W.dirs[d] = true; d = d:match("^(.*)/[^/]+$") end
    end
    for _i, d in ipairs(opts.dirs or {}) do W.dirs[d] = true end
    local lfs = {}
    function lfs.attributes(path, what)
        W.stats = W.stats + 1
        path = path:gsub("/$", "")
        if W.files[path] then return "file" end
        if W.dirs[path] then return "directory" end
        return nil
    end
    function lfs.dir(path)
        path = path:gsub("/$", "")
        if W.list_error[path] then error("EACCES") end
        local names, seen = { ".", ".." }, {}
        local prefix = path .. "/"
        for set in pairs({ [W.files] = true, [W.dirs] = true }) do
            for p in pairs(set) do
                if p:sub(1, #prefix) == prefix then
                    local name = p:sub(#prefix + 1):match("^[^/]+")
                    if name and not seen[name] then seen[name] = true; names[#names + 1] = name end
                end
            end
        end
        local i = 0
        return function() i = i + 1; return names[i] end
    end
    local pref = opts.pref or "doc"
    local mods = {
        ["libs/libkoreader-lfs"] = lfs,
        datastorage = {
            getDocSettingsDir = function() return "/ko/docsettings" end,
            getDocSettingsHashDir = function() return "/ko/hashdocsettings" end,
        },
        docsettings = {
            isHashLocationEnabled = function() return W.dirs["/ko/hashdocsettings"] == true end,
        },
    }
    local env = {
        require = function(name)
            local m = mods[name]; if not m then error("no module " .. name) end
            return m
        end,
        pcall = pcall, ipairs = ipairs, pairs = pairs, type = type, error = error,
        G_reader_settings = { readSetting = function(_s, _k, d) return pref or d end },
        Repo = {},
    }
    W.CM, W.reset = compile(block .. "\nreturn CM, _invalidateCustomMetaGate", env, "gate")()
    return W
end

local BOOK = "/books/Fantasy/Dune.epub"
local SIB  = "/books/Fantasy/Dune.sdr/custom_metadata.lua"
local MIR  = "/ko/docsettings/books/Fantasy/Dune.sdr/custom_metadata.lua"

t.test("the pieces are wired: hash gate first, name lookup otherwise", function()
    assert(ck:match("CM%.hashMayHoldCustom%(%)"), "_customPropsFor no longer asks the hash gate")
    assert(ck:match("findCustomMetadataFile"), "the exact probe must survive for a hash tree that holds one")
    assert(ck:match("CM%.namedFile%(filepath%)"), "_customPropsFor no longer resolves by name")
end)

t.test("no hash location in use: the hash tree is never consulted", function()
    local W = world{ pref = "doc" }
    assert(W.CM.hashMayHoldCustom() == false)
end)

t.test("hash preferred but no hash folder: nothing can be there", function()
    local W = world{ pref = "hash" }
    assert(W.CM.hashMayHoldCustom() == false)
end)

t.test("a hash tree of reading records only: no custom metadata possible", function()
    local W = world{ pref = "hash", files = {
        "/ko/hashdocsettings/ab/abcdef.sdr/metadata.epub.lua",
        "/ko/hashdocsettings/cd/cdef01.sdr/metadata.epub.lua" } }
    assert(W.CM.hashMayHoldCustom() == false)
end)

t.test("one custom_metadata.lua in the hash tree keeps the exact probe", function()
    local W = world{ pref = "doc", files = {
        "/ko/hashdocsettings/ab/abcdef.sdr/metadata.epub.lua",
        "/ko/hashdocsettings/cd/cdef01.sdr/custom_metadata.lua" } }
    assert(W.CM.hashMayHoldCustom() == true, "a leftover hash folder with one must still be probed")
end)

t.test("a hash listing that fails keeps the exact probe", function()
    local W = world{ pref = "hash", files = { "/ko/hashdocsettings/ab/abcdef.sdr/metadata.epub.lua" } }
    W.list_error["/ko/hashdocsettings/ab"] = true
    assert(W.CM.hashMayHoldCustom() == true)
end)

t.test("doc preference: the sibling wins over the mirror, as in KOReader", function()
    local W = world{ pref = "doc", files = { SIB, MIR } }
    assert(W.CM.namedFile(BOOK) == SIB)
end)

t.test("dir preference: the mirror wins over the sibling, as in KOReader", function()
    local W = world{ pref = "dir", files = { SIB, MIR } }
    assert(W.CM.namedFile(BOOK) == MIR)
end)

t.test("hash preference with nothing in hash: doc then dir, as in KOReader", function()
    local W = world{ pref = "hash", files = { SIB, MIR } }
    assert(W.CM.namedFile(BOOK) == SIB)
    local W2 = world{ pref = "hash", files = { MIR } }
    assert(W2.CM.namedFile(BOOK) == MIR)
end)

t.test("an opened book with no custom metadata: one stat, nil", function()
    local W = world{ pref = "dir", files = { "/books/Fantasy/Dune.sdr/metadata.epub.lua" } }
    W.CM.mirrorRoot()       -- resolved once per session, not per book
    local before = W.stats
    assert(W.CM.namedFile(BOOK) == nil)
    -- one listing read of the parent (cached for the folder's other books) +
    -- the one custom_metadata.lua stat; no mirror tree, so nothing there
    assert(W.stats - before <= 2, "expected at most 2 stats, got " .. (W.stats - before))
end)

t.test("a book never opened costs no custom_metadata stat", function()
    local W = world{ pref = "dir", dirs = { "/books/Fantasy", "/ko/docsettings" } }
    W.CM.namedFile(BOOK)          -- reads the two listings once
    local before = W.stats
    W.CM.namedFile("/books/Fantasy/Emma.epub")
    assert(W.stats == before, "a second book in a listed folder must need no stat")
end)

t.test("the gate state is dropped with the listings", function()
    local W = world{ pref = "hash", files = { "/ko/hashdocsettings/ab/abcdef.sdr/metadata.epub.lua" } }
    assert(W.CM.hashMayHoldCustom() == false)
    W.files["/ko/hashdocsettings/ab/abcdef.sdr/custom_metadata.lua"] = true
    assert(W.CM.hashMayHoldCustom() == false, "cached until the gate is reset")
    W.reset()
    assert(W.CM.hashMayHoldCustom() == true,
        "a reset (invalidateLightMeta) must see a custom_metadata.lua written since")
end)

-- The gate answers "does this book have a sibling .sdr?" from a per-directory
-- listing. The walk that produced the book list has just read every one of
-- those directories, so it hands its listings over instead of the gate reading
-- them again: 29 duplicate listings on the reference library, and the saving
-- grows with the number of directories, not the number of books.
--
-- Functionally verified on a PW5: the sibling lookup went from 104ms to 69ms
-- across 321 books with the seeding in place. That measurement is also what
-- proves the key normalisation below, since a mismatched key makes the whole
-- thing a silent no-op that no error would reveal.
local seed = src:match("\nlocal function _seedDirEntryCache%(listings%)\n(.-)\nend\n")

t.test("the walk hands its directory listings to the gate", function()
    assert(seed, "_seedDirEntryCache is gone or was renamed")
    assert(src:match("local function walkBooks%(root, depth, out, current_depth, dirs, listings%)"),
        "walkBooks no longer collects listings")
    assert(src:match("walkBooks%(home, depth, fresh, 0, dirs, listings%)"),
        "the cached walk no longer passes a listings table")
    assert(src:match("_seedDirEntryCache%(listings%)"),
        "the listings are collected but never handed over")
end)

t.test("the seeded key matches the form the gate looks up", function()
    -- CM.namedFile asks with the parent directory INCLUDING its trailing
    -- slash; the walk names directories without one. Seed under the raw name
    -- and every lookup misses, the gate reads every directory again, and
    -- nothing anywhere reports a problem -- it is just slow again.
    assert(seed:match('gsub%("/%*%$", ""%)') and seed:match('%.%. "/"'),
        "the seeded key must be normalised to the trailing-slash form")
end)

t.test("seeding never overwrites a listing already in hand", function()
    -- An entry already present was either read directly or seeded by a walk no
    -- older than this one, so it is never the staler of the two.
    assert(seed:match("== nil"),
        "the seed must not clobber an existing entry")
end)

t.test("only a fresh walk seeds the gate", function()
    -- Seeding from a cached walk would describe a library that may have
    -- changed since, and this cache decides whether a book's sidecar exists.
    local walkfn = src:match("\n    if stale_reason then\n(.-)\n    else\n")
        or src:match("walkBooks%(home, depth, fresh, 0, dirs, listings%)(.-)\n    else\n")
    assert(walkfn and walkfn:match("_seedDirEntryCache"),
        "seeding must sit on the fresh-walk branch, beside walkBooks")
end)

t.done()
